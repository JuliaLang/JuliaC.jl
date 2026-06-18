using JSON

function run_juliac_cli(args::Vector{String}; dir=nothing)
    cmd = `$(Base.julia_cmd()) --startup-file=no --history-file=no --project=$(ROOT) -m JuliaC $args`
    if dir !== nothing
        run(Cmd(cmd; dir=dir))
    else
        run(cmd)
    end
end

@testset "CLI app entrypoint (trim)" begin
    outdir = mktempdir()
    exename = "app"
    cliargs = String[
        "--output-exe", exename,
        "--trim=safe",
        TEST_PROJ,
        "--bundle", outdir,
        "--quiet",
    ]
    # Shell out to simulate user invocation
    run_juliac_cli(cliargs)
    actual_exe = Sys.iswindows() ? joinpath(outdir, "bin", exename * ".exe") : joinpath(outdir, "bin", exename)
    @test isfile(actual_exe)
    output = read(`$actual_exe`, String)
    @test occursin("Fast compilation test!", output)
end

# Windows expects all binaries to be next to each other, so we can't test this
if Sys.isunix()
    @testset "CLI app without bundle (system rpaths)" begin
        # Test that executables work without --bundle by using system Julia rpaths
        outdir = mktempdir()
        exename = "app_nobundle"
        exepath = joinpath(outdir, exename)
        cliargs = String[
            "--output-exe", exename,
            "--trim=safe",
            TEST_PROJ,
            "--quiet",
        ]
        # Run in outdir so the exe is created there
        run_juliac_cli(cliargs; dir=outdir)
        actual_exe = Sys.iswindows() ? exepath * ".exe" : exepath
        @test isfile(actual_exe)
        # The executable should run successfully using system Julia libraries
        output = read(`$actual_exe`, String)
        @test occursin("Fast compilation test!", output)

    end
end

@testset "ABI export" begin
    outdir = mktempdir()
    libout = joinpath(outdir, "libsimple")
    abiout = joinpath(outdir, "bindinginfo_libsimple.json")
    cliargs = String[
        "--output-lib", libout,
        "--compile-ccallable",
        "--trim=safe",
        joinpath(@__DIR__, "libsimple.jl"),
        "--export-abi",
        abiout,
        "--quiet",
    ]
    run_juliac_cli(cliargs)
    str = read(abiout, String)
    abi = JSON.parse(str)

    # `copyto_and_sum` should have been exported
    @test any(Bool[func["symbol"] == "copyto_and_sum" for func in abi["functions"]])

    # `CVector{Float32}` should have been exported with the correct info
    @test any(Bool[type["name"] == "CVector{Float32}" for type in abi["types"]])
    CVector_Float32 = abi["types"][findfirst(type["name"] == "CVector{Float32}" for type in abi["types"])]
    @test length(CVector_Float32["fields"]) == 2
    @test CVector_Float32["fields"][1]["offset"] == 0
    @test CVector_Float32["fields"][2]["offset"] == 8
    @test abi["types"][CVector_Float32["fields"][1]["type_id"]]["name"] == "Int32"
    @test abi["types"][CVector_Float32["fields"][2]["type_id"]]["name"] == "Ptr{Float32}"
    @test CVector_Float32["size"] == 16

    # `CVectorPair{Float32}` should have been exported with the correct info
    @test any(Bool[type["name"] == "CVectorPair{Float32}" for type in abi["types"]])
    CVectorPair_Float32 = abi["types"][findfirst(type["name"] == "CVectorPair{Float32}" for type in abi["types"])]
    @test length(CVectorPair_Float32["fields"]) == 2
    @test CVectorPair_Float32["fields"][1]["offset"] == 0
    @test CVectorPair_Float32["fields"][2]["offset"] == 16
    @test abi["types"][CVectorPair_Float32["fields"][1]["type_id"]]["name"] == "CVector{Float32}"
    @test abi["types"][CVectorPair_Float32["fields"][2]["type_id"]]["name"] == "CVector{Float32}"
    @test CVectorPair_Float32["size"] == 32

    # `CTree{Float64}` should have been exported with the correct info
    @test any(Bool[type["name"] == "CTree{Float64}" for type in abi["types"]])
    CTree_Float64_id = findfirst(type["name"] == "CTree{Float64}" for type in abi["types"])
    CTree_Float64 = abi["types"][CTree_Float64_id]
    @test length(CTree_Float64["fields"]) == 1
    @test CTree_Float64["fields"][1]["offset"] == 0
    CVector_CTree_Float64 = abi["types"][CTree_Float64["fields"][1]["type_id"]]
    @test CVector_CTree_Float64["name"] == "CVector{CTree{Float64}}"
    @test CTree_Float64["size"] == sizeof(UInt) * 2

    # `CVector{CTree{Float64}}` should have been exported with the correct info
    @test length(CVector_CTree_Float64["fields"]) == 2
    @test CVector_CTree_Float64["fields"][1]["offset"] == 0
    @test CVector_CTree_Float64["fields"][2]["offset"] == sizeof(UInt)
    @test abi["types"][CVector_CTree_Float64["fields"][1]["type_id"]]["name"] == "Int32"
    @test abi["types"][CVector_CTree_Float64["fields"][2]["type_id"]]["name"] == "Ptr{CTree{Float64}}"
    @test CVector_CTree_Float64["size"] == sizeof(UInt) * 2

    # `Ptr{CTree{Float64}}` should refer (recursively) back to the original type id
    Ptr_CTree_Float64 = abi["types"][CVector_CTree_Float64["fields"][2]["type_id"]]
    @test Ptr_CTree_Float64["pointee_type_id"] == CTree_Float64_id

    # Homogeneous NTuple field should be emitted with `"kind": "array"` rather
    # than expanded to per-element struct fields.
    @test any(Bool[type["name"] == "CBuf4" for type in abi["types"]])
    CBuf4 = abi["types"][findfirst(type["name"] == "CBuf4" for type in abi["types"])]
    @test length(CBuf4["fields"]) == 1
    tuple_type = abi["types"][CBuf4["fields"][1]["type_id"]]
    @test tuple_type["kind"] == "array"
    @test tuple_type["count"] == 4
    @test abi["types"][tuple_type["element_type_id"]]["name"] == "Float64"
    @test tuple_type["size"] == 32

    # Parametric struct with a non-type (`Int`) parameter: the build itself
    # is the test — before the guard in `recursively_add_types!` was added,
    # iterating `T.parameters` of `CArrayN{Float64,3}` hit the `2`/`3` `Int`
    # and crashed with a `MethodError`. Confirm the type made it out the
    # other side and has the expected shape.
    carray3d = abi["types"][findfirst(t["name"] == "CArrayN{Float64, 3}" for t in abi["types"])]
    @test carray3d["kind"] == "struct"
    @test length(carray3d["fields"]) == 2
    dims_type = abi["types"][carray3d["fields"][1]["type_id"]]
    @test dims_type["kind"] == "array"
    @test dims_type["count"] == 3
    @test abi["types"][dims_type["element_type_id"]]["name"] == "Int32"
    data_type = abi["types"][carray3d["fields"][2]["type_id"]]
    @test data_type["kind"] == "pointer"
    @test abi["types"][data_type["pointee_type_id"]]["name"] == "Float64"
end

@testset "CLI library privatize end-to-end" begin
    outdir = mktempdir()
    libout = joinpath(outdir, "libpriv")
    cliargs = String[
        "--output-lib", libout,
        "--project", TEST_LIB_PROJ,
        "--compile-ccallable",
        "--trim=safe",
        TEST_LIB_SRC,
        "--bundle", outdir,
        "--privatize",
        "--quiet",
    ]
    run_juliac_cli(cliargs)
    dlext = Base.BinaryPlatforms.platform_dlext()
    libpath = joinpath(outdir, Sys.iswindows() ? "bin" : "lib", basename(libout) * "." * dlext)
    @test isfile(libpath)
    # Check salted libjulia exists in bundle
    if Sys.isunix()
        # Verify the built library can be dlopened and called from a fresh Julia process
        lib_literal = repr(libpath)
        julia_snippet = "using Libdl; h = Libdl.dlopen(" * lib_literal * ", Libdl.RTLD_LOCAL); try; fptr = Libdl.dlsym(h, :jc_add_one); r = ccall(fptr, Cint, (Cint,), 41); println(r); finally; try Libdl.dlclose(h) catch end; end;"
        out = read(`$(Base.julia_cmd()) --startup-file=no --history-file=no -e $julia_snippet`, String)
        @test occursin("42", out)
    end
end

@testset "CLI parse args" begin
    # Basic executable with bundle default dir and rpath
    args = String[
        "--output-exe", "app",
        "--project", TEST_PROJ,
        "--trim=safe",
        TEST_SRC,
        "--bundle",
        "--verbose",
    ]
    img, link, bun = JuliaC._parse_cli_args(args)
    @test img.output_type == "--output-exe"
    @test img.project == TEST_PROJ
    @test img.trim_mode == "safe"
    @test link.outname == "app"
    @test bun.output_dir == abspath(dirname(link.outname))
    @test link.rpath == JuliaC.RPATH_BUNDLE  # Should use @bundle when bundling

    # Library with explicit bundle dir, ccallable and experimental
    outdir = mktempdir()
    args2 = String[
        "--output-lib", joinpath(outdir, "mylib"),
        "--project=$TEST_LIB_PROJ", # Test both --project= and --project <arg> forms
        "--compile-ccallable",
        "--experimental",
        "--trim",
        TEST_LIB_SRC,
        "--bundle", outdir,
    ]
    img2, link2, bun2 = JuliaC._parse_cli_args(args2)
    @test img2.output_type == "--output-lib"
    @test img2.add_ccallables
    @test "--experimental" in img2.julia_args
    @test img2.trim_mode == "safe"
    @test link2.outname == joinpath(outdir, "mylib")
    @test bun2.output_dir == outdir
    @test link2.rpath == JuliaC.RPATH_BUNDLE  # Should use @bundle when bundling

    args3 = String[
        "--output-exe", "app",
        "--project", TEST_PROJ,
        "--trim=safe",
        TEST_SRC,
        "--verbose",
    ]
    img3, link3, bun3 = JuliaC._parse_cli_args(args3)
    @test img3.output_type == "--output-exe"
    @test link3.rpath == JuliaC.RPATH_JULIA  # Should use @julia when not bundling
    @test bun3.output_dir === nothing  # No bundling

    # --jl-option with space separator
    args_jlopt = String[
        "--output-lib", joinpath(mktempdir(), "mylib"),
        "--jl-option", "handle-signals=no",
        TEST_LIB_SRC,
    ]
    img_jlopt, _, _ = JuliaC._parse_cli_args(args_jlopt)
    @test img_jlopt.jl_options["handle-signals"] == "no"

    # --jl-option= with equals separator
    args_jlopt2 = String[
        "--output-lib", joinpath(mktempdir(), "mylib"),
        "--jl-option=threads=4",
        TEST_LIB_SRC,
    ]
    img_jlopt2, _, _ = JuliaC._parse_cli_args(args_jlopt2)
    @test img_jlopt2.jl_options["threads"] == "4"

    # Multiple --jl-option flags
    args_jlopt3 = String[
        "--output-lib", joinpath(mktempdir(), "mylib"),
        "--jl-option", "handle-signals=no",
        "--jl-option=threads=4,2",
        TEST_LIB_SRC,
    ]
    img_jlopt3, _, _ = JuliaC._parse_cli_args(args_jlopt3)
    @test img_jlopt3.jl_options["handle-signals"] == "no"
    @test img_jlopt3.jl_options["threads"] == "4,2"

    # --jl-option missing value
    @test_throws ErrorException JuliaC._parse_cli_args(String[
        "--output-lib", joinpath(mktempdir(), "mylib"), TEST_LIB_SRC, "--jl-option"])

    # --jl-option missing = in value
    @test_throws ErrorException JuliaC._parse_cli_args(String[
        "--output-lib", joinpath(mktempdir(), "mylib"), TEST_LIB_SRC, "--jl-option", "badvalue"])

    # Errors: unknown option
    @test_throws ErrorException JuliaC._parse_cli_args(String["--unknown"])

    # Errors: missing output name
    @test_throws ErrorException JuliaC._parse_cli_args(String["--output-exe"])

    # Errors: invalid exe name with path
    @test_throws ErrorException JuliaC._parse_cli_args(String["--output-exe", "bin/app", TEST_SRC])

    # Errors: multiple output types
    @test_throws ErrorException JuliaC._parse_cli_args(String["--output-exe", "app", "--output-lib", "libx", TEST_SRC])

    # Errors: project missing argument
    @test_throws ErrorException JuliaC._parse_cli_args(String["--project"])

    # Errors: missing file
    @test_throws ErrorException JuliaC._parse_cli_args(String["--output-exe", "app"])
end

@testset "CLI help/usage" begin
    # Capture printed help when no args are passed
    io = IOBuffer()
    JuliaC._main_cli(String[]; io=io)
    out = String(take!(io))
    @test occursin("Usage:", out)
    @test occursin("--output-exe", out)
    @test occursin("--output-lib", out)
    @test occursin("--output-sysimage", out)
    @test occursin("--output-o", out)
    @test occursin("--output-bc", out)
    @test occursin("--project", out)
    @test occursin("--bundle", out)
    @test occursin("--trim", out)
    @test occursin("--compile-ccallable", out)
    @test occursin("--jl-option", out)
    @test occursin("--experimental", out)
    @test occursin("--verbose", out)
    @test occursin("--help", out)
end

@testset "CLI --version" begin
    io = IOBuffer()
    JuliaC._main_cli(String["--version"]; io = io)
    @test String(take!(io)) ==
        "juliac version $(pkgversion(JuliaC)), julia version $(VERSION)\n"
end

# https://github.com/JuliaLang/JuliaC.jl/issues/106 + #124
# Simulate the Pkg-app shim env by running `julia -m JuliaC` with
# JULIA_LOAD_PATH pointing at a JuliaC-containing project, the way the shim does.
@testset "Pkg app JULIA_LOAD_PATH isolation (#106)" begin
    projectroot = mktempdir()
    setup = """
    using Pkg
    Pkg.develop(path=$(repr(ROOT)))
    Pkg.instantiate()
    """
    @test success(`$(Base.julia_cmd()) --startup-file=no --history-file=no --project=$(projectroot) -e $setup`)

    outdir = mktempdir()
    exename = "app_pkgapp"
    cmd = addenv(
        `$(Base.julia_cmd()) --startup-file=no --history-file=no --project=$(projectroot) -m JuliaC
         --output-exe $exename $(TEST_PROJ) --bundle $outdir --quiet`,
        "JULIA_LOAD_PATH" => projectroot * "/",
    )
    @test success(cmd)
    actual_exe = Sys.iswindows() ? joinpath(outdir, "bin", exename * ".exe") : joinpath(outdir, "bin", exename)
    @test isfile(actual_exe)
    if isfile(actual_exe)
        output = read(`$actual_exe`, String)
        @test occursin("Fast compilation test!", output)
    end
end

@testset "Package dir basename differs from package name" begin
    # Regression: the buildscript must resolve the package name from the project
    # file's `name`, not the directory basename. They differ whenever a project is
    # built from a copy in a differently-named directory (e.g. a temp dir), which
    # previously failed with `Package <dirname> not found in current path`.
    projdir = joinpath(mktempdir(), "mismatched_dir_name")
    cp(TEST_PROJ, projdir)
    outdir = mktempdir()
    exename = "renamed_app"
    cliargs = String[
        "--output-exe", exename,
        "--trim=safe",
        projdir,
        "--bundle", outdir,
        "--quiet",
    ]
    run_juliac_cli(cliargs)
    actual_exe = Sys.iswindows() ? joinpath(outdir, "bin", exename * ".exe") : joinpath(outdir, "bin", exename)
    @test isfile(actual_exe)
    output = read(`$actual_exe`, String)
    @test occursin("Fast compilation test!", output)
end

# Copy a package source tree to a fresh, writable directory, skipping VCS/build
# cruft and any stale Manifest. Installed packages are read-only and `cp`
# preserves permissions, so we re-grant write to allow instantiation.
function _writable_pkg_copy(src::AbstractString)
    dst = joinpath(mktempdir(), basename(rstrip(src, '/')))
    mkpath(dst)
    for name in readdir(src)
        name in (".git", "build") && continue
        occursin(r"^(Julia)?Manifest.*\.toml$", name) && continue
        cp(joinpath(src, name), joinpath(dst, name); force=true)
    end
    for (root, dirs, files) in walkdir(dst)
        for n in Iterators.flatten((dirs, files))
            p = joinpath(root, n)
            chmod(p, filemode(p) | 0o200)
        end
    end
    return dst
end

# End-to-end: install JuliaC as a Pkg app, invoke the shim, compile a project.
# Unix-only: the Pkg app shim is a shell script on Unix, a .cmd on Windows.
if Sys.isunix()
@testset "Pkg app end-to-end (#106)" begin
    mktempdir() do depot
        outdir = mktempdir()
        exename = "app_e2e"
        sep = ":"
        bindir = joinpath(depot, "bin")

        # `Pkg.Apps.develop` points the generated shim's `JULIA_LOAD_PATH` at the
        # package source dir, so that dir must carry a resolved `Manifest.toml`
        # for `julia -m JuliaC` to load JuliaC's dependencies due to:
        #   https://github.com/JuliaLang/Pkg.jl/issues/4697
        #
        # FIXME: Delete this workaround once that bug is fixed.
        pkgsrc = _writable_pkg_copy(ROOT)
        depot_path = join([depot; Base.DEPOT_PATH], sep)
        install_script = """
        using Pkg
        Pkg.activate($(repr(pkgsrc)))
        Pkg.instantiate()
        Pkg.Apps.develop(; path=$(repr(pkgsrc)))
        """
        install_cmd = addenv(
            `$(Base.julia_cmd()) --startup-file=no --history-file=no -e $install_script`,
            "JULIA_DEPOT_PATH" => depot_path,
        )
        @test success(install_cmd)

        shim = joinpath(bindir, "juliac")
        @test isfile(shim)

        build_cmd = addenv(
            `$shim --output-exe $exename $(TEST_PROJ) --bundle $outdir --quiet`,
            "PATH" => bindir * sep * ENV["PATH"],
        )
        @test success(build_cmd)
        actual_exe = joinpath(outdir, "bin", exename)
        @test isfile(actual_exe)
        if isfile(actual_exe)
            output = read(`$actual_exe`, String)
            @test occursin("Fast compilation test!", output)
        end
    end
end
end
