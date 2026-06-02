using RelDepProject

function @main(ARGS)
    println(Core.stdout, RelDepProject.greet())
    return 0
end
