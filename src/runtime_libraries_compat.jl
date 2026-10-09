# Fallback for Julia < 1.14, which lacks `Base.Linking.runtime_libraries` and
# `Base.Linking.library_files`. Delete once JuliaC requires 1.14.

# PackageCompiler's hardcoded per-OS list, plus what it misses
function runtime_library_names_compat(; codegen::Bool)
    os = Sys.isapple() ? "mac" : Sys.iswindows() ? "windows" : "linux"
    names = copy(PackageCompiler.required_libraries[os])
    push!(names, Base.isdebugbuild() ? "libjulia-debug" : "libjulia")
    push!(names, "libzstd") # needed since 1.13; missing before PackageCompiler 2.4.1
    codegen && push!(names, Base.libllvm_name) # the `-jl` name libLLVM_jll dlopens
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

`Base.Linking.library_files` for Julia < 1.14.
"""
function library_files_compat(names)
    dirs = Pair{String,Vector{String}}[]
    for dir in unique!(String[julia_private_shlibdir(), julia_shlibdir()])
        isdir(dir) && push!(dirs, dir => readdir(dir; sort=true))
    end
    # no one-argument `parse_dl_name_version` before 1.13
    os = Base.BinaryPlatforms.os(Base.BinaryPlatforms.HostPlatform())
    paths = String[]
    for name in names
        for (dir, files) in dirs
            found = false
            for file in files
                _is_library_file_compat(name, file, os) || continue
                push!(paths, joinpath(dir, file))
                found = true
            end
            found && break # a library lives in only one directory
        end
    end
    return unique!(paths)
end
library_files_compat(name::AbstractString) = library_files_compat((name,))

# Before 1.14 `parse_dl_name_version` rejects a tagged soversion (`libLLVM.so.20.1jl`), so
# also try without the tag.
function _is_library_file_compat(name::AbstractString, file::AbstractString, os::AbstractString)
    for candidate in (file, _strip_soversion_tag(file))
        parsed = try
            first(Base.BinaryPlatforms.parse_dl_name_version(candidate, os))
        catch ex
            ex isa ArgumentError || rethrow()
            continue # not a shared library
        end
        parsed == name && return true
        # soversion before the extension, as in `libopenblas64_.0.3.33.so`
        Sys.isapple() && continue
        first(Base.BinaryPlatforms.parse_dl_name_version(parsed * ".dylib", "macos")) == name && return true
    end
    return false
end

# `libLLVM.so.20.1jl` -> `libLLVM.so.20.1`
_strip_soversion_tag(file::AbstractString) =
    replace(file, r"(?<=\d)[A-Za-z][\w\-]*$" => "")
