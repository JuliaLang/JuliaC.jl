@testset "Library flows (trim)" begin
    # Build a shared library once and reuse across subtests
    img_lib = JuliaC.ImageRecipe(
        file = TEST_LIB_SRC,
        output_type = "--output-lib",
        project = TEST_LIB_PROJ,
        add_ccallables = true,
        trim_mode = "safe",
        verbose = true,
    )
    JuliaC.compile_products(img_lib)
    @test isfile(img_lib.img_path)

    @testset "Programmatic API (trim)" begin
        outdir = mktempdir()
        outname = joinpath(outdir, "lib")
        link = JuliaC.LinkRecipe(image_recipe=img_lib, outname=outname, rpath=JuliaC.RPATH_BUNDLE)
        JuliaC.link_products(link)
        @test isfile(startswith(outname, "/") ? outname * "." * Base.BinaryPlatforms.platform_dlext() : joinpath(dirname(outname), basename(outname) * "." * Base.BinaryPlatforms.platform_dlext())) || isfile(outname)

        bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir)
        JuliaC.bundle_products(bun)
        @test isdir(outdir)

        # Verify the built library exists, accounting for Windows bundle layout
        dlext = Base.BinaryPlatforms.platform_dlext()
        libroot = Sys.iswindows() ? "bin" : "lib"
        libpath = joinpath(outdir, libroot, basename(outname) * "." * dlext)
        @test isfile(libpath)
        # Run the tiny C runner only on Unix (Windows lacks dlfcn.h and cc by default)
        if Sys.isunix()
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
    end

    @testset "Privatization (Unix salted ids)" begin
        if Sys.isunix()
            outdir = mktempdir()
            libout = joinpath(outdir, "libprivtest")
            link = JuliaC.LinkRecipe(image_recipe=img_lib, outname=libout, rpath=JuliaC.RPATH_BUNDLE)
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
                elseif Sys.islinux()
                    out = read(`$(Patchelf_jll.patchelf()) --print-soname $(f)`, String)
                end
                @test occursin("_libjulia", out)
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
            link = JuliaC.LinkRecipe(image_recipe=img_lib, outname=libout, rpath=JuliaC.RPATH_BUNDLE)
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
            link = JuliaC.LinkRecipe(image_recipe=img_lib, outname=libout, rpath=JuliaC.RPATH_BUNDLE)
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

    # https://github.com/JuliaLang/JuliaC.jl/pull/74
    @testset "Library has SONAME (Linux)" begin
        if Sys.islinux()
            outdir = mktempdir()
            libname = "libhassonametest"
            libout = joinpath(outdir, libname)
            link = JuliaC.LinkRecipe(image_recipe=img_lib, outname=libout, rpath=JuliaC.RPATH_BUNDLE)
            JuliaC.link_products(link)
            bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir)
            JuliaC.bundle_products(bun)

            soname = libname * "." * Base.BinaryPlatforms.platform_dlext()
            libpath = joinpath(outdir, "lib", soname)
            actual_soname = readchomp(`$(Patchelf_jll.patchelf()) --print-soname $(libpath)`)
            @test actual_soname == soname
        end
    end

    # https://github.com/JuliaLang/JuliaC.jl/pull/74
    @testset "Library has install_name (MacOS)" begin
        if Sys.isapple()
            outdir = mktempdir()
            libname = "libhasinstallnametest"
            libout = joinpath(outdir, libname)
            link = JuliaC.LinkRecipe(image_recipe=img_lib, outname=libout, rpath=JuliaC.RPATH_BUNDLE)
            JuliaC.link_products(link)
            bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir)
            JuliaC.bundle_products(bun)

            dylibname = libname * "." * Base.BinaryPlatforms.platform_dlext()
            libpath = joinpath(outdir, "lib", dylibname)
            # otool -D prints filename on first line, install_name on second
            install_name = split(readchomp(`otool -D $(libpath)`), '\n')[end]
            @test install_name == "@rpath/$(dylibname)"
        end
    end

    # https://github.com/JuliaLang/JuliaC.jl/pull/74
    @testset "Library has import library (Windows)" begin
        if Sys.iswindows()
            outdir = mktempdir()
            libname = "libhasimplibtest"
            libout = joinpath(outdir, libname)
            link = JuliaC.LinkRecipe(image_recipe=img_lib, outname=libout, rpath=JuliaC.RPATH_BUNDLE)
            JuliaC.link_products(link)
            bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir)
            JuliaC.bundle_products(bun)

            implibpath = joinpath(outdir, libname * ".dll.a")
            @test isfile(implibpath)
        end
    end

    # https://github.com/JuliaLang/JuliaC.jl/pull/69
    @testset "`ld_flags` passes flags to compiler (Linux + MacOS)" begin
        if Sys.islinux() || Sys.isapple() 
            outdir = mktempdir()
            libname = "libhasdebugtest"
            libout = joinpath(outdir, libname)
            rpath = "this/tests/ld/flags/"
            link = JuliaC.LinkRecipe(
                image_recipe=img_lib,
                outname=libout,
                ld_flags=["-Wl,-rpath,$(rpath)"]
            )
            JuliaC.link_products(link)
            bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir)
            JuliaC.bundle_products(bun)

            libfile_name = libname * "." * Base.BinaryPlatforms.platform_dlext()
            libpath = joinpath(outdir, "lib", libfile_name)
            output = if Sys.islinux()
                readchomp(`$(Patchelf_jll.patchelf()) --print-rpath $(libpath)`)
            else
                output = readchomp(`otool -l $(libpath)`)
            end
            @test occursin(rpath, output)
        end
    end

    # https://github.com/JuliaLang/JuliaC.jl/pull/69
    @testset "`ld_flags` passes flags to compiler (Windows)" begin
        if Sys.iswindows()
            outdir = mktempdir()
            libname = "libhasdebugtest"
            libout = joinpath(outdir, libname)
            link = JuliaC.LinkRecipe(
                image_recipe=img_lib,
                outname=libout,
                ld_flags=[
                    "-Wl,--major-image-version,32767",
                    "-Wl,--minor-image-version,32767"
                ]
            )
            JuliaC.link_products(link)
            bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir)
            JuliaC.bundle_products(bun)

            libfile_name = libname * "." * Base.BinaryPlatforms.platform_dlext()
            libpath = joinpath(outdir, "bin", libfile_name)
            output = read(`objdump -p $(libpath)`, String)
            @test occursin(r"MajorImageVersion\s+32767", output)
            @test occursin(r"MinorImageVersion\s+32767", output)
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
        trim_mode = "safe",
        verbose = true,
    )
    JuliaC.compile_products(img)
    link = JuliaC.LinkRecipe(image_recipe=img, outname=exeout, rpath=JuliaC.RPATH_BUNDLE)
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

@testset "Suffix handling" begin
    outdir = mktempdir()

    # Compile once
    img = JuliaC.ImageRecipe(
        file = TEST_LIB_SRC,
        output_type = "--output-lib",
        project = TEST_LIB_PROJ,
        add_ccallables = true,
        trim_mode = "safe",
        verbose = false,
    )
    JuliaC.compile_products(img)

    # Test 1: No suffix provided (should add platform suffix)
    libout1 = joinpath(outdir, "mylib")
    link1 = JuliaC.LinkRecipe(image_recipe=img, outname=libout1)

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

    link2 = JuliaC.LinkRecipe(image_recipe=img, outname=libout2)

    # This should error because wrong extension was provided
    @test_throws ErrorException JuliaC.link_products(link2)

    # Test 3: Correct suffix provided (should not change)
    libout3 = joinpath(outdir, "mylib") * expected_suffix

    link3 = JuliaC.LinkRecipe(image_recipe=img, outname=libout3)

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

@testset "jl_options defaults for libraries" begin
    # --output-lib should auto-populate jl_options when empty
    img = JuliaC.ImageRecipe(
        file = TEST_LIB_SRC,
        output_type = "--output-lib",
        project = TEST_LIB_PROJ,
        trim_mode = "safe",
        verbose = false,
    )
    @test isempty(img.jl_options)
    JuliaC.compile_products(img)
    @test img.jl_options["handle-signals"] == "no"
    @test img.jl_options["threads"] == "1"

    # User-provided jl_options should not be overwritten, other defaults still applied
    img2 = JuliaC.ImageRecipe(
        file = TEST_LIB_SRC,
        output_type = "--output-lib",
        project = TEST_LIB_PROJ,
        trim_mode = "safe",
        verbose = false,
        jl_options = Dict("handle-signals" => "yes"),
    )
    JuliaC.compile_products(img2)
    @test img2.jl_options["handle-signals"] == "yes"
    @test img2.jl_options["threads"] == "1"  # default still applied

    # --output-exe should not auto-populate jl_options
    img3 = JuliaC.ImageRecipe(
        file = TEST_SRC,
        output_type = "--output-exe",
        project = TEST_PROJ,
        trim_mode = "safe",
        verbose = false,
    )
    JuliaC.compile_products(img3)
    @test isempty(img3.jl_options)
end

@testset "jl_options validation" begin
    # Unknown option name should error
    img = JuliaC.ImageRecipe(
        file = TEST_LIB_SRC,
        output_type = "--output-lib",
        project = TEST_LIB_PROJ,
        trim_mode = "safe",
        jl_options = Dict("bogus_field" => "42"),
    )
    @test_throws ErrorException JuliaC.compile_products(img)

    # Unsupported (but real struct field) should also error
    @test_throws ErrorException JuliaC._validate_jl_options(Dict("opt_level" => "2"))

    # Supported options should pass validation
    JuliaC._validate_jl_options(Dict("handle-signals" => "no"))
    JuliaC._validate_jl_options(Dict("threads" => "1"))
end

@testset "jl_options applied at runtime" begin
    # Compile an executable with --jl-option and verify the options take effect
    jlopts_src = joinpath(@__DIR__, "jloptions_check.jl")
    outdir = mktempdir()
    exeout = joinpath(outdir, "jlopts_exe")
    img = JuliaC.ImageRecipe(
        file = jlopts_src,
        output_type = "--output-exe",
        project = TEST_PROJ,
        trim_mode = "safe",
        verbose = true,
        jl_options = Dict(
            "handle-signals" => "no",
            "threads" => "1",
        ),
    )
    JuliaC.compile_products(img)
    link = JuliaC.LinkRecipe(image_recipe=img, outname=exeout, rpath=JuliaC.RPATH_BUNDLE)
    JuliaC.link_products(link)
    bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir)
    JuliaC.bundle_products(bun)
    actual_exe = Sys.iswindows() ? joinpath(outdir, "bin", basename(exeout) * ".exe") : joinpath(outdir, "bin", basename(exeout))
    @test isfile(actual_exe)
    output = read(`$actual_exe`, String)
    # JL_OPTIONS_HANDLE_SIGNALS_OFF == 0
    @test occursin("handle_signals=0", output)
    @test occursin("nthreads=1", output)
    @test occursin("nthreadpools=1", output)
end

@testset "jl_options applied at runtime (library)" begin
    if Sys.isunix()
        jlopts_lib_src = joinpath(@__DIR__, "lib_jloptions_check.jl")
        outdir = mktempdir()
        libout = joinpath(outdir, "libjloptscheck")
        # Compile as library — auto-populates handle-signals and threads defaults
        img = JuliaC.ImageRecipe(
            file = jlopts_lib_src,
            output_type = "--output-lib",
            project = TEST_LIB_PROJ,
            add_ccallables = true,
            trim_mode = "safe",
            verbose = true,
        )
        JuliaC.compile_products(img)
        link = JuliaC.LinkRecipe(image_recipe=img, outname=libout, rpath=JuliaC.RPATH_BUNDLE)
        JuliaC.link_products(link)
        bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir, privatize=true)
        JuliaC.bundle_products(bun)

        dlext = Base.BinaryPlatforms.platform_dlext()
        libpath = joinpath(outdir, "lib", basename(libout) * "." * dlext)
        @test isfile(libpath)

        # dlopen from a fresh Julia process and call the exported functions
        lib_literal = repr(libpath)
        julia_snippet = """
            using Libdl
            h = Libdl.dlopen($lib_literal, Libdl.RTLD_LOCAL)
            try
                hs = ccall(Libdl.dlsym(h, :jc_get_handle_signals), Cint, ())
                nt = ccall(Libdl.dlsym(h, :jc_get_nthreads), Cint, ())
                np = ccall(Libdl.dlsym(h, :jc_get_nthreadpools), Cint, ())
                println("handle_signals=", hs)
                println("nthreads=", nt)
                println("nthreadpools=", np)
            finally
                try Libdl.dlclose(h) catch end
            end
        """
        out = read(`$(Base.julia_cmd()) --startup-file=no --history-file=no -e $julia_snippet`, String)
        # JL_OPTIONS_HANDLE_SIGNALS_OFF == 0
        @test occursin("handle_signals=0", out)
        @test occursin("nthreads=1", out)
        @test occursin("nthreadpools=1", out)
    end
end

@testset "Project as File" begin
    outdir = mktempdir()
    exeout = joinpath(outdir, "prog_exe_projfile")

    # Passing the project as a file and a project should error
    img_bad = JuliaC.ImageRecipe(
        file = TEST_PROJ,
        output_type = "--output-exe",
        project = TEST_PROJ,  # Invalid, should be a directory
        trim_mode = "safe",
        verbose = true,
    )
    @test_throws ErrorException JuliaC.compile_products(img_bad)
    img = JuliaC.ImageRecipe(
        file = TEST_PROJ,
        output_type = "--output-exe",
        trim_mode = "safe",
        verbose = true,
    )
    JuliaC.compile_products(img)
    link = JuliaC.LinkRecipe(image_recipe=img, outname=exeout, rpath=JuliaC.RPATH_BUNDLE)
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
