module DepProject

using SHA

function @main(ARGS)
    h = bytes2hex(sha256("hello"))
    println(Core.stdout, "sha256: ", h)
    return 0
end

end
