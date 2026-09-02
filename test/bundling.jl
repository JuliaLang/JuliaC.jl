# Unit tests for the bundle step's manifest-driven pruning decisions, on
# synthetic JLL.toml records (merged schema), link-inputs, and foreign-deps
# manifests; no compilation involved.

const FOO_UUID = "11111111-1111-1111-1111-111111111111"
const BAR_UUID = "22222222-2222-2222-2222-222222222222"
const FOO_HASH = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const BAR_HASH = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# A record build binding an artifact, with library products `libs` (each
# both dynamic and static) and optional extra (non-library) products.
function fake_build(hash, libs; deps = Dict{String, Vector{String}}(), extra = Any[])
    products = Any[]
    for name in libs
        d = get(deps, name, String[])
        push!(products, Dict{String, Any}("name" => name, "type" => "library",
            "linkage" => "dynamic", "soname" => "$name.so.1", "path" => "lib/$name.so.1.2.3",
            "deps" => d))
        push!(products, Dict{String, Any}("name" => name, "type" => "library",
            "linkage" => "static", "path" => "lib/$name.a", "deps" => d))
    end
    append!(products, extra)
    return Dict{String, Any}("artifact" => Dict{String, Any}("treehash" => "sha1:" * hash),
                             "products" => products)
end
fake_record(uuid, name, build) =
    JuliaC.JLLRecord(uuid, name, Dict{String, Any}("builds" => Any[build]), build)

static_input(uuid, product) = Dict{String, Any}("dlid" => "$uuid:$product",
    "linkage" => "static", "location" => "artifact", "dlname" => "$product.so.1")
dynamic_input(uuid, product) = Dict{String, Any}("dlid" => "$uuid:$product",
    "linkage" => "dynamic", "location" => "artifact", "dlname" => "$product.so.1")
inputs(libs...) = Dict{String, Any}("libraries" => Any[libs...])

lazy_group(uuid, product) = Dict{String, Any}("library_id" => "$uuid:$product",
    "symbols" => Any[Dict{String, Any}("symbol" => "f", "kind" => "ccall", "linkage" => "lazy")])
native_group(uuid, product) = Dict{String, Any}("library_id" => "$uuid:$product",
    "symbols" => Any[Dict{String, Any}("symbol" => "f", "kind" => "ccall", "linkage" => "native")])
manifest(groups::Pair...) = Dict{String, Any}("libraries" => Dict{String, Any}(groups...))

@testset "Bundling: manifest group sonames" begin
    cxx = fake_record(FOO_UUID, "CompilerSupportLibraries_jll",
        Dict{String, Any}("products" => Any[
            Dict{String, Any}("name" => "libstdcxx", "type" => "library",
                              "linkage" => "dynamic", "soname" => "libstdc++.so.6")]))
    records = Dict(FOO_UUID => cxx)
    # An identified group resolves to the record's soname, not its declared name.
    @test JuliaC._manifest_group_sonames("libstdcxx", lazy_group(FOO_UUID, "libstdcxx"), records) ==
          ["libstdc++.so.6"]
    # Identity keys compare case-insensitively on the uuid.
    @test JuliaC._manifest_group_sonames("libstdcxx", lazy_group(uppercase(FOO_UUID), "libstdcxx"), records) ==
          ["libstdc++.so.6"]
    # An identified library whose package ships no record: the declared name.
    @test JuliaC._manifest_group_sonames("libfoo", lazy_group(BAR_UUID, "libfoo"), records) == ["libfoo"]
    # A ccall on a literal library string: the string itself.
    @test JuliaC._manifest_group_sonames("libgmp.so.10", Dict{String, Any}("symbols" => Any[]), records) ==
          ["libgmp.so.10"]
end
