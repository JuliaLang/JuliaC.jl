# Trimming tests ported from Base Julia test/trimming/

const TRIM_PROJ = abspath(joinpath(@__DIR__, "TrimmabilityProject"))

@testset "Trimming: executable size check" begin
    # Uses the existing TEST_SRC (test.jl) hello world
    # Verifies the executable size stays reasonable
    outdir = mktempdir()
    exeout = joinpath(outdir, "hello")

    img = JuliaC.ImageRecipe(
        file = TEST_SRC,
        output_type = "--output-exe",
        project = TEST_PROJ,
        trim_mode = "safe",
        verbose = true,
    )
    JuliaC.compile_products(img)
    link = JuliaC.LinkRecipe(image_recipe=img, outname=exeout)
    JuliaC.link_products(link)
    bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir)
    JuliaC.bundle_products(bun)

    actual_exe = Sys.iswindows() ? joinpath(outdir, "bin", basename(exeout) * ".exe") : joinpath(outdir, "bin", basename(exeout))
    @test isfile(actual_exe)

    # Test that the executable size stays reasonable (< 3.5MB for the executable itself)
    @test filesize(actual_exe) < 3_500_000

    print_tree_with_sizes(outdir)
end

@testset "Trimming: trimmability.jl (various constructs)" begin
    outdir = mktempdir()
    exeout = joinpath(outdir, "trimmability")

    # Build trimmability project as executable - tests OncePerProcess, Sockets, sort, map, etc.
    img = JuliaC.ImageRecipe(
        file = TRIM_PROJ,
        output_type = "--output-exe",
        trim_mode = "safe",
        verbose = true,
    )
    JuliaC.compile_products(img)
    link = JuliaC.LinkRecipe(image_recipe=img, outname=exeout)
    JuliaC.link_products(link)
    bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir)
    JuliaC.bundle_products(bun)

    actual_exe = Sys.iswindows() ? joinpath(outdir, "bin", basename(exeout) * ".exe") : joinpath(outdir, "bin", basename(exeout))
    @test isfile(actual_exe)

    # Test output - the program should output:
    # 1. "Hello, world!" (from OncePerProcess)
    # 2. PROGRAM_FILE (the path to the executable)
    # 3. arg1
    # 4. arg2
    # 5. The sum_areas result: 4.0 + pi = 7.141592653589793
    output = readchomp(`$actual_exe arg1 arg2`)
    lines = split(output, '\n')
    @test length(lines) >= 5
    @test lines[1] == "Hello, world!"
    @test lines[2] == actual_exe  # PROGRAM_FILE
    @test lines[3] == "arg1"
    @test lines[4] == "arg2"
    @test parse(Float64, lines[5]) ≈ (4.0 + pi)

    print_tree_with_sizes(outdir)
end

@testset "Trimming: libsimple.jl C application test" begin
    outdir = mktempdir()
    libout = joinpath(outdir, "libsimple")

    # Build the libsimple library
    img = JuliaC.ImageRecipe(
        file = joinpath(@__DIR__, "libsimple.jl"),
        output_type = "--output-lib",
        project = TEST_LIB_PROJ,
        add_ccallables = true,
        trim_mode = "safe",
        verbose = true,
    )
    JuliaC.compile_products(img)
    link = JuliaC.LinkRecipe(image_recipe=img, outname=libout)
    JuliaC.link_products(link)
    bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir)
    JuliaC.bundle_products(bun)

    # Library location differs by platform: bin/ on Windows, lib/ on Unix
    libdir = joinpath(outdir, Sys.iswindows() ? "bin" : "lib")
    libpath = joinpath(libdir, basename(libout) * "." * Base.BinaryPlatforms.platform_dlext())
    @test isfile(libpath)

    # Compile and run the C application that uses libsimple
    # Use JuliaC's compiler (MinGW on Windows, system compiler on Unix)
    bindir = joinpath(outdir, "bin")
    mkpath(bindir)
    csrc = abspath(joinpath(@__DIR__, "c", "capplication.c"))
    exe = joinpath(bindir, Sys.iswindows() ? "capplication.exe" : "capplication")
    cc = JuliaC.get_compiler_cmd()

    if Sys.islinux()
        run(`$cc -o $exe $csrc -ldl`)
    else
        run(`$cc -o $exe $csrc`)
    end

    # Run the C application
    output = readlines(`$exe $libpath`)
    @test length(output) == 2
    @test output[1] == "Sum of copied values: 6.000000"
    @test output[2] == "Count of same vectors: 1"
end
