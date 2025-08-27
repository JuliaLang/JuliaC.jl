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

    # No-op: avoid creating unsalted macOS libjulia symlinks; privatization will manage salted symlinks only

    # Perform library removal operations
    remove_unnecessary_libraries(recipe)

    # Optional privatization of libjulia: single entry point dispatching per-OS (disabled by default)
    if recipe.privatize
        privatize_libjulia!(recipe)
    end

    # On macOS, codesign the bundled binaries to avoid Gatekeeper kills when loading
    if Sys.isapple()
        try
            _codesign_bundle!(recipe)
        catch e
            @warn "Codesign step failed" exception=(e, catch_backtrace())
        end
    end

    # Now perform all directory removals at once
    for dir in dirs_to_remove
        try
            rm(dir; force=true, recursive=true)
        catch
        end
    end
end

function remove_unnecessary_libraries(recipe::BundleRecipe)
    bundle_root = recipe.output_dir
    julia_dir = joinpath(bundle_root, recipe.libdir, "julia")
    !isdir(julia_dir) && return

    # If trim was enabled, remove large, unnecessary libraries such as LLVM from the bundle
    # Only do this for library bundles; executables may still require LLVM at runtime
    if recipe.link_recipe.image_recipe.enable_trim && recipe.link_recipe.image_recipe.output_type != "--output-exe"
        for (root, _, files) in walkdir(julia_dir)
            for f in files
                if occursin("libLLVM", f)
                    try
                        rm(joinpath(root, f); force=true)
                    catch
                    end
                end
            end
        end
    end

    # Remove libjulia-codegen if present (it's not needed for most applications)
    for (root, _, files) in walkdir(bundle_root)
        for f in files
            if occursin("libjulia-codegen", f)
                try
                    rm(joinpath(root, f); force=true)
                catch
                end
            end
        end
    end
end



function privatize_libjulia!(recipe::BundleRecipe)
    if Sys.isapple()
        try
            privatize_libjulia_macos!(recipe)
        catch e
            @warn "Failed to privatize libjulia on macOS" exception=(e, catch_backtrace())
        end
    elseif Sys.islinux()
        try
            privatize_libjulia_linux!(recipe)
        catch e
            @warn "Failed to privatize libjulia on Linux" exception=(e, catch_backtrace())
        end
    else
        @warn "Privatization not implemented for this OS"
    end
end


if Sys.isapple()
function _codesign_bundle!(recipe::BundleRecipe)
    cs = Sys.which("codesign")
    xattr = Sys.which("xattr")
    cs === nothing && return
    libroot = joinpath(recipe.output_dir, recipe.libdir)
    to_sign = String[]
    if isdir(libroot)
        for (r, _, files) in walkdir(libroot)
            for f in files
                p = joinpath(r, f)
                if endswith(p, ".dylib") || endswith(p, ".so") || endswith(p, ".bundle") || endswith(p, ".dylib")
                    push!(to_sign, p)
                end
            end
        end
    end
    # Also sign the primary artifact (exe or dylib)
    if isfile(recipe.link_recipe.outname)
        push!(to_sign, recipe.link_recipe.outname)
    end
    # Clear quarantine attributes first
    if xattr !== nothing
        for p in to_sign
            try
                run(`$xattr -dr com.apple.quarantine $p`)
            catch
            end
        end
    end
    # Narrow signing set: primary artifact and salted libjulia* copies only
    salted_re = r"^[A-Za-z0-9_-]+_libjulia.*\.(dylib|so|bundle)$"
    filtered = String[]
    for p in unique(to_sign)
        b = basename(p)
        if p == recipe.link_recipe.outname || occursin(salted_re, b)
            push!(filtered, p)
        end
    end
    # Perform deep ad-hoc signing
    for p in filtered
        # Skip symlinks; signing them is unnecessary and noisy
        if islink(p)
            continue
        end
        try
            run(`$cs -f -s - --deep --timestamp=none $p`)
        catch e
            @warn "codesign failed" file=p exception=(e, catch_backtrace())
        end
    end
end
end

