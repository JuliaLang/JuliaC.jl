module TinyLibm

import Base: @ccallable

@ccallable sin(x::Float64)::Float64 = Base.sin(x)
@ccallable sinf(x::Float32)::Float32 = Base.sin(x)
@ccallable cos(x::Float64)::Float64 = Base.cos(x)
@ccallable cosf(x::Float32)::Float32 = Base.cos(x)

end
