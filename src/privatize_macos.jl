"""
macOS-specific privatization for libjulia.

High-level steps:
1) Copy `libjulia*` and `libjulia-internal*` to salted basenames next to originals.
2) Set each salted library's install_name id to `@rpath/<salted>`; no SONAME on macOS.
3) Rewrite all load commands (install_name) in the built artifact and salted libs
   to point to the salted basenames using `@rpath/`.
4) Create minimal unsalted symlinks (short/medium) pointing to the salted full for loader convenience.
5) Remove originals. Codesigning is handled in bundling.
"""

function privatize_libjulia_macos!(recipe::BundleRecipe)
    try
        privatize_libjulia_common!(
            recipe;
            platform_ext = ".dylib",
            install_name_id_func! = install_name_id!,
            install_name_change_func! = install_name_change!,
            set_soname_func! = nothing,  # macOS doesn't use SONAME
            get_deps_func = get_dependencies_macos,
            dep_prefix = "@rpath/"
        )
    catch e
        @warn "Failed to privatize libjulia on macOS" exception=e
        rethrow()
    end
end

# macOS-specific dependency extraction
function get_dependencies_macos(bin::String)
    out = try
        read(`otool -L $(bin)`, String)
    catch
        return String[]
    end
    lines = split(out, '\n')
    deps = String[]
    for i in 2:length(lines)
        line = strip(lines[i])
        isempty(line) && continue
        sp = findfirst(' ', line)
        if sp !== nothing
            push!(deps, strip(line[1:prevind(line, first(sp))]))
        end
    end
    return deps
end

function install_name_id!(libpath::String, new_id::String)
    run(`install_name_tool -id $(new_id) $(libpath)`)
end

function install_name_change!(binpath::String, old_id::String, new_id::String)
    run(`install_name_tool -change $(old_id) $(new_id) $(binpath)`)
end

function _codesign_bundle!(recipe::BundleRecipe)
    cs = Sys.which("codesign")
    xattr = Sys.which("xattr")
    cs === nothing && return
    libroot = joinpath(recipe.output_dir, recipe.libdir)
    to_sign = String[]
    if isdir(libroot)
        for (r, _, files) in walkdir(libroot)
            for f in files
                p = joinpath(r, f)
                if endswith(p, ".dylib") || endswith(p, ".so") || endswith(p, ".bundle") || endswith(p, ".dylib")
                    push!(to_sign, p)
                end
            end
        end
    end
    # Also sign the primary artifact (exe or dylib)
    if isfile(recipe.link_recipe.outname)
        push!(to_sign, recipe.link_recipe.outname)
    end
    # Clear quarantine attributes first
    if xattr !== nothing
        for p in to_sign
            run(`$xattr -dr com.apple.quarantine $p`)
        end
    end
    # Narrow signing set: primary artifact and salted libjulia* copies only
    salted_re = r"^[A-Za-z0-9_-]+_libjulia.*\.(dylib|so|bundle)$"
    filtered = String[]
    for p in unique(to_sign)
        b = basename(p)
        if p == recipe.link_recipe.outname || occursin(salted_re, b)
            push!(filtered, p)
        end
    end
    # Perform deep ad-hoc signing
    for p in filtered
        # Skip symlinks; signing them is unnecessary and noisy
        if islink(p)
            continue
        end
        run(`$cs -f -s - --deep --timestamp=none $p`)
    end
end
