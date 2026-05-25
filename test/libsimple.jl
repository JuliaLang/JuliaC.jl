module SimpleLib
# Test the logging of entrypoints and types in a C-callable Julia library.

struct CVector{T}
    length::Cint
    data::Ptr{T}
end

struct CVectorPair{T}
    from::CVector{T}
    to::CVector{T}
end

struct MyTwoVec
    x::Int32
    y::Int32
end

struct CTree{T}
    # test that recursive datatypes work as expected
    children::CVector{CTree{T}}
end

Base.@ccallable "tree_size" function size(tree::CTree{Float64})::Int64
    children = unsafe_wrap(Array, tree.children.data, tree.children.length)
    # Return the size of this sub-tree
    return sum(Int64[
        size(child)
        for child in children
    ]; init=1)
end

Base.@ccallable "copyto_and_sum" function badname(fromto::CVectorPair{Float32})::Float32
    from, to = unsafe_wrap(Array, fromto.from.data, fromto.from.length), unsafe_wrap(Array, fromto.to.data, fromto.to.length)
    copyto!(to, from)
    return sum(to)
end

struct CBuf4
    data::NTuple{4, Float64}
end

Base.@ccallable "first_elt" function first_elt(buf::Ptr{CBuf4})::Float64
    return unsafe_load(buf).data[1]
end

# Parametric struct with an `Int` (non-type) parameter — mirrors JLWInterop's
# `CArray{T,N}`. Exercises that `recursively_add_types!` does not stumble
# over `T.parameters` entries that are not `DataType`s.
struct CArrayN{T, N}
    dims::NTuple{N, Int32}
    data::Ptr{T}
end

Base.@ccallable "carray3d_sum" function carray3d_sum(a::CArrayN{Float64, 3})::Float64
    n = Int(a.dims[1]) * Int(a.dims[2]) * Int(a.dims[3])
    s = 0.0
    for i in 1:n
        s += unsafe_load(a.data, i)
    end
    return s
end

Base.@ccallable function countsame(list::Ptr{MyTwoVec}, n::Int32)::Int32
    list = unsafe_wrap(Array, list, n)
    count = 0
    for v in list
        count += v.x == v.y
    end
    return count
end

export countsame, copyto_and_sum

# FIXME? varargs
# Base.@ccallable function printints(x::Cint...)::Nothing
#     for i in 1:length(x)
#         print(x[i], " ")
#     end
#     println()
# end

end
