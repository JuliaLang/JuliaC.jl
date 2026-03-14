module MathApp

function (@main)(args)
    # Use a transcendental math function to exercise libm linking.
    # With --cpu-target=generic, LLVM emits calls to libm symbols (e.g. sin)
    # that must be resolved at link time via -lm.
    # The argument must be a runtime value to prevent LLVM from constant-folding the call.
    x = parse(Float64, get(args, 1, "1.0"))
    println(Core.stdout, "sin(", x, ") = ", sin(x))
    return 0
end

end
