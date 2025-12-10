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
source_path, output_type, add_ccallables, use_loaded_libs, scripts_dir, export_abi = let
    source_path = ""
    output_type = ""
    add_ccallables = false
    use_loaded_libs = false
    scripts_dir = abspath(dirname(PROGRAM_FILE))
    export_abi = nothing
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
        end
    end
    source_path == "" && error("Missing required --source <path>")
    (source_path, output_type, add_ccallables, use_loaded_libs, scripts_dir, export_abi)
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

let usermod
    if isdir(source_path)
        patharg = source_path
        if endswith(patharg, "/")
            patharg = chop(patharg)
        end
        dname = splitdir(patharg)[2]
        pkgname = Symbol(splitext(dname)[1])
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
