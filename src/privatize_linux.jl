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
    salted_paths = privatize_libjulia_common!(recipe, LinuxPlatform())

    # Version-stamp symbol versions to avoid interposition (Linux-specific)
    if salted_paths !== nothing
        version_stamp_symbols!(salted_paths, recipe.link_recipe.outname)
    end
end

# Linux-specific dependency extraction (pure-Julia, via PatchVersion).
get_dependencies_linux(bin::String) = PatchVersion.read_needed(bin)

# On Linux the SONAME / DT_NEEDED strings carry the two-component version
# (e.g. "libjulia.so.1.12") while the files on disk carry the full version
# (e.g. "libjulia.so.1.12.6").  Salting therefore cannot reuse the salted file
# basename verbatim: that would grow the in-place string.  Instead we substitute
# the leading "libjulia" token in the live SONAME/NEEDED string with the same
# salt, which is length-preserving (the "libjulia" token is always 8 chars).
_salt_julia_name(name::String, salt::String) = replace(name, "libjulia" => salt; count = 1)

# Rename the single DT_NEEDED entry `old` (a "libjulia*" name) in `binpath` to its
# salt-substituted form.  Length-preserving: the version-bearing `old` string keeps
# its byte length.
function replace_needed_salted!(binpath::String, old::String, salt::String)
    @assert occursin("libjulia", old) "refusing to rewrite DT_NEEDED \"$old\" in $binpath: not a libjulia entry"
    PatchVersion.replace_needed!(binpath, old, _salt_julia_name(old, salt))
end

# Set the SONAME of `libpath`, in place, to the salt-substituted form of its current
# SONAME (length-preserving).  Guard: the existing SONAME must contain the "libjulia"
# token.
function set_soname_salted!(libpath::String, salt::String)
    current = PatchVersion.read_soname(libpath)
    @assert current !== nothing && occursin("libjulia", current) "refusing to set SONAME of $libpath: current soname $(repr(current)) is not a libjulia name"
    PatchVersion.set_soname!(libpath, _salt_julia_name(current, salt))
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
plat_set_library_id!(::LinuxPlatform, libpath::String, new_id::String, salt::String) = set_soname_salted!(libpath, salt)
plat_install_name_change!(::LinuxPlatform, binpath::String, old::String, new::String, salt::String) = replace_needed_salted!(binpath, old, salt)
plat_get_deps(::LinuxPlatform, bin::String) = get_dependencies_linux(bin)

# Linux salts by equal-length token substitution (libjulia -> 8-char salt), so the
# in-place .dynstr SONAME/NEEDED rewrites never grow a string. dep_libs is salted
# by the same substitution rather than by prepend.
plat_salted_basename(::LinuxPlatform, base::String, salt::String) = replace(base, "libjulia" => salt; count = 1)
plat_dep_libs_prepend(::LinuxPlatform) = false

