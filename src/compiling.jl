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

    if is_trim_enabled(recipe)
        # Inject the HostCPUFeatures `freeze_cpu_target` preference directly into the
        # temp project copy so it's visible without JULIA_LOAD_PATH manipulation.
        tmp_project_dir = isdir(project_arg) ? project_arg : dirname(project_arg)
        Preferences.set_preferences!(
            (Base.UUID("3e5b6fbb-0976-4d2c-9146-d79de83f2fb0"), "HostCPUFeatures"),
            "freeze_cpu_target" => true;
            project_toml = joinpath(tmp_project_dir, "Project.toml"),
            export_prefs = true,
            force = true,
        )
    end

    inst_cmd = addenv(`$(Base.julia_cmd(cpu_target=precompile_cpu_target)) --project=$project_arg -e "using Pkg; Pkg.instantiate(); Pkg.precompile()"`, env_overrides...)
    recipe.verbose && println("Running: $inst_cmd")
    precompile_time = time_ns()
    if !run_with_suppressed_output(inst_cmd; quiet=recipe.quiet)
        error("Error encountered during instantiate/precompile of app project.")
    end
    # Record the instantiated project dir for future bundling steps, cleanup, etc.
    recipe.instantiated_project = tmp_project
    recipe.verbose && println("Precompilation took $((time_ns() - precompile_time)/1e9) s")
    # Compile the Julia code
    if recipe.img_path == ""
        tmpdir = mktempdir()
        recipe.img_path = joinpath(tmpdir, "image.o.a")
    end
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
    if !isempty(recipe.link_native_libs) || recipe.link_native_blas !== nothing
        # The buildscript resolves these package specs through their
        # JuliaLibrary.toml records and registers the resolved dlids with the
        # runtime before any user code (and therefore any ccall lowering)
        # runs; the AOT stub-emission pass consults that table to decide
        # which ccalls to bind natively. The resolved libraries are written
        # to the link-inputs manifest for the link step, and a foreign-deps
        # manifest is always requested so the driver can verify afterwards
        # that every requested library was actually bound natively.
        recipe.link_inputs_path = recipe.img_path * ".link-inputs.toml"
        if !isempty(recipe.link_native_libs)
            cmd = `$cmd --link-native $(join(recipe.link_native_libs, ','))`
        end
        if recipe.link_native_blas !== nothing
            cmd = `$cmd --link-native-blas $(recipe.link_native_blas)`
        end
        cmd = `$cmd --link-inputs $(recipe.link_inputs_path)`
        if recipe.export_foreign_deps === nothing
            recipe.export_foreign_deps = recipe.img_path * ".foreign-deps.json"
        end
    end
    if recipe.export_foreign_deps !== nothing
        cmd = `$cmd --export-foreign-deps $(abspath(recipe.export_foreign_deps))`
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
    # Always compile the jl_options shim so that jl_parse_opts runs
    # consistently, even when no explicit options are provided.
    if !isempty(recipe.jl_options)
        _validate_jl_options(recipe.jl_options)
    end
    obj = _compile_jl_options_shim(recipe.jl_options; verbose=recipe.verbose)
    push!(recipe.extra_objects, obj)
    # Verify the native-link policy took effect: every library requested via
    # --link-native must have all of its ccall/cglobal sites bound natively.
    # A site left at lazy lookup here would silently fall back at runtime.
    if !isempty(recipe.link_native_libs) || recipe.link_native_blas !== nothing
        _verify_native_linkage(recipe)
    end
    # Compile the LBT control-API shim for --link-native-blas, configured
    # from the resolved provider entry in the link-inputs manifest.
    if recipe.link_native_blas !== nothing
        _compile_lbt_shim(recipe)
    end
end

"""
Compile JuliaC's libblastrampoline control-API shim (see shims/lbt-shim.c),
configured for the resolved BLAS provider, and add it to the link objects.
"""
function _compile_lbt_shim(recipe::ImageRecipe)
    inputs = TOML.parsefile(recipe.link_inputs_path)
    # The resolution pass records bare specs; strip any linkage-mode prefix.
    bare_spec = replace(recipe.link_native_blas, r"^(static|dynamic):" => "")
    provider = nothing
    for lib in get(inputs, "libraries", Any[])
        if lib["spec"] == bare_spec
            provider = lib
            break
        end
    end
    provider === nothing &&
        error("--link-native-blas: provider $(bare_spec) was not resolved")
    dlname = provider["dlname"]
    # Official Julia builds use the `64_`-suffixed ILP64 interface on 64-bit
    # platforms; the record's dlname carries that fact.
    ilp64 = occursin("64_", dlname)
    suffix = ilp64 ? "64_" : ""
    shim_src = joinpath(JuliaC.SHIMS_DIR, "lbt-shim.c")
    obj = joinpath(dirname(recipe.link_inputs_path), "lbt-shim.o")
    compiler_cmd = JuliaC.get_compiler_cmd()
    cflags = Base.shell_split(JuliaC.JuliaConfig.cflags(; framework=false))
    cmdc = compiler_cmd
    for cf in cflags
        cmdc = `$cmdc $cf`
    end
    cmdc = `$cmdc -DLBT_SHIM_LIBNAME="\"$(dlname)\"" -DLBT_SHIM_SUFFIX="\"$(suffix)\"" -DLBT_SHIM_ILP64=$(ilp64 ? 1 : 0)`
    cmdc = `$cmdc -c $(shim_src) -o $(obj)`
    recipe.verbose && println("Running: $cmdc")
    run(cmdc)
    push!(recipe.extra_objects, obj)
    return nothing
end

"""
Cross-check the foreign-deps manifest against the link-inputs manifest: every
dlid the resolution pass registered must appear only with `native` linkage.
The parse is deliberately minimal and coupled to the fixed formatting of the
runtime's manifest emitter (`aot_export_foreign_deps`): groups are keyed by
the frozen dlid, and each symbol line carries its linkage.
"""
function _verify_native_linkage(recipe::ImageRecipe)
    inputs_path = recipe.link_inputs_path
    manifest_path = recipe.export_foreign_deps
    (inputs_path === nothing || !isfile(inputs_path)) &&
        error("--link-native: buildscript did not produce the link-inputs manifest")
    (manifest_path === nothing || !isfile(manifest_path)) &&
        error("--link-native: no foreign-deps manifest was produced to verify against")
    inputs = TOML.parsefile(inputs_path)
    manifest = read(manifest_path, String)
    failures = String[]
    for lib in get(inputs, "libraries", Any[])
        dlid = lib["dlid"]
        # The group for this dlid, if any: from its key line to the next
        # group key (4-space indented quoted key) or the end of the object.
        m = findfirst("\"$(dlid)\":", manifest)
        m === nothing && continue # no sites referenced this library
        rest = manifest[last(m):end]
        nextgroup = findfirst(r"\n    \"", rest)
        group = nextgroup === nothing ? rest : rest[1:first(nextgroup)]
        for sym in eachmatch(r"\{\"symbol\": (\"[^\"]*\"), [^}]*\"linkage\": \"lazy\"\}", group)
            push!(failures, "$(lib["package"]).$(lib["product"]): $(sym.captures[1])")
        end
    end
    if !isempty(failures)
        error("--link-native: the following symbols were left at lazy lookup despite ",
              "their library being requested for native linking:\n  ",
              join(failures, "\n  "))
    end
    return nothing
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
