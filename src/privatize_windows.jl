"""
Windows-specific privatization for libjulia.

Unlike the Unix paths (salt-rename via `privatize_libjulia_common!`), Windows has no
SONAME, no symbol versioning, and no DT_NEEDED, so a different mechanism is used:

1. Inject an SxS private-assembly `RT_MANIFEST` resource into the built product
   (`.exe`/`.dll`). Its `<file>` entries list the bundled `libjulia*.dll` siblings,
   creating an activation context that makes the loader prefer the copies sitting in the
   product's own directory over any same-named DLL already on `PATH`.
2. Strip the stale `../bin/` prefix from the bundled `libjulia.dll`'s embedded,
   colon-separated library search path (the flat `bin/` bundle layout has no `../bin/`).

This file is standalone: it does not use `PrivatizePlatform` / the `plat_*` hooks and never
calls `privatize_libjulia_common!`.
"""

using ObjectFile
using StructIO
import ObjectFile: COFF, Sections, section_address, section_offset, findfirst

# Dir holding rsrc.bin (88-byte precompiled RT_MANIFEST header); @path so it survives bundling.
const TEMPLATE_DIR = @path joinpath(@__DIR__, "template")

# Offsets of the two patched UInt32 fields from the start of the .rsrc section (IMAGE_RESOURCE_DATA_ENTRY @ 0x48).
const MANIFEST_ADDRESS_OFFSET = UInt(0x48)  # IMAGE_RESOURCE_DATA_ENTRY.OffsetToData
const MANIFEST_SIZE_OFFSET    = UInt(0x4c)  # IMAGE_RESOURCE_DATA_ENTRY.Size

"""
    generate_manifest_xml(identity_name, dll_names) -> Vector{UInt8}

Build the SxS private-assembly RT_MANIFEST XML. `identity_name` is the assembly identity
label; `dll_names` is the list of DLL filenames to redirect to the product's own directory.
Returns the UTF-8 bytes.
"""
function generate_manifest_xml(identity_name::AbstractString, dll_names)
    io = IOBuffer()
    print(io, "<assembly xmlns=\"urn:schemas-microsoft-com:asm.v1\" manifestVersion=\"1.0\">\n")
    print(io, "    <assemblyIdentity type=\"win32\" name=\"", identity_name,
              "\" version=\"1.0.0.0\"></assemblyIdentity>\n")
    for dll in dll_names
        print(io, "    <file name=\"", dll, "\"></file>\n")
    end
    print(io, "</assembly>\n")
    return Vector{UInt8}(String(take!(io)))
end

# Per-product SxS assembly identity from the product basename (avoids SxS-cache clashes), name-safe.
function manifest_identity_for(product_path::AbstractString)
    stem = first(splitext(basename(product_path)))      # strip .exe/.dll
    safe = replace(stem, r"[^A-Za-z0-9._-]" => "_")
    return string("JuliaC.PrivateRuntime.", safe)
end

# The libjulia DLLs the manifest may redirect, in canonical order.
const LIBJULIA_DLL_CANDIDATES =
    ("libjulia.dll", "libjulia-internal.dll", "libjulia-codegen.dll")

"""
    inject_private_manifest!(product_path, dll_names)

Add the SxS `RT_MANIFEST` resource (listing `dll_names`) to the PE at `product_path`:
build a `.rsrc` payload (precompiled header ++ generated manifest ++ 4-byte pad), add it as
a `.rsrc` section with mingw `objcopy`, then patch the COFF optional header's ResourceTable
data directory and the section's internal manifest address/size fields.
"""
function inject_private_manifest!(product_path, dll_names)
    header = read(joinpath(TEMPLATE_DIR, "rsrc.bin"))
    manifest = generate_manifest_xml(manifest_identity_for(product_path), dll_names)

    # Build the section payload: header ++ manifest ++ pad-to-4-bytes.
    sectionfile = joinpath(dirname(product_path), "rsrc.bin")
    open(sectionfile, "w") do rsrc_bin
        write(rsrc_bin, header)
        write(rsrc_bin, manifest)
        if length(manifest) % sizeof(UInt32) != 0
            padding_size = sizeof(UInt32) - length(manifest) % sizeof(UInt32)
            write(rsrc_bin, zeros(UInt8, padding_size))
        end
    end

    # Add the section using objcopy from the mingw artifact already used for linking.
    objcopy = mingw_tool("objcopy.exe")            # WINDOWS-CI-ONLY: artifact + run
    run(`$objcopy --add-section .rsrc=$sectionfile --set-section-flags .rsrc=data $product_path`)
    rm(sectionfile)

    # Re-open and patch the headers now that objcopy has placed the section.
    open(product_path, read=true, write=true, create=false, truncate=false) do io
        oh = only(ObjectFile.readmeta(io))
        rsrc_section = findfirst(Sections(oh), ".rsrc")
        rsrc_section === nothing && error("objcopy did not create a .rsrc section in $product_path")

        # 1) Patch the optional header's ResourceTable data directory.
        magic = oh.opt_header.standard.Magic
        datadirs_offset = if magic == COFF.OPTHEADER_STANDARD_MAGIC32
            oh.header_offset + sizeof(COFF.COFFHeader) + sizeof(COFF.COFFOptionalHeaderStandard) +
                sizeof(UInt32) + sizeof(COFF.COFFOptionalHeaderWindows32)
        elseif magic == COFF.OPTHEADER_STANDARD_MAGIC64
            oh.header_offset + sizeof(COFF.COFFHeader) + sizeof(COFF.COFFOptionalHeaderStandard) +
                sizeof(COFF.COFFOptionalHeaderWindows64)
        else
            error("unexpected COFF optional-header magic: 0x$(string(magic, base=16))")
        end
        seek(oh, datadirs_offset + PatchVersion.fieldname_offset(COFF.COFFDataDirectories, :ResourceTable))
        pack(ObjectFile.handle(oh).io, COFF.COFFImageDataDirectory(
            #= VirtualAddress =# section_address(rsrc_section),
            #= Size          =# rsrc_section.section.VirtualSize,
        ))

        # 2) Patch the .rsrc data-entry's manifest address + size (relative until VA known).
        seek(oh, section_offset(rsrc_section) + MANIFEST_ADDRESS_OFFSET)
        write(ObjectFile.handle(oh).io, UInt32(section_address(rsrc_section) + sizeof(header)))
        seek(oh, section_offset(rsrc_section) + MANIFEST_SIZE_OFFSET)
        write(ObjectFile.handle(oh).io, UInt32(length(manifest)))
    end
    return nothing
end

"""
    fix_libjulia_libpath!(libjulia_path)

Strip the stale `../bin/` prefix from the bundled `libjulia.dll`'s embedded, colon-separated
library search path (rewriting `@../bin/` -> `@`), in place, NUL-terminated. The rewrite only
removes bytes, so it never grows the string and is safe to do in place.
"""
function fix_libjulia_libpath!(libjulia_path)
    if !isfile(libjulia_path)
        error("Unable to open libjulia.dll at $(libjulia_path)")
    end
    open(libjulia_path, read = true, write = true) do io
        needle = "../bin/"
        readuntil(io, needle)
        skip(io, -length(needle))
        libpath_offset = position(io)

        libpath = split(String(readuntil(io, UInt8(0))), ":")
        libpath = map(libpath) do l
            if startswith(l, "../bin/")
                return l[8:end]
            elseif startswith(l, "@../bin/")
                return "@" * l[9:end]
            end
            return l
        end

        seek(io, libpath_offset)
        write(io, join(libpath, ":"))
        write(io, UInt8(0))
    end
end

# The libjulia DLLs actually present in the bundle bin/ dir, in canonical order.
function present_libjulia_dlls(bindir)
    return [dll for dll in LIBJULIA_DLL_CANDIDATES if isfile(joinpath(bindir, dll))]
end

"""
Windows privatization entry point: inject the SxS manifest into the built product and fix
the bundled libjulia.dll's embedded libpath. Standalone; does not use the plat_* hooks.
"""
function privatize_libjulia_windows!(recipe::BundleRecipe)
    try
        # On Windows the bundle libdir is "bin" and the product + DLLs are co-located there.
        bindir = joinpath(recipe.output_dir, recipe.libdir)
        product = recipe.link_recipe.outname
        libjulia = joinpath(bindir, "libjulia.dll")

        dll_names = present_libjulia_dlls(bindir)
        isempty(dll_names) && error("no libjulia*.dll found in $bindir to privatize")

        inject_private_manifest!(product, dll_names)
        fix_libjulia_libpath!(libjulia)
    catch e
        error("Failed to privatize libjulia on Windows", e)
    end
    return nothing
end
