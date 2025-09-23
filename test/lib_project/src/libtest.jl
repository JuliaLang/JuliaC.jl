module LibTest

Base.@ccallable function jc_add_one(x::Cint)::Cint
    # this convoluted logic is to check that we support reshape with `Colon()`,
    # which tries to `show(::IO, ::Colon)` internally and used to fail
    m = reshape([x,x,x,x], :, 2)
    return m[1,1] + 1
end

end # module

