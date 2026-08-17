"""
Linux- and FreeBSD-specific privatization for libjulia.

High-level steps:
1) Copy `libjulia*` and `libjulia-internal*` to salted basenames next to originals.
2) Set SONAME of each salted library to the salted basename (via patchelf) and DEP_LIBS with ObjectFile.jl
3) Rewrite DT_NEEDED entries in the built artifact and salted libs to the salted basenames
   (no `@rpath` on Linux or FreeBSD; DT_NEEDED entries are plain basenames).
4) Recreate symlinks
5) Patch symbol versions to avoid interposition.
6) Remove originals.
"""

using Patchelf_jll

const LinuxOrBSD = Union{LinuxPlatform,FreeBSDPlatform}

function privatize_libjulia!(recipe::BundleRecipe, platform::LinuxOrBSD)
    try
        salted_paths = privatize_libjulia_common!(recipe, platform)

        # Version-stamp symbol versions to avoid interposition
        if salted_paths !== nothing
            try
                version_stamp_symbols!(salted_paths, recipe.link_recipe.outname)
            catch e
                error("Failed to patch symbol versions on salted libraries", e)
            end
        end
    catch e
        error("Failed to privatize libjulia", e)
    end
end

function plat_get_deps(::LinuxOrBSD, bin::String)
    filter!(!isempty, readlines(`$(Patchelf_jll.patchelf()) --print-needed $(bin)`))
end

function plat_install_name_change!(::LinuxOrBSD, binpath::String, old::String, new::String)
    run(`$(Patchelf_jll.patchelf()) --replace-needed $(old) $(new) $(binpath)`)
end

function plat_set_library_id!(::LinuxOrBSD, libpath::String, soname::String)
    run(`$(Patchelf_jll.patchelf()) --set-soname $(soname) $(libpath)`)
end

function version_stamp_symbols!(salted_paths::Dict{String,String}, product::String)
    old_ver = "JL_LIBJULIA_$(VERSION.major).$(VERSION.minor)"
    new_ver = "JL_$(random_salt(8))_$(VERSION.major).$(VERSION.minor)"
    for p in values(salted_paths)
        PatchVersion.patch_version!(p, old_ver, new_ver)
    end
    PatchVersion.patch_version!(product, old_ver, new_ver)
end

plat_ext(::LinuxOrBSD) = ".so"
plat_dep_prefix(::LinuxOrBSD) = ""
