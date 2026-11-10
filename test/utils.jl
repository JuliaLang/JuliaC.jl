cflags() = JuliaC.JuliaConfig.march_flags()

# dlopen `product` in a fresh Julia process, whose own runtime is already resident, and call
# its `jc_add_one`. Returns the process, its combined output, and for each loaded
# libjulia*/libLLVM* library (lowercased basename) the set of directories it is loaded from.
function load_in_julia_process(product)
    snippet = """
        using Libdl
        h = Libdl.dlopen($(repr(product)), Libdl.RTLD_LOCAL)
        println("RESULT=", ccall(Libdl.dlsym(h, :jc_add_one), Cint, (Cint,), 41))
        for p in Libdl.dllist()
            b = lowercase(basename(p))
            (startswith(b, "libjulia") || startswith(b, "libllvm")) &&
                println("DLL=", b, "|", lowercase(abspath(dirname(p))))
        end
        try Libdl.dlclose(h) catch end
        """
    logf = tempname()
    # One handle for both streams: they share a file offset instead of overwriting each other.
    proc = open(logf, "w") do io
        p = run(pipeline(`$(Base.julia_cmd()) --startup-file=no -e $snippet`; stdout=io, stderr=io); wait=false)
        # A loader deadlock must not stall the CI job.
        timedwait(() -> process_exited(p), 180) === :ok || kill(p)
        wait(p)
        p
    end
    output = read(logf, String)
    dirs_by_dll = Dict{String,Set{String}}()
    for m in eachmatch(r"^DLL=([^|]+)\|(.+)$"m, output)
        push!(get!(Set{String}, dirs_by_dll, m.captures[1]), rstrip(m.captures[2]))
    end
    return (; proc, output, dirs_by_dll)
end
