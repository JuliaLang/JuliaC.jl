module CpuTargetDep

# Recorded while this package is precompiled. The CPU target is the one that precompile-time code
# sees. `incremental` is set in a precompile worker, but not in the compile step, which only
# loads this package from source when it rejects the pkgimage.
const CPU_TARGET = unsafe_string(Base.JLOptions().cpu_target)
const IN_WORKER = Base.JLOptions().incremental != 0

end # module CpuTargetDep
