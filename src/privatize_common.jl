"""
Common privatization logic shared between macOS and Linux.
"""

using Base: BinaryPlatforms
using Mmap
using ObjectFile

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

    # Gather libjulia files
    real_files = String[]
    symlink_files = String[]
    for search_dir in search_dirs
        for (root, _, files) in walkdir(search_dir)
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
    end
    isempty(real_files) && return

    salt = random_salt(8)
    salted_paths = Dict{String,String}()
    base_to_salted = Dict{String,String}()
    originals_to_remove = String[]

    # 1) Salt all real library files
    for p in real_files
        base = basename(p)
        salted_base = string(salt, "_", base)
        salted_path = joinpath(dirname(p), salted_base)
        cp(p, salted_path; force=true)
        push!(originals_to_remove, p)
        # Update install_name/soname for salted copy
        if install_name_id_func! !== nothing
            install_name_id_func!(salted_path, dep_prefix * salted_base)
        end
        if set_soname_func! !== nothing
            set_soname_func!(salted_path, salted_base)
        end
        salted_paths[p] = salted_path
        base_to_salted[base] = salted_base
        if occursin("libjulia", base) && !occursin("-internal", base) && !occursin("-codegen", base) && !islink(salted_path)
            replace_dep_libs(salted_path, salt)
        end
    end

    # 2) For every existing symlink, create a salted symlink with the salted basename
    for lnk in symlink_files
        dir = dirname(lnk)
        link_base = basename(lnk)
        target = readlink(lnk)
        target_base = target === nothing ? nothing : basename(target)
        salted_target_base = (target_base !== nothing && haskey(base_to_salted, target_base)) ? base_to_salted[target_base] : nothing
        # If we don't know the salted target, try to best-effort point to any salted full we created (same dir)
        if salted_target_base === nothing && !isempty(values(salted_paths))
            salted_target_base = basename(first(values(salted_paths)))
        end
        salted_link = joinpath(dir, string(salt, "_", link_base))
        if salted_target_base !== nothing
            isfile(salted_link) || islink(salted_link) ? rm(salted_link; force=true) : nothing
            try
                symlink(salted_target_base, salted_link)
            catch e
                @warn "Symlink failed; falling back to copying salted target" link=salted_link target=salted_target_base exception=e
                # Fallback to copying if symlink creation fails; let any copy error propagate
                src = joinpath(dir, salted_target_base)
                isfile(src) || error("Salted target not found for copy fallback", src)
                cp(src, salted_link; force=true)
            end
            # Record that this symlink basename should be rewritten to the salted target
            base_to_salted[link_base] = salted_target_base
            # Schedule original symlink for removal
            push!(originals_to_remove, lnk)
        end
    end

    # Update built product and salted libs to use salted libraries
    all_targets = collect(values(salted_paths))
    push!(all_targets, product)
    for t in unique(all_targets)
        reps = replacements_for(t, base_to_salted, get_deps_func, dep_prefix)
        if recipe.link_recipe.image_recipe.verbose && !isempty(reps)
            println("Privatize: updating deps for ", t)
            for (old,new) in reps
                println("  ", old, " -> ", new)
            end
        end
        for (old, new) in reps
            install_name_change_func!(t, old, new)
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
