"""
Linux-specific privatization for libjulia.

High-level steps:
1) Copy `libjulia*` and `libjulia-internal*` to salted basenames next to originals.
2) Set SONAME of each salted library to the salted basename (in-place, pure-Julia ELF patching) and DEP_LIBS with ObjectFile.jl
3) Rewrite DT_NEEDED entries in the built artifact and salted libs to the salted basenames
   (no `@rpath` on Linux; DT_NEEDED entries are plain basenames).
4) Recreate symlinks
5) Patch symbol versions to avoid interposition.
6) Remove originals.
"""

function privatize_libjulia_linux!(recipe::BundleRecipe)
    try
        salted_paths = privatize_libjulia_common!(recipe, LinuxPlatform())

        # Version-stamp symbol versions to avoid interposition (Linux-specific)
        if salted_paths !== nothing
            try
                version_stamp_symbols!(salted_paths, recipe.link_recipe.outname)
            catch e
                error("Failed to patch symbol versions on salted libraries", e)
            end
        end
    catch e
        error("Failed to privatize libjulia on Linux", e)
    end
end

# Linux-specific dependency extraction (pure-Julia, via PatchVersion).
get_dependencies_linux(bin::String) = PatchVersion.read_needed(bin)

# On Linux the SONAME / DT_NEEDED strings carry the two-component version
# (e.g. "libjulia.so.1.12") while the files on disk carry the full version
# (e.g. "libjulia.so.1.12.6").  Salting therefore cannot reuse the salted file
# basename verbatim: that would grow the in-place string.  Instead we substitute
# the leading "libjulia" token in the live SONAME/NEEDED string with the same
# salt, which is length-preserving.  Every libjulia* basename begins with the
# 8-char "libjulia" token, so the salt is the leading 8 characters of the salted
# basename, recovered here.
_salt_of(salted_basename::String) = first(salted_basename, length("libjulia"))

# Substitute the leading "libjulia" token of `name` with `salt`, preserving length.
_salt_julia_name(name::String, salt::String) = replace(name, "libjulia" => salt; count = 1)

# Rename the single DT_NEEDED entry `old` (a "libjulia*" name) in `binpath` to the
# salt-substituted form derived from the salted dependency basename `new`.
# Length-preserving: the version-bearing `old` string keeps its byte length.
function replace_needed_salted!(binpath::String, old::String, new::String)
    @assert occursin("libjulia", old) "refusing to rewrite DT_NEEDED \"$old\" in $binpath: not a libjulia entry"
    salted = _salt_julia_name(old, _salt_of(basename(new)))
    PatchVersion.replace_needed!(binpath, old, salted)
end

# Set the SONAME of `libpath`, in place, to the salt-substituted form of its
# current SONAME (length-preserving).  The salt is recovered from the salted file
# basename `soname`.  Guard: the existing SONAME must contain the "libjulia" token.
function set_soname_salted!(libpath::String, soname::String)
    current = PatchVersion.read_soname(libpath)
    @assert current !== nothing && occursin("libjulia", current) "refusing to set SONAME of $libpath: current soname $(repr(current)) is not a libjulia name"
    salted = _salt_julia_name(current, _salt_of(basename(soname)))
    PatchVersion.set_soname!(libpath, salted)
end

function version_stamp_symbols!(salted_paths::Dict{String,String}, product::String)
    old_ver = "JL_LIBJULIA_$(VERSION.major).$(VERSION.minor)"
    new_ver = "JL_$(random_salt(8))_$(VERSION.major).$(VERSION.minor)"
    for p in values(salted_paths)
        PatchVersion.patch_version!(p, old_ver, new_ver)
    end
    PatchVersion.patch_version!(product, old_ver, new_ver)
end

# Platform hooks for Linux
plat_ext(::LinuxPlatform) = ".so"
plat_dep_prefix(::LinuxPlatform) = ""
plat_set_library_id!(::LinuxPlatform, libpath::String, new_id::String) = set_soname_salted!(libpath, basename(new_id))
plat_install_name_change!(::LinuxPlatform, binpath::String, old::String, new::String) = replace_needed_salted!(binpath, old, new)
plat_get_deps(::LinuxPlatform, bin::String) = get_dependencies_linux(bin)

# Linux salts by equal-length token substitution (libjulia -> 8-char salt), so the
# in-place .dynstr SONAME/NEEDED rewrites never grow a string. dep_libs is salted
# by the same substitution rather than by prepend.
plat_salted_basename(::LinuxPlatform, base::String, salt::String) = replace(base, "libjulia" => salt; count = 1)
plat_dep_libs_prepend(::LinuxPlatform) = false

