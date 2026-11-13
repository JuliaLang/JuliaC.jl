module HelloApp

function @main(args::Vector{String})
    println(Core.stdout, "Hello, world!")
    return 0
end

end
