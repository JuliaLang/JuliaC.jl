function get_rpath(recipe::LinkRecipe)
    if recipe.rpath === nothing
        recipe.rpath = Sys.iswindows() ? "" : joinpath("..", "lib") # Default rpaths
    end
    if Sys.isapple()
        base_token = "-Wl,-rpath,'@loader_path/"
    elseif Sys.islinux()
        base_token = "-Wl,-rpath,'\$ORIGIN/"
    else
        @warn "get_rpath not implemented for this platform"
        return ""
    end
    # If rpath is a relative subdir (e.g., "lib"), emit @loader_path/lib and @loader_path/lib/julia
    priv_path = joinpath(recipe.rpath, "julia")
    base_path = recipe.rpath
    flag1 = base_token * base_path * "'"
    flag2 = base_token * priv_path * "'"
    return string(flag1, " ", flag2)
end

function get_compiler_cmd(; cplusplus::Bool=false)
    cc = get(ENV, "JULIA_CC", nothing)
    path = nothing
    @static if Sys.iswindows() && cc === nothing
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

    # Validate that linking makes sense for this output type
    if image_recipe.output_type == "--output-o" || image_recipe.output_type == "--output-bc"
        error("Cannot link $(image_recipe.output_type) output type. $(image_recipe.output_type) generates object files/archives that don't require linking. Use compile_products() directly instead of link_products().")
    end
    if image_recipe.output_type == "--output-lib" || image_recipe.output_type == "--output-sysimage"
        of, ext = splitext(recipe.outname)
        soext = "." * Base.BinaryPlatforms.platform_dlext()
        if ext == ""
            # User provided no extension - add the platform-specific extension
            recipe.outname = of * soext
        elseif ext != soext
            # User provided wrong extension - this is an error
            error("Invalid file extension '$(ext)' for $(image_recipe.output_type). Expected '$(soext)' for this platform.")
        end
    end
    # Ensure .exe suffix for executables on Windows
    if Sys.iswindows()
        if image_recipe.output_type == "--output-exe"
            of, ext = splitext(recipe.outname)
            if ext == ""
                # User provided no extension - add .exe for Windows executables
                recipe.outname = of * ".exe"
            elseif lowercase(ext) != ".exe"
                # User provided wrong extension - this is an error
                error("Invalid file extension '$(ext)' for $(image_recipe.output_type). Expected '.exe' for Windows executables.")
            end
        end
    end
    rpath_str = Base.shell_split(get_rpath(recipe))
    julia_libs = Base.shell_split(Base.isdebugbuild() ? "-ljulia-debug -ljulia-internal-debug" : "-ljulia -ljulia-internal")
    compiler_cmd = get_compiler_cmd()
    allflags = Base.shell_split(JuliaConfig.allflags(; framework=false, rpath=false))
    try
        mkpath(dirname(recipe.outname))
        is_shared_output = image_recipe.output_type != "--output-exe"
        # Base command
        cmd2 = `$(compiler_cmd) $(allflags) $(rpath_str) -o $(recipe.outname)`
        if is_shared_output
            cmd2 = `$cmd2 -shared`
        end
        # Link in the whole archive and user-provided objects, then undo WHOLE_ARCHIVE
        cmd2 = `$cmd2 -Wl,$(Base.Linking.WHOLE_ARCHIVE) $(image_recipe.img_path) $(image_recipe.extra_objects...) -Wl,$(Base.Linking.NO_WHOLE_ARCHIVE) $(julia_libs)`
        # Platform-specific linker flags
        lib_name = basename(recipe.outname)
        if Sys.iswindows()
            lib_basename, _ = splitext(lib_name)
            import_lib_path = joinpath(dirname(recipe.outname), lib_basename * ".dll.a")
            cmd2 = `$cmd2 -Wl,--out-implib=$(import_lib_path)`
        elseif Sys.isapple()
            cmd2 = `$cmd2 -Wl,-install_name,@rpath/$(lib_name)`
        elseif Sys.islinux()
            cmd2 = `$cmd2 -Wl,-soname,$(lib_name)`
        end
        image_recipe.verbose && println("Running: $cmd2")
        run(cmd2)
    catch e
        error("\nCompilation failed: ", e)
    end
    image_recipe.verbose && println("Linking took $((time_ns() - link_start)/1e9) s")
    if image_recipe.verbose
        @assert isfile(recipe.outname)
        out_sz = stat(recipe.outname).size
        println("Linked artifact size: ", Base.format_bytes(out_sz))
    end
end
