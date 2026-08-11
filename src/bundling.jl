"""
Remove bundled shared libraries that the executable no longer references:
those whose static library was linked into the binary (shipping the
`.so` would at best waste space and at worst load a second copy), and those
whose call sites were substituted away entirely (e.g. libblastrampoline
under --link-native-blas).
"""
function _filter_statically_linked!(output_dir::String, image_recipe::ImageRecipe)
    inputs_path = image_recipe.link_inputs_path
    (inputs_path === nothing || !isfile(inputs_path)) && return
    inputs = TOML.parsefile(inputs_path)
    # Sonames the executable resolves through the system loader at process
    # start: hard runtime dependencies that no bundle filter may ever remove.
    protected = Set{String}(String(lib["dlname"]) for lib in get(inputs, "libraries", Any[])
                            if get(lib, "linkage", "") == "dynamic")
    for lib in get(inputs, "libraries", Any[])
        get(lib, "linkage", "") in ("static", "substituted") || continue
        dlname = lib["dlname"]
        # Strip the platform extension to a stem, and remove the soname, its
        # symlink chain, and versioned filenames (e.g. libfoo.so,
        # libfoo.so.2, libfoo.2.3.4.so).
        stem = replace(dlname, r"\.so(\.\d+)*$|\.\d+\.dylib$|\.dylib$|(-\d+)?\.dll$" => "")
        isempty(stem) && continue
        for (root, _, files) in walkdir(output_dir)
            for f in files
                startswith(f, stem * ".") || f == stem * ".dll" || continue
                f in protected && continue
                rm(joinpath(root, f); force=true)
            end
        end
    end
    return
end

# Natively-linked *dynamic* libraries that live in artifacts are not
# covered by the stdlib library bundling: flatten each into the bundle's
# private library directory under its soname (the name the executable's
# DT_NEEDED records), with an $ORIGIN rpath. The provision closure
# guarantees every dependency of a natively-linked library is itself
# natively provided and therefore co-located, so $ORIGIN suffices.
function _bundle_native_artifact_libs!(recipe::BundleRecipe)
    image_recipe = recipe.link_recipe.image_recipe
    inputs_path = image_recipe.link_inputs_path
    (inputs_path === nothing || !isfile(inputs_path)) && return
    inputs = TOML.parsefile(inputs_path)
    dest_dir = joinpath(recipe.output_dir, recipe.libdir, "julia")
    for lib in get(inputs, "libraries", Any[])
        get(lib, "linkage", "") == "dynamic" || continue
        get(lib, "location", "") == "artifact" || continue
        src = get(lib, "path", nothing)
        src isa String && isfile(src) ||
            error("--link-native: artifact library $(lib["dlname"]) vanished before bundling")
        mkpath(dest_dir)
        dest = joinpath(dest_dir, lib["dlname"])
        cp(src, dest; force=true)
        chmod(dest, 0o755)
        if Sys.islinux()
            origin_rpath = raw"$ORIGIN"
            run(`$(Patchelf_jll.patchelf()) --set-rpath $(origin_rpath) $(dest)`)
        end
        # On Windows the loader searches next to the executable.
        if Sys.iswindows()
            cp(dest, joinpath(recipe.output_dir, recipe.libdir, lib["dlname"]); force=true)
        end
    end
    return
end

# System libraries the dynamic loader provides on every supported system;
# DT_NEEDED entries matching these prefixes need not ship in the bundle.
const _SYSTEM_SONAME_PREFIXES = (
    "ld-linux", "libc.so", "libm.so", "libdl.so", "libpthread.so",
    "librt.so", "libutil.so", "libresolv.so", "libmvec.so",
)

"""
Verify the bundle satisfies what the link line promised: every natively
linked *dynamic* library resolves at process start, through the executable's
rpath, from files actually present in the bundle. Lazy loading masks a
broken library rpath (dependencies are dlopened explicitly, by absolute
path, before use); native linking hands the whole DT_NEEDED chain to the
system loader at exec, so presence and per-object closure are checked here
rather than discovered as a launch failure on the deployment target.
"""
function _verify_native_link_bundle!(recipe::BundleRecipe)
    image_recipe = recipe.link_recipe.image_recipe
    inputs_path = image_recipe.link_inputs_path
    (inputs_path === nothing || !isfile(inputs_path)) && return
    inputs = TOML.parsefile(inputs_path)
    libs = [lib for lib in get(inputs, "libraries", Any[])
            if get(lib, "linkage", "") == "dynamic"]
    isempty(libs) && return
    # The directories the executable's bundle rpath covers.
    roots = [joinpath(recipe.output_dir, recipe.libdir),
             joinpath(recipe.output_dir, recipe.libdir, "julia")]
    findlib(soname) = findfirst(r -> isfile(joinpath(r, soname)), roots)
    missing_libs = String[]
    bundled = Tuple{String,String}[]  # (soname, path in bundle)
    for lib in libs
        soname = String(lib["dlname"])
        idx = findlib(soname)
        if idx === nothing
            push!(missing_libs, "$(lib["package"]).$(lib["product"]) ($soname)")
        else
            push!(bundled, (soname, joinpath(roots[idx], soname)))
        end
    end
    isempty(missing_libs) ||
        error("--link-native: bundle is missing natively-linked dynamic libraries " *
              "required by the loader at process start: " * join(missing_libs, ", "))
    # Per-object closure (ELF): each natively-linked library's own DT_NEEDED
    # entries must resolve within the bundle or be system libraries.
    if Sys.islinux()
        unresolved = String[]
        for (soname, path) in bundled
            for needed in split(read(`$(Patchelf_jll.patchelf()) --print-needed $(path)`, String))
                needed = String(needed)
                findlib(needed) === nothing || continue
                any(p -> startswith(needed, p), _SYSTEM_SONAME_PREFIXES) && continue
                push!(unresolved, "$soname -> $needed")
            end
        end
        isempty(unresolved) ||
            error("--link-native: natively-linked libraries have dependencies that " *
                  "resolve neither in the bundle nor as system libraries: " *
                  join(unresolved, ", "))
    end
    return
end

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

    # Create julia subdirectory for bundled libraries under lib/ (or bin/ on Windows).
    image_recipe = recipe.link_recipe.image_recipe
    quiet = image_recipe.quiet

    # Bundle from the temporary project, where we compiled from
    @assert !isempty(image_recipe.instantiated_project) "project was not copied / instantiated"
    ctx2 = PackageCompiler.create_pkg_context(image_recipe.instantiated_project)
    stdlibs = unique(vcat(PackageCompiler.gather_stdlibs_project(ctx2),
                          intersect(PackageCompiler._STDLIBS, map(x->x.name, Base._sysimage_modules))))
    libs_info = PackageCompiler.bundle_julia_libraries(recipe.output_dir, stdlibs; quiet)
    _filter_statically_linked!(recipe.output_dir, image_recipe)
    artifacts_info = PackageCompiler.bundle_artifacts(ctx2, recipe.output_dir;
            include_lazy_artifacts=recipe.bundle_lazy_artifacts, quiet) # Lazy artifacts
    PackageCompiler.bundle_cert(recipe.output_dir) # SSL certificates

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

    # Natively-linked dynamic libraries sourced from artifacts must live on
    # the executable's rpath like the stdlib libraries do.
    _bundle_native_artifact_libs!(recipe)

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

    # The bundle must satisfy what the link line promised; check now that
    # every mutation (filters, privatization, removals) has run.
    _verify_native_link_bundle!(recipe)

    # Print the bundle size tables now that codegen libraries have been pruned
    # and any privatization applied, so the sizes reflect the final bundle.
    quiet || PackageCompiler.print_bundle_info(libs_info, artifacts_info)

    # Don't leak a value here: `@main` treats a returned `Bool` (`Bool <: Integer`)
    # as a process exit code, so `quiet || ...` returning `true` would exit 1.
    return nothing
end

function remove_unnecessary_libraries(recipe::BundleRecipe)
    bundle_root = recipe.output_dir
    julia_dir = joinpath(bundle_root, recipe.libdir)
    !isdir(julia_dir) && return
    # If trim is enable remove codegen
    if is_trim_enabled(recipe.link_recipe.image_recipe)
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



