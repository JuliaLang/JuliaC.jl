function get_rpath(recipe::LinkRecipe)
    if recipe.rpath !== nothing
        local base_token
        if Sys.isapple()
            base_token = "-Wl,-rpath,'@loader_path/"
        elseif Sys.islinux()
            base_token = "-Wl,-rpath,'\$ORIGIN/"
        else
            @warn "no path set"
            return ""
        end
        # If rpath is a relative subdir (e.g., "lib"), emit @loader_path/lib and @loader_path/lib/julia
        priv_path = joinpath(recipe.rpath, "julia")
        base_path = recipe.rpath
        flag1 = base_token * base_path * "'"
        flag2 = base_token * priv_path * "'"
        return string(flag1, " ", flag2)
    else
        return JuliaConfig.ldrpath()
    end
end

function get_compiler_cmd(; cplusplus::Bool=false)
    cc = get(ENV, "JULIA_CC", nothing)
    path = nothing
    @static if Sys.iswindows()
        path = joinpath(LazyArtifacts.artifact"mingw-w64",
                        "extracted_files",
                        (Int==Int64 ? "mingw64" : "mingw32"),
                        "bin",
                        cplusplus ? "g++.exe" : "gcc.exe")
        compiler_cmd = `$path`
    end
    if cc !== nothing
        compiler_cmd = Cmd(Base.shell_split(cc))
        path = nothing
    elseif !Sys.iswindows()
        compilers_cpp = ("g++", "clang++")
        compilers_c = ("gcc", "clang")
        found_compiler = false
        if cplusplus
            for compiler in compilers_cpp
                if Sys.which(compiler) !== nothing
                    compiler_cmd = `$compiler`
                    found_compiler = true
                    break
                end
            end
        end
        if !found_compiler
            for compiler in compilers_c
                if Sys.which(compiler) !== nothing
                    compiler_cmd = `$compiler`
                    found_compiler = true
                    break
                end
            end
        end
        found_compiler || error("could not find a compiler, looked for ",
            join(((cplusplus ? compilers_cpp : ())..., compilers_c...), ", ", " and "))
    end
    if path !== nothing
        compiler_cmd = addenv(compiler_cmd, "PATH" => string(ENV["PATH"], ";", dirname(path)))
    end
    return compiler_cmd
end

function link_products(recipe::LinkRecipe)
    link_start = time_ns()
    image_recipe = recipe.image_recipe
    if image_recipe.output_type == "--output-o" || image_recipe.output_type == "--output-bc"
        mkpath(dirname(recipe.outname))
        # Overwrite any previous build artifact to make tests idempotent
        if isfile(recipe.outname)
            rm(recipe.outname; force=true)
        end
        mv(image_recipe.img_path, recipe.outname; force=true)
        println("Linking took $((time_ns() - link_start)/1e9) s")
        try
            out_sz = stat(recipe.outname).size
            println("Linked artifact size: ", Base.format_bytes(out_sz))
        catch
        end
        return
    end
    if image_recipe.output_type == "--output-lib" || image_recipe.output_type == "--output-sysimage"
        of, ext = splitext(recipe.outname)
        soext = "." * Base.BinaryPlatforms.platform_dlext()
        if ext == ""
            recipe.outname = of * soext
        end
    end
    # Ensure .exe suffix for executables on Windows
    @static if Sys.iswindows()
        if image_recipe.output_type == "--output-exe"
            of, ext = splitext(recipe.outname)
            if lowercase(ext) != ".exe"
                recipe.outname = of * ".exe"
            end
        end
    end
    rpath_str = Base.shell_split(get_rpath(recipe))
    julia_libs = Base.shell_split(Base.isdebugbuild() ? "-ljulia-debug -ljulia-internal-debug" : "-ljulia -ljulia-internal")
    compiler_cmd = get_compiler_cmd()
    allflags = Base.shell_split(JuliaConfig.allflags(; framework=false, rpath=false))
    try
        mkpath(dirname(recipe.outname))
        if image_recipe.output_type == "--output-lib"
            cmd2 = `$(compiler_cmd) $(allflags) $(rpath_str) -o $(recipe.outname) -shared -Wl,$(Base.Linking.WHOLE_ARCHIVE) $(image_recipe.img_path) $(image_recipe.extra_objects...) -Wl,$(Base.Linking.NO_WHOLE_ARCHIVE)  $(julia_libs)`
        elseif image_recipe.output_type == "--output-sysimage"
            cmd2 = `$(compiler_cmd) $(allflags) $(rpath_str) -o $(recipe.outname) -shared -Wl,$(Base.Linking.WHOLE_ARCHIVE) $(image_recipe.img_path) $(image_recipe.extra_objects...) -Wl,$(Base.Linking.NO_WHOLE_ARCHIVE) $(julia_libs)`
        else
            cmd2 = `$(compiler_cmd) $(allflags) $(rpath_str) -o $(recipe.outname) -Wl,$(Base.Linking.WHOLE_ARCHIVE) $(image_recipe.img_path) $(image_recipe.extra_objects...) -Wl,$(Base.Linking.NO_WHOLE_ARCHIVE)  $(julia_libs)`
        end
        image_recipe.verbose && println("Running: $cmd2")
        run(cmd2)
    catch e
        error("\nCompilation failed: ", e)
    end
    println("Linking took $((time_ns() - link_start)/1e9) s")
    try
        out_sz = stat(recipe.outname).size
        println("Linked artifact size: ", Base.format_bytes(out_sz))
    catch
    end
end
