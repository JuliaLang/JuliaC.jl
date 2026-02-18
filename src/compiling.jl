# Lightweight terminal spinner
function _start_spinner(message::String; io::IO=stderr)
    anim_chars = ("◐", "◓", "◑", "◒")
    finished = Ref(false)
    # Detect whether the output supports carriage return animation
    can_tty = io isa Base.TTY
    term = get(ENV, "TERM", "")
    animate = can_tty && term != "dumb"
    task = Threads.@spawn begin
        idx = 1
        t = Timer(0; interval=0.2)
        try
            if !animate
                println(io, message)
                flush(io)
            end
            while !finished[]
                if animate
                    print(io, '\r', anim_chars[idx], ' ', message)
                    flush(io)
                    wait(t)
                    idx = idx == length(anim_chars) ? 1 : idx + 1
                else
                    wait(t)
                end
            end
        finally
            close(t)
            if animate
                print(io, '\r', '✓', ' ', message, '\n')
            else
                print(io, '✓', ' ', message, '\n')
            end
            flush(io)
        end
    end
    return finished, task
end

function compile_products(recipe::ImageRecipe)
    # Only strip IR / metadata if not `--trim=no`
    strip_args = String[]
    if is_trim_enabled(recipe)
        push!(strip_args, "--strip-ir")
        push!(strip_args, "--strip-metadata")
        # Detect trim support on 1.12 prereleases as well
        supports_trim = (VERSION.major > 1 || VERSION.minor >= 12) || (:trim in fieldnames(typeof(Base.JLOptions())))
        if supports_trim && recipe.trim_mode !== nothing
            # On 1.12 prereleases, --trim requires --experimental; harmless on stable
            push!(strip_args, "--experimental")
            push!(strip_args, "--trim=$(recipe.trim_mode)")
        end
    end
    if recipe.output_type == "--output-bc"
        image_arg = "--output-bc"
    else
        image_arg = "--output-o"
    end
    # Default: export ccallable entrypoints for shared libraries
    if recipe.output_type == "--output-lib" && recipe.add_ccallables == false
        recipe.add_ccallables = true
    end
    # Default: disable signal handlers and limit to single thread for shared libraries
    if recipe.output_type == "--output-lib"
        get!(recipe.jl_options, "handle-signals", "no")
        get!(recipe.jl_options, "threads", "1")
    end
    if recipe.cpu_target === nothing
        recipe.cpu_target = get(ENV,"JULIA_CPU_TARGET", nothing)
    end
    julia_cmd = `$(Base.julia_cmd(;cpu_target=recipe.cpu_target)) --startup-file=no --history-file=no`
    if recipe.cpu_target !== nothing
        precompile_cpu_target = String(first(split(recipe.cpu_target, [';',','])))
    else
        precompile_cpu_target = nothing
    end
    # Ensure the app project is instantiated and precompiled
    if isdir(recipe.file)
        if recipe.project != ""
            error("Cannot separately specify a project when compiling a package")
        end
        recipe.project = recipe.file
    end

    project_arg = recipe.project == "" ? Base.active_project() : recipe.project
    env_overrides = Dict{String,Any}()
    tmp_prefs_env = nothing
    if is_trim_enabled(recipe)
        load_path_sep = Sys.iswindows() ? ";" : ":"
        # Create a temporary environment with a LocalPreferences.toml that will be added to JULIA_LOAD_PATH.
        tmp_prefs_env = mktempdir()
        open(joinpath(tmp_prefs_env, "Project.toml"), "w") do io
            println(io, "[extras]")
            println(io, "HostCPUFeatures = \"3e5b6fbb-0976-4d2c-9146-d79de83f2fb0\"")
        end
        # Write LocalPreferences.toml with the trim preferences
        open(joinpath(tmp_prefs_env, "LocalPreferences.toml"), "w") do io
            println(io, "[HostCPUFeatures]")
            println(io, "freeze_cpu_target = true")
        end
        # Append the temp env to JULIA_LOAD_PATH

        env_overrides["JULIA_LOAD_PATH"] = load_path_sep * tmp_prefs_env
    end

    inst_cmd = addenv(`$(Base.julia_cmd(cpu_target=precompile_cpu_target)) --project=$project_arg -e "using Pkg; Pkg.instantiate(); Pkg.precompile()"`, env_overrides...)
    recipe.verbose && println("Running: $inst_cmd")
    precompile_time = time_ns()
    if !success(pipeline(inst_cmd; stdout, stderr))
        error("Error encountered during instantiate/precompile of app project.")
    end
    recipe.verbose && println("Precompilation took $((time_ns() - precompile_time)/1e9) s")
    # Compile the Julia code
    if recipe.img_path == ""
        tmpdir = mktempdir()
        recipe.img_path = joinpath(tmpdir, "image.o.a")
    end
    project_arg = recipe.project == "" ? Base.active_project() : recipe.project
    # Build command incrementally to guarantee proper token separation
    cmd = julia_cmd
    cmd = `$cmd --project=$project_arg $(image_arg) $(recipe.img_path) --output-incremental=no`
    for a in strip_args
        cmd = `$cmd $a`
    end
    for a in recipe.julia_args
        cmd = `$cmd $a`
    end
    cmd = `$cmd $(joinpath(JuliaC.SCRIPTS_DIR, "juliac-buildscript.jl")) --scripts-dir $(JuliaC.SCRIPTS_DIR) --source $(abspath(recipe.file)) $(recipe.output_type)`
    if recipe.add_ccallables
        cmd = `$cmd --compile-ccallable`
    end
    if recipe.use_loaded_libs
        cmd = `$cmd --use-loaded-libs`
    end
    if recipe.export_abi !== nothing
        cmd = `$cmd --export-abi $(recipe.export_abi)`
    end

    # Threading
    cmd = addenv(cmd, env_overrides...)
    recipe.verbose && println("Running: $cmd")
    # Show a spinner while the compiler runs
    spinner_done, spinner_task = _start_spinner("Compiling...")
    compile_time = time_ns()
    try
        if !success(pipeline(cmd; stdout, stderr))
            error("Failed to compile $(recipe.file)")
        end
    finally
        spinner_done[] = true
        wait(spinner_task)
    end
    recipe.verbose && println("Compilation took $((time_ns() - compile_time)/1e9) s")
    # Print compiled image size
    if recipe.verbose
        @assert isfile(recipe.img_path)
        img_sz = stat(recipe.img_path).size
        println("Image size: ", Base.format_bytes(img_sz))
    end
    # If C shim sources are provided, compile them to objects for linking stage
    if !isempty(recipe.c_sources)
        compiler_cmd = JuliaC.get_compiler_cmd()
        # Ensure include flags are passed as separate tokens
        default_cflags = Base.shell_split(JuliaC.JuliaConfig.cflags(; framework=false))
        user_cflags = String[]
        for cf in recipe.cflags
            if startswith(cf, "-I") && cf != "-I"
                push!(user_cflags, cf)
            else
                append!(user_cflags, split(cf))
            end
        end
        cflags = isempty(user_cflags) ? default_cflags : vcat(default_cflags, user_cflags)
        for csrc in recipe.c_sources
            obj = replace(csrc, ".c" => ".o")
            try
                # Build command incrementally to avoid argument concatenation issues
                cmdc = compiler_cmd
                for cf in cflags
                    cmdc = `$cmdc $cf`
                end
                cmdc = `$cmdc -c $(csrc) -o $(obj)`
                recipe.verbose && println("Running: $cmdc")
                run(cmdc)
                push!(recipe.extra_objects, obj)
            catch e
                error("C shim compilation failed: ", e)
            end
        end
    end
    # Generate and compile a C shim that sets jl_options fields via constructor
    if !isempty(recipe.jl_options)
        _validate_jl_options(recipe.jl_options)
        obj = _compile_jl_options_shim(recipe.jl_options; verbose=recipe.verbose)
        push!(recipe.extra_objects, obj)
    end
end

const _SUPPORTED_JL_OPTIONS = Set([
    "handle-signals",
    "threads",
])

"""
Validate that all keys in `jl_options` are supported option names.
Option names match Julia CLI flags (e.g. `handle-signals`, `threads`).
"""
function _validate_jl_options(jl_options::Dict{String,String})
    for key in keys(jl_options)
        if key ∉ _SUPPORTED_JL_OPTIONS
            error("Unsupported jl_options key: \"$key\". Supported keys are: $(join(sort(collect(_SUPPORTED_JL_OPTIONS)), ", "))")
        end
    end
end

"""
Generate and compile a C shim that calls `jl_parse_opts` with a synthetic
argv in an `__attribute__((constructor))`.

The boilerplate C code lives in `scripts/juliac-jl-options-shim.c` and
`#include`s a generated `juliac-jl-options-body.h` containing the argv
string literals.

After compilation, links the shim into a trivial executable and runs it
to validate that `jl_parse_opts` accepts the options. This catches invalid
values at compile time rather than at load time.

Returns the path to the compiled object file.
"""
function _compile_jl_options_shim(jl_options::Dict{String,String}; verbose::Bool=false)
    compiler_cmd = JuliaC.get_compiler_cmd()
    default_cflags = Base.shell_split(JuliaC.JuliaConfig.cflags(; framework=false))
    tmpdir = mktempdir()
    shim_src = joinpath(JuliaC.SCRIPTS_DIR, "juliac-jl-options-shim.c")
    body_hdr = joinpath(tmpdir, "juliac-jl-options-body.h")
    init_obj = joinpath(tmpdir, "juliac-jl-options-init.o")
    # Generate argv entries for jl_parse_opts
    open(body_hdr, "w") do io
        println(io, "/* Generated by JuliaC — jl_parse_opts argv entries */")
        for (key, value) in jl_options
            println(io, "\"--$(key)=$(value)\",")
        end
    end
    verbose && println("Generated jl_options body: $body_hdr")
    # Compile the template shim with -I pointing at the generated body
    cmdc = compiler_cmd
    for cf in default_cflags
        cmdc = `$cmdc $cf`
    end
    cmdc = `$cmdc -I$tmpdir -c $shim_src -o $init_obj`
    verbose && println("Running: $cmdc")
    try
        run(cmdc)
    catch e
        error("jl_options init shim compilation failed: ", e)
    end
    # Validate by running julia with the same flags.
    julia_bin = joinpath(Sys.BINDIR, "julia")
    validate_cmd = `$julia_bin`
    for (key, value) in jl_options
        validate_cmd = `$validate_cmd --$(key)=$(value)`
    end
    validate_cmd = `$validate_cmd -e ""`
    verbose && println("Validating jl_options: $validate_cmd")
    if !success(pipeline(validate_cmd; stdout=devnull, stderr))
        error("Invalid --jl-option values. Check that option values match Julia CLI syntax (e.g. --handle-signals=yes|no, --threads=N[,M]).")
    end
    return init_obj
end
