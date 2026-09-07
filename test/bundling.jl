# Unit tests for the bundle step's manifest-driven pruning decisions, on
# synthetic JLL.toml records (merged schema), link-inputs, and used-symbols
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

static_input(uuid, product) = Dict{String, Any}("package_uuid" => uuid, "product" => product,
    "linkage" => "static", "location" => "artifact", "dlname" => "$product.so.1")
dynamic_input(uuid, product) = Dict{String, Any}("package_uuid" => uuid, "product" => product,
    "linkage" => "dynamic", "location" => "artifact", "dlname" => "$product.so.1")
inputs(libs...) = Dict{String, Any}("libraries" => Any[libs...])

lazy_group(uuid, product) = Dict{String, Any}("package_uuid" => uuid, "library" => product,
    "symbols" => Any[Dict{String, Any}("symbol" => "f", "kind" => "ccall", "linkage" => "lazy")])
native_group(uuid, product) = Dict{String, Any}("package_uuid" => uuid, "library" => product,
    "symbols" => Any[Dict{String, Any}("symbol" => "f", "kind" => "ccall", "linkage" => "native")])
manifest(groups...) = Dict{String, Any}("libraries" => Any[groups...])

@testset "Bundling: manifest group sonames" begin
    cxx = fake_record(FOO_UUID, "CompilerSupportLibraries_jll",
        Dict{String, Any}("products" => Any[
            Dict{String, Any}("name" => "libstdcxx", "type" => "library",
                              "linkage" => "dynamic", "soname" => "libstdc++.so.6")]))
    records = Dict(FOO_UUID => cxx)
    coords(group) = only(JuliaC._manifest_library_groups(manifest(group)))[1:2]
    # An identified group resolves to the record's soname, not its declared name.
    @test JuliaC._manifest_group_sonames(coords(lazy_group(FOO_UUID, "libstdcxx"))..., records) ==
          ["libstdc++.so.6"]
    # Package UUIDs compare case-insensitively.
    @test JuliaC._manifest_group_sonames(coords(lazy_group(uppercase(FOO_UUID), "libstdcxx"))..., records) ==
          ["libstdc++.so.6"]
    # An identified library whose package ships no record: the declared name.
    @test JuliaC._manifest_group_sonames(coords(lazy_group(BAR_UUID, "libfoo"))..., records) == ["libfoo"]
    # A ccall on a literal library string: the string itself.
    literal = Dict{String, Any}("library" => "libgmp.so.10", "symbols" => Any[])
    @test JuliaC._manifest_group_sonames(coords(literal)..., records) == ["libgmp.so.10"]
    # A symbol looked up across the process names no file.
    process = Dict{String, Any}("library" => nothing, "symbols" => Any[])
    @test JuliaC._manifest_group_sonames(coords(process)..., records) == String[]
end

@testset "Bundling: manifest library groups" begin
    dynamic = Dict{String, Any}("package_uuid" => FOO_UUID, "library" => "libfoo",
                                "kind" => "ccall", "linkage" => "lazy")
    unknown = Dict{String, Any}("symbol" => "g", "kind" => "ccall", "linkage" => "lazy")
    m = Dict{String, Any}("libraries" => Any[lazy_group(BAR_UUID, "libbar")],
                          "unresolved" => Any[dynamic, unknown])
    groups = JuliaC._manifest_library_groups(m)
    @test length(groups) == 2
    @test groups[1][1:2] == (BAR_UUID, "libbar") && length(groups[1][3]) == 1
    @test groups[2][1:2] == (FOO_UUID, "libfoo") && groups[2][3] == Any[dynamic]
    @test isempty(JuliaC._manifest_library_groups(nothing))
end

@testset "Bundling: artifact prune plan" begin
    foo = fake_record(FOO_UUID, "Foo_jll", fake_build(FOO_HASH, ["libfoo", "libfoof"]))
    records = Dict(FOO_UUID => foo)

    # Every library product statically linked, nothing reached: whole drop (trim).
    plan = JuliaC._artifact_prune_plan(records,
        inputs(static_input(FOO_UUID, "libfoo"), static_input(FOO_UUID, "libfoof")),
        manifest(native_group(FOO_UUID, "libfoo")))
    @test length(plan) == 1 && plan[1].drop && plan[1].hash == FOO_HASH && plan[1].package == "Foo_jll"

    # Same link, but without --trim there is no complete manifest: only the
    # statically linked products' shared libraries go.
    plan = JuliaC._artifact_prune_plan(records,
        inputs(static_input(FOO_UUID, "libfoo"), static_input(FOO_UUID, "libfoof")), nothing)
    @test length(plan) == 1 && !plan[1].drop
    @test sort(plan[1].remove) == [("libfoo", "lib/libfoo.so.1.2.3"), ("libfoof", "lib/libfoof.so.1.2.3")]
    @test sort(plan[1].archives) == [("libfoo", "lib/libfoo.a"), ("libfoof", "lib/libfoof.a")]

    # One product static, the other reached lazily: keep the artifact, remove
    # only the static product's shared library.
    plan = JuliaC._artifact_prune_plan(records, inputs(static_input(FOO_UUID, "libfoo")),
        manifest(native_group(FOO_UUID, "libfoo"), lazy_group(FOO_UUID, "libfoof")))
    @test length(plan) == 1 && !plan[1].drop && plan[1].remove == [("libfoo", "lib/libfoo.so.1.2.3")]

    # A kept artifact loses only its static libraries, which nothing loads
    # at run time.
    archives_only(plan) = length(plan) == 1 && !plan[1].drop && isempty(plan[1].remove) &&
        sort(plan[1].archives) == [("libfoo", "lib/libfoo.a"), ("libfoof", "lib/libfoof.a")]

    # A natively-linked *dynamic* product is flattened into lib/julia; the
    # artifact is treated as referenced and its shared libraries stay.
    plan = JuliaC._artifact_prune_plan(records,
        inputs(dynamic_input(FOO_UUID, "libfoo"), dynamic_input(FOO_UUID, "libfoof")),
        manifest(native_group(FOO_UUID, "libfoo")))
    @test archives_only(plan)

    # Nothing linked natively, one product reached lazily: shared libraries stay.
    plan = JuliaC._artifact_prune_plan(records, inputs(),
        manifest(lazy_group(FOO_UUID, "libfoo")))
    @test archives_only(plan)

    # A non-library product keeps the artifact even when every library is static.
    withfile = fake_record(FOO_UUID, "Foo_jll", fake_build(FOO_HASH, ["libfoo"];
        extra = Any[Dict{String, Any}("name" => "data", "type" => "file", "path" => "share/data.bin")]))
    plan = JuliaC._artifact_prune_plan(Dict(FOO_UUID => withfile),
        inputs(static_input(FOO_UUID, "libfoo")), manifest(native_group(FOO_UUID, "libfoo")))
    @test length(plan) == 1 && !plan[1].drop && plan[1].remove == [("libfoo", "lib/libfoo.so.1.2.3")]

    # Dependency closure: Bar.libbar is reached lazily and its record says it
    # depends on Foo_jll.libfoo, so Foo's artifact is reached too.
    bar = fake_record(BAR_UUID, "Bar_jll",
        fake_build(BAR_HASH, ["libbar"]; deps = Dict("libbar" => ["Foo_jll.libfoo"])))
    plan = JuliaC._artifact_prune_plan(Dict(FOO_UUID => foo, BAR_UUID => bar), inputs(),
        manifest(lazy_group(BAR_UUID, "libbar")))
    @test [(a.hash, a.drop, a.remove) for a in plan] == [(FOO_HASH, false, []), (BAR_HASH, false, [])]
    # Without that edge, Foo's artifact is unreachable and dropped; Bar's stays.
    bar2 = fake_record(BAR_UUID, "Bar_jll", fake_build(BAR_HASH, ["libbar"]))
    plan = JuliaC._artifact_prune_plan(Dict(FOO_UUID => foo, BAR_UUID => bar2), inputs(),
        manifest(lazy_group(BAR_UUID, "libbar")))
    @test [(a.hash, a.drop) for a in plan] == [(FOO_HASH, true), (BAR_HASH, false)]
    @test plan[2].archives == [("libbar", "lib/libbar.a")]

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

        plan = [JuliaC.ArtifactPrune(FOO_HASH, "Foo_jll", false, [("libfoo", "lib/libfoo.so.1.2.3")],
                                     [("libfoo", "lib/libfoo.a"), ("libfoof", "lib/libfoof.a")]),
                JuliaC.ArtifactPrune(BAR_HASH, "Bar_jll", true, Tuple{String, String}[], Tuple{String, String}[])]
        dropped, removed, archives = JuliaC._apply_artifact_prune!(out, plan; quiet = true)
        @test dropped == ["$BAR_HASH (Bar_jll)"]
        @test length(removed) == 3
        @test archives == ["Foo_jll.libfoo: lib/libfoo.a"]   # libfoof.a is absent: skipped
        @test sort(readdir(lib)) == ["libfoo.la", "libfoof.so.1.2.3"]
        @test !ispath(bar)
    end
end

@testset "strip: object detection" begin
    out = mktempdir()
    elf = joinpath(out, "libelf.so.1"); write(elf, UInt8[0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01])
    macho = joinpath(out, "libmacho.dylib"); write(macho, UInt8[0xcf, 0xfa, 0xed, 0xfe, 0x07, 0x00])
    pe = joinpath(out, "lib.dll"); write(pe, "MZ\x90\x00\x03")
    archive = joinpath(out, "libfoo.a"); write(archive, "!<arch>\n")
    script = joinpath(out, "libgcc_s.so"); write(script, "/* GNU ld script */\nINPUT(libgcc_s.so.1 -lgcc)\n")
    tiny = joinpath(out, "tiny"); write(tiny, "\x7fE")
    cert = joinpath(out, "cert.pem"); write(cert, "-----BEGIN CERTIFICATE-----\n")
    symlink("libelf.so.1", joinpath(out, "libelf.so"))
    @test JuliaC._is_strippable_object(elf)
    @test JuliaC._is_strippable_object(macho)
    @test JuliaC._is_strippable_object(pe)
    @test !JuliaC._is_strippable_object(archive)
    @test !JuliaC._is_strippable_object(script)
    @test !JuliaC._is_strippable_object(tiny)
    @test !JuliaC._is_strippable_object(cert)
    @test !JuliaC._is_strippable_object(joinpath(out, "libelf.so"))   # symlink: stripped via its target
    @test !JuliaC._is_strippable_object(out)                          # directory
    @test !JuliaC._is_strippable_object(joinpath(out, "missing"))
end

# Strip a copy of the running Julia's own runtime library in place, through
# the same pass the bundle step uses, and check it stays loadable.
if Sys.which("strip") !== nothing
@testset "strip: bundle pass" begin
    out = mktempdir()
    libdir = joinpath(out, "lib", "julia"); mkpath(libdir)
    src = Libdl.dlpath("libjulia-internal")
    dest = joinpath(libdir, basename(src)); cp(src, dest; follow_symlinks = true)
    symlink(basename(src), joinpath(libdir, "libjulia-internal-link.so"))
    write(joinpath(libdir, "libgcc_s.so"), "INPUT(libgcc_s.so.1)\n")
    mkpath(joinpath(out, "share", "julia")); write(joinpath(out, "share", "julia", "cert.pem"), "x")
    before = filesize(dest)
    # Bundled artifacts arrive read-only (file and directory), as in the depot.
    chmod(dest, 0o444); chmod(libdir, 0o555)
    recipe = JuliaC.BundleRecipe(output_dir = out, strip = true)
    recipe.link_recipe.image_recipe.quiet = true
    stripped = JuliaC._strip_bundle!(recipe)
    @test stripped == [dest]
    @test filesize(dest) < before
    @test filemode(dest) & 0o777 == 0o444
    @test filemode(libdir) & 0o777 == 0o555
    chmod(libdir, 0o755)
    @test read(joinpath(libdir, "libgcc_s.so"), String) == "INPUT(libgcc_s.so.1)\n"
    # The dynamic symbol table survives: the library still loads and exports.
    h = Libdl.dlopen(dest, Libdl.RTLD_LOCAL | Libdl.RTLD_LAZY)
    try
        @test Libdl.dlsym(h, :jl_get_ptls_states; throw_error = false) !== nothing ||
              Libdl.dlsym(h, :jl_gc_enable; throw_error = false) !== nothing
    finally
        Libdl.dlclose(h)
    end
end
end
