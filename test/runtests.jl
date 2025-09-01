using Test
using JuliaC
using Libdl
using Patchelf_jll

const ROOT = abspath(joinpath(@__DIR__, ".."))
const TEST_PROJ = abspath(joinpath(@__DIR__, "app_project"))
const TEST_SRC = joinpath(TEST_PROJ, "src", "test.jl")
const TEST_LIB_PROJ = abspath(joinpath(@__DIR__, "lib_project"))
const TEST_LIB_SRC = joinpath(TEST_LIB_PROJ, "src", "libtest.jl")

include("utils.jl")
include("programatic.jl")
include("cli.jl")
