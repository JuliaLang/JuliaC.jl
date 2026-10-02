#!/usr/bin/env julia
# This file is a part of Julia. License is MIT: https://julialang.org/license

import Libdl

const options = [
    "--cflags",
    "--ldflags",
    "--ldlibs",
    "--allflags",
    "--framework"
];

function libDir()
    return if Base.isdebugbuild()
        if Base.DARWIN_FRAMEWORK
            joinpath(dirname(abspath(Libdl.dlpath(Base.DARWIN_FRAMEWORK_NAME * "_debug"))),"lib")
        else
            dirname(abspath(Libdl.dlpath("libjulia-debug")))
        end
    else
        if Base.DARWIN_FRAMEWORK
            joinpath(dirname(abspath(Libdl.dlpath(Base.DARWIN_FRAMEWORK_NAME))),"lib")
        else
            dirname(abspath(Libdl.dlpath("libjulia")))
        end
    end
end

function frameworkDir()
    libjulia = Base.isdebugbuild() ?
        Libdl.dlpath(Base.DARWIN_FRAMEWORK_NAME * "_debug") :
        Libdl.dlpath(Base.DARWIN_FRAMEWORK_NAME)
    normpath(joinpath(dirname(abspath(libjulia)),"..","..",".."))
end

private_libDir() = abspath(Sys.BINDIR, Base.PRIVATE_LIBDIR)

function includeDir()
    return abspath(Sys.BINDIR, Base.INCLUDEDIR, "julia")
end

# The flag functions below return one compiler argument per element, so paths
# containing spaces need no quoting. `main` shell-escapes them for printing.

function march_flags()
    if Sys.ARCH === :i686
        return ["-m32", "-march=pentium4"]
    end
    return String[]
end

function ldflags(; framework::Bool=false)
    framework && return ["-F" * frameworkDir()]
    fl = [march_flags(); "-L" * libDir()]
    if Sys.iswindows()
        push!(fl, "-Wl,--stack,8388608")
    elseif !Sys.isapple()
        push!(fl, "-Wl,--export-dynamic")
    end
    return fl
end

function ldrpath()
    libname = if Base.isdebugbuild()
        "julia-debug"
    else
        "julia"
    end
    return ["-Wl,-rpath," * private_libDir(), "-Wl,-rpath," * libDir(), "-l" * libname]
end

function ldlibs(; framework::Bool=false, rpath::Bool=true)
    # Return "Julia" for the framework even if this is a debug build.
    # If the user wants the debug framework, DYLD_IMAGE_SUFFIX=_debug
    # should be used (refer to man 1 dyld).
    framework && return ["-framework", Base.DARWIN_FRAMEWORK_NAME]
    libname = if Base.isdebugbuild()
        "julia-debug"
    else
        "julia"
    end
    if Sys.isunix()
        if rpath
            return ["-L" * private_libDir(); ldrpath()]
        else
            return ["-L" * private_libDir()]
        end
    else
        return ["-l" * libname, "-lopenlibm"]
    end
end

function cflags(; framework::Bool=false)
    flags = ["-std=gnu11"; march_flags()]
    if Sys.ARCH === :i686
        push!(flags, "-Wno-psabi")
    end
    if framework
        push!(flags, "-F" * frameworkDir())
    else
        push!(flags, "-I" * includeDir())
    end
    if Sys.isunix()
        push!(flags, "-fPIC")
    end
    if Sys.isapple()
        push!(flags, "-Wno-nullability-completeness")
    end
    return flags
end

function allflags(; framework::Bool=false, rpath::Bool=true)
    return [cflags(; framework); ldflags(; framework); ldlibs(; framework, rpath)]
end

function check_args(args)
    checked = intersect(args, options)
    if length(checked) == 0 || length(checked) != length(args)
        println(stderr, "Usage: julia-config [", join(options, " | "), "]")
        exit(1)
    end
end

function check_framework_flag(args)
    framework = "--framework" in args
    if framework && !Base.DARWIN_FRAMEWORK
        println(stderr, "NOTICE: Ignoring --framework because Julia is not packaged as a framework.")
        return false
    elseif !framework && Base.DARWIN_FRAMEWORK
        println(stderr, "NOTICE: Consider using --framework because Julia is packaged as a framework.")
        return false
    end
    return framework
end

function (@main)(args)
    check_args(args)
    framework = check_framework_flag(args)
    for args in args
        if args == "--ldflags"
            println(Base.shell_escape(ldflags(; framework)...))
        elseif args == "--cflags"
            println(Base.shell_escape(cflags(; framework)...))
        elseif args == "--ldlibs"
            println(Base.shell_escape(ldlibs(; framework)...))
        elseif args == "--allflags"
            println(Base.shell_escape(allflags(; framework)...))
        end
    end
end
