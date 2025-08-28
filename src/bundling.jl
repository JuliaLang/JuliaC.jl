function bundle_products(recipe::BundleRecipe)
    bundle_start = time_ns()

    # Validate that bundling makes sense for this output type
    output_type = recipe.link_recipe.image_recipe.output_type
    if output_type == "--output-o" || output_type == "--output-bc"
        error("Cannot bundle $(output_type) output type. $(output_type) generates object files/archives that don't require bundling. Use compile_products() directly instead of bundle_products().")
    end

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
                # Track this directory for removal in the consolidation function
                dirs_to_remove = [dest_julia_dir]
            else
                dirs_to_remove = String[]
            end
            mv(src_julia_dir, dest_julia_dir; force=true)
        else
            dirs_to_remove = String[]
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
    else
        dirs_to_remove = String[]
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
                        try
                            symlink(best, target)
                        catch
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

    # Perform library removal operations
    remove_unnecessary_libraries(recipe)

    # Optional privatization of libjulia: single entry point dispatching per-OS (disabled by default)
    if recipe.privatize
        privatize_libjulia!(recipe)
    end

    # On macOS, codesign the bundled binaries to avoid Gatekeeper kills when loading
    if Sys.isapple()
        _codesign_bundle!(recipe)
    end

    # Now perform all directory removals at once
    for dir in dirs_to_remove
        rm(dir; force=true, recursive=true)
    end
end

function remove_unnecessary_libraries(recipe::BundleRecipe)
    bundle_root = recipe.output_dir
    julia_dir = joinpath(bundle_root, recipe.libdir)
    !isdir(julia_dir) && return
    # If trim is enable remove codegen
    if recipe.link_recipe.image_recipe.enable_trim
        for (root, _, files) in walkdir(julia_dir)
            for f in files
                if occursin("libLLVM", f) || occursin("libjulia-codegen", f)
                    rm(joinpath(root, f); force=true)
                end
            end
        end
    end
end



function privatize_libjulia!(recipe::BundleRecipe)
    if Sys.isapple()
        privatize_libjulia_macos!(recipe)
    elseif Sys.islinux()
        privatize_libjulia_linux!(recipe)
    else
        @warn "Privatization not implemented for this OS"
    end
end



