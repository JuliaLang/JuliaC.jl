# Regression tests for paths containing spaces (and other characters that are
# significant to `Base.shell_split`, used to parse flag strings back into args).

@testset "Paths with spaces" begin

@testset "shell_escape round-trips awkward paths" begin
    paths = [
        "/plain/path",
        "/home/john doe/julia/lib",
        "/home/it's mine/julia/lib",
        raw"C:\Program Files\Julia-1.12\include\julia",
    ]
    for p in paths
        @test Base.shell_split(JuliaC.JuliaConfig.shell_escape(p)) == [p]
    end
end

@testset "julia-config flags survive the shell_split round-trip" begin
    # Separate tokens, with the (possibly space-containing) directories intact.
    for flags in (JuliaC.JuliaConfig.cflags(; framework=false),
                  JuliaC.JuliaConfig.allflags(; framework=false, rpath=false))
        tokens = Base.shell_split(flags)
        @test !isempty(tokens)
        for t in tokens
            @test startswith(t, "-")
        end
        incdir = JuliaC.JuliaConfig.includeDir()
        @test "-I" * incdir in tokens
    end
end

@testset "rpath flags keep space-containing paths in one token" begin
    img = JuliaC.ImageRecipe(output_type = "--output-exe")

    if !Sys.iswindows()
        link = JuliaC.LinkRecipe(image_recipe = img, outname = "app",
                                 rpath = JuliaC.RPATH_JULIA)
        @test Base.shell_split(JuliaC.get_rpath(link)) ==
            ["-Wl,-rpath," * JuliaC.JuliaConfig.libDir(),
             "-Wl,-rpath," * JuliaC.JuliaConfig.private_libDir()]
    end

    if Sys.isunix()
        # A custom rpath with a space must stay a single linker argument.
        link = JuliaC.LinkRecipe(image_recipe = img, outname = "app",
                                 rpath = joinpath("..", "my libs"))
        tokens = Base.shell_split(JuliaC.get_rpath(link))
        @test length(tokens) == 2
        @test endswith(tokens[1], joinpath("..", "my libs"))
        @test endswith(tokens[2], joinpath("..", "my libs", "julia"))
    end
end

@testset "JULIA_CC pointing at a path with spaces" begin
    mktempdir() do dir
        ccdir = joinpath(dir, "my compiler")
        mkpath(ccdir)
        cc = joinpath(ccdir, Sys.iswindows() ? "cc.bat" : "cc")
        touch(cc)
        @test JuliaC.parse_compiler_env(cc).exec == [cc]
        withenv("JULIA_CC" => cc) do
            @test JuliaC.get_compiler_cmd().exec == [cc]
        end
    end
    # Values that are not a path are still parsed as a command line.
    @test JuliaC.parse_compiler_env("ccache gcc").exec == ["ccache", "gcc"]
end

@testset "user compiler flags are passed through verbatim" begin
    # The reported failure: with `-I` and the directory as two entries, the
    # directory used to be split on its spaces into several arguments.
    flags = ["-I", raw"C:\Program Files\Julia-1.12\include\julia",
             "-I/my dir/include", "-isystem/my dir/include",
             "-DGREETING=\"hello world\""]
    @test JuliaC.normalize_user_flags(flags) == flags
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
    out = """
    /Users/john doe/build/lib/libfoo.dylib:
    \t@rpath/my libs/libjulia.1.12.dylib (compatibility version 1.0.0, current version 1.12.0)
    \t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1345.0.0)
    """
    @test JuliaC.parse_otool_deps(out) ==
        ["@rpath/my libs/libjulia.1.12.dylib", "/usr/lib/libSystem.B.dylib"]
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
