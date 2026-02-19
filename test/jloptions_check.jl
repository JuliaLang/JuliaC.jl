function @main(ARGS)
    opts = Base.JLOptions()
    println(Core.stdout, "handle_signals=", opts.handle_signals)
    println(Core.stdout, "nthreads=", opts.nthreads)
    println(Core.stdout, "nthreadpools=", opts.nthreadpools)
    return 0
end
