# How JuliaC passes the CPU target to package precompilation. Each test below would have caught a
# mistake that was made, or nearly made, while getting this right.

@testset "CPU target: first_cpu_target" begin
    f = JuliaC.first_cpu_target
    # Takes the first `;`-separated target. Splitting on `,` as well dropped every feature.
    @test f("generic") == "generic"
    @test f("native") == "native"
    @test f("apple-m1,+sme,+sme2") == "apple-m1,+sme,+sme2"
    @test f("haswell,-rdrnd") == "haswell,-rdrnd"
    @test f("x86-64,sse4_2") == "x86-64,sse4_2"  # a feature without `+` is still a feature
    @test f("apple-m1,+sme;generic") == "apple-m1,+sme"
    @test f("generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)") == "generic"
    # Drops the directives that an ordinary process rejects, with any `+`/`-` prefix that Julia accepts
    @test f("generic,clone_all") == "generic"
    @test f("generic,+clone_all") == "generic"
    @test f("generic,-clone_all") == "generic"
    @test f("generic,opt_size") == "generic"
    @test f("generic,+min_size") == "generic"
    @test f("haswell,base(1)") == "haswell"
    @test f("haswell,+base(1)") == "haswell"
    @test f("apple-m1,+sme,+clone_all,base(0),-dotprod") == "apple-m1,+sme,-dotprod"
    @test f("") == ""
end

@testset "CPU target: expand_sysimage_target" begin
    e = JuliaC.expand_sysimage_target
    # Julia only expands the keyword as the first target
    @test e("sysimagefoo") == "sysimagefoo"
    @test e("generic;sysimage") == "generic;sysimage"
    @test e("native") == "native"
    if isdefined(Sys, :sysimage_target)
        target = JuliaC.default_cpu_target()
        @test e("sysimage") == target
        @test e("sysimage;neoverse-v2") == target * ";neoverse-v2"
        # Expanded before the first target is taken; otherwise the driver gets `sysimage` and
        # so every target, which an ordinary process rejects
        @test JuliaC.first_cpu_target(e("sysimage")) == JuliaC.first_cpu_target(target)
        @test !startswith(JuliaC.first_cpu_target(e("sysimage")), "sysimage")
    else
        @test e("sysimage") == "sysimage"
    end
end

# A first target with a feature that every CI machine has. Then, where memory allows, a second
# target with `clone_all`, which only an output process accepts.
const CPU_TARGET_WITH_FEATURES = Sys.ARCH === :x86_64  ? "generic,+ssse3;haswell,clone_all" :
                                 Sys.ARCH === :aarch64 ? "generic,+crc;apple-m1,clone_all"  :
                                 # Julia 1.13+ detects only baseline features on i686
                                 Sys.ARCH === :i686    ? "pentium4,+sse2"                   :
                                                         nothing

# `cpu_target` => the full target that packages should be precompiled for
const CPU_TARGET_CASES = Pair{String,String}[]
CPU_TARGET_WITH_FEATURES === nothing ||
    push!(CPU_TARGET_CASES, CPU_TARGET_WITH_FEATURES => CPU_TARGET_WITH_FEATURES)
# `sysimage` stands for every target of Julia's own image (Julia 1.13+)
isdefined(Sys, :sysimage_target) && push!(CPU_TARGET_CASES, "sysimage" => JuliaC.default_cpu_target())

@testset "CPU target: packages are precompiled for the full target ($cpu_target)" for (cpu_target, expected) in CPU_TARGET_CASES
    # Julia reuses a cache file built for another target string whenever it can load it, so a
    # cache left by an earlier run could hide a bug here. Copies at a new path start without any.
    fixtures = mktempdir()
    for name in ("CpuTargetProject", "CpuTargetDep")
        cp(joinpath(@__DIR__, name), joinpath(fixtures, name))
    end
    proj = joinpath(fixtures, "CpuTargetProject")
    dep = joinpath(fixtures, "CpuTargetDep")

    # Leave a `native` pkgimage of the dependency in the depot. A Pkg driver whose own target is
    # not the first output target (such as `native`) keeps this cache, and the precompile worker
    # and compile step reject it. The compile step then quietly recompiles from source.
    withenv("JULIA_CPU_TARGET" => nothing, "JULIA_LOAD_PATH" => nothing) do
        run(`$(Base.julia_cmd()) --startup-file=no --project=$dep -e "using CpuTargetDep"`)
    end

    outdir = mktempdir()
    exeout = joinpath(outdir, "cpu_target_app")
    img = JuliaC.ImageRecipe(
        file = proj,
        output_type = "--output-exe",
        trim_mode = "safe",
        cpu_target = cpu_target,
        quiet = true,
    )
    JuliaC.compile_products(img)
    link = JuliaC.LinkRecipe(image_recipe=img, outname=exeout)
    JuliaC.link_products(link)
    JuliaC.bundle_products(JuliaC.BundleRecipe(link_recipe=link, output_dir=outdir))

    exe = joinpath(outdir, "bin", basename(exeout) * (Sys.iswindows() ? ".exe" : ""))
    out = Dict(split(l, '=', limit=2) for l in eachline(`$exe`))
    for pkg in ("app", "dep")
        # Precompile-time code sees the full target, features and every other target included
        @test out["$(pkg)_cpu_target"] == expected
        # The pkgimage from precompilation was loaded, and not recompiled by the compile step
        @test out["$(pkg)_in_worker"] == "true"
    end
end
