using Test
using JuliaC
using Libdl
using Patchelf_jll

const ROOT = abspath(joinpath(@__DIR__, ".."))
const TEST_PROJ = abspath(joinpath(@__DIR__, "app_project"))
const TEST_SRC = joinpath(TEST_PROJ, "src", "test.jl")
const TEST_LIB_PROJ = abspath(joinpath(@__DIR__, "lib_project"))
const TEST_LIB_SRC = joinpath(TEST_LIB_PROJ, "src", "libtest.jl")

include("utils.jl")

@testset "Library flows (trim)" begin
    # Build a shared library once and reuse across subtests
    img_lib = JuliaC.ImageRecipe(
        file = TEST_LIB_SRC,
        output_type = "--output-lib",
        project = TEST_LIB_PROJ,
        add_ccallables = true,
        enable_trim = true,
        trim_mode = "safe",
        verbose = true,
    )
    JuliaC.compile_products(img_lib)
    @test isfile(img_lib.img_path)

    @testset "Programmatic API (trim)" begin
        outdir = mktempdir()
        outname = joinpath(outdir, "app")
        link = JuliaC.LinkRecipe(image_recipe=img_lib, outname=outname, rpath=".")
        JuliaC.link_products(link)
        @test isfile(startswith(outname, "/") ? outname * "." * Base.BinaryPlatforms.platform_dlext() : joinpath(dirname(outname), basename(outname) * "." * Base.BinaryPlatforms.platform_dlext())) || isfile(outname)

        bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir)
        JuliaC.bundle_products(bun)
        @test isdir(outdir)

        # Verify the built library actually works by calling jc_add_one via a tiny C runner
        dlext = Base.BinaryPlatforms.platform_dlext()
        libpath = joinpath(outdir, "lib", basename(outname) * "." * dlext)
        @test isfile(libpath)
        csrc = abspath(joinpath(@__DIR__, "c", "ctest.c"))
        exe = joinpath(outdir, "ctest_progapi")
        cc = something(Sys.which("cc"), Sys.which("clang"))
        cc === nothing && error("C compiler not found")
        if Sys.islinux()
            run(`$cc -o $exe $csrc -ldl`)
        else
            run(`$cc -o $exe $csrc`)
        end
        run(`$exe $libpath`)
    end

    @testset "Privatization (Unix salted ids)" begin
        if Sys.isunix()
            outdir = mktempdir()
            libout = joinpath(outdir, "libprivtest")
            link = JuliaC.LinkRecipe(image_recipe=img_lib, outname=libout, rpath=".")
            JuliaC.link_products(link)
            bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir, privatize=true)
            JuliaC.bundle_products(bun)

            julia_dir = joinpath(outdir, "lib", "julia")
            @test isdir(julia_dir)
            dylibs = filter(f -> endswith(f, ".dylib") || endswith(f, ".so"), readdir(julia_dir; join=true))
            salted = filter(f -> occursin("_libjulia", basename(f)), dylibs)
            @test !isempty(salted)
            for f in salted
                if Sys.isapple()
                    out = read(`otool -D $(f)`, String)
                    @test occursin("@rpath/", out)
                elseif Sys.islinux()
                    out = read(`$(Patchelf_jll.patchelf()) --print-soname $(f)`, String)
                    @test occursin("_libjulia", out)
                end
            end

            dlext = Base.BinaryPlatforms.platform_dlext()
            libpath = joinpath(outdir, "lib", basename(libout) * "." * dlext)
            @test isfile(libpath)
        end
    end

    @testset "C dlopen test (Unix)" begin
        if Sys.isunix()
            outdir = mktempdir()
            libout = joinpath(outdir, "libctest")
            link = JuliaC.LinkRecipe(image_recipe=img_lib, outname=libout, rpath=".")
            JuliaC.link_products(link)
            bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir)
            JuliaC.bundle_products(bun)
            libpath = joinpath(outdir, "lib", basename(libout) * "." * Base.BinaryPlatforms.platform_dlext())
            @test isfile(libpath)

            csrc = abspath(joinpath(@__DIR__, "c", "ctest.c"))
            exe = joinpath(outdir, "ctest")
            cc = something(Sys.which("cc"), Sys.which("clang"))
            cc === nothing && error("C compiler not found")
            if Sys.islinux()
                run(`$cc -o $exe $csrc -ldl`)
            else
                run(`$cc -o $exe $csrc`)
            end
            run(`$exe $libpath`)
        end
    end

    @testset "Julia dlopen test (Unix)" begin
        if Sys.isunix()
            outdir = mktempdir()
            libout = joinpath(outdir, "libjldlopentest")
            link = JuliaC.LinkRecipe(image_recipe=img_lib, outname=libout, rpath=".")
            JuliaC.link_products(link)
            bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir, privatize=true)
            JuliaC.bundle_products(bun)

            libpath = joinpath(outdir, "lib", basename(libout) * "." * Base.BinaryPlatforms.platform_dlext())
            @test isfile(libpath)

            # Verify from a fresh Julia process that the exported function works
            lib_literal = repr(libpath)  # safe Julia string literal of the path
            julia_snippet = "using Libdl; h = Libdl.dlopen(" * lib_literal * ", Libdl.RTLD_LOCAL); try; fptr = Libdl.dlsym(h, :jc_add_one); r = ccall(fptr, Cint, (Cint,), 41); println(r); finally; try Libdl.dlclose(h) catch end; end;"
            out = read(`$(Base.julia_cmd()) --startup-file=no --history-file=no -e $julia_snippet`, String)
            @test occursin("42", out)
        end
    end
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


@testset "Suffix handling" begin
    outdir = mktempdir()
    
    # Compile once
    img = JuliaC.ImageRecipe(
        file = TEST_LIB_SRC,
        output_type = "--output-lib",
        project = TEST_LIB_PROJ,
        add_ccallables = true,
        enable_trim = true,
        trim_mode = "safe",
        verbose = false,
    )
    JuliaC.compile_products(img)

    # Test 1: No suffix provided (should add platform suffix)
    libout1 = joinpath(outdir, "mylib")
    link1 = JuliaC.LinkRecipe(image_recipe=img, outname=libout1, rpath=".")
    
    # The link_products function should modify the outname to add the correct suffix
    expected_suffix = "." * Base.BinaryPlatforms.platform_dlext()
    expected_name = libout1 * expected_suffix
    
    JuliaC.link_products(link1)
    
    # Verify the outname was corrected
    @test link1.outname == expected_name
    @test isfile(link1.outname)
    
    # Test 2: Wrong suffix provided (should error)
    if Sys.iswindows()
        wrong_ext = ".so"  # Wrong extension for Windows
    else
        wrong_ext = ".exe"  # Wrong extension for Unix
    end
    libout2 = joinpath(outdir, "mylib") * wrong_ext
    
    link2 = JuliaC.LinkRecipe(image_recipe=img, outname=libout2, rpath=".")
    
    # This should error because wrong extension was provided
    @test_throws ErrorException JuliaC.link_products(link2)
    
    # Test 3: Correct suffix provided (should not change)
    libout3 = joinpath(outdir, "mylib") * expected_suffix
    
    link3 = JuliaC.LinkRecipe(image_recipe=img, outname=libout3, rpath=".")
    
    # Store original correct name
    original_correct_name = link3.outname
    
    JuliaC.link_products(link3)
    
    # Verify the correct suffix was not changed
    @test link3.outname == original_correct_name
    @test isfile(link3.outname)
end

@testset "Object file validation" begin
    outdir = mktempdir()
    
    # Test that linking object files errors
    img = JuliaC.ImageRecipe(
        file = TEST_LIB_SRC,
        output_type = "--output-o",
        project = TEST_LIB_PROJ,
        enable_trim = true,
        trim_mode = "safe",
        verbose = false,
    )
    JuliaC.compile_products(img)
    @test isfile(img.img_path)
    
    link = JuliaC.LinkRecipe(image_recipe=img, outname=joinpath(outdir, "test.o"))
    @test_throws ErrorException JuliaC.link_products(link)
    
    # Test that bundling object files errors
    bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir)
    @test_throws ErrorException JuliaC.bundle_products(bun)
end

