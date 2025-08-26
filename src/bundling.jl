function bundle_products(recipe::BundleRecipe)
    bundle_start = time_ns()

    if recipe.output_dir === nothing
        return
    end

    # Ensure the bundle output directory exists
    mkpath(recipe.output_dir)

    # Create julia subdirectory for bundled libraries under lib/ (or bin/ on Windows)
    ctx2 = PackageCompiler.create_pkg_context(recipe.link_recipe.image_recipe.project)
    stdlibs = unique(vcat(PackageCompiler.gather_stdlibs_project(ctx2), PackageCompiler.stdlibs_in_sysimage()))
    PackageCompiler.bundle_julia_libraries(recipe.output_dir, stdlibs)
    PackageCompiler.bundle_artifacts(ctx2, recipe.output_dir; include_lazy_artifacts=false) # Lazy artifacts

    # Re-home bundled libraries into the desired bundle layout
    libdir = recipe.libdir
    # Move `<output_dir>/julia` -> `<output_dir>/<libdir>/julia`
    src_julia_dir = joinpath(recipe.output_dir, "julia")
    if isdir(src_julia_dir)
        dest_root = joinpath(recipe.output_dir, libdir)
        mkpath(dest_root)
        dest_julia_dir = joinpath(dest_root, "julia")
        if abspath(src_julia_dir) != abspath(dest_julia_dir)
            if isdir(dest_julia_dir)
                rm(dest_julia_dir; force=true, recursive=true)
            end
            mv(src_julia_dir, dest_julia_dir; force=true)
        end
        # On Windows, place required DLLs next to the executable (in bin/) for loader discovery
        if Sys.iswindows()
            bindir = dest_root
            # Recursively copy .dll files from julia dir into bin root
            for (root, _, files) in walkdir(dest_julia_dir)
                for f in files
                    if endswith(f, ".dll")
                        src = joinpath(root, f)
                        dst = joinpath(bindir, f)
                        cp(src, dst; force=true)
                    end
                end
            end
        end
    end

    # Determine where to place the built product within the bundle
    outname = recipe.link_recipe.outname
    is_exe = recipe.link_recipe.image_recipe.output_type == "--output-exe"
    bindir = Sys.iswindows() ? libdir : "bin"
    dest_dir = is_exe ? joinpath(recipe.output_dir, bindir) : joinpath(recipe.output_dir, libdir)
    mkpath(dest_dir)
    dest = joinpath(dest_dir, basename(outname))
    if abspath(outname) != abspath(dest)
        mv(outname, dest; force=true)
        recipe.link_recipe.outname = dest
    end
    # Use relative rpath layout by default (handled by linking with empty rpath string)

    # On macOS, ensure expected dylib version symlinks exist (e.g., libjulia.1.12.dylib -> libjulia.1.12.0.dylib)
    if Sys.isapple()
        julia_dir = joinpath(recipe.output_dir, libdir, "julia")
        if isdir(julia_dir)
            # Map of base name to the symlink we want
            wanted = [
                ("libjulia", "1.12"),
                ("libjulia-internal", "1.12"),
            ]
            for (base, shortver) in wanted
                target = joinpath(julia_dir, string(base, ".", shortver, ".dylib"))
                if !isfile(target)
                    # Find the highest semantic versioned dylib for this base
                    candidates = filter(readdir(julia_dir)) do f
                        startswith(f, base * ".") && endswith(f, ".dylib")
                    end
                    if !isempty(candidates)
                        # Prefer the longest version string (most specific)
                        best = sort(candidates, by=length, rev=true)[1]
                        # Try symlink first; if it fails, copy as a fallback
                        ok = false
                        try
                            symlink(best, target)
                            ok = true
                        catch
                            ok = false
                        end
                        if !ok
                            try
                                cp(joinpath(julia_dir, best), target; force=true)
                            catch
                                # ignore if copy fails; test will fail and surface issue
                            end
                        end
                    end
                end
            end
        end
    end
    # Summarize bundle size
    try
        total = 0
        for (root, _, files) in walkdir(recipe.output_dir)
            for f in files
                total += stat(joinpath(root, f)).size
            end
        end
        println("Bundling took $((time_ns() - bundle_start)/1e9) s")
        println("Bundle size: ", Base.format_bytes(total))
    catch
    end
end
