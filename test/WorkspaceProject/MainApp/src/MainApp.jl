module MainApp

using WsDep

function (@main)(ARGS)
    println(Core.stdout, WsDep.greet())
    return 0
end

end
