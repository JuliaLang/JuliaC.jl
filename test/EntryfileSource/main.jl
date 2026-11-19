using EntryfileProject

function @main(ARGS)
    println(Core.stdout, EntryfileProject.greet())
    return 0
end
