# Test that various constructs support trimming
module TrimmabilityProject

using HostCPUFeatures
using Sockets

world::String = "world!"
const str = OncePerProcess{String}() do
    return "Hello, " * world
end

# Concrete type dispatch (no abstract types)
struct Square
    side::Float64
end
struct Circle
    radius::Float64
end
area(s::Square) = s.side^2
area(c::Circle) = pi*c.radius^2

function @main(args::Vector{String})::Cint
    println(Core.stdout, str())
    println(Core.stdout, PROGRAM_FILE)
    foreach(x->println(Core.stdout, x), args)

    # test concrete type dispatch (not abstract type dispatch)
    println(Core.stdout, area(Circle(1)) + area(Square(2)))

    arr = rand(10)
    sorted_arr = sort(arr)
    tot = sum(sorted_arr)
    tot = prod(sorted_arr)
    a = any(x -> x > 0, sorted_arr)
    b = all(x -> x >= 0, sorted_arr)
    c = map(x -> x^2, sorted_arr)
    d = mapreduce(x -> x^2, +, sorted_arr)
    # e = reduce(xor, rand(Int, 10))

    try
        sock = connect("localhost", 4900)
        if isopen(sock)
            write(sock, "Hello")
            flush(sock)
            close(sock)
        end
    catch
    end

    Base.donotdelete(reshape([1,2,3],:,1,1))

    return 0
end

end
