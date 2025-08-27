module PatchVersion

export patch_version, patch_version!

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

end
