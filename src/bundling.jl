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
        get(lib, "linkage", "") in ("static", "none") || continue
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
    by_spec = Dict{String,Any}(String(l["package"]) * "." * String(l["product"]) => l
                               for l in libs)
    # Sonames a consumer may still reference, and what to do about each: a
    # library that linked nothing names its replacement, and the rewrite
    # follows that; one consumed as an archive has no shared form to point at.
    replacement = Dict{String,Any}()
    unreplaced = Set{String}()
    for l in libs
        get(l, "linkage", "") == "none" || continue
        target = get(l, "replaced_with", nothing)
        r = target isa String ? get(by_spec, target, nothing) : nothing
        r === nothing ? push!(unreplaced, String(l["dlname"])) :
                        (replacement[String(l["dlname"])] = r)
    end
    consumed_static = Set{String}(String(l["dlname"]) for l in libs
                                  if get(l, "linkage", "") == "static")
    (isempty(replacement) && isempty(unreplaced) && isempty(consumed_static)) && return
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
                if haskey(replacement, n)
                    target = replacement[n]
                    get(target, "linkage", "") == "dynamic" ||
                        error("--link-native: bundled $(soname) requires $(n) at load " *
                              "time, which was replaced by $(target["package"]).$(target["product"]); " *
                              "that replacement was linked statically, so there is no " *
                              "shared library to point at (a statically-linked provider " *
                              "with dynamically-linked native consumers is not yet supported)")
                    run(`$(Patchelf_jll.patchelf()) --replace-needed $(n) $(String(target["dlname"])) $(path)`)
                elseif n in unreplaced
                    error("--link-native: bundled $(soname) requires $(n) at load time, " *
                          "but nothing was linked in its place")
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
                          if get(l, "linkage", "") in ("static", "none"))
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

# A JLL package of the compiled project together with its `JLL.toml` record
# and the record's build for this host (`nothing` when the record has none).
struct JLLRecord
    uuid::String          # lowercase, as it appears in identity keys
    name::String
    record::Dict{String, Any}
    build::Union{Dict{String, Any}, Nothing}
end

# Every package of the compiled project's environment that ships a
# `JLL.toml` record, keyed by lowercase UUID. Stdlib JLLs carry no record in
# this Julia installation and so are absent; identified libraries without a
# record fall back to their declared name below.
function _collect_jll_records(ctx)
    host = Base.BinaryPlatforms.HostPlatform()
    records = Dict{String, JLLRecord}()
    for pkg in PackageCompiler.load_all_deps(ctx)
        pkg.uuid === nothing && continue
        src = PackageCompiler.source_path(ctx, pkg)
        src === nothing && continue
        record_path = joinpath(src, "JLL.toml")
        isfile(record_path) || continue
        record = try
            TOML.parsefile(record_path)
        catch
            continue
        end
        haskey(record, "builds") || continue
        build = try
            JuliaCLinkNative.select_build(record, host)
        catch
            nothing
        end
        uuid = lowercase(string(pkg.uuid))
        records[uuid] = JLLRecord(uuid, String(pkg.name), record, build)
    end
    return records
end

# Split an identity key "<uuid>:<product>" (see `library_identity_key` in the
# resolution pass) into its two coordinates, or `nothing`.
function _split_identity_key(key::AbstractString)
    idx = findfirst(':', key)
    idx === nothing && return nothing
    return lowercase(String(key[1:prevind(key, idx)])), String(key[nextind(key, idx):end])
end

# The library product entries of a record's host build that carry `name`,
# as (linkage, entry).
function _product_entries(rec::JLLRecord, name::AbstractString)
    rec.build === nothing && return Tuple{String, Any}[]
    return [(linkage, p) for (pname, linkage, p) in JuliaCLinkNative.build_library_entries(rec.build)
            if pname == name]
end

# The sonames a foreign-deps manifest group refers to. An identified group
# (`library_id` = "<uuid>:<product>") names a `LazyLibrary` product whose
# file name is not its declared name; the merged-schema record of its
# package states the soname. A group without an identity is a ccall on a
# literal library string, which is the file name (or its stem) itself, and
# that is also the fallback for an identified library whose package ships no
# record.
function _manifest_group_sonames(name::AbstractString, group, records::Dict{String, JLLRecord})
    lid = group isa Dict ? get(group, "library_id", nothing) : nothing
    if lid isa String
        coords = _split_identity_key(lid)
        if coords !== nothing
            rec = get(records, coords[1], nothing)
            if rec !== nothing
                sonames = String[]
                for (linkage, p) in _product_entries(rec, coords[2])
                    linkage == "dynamic" || continue
                    soname = get(p, "soname", nothing)
                    soname isa String && push!(sonames, soname)
                end
                isempty(sonames) || return sonames
            end
        end
    end
    return [String(name)]
end

"""
Remove bundled shared libraries the trimmed image cannot reference. Under
`--trim` the foreign-deps manifest records the image's complete ccall
surface, so the keep set is computable: the runtime's own libraries, every
library the manifest references (by soname or, for `LazyLibrary`s, by
identity resolved through the package's JLL.toml record), every library named in the
link-inputs manifest, and the transitive `DT_NEEDED` closure of all of the
above within the bundle. Everything else is removed, with a log of what was
dropped. ELF-only for now; no-op elsewhere or when the manifest is absent.
"""
function _filter_unreferenced_libraries!(recipe::BundleRecipe, records::Dict{String, JLLRecord})
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
    groups = get(manifest, "libraries", Dict{String, Any}())
    keep_stems = Set{String}(["libjulia", "libjulia-internal", "libjulia-codegen", "sys"])
    for (name, group) in pairs(groups)
        startswith(name, "<") && continue  # runtime pseudo-libraries
        for soname in _manifest_group_sonames(name, group, records)
            push!(keep_stems, _shlib_stem(soname))
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
    lbt_lazy = any(pairs(groups)) do (name, group)
        sonames = _manifest_group_sonames(name, group, records)
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

# One bundled artifact's pruning decision (see `_artifact_prune_plan`).
struct ArtifactPrune
    hash::String       # the bundled directory name (hex tree hash)
    package::String
    drop::Bool         # remove the whole artifact directory
    # When not dropping: (product, path of its shared library within the
    # artifact) for every statically linked product; the file and its
    # soname/symlink chain are removed.
    remove::Vector{Tuple{String, String}}
end

# Products of artifact-located libraries the link step provided natively,
# per package uuid: statically (linked into the image) and dynamically
# (flattened into the private library directory by
# `_bundle_native_artifact_libs!`).
function _native_artifact_products(inputs)
    static = Dict{String, Set{String}}()
    dynamic = Dict{String, Set{String}}()
    for lib in get(inputs, "libraries", Any[])
        lib isa Dict || continue
        get(lib, "location", "") == "artifact" || continue
        coords = _split_identity_key(String(get(lib, "dlid", "")))
        coords === nothing && continue
        linkage = get(lib, "linkage", "")
        target = linkage == "static" ? static : linkage == "dynamic" ? dynamic : nothing
        target === nothing && continue
        push!(get!(Set{String}, target, coords[1]), coords[2])
    end
    return static, dynamic
end

# (uuid, product) of every identified library the manifest reaches lazily
# (its `LazyLibrary` is dlopened at run time), closed over the dependency
# edges its record declares: a `LazyLibrary` dlopens its dependencies first,
# so those are reached too even without ccall sites of their own.
function _lazy_referenced_products(manifest, records::Dict{String, JLLRecord})
    refs = Set{Tuple{String, String}}()
    manifest === nothing && return refs
    for (_, group) in pairs(get(manifest, "libraries", Dict{String, Any}()))
        group isa Dict || continue
        lid = get(group, "library_id", nothing)
        lid isa String || continue
        any(sym -> sym isa Dict && get(sym, "linkage", "") == "lazy",
            get(group, "symbols", Any[])) || continue
        coords = _split_identity_key(lid)
        coords === nothing || push!(refs, coords)
    end
    byname = Dict{String, String}(rec.name => uuid for (uuid, rec) in records)
    worklist = collect(refs)
    while !isempty(worklist)
        (uuid, prod) = pop!(worklist)
        rec = get(records, uuid, nothing)
        rec === nothing && continue
        for (_, p) in _product_entries(rec, prod), dep in get(p, "deps", Any[])
            dep isa String || continue
            parts = split(dep, '.')
            dep_uuid = length(parts) == 1 ? uuid :
                       length(parts) == 2 ? get(byname, String(parts[1]), nothing) : nothing
            dep_uuid === nothing && continue
            edge = (String(dep_uuid), String(parts[end]))
            edge in refs && continue
            push!(refs, edge)
            push!(worklist, edge)
        end
    end
    return refs
end

"""
Decide, for every bundled artifact of a JLL with a record, what the bundle
may omit. A statically linked product's shared library is never loaded (the
image carries its code), so it is removed whatever else the artifact holds.
The whole artifact is dropped only when the image can reach nothing in it:
`manifest` (the foreign-deps manifest, passed only under `--trim`, where it is
the image's complete ccall surface) names no product of it lazily, no product
of it was flattened into the private library directory as a natively-linked
dynamic library, and the build declares no non-library products (file and
executable products are reached through paths the manifest cannot see). The
decision is a per-artifact referenced-ness check; `--link-native` on its own
(without `--trim`) only removes the statically linked shared libraries.
"""
function _artifact_prune_plan(records::Dict{String, JLLRecord}, inputs, manifest)
    static, dynamic = _native_artifact_products(inputs)
    lazy = _lazy_referenced_products(manifest, records)
    plan = ArtifactPrune[]
    for (uuid, rec) in records
        rec.build === nothing && continue
        hash = JuliaCLinkNative.build_artifact_hash(rec.build)
        hash === nothing && continue  # a bundled build ships no artifact
        entries = JuliaCLinkNative.build_library_entries(rec.build)
        libs = unique(String[name for (name, _, _) in entries])
        has_other_products = any(get(rec.build, "products", Any[])) do p
            p isa Dict && get(p, "type", "library") != "library"
        end
        s = get(static, uuid, Set{String}())
        d = get(dynamic, uuid, Set{String}())
        reached = any(l -> l in d || (uuid, l) in lazy, libs)
        drop = manifest !== nothing && !has_other_products && !reached
        remove = Tuple{String, String}[]
        if !drop
            for (name, linkage, p) in entries
                (name in s && linkage == "dynamic") || continue
                path = get(p, "path", nothing)
                path isa String && push!(remove, (name, path))
            end
        end
        (drop || !isempty(remove)) &&
            push!(plan, ArtifactPrune(bytes2hex(hash.bytes), rec.name, drop, remove))
    end
    return sort!(plan; by = a -> a.hash)
end

# Whether `f` is the shared library with stem `stem`, or one of its versioned
# names or symlinks (`libfoo.so`, `libfoo.so.3`, `libfoo.so.3.7.11`,
# `libfoo.3.dylib`, `libfoo-3.dll`), and not a different library sharing the
# prefix (`libfoof.so`) nor the static archive (`libfoo.a`).
function _is_shlib_named(stem::AbstractString, f::AbstractString)
    quoted = replace(stem, r"([\\.^$|?*+()\[\]{}])" => s"\\\1")
    return occursin(Regex("^" * quoted * raw"((\.\d+)*\.(so|dylib)(\.\d+)*|(-\d+)?\.dll)$"), f)
end

function _apply_artifact_prune!(output_dir::String, plan::Vector{ArtifactPrune}; quiet::Bool = false)
    artifacts_dir = joinpath(output_dir, "share", "julia", "artifacts")
    dropped = String[]
    removed = String[]
    for a in plan
        dir = joinpath(artifacts_dir, a.hash)
        isdir(dir) || continue
        if a.drop
            rm(dir; recursive = true, force = true)
            push!(dropped, "$(a.hash) ($(a.package))")
            continue
        end
        for (product, relpath) in a.remove
            libdir = joinpath(dir, dirname(relpath))
            isdir(libdir) || continue
            stem = _shlib_stem(basename(relpath))
            for f in readdir(libdir)
                _is_shlib_named(stem, f) || continue
                rm(joinpath(libdir, f); force = true)
                push!(removed, "$(a.package).$(product): $(joinpath(dirname(relpath), f))")
            end
        end
    end
    if !quiet
        if !isempty(dropped)
            println("Pruned $(length(dropped)) bundled artifacts the image cannot reach:")
            foreach(d -> println("  - ", d), dropped)
        end
        if !isempty(removed)
            println("Pruned $(length(removed)) shared libraries of statically linked products from bundled artifacts:")
            foreach(r -> println("  - ", r), removed)
        end
    end
    return dropped, removed
end

# Apply `_artifact_prune_plan` to the bundle. The link-inputs manifest
# supplies the natively-provided products; the foreign-deps manifest is
# consulted only under `--trim`, where it is complete.
function _prune_bundled_artifacts!(recipe::BundleRecipe, records::Dict{String, JLLRecord})
    image_recipe = recipe.link_recipe.image_recipe
    inputs_path = image_recipe.link_inputs_path
    inputs = inputs_path !== nothing && isfile(inputs_path) ? TOML.parsefile(inputs_path) :
             Dict{String, Any}()
    manifest_path = image_recipe.export_foreign_deps
    manifest = is_trim_enabled(image_recipe) && manifest_path !== nothing && isfile(manifest_path) ?
               JSON_parsefile(manifest_path) : nothing
    plan = _artifact_prune_plan(records, inputs, manifest)
    isempty(plan) && return
    _apply_artifact_prune!(recipe.output_dir, plan; quiet = image_recipe.quiet)
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
    records = _collect_jll_records(ctx2)
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
    _filter_unreferenced_libraries!(recipe, records)

    # Bundled artifacts of JLLs: drop the shared libraries of statically
    # linked products and, under --trim, whole artifacts the image cannot
    # reach.
    _prune_bundled_artifacts!(recipe, records)

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



