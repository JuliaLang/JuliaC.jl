# Which shared libraries a bundle needs is declared by Julia itself, via
# `Base.Linking.runtime_libraries` (Julia 1.14 and later), so that the list keeps matching
# the runtime as its dependencies change. Julia versions that do not declare it are served by
# `runtime_libraries_compat.jl`, which is where everything that duplicates Julia's own
# functionality lives.

const _JULIA_DECLARES_RUNTIME_LIBRARIES = isdefined(Base.Linking, :runtime_libraries)

@static if !_JULIA_DECLARES_RUNTIME_LIBRARIES
    include("runtime_libraries_compat.jl")
end

# The directory holding the shared libraries of the running Julia installation (`bin` on
# Windows, `lib` elsewhere), and the one holding its private libraries.
julia_shlibdir() = JuliaConfig.libDir()
julia_private_shlibdir() = JuliaConfig.private_libDir()

"""
    runtime_libraries(; codegen::Bool=true) -> Vector{String}

Absolute paths of the shared library files of the running Julia installation that a program
embedding the Julia runtime needs at run time, including the version symlinks that go with
them.

Pass `codegen=false` for a program that never generates native code at run time (a `--trim`
build), which drops `libjulia-codegen` and LLVM.
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

Absolute paths of the shared library files that the standard library `stdlib` provides, e.g.
`libopenblas` for `OpenBLAS_jll`. These live in the Julia installation, unlike the libraries
of ordinary JLL packages, which are bundled as artifacts.
"""
stdlib_libraries(stdlib::AbstractString) =
    library_files(get(Vector{String}, PackageCompiler.jll_mapping, stdlib))

# Resolve library names to the files the running Julia installation ships under them.
@static if _JULIA_DECLARES_RUNTIME_LIBRARIES
    const library_files = Base.Linking.library_files
else
    const library_files = library_files_compat
end

"""
    bundle_libraries(recipe::BundleRecipe, stdlibs) -> PackageCompiler.BundledLibraries

Copy the Julia runtime libraries, and the libraries of `stdlibs`, into the bundle.

Each library keeps the location it has relative to the Julia installation's library
directory, so that the dependency paths embedded in `libjulia` keep resolving.
"""
function bundle_libraries(recipe::BundleRecipe, stdlibs)
    # the `julia` subdirectory is part of the bundle layout even when this Julia keeps its
    # private libraries in the library directory itself, as a build from source does
    Sys.isunix() && mkpath(joinpath(recipe.output_dir::String, recipe.libdir, "julia"))
    # a trimmed program cannot generate code at run time, so it needs neither LLVM nor
    # `libjulia-codegen`
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

# Install a library file into the bundle, preserving symlinks, and return its destination.
function _install_library(recipe::BundleRecipe, src::String)
    dest = _bundle_destination(recipe, src)
    (isfile(dest) || islink(dest)) && return dest
    mkpath(dirname(dest))
    if islink(src)
        target = readlink(src)
        if basename(target) == target # a plain link to a sibling file, e.g. `libjulia.so.1`
            symlink(target, dest)
            return dest
        end
    end
    cp(src, dest; force=true, follow_symlinks=true)
    return dest
end

function _bundle_destination(recipe::BundleRecipe, lib::String)
    rel = relpath(dirname(lib), julia_shlibdir())
    # a private library outside the library directory (an unusual layout) goes into the
    # `julia` subdirectory, where the loader looks for it
    startswith(rel, "..") && (rel = "julia")
    return normpath(joinpath(recipe.output_dir::String, recipe.libdir, rel, basename(lib)))
end
