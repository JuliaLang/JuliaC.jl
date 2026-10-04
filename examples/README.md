## JuliaC examples

This directory contains simple examples of how to use the core JuliaC features of
generating executables and shared libraries, together with bundling and/or trimming.

Follow these steps to try out the examples:

### Install the juliac app

```
julia
]app add JuliaC
```

### Generate an executable with trimming

The following commands assume this `examples` directory is your current directory.

```
~/.julia/bin/juliac HelloApp --output-exe hello --trim

./hello
```

### Generate a self-contained bundle for an executable

```
~/.julia/bin/juliac HelloApp --output-exe hello --trim --bundle hellodir

./hellodir/bin/hello
```

### Generate a shared library

```
~/.julia/bin/juliac TinyLibm --output-lib tinylibm --compile-ccallable --trim 

objdump -T tinylibm.so | less
```

With symbol privatization, allowing the library to be loaded within a julia process:

```
~/.julia/bin/juliac TinyLibm --output-lib tinylibm --compile-ccallable --trim --bundle tinylibm --privatize

julia

ccall((:sin, "tinylibm/lib/tinylibm.so"), Float64, (Float64,), 2.1)
```

### Generate a C header file

```
~/.julia/bin/juliac TinyLibm --output-lib tinylibm --compile-ccallable --trim --bundle tinylibm --privatize --export-abi tinylibm.json

julia gen_c_header.jl tinylibm

cat tinylibm.h
```
