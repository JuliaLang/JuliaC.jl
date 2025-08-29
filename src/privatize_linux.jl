"""
Linux-specific privatization for libjulia.

High-level steps:
1) Copy `libjulia*` and `libjulia-internal*` to salted basenames next to originals.
2) Set SONAME of each salted library to the salted basename (via patchelf).
3) Rewrite DT_NEEDED entries in the built artifact and salted libs to the salted basenames
   (no `@rpath` on Linux; DT_NEEDED entries are plain basenames).
4) Create minimal unsalted symlinks (short/medium) pointing to the salted full for loader convenience.
5) Optionally patch symbol versions to avoid interposition.
6) Remove originals.
"""

using Patchelf_jll

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

# Linux-specific dependency extraction
function get_dependencies_linux(bin::String)
    out = read(`$(Patchelf_jll.patchelf()) --print-needed $(bin)`, String)
    return filter(!isempty, split(out, '\n'))
end

function patchelf_replace_needed!(binpath::String, old::String, new::String)
    run(`$(Patchelf_jll.patchelf()) --replace-needed $(old) $(new) $(binpath)`)
end

function patchelf_set_soname!(libpath::String, soname::String)
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

# Platform hooks for Linux
plat_ext(::LinuxPlatform) = ".so"
plat_dep_prefix(::LinuxPlatform) = ""
plat_set_library_id!(::LinuxPlatform, libpath::String, new_id::String) = patchelf_set_soname!(libpath, basename(new_id))
plat_install_name_change!(::LinuxPlatform, binpath::String, old::String, new::String) = patchelf_replace_needed!(binpath, old, new)
plat_get_deps(::LinuxPlatform, bin::String) = get_dependencies_linux(bin)

