function run_juliac_cli(args::Vector{String})
    cmd = `$(Base.julia_cmd()) --startup-file=no --history-file=no --project=$(ROOT) -m JuliaC`
    for a in args
        cmd = `$cmd $a`
    end
    run(cmd)
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
    if Sys.iswindows()
        @test link.rpath == bun.libdir
    else
        @test link.rpath == joinpath("..", bun.libdir)
    end

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
    if Sys.iswindows()
        @test link2.rpath == bun2.libdir
    else
        @test link2.rpath == joinpath("..", bun2.libdir)
    end

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
    @test occursin("--experimental", out)
    @test occursin("--verbose", out)
    @test occursin("--help", out)
end
