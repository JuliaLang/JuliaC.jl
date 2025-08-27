# Pretty-print a directory tree with sizes

function _dir_size(root::AbstractString)
    total = 0
    if isdir(root)
        for (r, _, files) in walkdir(root)
            for f in files
                p = joinpath(r, f)
                islink(p) && continue
                total += stat(p).size
            end
        end
    elseif isfile(root)
        if !islink(root)
            total = stat(root).size
        end
    end
    return total
end

function print_tree_with_sizes(root::AbstractString; io::IO=stdout)
    println(io, "Bundle tree for: ", root)
    # Pre-compute sizes for files
    file_sizes = Dict{String, Int}()
    if isdir(root)
        for (r, _, files) in walkdir(root)
            for f in files
                p = joinpath(r, f)
                islink(p) && continue
                file_sizes[p] = stat(p).size
            end
        end
    end
    # Recursive printer
    function print_node(path::String, prefix::String)
        if isdir(path)
            sz = _dir_size(path)
            println(io, prefix, basename(path), "/ (", Base.format_bytes(sz), ")")
            entries = readdir(path)
            entries = filter(name -> !islink(joinpath(path, name)), entries)
            sort!(entries)
            for (idx, name) in enumerate(entries)
                child = joinpath(path, name)
                islast = idx == length(entries)
                branch = islast ? "└── " : "├── "
                subprefix = islast ? prefix * "    " : prefix * "│   "
                if isdir(child)
                    print(io, prefix, branch)
                    print_node(child, subprefix)
                else
                    szf = get(file_sizes, child, isfile(child) && !islink(child) ? stat(child).size : 0)
                    println(io, prefix, branch, name, " (", Base.format_bytes(szf), ")")
                end
            end
        else
            if !islink(path)
                szf = get(file_sizes, path, isfile(path) ? stat(path).size : 0)
                println(io, prefix, basename(path), " (", Base.format_bytes(szf), ")")
            end
        end
    end
    print_node(abspath(root), "")
    println(io)
end


