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

function _absolutize_paths!(x, base)
    if x isa AbstractDict
        p = get(x, "path", nothing)
        if p isa AbstractString && !isabspath(p)
            x["path"] = abspath(joinpath(base, p))
        end
        for v in values(x)
            _absolutize_paths!(v, base)
        end
    elseif x isa AbstractVector
        for v in values(x)
            _absolutize_paths!(v, base)
        end
    end
end

# Replace `[sources]` with absolute paths, referenced to `basedir`
function absolutize_paths!(project_dir, basedir)
    for f in readdir(project_dir)
        occursin(r"^(Julia)?(Project|Manifest).*\.toml$", f) || continue
        file = joinpath(project_dir, f)
        let data = TOML.parsefile(file)
            _absolutize_paths!(data, basedir)
            open(file, "w") do io
                TOML.print(io, data)
            end
        end
    end
    return nothing
end

"""
    TRIM_PREFERENCE

Name of the preference that JuliaC sets to `true`, for every package in the environment
being compiled, when trimming is enabled. A package can load it at compile time to leave
out code that should not end up in a trimmed binary:

    using Preferences
    const JULIAC_TRIM = @load_preference("juliac_trim", false)
"""
const TRIM_PREFERENCE = "juliac_trim"

# Set `TRIM_PREFERENCE` for every package in the environment of `project_toml`: the
# project itself (if it is a package) and the contents of its manifest.
#
# Preferences are only tracked per package: a precompile cache is keyed on the
# preferences its own package loaded, so a single preference under JuliaC's UUID would
# not cause the packages reading it to be recompiled. Setting it under each package's
# own name does, and only for the packages that actually load it.
function set_trim_preferences!(project_toml::AbstractString)
    project = TOML.parsefile(project_toml)
    pkgs = Tuple{Base.UUID,String}[]
    name, uuid = get(project, "name", nothing), get(project, "uuid", nothing)
    if name isa String && uuid isa String
        push!(pkgs, (Base.UUID(uuid), name))
    end
    manifest_file = Base.project_file_manifest_path(String(project_toml))
    if manifest_file !== nothing && isfile(manifest_file)
        for (dep, entries) in Base.get_deps(TOML.parsefile(manifest_file)), entry in entries
            dep_uuid = get(entry, "uuid", nothing)
            dep_uuid isa String && push!(pkgs, (Base.UUID(dep_uuid), dep))
        end
    end

    extras = get!(Dict{String,Any}, project, "extras")
    prefs = get!(Dict{String,Any}, project, "preferences")
    for (uuid, name) in pkgs
        # Preferences are looked up under the name the project knows the package by,
        # which a package that is not a direct dependency only has through `[extras]`.
        known = Base.get_uuid_name(project, uuid)
        if known === nothing
            # Two packages may share a name, but `[extras]` can only map it to one UUID
            known = haskey(extras, name) ? string(name, "-", uuid) : name
            extras[known] = string(uuid)
        end
        get!(Dict{String,Any}, prefs, known)[TRIM_PREFERENCE] = true
    end
    open(project_toml, "w") do io
        TOML.print(io, project; sorted = true)
    end
    return nothing
end

function run_with_suppressed_output(cmd::Base.AbstractCmd; quiet::Bool)
    if quiet
        buf = IOBuffer()
        ok = success(pipeline(cmd; stdout=buf, stderr=buf))
        if !ok
            data = take!(buf)
            isempty(data) || write(stderr, data)
        end
        return ok
    else
        return success(pipeline(cmd; stdout, stderr))
    end
end

"""
    c_shim_compile_cmd(recipe::ImageRecipe, csrc, obj) -> Cmd

Command compiling the C shim `csrc` into `obj`: Julia's cflags followed by
`recipe.cflags`, each entry passed to the compiler as one argument.
"""
function c_shim_compile_cmd(recipe::ImageRecipe, csrc::AbstractString, obj::AbstractString)
    cflags = [JuliaConfig.cflags(; framework=false); recipe.cflags]
    return `$(get_compiler_cmd()) $cflags -c $csrc -o $obj`
end

# `Base.julia_cmd` forwards many codegen-relevant args by default. These affect the compiled
# product(s), so we filter them and require these to be passed via `recipe.julia_args` instead.
const SESSION_CODEGEN_OPTIONS = ("--code-coverage", "--track-allocation", "--check-bounds",
                                 "--inline", "--min-optlevel", "--compile=")

# `Base.julia_cmd`, without this session's code generation options (including `-O` and `-g`)
function build_julia_cmd(; kwargs...)
    cmd = Base.julia_cmd(; kwargs...)
    return Cmd(filter(cmd.exec) do arg
        !(any(opt -> startswith(arg, opt), SESSION_CODEGEN_OPTIONS) || occursin(r"^-[Og]\d$", arg))
    end)
end

# Build for the same CPUs as Julia's own system image (Julia 1.13+ only)
function default_cpu_target()
    isdefined(Sys, :sysimage_target) || return nothing
    # Ask a new process: loading packages overwrites this value in the current one
    return readchomp(`$(Base.julia_cmd()) --startup-file=no --history-file=no -e "print(Sys.sysimage_target())"`)
end

function expand_sysimage_target(cpu_target::AbstractString)
    (cpu_target == "sysimage" || startswith(cpu_target, "sysimage;")) || return String(cpu_target)
    target = default_cpu_target()
    target === nothing && return String(cpu_target)
    return target * chopprefix(cpu_target, "sysimage")
end

function is_cpu_target_directive(tok::AbstractString)
    name = (startswith(tok, '+') || startswith(tok, '-')) ? SubString(tok, 2) : tok
    return name in ("clone_all", "opt_size", "min_size") ||
           (startswith(name, "base(") && endswith(name, ")"))
end

function first_cpu_target(cpu_target::AbstractString)
    tokens = split(first(split(cpu_target, ';')), ',')
    return join([first(tokens); filter(!is_cpu_target_directive, tokens[2:end])], ',')
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
        recipe.cpu_target = get(default_cpu_target, ENV, "JULIA_CPU_TARGET")
    end
    if recipe.cpu_target !== nothing
        recipe.cpu_target = expand_sysimage_target(recipe.cpu_target)
    end
    # Ensure the app project is instantiated and precompiled
    if isdir(recipe.file)
        if recipe.project != ""
            error("Cannot separately specify a project when compiling a package")
        end
        recipe.project = recipe.file
    end

    project_arg = recipe.project == "" ? Base.active_project() : recipe.project

    # Always copy the project to a temp dir so Pkg.instantiate() can write Manifest.toml etc.
    # This avoids failures when the project dir is read-only (e.g. installed packages).
    # project_arg may be a Project.toml path (from Base.active_project()) or a directory.
    project_dir = isdir(project_arg) ? project_arg : dirname(project_arg)
    tmp_project = mktempdir()
    for f in readdir(project_dir)
        src = joinpath(project_dir, f)
        dst = joinpath(tmp_project, f)
        cp(src, dst; force=true)
    end
    # Ensure copied files are writable — Pkg-installed packages are read-only,
    # and cp() preserves permissions. Pkg.instantiate() needs to write Manifest.toml etc.
    for (root, dirs, files) in walkdir(tmp_project)
        for name in Iterators.flatten((dirs, files))
            p = joinpath(root, name)
            chmod(p, filemode(p) | 0o200)
        end
    end
    project_arg = isdir(project_arg) ? tmp_project : joinpath(tmp_project, basename(project_arg))

    # Update any `[sources]` to refer to the original `project_dir`
    absolutize_paths!(tmp_project, project_dir)

    # Always clear JULIA_LOAD_PATH to prevent parent environment leakage
    # (e.g. when JuliaC is invoked as a Pkg app, the shim sets JULIA_LOAD_PATH
    # to JuliaC's own project, which would break user project compilation — #106/#124).
    env_overrides = Dict{String,Any}("JULIA_LOAD_PATH" => nothing)

    # Preferences are injected directly into the temp project copy so they're visible
    # without JULIA_LOAD_PATH manipulation.
    tmp_project_toml = project_arg
    if isdir(project_arg)
        # The file Julia will use for `--project=<dir>`, which may be `JuliaProject.toml`
        located = Base.env_project_file(project_arg)
        tmp_project_toml = located isa String ? located : joinpath(project_arg, "Project.toml")
    end
    if is_trim_enabled(recipe)
        Preferences.set_preferences!(
            (Base.UUID("3e5b6fbb-0976-4d2c-9146-d79de83f2fb0"), "HostCPUFeatures"),
            "freeze_cpu_target" => true;
            project_toml = tmp_project_toml,
            export_prefs = true,
            force = true,
        )
    end

    jit_target = recipe.cpu_target === nothing ? nothing : first_cpu_target(recipe.cpu_target)
    function run_pkg(code, env...)
        pkg_cmd = addenv(`$(build_julia_cmd(cpu_target=jit_target)) --project=$project_arg -e $code`,
                         env_overrides..., "JULIA_CPU_TARGET" => recipe.cpu_target, env...)
        recipe.verbose && println("Running: $pkg_cmd")
        if !run_with_suppressed_output(pkg_cmd; quiet=recipe.quiet)
            error("Error encountered during instantiate/precompile of app project.")
        end
    end
    precompile_time = time_ns()
    # The packages to set the trim preference for are only known once the manifest is
    # resolved, and they must see it before they are precompiled, so instantiate without
    # precompiling first.
    run_pkg("using Pkg; Pkg.instantiate()", "JULIA_PKG_PRECOMPILE_AUTO" => "0")
    is_trim_enabled(recipe) && set_trim_preferences!(tmp_project_toml)
    run_pkg("using Pkg; Pkg.precompile()")
    # Record the instantiated project dir for future bundling steps, cleanup, etc.
    recipe.instantiated_project = tmp_project
    recipe.verbose && println("Precompilation took $((time_ns() - precompile_time)/1e9) s")
    # Compile the Julia code
    if recipe.img_path == ""
        tmpdir = mktempdir()
        recipe.img_path = joinpath(tmpdir, "image.o.a")
    end
    # Build command incrementally to guarantee proper token separation
    cmd = `$(build_julia_cmd(;cpu_target=recipe.cpu_target)) --startup-file=no --history-file=no`
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
    # Show a spinner while the compiler runs (suppressed in quiet mode)
    (spinner_done, spinner_task) = if recipe.quiet
        (nothing, nothing)
    else
        _start_spinner("Compiling...")
    end
    compile_time = time_ns()
    try
        if !run_with_suppressed_output(cmd; quiet=recipe.quiet)
            error("Failed to compile $(recipe.file)")
        end
    finally
        if spinner_task !== nothing
            spinner_done[] = true
            wait(spinner_task)
        end
    end
    recipe.verbose && println("Compilation took $((time_ns() - compile_time)/1e9) s")
    # Print compiled image size
    if recipe.verbose
        @assert isfile(recipe.img_path)
        img_sz = stat(recipe.img_path).size
        println("Image size: ", Base.format_bytes(img_sz))
    end
    # If C shim sources are provided, compile them to objects for linking stage
    for csrc in recipe.c_sources
        obj = replace(csrc, ".c" => ".o")
        cmdc = c_shim_compile_cmd(recipe, csrc, obj)
        recipe.verbose && println("Running: $cmdc")
        try
            run(cmdc)
        catch e
            error("C shim compilation failed: ", e)
        end
        push!(recipe.extra_objects, obj)
    end
    # Always compile the jl_options shim so that jl_parse_opts runs
    # consistently, even when no explicit options are provided.
    if !isempty(recipe.jl_options)
        _validate_jl_options(recipe.jl_options)
    end
    obj = _compile_jl_options_shim(recipe.jl_options; verbose=recipe.verbose)
    push!(recipe.extra_objects, obj)
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
    default_cflags = JuliaC.JuliaConfig.cflags(; framework=false)
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
    if !isempty(jl_options)
        julia_bin = joinpath(Sys.BINDIR, "julia")
        validate_cmd = `$julia_bin --startup-file=no`
        for (key, value) in jl_options
            validate_cmd = `$validate_cmd --$(key)=$(value)`
        end
        validate_cmd = `$validate_cmd -e ""`
        verbose && println("Validating jl_options: $validate_cmd")
        errbuf = IOBuffer()
        if !success(pipeline(validate_cmd; stdout=devnull, stderr=errbuf))
            errmsg = String(take!(errbuf))
            error("Invalid --jl-option values: $(strip(errmsg))")
        end
    end
    return init_obj
end
