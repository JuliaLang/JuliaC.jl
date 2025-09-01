module LibTest

Base.@ccallable function jc_add_one(x::Cint)::Cint
    return x + 1
end

end # module

