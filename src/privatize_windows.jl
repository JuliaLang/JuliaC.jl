# Windows privatization for libjulia: pin the built product to the `libjulia*.dll` copies
# bundled beside it, with two PE-level edits driven directly from this file.
#
# 1. `inject_private_manifest!` gives the product an SxS private-assembly `RT_MANIFEST`
#    resource whose `<file>` entries name the bundled `libjulia*.dll` siblings. The loader
#    resolves those names from the product's own directory, ahead of any same-named DLL
#    on `PATH`.
# 2. `fix_libjulia_libpath!` salts the bundled `libjulia.dll`'s dependency-list entries for
#    the `libjulia*.dll` files the bundle omits, so they resolve nowhere.
#
# PE carries no SONAME, symbol versioning, or DT_NEEDED, so the salt-renaming that
# `privatize_libjulia_common!` performs on Linux and macOS has nothing to act on here.

using ObjectFile
using StructIO
import ObjectFile: COFF, Sections, section_address, section_offset, findfirst

# Holds rsrc.bin, the 88-byte precompiled RT_MANIFEST header; `@path` keeps it resolvable
# after JuliaC itself is bundled.
const TEMPLATE_DIR = @path joinpath(@__DIR__, "template")

# Byte offsets from the start of the .rsrc section; rsrc.bin puts its
# IMAGE_RESOURCE_DATA_ENTRY at 0x48.
const MANIFEST_ADDRESS_OFFSET = UInt(0x48)  # .OffsetToData
const MANIFEST_SIZE_OFFSET    = UInt(0x4c)  # .Size

"""
    generate_manifest_xml(identity_name, dll_names) -> Vector{UInt8}

Build the UTF-8 bytes of an SxS private-assembly RT_MANIFEST that redirects each filename in
`dll_names` to the product's own directory, under the assembly identity `identity_name`.
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

# Each product needs its own entry in the SxS assembly cache, so the identity carries both
# the product basename and the salt.
function manifest_identity_for(product_path::AbstractString, salt::AbstractString)
    stem = first(splitext(basename(product_path)))
    safe = replace(stem, r"[^A-Za-z0-9._-]" => "_")
    return string("JuliaC.PrivateRuntime.", safe, ".", salt)
end

# The libjulia DLLs the manifest may redirect.
const LIBJULIA_DLL_CANDIDATES =
    ("libjulia.dll", "libjulia-internal.dll", "libjulia-codegen.dll")

"""
    next_free_section_vma(product_path) -> UInt64

Return the virtual address at which a new section can be appended to the PE at
`product_path`: the image base plus the end of the last section's virtual extent, rounded
up to `SectionAlignment`.

Past the last section is the only free spot: the section table must stay in ascending RVA
order and inside `SizeOfImage`.
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

Give the PE at `product_path` an SxS `RT_MANIFEST` resource listing `dll_names`, so the
loader resolves those DLLs from the product's own directory:

1. Build the payload: precompiled header, generated manifest, pad to a 4-byte multiple.
2. Add it as a `.rsrc` section with mingw `objcopy`, at the address `next_free_section_vma`
   reports.
3. Patch the COFF optional header's ResourceTable data directory and the section's own
   manifest address/size fields.
"""
function inject_private_manifest!(product_path, dll_names, salt::AbstractString)
    header = read(joinpath(TEMPLATE_DIR, "rsrc.bin"))
    manifest = generate_manifest_xml(manifest_identity_for(product_path, salt), dll_names)

    # The payload ends on a 4-byte boundary: resource data is read as UInt32 fields.
    sectionfile = joinpath(dirname(product_path), "rsrc.bin")
    open(sectionfile, "w") do rsrc_bin
        write(rsrc_bin, header)
        write(rsrc_bin, manifest)
        if length(manifest) % sizeof(UInt32) != 0
            padding_size = sizeof(UInt32) - length(manifest) % sizeof(UInt32)
            write(rsrc_bin, zeros(UInt8, padding_size))
        end
    end

    # `--change-section-address` is mandatory: objcopy defaults a new section to VMA 0, below
    # the image base, warns "section below image base", exits 0 anyway, and leaves an RVA
    # outside `SizeOfImage` that the loader rejects with ERROR_BAD_EXE_FORMAT ("%1 is not a
    # valid Win32 application").
    objcopy = mingw_tool("objcopy.exe")
    rsrc_vma = next_free_section_vma(product_path)
    run(`$objcopy --add-section .rsrc=$sectionfile --set-section-flags .rsrc=data --change-section-address .rsrc=$(rsrc_vma) $product_path`)
    rm(sectionfile)

    open(product_path; read=true, write=true, create=false, truncate=false) do io
        oh = only(ObjectFile.readmeta(io))
        rsrc_section = findfirst(Sections(oh), ".rsrc")
        rsrc_section === nothing && error("objcopy did not create a .rsrc section in $product_path")
        # objcopy only warns about a bad placement, so confirm the address before trusting
        # the section's RVA below.
        placed_vma = UInt64(oh.opt_header.windows.ImageBase) + UInt64(section_address(rsrc_section))
        placed_vma == rsrc_vma || error("objcopy placed .rsrc at $(repr(placed_vma)), expected $(repr(rsrc_vma)) in $product_path")

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

        # OffsetToData is an RVA, known only once objcopy has placed the section, so
        # rsrc.bin ships without it and it is patched in here.
        seek(oh, section_offset(rsrc_section) + MANIFEST_ADDRESS_OFFSET)
        write(ObjectFile.handle(oh).io, UInt32(section_address(rsrc_section) + sizeof(header)))
        seek(oh, section_offset(rsrc_section) + MANIFEST_SIZE_OFFSET)
        write(ObjectFile.handle(oh).io, UInt32(length(manifest)))
    end
    return nothing
end

"""
    fix_libjulia_libpath!(libjulia_path, present_dlls, salt)

Salt the dependency-list entries embedded in the bundled `libjulia.dll`: every
`libjulia*.dll` outside `present_dlls` (see `present_libjulia_dlls`) becomes a name that
resolves nowhere, keeping the runtime on its codegen fallback stubs (`codegen-stubs.c`).

The salting matters because a bare-name `LoadLibrary` matches already-loaded modules by
basename: in a process that already hosts Julia, an omitted DLL would bind the *host's*
copy. Under `--trim` the omitted DLL is `libjulia-codegen.dll`, dropped by
`remove_unnecessary_libraries`.

The rewrite is in place and length-preserving; a length change raises an error.
"""
function fix_libjulia_libpath!(libjulia_path, present_dlls::Vector{String}, salt::AbstractString)
    if !isfile(libjulia_path)
        error("no libjulia.dll to patch at $(libjulia_path)")
    end
    data = read(libjulia_path)
    # Anchor on the one entry every Julia ships. The list reads
    # "libgcc_s_seh-1.dll:libopenlibm.dll:@:@libjulia-internal.dll:@libjulia-codegen.dll:\0",
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

function present_libjulia_dlls(bindir)
    return [dll for dll in LIBJULIA_DLL_CANDIDATES if isfile(joinpath(bindir, dll))]
end

"""
    present_libllvm_dlls(bindir) -> Vector{String}

The bundled `libLLVM-*.dll`, if any (its name carries the LLVM major version; trimmed
bundles ship none). The manifest must redirect it alongside the libjulia DLLs: LLVM keeps
its registered-module set in libLLVM's own data segment, so a private `libjulia-codegen`
bound to the host's libLLVM shares that set with the host runtime, and Julia >= 1.14
(JuliaLang/julia#60988) aborts in `JuliaOJIT`'s constructor on the resulting duplicate
registration ("unable to dlopen libjulia dependency / Library already loaded").
"""
function present_libllvm_dlls(bindir)
    isdir(bindir) || return String[]
    return sort!([f for f in readdir(bindir)
                  if startswith(f, "libLLVM") && endswith(f, ".dll")])
end

"""
Windows arm of `privatize_libjulia!`: apply both PE-level edits described at the top of this
file to the bundle in `recipe`.
"""
function privatize_libjulia_windows!(recipe::BundleRecipe, salt::String)
    try
        # The Windows bundle libdir is "bin", holding the product and its DLLs together.
        bindir = joinpath(recipe.output_dir, recipe.libdir)
        product = recipe.link_recipe.outname
        libjulia = joinpath(bindir, "libjulia.dll")

        dll_names = present_libjulia_dlls(bindir)
        isempty(dll_names) && error("no libjulia*.dll found in $bindir to privatize")

        # libLLVM must be redirected too (see `present_libllvm_dlls`), but stays out of
        # `dll_names`: `fix_libjulia_libpath!` rewrites only `libjulia*` dep-list entries.
        inject_private_manifest!(product, vcat(dll_names, present_libllvm_dlls(bindir)), salt)
        fix_libjulia_libpath!(libjulia, dll_names, salt)
    catch e
        error("Failed to privatize libjulia on Windows", e)
    end
    return nothing
end
