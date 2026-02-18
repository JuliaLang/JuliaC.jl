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
    if recipe.output_type == "--output-lib" && isempty(recipe.jl_options)
        recipe.jl_options["handle-signals"] = "no"
        recipe.jl_options["threads"] = "1"
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
Parse `--jl-option handle-signals=yes|no` into C assignments.
Mirrors Julia's `--handle-signals` parsing in `jloptions.c`.
"""
function _emit_handle_signals(io::IO, value::String)
    if value == "yes"
        println(io, "opts->handle_signals = JL_OPTIONS_HANDLE_SIGNALS_ON;")
    elseif value == "no"
        println(io, "opts->handle_signals = JL_OPTIONS_HANDLE_SIGNALS_OFF;")
    else
        error("Invalid value for handle-signals: \"$value\". Expected \"yes\" or \"no\".")
    end
end

"""
Parse `--jl-option threads=N[,M]` into C assignments.
Mirrors Julia's `--threads` / `-t` parsing in `jloptions.c`:
- `N` → N threads in default pool; if N==1, 1 pool; else 2 pools (+ 1 interactive)
- `N,M` → N default + M interactive; if M==0, 1 pool; else 2 pools
- `N,auto` → N default + 1 interactive, 2 pools

Does not support `auto` for N (libraries should specify a concrete thread count).
"""
function _emit_threads(io::IO, value::String)
    parts = split(value, ','; limit=2)
    nthreads_str = parts[1]
    nthreads_str == "auto" && error("\"auto\" is not supported for threads in --jl-option; specify a concrete count.")
    nthreads = tryparse(Int, nthreads_str)
    nthreads === nothing && error("Invalid thread count: \"$nthreads_str\"")
    nthreads < 1 && error("Thread count must be >= 1, got $nthreads")

    if length(parts) == 2
        # N,M or N,auto
        ipart = parts[2]
        if ipart == "auto"
            nthreadsi = 1
        else
            nthreadsi = tryparse(Int, ipart)
            nthreadsi === nothing && error("Invalid interactive thread count: \"$ipart\"")
            nthreadsi < 0 && error("Interactive thread count must be >= 0, got $nthreadsi")
        end
    elseif nthreads == 1
        # Like Julia: 1 thread → no interactive pool
        nthreadsi = 0
    else
        # Like Julia: N>1 → add 1 interactive thread
        nthreadsi = 1
    end

    nthreadpools = nthreadsi == 0 ? 1 : 2
    total = nthreads + nthreadsi

    println(io, "opts->nthreads = $total;")
    println(io, "opts->nthreadpools = $nthreadpools;")
    println(io, "{")
    println(io, "    int16_t *ntpp = (int16_t *)malloc($nthreadpools * sizeof(int16_t));")
    println(io, "    if (ntpp) {")
    println(io, "        ntpp[0] = (int16_t)$nthreads;")
    if nthreadpools == 2
        println(io, "        ntpp[1] = (int16_t)$nthreadsi;")
    end
    println(io, "        opts->nthreads_per_pool = ntpp;")
    println(io, "    }")
    println(io, "}")
end

"""
Generate and compile a C shim that overrides `jl_options` fields via an
`__attribute__((constructor))`.

The boilerplate C code lives in `scripts/juliac-jl-options-shim.c` and
`#include`s a generated `juliac-jl-options-body.h` containing just the
option assignments.  See the shim source for how `jl_options` is resolved
on each platform.

Returns the path to the compiled object file.
"""
function _compile_jl_options_shim(jl_options::Dict{String,String}; verbose::Bool=false)
    compiler_cmd = JuliaC.get_compiler_cmd()
    default_cflags = Base.shell_split(JuliaC.JuliaConfig.cflags(; framework=false))
    tmpdir = mktempdir()
    shim_src = joinpath(JuliaC.SCRIPTS_DIR, "juliac-jl-options-shim.c")
    body_hdr = joinpath(tmpdir, "juliac-jl-options-body.h")
    init_obj = joinpath(tmpdir, "juliac-jl-options-init.o")
    # Generate only the option-assignment body
    open(body_hdr, "w") do io
        println(io, "/* Generated by JuliaC — jl_options field assignments */")
        if haskey(jl_options, "handle-signals")
            _emit_handle_signals(io, jl_options["handle-signals"])
        end
        if haskey(jl_options, "threads")
            _emit_threads(io, jl_options["threads"])
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
    return init_obj
end
