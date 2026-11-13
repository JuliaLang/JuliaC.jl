using JuliaLibWrapping

name = ARGS[1]
dest = CProject(".", name)
abi = import_abi_info(name * ".json")
wrapper(dest, abi)
