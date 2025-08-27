using Test
using JuliaC

const ROOT = abspath(joinpath(@__DIR__, ".."))
const TEST_PROJ = abspath(joinpath(@__DIR__, "app_project"))
const TEST_SRC = joinpath(TEST_PROJ, "src", "test.jl")

include("utils.jl")

@testset "Programmatic API (trim)" begin
    outdir = mktempdir()
    # Build a sysimage object file programmatically
    img = JuliaC.ImageRecipe(
        file = TEST_SRC,
        output_type = "--output-o",
        project = TEST_PROJ,
        enable_trim = true,
        trim_mode = "safe",
        verbose = true,
    )
    JuliaC.compile_products(img)
    @test isfile(img.img_path)

    # Link into a shared lib and bundle
    outname = joinpath(outdir, "app")
    link = JuliaC.LinkRecipe(image_recipe=img, outname=outname)
    JuliaC.link_products(link)
    @test isfile(startswith(outname, "/") ? outname * "." * Base.BinaryPlatforms.platform_dlext() : joinpath(dirname(outname), basename(outname) * "." * Base.BinaryPlatforms.platform_dlext())) || isfile(outname)

    bundle_dir = outdir
    bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=bundle_dir)
    JuliaC.bundle_products(bun)
    @test isdir(bundle_dir)
    # Print tree for debugging/inspection
    print_tree_with_sizes(bundle_dir)
end

@testset "Programmatic binary (trim)" begin
    outdir = mktempdir()
    exeout = joinpath(outdir, "prog_exe")
    # Build programmatically with trim
    img = JuliaC.ImageRecipe(
        file = TEST_SRC,
        output_type = "--output-exe",
        project = TEST_PROJ,
        enable_trim = true,
        trim_mode = "safe",
        verbose = true,
    )
    JuliaC.compile_products(img)
    link = JuliaC.LinkRecipe(image_recipe=img, outname=exeout, rpath=Sys.iswindows() ? "bin" : joinpath("..", "lib"))
    JuliaC.link_products(link)
    bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir)
    JuliaC.bundle_products(bun)
    actual_exe = Sys.iswindows() ? joinpath(outdir, "bin", basename(exeout) * ".exe") : joinpath(outdir, "bin", basename(exeout))
    @test isfile(actual_exe)
    output = read(`$actual_exe`, String)
    @test occursin("Fast compilation test!", output)
    # Print tree for debugging/inspection
    print_tree_with_sizes(outdir)
end

@testset "CLI app entrypoint (trim)" begin
    outdir = mktempdir()
    exename = "app_cli"
    cliargs = String[
        "--output-exe", exename,
        "--project", TEST_PROJ,
        "--trim=safe",
        TEST_SRC,
        "--bundle", outdir,
        "--verbose",
    ]
    # Invoke the module's CLI entrypoint directly to avoid any argument quoting issues
    JuliaC._main_cli(cliargs)
    # Determine actual executable path (Windows adds .exe)
    actual_exe = Sys.iswindows() ? joinpath(outdir, "bin", exename * ".exe") : joinpath(outdir, "bin", exename)
    @test isfile(actual_exe)
    # Execute the binary and capture output
    output = read(`$actual_exe`, String)
    @test occursin("Fast compilation test!", output)
    # Print tree for debugging/inspection
    print_tree_with_sizes(outdir)
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

