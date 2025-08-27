"""
Common privatization logic shared between macOS and Linux.
"""

using Base: BinaryPlatforms

function privatize_libjulia_common!(recipe::BundleRecipe; 
                                   platform_ext::String,
                                   install_name_id_func!,
                                   install_name_change_func!,
                                   set_soname_func!,
                                   get_deps_func::Function,
                                   dep_prefix::String)
    libdir = recipe.libdir
    bundle_root = recipe.output_dir
    product = recipe.link_recipe.outname
    
    # Search in both the main lib directory and the julia subdirectory
    search_dirs = String[]
    lib_dir = joinpath(bundle_root, libdir)
    if isdir(lib_dir)
        push!(search_dirs, lib_dir)
    end
    julia_dir = joinpath(lib_dir, "julia")
    if isdir(julia_dir)
        push!(search_dirs, julia_dir)
    end
    
    if isempty(search_dirs)
        return
    end

    # Find all libjulia libraries, but only process the actual files (not symlinks)
    libs = String[]
    for search_dir in search_dirs
        for (root, _, files) in walkdir(search_dir)
            for f in files
                if endswith(f, platform_ext) && occursin("libjulia", f)
                    libpath = joinpath(root, f)
                    # Only process actual files, not symlinks
                    if !islink(libpath)
                        push!(libs, libpath)
                    end
                end
            end
        end
    end
    isempty(libs) && return

    salt = random_salt(8)
    salted_paths = Dict{String,String}()
    base_to_salted = Dict{String,String}()
    # First, create all salted libraries (salt_ + original basename)
    esc_ext = escape_string(platform_ext)
    for p in libs
        base = basename(p)
        salted_base = string(salt, "_", base)
        salted_path = joinpath(dirname(p), salted_base)
        cp(p, salted_path; force=true)
        # Update soname/install_name_id
        if install_name_id_func! !== nothing
            install_name_id_func!(salted_path, dep_prefix * salted_base)
        end
        if set_soname_func! !== nothing
            set_soname_func!(salted_path, salted_base)
        end
        # Create compatibility symlinks alongside the salted copy (minimal, only for libjulia*)
        if occursin("libjulia", base)
            dir = dirname(p)
            # Unsalted medium and short basenames
            medium = replace(base, Regex("\\.\\d+" * escape_string(platform_ext) * raw"$") => platform_ext)
            short = replace(base, Regex("\\.\\d+(\\.\\d+){0,2}" * escape_string(platform_ext) * raw"$") => platform_ext)
            # Point unsalted medium/short to the salted full basename
            for linkname in (medium, short)
                if linkname != base
                    linkpath = joinpath(dir, linkname)
                    if islink(linkpath) || isfile(linkpath)
                        rm(linkpath; force=true)
                    end
                    try
                        symlink(salted_base, linkpath)
                    catch
                        cp(salted_path, linkpath; force=true)
                    end
                end
            end
        end
        salted_paths[p] = salted_path
        # Map all common libjulia name variants to the salted full
        base_to_salted[base] = salted_base
        # medium version (libjulia.1.12.ext)
        medium = replace(base, Regex("\\.\\d+" * escape_string(platform_ext) * raw"$") => platform_ext)
        if medium != base
            base_to_salted[medium] = salted_base
        end
        # short name (libjulia.ext)
        short = replace(base, Regex("\\.\\d+(\\.\\d+){0,2}" * escape_string(platform_ext) * raw"$") => platform_ext)
        if short != base && short != medium
            base_to_salted[short] = salted_base
        end
    end

    # Update built product and salted libs to use salted libraries
    all_targets = collect(values(salted_paths))
    push!(all_targets, product)
    for t in unique(all_targets)
        for (old, new) in replacements_for(t, base_to_salted, get_deps_func, dep_prefix)
            install_name_change_func!(t, old, new)
        end
    end
    
    # Then remove the original libraries (after all dependency updates are done)
    for p in libs
        rm(p; force=true)
    end

    return salted_paths
end

function replacements_for(bin::String, base_to_salted::Dict{String,String}, get_deps_func::Function, dep_prefix::String)
    seen = Set{Tuple{String,String}}()
    for dep in get_deps_func(bin)
        b = basename(dep)
        if haskey(base_to_salted, b)
            new_dep = dep_prefix * base_to_salted[b]
            if dep != new_dep
                push!(seen, (dep, new_dep))
            end
        end
    end
    return collect(seen)
end

    # No symlink recreation: all load commands point directly at salted names

"""
Get platform-specific dynamic library extension.
"""
platform_dlext() = "." * Base.BinaryPlatforms.platform_dlext()

"""
Generate a random salt string for library names.
"""
function random_salt(len::Int=8)
    chars = ['a':'z'; 'A':'Z'; '0':'9'; '-'; '_']
    return String(rand(chars, len))
end
