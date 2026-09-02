# This file is a part of Julia. License is MIT: https://julialang.org/license

# Patches to stdlib needed for trimming

let
    find_loaded_root_module(key::Base.PkgId) = Base.maybe_root_module(key)

    SparseArrays = find_loaded_root_module(Base.PkgId(
        Base.UUID("2f01184e-e22b-5df5-ae63-d93ebab69eaf"), "SparseArrays"))
    if SparseArrays !== nothing && Base.USE_GPL_LIBS
        @eval SparseArrays.CHOLMOD begin
            function __init__()
                ccall((:SuiteSparse_config_malloc_func_set, :libsuitesparseconfig),
                    Cvoid, (Ptr{Cvoid},), cglobal(:jl_malloc, Ptr{Cvoid}))
                ccall((:SuiteSparse_config_calloc_func_set, :libsuitesparseconfig),
                    Cvoid, (Ptr{Cvoid},), cglobal(:jl_calloc, Ptr{Cvoid}))
                ccall((:SuiteSparse_config_realloc_func_set, :libsuitesparseconfig),
                    Cvoid, (Ptr{Cvoid},), cglobal(:jl_realloc, Ptr{Cvoid}))
                ccall((:SuiteSparse_config_free_func_set, :libsuitesparseconfig),
                Cvoid, (Ptr{Cvoid},), cglobal(:jl_free, Ptr{Cvoid}))
            end
        end
    end

    Artifacts = find_loaded_root_module(Base.PkgId(
        Base.UUID("56f22d72-fd6d-98f1-02f0-08ddc0907c33"), "Artifacts"))
    if Artifacts !== nothing
        @eval Artifacts begin
            # `Overrides.toml` is not consulted: `load_overrides` parses it into
            # `Dict{Symbol,Any}` tables, dynamic calls the trim verifier cannot
            # resolve. The closed world resolves artifacts by depot layout only.
            # This is also what `Base.string(::LazyJLLWrappers.LazyArtifactDir)`
            # reaches, so artifact-backed lazy library paths verify through it.
            function artifact_path(hash::SHA1; honor_overrides::Bool=true)
                possible_paths = artifacts_dirs(bytes2hex(hash.bytes))
                for p in possible_paths
                    if isdir(p)
                        return p
                    end
                end
                # If none exist, then just return the one that would exist within `depots1()`.
                return first(possible_paths)
            end

            function _artifact_str(
                __module__,
                artifacts_toml,
                name,
                path_tail,
                artifact_dict,
                hash,
                platform,
                _::Val{LazyArtifacts}
            ) where LazyArtifacts
                # If the artifact exists, we're in the happy path and we can immediately
                # return the path to the artifact:
                dir = artifact_path(hash)
                isdir(dir) || error("Artifact not found")
                return jointail(dir, path_tail)
            end
        end
    end

    Pkg = find_loaded_root_module(Base.PkgId(
        Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"))
    if Pkg !== nothing
        @eval Pkg begin
            __init__() = rand() #TODO, methods that do nothing don't get codegened
        end
    end

    StyledStrings = find_loaded_root_module(Base.PkgId(
        Base.UUID("f489334b-da3d-4c2e-b8f0-e476e12c162b"), "StyledStrings"))
    if StyledStrings !== nothing
        @eval StyledStrings begin
            __init__() = rand()
        end
    end

    Markdown = find_loaded_root_module(Base.PkgId(
        Base.UUID("d6f4376e-aef5-505a-96c1-9c027394607a"), "Markdown"))
    if Markdown !== nothing
        @eval Markdown begin
            __init__() = rand()
        end
    end

    JuliaSyntaxHighlighting = find_loaded_root_module(Base.PkgId(
        Base.UUID("ac6e5ff7-fb65-4e79-a425-ec3bc9c03011"), "JuliaSyntaxHighlighting"))
    if JuliaSyntaxHighlighting !== nothing
        @eval JuliaSyntaxHighlighting begin
            __init__() = rand()
        end
    end
end
