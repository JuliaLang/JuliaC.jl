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
        @warn "Failed to privatize libjulia on macOS" exception=(e, catch_backtrace())
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

