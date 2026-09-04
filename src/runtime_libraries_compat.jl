# Resolving libraries in a Julia installation on versions that do not do it themselves, i.e.
# before `Base.Linking.runtime_libraries` and `Base.Linking.library_files` (Julia 1.14). This
# file is included only on those versions; everything in it disappears once JuliaC requires
# Julia 1.14.

# Which libraries the runtime depends on has to come from somewhere, and before Julia
# declared it the only list around was PackageCompiler's, which is hardcoded per operating
# system. It has drifted from the runtime, so patch up what we know is missing.
function runtime_library_names_compat(; codegen::Bool)
    os = Sys.isapple() ? "mac" : Sys.iswindows() ? "windows" : "linux"
    names = copy(PackageCompiler.required_libraries[os])
    # PackageCompiler's list covers the private libraries only
    push!(names, Base.isdebugbuild() ? "libjulia-debug" : "libjulia")
    # ... and it does not mention libzstd, which `libjulia-internal` has needed since 1.13;
    # it ends up in bundles only because `libz` is a prefix of it
    push!(names, "libzstd")
    # ... nor the name libLLVM_jll dlopens, which is a symlink beside the library itself
    codegen && push!(names, Base.libllvm_name)
    if Base.isdebugbuild()
        replace!(names, "libjulia-internal" => "libjulia-internal-debug",
                        "libjulia-codegen" => "libjulia-codegen-debug")
    end
    if !codegen
        filter!(name -> !startswith(name, "libLLVM") && !startswith(name, "libjulia-codegen"), names)
    end
    return names
end

"""
    library_files_compat(names) -> Vector{String}

The absolute paths of the shared library files that the running Julia installation ships
under any of `names`, including the version symlinks that go with them.

This is `Base.Linking.library_files` for Julia versions that do not have it.
"""
function library_files_compat(names)
    dirs = Pair{String,Vector{String}}[]
    for dir in unique!(String[julia_private_shlibdir(), julia_shlibdir()])
        isdir(dir) && push!(dirs, dir => readdir(dir; sort=true))
    end
    paths = String[]
    for name in names
        for (dir, files) in dirs
            found = false
            for file in files
                _is_library_file_compat(name, file) || continue
                push!(paths, joinpath(dir, file))
                found = true
            end
            # a library is not shipped in more than one of these directories
            found && break
        end
    end
    # several names can refer to the same file, e.g. `libopenblas` and `libopenblas64_`
    return unique!(paths)
end
library_files_compat(name::AbstractString) = library_files_compat((name,))

# `Base.BinaryPlatforms.parse_dl_name_version` exists here, but before Julia 1.14 it rejects
# a soversion carrying a tag, which is how Julia spells its own LLVM (`libLLVM.so.20.1jl`),
# so fall back to asking it about the name with such a tag removed.
function _is_library_file_compat(name::AbstractString, file::AbstractString)
    for candidate in (file, _strip_soversion_tag(file))
        parsed = try
            first(Base.BinaryPlatforms.parse_dl_name_version(candidate))
        catch ex
            ex isa ArgumentError || rethrow()
            continue # not the name of a shared library file
        end
        parsed == name && return true
        # a library may carry its soversion before the extension even on a platform where it
        # normally follows it, as OpenBLAS does in `libopenblas64_.0.3.33.so`
        Sys.isapple() && continue
        first(Base.BinaryPlatforms.parse_dl_name_version(parsed * ".dylib", "macos")) == name && return true
    end
    return false
end

# `libLLVM.so.20.1jl` -> `libLLVM.so.20.1`
_strip_soversion_tag(file::AbstractString) =
    replace(file, r"(?<=\d)[A-Za-z][\w\-]*$" => "")
