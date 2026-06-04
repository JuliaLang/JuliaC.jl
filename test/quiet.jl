# Tests for `--quiet`: a successful build must print nothing and exit 0, while a
# failing build must still surface the underlying error output (including the
# `--trim` verifier errors) so failures are never silently swallowed.

# Run the juliac CLI in a subprocess, capturing stdout, stderr and exit code.
function run_juliac_capture(args::Vector{String}; dir=nothing)
    cmd = `$(Base.julia_cmd()) --startup-file=no --history-file=no --project=$(ROOT) -m JuliaC $args`
    cmd = ignorestatus(dir === nothing ? cmd : Cmd(cmd; dir=dir))
    out, err = IOBuffer(), IOBuffer()
    p = run(pipeline(cmd; stdout=out, stderr=err))
    return (; code=p.exitcode, out=String(take!(out)), err=String(take!(err)))
end

@testset "Quiet mode" begin
    # Warm up package precompilation so the build subprocesses below don't emit
    # "Precompiling packages..." to stderr and trip the silence assertions.
    run(pipeline(`$(Base.julia_cmd()) --startup-file=no --history-file=no --project=$(ROOT) -e "using JuliaC"`;
                 stdout=devnull, stderr=devnull))

    @testset "successful build is silent and exits 0" begin
        outdir = mktempdir()
        exename = "app_quiet"
        result = run_juliac_capture(String[
            "--output-exe", exename,
            "--trim=safe",
            TEST_PROJ,
            "--bundle", outdir,
            "--quiet",
        ])
        @test result.code == 0
        @test isempty(result.out)
        @test isempty(result.err)

        # The build should still have produced a working executable.
        actual_exe = Sys.iswindows() ? joinpath(outdir, "bin", exename * ".exe") : joinpath(outdir, "bin", exename)
        @test isfile(actual_exe)
        @test occursin("Fast compilation test!", read(`$actual_exe`, String))
    end

    @testset "build errors are still reported" begin
        outdir = mktempdir()
        # `untrimmable.jl` performs a dynamic dispatch the `--trim` verifier
        # cannot resolve, so the build is expected to fail.
        result = run_juliac_capture(String[
            "--output-exe", "app_quiet_err",
            "--trim=safe",
            joinpath(@__DIR__, "untrimmable.jl"),
            "--project", TEST_PROJ,
            "--bundle", outdir,
            "--quiet",
        ])
        @test result.code != 0

        # Even in quiet mode the underlying `--trim` errors and the failure
        # summary must reach the user.
        combined = result.out * result.err
        @test occursin("unresolved call", combined)
        @test occursin("Trim verify finished", combined)
        @test occursin("Failed to compile", combined)
    end
end
