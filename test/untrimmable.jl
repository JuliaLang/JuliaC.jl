# A deliberately untrimmable entrypoint: it performs a dynamic dispatch through
# an inference barrier that the `--trim` verifier cannot resolve, so building
# this with `--trim=safe` is expected to fail. Used to check that `--quiet`
# still surfaces `--trim` errors when a build fails.
function @main(ARGS)
    x = Base.inferencebarrier(1)
    println(Core.stdout, x + x)
    return 0
end
