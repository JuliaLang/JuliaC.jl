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

@testset "Bundling: artifact prune plan" begin
    foo = fake_record(FOO_UUID, "Foo_jll", fake_build(FOO_HASH, ["libfoo", "libfoof"]))
    records = Dict(FOO_UUID => foo)

    # Every library product statically linked, nothing reached: whole drop (trim).
    plan = JuliaC._artifact_prune_plan(records,
        inputs(static_input(FOO_UUID, "libfoo"), static_input(FOO_UUID, "libfoof")),
        manifest("libfoo" => native_group(FOO_UUID, "libfoo")))
    @test length(plan) == 1 && plan[1].drop && plan[1].hash == FOO_HASH && plan[1].package == "Foo_jll"

    # Same link, but without --trim there is no complete manifest: only the
    # statically linked products' shared libraries go.
    plan = JuliaC._artifact_prune_plan(records,
        inputs(static_input(FOO_UUID, "libfoo"), static_input(FOO_UUID, "libfoof")), nothing)
    @test length(plan) == 1 && !plan[1].drop
    @test sort(plan[1].remove) == [("libfoo", "lib/libfoo.so.1.2.3"), ("libfoof", "lib/libfoof.so.1.2.3")]

    # One product static, the other reached lazily: keep the artifact, remove
    # only the static product's shared library.
    plan = JuliaC._artifact_prune_plan(records, inputs(static_input(FOO_UUID, "libfoo")),
        manifest("libfoo" => native_group(FOO_UUID, "libfoo"), "libfoof" => lazy_group(FOO_UUID, "libfoof")))
    @test length(plan) == 1 && !plan[1].drop && plan[1].remove == [("libfoo", "lib/libfoo.so.1.2.3")]

    # A natively-linked *dynamic* product is flattened into lib/julia; the
    # artifact is treated as referenced and nothing is removed from it.
    plan = JuliaC._artifact_prune_plan(records,
        inputs(dynamic_input(FOO_UUID, "libfoo"), dynamic_input(FOO_UUID, "libfoof")),
        manifest("libfoo" => native_group(FOO_UUID, "libfoo")))
    @test isempty(plan)

    # Nothing linked natively, one product reached lazily: untouched.
    plan = JuliaC._artifact_prune_plan(records, inputs(),
        manifest("libfoo" => lazy_group(FOO_UUID, "libfoo")))
    @test isempty(plan)

    # A non-library product keeps the artifact even when every library is static.
    withfile = fake_record(FOO_UUID, "Foo_jll", fake_build(FOO_HASH, ["libfoo"];
        extra = Any[Dict{String, Any}("name" => "data", "type" => "file", "path" => "share/data.bin")]))
    plan = JuliaC._artifact_prune_plan(Dict(FOO_UUID => withfile),
        inputs(static_input(FOO_UUID, "libfoo")), manifest("libfoo" => native_group(FOO_UUID, "libfoo")))
    @test length(plan) == 1 && !plan[1].drop && plan[1].remove == [("libfoo", "lib/libfoo.so.1.2.3")]

    # Dependency closure: Bar.libbar is reached lazily and its record says it
    # depends on Foo_jll.libfoo, so Foo's artifact is reached too.
    bar = fake_record(BAR_UUID, "Bar_jll",
        fake_build(BAR_HASH, ["libbar"]; deps = Dict("libbar" => ["Foo_jll.libfoo"])))
    plan = JuliaC._artifact_prune_plan(Dict(FOO_UUID => foo, BAR_UUID => bar), inputs(),
        manifest("libbar" => lazy_group(BAR_UUID, "libbar")))
    @test isempty(plan)
    # Without that edge, Foo's artifact is unreachable and dropped; Bar's stays.
    bar2 = fake_record(BAR_UUID, "Bar_jll", fake_build(BAR_HASH, ["libbar"]))
    plan = JuliaC._artifact_prune_plan(Dict(FOO_UUID => foo, BAR_UUID => bar2), inputs(),
        manifest("libbar" => lazy_group(BAR_UUID, "libbar")))
    @test [(a.hash, a.drop) for a in plan] == [(FOO_HASH, true)]

    # A bundled (non-artifact) build has nothing in share/julia/artifacts.
    bundled = fake_record(FOO_UUID, "Foo_jll", Dict{String, Any}(
        "artifact" => Dict{String, Any}("bundled_path" => "private_shlibdir"),
        "products" => Any[Dict{String, Any}("name" => "libfoo", "type" => "library",
                                             "linkage" => "static", "path" => "lib/libfoo.a")]))
    @test isempty(JuliaC._artifact_prune_plan(Dict(FOO_UUID => bundled),
        inputs(static_input(FOO_UUID, "libfoo")), manifest()))
end

@testset "Bundling: artifact prune application" begin
    @test JuliaC._is_shlib_named("libfoo", "libfoo.so")
    @test JuliaC._is_shlib_named("libfoo", "libfoo.so.1")
    @test JuliaC._is_shlib_named("libfoo", "libfoo.so.1.2.3")
    @test JuliaC._is_shlib_named("libfoo", "libfoo.1.dylib")
    @test JuliaC._is_shlib_named("libfoo", "libfoo-1.dll")
    @test JuliaC._is_shlib_named("libstdc++", "libstdc++.so.6")
    @test !JuliaC._is_shlib_named("libfoo", "libfoof.so.1")
    @test !JuliaC._is_shlib_named("libfoo", "libfoo.a")
    @test !JuliaC._is_shlib_named("libfoo", "libfoo.la")

    mktempdir() do out
        lib = joinpath(out, "share", "julia", "artifacts", FOO_HASH, "lib")
        mkpath(lib)
        for f in ("libfoo.so.1.2.3", "libfoo.a", "libfoo.la", "libfoof.so.1.2.3")
            write(joinpath(lib, f), "x")
        end
        symlink("libfoo.so.1.2.3", joinpath(lib, "libfoo.so.1"))
        symlink("libfoo.so.1", joinpath(lib, "libfoo.so"))
        bar = joinpath(out, "share", "julia", "artifacts", BAR_HASH)
        mkpath(joinpath(bar, "lib"))
        write(joinpath(bar, "lib", "libbar.so.1"), "x")

        plan = [JuliaC.ArtifactPrune(FOO_HASH, "Foo_jll", false, [("libfoo", "lib/libfoo.so.1.2.3")]),
                JuliaC.ArtifactPrune(BAR_HASH, "Bar_jll", true, Tuple{String, String}[])]
        dropped, removed = JuliaC._apply_artifact_prune!(out, plan; quiet = true)
        @test dropped == ["$BAR_HASH (Bar_jll)"]
        @test length(removed) == 3
        @test sort(readdir(lib)) == ["libfoo.a", "libfoo.la", "libfoof.so.1.2.3"]
        @test !ispath(bar)
    end
end
