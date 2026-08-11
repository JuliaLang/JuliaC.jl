# This file is a part of JuliaC. License is MIT: https://julialang.org/license
#
# Resolution pass for `--link-native`: turn package-level specs
# (`Pkg_jll` or `Pkg_jll.product`) into a concrete set of libraries by
# consuming each package's `JuliaLibrary.toml` record, register every
# resolved library's dlid with the runtime's native-link policy table, and
# write a link-inputs manifest for the driver's link step.
#
# This runs before any user code (and therefore before any ccall lowering),
# in the target process, so record resolution sees the target project's
# load path. Records are consumed as data; the JLL modules themselves are
# not loaded here.

module JuliaCLinkNative

using Base.BinaryPlatforms: AbstractPlatform, HostPlatform, Platform, select_platform, arch

struct ResolvedLibrary
    spec::String        # the request that pulled this in (or "<dep of X>")
    package::String
    product::String
    dlid::String
    dlname::String
    # Absolute path of the file to link, or `nothing` for a library whose
    # sites are bound natively but whose symbols are satisfied by other link
    # inputs (e.g. libblastrampoline under --link-native-blas).
    path::Union{String, Nothing}
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
        record_path = joinpath(pkgdir, "JuliaLibrary.toml")
        isfile(record_path) ||
            error("--link-native: $pkgname has no JuliaLibrary.toml record; " *
                  "only packages that ship one can be natively linked")
        record = Base.parsed_toml(record_path)
        fmt = get(record, "library_format", nothing)
        fmt isa Real && 1.0 <= fmt < 2.0 ||
            error("--link-native: $record_path has unsupported library_format $(repr(fmt))")
        haskey(record, "products") ||
            error("--link-native: $record_path declares no products")
        return record
    end
end

# Select the variant of `product` matching the host platform, Artifacts.toml
# style: String-valued keys are platform tags, most specific match wins.
function select_variant(product::Dict{String,Any}, host::AbstractPlatform)
    variants = get(product, "variants", Any[])
    dict = Dict{Platform,Any}()
    for v in variants
        haskey(v, "os") || error("--link-native: record variant missing an `os` key")
        tags = Dict{Symbol,String}()
        for (k, val) in v
            (val isa String && k != "dlname" && k != "path" && k != "os" && k != "arch") || continue
            tags[Symbol(k)] = val
        end
        p = Platform(get(v, "arch", arch(host)), v["os"]; tags...)
        dict[p] = v
    end
    return select_platform(dict, host)
end

# The private shared-library directory of this Julia installation, where
# `location = "bundled"` products live under their `dlname`.
function bundled_shlibdir()
    libname = ifelse(Base.isdebugbuild(), "libjulia-internal-debug", "libjulia-internal")
    return dirname(Base.Libc.Libdl.dlpath(libname))
end

function resolve_library(spec::String, pkgname::String, prodname::String,
                         record::Dict{String,Any}, host::AbstractPlatform)
    product = get(record["products"], prodname, nothing)
    product === nothing &&
        error("--link-native: $pkgname's record declares no product `$prodname`")
    dlid = get(product, "dlid", nothing)
    dlid isa String ||
        error("--link-native: $pkgname.$prodname declares no dlid")
    variant = select_variant(product, host)
    variant === nothing &&
        error("--link-native: $pkgname.$prodname is not available for this platform")
    dlname = get(variant, "dlname", nothing)
    dlname isa String ||
        error("--link-native: $pkgname.$prodname's selected variant declares no dlname")
    location = get(product, "location", nothing)
    if location == "bundled"
        # Definitionally the file named `dlname` in the private shlibdir of
        # the installation that owns the record (the same file the package's
        # lazy loading path opens).
        path = joinpath(bundled_shlibdir(), dlname)
    elseif location == "artifact"
        error("--link-native: $pkgname.$prodname is artifact-backed, which is not yet supported")
    else
        error("--link-native: $pkgname.$prodname has unsupported location $(repr(location))")
    end
    isfile(path) ||
        error("--link-native: $pkgname.$prodname resolved to $path, which does not exist")
    return ResolvedLibrary(spec, pkgname, prodname, dlid, dlname, path), variant
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
    queue = Tuple{String,String,String}[]  # (spec, package, product)

    substituted = ResolvedLibrary[]
    if blas_provider !== nothing
        # Register the trampoline's identities so its call sites are bound
        # natively, but do not link it: its computational symbols resolve
        # directly into the provider, and its control API into the shim.
        record = load_record(BLAS_TRAMPOLINE_PACKAGE, record_cache)
        for prodname in keys(record["products"])
            lib, _ = resolve_library("<blas trampoline>", BLAS_TRAMPOLINE_PACKAGE,
                                     String(prodname), record, host)
            push!(substituted, ResolvedLibrary(lib.spec, lib.package, lib.product,
                                               lib.dlid, lib.dlname, nothing))
            push!(seen, (BLAS_TRAMPOLINE_PACKAGE, String(prodname)))
        end
        # The provider is an ordinary native-link request (with its closure).
        push!(queue, (blas_provider, String(split(blas_provider, '.')[1]),
                      length(split(blas_provider, '.')) == 2 ?
                          String(split(blas_provider, '.')[2]) : ""))
    end

    for spec in specs
        parts = split(spec, '.')
        length(parts) <= 2 ||
            error("--link-native: malformed spec `$spec` (expected `Pkg_jll` or `Pkg_jll.product`)")
        pkgname = String(parts[1])
        record = load_record(pkgname, record_cache)
        if length(parts) == 2
            push!(queue, (spec, pkgname, String(parts[2])))
        else
            for prodname in keys(record["products"])
                push!(queue, (spec, pkgname, String(prodname)))
            end
        end
    end

    while !isempty(queue)
        (spec, pkgname, prodname) = popfirst!(queue)
        if isempty(prodname)
            # expand to every product of the package
            record = load_record(pkgname, record_cache)
            for pn in keys(record["products"])
                push!(queue, (spec, pkgname, String(pn)))
            end
            continue
        end
        (pkgname, prodname) in seen && continue
        push!(seen, (pkgname, prodname))
        record = load_record(pkgname, record_cache)
        lib, variant = resolve_library(spec, pkgname, prodname, record, host)
        push!(resolved, lib)
        # Provision closure: everything a natively-provided library depends on
        # must itself be natively provided (its dlopen never runs).
        for dep in get(variant, "deps", String[])
            depparts = split(dep, '.')
            if length(depparts) == 1
                push!(queue, ("<dep of $pkgname.$prodname>", pkgname, String(depparts[1])))
            elseif length(depparts) == 2
                push!(queue, ("<dep of $pkgname.$prodname>", String(depparts[1]), String(depparts[2])))
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
            if lib.path !== nothing
                println(io, "path = \"", esc(lib.path), "\"")
            end
            println(io)
        end
    end
    return length(resolved)
end

end # module JuliaCLinkNative
