module CpuTargetProject

using CpuTargetDep

# See `CpuTargetDep` for what these record
const CPU_TARGET = unsafe_string(Base.JLOptions().cpu_target)
const IN_WORKER = Base.JLOptions().incremental != 0

function @main(args::Vector{String})::Cint
    println(Core.stdout, "app_cpu_target=", CPU_TARGET)
    println(Core.stdout, "app_in_worker=", IN_WORKER)
    println(Core.stdout, "dep_cpu_target=", CpuTargetDep.CPU_TARGET)
    println(Core.stdout, "dep_in_worker=", CpuTargetDep.IN_WORKER)
    return 0
end

end # module CpuTargetProject
