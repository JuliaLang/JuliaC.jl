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

# The 88-byte precompiled `.rsrc` resource-directory header. It encodes the tree
#   RT_MANIFEST(24) -> resource id 2 -> langid 0x409 -> IMAGE_RESOURCE_DATA_ENTRY @ 0x48
# with the data entry's OffsetToData (0x48) and Size (0x4c) fields zeroed; those are
# patched after objcopy places the section and the loader-relative VA is known.
# Located via RelocatableFolders @path exactly like SCRIPTS_DIR, so it survives app
# bundling / relocation.
const TEMPLATE_DIR = @path joinpath(@__DIR__, "template")

# Offsets of the two patched UInt32 fields, measured from the start of the .rsrc section.
# Derived by decoding rsrc.bin against the PE format spec:
#   https://learn.microsoft.com/windows/win32/debug/pe-format#the-rsrc-section
# (0x00..0x47 = directory tree, 0x48 = IMAGE_RESOURCE_DATA_ENTRY).
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

# Build a per-product SxS assembly identity from the product basename (avoids identity
# clashes in the SxS cache when multiple bundles co-reside). Sanitized to the name-safe
# charset; generic prefix (no domain language).
function manifest_identity_for(product_path::AbstractString)
    stem = first(splitext(basename(product_path)))      # strip .exe/.dll
    safe = replace(stem, r"[^A-Za-z0-9._-]" => "_")
    return string("JuliaC.PrivateRuntime.", safe)
end

# The libjulia DLLs the manifest may redirect, in canonical order.
const LIBJULIA_DLL_CANDIDATES =
    ("libjulia.dll", "libjulia-internal.dll", "libjulia-codegen.dll")
