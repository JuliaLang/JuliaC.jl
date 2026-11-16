# A package with a development-only diagnostic that cannot be trimmed, which it leaves
# out when JuliaC says it is being compiled with `--trim`.
module TrimPrefDep

using Preferences

const JULIAC_TRIM = @load_preference("juliac_trim", false)

@static if JULIAC_TRIM
    caller_name() = "trimmed"
else
    @noinline function caller_name()
        st = stacktrace(backtrace())
        return String(st[min(2, length(st))].func)
    end
end

end
