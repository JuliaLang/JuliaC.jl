# This file is a part of Julia. License is MIT: https://julialang.org/license

# Standalone Libdl overrides to reuse existing loaded libraries when dlopening
# absolute paths that match a currently loaded SONAME-style key.

let
    find_loaded_root_module(key::Base.PkgId) = Base.maybe_root_module(key)

    Libdl = find_loaded_root_module(Base.PkgId(
        Base.UUID("8f399da3-3557-5675-b5ff-fb832c97cbdb"), "Libdl"))
    if Libdl !== nothing
        Base.@eval Libdl begin
            """
                dlopen(libfile::AbstractString, flags::Integer = Libdl.default_rtld_flags; throw_error::Bool = true)

            Open a shared library, but when given an absolute path first scans currently
            loaded libraries and returns an existing handle if the SONAME-style key matches
            (emulating the usual deduplication that occurs for non-absolute `dlopen`).

            On Linux/BSD, the SONAME key is `name.so.MAJOR`.
            On macOS, the key is `name.MAJOR.dylib`.
            On Windows, the key is `name-MAJOR.dll` (best-effort; Windows does not use SONAMEs).
            """
            function dlopen(libfile::AbstractString, flags::Integer = Libdl.default_rtld_flags; throw_error::Bool = true)
                if isabspath(libfile)
                    # Build a platform-appropriate SONAME-style key for the target library.
                    target_key = _soname_key(libfile)
                    for loaded_path in Libdl.dllist()
                        # Some platforms may report empty entries; skip those.
                        if isempty(loaded_path)
                            continue
                        end
                        if _keys_match(target_key, _soname_key(loaded_path))
                            # Acquire existing handle without forcing a new load
                            h = ccall(:jl_load_dynamic_library, Ptr{Cvoid}, (Cstring,UInt32,Cint), loaded_path, UInt32(Libdl.RTLD_NOLOAD), Cint(0))
                            if h != C_NULL
                                return h
                            end
                        end
                    end
                end

                # Fall back to normal loader behavior
                ret = ccall(:jl_load_dynamic_library, Ptr{Cvoid}, (Cstring,UInt32,Cint), libfile, UInt32(flags), Cint(throw_error))
                if !throw_error && ret == C_NULL
                    return nothing
                end
                return ret
            end

            """
                _soname_key(path::AbstractString) -> String

            Compute a platform-appropriate SONAME-style key from a shared library file path,
            using simple filename regex parsing. This normalizes versioning to major version
            when applicable and avoids heavy dependencies.
            """
            function _soname_key(path::AbstractString)
                fname = _normalize_case(basename(String(path)))

                if Sys.iswindows()
                    # libname[-MAJOR].dll (case-insensitive handled by normalization)
                    m = match(r"^(.*?)(?:-([0-9]+))?\.dll$"sa, fname)
                    if m === nothing
                        return fname
                    end
                    name = m.captures[1]
                    major = m.captures[2]
                    return major === nothing ? string(name, ".dll") : string(name, "-", major, ".dll")
                elseif Sys.isapple()
                    # libname[.MAJOR[.MINOR...]].dylib
                    m = match(r"^(.*?)(?:\.([0-9]+)(?:\.[0-9]+)*)?\.dylib$"sa, fname)
                    if m === nothing
                        return fname
                    end
                    name = m.captures[1]
                    major = m.captures[2]
                    return major === nothing ? string(name, ".dylib") : string(name, ".", major, ".dylib")
                else
                    # libname.so[.MAJOR[.MINOR...]]
                    m = match(r"^(.*?)(?:\.so(?:\.([0-9]+)(?:\.[0-9]+)*)?)$"sa, fname)
                    if m === nothing
                        return fname
                    end
                    name = m.captures[1]
                    major = m.captures[2]
                    return major === nothing ? string(name, ".so") : string(name, ".so.", major)
                end
            end

            # Case-folding helper for Windows where library matching should be case-insensitive
            _normalize_case(s::AbstractString) = Sys.iswindows() ? lowercase(String(s)) : String(s)

            # Compare keys, accounting for Windows case-insensitivity
            function _keys_match(a::AbstractString, b::AbstractString)
                if Sys.iswindows()
                    return lowercase(String(a)) == lowercase(String(b))
                else
                    return String(a) == String(b)
                end
            end
        end
    end
end


