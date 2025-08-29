"""
Common privatization logic shared between macOS and Linux.
"""

using Base: BinaryPlatforms
using Mmap
using ObjectFile

abstract type PrivatizePlatform end
struct MacOSPlatform <: PrivatizePlatform end
struct LinuxPlatform <: PrivatizePlatform end

# Per-platform hooks (implemented in platform-specific files)
plat_ext(::PrivatizePlatform) = error("Unsupported platform")
plat_dep_prefix(::PrivatizePlatform) = error("Unsupported platform")
plat_set_library_id!(::PrivatizePlatform, libpath::String, new_id::String) = nothing
plat_install_name_change!(::PrivatizePlatform, binpath::String, old::String, new::String) = error("Unsupported platform change")
plat_get_deps(::PrivatizePlatform, bin::String) = String[]

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
    salted_paths = Dict{String,String}()
    salted_filenames = Dict{String,String}()
    originals_to_remove = String[]

    # 1) Salt all real library files
    for p in real_files
        base = basename(p)
        salted_base = string(salt, "_", base)
        salted_path = joinpath(dirname(p), salted_base)
        cp(p, salted_path; force=true)
        push!(originals_to_remove, p)
        # Update library identity for salted copy (install_name/SONAME) via unified hook
        plat_set_library_id!(platform, salted_path, plat_dep_prefix(platform) * salted_base)
        salted_paths[p] = salted_path
        salted_filenames[base] = salted_base
        if startswith("libjulia.", base) && !islink(salted_path)
            replace_dep_libs(salted_path, salt)
        end
    end

    # 2) For every existing symlink, create a salted symlink with the salted basename
    for lnk in symlink_files
        dir = dirname(lnk)
        link_base = basename(lnk)
        target = readlink(lnk)
        target_base = basename(target)
        haskey(salted_filenames, target_base) || continue
        salted_target_base = salted_filenames[target_base]
        salted_link = joinpath(dir, string(salt, "_", link_base))
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
        # Record that this symlink basename should be rewritten to the salted target
        # This is necessary because the DT_NEEDED entries may point to a symlink
        salted_filenames[link_base] = salted_target_base
        # Schedule original symlink for removal
        push!(originals_to_remove, lnk)
    end

    # Update built product and salted libs to use salted libraries
    all_targets = collect(values(salted_paths))
    push!(all_targets, product)
    for t in unique(all_targets)
        reps = replacements_for(t, salted_filenames, platform)
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

function replace_dep_libs(file, salt)
    obj = only(readmeta(open(file, "r")))
    syms = collect(Symbols(obj))
    syms_names = symbol_name.(syms)
    sym = syms[findfirst(syms_names .== mangle_symbol_name(obj, "dep_libs"))]
    offset = symbol_offset(sym)
    fileh = open(file, "r+")
    filem = Mmap.mmap(fileh)
    data = String(filem[offset : (offset + DEP_LIBS_LENGTH - 1)])
    new_data = Vector{UInt8}(replace(data, "libjulia" => salt * "_" * "libjulia")[begin:DEP_LIBS_LENGTH])
    filem[offset : (offset + DEP_LIBS_LENGTH - 1)] .= new_data
    Mmap.sync!(filem)
end

function replacements_for(bin::String, salted_filenames::Dict{String,String}, platform::PrivatizePlatform)
    seen = Set{Tuple{String,String}}()
    for dep in plat_get_deps(platform, bin)
        b = basename(dep)
        if haskey(salted_filenames, b)
            new_dep = plat_dep_prefix(platform) * salted_filenames[b]
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
