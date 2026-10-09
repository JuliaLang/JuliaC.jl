# Julia 1.14 lists the libraries its runtime needs; older versions use
# `runtime_libraries_compat.jl`. The Base functions are internal, so check for them rather
# than for a version.

const _JULIA_DECLARES_RUNTIME_LIBRARIES = isdefined(Base.Linking, :runtime_libraries)

@static if !_JULIA_DECLARES_RUNTIME_LIBRARIES
    include("runtime_libraries_compat.jl")
end

# shared library directory (`bin` on Windows, `lib` elsewhere) and private library directory
julia_shlibdir() = JuliaConfig.libDir()
julia_private_shlibdir() = JuliaConfig.private_libDir()

"""
    runtime_libraries(; codegen::Bool=true) -> Vector{String}

Paths of the shared libraries, including version symlinks, that a program embedding this
Julia's runtime needs. `codegen=false` (for `--trim`) leaves out `libjulia-codegen` and LLVM.
"""
function runtime_libraries(; codegen::Bool=true)
    @static if _JULIA_DECLARES_RUNTIME_LIBRARIES
        components = codegen ? Base.Linking.DEFAULT_COMPONENTS :
                               filter(!=(:codegen), Base.Linking.DEFAULT_COMPONENTS)
        return Base.Linking.runtime_libraries(; optional_components = components)
    else
        return library_files(runtime_library_names_compat(; codegen))
    end
end

"""
    stdlib_libraries(stdlib) -> Vector{String}

Paths of the shared libraries that `stdlib` (e.g. `OpenBLAS_jll`) ships inside the Julia
installation rather than as an artifact.
"""
stdlib_libraries(stdlib::AbstractString) =
    library_files(get(Vector{String}, PackageCompiler.jll_mapping, stdlib))

@static if _JULIA_DECLARES_RUNTIME_LIBRARIES
    const library_files = Base.Linking.library_files
else
    const library_files = library_files_compat
end

"""
    bundle_libraries(recipe::BundleRecipe, stdlibs) -> PackageCompiler.BundledLibraries

Copy the runtime libraries and those of `stdlibs` into the bundle, at the same path relative
to the library directory as in the installation, which is where `libjulia` looks for them.
"""
function bundle_libraries(recipe::BundleRecipe, stdlibs)
    # create `lib/julia` even when a source build keeps its libraries in `lib`
    Sys.isunix() && mkpath(joinpath(recipe.output_dir::String, recipe.libdir, "julia"))
    codegen = !is_trim_enabled(recipe.link_recipe.image_recipe)
    base_dests = _install_libraries(recipe, runtime_libraries(; codegen))
    stdlib_dests = Pair{String, Vector{String}}[]
    for stdlib in stdlibs
        dests = _install_libraries(recipe, stdlib_libraries(stdlib))
        isempty(dests) || push!(stdlib_dests, stdlib => dests)
    end
    return PackageCompiler.BundledLibraries(base_dests, stdlib_dests)
end

_install_libraries(recipe::BundleRecipe, libs::Vector{String}) =
    unique!(String[_install_library(recipe, lib) for lib in libs])

# Copy `src` into the bundle, keeping links to siblings as links; return the destination.
function _install_library(recipe::BundleRecipe, src::String)
    dest = _bundle_destination(recipe, src)
    (isfile(dest) || islink(dest)) && return dest
    mkpath(dirname(dest))
    if islink(src)
        target = readlink(src)
        if basename(target) == target # e.g. `libjulia.so.1`
            symlink(target, dest)
            return dest
        end
    end
    cp(src, dest; force=true, follow_symlinks=true)
    return dest
end

function _bundle_destination(recipe::BundleRecipe, lib::String)
    rel = relpath(dirname(lib), julia_shlibdir())
    # outside the library directory: use `julia/`, where the loader looks
    startswith(rel, "..") && (rel = "julia")
    return normpath(joinpath(recipe.output_dir::String, recipe.libdir, rel, basename(lib)))
end
