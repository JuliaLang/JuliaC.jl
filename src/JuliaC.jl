module JuliaC

using Pkg
using PackageCompiler
using LazyArtifacts

module JuliaConfig
    include(joinpath(Sys.BINDIR, Base.DATAROOTDIR, "julia", "julia-config.jl"))
end

Base.@kwdef mutable struct ImageRecipe
    # codegen options
    cpu_target::Union{String, Nothing} = nothing
    output_type::String = ""
    enable_trim::Bool = false
    trim_mode::Union{String, Nothing} = nothing
    add_ccallables::Bool = false
    # build options
    file::String = ""
    julia_args::Vector{String} = String[]
    project::String = ""
    img_path::String = ""
    # compile-time configuration
    verbose::Bool = false
    # C shim sources to compile and link into the final artifact
    c_sources::Vector{String} = String[]
    cflags::Vector{String} = String[]
    extra_objects::Vector{String} = String[]
end

Base.@kwdef mutable struct LinkRecipe
    image_recipe::ImageRecipe = ImageRecipe()
    outname::String = ""
    rpath::Union{String, Nothing} = nothing
end

Base.@kwdef mutable struct BundleRecipe
    link_recipe::LinkRecipe = LinkRecipe()
    output_dir::Union{String, Nothing} = nothing # if nothing, don't bundle
    libdir::String = Sys.iswindows() ? "bin" : "lib"
    privatize::Bool = false
end

include("compiling.jl")
include("linking.jl")
include("bundling.jl")
include("patchversion.jl")
include("privatize_common.jl")
include("privatize_linux.jl")
include("privatize_macos.jl")

export ImageRecipe, LinkRecipe, BundleRecipe
export compile_products, link_products, bundle_products


# Helper: validate executable name is a bare name (no directories)
_is_name_only(s::AbstractString) = (basename(s) == s) && !isabspath(s) && !occursin('\\', s)

# Print CLI usage/help
function _print_usage(io::IO=stdout)
    println(io, "juliac - compile Julia code into an executable, library, sysimage, object or bitcode")
    println(io)
    println(io, "Usage:")
    println(io, "  juliac [options] <file>")
    println(io)
    println(io, "Options:")
    println(io, "  --output-exe <name>         Output native executable (name only)")
    println(io, "  --output-lib <path>         Output shared library (lib)")
    println(io, "  --output-sysimage <path>    Output shared library (sysimage)")
    println(io, "  --output-o <path>           Output object archive (default for linking)")
    println(io, "  --output-bc <path>          Output LLVM bitcode archive")
    println(io, "  --project <path>            App project to instantiate/precompile")
    println(io, "  --bundle <dir>              Bundle libjulia, stdlibs, and artifacts")
    println(io, "  --privatize                 Privatize bundled libjulia (Unix)")
    println(io, "  --trim[=mode]               Strip IR/metadata (e.g. --trim=safe)")
    println(io, "  --compile-ccallable         Export ccallable entrypoints")
    println(io, "  --experimental              Forwarded to Julia (needed for some --trim)")
    println(io, "  --verbose                   Print commands and timings")
    println(io, "  -h, --help                  Show this help")
    println(io)
    println(io, "Examples:")
    println(io, "  juliac --output-exe app --project ./MyApp --bundle build --trim=safe src/main.jl")
    println(io, "  juliac --output-lib build/libapp --project ./MyApp src/libentry.jl")
end

# CLI app entrypoint for Pkg apps
function _parse_cli_args(args::Vector{String})
    image_recipe = ImageRecipe()
    link_recipe = LinkRecipe(image_recipe=image_recipe)
    bundle_recipe = BundleRecipe(link_recipe=link_recipe)
    bundle_specified = false

    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--output-exe" || arg == "--output-lib" || arg == "--output-sysimage" || arg == "--output-o" || arg == "--output-bc"
            image_recipe.output_type == "" || error("Multiple output types specified")
            image_recipe.output_type = arg
            i == length(args) && error("Output specifier requires an argument")
            name_or_path = args[i+1]
            if arg == "--output-exe" && !_is_name_only(name_or_path)
                error("--output-exe expects a name (no path). Got: " * name_or_path)
            end
            link_recipe.outname = name_or_path
            i += 1
        elseif startswith(arg, "--trim=")
            # Enable trim and parse mode for compile-time handling
            image_recipe.enable_trim = arg != "--trim=no"
            mode = split(arg, '='; limit=2)[2]
            image_recipe.trim_mode = mode
        elseif arg == "--trim"
            image_recipe.enable_trim = true
            image_recipe.trim_mode = "safe"
        elseif arg == "--experimental"
            push!(image_recipe.julia_args, arg)
        elseif arg == "--compile-ccallable"
            image_recipe.add_ccallables = true
        elseif startswith(arg, "--project")
            if occursin('=', arg)
                proj = split(arg, '='; limit=2)[2]
            else
                i == length(args) && error("--project requires an argument")
                proj = args[i+1]
            end
            image_recipe.project = proj
            i += 1
        elseif arg == "--bundle"
            bundle_specified = true
            if i < length(args) && (length(args[i+1]) == 0 || args[i+1][1] != '-')
                bundle_recipe.output_dir = args[i+1]
                i += 1
            end
        elseif arg == "--privatize"
            bundle_recipe.privatize = true
        elseif arg == "--verbose"
            image_recipe.verbose = true
        else
            if arg[1] == '-' || image_recipe.file != ""
                error("Unexpected argument `$arg`")
            end
            image_recipe.file = arg
        end
        i += 1
    end

    link_recipe.outname == "" && error("No output file specified")
    image_recipe.file == "" && error("No input file specified")

    if bundle_specified
        if bundle_recipe.output_dir === nothing
            bundle_recipe.output_dir = abspath(dirname(link_recipe.outname))
        end
        # When bundling, executables are placed in bin/ and libs in lib/ (Windows: all in bin)
        # Set rpath relative to the executable location
        if Sys.iswindows()
            link_recipe.rpath = bundle_recipe.libdir
        else
            link_recipe.rpath = joinpath("..", bundle_recipe.libdir)
        end
    end
    return image_recipe, link_recipe, bundle_recipe
end

function _main_cli(args::Vector{String}; io::IO=stdout)
    if isempty(args) || any(a -> a == "-h" || a == "--help", args)
        _print_usage(io)
        return
    end
    img, link, bun = _parse_cli_args(args)
    compile_products(img)
    link_products(link)
    bundle_products(bun)
end

function (@main)(ARGS)
    _main_cli(ARGS)
end

precompile(main, (Vector{String},))

end # module JuliaC
