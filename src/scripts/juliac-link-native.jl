# This file is a part of JuliaC. License is MIT: https://julialang.org/license
#
# Resolution pass for `--link-native`: turn package-level specs
# (`Pkg_jll` or `Pkg_jll.product`) into a concrete set of libraries by
# consuming each package's `JLL.toml` record, register every resolved
# library's identity with the runtime's native-link policy table, and write
# a link-inputs manifest for the driver's link step.
#
# The record format (`format_version = "1.0"`) is the one BinaryBuilder2
# generates: each build carries an `artifact` table that either binds an
# artifact (`treehash`) or names a Julia-bundled location (`bundled_path`),
# and each library product entry states its `linkage` ("dynamic" or
# "static"); static entries add `path`, `deps`, `system_deps` and `roots`.
# Records predating those fields are read with defaults where possible.
#
# A library's identity is not read from the record: it is the `LibraryID`
# the package's wrapper declares, `LibraryID(<package UUID>, "<product>")`,
# which this pass reconstructs from the same two coordinates and registers
# with `jl_set_foreign_link_policy`.
#
# This runs before any user code (and therefore before any ccall lowering),
# in the target process, so record resolution sees the target project's
# load path. Records are consumed as data; the JLL modules themselves are
# not loaded here. The driver includes this file too, for the record helpers
# (`select_build`, `build_library_entries`, `build_artifact_hash`) its bundle
# step uses to prune artifacts.

module JuliaCLinkNative

using Base.BinaryPlatforms: AbstractPlatform, HostPlatform, Platform, select_platform, arch
import Artifacts

struct ResolvedLibrary
    spec::String        # the request that pulled this in (or "<dep of X>")
    package::String
    product::String
    package_uuid::String # the package's UUID (lowercase text); with `product`, its `LibraryID`
    dlname::String      # the dynamic library's soname (identification / bundle filtering)
    # Absolute path of the file to link, or `nothing` for a library whose
    # sites are bound natively but whose symbols are satisfied by other link
    # inputs (e.g. libblastrampoline under --link-native-blas).
    path::Union{String, Nothing}
    linkage::String     # "static" or "dynamic"
    location::String    # "bundled" or "artifact" (where the library file lives)
    system_deps::Vector{String}
    # For an entry with no linkage: the "Package.product" that satisfies its
    # symbols instead (see `--link-native-blas`).
    replaced_with::Union{String, Nothing}
    # A static archive to be linked whole: the Julia runtime, which Julia code
    # reaches by symbol name through `dlsym` on the executable, so that no
    # object of it may be discarded.
    whole_archive::Bool
end
ResolvedLibrary(spec, package, product, package_uuid, dlname, path, linkage, location, system_deps,
                replaced_with = nothing; whole_archive::Bool = false) =
    ResolvedLibrary(spec, package, product, package_uuid, dlname, path, linkage, location,
                    system_deps, replaced_with, whole_archive)

# The identity the package's wrapper declares for this library.
library_identity(lib::ResolvedLibrary) =
    Base.Libc.Libdl.LibraryID(Base.UUID(lib.package_uuid), lib.product)

# Locate a package's source directory without loading the package.
function locate_pkgid(pkgname::AbstractString)
    pkgid = Base.identify_package(String(pkgname))
    pkgid === nothing &&
        error("--link-native: package $pkgname not found in the project's dependencies")
    return pkgid
end

function locate_pkgdir(pkgname::AbstractString)
    pkgid = locate_pkgid(pkgname)
    entry = Base.locate_package(pkgid)
    entry === nothing &&
        error("--link-native: package $pkgname could not be located (is the project instantiated?)")
    return dirname(dirname(entry))
end

function load_record(pkgname::AbstractString, record_cache::Dict{String,Any})
    get!(record_cache, String(pkgname)) do
        pkgdir = locate_pkgdir(pkgname)
        record_path = joinpath(pkgdir, "JLL.toml")
        isfile(record_path) ||
            error("--link-native: $pkgname has no JLL.toml record; " *
                  "only packages that ship one can be natively linked")
        record = Base.parsed_toml(record_path)
        # An absent `format_version` is a record written before the format was
        # versioned; it is read with defaults rather than refused.
        fmt = get(record, "format_version", nothing)
        if fmt !== nothing
            ver = fmt isa AbstractString ? tryparse(VersionNumber, fmt) : nothing
            ver isa VersionNumber && ver.major == 1 ||
                error("--link-native: $record_path has unsupported format_version $(repr(fmt))")
        end
        haskey(record, "builds") ||
            error("--link-native: $record_path declares no builds")
        return record
    end
end

# Library product entries of a build, as (name, linkage, entry). A record
# written before the format was versioned carries neither `type` nor
# `linkage`, so both default: products are libraries and libraries are
# dynamic.
function build_library_entries(build)
    entries = Tuple{String,String,Any}[]
    for p in get(build, "products", Any[])
        p isa Dict || continue
        get(p, "type", "library") == "library" || continue
        name = get(p, "name", nothing)
        name isa String || continue
        push!(entries, (name, String(get(p, "linkage", "dynamic")), p))
    end
    return entries
end

# The UUID of a package, as lowercase text: with a product name it is the
# `LibraryID(uuid, name)` the package's wrapper declares.
function package_uuid(pkgname::AbstractString)
    pkgid = locate_pkgid(pkgname)
    pkgid.uuid === nothing &&
        error("--link-native: package $pkgname has no UUID, so its libraries have no identity")
    return lowercase(string(pkgid.uuid))
end

# Where a build's product paths resolve: "artifact" when the build's
# `artifact` table binds one (`treehash`), "bundled" when it names a location
# inside the Julia installation (`bundled_path`). Records written before the
# `artifact` table existed carried a `location` key instead.
function build_location(b)
    binding = get(b, "artifact", nothing)
    if binding isa Dict
        haskey(binding, "bundled_path") && return "bundled"
        haskey(binding, "treehash") && return "artifact"
    end
    return String(get(b, "location", build_artifact_hash(b) === nothing ? "bundled" : "artifact"))
end

# For a bundled build, which directory of the Julia installation its product
# paths are relative to.
function build_bundled_path(b)
    binding = get(b, "artifact", nothing)
    binding isa Dict || return "private_shlibdir"
    return String(get(binding, "bundled_path", "private_shlibdir"))
end

# Keys of a [[builds]] block that are data rather than platform-selector
# tags in the hand-written (tag-key) form.
const BUILD_DATA_KEYS = ("location", "platform", "platforms", "name", "src_version", "lazy")

# The SHA1 tree hash of a build's artifact binding, or `nothing`.
function build_artifact_hash(b)
    binding = get(b, "artifact", nothing)
    binding isa Dict || return nothing
    th = get(binding, "treehash", nothing)
    th isa String || return nothing
    return Base.SHA1(chopprefix(th, "sha1:"))
end

# Select the [[builds]] block describing this host's libraries.
#
# Artifact-located builds resolve by *identity*: the installed artifact
# decides which build describes what is on disk — the platform-augmentation
# hooks already ran when that artifact was chosen, so no platform matching
# is repeated here. Bundled builds (and disambiguation between several
# installed artifacts) match by platform: a generated build carries a
# concrete `platform` triplet; a hand-written build carries either a
# `platforms` triplet list (identical build for several platforms) or
# Artifacts.toml-style tag keys (`os`, `arch`, ...), where String-valued
# keys are platform tags, most specific match wins, and a build with no
# selector at all is a wildcard fallback.
function select_build(record::Dict{String,Any}, host::AbstractPlatform)
    installed = Any[]
    for b in record["builds"]
        build_location(b) == "artifact" || continue
        hash = build_artifact_hash(b)
        hash === nothing && continue
        Artifacts.artifact_exists(hash) && push!(installed, b)
    end
    length(installed) == 1 && return installed[1]
    if length(installed) > 1
        dict = Dict{Platform,Any}()
        for b in installed
            haskey(b, "platform") && (dict[parse(Platform, b["platform"]::String)] = b)
        end
        b = select_platform(dict, host)
        b !== nothing && return b
    end
    dict = Dict{Platform,Any}()
    wildcard = nothing
    for b in record["builds"]
        if haskey(b, "platform")
            dict[parse(Platform, b["platform"]::String)] = b
        elseif haskey(b, "platforms")
            for t in b["platforms"]
                dict[parse(Platform, t::String)] = b
            end
        elseif haskey(b, "os")
            tags = Dict{Symbol,String}()
            for (k, val) in b
                (val isa String && !(k in BUILD_DATA_KEYS) && k != "os" && k != "arch") || continue
                tags[Symbol(k)] = val
            end
            p = Platform(get(b, "arch", arch(host)), b["os"]; tags...)
            dict[p] = b
        else
            for (k, val) in b
                (val isa String && !(k in BUILD_DATA_KEYS)) &&
                    error("--link-native: record build has selector `$k` but no `os` key")
            end
            wildcard === nothing ||
                error("--link-native: record declares multiple selector-less builds")
            wildcard = b
        end
    end
    build = select_platform(dict, host)
    return build === nothing ? wildcard : build
end

# The private shared-library directory of this Julia installation
# (`bundled_path = "private_shlibdir"`).
function bundled_shlibdir()
    libname = ifelse(Base.isdebugbuild(), "libjulia-internal-debug", "libjulia-internal")
    return dirname(Base.Libc.Libdl.dlpath(libname))
end

function resolve_library(spec::String, pkgname::String, prodname::String,
                         record::Dict{String,Any}, host::AbstractPlatform;
                         static::Union{Bool, Symbol} = false)
    build = select_build(record, host)
    build === nothing &&
        error("--link-native: $pkgname's record has no build for this platform")
    location = build_location(build)
    location in ("bundled", "artifact") ||
        error("--link-native: $pkgname's record build has unsupported location $(repr(location))")
    if location == "artifact"
        hash = build_artifact_hash(build)
        hash === nothing &&
            error("--link-native: $pkgname's artifact-located build has no artifact binding")
        Artifacts.artifact_exists(hash) ||
            error("--link-native: $pkgname's artifact $(hash) is not installed " *
                  "(is the project instantiated?)")
        base = Artifacts.artifact_path(hash)
    else
        # Bundled: paths resolve against the named directory of the Julia
        # installation that owns the record.
        bundled_path = build_bundled_path(build)
        base = bundled_path == "private_shlibdir" ? bundled_shlibdir() :
               bundled_path == "private_libdir" ? dirname(Base.Libc.Libdl.dlpath("libjulia")) :
               bundled_path == "private_bindir" ? Sys.BINDIR :
               error("--link-native: $pkgname's record build names unsupported bundled_path $(repr(bundled_path))")
    end

    # A product may appear once per linkage; identity is shared between them.
    dynentry = nothing
    stentry = nothing
    for (name, linkage, entry) in build_library_entries(build)
        name == prodname || continue
        if linkage == "static"
            stentry = entry
        elseif linkage == "dynamic"
            dynentry = entry
        else
            error("--link-native: $pkgname.$prodname declares unsupported " *
                  "linkage $(repr(linkage))")
        end
    end
    (dynentry === nothing && stentry === nothing) &&
        error("--link-native: $pkgname.$prodname is not available for this platform")
    uuid = package_uuid(pkgname)

    # `:auto` (from `static:all`): the archive when the record declares one
    # for this platform and it is installed, the shared library otherwise.
    if static === :auto
        relpath = stentry === nothing ? nothing : get(stentry, "path", nothing)
        static = relpath isa String && isfile(joinpath(base, relpath))
    end
    if static
        # Static linkage: link the archive declared by the entry. Its
        # dependency edges and system-library closure come from the record,
        # because archives carry no DT_NEEDED equivalent.
        stentry === nothing &&
            error("--link-native: $pkgname.$prodname has no static library for this platform")
        relpath = get(stentry, "path", nothing)
        relpath isa String ||
            error("--link-native: $pkgname.$prodname's static entry declares no path")
        path = joinpath(base, relpath)
        isfile(path) ||
            error("--link-native: $pkgname.$prodname's static archive $path does not exist")
        deps = Vector{String}(get(stentry, "deps", String[]))
        system_deps = Vector{String}(get(stentry, "system_deps", String[]))
        # The dynamic library's soname still names the shipped shared file
        # (bundle filtering, shim configuration); a static-only product has
        # none, so fall back to the archive name.
        dlname = dynentry === nothing ? basename(relpath) :
            something(get(dynentry, "soname", nothing), basename(relpath))
        lib = ResolvedLibrary(spec, pkgname, prodname, uuid, dlname, path,
                              "static", location, system_deps)
        return lib, deps
    else
        if dynentry === nothing
            error("--link-native: $pkgname.$prodname has only a static library " *
                  "for this platform; request it as `static:$pkgname.$prodname`")
        end
        soname = get(dynentry, "soname", nothing)
        soname isa String ||
            error("--link-native: $pkgname.$prodname's dynamic entry declares no soname")
        # The locator defaults to the soname: the file so named in the
        # private shlibdir of the installation that owns the record (the
        # same file the package's lazy loading path opens).
        path = joinpath(base, get(dynentry, "path", soname))
        isfile(path) ||
            error("--link-native: $pkgname.$prodname resolved to $path, which does not exist")
        lib = ResolvedLibrary(spec, pkgname, prodname, uuid, soname, path,
                              "dynamic", location, String[])
        return lib, Vector{String}(get(dynentry, "deps", String[]))
    end
end

# Every package of the target environment that ships a `JLL.toml` record:
# the packages of the active project's manifest, and the bundled stdlib
# JLLs (a manifest package shadows a stdlib of the same UUID, as for
# loading). This is what `--link-native static:all` expands to.
function environment_record_packages()
    names = String[]
    seen_uuids = Set{Base.UUID}()
    project = Base.active_project()
    manifest = project === nothing ? nothing : Base.project_file_manifest_path(project)
    if manifest !== nothing && isfile(manifest)
        for (name, entries) in Base.get_deps(Base.parsed_toml(manifest))
            for entry in entries
                uuid = get(entry, "uuid", nothing)
                uuid isa String || continue
                pkgid = Base.PkgId(Base.UUID(uuid), String(name))
                src = Base.locate_package(pkgid)
                src === nothing && continue
                isfile(joinpath(dirname(dirname(src)), "JLL.toml")) || continue
                push!(seen_uuids, pkgid.uuid)
                push!(names, String(name))
            end
        end
    end
    for name in readdir(Sys.STDLIB)
        dir = joinpath(Sys.STDLIB, name)
        isfile(joinpath(dir, "JLL.toml")) || continue
        uuid = get(Base.parsed_toml(joinpath(dir, "Project.toml")), "uuid", nothing)
        uuid isa String || continue
        Base.UUID(uuid) in seen_uuids && continue
        push!(names, name)
    end
    return sort!(unique!(names))
end

# The package whose call sites `--link-native-blas` redirects: every
# libblastrampoline site is bound natively, and its symbols are satisfied by
# the provider's library plus JuliaC's LBT control-API shim.
const BLAS_TRAMPOLINE_PACKAGE = "libblastrampoline_jll"

"""
Resolve `--link-native` specs to concrete libraries, close over their record
dependency edges, register every identity with the runtime policy table, and
write the link-inputs manifest to `link_inputs_path`.

With `blas_provider` set (`--link-native-blas`), additionally register
libblastrampoline's identities — without linking libblastrampoline itself — and
resolve the provider (and its closure) as ordinary native link inputs.
"""
function resolve_and_register!(specs::Vector{String}, link_inputs_path::String;
                               blas_provider::Union{String, Nothing} = nothing,
                               static_runtime::Bool = false)
    # Runtime support check up front, so the failure mode is a clear error
    # rather than a missing-symbol crash at registration time.
    let handle = Base.Libc.Libdl.dlopen("libjulia-internal"; throw_error=false)
        if handle === nothing || !isdefined(Base.Libc.Libdl, :LibraryID) ||
                Base.Libc.Libdl.dlsym(handle, :jl_set_foreign_link_policy; throw_error=false) === nothing
            error("--link-native requires a Julia runtime with a foreign link policy " *
                  "keyed on `LibraryID`; this Julia ($(VERSION)) does not provide it.")
        end
    end

    host = HostPlatform()
    record_cache = Dict{String,Any}()
    resolved = ResolvedLibrary[]
    seen = Set{Tuple{String,String}}()  # (package, product)
    # (spec, package, product, static); empty product = every product;
    # static may be :auto (see `all`)
    queue = Tuple{String,String,String,Union{Bool,Symbol}}[]
    dep_mode = nothing # provisioning of dependency edges; set once `all` is known
    # every dependency edge seen, dependency => owners ("Pkg.product" keys),
    # recorded whether or not the dependency was already resolved
    needed_by = Dict{String,Vector{String}}()

    # A spec may carry a linkage-mode prefix: `static:` selects the record's
    # static library for the named products (their dependency edges are
    # provisioned dynamically unless themselves requested static).
    function parse_mode(spec::AbstractString)
        static = startswith(spec, "static:")
        bare = static ? chopprefix(spec, "static:") : spec
        return String(bare), static
    end

    # Expanding a whole-package spec means every product of the build
    # selected for this platform (the identity table may list products a
    # given platform does not ship).
    function platform_products(record)
        build = select_build(record, host)
        build === nothing && return String[]
        return unique(name for (name, _, _) in build_library_entries(build))
    end

    substituted = ResolvedLibrary[]
    provider_bare = nothing
    if blas_provider !== nothing
        # Register the trampoline's identities so its call sites are bound
        # natively, but do not link it: its computational symbols resolve
        # directly into the provider, and its control API into the shim.
        record = load_record(BLAS_TRAMPOLINE_PACKAGE, record_cache)
        for prodname in platform_products(record)
            lib, _ = resolve_library("<blas trampoline>", BLAS_TRAMPOLINE_PACKAGE,
                                     String(prodname), record, host)
            push!(substituted, ResolvedLibrary(lib.spec, lib.package, lib.product,
                                               lib.package_uuid, lib.dlname, nothing,
                                               "none", lib.location, String[]))
            push!(seen, (BLAS_TRAMPOLINE_PACKAGE, String(prodname)))
        end
        # The provider is an ordinary native-link request (with its closure).
        bare, static = parse_mode(blas_provider)
        provider_bare = bare
        parts = split(bare, '.')
        push!(queue, (bare, String(parts[1]),
                      length(parts) == 2 ? String(parts[2]) : "", static))
    end

    # `all` (`static:all` or `dynamic:all`): every product of every package
    # with a record, after the explicit specs so those take precedence for
    # the products they name. Static means "where an archive exists".
    all_mode = nothing
    for spec in specs
        bare, static = parse_mode(spec)
        if bare == "all"
            all_mode = static ? :auto : false
            continue
        end
        parts = split(bare, '.')
        length(parts) <= 2 ||
            error("--link-native: malformed spec `$spec` (expected `Pkg_jll` or `Pkg_jll.product`)")
        push!(queue, (bare, String(parts[1]),
                      length(parts) == 2 ? String(parts[2]) : "", static))
    end
    if all_mode !== nothing
        for pkgname in environment_record_packages()
            pkgname == BLAS_TRAMPOLINE_PACKAGE && blas_provider !== nothing && continue
            push!(queue, ("all", pkgname, "", all_mode))
        end
    end

    function enqueue_deps!(owner::String, pkgname::String, deps)
        mode = dep_mode === nothing ? false : dep_mode
        for dep in deps
            depparts = split(dep, '.')
            if length(depparts) == 1
                deppkg, depprod = pkgname, String(depparts[1])
            elseif length(depparts) == 2
                deppkg, depprod = String(depparts[1]), String(depparts[2])
            else
                error("--link-native: malformed dep edge `$dep` in $pkgname's record")
            end
            push!(get!(Vector{String}, needed_by, deppkg * "." * depprod), owner)
            push!(queue, ("<dep of $owner>", deppkg, depprod, mode))
        end
    end
    function drain!()
        while !isempty(queue)
            (spec, pkgname, prodname, static) = popfirst!(queue)
            record = load_record(pkgname, record_cache)
            if isempty(prodname)
                # expand to every product of the package
                for pn in platform_products(record)
                    push!(queue, (spec, pkgname, pn, static))
                end
                continue
            end
            (pkgname, prodname) in seen && continue
            push!(seen, (pkgname, prodname))
            lib, deps = resolve_library(spec, pkgname, prodname, record, host; static)
            push!(resolved, lib)
            # Provision closure: everything a natively-provided library depends on
            # must itself be natively provided (its dlopen never runs). Dependency
            # edges provision dynamically; staticness is chosen per requested node.
            enqueue_deps!("$pkgname.$prodname", pkgname, deps)
        end
    end
    dep_mode = all_mode
    drain!()

    # The Julia runtime itself (`--link-runtime=static`): the archive the
    # build installed next to libjulia, described by the record beside it.
    # It is linked whole, and its dependency edges are provisioned like any
    # other library's, after the requested specs so that a `static:` request
    # for one of them takes precedence over the default dynamic provision.
    if static_runtime
        libdir = dirname(Base.Libc.Libdl.dlpath("libjulia"))
        record_path = joinpath(libdir, "libjulia-internal.toml")
        isfile(record_path) ||
            error("--link-runtime=static: $(record_path) not found; this Julia was built " *
                  "without the static runtime archive (`make -C src <libdir>/libjulia-internal.a`)")
        record = Base.parsed_toml(record_path)
        build = select_build(record, host)
        build === nothing &&
            error("--link-runtime=static: the runtime record has no build for this platform")
        entry = nothing
        for (name, linkage, p) in build_library_entries(build)
            (name == "libjulia-internal" && linkage == "static") && (entry = p)
        end
        entry === nothing &&
            error("--link-runtime=static: the runtime record declares no static libjulia-internal")
        path = joinpath(libdir, String(entry["path"]))
        isfile(path) ||
            error("--link-runtime=static: $(path) does not exist")
        soext = Base.BinaryPlatforms.platform_dlext()
        dlname = "libjulia-internal.$(soext).$(VERSION.major).$(VERSION.minor)"
        push!(resolved, ResolvedLibrary("<runtime>", "julia", "libjulia-internal", "", dlname,
                                        path, "static", "bundled",
                                        Vector{String}(get(entry, "system_deps", String[]));
                                        whole_archive = true))
        enqueue_deps!("julia.libjulia-internal", "julia", get(entry, "deps", String[]))
        drain!()
    end

    # A substituted library links nothing of its own; name what satisfies
    # its symbols instead, so the link and bundle steps can follow the
    # replacement without knowing why it happened.
    if provider_bare !== nothing && !isempty(substituted)
        idx = findfirst(l -> l.spec == provider_bare, resolved)
        if idx !== nothing
            target = resolved[idx].package * "." * resolved[idx].product
            for (i, lib) in pairs(substituted)
                substituted[i] = ResolvedLibrary(lib.spec, lib.package, lib.product,
                                                 lib.package_uuid, lib.dlname, lib.path,
                                                 lib.linkage, lib.location,
                                                 lib.system_deps, target)
            end
        end
    end
    append!(resolved, substituted)
    for lib in resolved
        isempty(lib.package_uuid) && continue # the runtime archive: no identity of its own
        ccall(:jl_set_foreign_link_policy, Cvoid, (Any, Cint), library_identity(lib), true)
    end

    # TOML link-inputs manifest for the driver's link step. Values are
    # emitted as TOML basic strings; escape the two characters that require
    # it in the data we carry (paths may contain backslashes on Windows).
    esc(s) = replace(s, '\\' => "\\\\", '"' => "\\\"")
    open(link_inputs_path, "w") do io
        println(io, "# Written by juliac's --link-native resolution pass; consumed by its link step.")
        for lib in resolved
            println(io, "[[libraries]]")
            println(io, "spec = \"", esc(lib.spec), "\"")
            println(io, "package = \"", esc(lib.package), "\"")
            println(io, "product = \"", esc(lib.product), "\"")
            println(io, "package_uuid = \"", esc(lib.package_uuid), "\"")
            println(io, "dlname = \"", esc(lib.dlname), "\"")
            println(io, "linkage = \"", esc(lib.linkage), "\"")
            println(io, "location = \"", esc(lib.location), "\"")
            if lib.replaced_with !== nothing
                println(io, "replaced_with = \"", esc(lib.replaced_with), "\"")
            end
            lib.whole_archive && println(io, "whole_archive = true")
            owners = get(needed_by, lib.package * "." * lib.product, nothing)
            if owners !== nothing
                println(io, "needed_by = [", join(("\"" * esc(o) * "\"" for o in unique(owners)), ", "), "]")
            end
            if lib.path !== nothing
                println(io, "path = \"", esc(lib.path), "\"")
            end
            if !isempty(lib.system_deps)
                println(io, "system_deps = [", join(("\"" * esc(d) * "\"" for d in lib.system_deps), ", "), "]")
            end
            println(io)
        end
    end
    return length(resolved)
end

end # module JuliaCLinkNative
