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

# Per-product SxS assembly identity from the product basename + salt (avoids SxS-cache clashes), name-safe.
function manifest_identity_for(product_path::AbstractString, salt::AbstractString)
    stem = first(splitext(basename(product_path)))      # strip .exe/.dll
    safe = replace(stem, r"[^A-Za-z0-9._-]" => "_")
    return string("JuliaC.PrivateRuntime.", safe, ".", salt)
end

# The libjulia DLLs the manifest may redirect, in canonical order.
const LIBJULIA_DLL_CANDIDATES =
    ("libjulia.dll", "libjulia-internal.dll", "libjulia-codegen.dll")

"""
    next_free_section_vma(product_path) -> UInt64

Return the virtual address at which a new section can be appended to the PE at
`product_path`: the image base plus the end of the last section's virtual extent, rounded up
to `SectionAlignment`. Sections must be listed in ascending RVA order and lie inside
`SizeOfImage`, so a new section has to go past every existing one.
"""
function next_free_section_vma(product_path)
    open(product_path) do io
        oh = only(ObjectFile.readmeta(io))
        win = oh.opt_header.windows
        align = UInt64(win.SectionAlignment)
        last_rva = UInt64(0)
        for section in Sections(oh)
            last_rva = max(last_rva,
                           UInt64(section_address(section)) + UInt64(section.section.VirtualSize))
        end
        return UInt64(win.ImageBase) + cld(last_rva, align) * align
    end
end

"""
    inject_private_manifest!(product_path, dll_names, salt)

Add the SxS `RT_MANIFEST` resource (listing `dll_names`) to the PE at `product_path`:
build a `.rsrc` payload (precompiled header ++ generated manifest ++ 4-byte pad), add it as
a `.rsrc` section with mingw `objcopy`, then patch the COFF optional header's ResourceTable
data directory and the section's internal manifest address/size fields.
"""
function inject_private_manifest!(product_path, dll_names, salt::AbstractString)
    header = read(joinpath(TEMPLATE_DIR, "rsrc.bin"))
    manifest = generate_manifest_xml(manifest_identity_for(product_path, salt), dll_names)

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
    # `--change-section-address` is mandatory: objcopy defaults a newly added section's VMA
    # to 0, which is *below* the image base mingw's `--enable-auto-image-base` assigns to
    # these products. objcopy then warns "section below image base" and stores a nonsense
    # RVA outside SizeOfImage, and the loader rejects the file with ERROR_BAD_EXE_FORMAT
    # ("%1 is not a valid Win32 application"). Placing it at the first free VA past the last
    # section keeps the section table RVA-ordered and lets objcopy grow SizeOfImage for us.
    objcopy = mingw_tool("objcopy.exe")            # WINDOWS-CI-ONLY: artifact + run
    rsrc_vma = next_free_section_vma(product_path)
    run(`$objcopy --add-section .rsrc=$sectionfile --set-section-flags .rsrc=data --change-section-address .rsrc=$(rsrc_vma) $product_path`)
    rm(sectionfile)

    # Re-open and patch the headers now that objcopy has placed the section.
    open(product_path; read=true, write=true, create=false, truncate=false) do io
        oh = only(ObjectFile.readmeta(io))
        rsrc_section = findfirst(Sections(oh), ".rsrc")
        rsrc_section === nothing && error("objcopy did not create a .rsrc section in $product_path")
        # objcopy signals a bad placement only as a stderr warning with exit 0, so verify it
        # actually honored the requested address before trusting the section's RVA below.
        placed_vma = UInt64(oh.opt_header.windows.ImageBase) + UInt64(section_address(rsrc_section))
        placed_vma == rsrc_vma || error("objcopy placed .rsrc at $(repr(placed_vma)), expected $(repr(rsrc_vma)) in $product_path")

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
    fix_libjulia_libpath!(libjulia_path, present_dlls, salt)

Rewrite the bundled `libjulia.dll` loader's embedded, colon-separated, NUL-terminated
dependency list in place so that any `libjulia*.dll` entry whose file is not shipped in the
bundle (e.g. `libjulia-codegen.dll` under `--trim`, removed by
`remove_unnecessary_libraries`) is renamed to a salted, same-length name that cannot resolve.

A bare-name `LoadLibrary` on Windows matches already-loaded modules by basename, so when the
product is loaded into a process that already hosts Julia the loader would otherwise bind the
*host's* copy of a DLL we didn't ship instead of failing cleanly into its codegen fallback
stubs (`codegen-stubs.c`). Renaming the entry to something unresolvable mirrors what the
salted SONAME/install-name rewrite achieves on Linux/macOS. Same-length replacement is
enforced so no other byte of the loader moves.
"""
function fix_libjulia_libpath!(libjulia_path, present_dlls::Vector{String}, salt::AbstractString)
    if !isfile(libjulia_path)
        error("Unable to open libjulia.dll at $(libjulia_path)")
    end
    data = read(libjulia_path)
    # Anchor on the one entry every Julia ships; the list looks like
    # "libgcc_s_seh-1.dll:libopenlibm.dll:@:@libjulia-internal.dll:@libjulia-codegen.dll:\0"
    # where a leading `@` means "relative to the loader's own directory".
    anchor = findfirst(codeunits("@libjulia-internal.dll:"), data)
    anchor === nothing && error("could not locate the embedded dependency list in $(libjulia_path)")
    lo = something(findprev(iszero, data, first(anchor)), 0) + 1
    hi = something(findnext(iszero, data, first(anchor)), lastindex(data) + 1) - 1
    entries = map(split(String(data[lo:hi]), ':')) do l
        at, name = startswith(l, "@") ? ("@", String(l[2:end])) : ("", String(l))
        if startswith(name, "libjulia") && endswith(name, ".dll") && !(name in present_dlls)
            stem = name[1:end-4]
            name = rpad(first(salt, length(stem)), length(stem), '_') * ".dll"
        end
        at * name
    end
    newlist = join(entries, ':')
    ncodeunits(newlist) == hi - lo + 1 ||
        error("dependency list rewrite changed its length in $(libjulia_path)")
    data[lo:hi] = codeunits(newlist)
    write(libjulia_path, data)
    return nothing
end

# The libjulia DLLs actually present in the bundle bin/ dir, in canonical order.
function present_libjulia_dlls(bindir)
    return [dll for dll in LIBJULIA_DLL_CANDIDATES if isfile(joinpath(bindir, dll))]
end

"""
Windows privatization entry point: inject the SxS manifest into the built product and fix
the bundled libjulia.dll's embedded libpath. Standalone; does not use the plat_* hooks.
"""
function privatize_libjulia_windows!(recipe::BundleRecipe, salt::String)
    try
        # On Windows the bundle libdir is "bin" and the product + DLLs are co-located there.
        bindir = joinpath(recipe.output_dir, recipe.libdir)
        product = recipe.link_recipe.outname
        libjulia = joinpath(bindir, "libjulia.dll")

        dll_names = present_libjulia_dlls(bindir)
        isempty(dll_names) && error("no libjulia*.dll found in $bindir to privatize")

        inject_private_manifest!(product, dll_names, salt)
        fix_libjulia_libpath!(libjulia, dll_names, salt)
    catch e
        error("Failed to privatize libjulia on Windows", e)
    end
    return nothing
end
