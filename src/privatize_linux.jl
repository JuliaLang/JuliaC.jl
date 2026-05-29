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

# Substitute the 8-char "libjulia" token with the 8-char salt (length-preserving).
# This is Linux's name-salting function, used for basenames, SONAMEs, NEEDED
# entries and dep_libs stems alike. Same length in == same length out, so every
# in-place .dynstr patch is non-growing.
_salt_julia_name(name::AbstractString, salt::String) =
    replace(String(name), "libjulia" => salt; count = 1)

# Rename the libjulia DT_NEEDED entry `old` to the already-salted `new`, in place.
function replace_needed_salted!(binpath::String, old::String, new::String)
    @assert occursin("libjulia", old) "refusing to rewrite DT_NEEDED \"$old\" in $binpath: not a libjulia entry"
    PatchVersion.replace_needed!(binpath, old, new)
end

# Set `libpath`'s SONAME to the salted form of its *current* SONAME, in place.
# We salt the current SONAME (e.g. `libjulia.so.1.12`) rather than the basename
# (e.g. `libjulia.so.1.12.6`) because the two can differ; salting via the map's
# `rename` keeps it length-preserving and consistent with every other name.
function set_soname_salted!(smap::SaltMap, libpath::String)
    current = PatchVersion.read_soname(libpath)
    @assert current !== nothing && occursin("libjulia", current) "refusing to set SONAME of $libpath: current soname $(repr(current)) is not a libjulia name"
    PatchVersion.set_soname!(libpath, salt_name(smap, current))
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
# DT_NEEDED / SONAME strings are bare names on Linux (no @rpath).
plat_dep_ref(::LinuxPlatform, name::String) = name
# Linux's renamer salts by equal-length "libjulia" token substitution (not
# prepend) so every in-place .dynstr patch is length-preserving. This single
# function is used for basenames, SONAMEs, NEEDED entries and dep_libs stems.
plat_make_renamer(::LinuxPlatform, salt::String) = name -> _salt_julia_name(name, salt)
plat_set_library_id!(::LinuxPlatform, smap::SaltMap, libpath::String) = set_soname_salted!(smap, libpath)
plat_install_name_change!(::LinuxPlatform, binpath::String, old::String, new::String) = replace_needed_salted!(binpath, old, new)
plat_get_deps(::LinuxPlatform, bin::String) = get_dependencies_linux(bin)

