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
    if recipe.enable_trim
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
    if recipe.cpu_target === nothing
        recipe.cpu_target = get(ENV,"JULIA_CPU_TARGET", nothing)
    end
    julia_cmd = `$(Base.julia_cmd(;cpu_target=recipe.cpu_target)) --startup-file=no --history-file=no`
    # Ensure the app project is instantiated and precompiled
    project_arg = recipe.project == "" ? Base.active_project() : recipe.project
    env_overrides = Dict{String,Any}()
    inst_cmd = addenv(`$(Base.julia_cmd()) --project=$project_arg -e "using Pkg; Pkg.instantiate(); Pkg.precompile()"`, env_overrides...)
    recipe.verbose && println("Running: $inst_cmd")
    precompile_time = time_ns()
    if !success(pipeline(inst_cmd; stdout, stderr))
        error("Error encountered during instantiate/precompile of app project.")
    end
    println("Precompilation took $((time_ns() - precompile_time)/1e9) s")
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
    cmd = `$cmd $(joinpath(@__DIR__, "scripts", "juliac-buildscript.jl")) $(abspath(recipe.file)) $(recipe.output_type) $(string(recipe.add_ccallables))`
    # Threading
    cmd = addenv(cmd, "OPENBLAS_NUM_THREADS" => 1, "JULIA_NUM_THREADS" => 1)
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
    println("Compilation took $((time_ns() - compile_time)/1e9) s")
    # Print compiled image size
    try
        img_sz = stat(recipe.img_path).size
        println("Image size: ", Base.format_bytes(img_sz))
    catch
        # ignore size errors
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
        new_cflags = ``
        for flag in cflags
            new_cflags = `$new_cflags $flag`
        end
        @show new_cflags
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
end
