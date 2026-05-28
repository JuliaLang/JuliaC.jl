module PatchVersion

export patch_version, patch_version!, read_soname, read_needed, set_soname!, replace_needed!

import ObjectFile: ObjectFile, ELFHandle, StrTab, SectionRef, Sections, strtab_lookup,
    ELF, section_offset, section_size
import .ELF: ELFVerDef, ELFVerdAux, ELFVerNeed, ELFVernAux, ELFHash
using StructIO

function fieldname_offset(s::DataType, f::Symbol)
    i = findfirst((x)->x==f, fieldnames(s))
    fieldoffset(s, i)
end

"""
Replace the string at byte position `pos` from the start of `tab`.
If `newstr` is longer than the existing string, show an error.
"""
function patch_str!(tab::SectionRef, pos, newstr::Vector{UInt8})
    seek(tab, pos)
    old = readuntil(ObjectFile.handle(tab), UInt8(0))
    pad = length(old) - length(newstr)
    if pad < 0
        error(string("Length mismatch; can't overwrite $old with $newstr"))
    elseif pad > 0
        newstr = vcat(newstr, fill(UInt8(0), pad))
    end
    seek(tab, pos)
    write(ObjectFile.handle(tab).io, newstr)
    return nothing
end

"""
Update every (.*)@oldver\0 in a string table
"""
function patch_strtab!(tab::SectionRef, oldver::Vector{UInt8}, newver::Vector{UInt8})
    io = ObjectFile.handle(tab).io
    off = section_offset(tab)
    at_oldver = [UInt8('@'), oldver...]
    n_done = 0

    while off < section_offset(tab) + section_size(tab)
        seek(io, off)
        s = readuntil(ObjectFile.handle(tab), UInt8(0))
        # beginning position of string to maybe cmp with @oldver
        vpos = length(s) - length(at_oldver) + 1
        if vpos > 0 && s[vpos:end] == at_oldver
            patch_str!(tab,
                       off + vpos - section_offset(tab) - 1,
                       [UInt8('@'), newver...])
            n_done += 1
        end
        off += length(s) + 1
    end
    return n_done
end

"""
Update version strings and hashes in-place.  Touches the .dynstr, .gnu.version_d
(definitions), .gnu.version_r (requirements), and .strtab sections unless suppressed.
"""
function patch_version!(infile::AbstractString, oldver::Vector{UInt8}, newver::Vector{UInt8};
                        patch_def=true, patch_need=true, patch_strtab=true)
    if length(oldver) < length(newver)
        error(string("Length mismatch; can't overwrite $oldver with $newver"))
    end

    open(infile, read=true, write=true, create=false, truncate=false) do io
        oh = only(ObjectFile.readmeta(io))
        tab = findfirst(Sections(oh), ".dynstr")

        # patch verdef (and .dynstr table)
        s_vd = findfirst(Sections(oh), ".gnu.version_d")
        off = isnothing(s_vd) ? nothing : section_offset(s_vd.section)
        while !isnothing(off) && patch_def
            seek(oh, off)
            vd = unpack(oh, ELFVerDef{ELFHandle})

            inner_off = off + vd.vd_aux
            for i in 1:vd.vd_cnt
                seek(oh, inner_off)
                vda = unpack(oh, ELFVerdAux{ELFHandle})
                v = Vector{UInt8}(strtab_lookup(StrTab(tab), vda.vda_name))
                if v == oldver
                    patch_str!(tab, vda.vda_name, newver)
                    # the first verdaux entry is "ours" (ELFHash(vda) == vd.vd_hash).
                    # for the others, just patch names.
                    if i == 1
                        seek(oh, off + fieldname_offset(typeof(vd), :vd_hash))
                        write(io, ELFHash(newver))
                    end
                end
                inner_off += vda.vda_next
            end
            off += vd.vd_next
            vd.vd_next == 0 && break
        end

        # patch verneed: similar to verdef, but we might need hash updates
        # without associated .dynstr patches
        s_vn = findfirst(Sections(oh), ".gnu.version_r")
        off = isnothing(s_vn) ? nothing : section_offset(s_vn.section)
        while !isnothing(off) && patch_need
            seek(oh, off)
            vn = unpack(oh, ELFVerNeed{ELFHandle})

            inner_off = off + vn.vn_aux
            for i in 1:vn.vn_cnt
                seek(oh, inner_off)
                vna = unpack(oh, ELFVernAux{ELFHandle})
                v = Vector{UInt8}(strtab_lookup(StrTab(tab), vna.vna_name))
                if v == oldver
                    patch_str!(tab, vna.vna_name, newver)
                end
                if v == oldver || v == newver
                    # hashes are in the aux structs this time
                    seek(oh, inner_off + fieldname_offset(typeof(vna), :vna_hash))
                    write(io, ELFHash(newver))
                end
                inner_off += vna.vna_next
            end
            off += vn.vn_next
            vn.vn_next == 0 && break
        end

        # patch .strtab sym@oldver symbols
        if patch_strtab
            stab = findfirst(Sections(oh), ".strtab")
            patch_strtab!(stab, oldver, newver)
        end
    end
    return nothing
end

function patch_version(infile::AbstractString, oldver::Vector{UInt8}, newver::Vector{UInt8}, outfile::AbstractString; kwargs...)
    cp(infile, outfile; follow_symlinks=true, force=true)
    patch_version!(outfile, oldver, newver; kwargs...)
end

# Handle string versions
patch_version(i, o, n, out; kwargs...) = patch_version(i, Vector{UInt8}(o), Vector{UInt8}(n), out; kwargs...)
patch_version!(i, o, n; kwargs...) = patch_version!(i, Vector{UInt8}(o), Vector{UInt8}(n); kwargs...)

# --- DT_SONAME / DT_NEEDED in-place patching (same-length substitution) -------
#
# These pure-Julia operations replace the patchelf shell-outs previously used by
# the Linux privatization path.  They patch the dynamic string table (.dynstr)
# in place via patch_str! above, which errors if the new string is longer than
# the old one (we never grow the string table).

# The .dynstr SectionRef that a dynamic entry's string lives in, located via the
# .dynamic section's sh_link (the canonical pointer to the dynamic string table).
_dynstr_section(oh, d) = Sections(oh)[ObjectFile.deref(ObjectFile.Section(d)).sh_link + 1]

# Byte offsets (into .dynstr) of every DT_SONAME/DT_NEEDED string -- the only
# dynamic strings we ever patch, used to guard against corrupting an overlapping
# (tail-merged) entry.
_dyn_string_offsets(oh) =
    Int[Int(ObjectFile.deref(d).d_val) for tag in (ELF.DT_SONAME, ELF.DT_NEEDED)
                                       for d in ELF.ELFDynEntries(oh, [tag])]

# Overwrite the .dynstr string referenced by dynamic entry `d` with `newstr`,
# in place (length-preserving or shorter; patch_str! errors on grow).  Refuses
# non-ELF inputs and refuses to patch if another dynamic string starts strictly
# inside the byte range being overwritten.
function _patch_dyn_string!(oh::ELFHandle, d, newstr::Vector{UInt8})
    # Works for any ELF class/endianness: every multi-byte field read goes through
    # ObjectFile.jl/StructIO, which select the 32- vs 64-bit struct layout and
    # byte-swap per the parsed ELF header, and the string bytes we overwrite are
    # raw ASCII (not endianness/width sensitive).  The `oh::ELFHandle` type
    # restriction is the only guard we need (rejects MachO/COFF up front).
    pos = Int(ObjectFile.deref(d).d_val)
    tab = _dynstr_section(oh, d)
    seek(tab, pos)
    oldlen = length(readuntil(ObjectFile.handle(tab), UInt8(0)))
    for o in _dyn_string_offsets(oh)
        if pos < o < pos + oldlen
            error("Refusing in-place .dynstr patch at $pos: a dynamic string starts at $o inside [$pos, $(pos+oldlen))")
        end
    end
    patch_str!(tab, pos, newstr)
    return nothing
end

"""
    read_soname(file)::Union{String,Nothing}

Return the `DT_SONAME` string of an ELF shared object, or `nothing` if it has none.
"""
read_soname(file) = open(file) do io
    oh = only(ObjectFile.readmeta(io))
    es = ELF.ELFDynEntries(oh, [ELF.DT_SONAME])
    isempty(es) ? nothing : String(strtab_lookup(only(es)))
end

"""
    read_needed(file)::Vector{String}

Return all `DT_NEEDED` entries of an ELF shared object, in order.
"""
read_needed(file) = open(file) do io
    oh = only(ObjectFile.readmeta(io))
    String[String(strtab_lookup(d)) for d in ELF.ELFDynEntries(oh, [ELF.DT_NEEDED])]
end

"""
    set_soname!(file, newname)

Rewrite the `DT_SONAME` of an ELF shared object in place.  Errors if `file` has
no `DT_SONAME` or if `newname` is longer than the current soname.
"""
function set_soname!(file, newname)
    open(file, read=true, write=true, create=false, truncate=false) do io
        oh = only(ObjectFile.readmeta(io))
        es = ELF.ELFDynEntries(oh, [ELF.DT_SONAME])
        isempty(es) && error("no DT_SONAME in $file")
        _patch_dyn_string!(oh, only(es), Vector{UInt8}(newname))
    end
end

"""
    replace_needed!(file, oldname, newname)

Rename the single `DT_NEEDED` entry equal to `oldname` to `newname`, in place.
Asserts exactly one entry matches `oldname`; errors if `newname` is longer.
"""
function replace_needed!(file, oldname, newname)
    open(file, read=true, write=true, create=false, truncate=false) do io
        oh = only(ObjectFile.readmeta(io))
        matches = filter(d -> strtab_lookup(d) == oldname, ELF.ELFDynEntries(oh, [ELF.DT_NEEDED]))
        @assert length(matches) == 1 "expected exactly one DT_NEEDED == \"$oldname\" in $file, got $(length(matches))"
        _patch_dyn_string!(oh, only(matches), Vector{UInt8}(newname))
    end
end

end
