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
        "--verbose",
    ]
    # Shell out to simulate user invocation
    run_juliac_cli(cliargs)
    actual_exe = Sys.iswindows() ? joinpath(outdir, "bin", exename * ".exe") : joinpath(outdir, "bin", exename)
    @test isfile(actual_exe)
    output = read(`$actual_exe`, String)
    @test occursin("Fast compilation test!", output)
    print_tree_with_sizes(outdir)
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
            "--verbose",
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
        "--verbose",
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
        "--verbose",
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
    @show img2.add_ccallables
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
