# Regression tests for paths containing spaces.

@testset "Paths with spaces" begin

@testset "julia-config flags keep directories in one argument" begin
    @test "-I" * JuliaC.JuliaConfig.includeDir() in JuliaC.JuliaConfig.cflags(; framework=false)
    @test "-L" * JuliaC.JuliaConfig.libDir() in
        JuliaC.JuliaConfig.allflags(; framework=false, rpath=false)
end

@testset "rpath flags" begin
    img = JuliaC.ImageRecipe(output_type = "--output-exe")
    rpath_flags(rpath) =
        JuliaC.get_rpath(JuliaC.LinkRecipe(image_recipe = img, outname = "app", rpath = rpath))

    if Sys.iswindows()
        @test isempty(rpath_flags(JuliaC.RPATH_JULIA))
    else
        @test rpath_flags(JuliaC.RPATH_JULIA) ==
            ["-Wl,-rpath," * JuliaC.JuliaConfig.libDir(),
             "-Wl,-rpath," * JuliaC.JuliaConfig.private_libDir()]
    end
    if Sys.islinux() || Sys.isapple()
        base = Sys.isapple() ? "@loader_path" : "\$ORIGIN"
        @test rpath_flags(joinpath("..", "my libs")) ==
            ["-Wl,-rpath,$base/../my libs", "-Wl,-rpath,$base/../my libs/julia"]
    end
end

@testset "JULIA_CC with a quoted path containing spaces" begin
    # Parsed like `CC`: the path must be quoted.
    cc = joinpath(tempdir(), "my compiler", "cc")
    withenv("JULIA_CC" => Base.shell_escape(cc) * " --flag") do
        @test JuliaC.get_compiler_cmd().exec == [cc, "--flag"]
    end
end

@testset "C shim compile command keeps user flags intact" begin
    # The reported failure: with `cflags = ["-I", dir]`, `dir` used to be split
    # on its spaces into several arguments.
    incdir = joinpath(tempdir(), "my includes")
    img = JuliaC.ImageRecipe(cflags = ["-I", incdir, "-DGREETING=\"hello world\""])
    args = JuliaC.c_shim_compile_cmd(img, "shim.c", "shim.o").exec
    i = findfirst(==("-I"), args)
    @test i !== nothing && args[i + 1] == incdir
    @test "-DGREETING=\"hello world\"" in args
    @test "-I" * JuliaC.JuliaConfig.includeDir() in args
    @test args[end-3:end] == ["-c", "shim.c", "-o", "shim.o"]
end

@testset "C shim with an include directory containing spaces" begin
    workdir = mktempdir()
    incdir = joinpath(workdir, "my includes")
    mkpath(incdir)
    write(joinpath(incdir, "juliac_spaced_header.h"), "#define JULIAC_SPACED_HEADER 1\n")
    csrc = joinpath(workdir, "cshim_spaced.c")
    write(csrc, """
    #include "juliac_spaced_header.h"
    #ifndef JULIAC_SPACED_HEADER
    #error "header from the spaced include directory was not found"
    #endif
    int juliac_spaced_shim(void) { return 42; }
    """)
    img = JuliaC.ImageRecipe(
        file = TEST_LIB_SRC,
        output_type = "--output-lib",
        project = TEST_LIB_PROJ,
        add_ccallables = true,
        trim_mode = "safe",
        c_sources = [csrc],
        cflags = ["-I", incdir],
        quiet = true,
    )
    JuliaC.compile_products(img)
    @test isfile(replace(csrc, ".c" => ".o"))
end

@testset "otool -L install names with spaces" begin
    thin = """
    /Users/john doe/lib/libfoo.dylib:
    \t@rpath/my libs/libjulia.1.12.dylib (compatibility version 1.0.0, current version 1.12.0)
    \t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1345.0.0)
    """
    @test JuliaC.parse_otool_deps(thin) ==
        ["@rpath/my libs/libjulia.1.12.dylib", "/usr/lib/libSystem.B.dylib"]

    # Fat binaries print a header per architecture.
    fat = """
    /Users/john doe/lib/libfoo.dylib (architecture x86_64):
    \t@rpath/my libs (old)/libjulia.1.12.dylib (compatibility version 1.0.0, current version 1.12.0)
    /Users/john doe/lib/libfoo.dylib (architecture arm64):
    \t@rpath/my libs (old)/libjulia.1.12.dylib (compatibility version 1.0.0, current version 1.12.0)
    """
    @test JuliaC.parse_otool_deps(fat) ==
        fill("@rpath/my libs (old)/libjulia.1.12.dylib", 2)
end

@testset "CLI build from and into directories with spaces" begin
    base = mktempdir()
    projdir = joinpath(base, "my projects", "AppProject")
    mkpath(dirname(projdir))
    cp(TEST_PROJ, projdir)
    outdir = joinpath(base, "out dir")
    exename = "app"
    run_juliac_cli(String[
        "--output-exe", exename,
        "--trim=safe",
        projdir,
        "--bundle", outdir,
        "--quiet",
    ])
    actual_exe = Sys.iswindows() ? joinpath(outdir, "bin", exename * ".exe") :
                                   joinpath(outdir, "bin", exename)
    @test isfile(actual_exe)
    if isfile(actual_exe)
        @test occursin("Fast compilation test!", read(`$actual_exe`, String))
    end
end

end
