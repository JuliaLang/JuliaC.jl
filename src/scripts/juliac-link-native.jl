# This file is a part of JuliaC. License is MIT: https://julialang.org/license
#
# Resolution pass for `--link-native`: turn package-level specs
# (`Pkg_jll` or `Pkg_jll.product`) into a concrete set of libraries by
# consuming each package's `JLL.toml` record, register every resolved
# library's dlid with the runtime's native-link policy table, and write a
# link-inputs manifest for the driver's link step.
#
# The record format (jll_format 2.0) is shared with BinaryBuilder2-generated
# JLLs; hand-written stdlib records are partial instances of the same
# schema. Product identity (dlid) lives in a top-level name-keyed
# [products] table; each [[builds]] block completely describes one
# platform's shipped product set, with per-linkage tables (`dynamic`,
# `static`) per product and an explicit `location`.
#
# This runs before any user code (and therefore before any ccall lowering),
# in the target process, so record resolution sees the target project's
# load path. Records are consumed as data; the JLL modules themselves are
# not loaded here.

module JuliaCLinkNative

using Base.BinaryPlatforms: AbstractPlatform, HostPlatform, Platform, select_platform, arch
import Artifacts

struct ResolvedLibrary
    spec::String        # the request that pulled this in (or "<dep of X>")
    package::String
    product::String
    dlid::String
    dlname::String      # the dynamic library's soname (identification / bundle filtering)
    # Absolute path of the file to link, or `nothing` for a library whose
    # sites are bound natively but whose symbols are satisfied by other link
    # inputs (e.g. libblastrampoline under --link-native-blas).
    path::Union{String, Nothing}
    linkage::String     # "static" or "dynamic"
    location::String    # "bundled" or "artifact" (where the library file lives)
    system_deps::Vector{String}
end

# Locate a package's source directory without loading the package.
function locate_pkgdir(pkgname::AbstractString)
    pkgid = Base.identify_package(String(pkgname))
    pkgid === nothing &&
        error("--link-native: package $pkgname not found in the project's dependencies")
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
        fmt = get(record, "jll_format", nothing)
        ver = fmt isa AbstractString ? tryparse(VersionNumber, fmt) : nothing
        ver isa VersionNumber && ver.major == 2 ||
            error("--link-native: $record_path has unsupported jll_format $(repr(fmt))")
        haskey(record, "products") ||
            error("--link-native: $record_path declares no product identities")
        haskey(record, "builds") ||
            error("--link-native: $record_path declares no builds")
        return record
    end
end

# Keys of a [[builds]] block that are data rather than platform-selector
# tags in the hand-written (tag-key) spelling.
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
        get(b, "location", nothing) == "artifact" || continue
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

# The private shared-library directory of this Julia installation, where
# `location = "bundled"` products live under their `dlname`.
function bundled_shlibdir()
    libname = ifelse(Base.isdebugbuild(), "libjulia-internal-debug", "libjulia-internal")
    return dirname(Base.Libc.Libdl.dlpath(libname))
end

function resolve_library(spec::String, pkgname::String, prodname::String,
                         record::Dict{String,Any}, host::AbstractPlatform;
                         static::Bool = false)
    identity = get(record["products"], prodname, nothing)
    identity === nothing &&
        error("--link-native: $pkgname's record declares no product `$prodname`")
    dlid = get(identity, "dlid", nothing)
    dlid isa String ||
        error("--link-native: $pkgname.$prodname declares no dlid")
    build = select_build(record, host)
    build === nothing &&
        error("--link-native: $pkgname's record has no build for this platform")
    location = get(build, "location", nothing)
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
        # Bundled: paths resolve against the private shlibdir of the Julia
        # installation that owns the record.
        base = bundled_shlibdir()
    end
    product = get(get(build, "products", Dict{String,Any}()), prodname, nothing)
    product === nothing &&
        error("--link-native: $pkgname.$prodname is not available for this platform")
    dyngroup = get(product, "dynamic", nothing)
    stgroup = get(product, "static", nothing)
    if static
        # Static linkage: link the archive declared by the `static` table. Its
        # dependency edges and system-library closure come from the record,
        # because archives carry no DT_NEEDED equivalent.
        stgroup isa Dict ||
            error("--link-native: $pkgname.$prodname has no static library for this platform")
        relpath = get(stgroup, "path", nothing)
        relpath isa String ||
            error("--link-native: $pkgname.$prodname's static group declares no path")
        path = joinpath(base, relpath)
        isfile(path) ||
            error("--link-native: $pkgname.$prodname's static archive $path does not exist")
        deps = Vector{String}(get(stgroup, "deps", String[]))
        system_deps = Vector{String}(get(stgroup, "system_deps", String[]))
        # The dynamic library's soname still names the shipped shared
        # file (bundle filtering, shim configuration); a static-only product
        # has none, so fall back to the archive name.
        dlname = dyngroup isa Dict ?
            something(get(dyngroup, "soname", nothing), basename(relpath)) : basename(relpath)
        lib = ResolvedLibrary(spec, pkgname, prodname, dlid, dlname, path, "static", location, system_deps)
        return lib, deps
    else
        if !(dyngroup isa Dict)
            stgroup isa Dict &&
                error("--link-native: $pkgname.$prodname has only a static library " *
                      "for this platform; request it as `static:$pkgname.$prodname`")
            error("--link-native: $pkgname.$prodname has no dynamic library for this platform")
        end
        soname = get(dyngroup, "soname", nothing)
        soname isa String ||
            error("--link-native: $pkgname.$prodname's dynamic group declares no soname")
        # The locator defaults to the soname: the file so named in the
        # private shlibdir of the installation that owns the record (the
        # same file the package's lazy loading path opens).
        path = joinpath(base, get(dyngroup, "path", soname))
        isfile(path) ||
            error("--link-native: $pkgname.$prodname resolved to $path, which does not exist")
        lib = ResolvedLibrary(spec, pkgname, prodname, dlid, soname, path, "dynamic", location, String[])
        return lib, Vector{String}(get(dyngroup, "deps", String[]))
    end
end

# The package whose call sites `--link-native-blas` redirects: every
# libblastrampoline site is bound natively, and its symbols are satisfied by
# the provider's library plus JuliaC's LBT control-API shim.
const BLAS_TRAMPOLINE_PACKAGE = "libblastrampoline_jll"

"""
Resolve `--link-native` specs to concrete libraries, close over their record
dependency edges, register every dlid with the runtime policy table, and
write the link-inputs manifest to `link_inputs_path`.

With `blas_provider` set (`--link-native-blas`), additionally register
libblastrampoline's dlids — without linking libblastrampoline itself — and
resolve the provider (and its closure) as ordinary native link inputs.
"""
function resolve_and_register!(specs::Vector{String}, link_inputs_path::String;
                               blas_provider::Union{String, Nothing} = nothing)
    # Runtime support check up front, so the failure mode is a clear error
    # rather than a missing-symbol crash at registration time.
    let handle = Base.Libc.Libdl.dlopen("libjulia-internal"; throw_error=false)
        if handle === nothing ||
                Base.Libc.Libdl.dlsym(handle, :jl_add_native_link_lib_id; throw_error=false) === nothing
            error("--link-native requires a Julia runtime with id-keyed native-link " *
                  "support; this Julia ($(VERSION)) does not provide it.")
        end
    end

    host = HostPlatform()
    record_cache = Dict{String,Any}()
    resolved = ResolvedLibrary[]
    seen = Set{Tuple{String,String}}()  # (package, product)
    # (spec, package, product, static); empty product = every product
    queue = Tuple{String,String,String,Bool}[]

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
        return collect(String, keys(get(build, "products", Dict{String,Any}())))
    end

    substituted = ResolvedLibrary[]
    if blas_provider !== nothing
        # Register the trampoline's identities so its call sites are bound
        # natively, but do not link it: its computational symbols resolve
        # directly into the provider, and its control API into the shim.
        record = load_record(BLAS_TRAMPOLINE_PACKAGE, record_cache)
        for prodname in platform_products(record)
            lib, _ = resolve_library("<blas trampoline>", BLAS_TRAMPOLINE_PACKAGE,
                                     String(prodname), record, host)
            push!(substituted, ResolvedLibrary(lib.spec, lib.package, lib.product,
                                               lib.dlid, lib.dlname, nothing,
                                               "substituted", lib.location, String[]))
            push!(seen, (BLAS_TRAMPOLINE_PACKAGE, String(prodname)))
        end
        # The provider is an ordinary native-link request (with its closure).
        bare, static = parse_mode(blas_provider)
        parts = split(bare, '.')
        push!(queue, (bare, String(parts[1]),
                      length(parts) == 2 ? String(parts[2]) : "", static))
    end

    for spec in specs
        bare, static = parse_mode(spec)
        parts = split(bare, '.')
        length(parts) <= 2 ||
            error("--link-native: malformed spec `$spec` (expected `Pkg_jll` or `Pkg_jll.product`)")
        push!(queue, (bare, String(parts[1]),
                      length(parts) == 2 ? String(parts[2]) : "", static))
    end

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
        for dep in deps
            depparts = split(dep, '.')
            if length(depparts) == 1
                push!(queue, ("<dep of $pkgname.$prodname>", pkgname, String(depparts[1]), false))
            elseif length(depparts) == 2
                push!(queue, ("<dep of $pkgname.$prodname>", String(depparts[1]), String(depparts[2]), false))
            else
                error("--link-native: malformed dep edge `$dep` in $pkgname's record")
            end
        end
    end

    append!(resolved, substituted)
    for lib in resolved
        ccall(:jl_add_native_link_lib_id, Cvoid, (Cstring,), lib.dlid)
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
            println(io, "dlid = \"", esc(lib.dlid), "\"")
            println(io, "dlname = \"", esc(lib.dlname), "\"")
            println(io, "linkage = \"", esc(lib.linkage), "\"")
            println(io, "location = \"", esc(lib.location), "\"")
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
