# This file is a part of Julia. License is MIT: https://julialang.org/license

# Script to run in the process that generates juliac's object file output

# Initialize some things not usually initialized when output is requested
Sys.__init__()
Base.reinit_stdio()
Base.init_depot_path()
Base.init_load_path()
Base.init_active_project()
task = current_task()
task.rngState0 = 0x5156087469e170ab
task.rngState1 = 0x7431eaead385992c
task.rngState2 = 0x503e1d32781c2608
task.rngState3 = 0x3a77f7189200c20b
task.rngState4 = 0x5502376d099035ae
uuid_tuple = (UInt64(0), UInt64(0))
ccall(:jl_set_module_uuid, Cvoid, (Any, NTuple{2, UInt64}), Base.__toplevel__, uuid_tuple)
if Base.get_bool_env("JULIA_USE_FLISP_PARSER", false) === false
    Base.JuliaSyntax.enable_in_core!()
end

# Parse named arguments (avoid soft scope issues by using a `let` block)
#
# Recognized flags:
#   --source <path>              : Required. Source file or package directory to load.
#   --output-<type>              : One of: exe | lib | sysimage | o | bc. Controls entrypoint setup.
#   --compile-ccallable          : Export ccallable entrypoints (for shared libraries).
#   --use-loaded-libs            : Enable Libdl.dlopen override to reuse existing loads.
#   --scripts-dir <path>         : Directory containing build helper scripts.
#   --export-abi <path>          : Emit JSON ABI spec
#   --link-native <specs>        : Comma-separated `Pkg_jll` / `Pkg_jll.product` specs
#                                  whose libraries are bound via direct external
#                                  symbols at link time, resolved through each
#                                  package's JLL.toml record.
#   --link-inputs <path>         : Where to write the link-inputs manifest consumed
#                                  by the driver's link step (required with --link-native).
#   --export-foreign-deps <path> : Write a JSON manifest of every ccall/cglobal site.
source_path, output_type, add_ccallables, use_loaded_libs, scripts_dir, export_abi,
        link_native_libs, link_native_blas, link_inputs_path, export_foreign_deps = let
    source_path = ""
    output_type = ""
    add_ccallables = false
    use_loaded_libs = false
    scripts_dir = abspath(dirname(PROGRAM_FILE))
    export_abi = nothing
    link_native_libs = String[]
    link_native_blas = nothing
    link_inputs_path = nothing
    export_foreign_deps = nothing
    it = Iterators.Stateful(ARGS)
    for arg in it
        if startswith(arg, "--source=")
            source_path = split(arg, "=", limit=2)[2]
        elseif arg == "--source"
            nextarg = popfirst!(it)
            nextarg === nothing && error("Missing value for --source")
            source_path = nextarg
        elseif startswith(arg, "--scripts-dir=")
            scripts_dir = split(arg, "=", limit=2)[2]
        elseif arg == "--scripts-dir"
            nextarg = popfirst!(it)
            nextarg === nothing && error("Missing value for --scripts-dir")
            scripts_dir = nextarg
        elseif arg == "--output-exe" || arg == "--output-lib" || arg == "--output-sysimage" || arg == "--output-o" || arg == "--output-bc"
            output_type = arg
        elseif arg == "--compile-ccallable" || arg == "--add-ccallables"
            add_ccallables = true
        elseif arg == "--use-loaded-libs"
            use_loaded_libs = true
        elseif arg == "--export-abi"
            export_abi = popfirst!(it)
        elseif startswith(arg, "--link-native=")
            names = split(arg, "=", limit=2)[2]
            append!(link_native_libs, String(n) for n in split(names, ',', keepempty=false))
        elseif arg == "--link-native"
            names = popfirst!(it)
            names === nothing && error("Missing value for --link-native")
            append!(link_native_libs, String(n) for n in split(names, ',', keepempty=false))
        elseif startswith(arg, "--link-native-blas=")
            link_native_blas = split(arg, "=", limit=2)[2]
        elseif arg == "--link-native-blas"
            link_native_blas = popfirst!(it)
            link_native_blas === nothing && error("Missing value for --link-native-blas")
        elseif startswith(arg, "--link-inputs=")
            link_inputs_path = split(arg, "=", limit=2)[2]
        elseif arg == "--link-inputs"
            link_inputs_path = popfirst!(it)
            link_inputs_path === nothing && error("Missing value for --link-inputs")
        elseif startswith(arg, "--export-foreign-deps=")
            export_foreign_deps = split(arg, "=", limit=2)[2]
        elseif arg == "--export-foreign-deps"
            export_foreign_deps = popfirst!(it)
            export_foreign_deps === nothing && error("Missing value for --export-foreign-deps")
        end
    end
    source_path == "" && error("Missing required --source <path>")
    (source_path, output_type, add_ccallables, use_loaded_libs, scripts_dir, export_abi,
     link_native_libs, link_native_blas, link_inputs_path, export_foreign_deps)
end

# Native-link policy / foreign-deps export. Both must be registered with the
# runtime before any user code (and therefore any ccall lowering) runs.
if !isempty(link_native_libs) || link_native_blas !== nothing
    link_inputs_path !== nothing ||
        error("--link-native requires --link-inputs (passed automatically by the juliac driver)")
    include(joinpath(scripts_dir, "juliac-link-native.jl"))
    JuliaCLinkNative.resolve_and_register!(link_native_libs, String(link_inputs_path);
        blas_provider = link_native_blas === nothing ? nothing : String(link_native_blas))
end
if export_foreign_deps !== nothing
    let handle = Base.Libc.Libdl.dlopen("libjulia-internal"; throw_error=false)
        if handle === nothing ||
                Base.Libc.Libdl.dlsym(handle, :jl_set_foreign_deps_export_path; throw_error=false) === nothing
            error("--export-foreign-deps requires a Julia runtime with native-link support; " *
                  "this Julia ($(VERSION)) does not provide it.")
        end
    end
    ccall(:jl_set_foreign_deps_export_path, Cvoid, (Cstring,), export_foreign_deps)
end

# Load user code

import Base.Experimental.entrypoint

# for use as C main if needed
function _main(argc::Cint, argv::Ptr{Ptr{Cchar}})::Cint
    args = ccall(:jl_set_ARGS, Any, (Cint, Ptr{Ptr{Cchar}}), argc, argv)::Vector{String}
    setglobal!(Base, :PROGRAM_FILE, args[1])
    popfirst!(args)
    append!(Base.ARGS, args)
    exit(Main.main(args))
end

# Resolve the package name from a project file's `name` entry
function get_pkgname(source_path)
    pkgname = nothing
    for project_name in Base.project_names
        path = joinpath(source_path, project_name)
        if isfile(path)
            name = get(Base.parsed_toml(path), "name", nothing)
            if name !== nothing
                return Symbol(name::String)
            end
        end
    end
    return nothing
end

let usermod
    if isdir(source_path)
        pkgname = get_pkgname(source_path)
        pkgname === nothing && error("Could not determine a package name: no `name` entry in a Project.toml under \"$source_path\"")
        Base.eval(Main, :(using $pkgname))
        Core.@latestworld
        usermod = getglobal(Main, pkgname)
    else
        include_result = Base.include(Main, source_path)
        usermod = Main
    end
    Core.@latestworld
    if output_type == "--output-exe"
        if usermod !== Main && isdefined(usermod, :main)
            Base.eval(Main, :(import $pkgname.main))
        end
        Core.@latestworld
        have_cmain = false
        if isdefined(Main, :main)
            for m in methods(Main.main)
                if isdefined(m, :ccallable)
                    # TODO: possibly check signature and return type
                    have_cmain = true
                    break
                end
            end
        end
        if !have_cmain
            if Base.should_use_main_entrypoint()
                if hasmethod(Main.main, Tuple{Vector{String}})
                    entrypoint(_main, (Cint, Ptr{Ptr{Cchar}}))
                    Base._ccallable("main", Cint, Tuple{typeof(_main), Cint, Ptr{Ptr{Cchar}}})
                else
                    error("`@main` must accept a `Vector{String}` argument.")
                end
            else
                error("To generate an executable a `@main` function must be defined.")
            end
        end
    end
    #entrypoint(join, (Base.GenericIOBuffer{Memory{UInt8}}, Array{Base.SubString{String}, 1}, String))
    #entrypoint(join, (Base.GenericIOBuffer{Memory{UInt8}}, Array{String, 1}, Char))
    if add_ccallables
        if isdefined(Base.Compiler, :add_ccallable_entrypoints!)
            Base.Compiler.add_ccallable_entrypoints!()
        else
            ccall(:jl_add_ccallable_entrypoints, Cvoid, ())
        end
    end
end

if export_abi !== nothing
    include(joinpath(@__DIR__, "..", "abi_export.jl"))
    Core.@latestworld
    open(export_abi, "w") do io
        write_abi_metadata(io)
    end
end

# Run the verifier in the current world (before build-script modifications),
# so that error messages and types print in their usual way.
Core.Compiler._verify_trim_world_age[] = Base.get_world_counter()

if Base.JLOptions().trim != 0
    include(joinpath(scripts_dir, "juliac-trim-base.jl"))
    include(joinpath(scripts_dir, "juliac-trim-stdlib.jl"))
end

# Optionally install Libdl overrides to reuse existing loaded libs on absolute dlopen
if use_loaded_libs
    include(joinpath(scripts_dir, "juliac-libdl-overrides.jl"))
end

entrypoint(Base.task_done_hook, (Task,))
entrypoint(Base.wait, ())
if isdefined(Base, :poptask)
    entrypoint(Base.poptask, (Base.StickyWorkqueue,))
end
if isdefined(Base, :wait_forever)
    entrypoint(Base.wait_forever, ())
end
entrypoint(Base.trypoptask, (Base.StickyWorkqueue,))
entrypoint(Base.checktaskempty, ())

empty!(Core.ARGS)
empty!(Base.ARGS)
empty!(LOAD_PATH)
empty!(DEPOT_PATH)
empty!(Base.TOML_CACHE.d)
Base.TOML.reinit!(Base.TOML_CACHE.p, "")
Base.ACTIVE_PROJECT[] = nothing
@eval Base begin
    PROGRAM_FILE = ""
end
@eval Sys begin
    BINDIR = ""
    STDLIB = ""
end
