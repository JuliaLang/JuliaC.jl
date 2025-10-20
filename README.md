## JuliaC

JuliaC is a companion to PackageCompiler that streamlines turning Julia code into a native executable, shared library, system image, or intermediate object/bitcode. It provides:

- A CLI app `juliac`
- A simple library API with explicit "compile → link → bundle" steps
- Optional bundling of `libjulia`/stdlibs and artifacts for portable distribution
- Optional trimming of IR, metadata, and unreachable code for smaller binaries on Julia 1.12+

Built on top of `PackageCompiler.jl`.

### Requirements

- Julia 1.12+
- A working C compiler (`clang`/`gcc` on macOS/Linux; MSYS2 mingw on Windows)

### Installation
Install JuliaC as a [Julia app](https://pkgdocs.julialang.org/v1/apps/):

```julia
pkg> app add JuliaC
```

Optional: enable `Pkg` app shims on your shell PATH so you can run `juliac` directly:

```bash
echo 'export PATH="$HOME/.julia/bin:$PATH"' >> ~/.bashrc    # adapt for your shell
```

### Quick start (CLI)

Given an app in `test/AppProject` (see the files in this repository),
compile an executable and produce a self-contained bundle in `build/`:

```bash
juliac \
  --output-exe app_test_exe \
  --project test/AppProject\
  --bundle build \
  --trim=safe \
  --experimental \
  --verbose \
  test/AppProject/src/test.jl
```

Notes:
- `--trim[=mode]` enables removing unreachable code; on 1.12 prereleases this implies `--experimental`.
- Define `function @main(args::Vector{String})` in your package or source file to build an executable.

### Quick start (module, no app install)

```bash
julia --project -e "using JuliaC; JuliaC.main(ARGS)" -- \
  --output-exe app_test_exe \
  --project test/AppProject \
  --bundle build \
  --trim=safe \
  --experimental \
  --verbose \
  test/AppProject/src/test.jl
```

### CLI reference

- `--output-exe <name>`: Output native executable name (no path). Use `--bundle` to choose destination directory.
- `--output-lib|--output-sysimage|--output-o|--output-bc <path>`: Output path for non-executable artifacts.
- `--project <path>`: App project to instantiate/precompile (defaults to active project).
- `--bundle <dir>`: Copy required Julia libs/stdlibs and artifacts next to the output; also sets a relative rpath.
- `--trim[=mode]`: Enable IR/metadata trimming (e.g. `--trim=safe`). Use `--trim=no` to disable.
- `--compile-ccallable`: Export `ccallable` entrypoints (see C-callable section).
- `--experimental`: Forwarded to Julia; required for `--trim` on some builds.
- `--verbose`: Print underlying commands and timing.
- `<file>`: The Julia entry file to compile (must define `@main` for executables).

### Library API

```julia
using JuliaC

img = ImageRecipe(
    output_type = "--output-exe",
    file        = "test/AppProject/src/test.jl",
    project     = "test/AppProject",
    trim_mode   = "safe",
    add_ccallables = false,
    verbose     = true,
)

link = LinkRecipe(
    image_recipe = img,
    outname      = "build/app_test_exe",
    rpath        = nothing, # set automatically when bundling
)

bun = BundleRecipe(
    link_recipe = link,
    output_dir  = "build", # or `nothing` to skip bundling
)

compile_products(img)
link_products(link)
bundle_products(bun)
```

### Bundling and rpath

When `--bundle` (or `BundleRecipe.output_dir`) is set, JuliaC:
- Places the executable in `<output_dir>/bin` and libraries in `<output_dir>/lib` and `<output_dir>/lib/julia` (Windows: everything under `<output_dir>/bin`).
- Copies required artifacts alongside the bundle.
- Links your output with a relative rpath so the executable finds sibling libs (Unix uses `@loader_path/../lib` or `$ORIGIN/../lib`).
- On macOS, creates convenience versioned `.dylib` symlinks if missing.

This produces a relocatable directory you can distribute.

### Trimming

On Julia 1.12+, JuliaC can exclude code proven not to be reachable from entry points, reducing
binary size:

```bash
--trim=safe
```

On certain builds, `--trim` requires `--experimental` (JuliaC will pass it through if needed).

### C-callable entrypoints

If you pass `--compile-ccallable` (or set `ImageRecipe.add_ccallables = true`), JuliaC will export `ccallable` entrypoints discovered in your code. This is often used when building libraries intended to be called from C or other languages.

### Platform notes

- macOS/Linux: requires `clang` or `gcc` available on PATH
- Windows: looks for a MinGW compiler via `LazyArtifacts` or `JULIA_CC`
- You can override the compiler with `ENV["JULIA_CC"]` (e.g. `clang`/`gcc` path)

### Acknowledgements

JuliaC builds on `PackageCompiler.jl` and Julia's own build machinery. Many thanks to their authors and contributors.

### Contributing

Issues and PRs are welcome. Please provide OS, Julia version, and a minimal reproducer when reporting problems.

### License

MIT. See the LICENSE file for details.
