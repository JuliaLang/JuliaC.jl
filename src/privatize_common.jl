"""
Common privatization logic shared between macOS and Linux.
"""

using Base: BinaryPlatforms
using Mmap
using ObjectFile

abstract type PrivatizePlatform end
struct MacOSPlatform <: PrivatizePlatform end
struct LinuxPlatform <: PrivatizePlatform end

"""
    SaltMap

A single, explicit description of how every library name is rewritten during
privatization. It is built once per run (see `build_salt_map`) and threaded
through all rewrite sites, so the salted form of a name is derived in exactly
one place.

Fields:
- `salt`: the raw salt token, retained only as a record of this run for
  logging/debugging. It is *not* re-applied to names anywhere downstream — all
  salting goes through `rename`.
- `rename`: the platform's name-salting function, `name -> salted_name`. It is
  total: it works on full basenames (`libjulia.so.1.13`), bare SONAME/NEEDED
  strings, and on the extension-less stems that appear inside `dep_libs`
  (`libjulia`, `libjulia-internal`). This is the only definition of "how a name
  is salted".
- `basenames`: the concrete map of `original_basename => salted_basename` for
  every real library file actually discovered on disk, plus any symlink
  basenames that resolve to one of them. This is what we consult when we need to
  know *which* names were salted (dependency / NEEDED rewrites, symlink
  retargeting) rather than how to salt an arbitrary name.

`rename` and `basenames` are consistent by construction: every value in
`basenames` equals `rename` applied to its key.
"""
struct SaltMap{F}
    salt::String
    rename::F
    basenames::Dict{String,String}
end

# Apply the platform's name-salting to one name (the single definition of "salting a name").
salt_name(m::SaltMap, name::AbstractString) = m.rename(String(name))

# Record that real library basename `base` is salted, returning the salted basename.
function record!(m::SaltMap, base::AbstractString)
    salted = salt_name(m, base)
    m.basenames[String(base)] = salted
    return salted
end

# Per-platform hooks (implemented in platform-specific files)
plat_ext(::PrivatizePlatform) = error("Unsupported platform")

# How a dependency is referenced in load metadata (macOS `@rpath/<name>`, Linux bare `<name>`); applied uniformly to the id and every dependency reference.
plat_dep_ref(::PrivatizePlatform, name::String) = error("Unsupported platform")

# Build this run's name-salting function (`name -> salted_name`); the only place salt becomes a transform — macOS prepends (may grow), Linux substitutes same-length.
plat_make_renamer(::PrivatizePlatform, salt::String) = error("Unsupported platform")

# Set a salted library's own identity (install_name id / SONAME), resolved from the `SaltMap`: macOS uses `@rpath/<salted base>`, Linux salts the current SONAME.
plat_set_library_id!(::PrivatizePlatform, smap, libpath::String) = nothing

# Rewrite one dependency reference in `binpath` from `old` to `new` (both already fully-resolved).
plat_install_name_change!(::PrivatizePlatform, binpath::String, old::String, new::String) =
    error("Unsupported platform change")

plat_get_deps(::PrivatizePlatform, bin::String) = String[]

# Build the SaltMap for a run from the platform's renamer.
build_salt_map(platform::PrivatizePlatform, salt::String) =
    SaltMap(salt, plat_make_renamer(platform, salt), Dict{String,String}())

function privatize_libjulia_common!(recipe::BundleRecipe, platform::PrivatizePlatform)
    bundle_root = recipe.output_dir
    product = recipe.link_recipe.outname
    platform_ext = plat_ext(platform)

    # Search in both the main lib directory and the julia subdirectory
    search_dirs = String[]
    lib_dir = joinpath(bundle_root, recipe.libdir)

    # Gather libjulia files
    real_files = String[]
    symlink_files = String[]
    for (root, _, files) in walkdir(lib_dir)
        for f in files
            occursin("libjulia", f) || continue
            p = joinpath(root, f)
            if islink(p)
                push!(symlink_files, p)
            else
                # Optional extension filter; keep anything that looks like a library file
                if endswith(f, platform_ext) || occursin(platform_ext * ".", f)
                    push!(real_files, p)
                end
            end
        end
    end
    isempty(real_files) && return

    salt = random_salt(8)
    smap = build_salt_map(platform, salt)
    salted_paths = Dict{String,String}()
    originals_to_remove = String[]

    # 1) Salt all real library files
    for p in real_files
        base = basename(p)
        salted_base = record!(smap, base)   # records base => salted_base in the map
        salted_path = joinpath(dirname(p), salted_base)
        cp(p, salted_path; force=true)
        chmod(salted_path, filemode(salted_path) | 0o200)  # ensure writable for patching
        push!(originals_to_remove, p)
        # Update the salted copy's identity (install_name/SONAME); the platform resolves the new id from the shared map.
        plat_set_library_id!(platform, smap, salted_path)
        salted_paths[p] = salted_path
        if startswith(base, "libjulia.") && !islink(salted_path)
            replace_dep_libs(salted_path, smap)
        end
    end

    # 2) For every existing symlink, create a salted symlink with the salted basename
    for lnk in symlink_files
        dir = dirname(lnk)
        link_base = basename(lnk)
        target = readlink(lnk)
        target_base = basename(target)
        haskey(smap.basenames, target_base) || continue
        salted_target_base = smap.basenames[target_base]
        salted_link = joinpath(dir, salt_name(smap, link_base))
        try
            symlink(salted_target_base, salted_link)
        catch e
            # If link already exists, skip; otherwise copy the salted target
            if isa(e, Base.IOError) && occursin("EEXIST", sprint(showerror, e))
                # Already exists; nothing to do
            else
                error("Failed to create symlink $salted_link -> $salted_target_base", e)
            end
        end
        # Record the symlink basename so DT_NEEDED entries that name the symlink are recognized as bundled (and thus rewritten).
        smap.basenames[link_base] = salted_target_base
        # Schedule original symlink for removal
        push!(originals_to_remove, lnk)
    end

    # Update built product and salted libs to use salted libraries
    all_targets = collect(values(salted_paths))
    push!(all_targets, product)
    for t in unique(all_targets)
        reps = replacements_for(t, smap, platform)
        if recipe.link_recipe.image_recipe.verbose && !isempty(reps)
            println("Privatize: updating deps for ", t)
            for (old,new) in reps
                println("  ", old, " -> ", new)
            end
        end
        for (old, new) in reps
            plat_install_name_change!(platform, t, old, new)
        end
    end

    # Remove originals after all dependency updates are applied
    for path in unique(originals_to_remove)
        rm(path; force=true)
    end

    return salted_paths
end

const DEP_LIBS_LENGTH = 512 # This is technically 1024 bytes, but we use 512 to be safe

"""
    replace_dep_libs(file, smap::SaltMap)

Rewrite the `dep_libs` string (a NUL/colon list of bare library stems such as
`libjulia:libjulia-internal`) in place, salting each stem with the same
`smap.rename` used for every other name. macOS's renamer may grow the stems
(absorbed by the fixed-size buffer); Linux's renamer is length-preserving.
"""
function replace_dep_libs(file, smap::SaltMap)
    obj = only(readmeta(open(file, "r")))
    syms = collect(Symbols(obj))
    syms_names = symbol_name.(syms)
    sym = syms[findfirst(syms_names .== mangle_symbol_name(obj, "dep_libs"))]
    offset = symbol_offset(sym)
    fileh = open(file, "r+")
    filem = Mmap.mmap(fileh)
    data = String(filem[offset : (offset + DEP_LIBS_LENGTH - 1)])
    new = salt_dep_libs(data, smap)
    new_data = Vector{UInt8}(new[begin:DEP_LIBS_LENGTH])
    filem[offset : (offset + DEP_LIBS_LENGTH - 1)] .= new_data
    Mmap.sync!(filem)
end

# Salt each stem in the colon-separated, NUL-padded `dep_libs` blob with the platform renamer (no per-platform branch here).
function salt_dep_libs(data::AbstractString, smap::SaltMap)
    return replace(data, r"[^:\0]+" => m -> salt_name(smap, m))
end

function replacements_for(bin::String, smap::SaltMap, platform::PrivatizePlatform)
    seen = Set{Tuple{String,String}}()
    for dep in plat_get_deps(platform, bin)
        b = basename(dep)
        if haskey(smap.basenames, b)
            # Salt the live dep string (not the recorded basename) so a soname like libjulia.so.1.12 maps to <salt>.so.1.12 — length-preserving; basenames is only the "bundled?" guard.
            new_dep = plat_dep_ref(platform, salt_name(smap, b))
            push!(seen, (dep, new_dep))
        end
    end
    return collect(seen)
end

"""
Generate a random salt string for library names.
"""
function random_salt(len::Int=8)
    chars = ['a':'z'; 'A':'Z'; '0':'9'; '-'; '_']
    return String(rand(chars, len))
end
