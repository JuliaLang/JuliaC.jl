@testset "Library flows (trim)" begin
    # Build a shared library once and reuse across subtests
    img_lib = JuliaC.ImageRecipe(
        file = TEST_LIB_SRC,
        output_type = "--output-lib",
        project = TEST_LIB_PROJ,
        add_ccallables = true,
        trim_mode = "safe",
        quiet = true,
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
                run(`$cc $(cflags()) -o $exe $csrc -ldl`)
            else
                run(`$cc $(cflags()) -o $exe $csrc`)
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
            salt = JuliaC.salt_for(bun)
            JuliaC.bundle_products(bun)

            julia_dir = joinpath(outdir, "lib", "julia")
            @test isdir(julia_dir)
            dylibs = filter(f -> endswith(f, ".dylib") || endswith(f, ".so"), readdir(julia_dir; join=true))
            salted = filter(f -> occursin("_libjulia", basename(f)), dylibs)
            @test !isempty(salted)
            # The salt is stable across builds.
            @test all(f -> startswith(basename(f), salt * "_"), salted)
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
                run(`$cc $(cflags()) -o $exe $csrc -ldl`)
            else
                run(`$cc $(cflags()) -o $exe $csrc`)
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

    # https://github.com/JuliaLang/JuliaC.jl/issues/135
    @testset "Multiple extra_objects link correctly" begin
        outdir = mktempdir()
        libname = "libmultiextraobjs"
        libout = joinpath(outdir, libname)
        # Compilation deposits the object files alongside their sources, so work
        # from copies in the temporary directory to keep `test/c` clean.
        c_sources = map(["cshim_extra1.c", "cshim_extra2.c"]) do name
            cp(joinpath(@__DIR__, "c", name), joinpath(outdir, name))
        end
        img = JuliaC.ImageRecipe(
            file = TEST_LIB_SRC,
            output_type = "--output-lib",
            project = TEST_LIB_PROJ,
            add_ccallables = true,
            trim_mode = "safe",
            c_sources = c_sources,
            quiet = true,
        )
        JuliaC.compile_products(img)
        @test length(img.extra_objects) >= 2
        link = JuliaC.LinkRecipe(image_recipe=img, outname=libout, rpath=JuliaC.RPATH_BUNDLE)
        JuliaC.link_products(link)

        dlext = Base.BinaryPlatforms.platform_dlext()
        @test isfile(libout * "." * dlext)
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
            # Read PE image version directly from the optional header to avoid
            # depending on objdump being available on Windows CI.
            ver = open(libpath) do io
                seek(io, 0x3C)
                pe_offset = read(io, UInt32)
                # PE signature (4) + COFF header (20) + optional header starts here
                opt_hdr = pe_offset + 4 + 20
                seek(io, opt_hdr)
                magic = read(io, UInt16)
                # MajorImageVersion is at offset 0x2C into the optional header
                seek(io, opt_hdr + 0x2C)
                major = read(io, UInt16)
                minor = read(io, UInt16)
                (major=major, minor=minor)
            end
            @test ver.major == 32767
            @test ver.minor == 32767
        end
    end

    @testset "Windows privatization injects manifest + fixes libpath" begin
        if Sys.iswindows()
            outdir = mktempdir()
            libname = "libwinprivtest"
            libout = joinpath(outdir, libname)
            link = JuliaC.LinkRecipe(image_recipe=img_lib, outname=libout, rpath=JuliaC.RPATH_BUNDLE)
            JuliaC.link_products(link)
            bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir, privatize=true)
            JuliaC.bundle_products(bun)

            product = joinpath(outdir, "bin", libname * "." * Base.BinaryPlatforms.platform_dlext())
            @test isfile(product)

            # (a) The product PE now has a .rsrc section (read via ObjectFile, already a dep).
            rsrc_va = open(product) do io
                oh = only(JuliaC.ObjectFile.readmeta(io))
                rsrc = JuliaC.ObjectFile.findfirst(JuliaC.ObjectFile.Sections(oh), ".rsrc")
                @test rsrc !== nothing
                rsrc === nothing ? UInt32(0) : UInt32(JuliaC.ObjectFile.section_address(rsrc))
            end

            # (b) The optional header's ResourceTable data directory now points at .rsrc.
            #     Read via raw seek/read (not ObjectFile) to independently confirm the COFF
            #     patch landed.
            rt = open(product) do io
                seek(io, 0x3C); pe_off = read(io, UInt32)
                opt_hdr = pe_off + 4 + 20                 # PE sig (4) + COFF header (20)
                seek(io, opt_hdr); magic = read(io, UInt16)
                # 64-bit: standard(24) + windows64(88) = 112 to the data directories;
                # 32-bit: standard(24) + BaseOfData(4) + windows32(68) = 96.
                dd = opt_hdr + (magic == 0x20b ? 112 : 96)
                seek(io, dd + 0x10)                        # ResourceTable slot
                (va = read(io, UInt32), size = read(io, UInt32))
            end
            @test rt.va == rsrc_va
            @test rt.va != 0
            @test rt.size != 0

            # (c) The bundled loader's dependency list is intact. This bundle is trimmed, so
            #     its entry for the unshipped libjulia-codegen.dll is neutralized to a salted
            #     name that can never bind a host's loaded copy.
            libjulia = joinpath(outdir, "bin", "libjulia.dll")
            @test isfile(libjulia)
            loaderbytes = String(read(libjulia))
            @test occursin("@libjulia-internal.dll:", loaderbytes)
            @test !occursin("libjulia-codegen.dll", loaderbytes)
        end
    end

    @testset "Privatized library loads its own runtime copy (Windows)" begin
        # Asserts that dlopen'ing the product from a live Julia session makes each bundled
        # runtime DLL appear twice in Libdl.dllist(): the host Julia's copy and the bundle's
        # own. See src/privatize_windows.jl for the SxS manifest mechanism this exercises.
        #
        # Built WITHOUT --trim so all three runtime DLLs, codegen included, are bundled and
        # must each show up twice; the trimmed case is covered by the testset below.
        if Sys.iswindows()
            img_untrimmed = JuliaC.ImageRecipe(
                file = TEST_LIB_SRC,
                output_type = "--output-lib",
                project = TEST_LIB_PROJ,
                add_ccallables = true,
                quiet = true,
            )
            JuliaC.compile_products(img_untrimmed)

            outdir = mktempdir()
            libname = "libwinprivloadtest"
            link = JuliaC.LinkRecipe(image_recipe=img_untrimmed, outname=joinpath(outdir, libname),
                                     rpath=JuliaC.RPATH_BUNDLE)
            JuliaC.link_products(link)
            JuliaC.bundle_products(JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir, privatize=true))

            bindir = joinpath(outdir, "bin")
            product = joinpath(bindir, libname * "." * Base.BinaryPlatforms.platform_dlext())
            @test isfile(product)

            # The runtime DLLs the manifest redirects; each must end up loaded twice.
            bundled = JuliaC.present_libjulia_dlls(bindir)
            @test "libjulia.dll" in bundled
            @test "libjulia-codegen.dll" in bundled

            # Load the product from a fresh Julia process (which already has its own runtime
            # resident) and report dllist() before and after. Markers flush to stderr
            # immediately, so a deadlock still leaves evidence of how far it got.
            snippet = """
                using Libdl
                errln(s) = (println(stderr, s); flush(stderr))
                juliadlls() = filter(p -> startswith(lowercase(basename(p)), "libjulia"), Libdl.dllist())
                errln("M1_PRE_DLOPEN n=" * string(length(juliadlls())))
                h = Libdl.dlopen($(repr(product)), Libdl.RTLD_LOCAL)
                errln("M2_POST_DLOPEN n=" * string(length(juliadlls())))
                r = ccall(Libdl.dlsym(h, :jc_add_one), Cint, (Cint,), 41)
                errln("M3_POST_CCALL r=" * string(r))
                println("RESULT=", r)
                for p in juliadlls()
                    println("DLL=", lowercase(basename(p)), "|", lowercase(abspath(dirname(p))))
                end
                try Libdl.dlclose(h) catch end
                """
            logf = joinpath(outdir, "winload.log")
            proc = run(pipeline(`$(Base.julia_cmd()) --startup-file=no --history-file=no -e $snippet`;
                                stdout=logf, stderr=logf); wait=false)
            # Watchdog: kills the process after 180s so a loader deadlock cannot stall the
            # whole CI job.
            watchdog = Timer(180) do _
                Base.process_running(proc) && (kill(proc); @warn "Windows load test exceeded 180s; killed")
            end
            try
                wait(proc)
            finally
                close(watchdog)
            end
            out = isfile(logf) ? read(logf, String) : ""
            @info "Windows privatized-load diagnostic" output=out

            # The exported symbol resolves and runs through the privatized runtime.
            @test occursin("RESULT=42", out)

            # Group the reported runtime DLLs by filename -> set of directories holding them.
            dirs_by_dll = Dict{String,Set{String}}()
            for m in eachmatch(r"^DLL=([^|]+)\|(.+)$"m, out)
                push!(get!(Set{String}, dirs_by_dll, m.captures[1]), rstrip(m.captures[2]))
            end
            @test !isempty(dirs_by_dll)

            bundled_dir = lowercase(abspath(bindir))
            for dll in bundled
                dirs = get(dirs_by_dll, lowercase(dll), Set{String}())
                # Two copies: the host Julia's, and the product's own private one.
                @test length(dirs) >= 2
                @test bundled_dir in dirs
                # At least one copy is not ours: the host's pre-existing one.
                @test any(!=(bundled_dir), dirs)
            end
        end
    end

    @testset "Trimmed privatized library falls back to codegen stubs (Windows)" begin
        # `remove_unnecessary_libraries` strips libjulia-codegen.dll from a trimmed bundle,
        # so privatization salts the loader's codegen entry to an unresolvable name: the load
        # fails cleanly and the runtime falls back to its built-in codegen stubs. Binding the
        # host's already-loaded codegen via a bare-name LoadLibrary aborts the process in
        # jl_init_llvm ("Library already loaded").
        if Sys.iswindows()
            outdir = mktempdir()
            libname = "libwinprivtrimtest"
            link = JuliaC.LinkRecipe(image_recipe=img_lib, outname=joinpath(outdir, libname),
                                     rpath=JuliaC.RPATH_BUNDLE)
            JuliaC.link_products(link)
            JuliaC.bundle_products(JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir, privatize=true))

            bindir = joinpath(outdir, "bin")
            bundled = JuliaC.present_libjulia_dlls(bindir)
            @test "libjulia.dll" in bundled
            @test "libjulia-internal.dll" in bundled
            @test !("libjulia-codegen.dll" in bundled)

            # Loaded into a live Julia session, the trimmed product still works: private
            # copies of the shipped DLLs, no private codegen, exported symbol runs.
            product = joinpath(bindir, libname * "." * Base.BinaryPlatforms.platform_dlext())
            snippet = """
                using Libdl
                juliadlls() = filter(p -> startswith(lowercase(basename(p)), "libjulia"), Libdl.dllist())
                h = Libdl.dlopen($(repr(product)), Libdl.RTLD_LOCAL)
                r = ccall(Libdl.dlsym(h, :jc_add_one), Cint, (Cint,), 41)
                println("RESULT=", r)
                for p in juliadlls()
                    println("DLL=", lowercase(basename(p)), "|", lowercase(abspath(dirname(p))))
                end
                try Libdl.dlclose(h) catch end
                """
            logf = joinpath(outdir, "wintrimload.log")
            proc = run(pipeline(`$(Base.julia_cmd()) --startup-file=no --history-file=no -e $snippet`;
                                stdout=logf, stderr=logf); wait=false)
            watchdog = Timer(180) do _
                Base.process_running(proc) && (kill(proc); @warn "Windows trimmed load test exceeded 180s; killed")
            end
            try
                wait(proc)
            finally
                close(watchdog)
            end
            out = isfile(logf) ? read(logf, String) : ""
            @info "Windows trimmed privatized-load diagnostic" output=out

            @test success(proc)
            @test occursin("RESULT=42", out)
            dirs_by_dll = Dict{String,Set{String}}()
            for m in eachmatch(r"^DLL=([^|]+)\|(.+)$"m, out)
                push!(get!(Set{String}, dirs_by_dll, m.captures[1]), rstrip(m.captures[2]))
            end
            bundled_dir = lowercase(abspath(bindir))
            @test bundled_dir in get(dirs_by_dll, "libjulia.dll", Set{String}())
            @test bundled_dir in get(dirs_by_dll, "libjulia-internal.dll", Set{String}())
            # No private codegen exists, and the host's copy stays the only one.
            @test !(bundled_dir in get(dirs_by_dll, "libjulia-codegen.dll", Set{String}()))
        end
    end
end

@testset "Privatization salts" begin
    recipe(outname; privatize = true) = JuliaC.BundleRecipe(;
        link_recipe = JuliaC.LinkRecipe(image_recipe = JuliaC.ImageRecipe(), outname = outname),
        privatize)

    @test !JuliaC.is_privatize_enabled(JuliaC.BundleRecipe())
    @test JuliaC.is_privatize_enabled(recipe("libfoo"))

    # Build directories do not affect the salt.
    @test JuliaC.salt_for(recipe("libfoo")) == JuliaC.salt_for(recipe("libfoo"))
    @test JuliaC.salt_for(recipe(joinpath("build", "libfoo"))) == JuliaC.salt_for(recipe(joinpath("elsewhere", "libfoo")))
    # Product names affect the salt.
    @test JuliaC.salt_for(recipe("libfoo")) != JuliaC.salt_for(recipe("libbar"))

    derived = JuliaC.salt_for(recipe("libfoo"))
    @test length(derived) == JuliaC.SALT_LENGTH
    @test JuliaC.validate_salt(derived) == derived

    # Project versions affect the salt.
    project_dir = mktempdir()
    write(joinpath(project_dir, "Project.toml"), """
        name = "Foo"
        uuid = "8ba89e20-285c-5b6f-9357-94700520ee1b"
        version = "0.1.0"
        """)
    versioned = recipe("libfoo")
    versioned.link_recipe.image_recipe.instantiated_project = project_dir
    salt_v1 = JuliaC.salt_for(versioned)
    @test salt_v1 != JuliaC.salt_for(recipe("libfoo"))
    write(joinpath(project_dir, "Project.toml"), """
        name = "Foo"
        uuid = "8ba89e20-285c-5b6f-9357-94700520ee1b"
        version = "0.2.0"
        """)
    @test JuliaC.salt_for(versioned) != salt_v1

    # Explicit salts are preserved.
    @test JuliaC.salt_for(recipe("libfoo"; privatize = "Ab_9")) == "Ab_9"
    for bad in ("", "9abc", "a-b", "a b", "toolongsalt")
        @test_throws ArgumentError JuliaC.validate_salt(bad)
        @test_throws ArgumentError JuliaC.salt_for(recipe("libfoo"; privatize = bad))
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
        quiet = true,
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
        quiet = true,
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
        quiet = true,
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
        quiet = true,
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
        quiet = true,
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
        quiet = true,
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
        quiet = true,
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
        quiet = true,
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
        quiet = true,
    )
    JuliaC.compile_products(img)
    link = JuliaC.LinkRecipe(image_recipe=img, outname=libout, rpath=JuliaC.RPATH_BUNDLE)
    JuliaC.link_products(link)
    bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir)
    JuliaC.bundle_products(bun)

    dlext = Base.BinaryPlatforms.platform_dlext()
    libroot = Sys.iswindows() ? "bin" : "lib"
    libpath = joinpath(outdir, libroot, basename(libout) * "." * dlext)
    @test isfile(libpath)

    # Compile a small C driver that dlopens the library and queries jl_options
    csrc = abspath(joinpath(@__DIR__, "c", "ctest_jloptions.c"))
    bindir = joinpath(outdir, "bin")
    mkpath(bindir)
    exe = joinpath(bindir, Sys.iswindows() ? "ctest_jloptions.exe" : "ctest_jloptions")
    cc = JuliaC.get_compiler_cmd()
    if Sys.islinux()
        run(`$cc $(cflags()) -o $exe $csrc -ldl`)
    else
        run(`$cc $(cflags()) -o $exe $csrc`)
    end

    out = read(`$exe $libpath`, String)
    # JL_OPTIONS_HANDLE_SIGNALS_OFF == 0
    @test occursin("handle_signals=0", out)
    @test occursin("nthreads=1", out)
    @test occursin("nthreadpools=1", out)
end

# https://github.com/JuliaLang/JuliaC.jl/issues/124
const DEP_PROJ = abspath(joinpath(@__DIR__, "DepProject"))

@testset "Project with dependencies (no trim) (#124)" begin
    outdir = mktempdir()
    exeout = joinpath(outdir, "depproject")

    img = JuliaC.ImageRecipe(
        file = DEP_PROJ,
        output_type = "--output-exe",
        quiet = true,
    )
    JuliaC.compile_products(img)
    link = JuliaC.LinkRecipe(image_recipe=img, outname=exeout, rpath=JuliaC.RPATH_BUNDLE)
    JuliaC.link_products(link)
    bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir)
    JuliaC.bundle_products(bun)

    actual_exe = Sys.iswindows() ? joinpath(outdir, "bin", basename(exeout) * ".exe") : joinpath(outdir, "bin", basename(exeout))
    @test isfile(actual_exe)
    if isfile(actual_exe)
        output = read(`$actual_exe`, String)
        @test occursin("sha256:", output)
    end
end

@testset "Project with dependencies (trim) (#124)" begin
    outdir = mktempdir()
    exeout = joinpath(outdir, "depproject_trim")

    img = JuliaC.ImageRecipe(
        file = DEP_PROJ,
        output_type = "--output-exe",
        trim_mode = "safe",
        quiet = true,
    )
    JuliaC.compile_products(img)
    link = JuliaC.LinkRecipe(image_recipe=img, outname=exeout, rpath=JuliaC.RPATH_BUNDLE)
    JuliaC.link_products(link)
    bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir)
    JuliaC.bundle_products(bun)

    actual_exe = Sys.iswindows() ? joinpath(outdir, "bin", basename(exeout) * ".exe") : joinpath(outdir, "bin", basename(exeout))
    @test isfile(actual_exe)
    if isfile(actual_exe)
        output = read(`$actual_exe`, String)
        @test occursin("sha256:", output)
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
        quiet = true,
    )
    @test_throws ErrorException JuliaC.compile_products(img_bad)
    img = JuliaC.ImageRecipe(
        file = TEST_PROJ,
        output_type = "--output-exe",
        trim_mode = "safe",
        quiet = true,
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
end

@testset "Relative `[sources]` dep path (#153)" begin
    # Projects with relative path `[sources]` need special handling
    # by JuliaC's Project.toml logic
    relapp_proj = abspath(joinpath(@__DIR__, "RelAppProject"))
    outdir = mktempdir()
    exeout = joinpath(outdir, "relapp")

    img = JuliaC.ImageRecipe(
        file = joinpath(relapp_proj, "src", "main.jl"),
        output_type = "--output-exe",
        project = relapp_proj,
        trim_mode = "safe",
        quiet = true,
    )
    JuliaC.compile_products(img)
    link = JuliaC.LinkRecipe(image_recipe=img, outname=exeout, rpath=JuliaC.RPATH_BUNDLE)
    JuliaC.link_products(link)
    bun = JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir)
    JuliaC.bundle_products(bun)

    output_exe = if Sys.iswindows()
        joinpath(outdir, "bin", basename(exeout) * ".exe")
    else
        joinpath(outdir, "bin", basename(exeout))
    end
    @test isfile(output_exe)
    output = read(`$output_exe`, String)
    @test occursin("hello from a relative-path dependency", output)
end
