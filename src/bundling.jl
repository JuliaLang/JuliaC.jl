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

# Natively-linked dynamic libraries can carry DT_NEEDED entries naming
# libraries this build substituted (e.g. SuiteSparse's libraries NEED
# libblastrampoline, whose sites --link-native-blas binds to the provider).
# The provider exports the same symbols the substituted library did, so the
# substitution is completed for native consumers by rewriting their NEEDED
# entries on the bundled copies. A dynamic consumer of a *statically*
# consumed library is an inconsistent linkage strategy and errors instead.
function _patch_native_consumer_needed!(recipe::BundleRecipe)
    Sys.islinux() || return
    image_recipe = recipe.link_recipe.image_recipe
    inputs_path = image_recipe.link_inputs_path
    (inputs_path === nothing || !isfile(inputs_path)) && return
    libs = get(TOML.parsefile(inputs_path), "libraries", Any[])
    substituted = Set{String}(String(l["dlname"]) for l in libs
                              if get(l, "linkage", "") == "substituted")
    consumed_static = Set{String}(String(l["dlname"]) for l in libs
                                  if get(l, "linkage", "") == "static")
    isempty(substituted) && isempty(consumed_static) && return
    provider = nothing
    provider_static = false
    for l in libs
        get(l, "blas_provider", false) === true || continue
        if get(l, "linkage", "") == "dynamic"
            provider = String(l["dlname"])
        else
            provider_static = true
        end
    end
    roots = [joinpath(recipe.output_dir, recipe.libdir),
             joinpath(recipe.output_dir, recipe.libdir, "julia")]
    for l in libs
        get(l, "linkage", "") == "dynamic" || continue
        soname = String(l["dlname"])
        for r in roots
            path = joinpath(r, soname)
            isfile(path) || continue
            needed = split(read(`$(Patchelf_jll.patchelf()) --print-needed $(path)`, String))
            for n in needed
                n = String(n)
                if n in substituted
                    provider === nothing &&
                        error("--link-native: bundled $(soname) requires substituted $(n) " *
                              "at load time" * (provider_static ?
                              "; a statically-linked BLAS provider with dynamically-linked " *
                              "native consumers is not yet supported" : ""))
                    run(`$(Patchelf_jll.patchelf()) --replace-needed $(n) $(provider) $(path)`)
                elseif n in consumed_static
                    error("--link-native: bundled $(soname) requires $(n) at load time, " *
                          "but that library was consumed statically; request " *
                          "`static:` linkage for its dependents as well")
                end
            end
            break
        end
    end
    return
end

# Backstop for lazily-provisioned consumers the surgery above does not
# touch: no shared library remaining in the bundle may reference a soname
# this build removed.
function _verify_no_dangling_needed!(recipe::BundleRecipe)
    Sys.islinux() || return
    image_recipe = recipe.link_recipe.image_recipe
    inputs_path = image_recipe.link_inputs_path
    (inputs_path === nothing || !isfile(inputs_path)) && return
    libs = get(TOML.parsefile(inputs_path), "libraries", Any[])
    removed = Set{String}(String(l["dlname"]) for l in libs
                          if get(l, "linkage", "") in ("static", "substituted"))
    isempty(removed) && return
    dangling = String[]
    for dir in (joinpath(recipe.output_dir, recipe.libdir),
                joinpath(recipe.output_dir, recipe.libdir, "julia"))
        isdir(dir) || continue
        for name in readdir(dir)
            occursin(".so", name) || continue
            path = joinpath(dir, name)
            islink(path) && continue
            needed = try
                split(read(`$(Patchelf_jll.patchelf()) --print-needed $(path)`, String))
            catch
                continue
            end
            for n in needed
                String(n) in removed && push!(dangling, "$name -> $n")
            end
        end
    end
    isempty(dangling) ||
        error("--link-native: bundled libraries still reference removed libraries " *
              "at load time (their linkage strategy is inconsistent with the " *
              "native-link request; consider extending --link-native over them): " *
              join(unique(dangling), ", "))
    return
end

# Strip a shared-library filename to its stem (drop `.so[.N]*`, `.dylib`,
# `.dll` and version decorations).
_shlib_stem(name::String) =
    replace(name, r"\.so(\.\d+)*$|(\.\d+)*\.dylib$|\.dylib$|(-\d+)?\.dll$" => "")

# Map every product dlid declared by this installation's stdlib JLL.toml
# records to the sonames of its dynamic libraries (across all builds; an
# over-approximation is safe — sonames for other platforms simply match no
# bundled file).
function _stdlib_dlid_sonames()
    map = Dict{String, Vector{String}}()
    for stdlib in readdir(Sys.STDLIB; join = true)
        record_path = joinpath(stdlib, "JLL.toml")
        isfile(record_path) || continue
        record = try
            TOML.parsefile(record_path)
        catch
            continue
        end
        products = get(record, "products", nothing)
        products isa Dict || continue
        dlids = Dict{String, String}(String(name) => get(p, "dlid", "")
                                     for (name, p) in products if p isa Dict)
        for build in get(record, "builds", Any[])
            bprods = get(build, "products", nothing)
            bprods isa Dict || continue
            for (name, p) in bprods
                dlid = get(dlids, String(name), "")
                isempty(dlid) && continue
                dyn = get(p, "dynamic", nothing)
                dyn isa Dict || continue
                soname = get(dyn, "soname", nothing)
                soname isa String || continue
                push!(get!(Vector{String}, map, lowercase(dlid)), soname)
            end
        end
    end
    return map
end

"""
Remove bundled shared libraries the trimmed image cannot reference. Under
`--trim` the foreign-deps manifest records the image's complete ccall
surface, so the keep set is computable: the runtime's own libraries, every
library the manifest references (by soname or, for `LazyLibrary`s, by dlid
resolved through the stdlib JLL.toml records), every library named in the
link-inputs manifest, and the transitive `DT_NEEDED` closure of all of the
above within the bundle. Everything else is removed, with a log of what was
dropped. ELF-only for now; no-op elsewhere or when the manifest is absent.
"""
function _filter_unreferenced_libraries!(recipe::BundleRecipe)
    Sys.islinux() || return
    image_recipe = recipe.link_recipe.image_recipe
    is_trim_enabled(image_recipe) || return
    manifest_path = image_recipe.export_foreign_deps
    (manifest_path === nothing || !isfile(manifest_path)) && return

    libdir = joinpath(recipe.output_dir, recipe.libdir)
    isdir(libdir) || return
    julia_dir = joinpath(libdir, "julia")

    # Candidate shared libraries in the bundle (realpath => filenames).
    candidates = Dict{String, Vector{Tuple{String, String}}}()  # realpath => [(dir, name)]
    for dir in (libdir, julia_dir)
        isdir(dir) || continue
        for name in readdir(dir)
            occursin(".so", name) || continue
            path = joinpath(dir, name)
            target = try
                realpath(path)
            catch
                continue
            end
            push!(get!(Vector{Tuple{String, String}}, candidates, target), (dir, name))
        end
    end

    # Referenced stems from the foreign-deps manifest.
    manifest = JSON_parsefile(manifest_path)
    dlid_sonames = _stdlib_dlid_sonames()
    keep_stems = Set{String}(["libjulia", "libjulia-internal", "libjulia-codegen", "sys"])
    for name in keys(get(manifest, "libraries", Dict{String, Any}()))
        startswith(name, "<") && continue  # runtime pseudo-libraries
        for soname in get(dlid_sonames, lowercase(name), [String(name)])
            push!(keep_stems, _shlib_stem(String(soname)))
        end
    end
    # Libraries named by the link step (dynamic natively-linked sonames are
    # loader-critical; static/substituted stems were already removed).
    inputs_path = image_recipe.link_inputs_path
    if inputs_path !== nothing && isfile(inputs_path)
        for lib in get(TOML.parsefile(inputs_path), "libraries", Any[])
            get(lib, "linkage", "") == "dynamic" || continue
            push!(keep_stems, _shlib_stem(String(lib["dlname"])))
        end
    end
    # The julia loader dlopens a baked-in dependency list (DEP_LIBS: a
    # colon-separated string, `@` = libdir-relative) before anything else;
    # neither the manifest nor DT_NEEDED sees it. Extract it from the
    # bundled libjulia.
    for (target, names) in candidates
        any(((_, n),) -> startswith(n, "libjulia.so"), names) || continue
        data = String(read(target))
        for m in eachmatch(r"(?:@?[A-Za-z0-9_.+\-]+\.so[A-Za-z0-9_.]*:)+", data)
            occursin("libjulia-internal", m.match) || continue
            for dep in split(m.match, ':'; keepempty = false)
                push!(keep_stems, _shlib_stem(String(lstrip(dep, '@'))))
            end
        end
        break
    end
    # Known runtime attachment: LinearAlgebra eagerly forwards
    # libblastrampoline to the default BLAS provider at `__init__` via
    # dlopen — an edge with no ccall sites of its own and (deliberately) no
    # record dependency. If LBT is in the image with lazy sites, its
    # provider must ship too. (Under --link-native-blas the LBT sites are
    # native and this correctly does not fire.)
    lbt_lazy = any(pairs(get(manifest, "libraries", Dict{String, Any}()))) do (name, group)
        sonames = get(dlid_sonames, lowercase(String(name)), String[])
        any(s -> _shlib_stem(s) == "libblastrampoline", sonames) || return false
        any(sym -> get(sym, "linkage", "") == "lazy", get(group, "symbols", Any[]))
    end
    if lbt_lazy
        provider_record = joinpath(Sys.STDLIB, "OpenBLAS_jll", "JLL.toml")
        if isfile(provider_record)
            for build in get(TOML.parsefile(provider_record), "builds", Any[])
                for (_, p) in get(build, "products", Dict{String, Any}())
                    dyn = get(p, "dynamic", nothing)
                    dyn isa Dict || continue
                    soname = get(dyn, "soname", nothing)
                    soname isa String && push!(keep_stems, _shlib_stem(soname))
                end
            end
        end
    end

    # Seed the keep set, then close over DT_NEEDED within the bundle.
    kept = Set{String}()  # realpaths
    matches(name) = _shlib_stem(name) in keep_stems
    for (target, names) in candidates
        any(((_, name),) -> matches(name), names) && push!(kept, target)
    end
    exe = recipe.link_recipe.outname
    worklist = collect(kept)
    isfile(exe) && push!(worklist, String(realpath(exe)))
    seen = Set{String}(worklist)
    byname = Dict{String, String}()  # filename => realpath
    for (target, names) in candidates, (_, name) in names
        byname[name] = target
    end
    while !isempty(worklist)
        obj = pop!(worklist)
        needed = try
            split(read(`$(Patchelf_jll.patchelf()) --print-needed $(obj)`, String))
        catch
            continue
        end
        for n in needed
            target = get(byname, String(n), nothing)
            target === nothing && continue
            target in kept && continue
            push!(kept, target)
            target in seen || (push!(worklist, target); push!(seen, target))
        end
    end

    dropped = String[]
    for (target, names) in candidates
        target in kept && continue
        for (dir, name) in names
            rm(joinpath(dir, name); force = true)
        end
        push!(dropped, basename(target))
    end
    if !isempty(dropped) && !image_recipe.quiet
        sort!(dropped)
        println("Pruned $(length(dropped)) bundled libraries the trimmed image cannot reference:")
        for name in dropped
            println("  - ", name)
        end
    end
    return
end

# Minimal JSON reader for the foreign-deps manifest (flat structure of
# objects, arrays, and strings) to avoid a JSON package dependency.
function JSON_parsefile(path::String)
    s = read(path, String)
    pos = Ref(1)
    skipws() = while pos[] <= lastindex(s) && s[pos[]] in (' ', '\t', '\n', '\r'); pos[] += 1; end
    function parse_value()
        skipws()
        c = s[pos[]]
        if c == '{'
            obj = Dict{String, Any}()
            pos[] += 1; skipws()
            if s[pos[]] == '}'; pos[] += 1; return obj; end
            while true
                skipws()
                key = parse_value()::String
                skipws(); @assert s[pos[]] == ':'; pos[] += 1
                obj[key] = parse_value()
                skipws()
                s[pos[]] == ',' ? pos[] += 1 : break
            end
            skipws(); @assert s[pos[]] == '}'; pos[] += 1
            return obj
        elseif c == '['
            arr = Any[]
            pos[] += 1; skipws()
            if s[pos[]] == ']'; pos[] += 1; return arr; end
            while true
                push!(arr, parse_value())
                skipws()
                s[pos[]] == ',' ? pos[] += 1 : break
            end
            skipws(); @assert s[pos[]] == ']'; pos[] += 1
            return arr
        elseif c == '"'
            pos[] += 1
            start = pos[]
            io = IOBuffer()
            while s[pos[]] != '"'
                if s[pos[]] == '\\'
                    pos[] += 1
                    c2 = s[pos[]]
                    write(io, c2 == 'n' ? '\n' : c2 == 't' ? '\t' : c2)
                else
                    write(io, s[pos[]])
                end
                pos[] += 1
            end
            pos[] += 1
            return String(take!(io))
        else
            start = pos[]
            while pos[] <= lastindex(s) && !(s[pos[]] in (',', '}', ']', ' ', '\t', '\n', '\r'))
                pos[] += 1
            end
            tok = s[start:pos[]-1]
            tok == "true" && return true
            tok == "false" && return false
            tok == "null" && return nothing
            return something(tryparse(Int, tok), tryparse(Float64, tok), tok)
        end
    end
    return parse_value()
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

    # Complete the substitution for natively-linked native-code consumers
    # (rewrite their DT_NEEDED entries on the bundled copies).
    _patch_native_consumer_needed!(recipe)

    # Under --trim, drop bundled libraries the image cannot reference (the
    # foreign-deps manifest is its complete ccall surface).
    _filter_unreferenced_libraries!(recipe)

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
    _verify_no_dangling_needed!(recipe)

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



