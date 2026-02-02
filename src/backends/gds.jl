module GDS
using Dates
using Unitful
import Unitful: Length, °
import DeviceLayout: pm, nm, μm, m

import Base: bswap, bitstring, convert, write, read
import DeviceLayout: DEFAULT_LAYER, DEFAULT_DATATYPE, GDSMeta
import DeviceLayout: datatype, gdslayer, load, points, render!, text!, save
import ..Align: LeftEdge, RightEdge, XCenter, TopEdge, BottomEdge, YCenter
using ..Points
import ..Rectangles: Rectangle
import ..Polygons: Polygon
using ..Cells
using ..Texts

import FileIO: File, @format_str, stream, magic, skipmagic

export GDS64
export gdsbegin, gdsend, gdswrite
export GDSWriterOptions

const GDSVERSION   = UInt16(600)
const HEADER       = 0x0002
const BGNLIB       = 0x0102
const LIBNAME      = 0x0206
const UNITS        = 0x0305
const ENDLIB       = 0x0400
const BGNSTR       = 0x0502
const STRNAME      = 0x0606
const ENDSTR       = 0x0700
const BOUNDARY     = 0x0800
const PATH         = 0x0900
const SREF         = 0x0A00
const AREF         = 0x0B00
const TEXT         = 0x0C00
const LAYER        = 0x0D02
const DATATYPE     = 0x0E02
const WIDTH        = 0x0F03
const XY           = 0x1003
const ENDEL        = 0x1100
const SNAME        = 0x1206
const COLROW       = 0x1302
const TEXTNODE     = 0x1400
const NODE         = 0x1500
const TEXTTYPE     = 0x1602
const PRESENTATION = 0x1701
const STRING       = 0x1906
const STRANS       = 0x1A01
const MAG          = 0x1B05
const ANGLE        = 0x1C05
const REFLIBS      = 0x1F06
const FONTS        = 0x2006
const PATHTYPE     = 0x2102
const GENERATIONS  = 0x2202
const ATTRTABLE    = 0x2306
const EFLAGS       = 0x2601
const NODETYPE     = 0x2A02
const PROPATTR     = 0x2B02
const PROPVALUE    = 0x2C06
const BOX          = 0x2D00
const BOXTYPE      = 0x2E02
const PLEX         = 0x2F03

"""
    @kwdef struct GDSWriterOptions

Options controlling warnings and validation during GDS file writing.

# Fields

  - `max_layer::Int = 32767`: Maximum allowed layer number. Modern tools commonly support 0-65535, but 32767 is the maximum if the layer number is read as a two-byte signed integer.
  - `max_datatype::Int = 32767`: Maximum allowed datatype number. Modern tools commonly support 0-65535, but 32767 is the maximum if the layer number is read as a two-byte signed integer.
  - `warn_invalid_names::Bool = true`: Whether to warn about cell/text names that violate
    the GDSII spec (must be ≤32 chars, only A-Z, a-z, 0-9, '_', '?', '\$').

# Examples

```julia
# Default: modern limits, name warnings enabled
opts = GDSWriterOptions()

# Strict GDSII spec compliance
opts = GDSWriterOptions(max_layer=63, max_datatype=63)

# No warnings at all
opts = GDSWriterOptions(
    max_layer=typemax(UInt16),
    max_datatype=typemax(UInt16),
    warn_invalid_names=false
)
```
"""
@kwdef struct GDSWriterOptions
    max_layer::Int = 32767
    max_datatype::Int = 32767
    warn_invalid_names::Bool = true
end

const GDSTokens = Dict{UInt16, String}(
    0x0258 => "GDSVERSION",
    0x0002 => "HEADER",
    0x0102 => "BGNLIB",
    0x0206 => "LIBNAME",
    0x0305 => "UNITS",
    0x0400 => "ENDLIB",
    0x0502 => "BGNSTR",
    0x0606 => "STRNAME",
    0x0700 => "ENDSTR",
    0x0800 => "BOUNDARY",
    0x0900 => "PATH",
    0x0A00 => "SREF",
    0x0B00 => "AREF",
    0x0C00 => "TEXT",
    0x0D02 => "LAYER",
    0x0E02 => "DATATYPE",
    0x0F03 => "WIDTH",
    0x1003 => "XY",
    0x1100 => "ENDEL",
    0x1206 => "SNAME",
    0x1302 => "COLROW",
    0x1400 => "TEXTNODE",
    0x1500 => "NODE",
    0x1602 => "TEXTTYPE",
    0x1701 => "PRESENTATION",
    0x1906 => "STRING",
    0x1A01 => "STRANS",
    0x1B05 => "MAG",
    0x1C05 => "ANGLE",
    0x1F06 => "REFLIBS",
    0x2006 => "FONTS",
    0x2102 => "PATHTYPE",
    0x2202 => "GENERATIONS",
    0x2306 => "ATTRTABLE",
    0x2601 => "EFLAGS",
    0x2A02 => "NODETYPE",
    0x2B02 => "PROPATTR",
    0x2C06 => "PROPVALUE",
    0x2D00 => "BOX",
    0x2E02 => "BOXTYPE",
    0x2F03 => "PLEX"
)

"""
    abstract type GDSFloat <: Real end

Floating-point formats found in GDSII files.
"""
abstract type GDSFloat <: Real end

"""
    struct GDS64 <: GDSFloat
        x::UInt64
        GDS64(x::UInt64) = new(x)
    end

"8-byte (64-bit) real" format found in GDSII files.
"""
struct GDS64 <: GDSFloat
    x::UInt64
    GDS64(x::UInt64) = new(x)
end

"""
    bitstring(x::GDS64)

A string giving the literal bit representation of a GDS64 number.
"""
bitstring(x::GDS64) = bitstring(x.x)

"""
    bswap(x::GDS64)

Byte-swap a GDS64 number. Used implicitly by `hton`, `ntoh` for endian conversion.
"""
bswap(x::GDS64) = GDS64(Base.bswap_int(x.x))

"""
    even(str)

Pads a string with `\0` if necessary to make it have an even length.
"""
function even(str)
    if mod(length(str), 2) == 1
        str * "\0"
    else
        str
    end
end

function convert(::Type{GDS64}, y::T) where {T <: AbstractFloat}
    !isfinite(y) &&
        error("May we suggest you consider using ", "only finite numbers in your CAD file.")

    inty      = reinterpret(UInt64, convert(Float64, y))
    neg       = 0x8000000000000000
    pos       = 0x7fffffffffffffff
    smask     = 0x000fffffffffffff
    hiddenbit = 0x0010000000000000
    z         = 0x0000000000000000

    significand = (smask & inty) | hiddenbit
    floatexp    = (pos & inty) >> 52

    if floatexp <= 0x00000000000002fa   # 762
        # too small to represent
        result = 0x0000000000000000
    else
        while floatexp & 3 != 2         # cheap modulo
            floatexp += 1
            significand >>= 1
        end
        result = ((floatexp - 766) >> 2) << 56
        result |= (significand << 3)
    end
    return GDS64(y < 0.0 ? result | neg : result & pos)
end

function convert(::Type{Float64}, y::GDS64)
    inty   = y.x
    smask  = 0x00ffffffffffffff
    emask  = 0x7f00000000000000
    result = 0x8000000000000000 & inty

    significand = (inty & smask)
    significand == 0 && return result
    significand >>= 4

    exponent = (((inty & emask) >> 56) * 4 + 767)
    while significand & 0x0010000000000000 == 0
        significand <<= 1
        exponent -= 1
    end

    significand &= 0x000fffffffffffff
    result |= (exponent << 52)
    result |= significand
    return reinterpret(Float64, result)
end

gdswerr(x) = error("Wrong data type for token 0x$(lpad(string(x, base=16), 4, '0')).")

"""
    write(s::IO, x::GDS64)

Write a GDS64 number to an IO stream.
"""
write(s::IO, x::GDS64) = write(s, x.x)

"""
    read(s::IO, ::Type{GDS64})

Read a GDS64 number from an IO stream.
"""
read(s::IO, ::Type{GDS64}) = GDS64(read(s, UInt64))

function gdswrite(io::IO, x::UInt16)
    (x & 0x00ff != 0x0000) && gdswerr(x)
    return write(io, hton(UInt16(4))) + write(io, hton(x))
end

function gdswrite(io::IO, x::UInt16, y::Number...)
    l = sizeof(y) + 2
    l + 2 > 0xFFFF && error("Too many bytes in record for GDSII format.")    # 7fff?
    return write(io, hton(UInt16(l + 2))) + write(io, hton(x), map(hton, y)...)
end

function gdswrite(io::IO, x::UInt16, y::AbstractArray{T, 1}) where {T <: Real}
    l = sizeof(y) + 2
    l + 2 > 0xFFFF && error("Too many bytes in record for GDSII format.")    # 7fff?
    return write(io, hton(UInt16(l + 2))) + write(io, hton(x)) + write(io, map(hton, y))
end

function gdswrite(io::IO, x::UInt16, y::String)
    (x & 0x00ff != 0x0006) && gdswerr(x)
    z = y
    mod(length(z), 2) == 1 && (z *= "\0")
    l = length(y) + 2
    l + 2 > 0xFFFF && error("Too many bytes in record for GDSII format.")    # 7fff?
    return write(io, hton(UInt16(l + 2))) + write(io, hton(x), z)
end

gdswrite(io::IO, x::UInt16, y::AbstractFloat...) = gdswrite(io, x, convert.(GDS64, y)...)

function gdswrite(io::IO, x::UInt16, y::Int...)
    datatype = x & 0x00ff
    if datatype == 0x0002
        if GDSTokens[x] == "LAYER" || GDSTokens[x] == "DATATYPE"
            gdswrite(io, x, map(UInt16, y)...) # Allow for GDSII extension that interprets as unsigned integer
        else
            gdswrite(io, x, map(Int16, y)...)
        end
    elseif datatype == 0x0003
        gdswrite(io, x, map(Int32, y)...)
    elseif datatype == 0x0005
        gdswrite(io, x, map(float, y)...)
    else
        gdswerr(x)
    end
end

function gdsbegin(
    io::IO,
    libname::String,
    dbunit::Length,
    userunit::Length,
    modify::DateTime,
    acc::DateTime
)
    y   = UInt16(Dates.value(Dates.Year(modify)))
    mo  = UInt16(Dates.value(Dates.Month(modify)))
    d   = UInt16(Dates.value(Dates.Day(modify)))
    h   = UInt16(Dates.value(Dates.Hour(modify)))
    min = UInt16(Dates.value(Dates.Minute(modify)))
    s   = UInt16(Dates.value(Dates.Second(modify)))

    y1   = UInt16(Dates.value(Dates.Year(acc)))
    mo1  = UInt16(Dates.value(Dates.Month(acc)))
    d1   = UInt16(Dates.value(Dates.Day(acc)))
    h1   = UInt16(Dates.value(Dates.Hour(acc)))
    min1 = UInt16(Dates.value(Dates.Minute(acc)))
    s1   = UInt16(Dates.value(Dates.Second(acc)))

    return gdswrite(io, BGNLIB, y, mo, d, h, min, s, y1, mo1, d1, h1, min1, s1) +
           gdswrite(io, LIBNAME, libname) +
           gdswrite(
               io,
               UNITS,
               convert(Float64, dbunit / userunit),
               convert(Float64, dbunit / (1m))
           )
end

"""
    gdswrite(io::IO, cell::Cell, dbs::Length, options::GDSWriterOptions=GDSWriterOptions())

Write a `Cell` to an IO buffer. The creation and modification date of the cell
are written first, followed by the cell name, the polygons in the cell,
and finally any references or arrays. Warnings are controlled by `options`.
"""
function gdswrite(
    io::IO,
    cell::Cell,
    dbs::Length,
    options::GDSWriterOptions=GDSWriterOptions()
)
    name = even(cell.name)
    options.warn_invalid_names && namecheck(name)

    y   = UInt16(Dates.value(Dates.Year(cell.create)))
    mo  = UInt16(Dates.value(Dates.Month(cell.create)))
    d   = UInt16(Dates.value(Dates.Day(cell.create)))
    h   = UInt16(Dates.value(Dates.Hour(cell.create)))
    min = UInt16(Dates.value(Dates.Minute(cell.create)))
    s   = UInt16(Dates.value(Dates.Second(cell.create)))

    modify = now()
    y1 = UInt16(Dates.value(Dates.Year(modify)))
    mo1 = UInt16(Dates.value(Dates.Month(modify)))
    d1 = UInt16(Dates.value(Dates.Day(modify)))
    h1 = UInt16(Dates.value(Dates.Hour(modify)))
    min1 = UInt16(Dates.value(Dates.Minute(modify)))
    s1 = UInt16(Dates.value(Dates.Second(modify)))

    bytes = gdswrite(io, BGNSTR, y, mo, d, h, min, s, y1, mo1, d1, h1, min1, s1)
    bytes += gdswrite(io, STRNAME, name)
    for (x, m) in zip(cell.elements, cell.element_metadata)
        bytes += gdswrite(io, x, m, dbs, options)
    end
    for x in cell.refs
        bytes += gdswrite(io, x, dbs)
    end
    for (x, m) in zip(cell.texts, cell.text_metadata)
        bytes += gdswrite(io, x, m, dbs, options)
    end
    return bytes += gdswrite(io, ENDSTR)
end

p2p(x::Length, dbs) = convert(Int, round(convert(Float64, x / dbs)))
p2p(x::Real, dbs) = p2p(x * 1μm, dbs)

"""
    gdswrite(io::IO, poly::Polygon{T}, meta, dbs, options::GDSWriterOptions=GDSWriterOptions()) where {T}

Write a polygon to an IO buffer. The layer and datatype are written first,
then the boundary of the polygon is written in a 32-bit integer format with
specified database scale.

Note that polygons without units are presumed to be in microns. Warnings are
controlled by `options`.
"""
function gdswrite(
    io::IO,
    poly::Polygon{T},
    meta,
    dbs,
    options::GDSWriterOptions=GDSWriterOptions()
) where {T}
    bytes = gdswrite(io, BOUNDARY)
    lyr = gdslayer(meta)
    dt = datatype(meta)
    layerdatatypecheck(lyr, dt, options)
    bytes += gdswrite(io, LAYER, lyr)
    bytes += gdswrite(io, DATATYPE, dt)

    xy = reinterpret(T, points(poly))          # Go from Point to sequential numbers
    xyf = map(x -> p2p(x, dbs), xy)         # Divide by the scale and such
    xyInt = convert(Array{Int32, 1}, xyf) # Convert to Int32
    # TODO: check if polygon is closed already
    push!(xyInt, xyInt[1], xyInt[2])     # Need closed polygons for GDSII
    bytes += gdswrite(io, XY, xyInt)
    return bytes += gdswrite(io, ENDEL)
end

"""
    gdswrite(io::IO, t::Texts.Text, meta, dbs, options::GDSWriterOptions=GDSWriterOptions())

Write text to an IO buffer. Width without units presumed to be in microns. Warnings are
controlled by `options`.
"""
function gdswrite(
    io::IO,
    t::Texts.Text,
    meta,
    dbs,
    options::GDSWriterOptions=GDSWriterOptions()
)
    bytes = gdswrite(io, TEXT)
    lyr = gdslayer(meta)
    dt = datatype(meta)
    layerdatatypecheck(lyr, dt, options)
    bytes += gdswrite(io, LAYER, lyr)
    bytes += gdswrite(io, TEXTTYPE, dt)

    p = t.yalign == BottomEdge() ? 0b10 : (t.yalign == YCenter() ? 0b01 : 0b00)
    p = p << 2
    p |= t.xalign == RightEdge() ? 0b10 : (t.xalign == XCenter() ? 0b01 : 0b00)

    bytes += gdswrite(io, PRESENTATION, 0x00, p)

    width = Int32(p2p(t.width, dbs))
    bytes += gdswrite(io, WIDTH, t.can_scale ? width : -width)

    bytes += strans(io, t)

    x, y = p2p(t.origin.x, dbs), p2p(t.origin.y, dbs)
    bytes += gdswrite(io, XY, x, y)

    str = even(t.text)
    options.warn_invalid_names && namecheck(str)
    bytes += gdswrite(io, STRING, str)

    return bytes += gdswrite(io, ENDEL)
end

"""
    gdswrite(io::IO, ref::CellReference, dbs)

Write a [`CellReference`](@ref) to an IO buffer. The name of the referenced cell
is written first. Reflection, magnification, and rotation info are written next.
Finally, the origin of the cell reference is written.

Note that cell references without units on their `origin` are presumed to
be in microns.
"""
function gdswrite(io::IO, ref::CellReference, dbs)
    bytes = gdswrite(io, SREF)
    bytes += gdswrite(io, SNAME, even(ref.structure.name))

    bytes += strans(io, ref)

    x0, y0 = ref.origin.x, ref.origin.y
    x, y = p2p(x0, dbs), p2p(y0, dbs)
    bytes += gdswrite(io, XY, x, y)
    return bytes += gdswrite(io, ENDEL)
end

"""
    gdswrite(io::IO, a::CellArray, dbs)

Write a [`CellArray`](@ref) to an IO buffer. The name of the referenced cell is
written first. Reflection, magnification, and rotation info are written next.
After that the number of columns and rows are written. Finally, the origin,
column vector, and row vector are written.

Note that cell references without units on their `origin` are presumed to
be in microns.
"""
function gdswrite(io::IO, a::CellArray, dbs)
    bytes = gdswrite(io, AREF)
    bytes += gdswrite(io, SNAME, even(a.structure.name))

    bytes += strans(io, a)

    gdswrite(io, COLROW, a.col, a.row)
    ox, oy = a.origin.x, a.origin.y
    dcx, dcy = a.deltacol.x, a.deltacol.y
    drx, dry = a.deltarow.x, a.deltarow.y
    x, y = p2p(ox, dbs), p2p(oy, dbs)
    cx, cy = p2p(dcx, dbs) * a.col, p2p(dcy, dbs) * a.col
    rx, ry = p2p(drx, dbs) * a.row, p2p(dry, dbs) * a.row
    cx += x
    cy += y
    rx += x
    ry += y
    bytes += gdswrite(io, XY, x, y, cx, cy, rx, ry)
    return bytes += gdswrite(io, ENDEL)
end

"""
    strans(io::IO, ref)

Writes bytes to the IO stream (if needed) to encode x-reflection, magnification,
and rotation settings of a reference or array. Returns the number of bytes written.
"""
function strans(io::IO, ref)
    bits = 0x0000

    ref.xrefl && (bits += 0x8000)
    # if ref.mag != 1.0
    #     bits += 0x0004 # absolute (not relative) mag flag
    # end
    # if mod(ref.rot,2π) != 0.0
    #     bits += 0x0002 # absolute (not relative) angle flag
    # end
    bytes = 0
    (ref.xrefl || ref.mag != 1.0 || ref.rot != 0.0) && (bytes += gdswrite(io, STRANS, bits))
    ref.mag != 1.0 && (bytes += gdswrite(io, MAG, ref.mag))
    ref.rot != 0.0 && (bytes += gdswrite(io, ANGLE, ustrip(ref.rot |> °)))
    return bytes
end

function colrowcheck(c)
    return (0 <= c <= 32767) || @warn(
        string(
            "CellArray col/row ",
            c,
            ": The GDSII spec only permits 0 to 32767 rows or columns."
        )
    )
end

function namecheck(a::String)
    invalid = r"[^A-Za-z0-9_\?\0\$]+"
    return (length(a) > 32 || occursin(invalid, a)) && @warn(
        string(
            "Cell name ",
            a,
            ": The GDSII spec says that cell names must only have characters A-Z, a-z, ",
            "0-9, '_', '?', '\$', and be less than or equal to 32 characters long."
        )
    )
end

"""
    layerdatatypecheck(layer, datatype, options::GDSWriterOptions)

Check layer and datatype against configured limits. Warns if either exceeds the
maximum values specified in `options`.
"""
function layerdatatypecheck(layer, datatype, options::GDSWriterOptions)
    if !(0 <= layer <= options.max_layer)
        @warn(
            string(
                "Layer ",
                layer,
                " exceeds configured maximum (",
                options.max_layer,
                ")."
            )
        )
    end
    if !(0 <= datatype <= options.max_datatype)
        @warn(
            string(
                "Datatype ",
                datatype,
                " exceeds configured maximum (",
                options.max_datatype,
                ")."
            )
        )
    end
    return nothing
end

gdsend(io::IO) = gdswrite(io, ENDLIB)

"""
    save(::Union{AbstractString,IO}, cell0::Cell{T}, cell::Cell...)
    save(f::File{format"GDS"}, cell0::Cell, cell::Cell...;
        name="GDSIILIB", userunit=1μm, modify=now(), acc=now(),
        options=GDSWriterOptions(), spec_warnings=nothing, verbose=false,
        max_layer=nothing, max_datatype=nothing, warn_invalid_names=nothing)

This bottom method is implicitly called when you use the convenient syntax of
the top method: `save("/path/to/my.gds", cells_i_want_to_save...)`

Keyword arguments include:

  - `name`: used for the internal library name of the GDSII file and probably
    inconsequential for modern workflows.
  - `userunit`: sets what 1.0 corresponds to when viewing this file in graphical GDS editors
    with inferior unit support.
  - `modify`: date of last modification.
  - `acc`: date of last accession. It would be unusual to have this differ from `now()`.
  - `options`: a [`GDSWriterOptions`](@ref) controlling validation and warnings.
  - `max_layer`: if specified, overrides `options.max_layer`
  - `max_datatype`: if specified, overrides `options.max_datatype`
  - `warn_invalid_names`: if specified, overrides `options.warn_invalid_names`
  - `spec_warnings`: if `false`, disables warnings for max layer/datatype and invalid names
  - `verbose`: monitor the output of [`traverse!`](@ref) and [`order!`](@ref) to see if
    something funny is happening while saving.
"""
function save(
    f::File{format"GDS"},
    cell0::Cell,
    cell::Cell...;
    name="GDSIILIB",
    userunit=1μm,
    modify=now(),
    acc=now(),
    options::GDSWriterOptions=GDSWriterOptions(),
    max_layer=nothing,
    max_datatype=nothing,
    warn_invalid_names=nothing,
    spec_warnings::Bool=true,
    verbose=false
)
    if !spec_warnings
        options = GDSWriterOptions(typemax(UInt16), typemax(UInt16), false)
    else
        options = GDSWriterOptions(
            isnothing(max_layer) ? options.max_layer : max_layer,
            isnothing(max_datatype) ? options.max_datatype : max_datatype,
            isnothing(warn_invalid_names) ? options.warn_invalid_names : warn_invalid_names
        )
    end
    dbs = dbscale(cell0, cell...)
    pad = mod(length(name), 2) == 1 ? "\0" : ""
    open(f, "w") do s
        io = stream(s)
        bytes = 0
        bytes += write(io, magic(format"GDS"))
        bytes += write(io, 0x02, 0x58)
        bytes += gdsbegin(io, name * pad, dbs, userunit, modify, acc)
        a = Tuple{Int, Cell}[]
        traverse!(a, cell0)
        for c in cell
            traverse!(a, c)
        end
        if verbose
            @info("Traversal tree:")
            display(a)
            print("\n")
        end
        ordered = order!(a)
        names = Dict{String, Cell}()
        if verbose
            @info("Cells written in order:")
            display(ordered)
            print("\n")
        end
        for c in ordered
            if (haskey(names, c.name) && names[c.name] != c) ||
               (!haskey(names, c.name) && lowercase(c.name) in lowercase.(keys(names)))
                match = first(filter(s -> lowercase(s) == lowercase(c.name), keys(names)))
                @warn(
                    """Duplicate cell name '$(c.name)' will lead to undefined behavior. Please fix before design review.
              Original: $(names[match])
              With duplicate name: $c"""
                )
            end
            names[c.name] = c
            bytes += gdswrite(io, c, dbs, options)
        end
        return bytes += gdsend(io)
    end
end

"""
    load(f::File{format"GDS"}; verbose::Bool=false, nounits::Bool=false)

A dictionary of top-level cells (`Cell` objects) found in the GDSII file is
returned. The dictionary keys are the cell names. The other cells in the GDSII
file are retained by `CellReference` or `CellArray` objects held by the
top-level cells. Currently, cell references and arrays are not implemented.

The FileIO package recognizes files based on "magic bytes" at the start of the
file. To permit any version of GDSII file to be read, we consider the magic
bytes to be the GDS HEADER tag (`0x0002`), preceded by the number of bytes in
total (`0x0006`) for the entire HEADER record. The last well-documented version
of GDSII is v6.0.0, encoded as `0x0258 == 600`. LayoutEditor appears to save a
version 7 as `0x0007`, which as far as I can tell is unofficial, and probably
just permits more layers than 64, or extra characters in cell names, etc.

If the database scale is `1μm`, `1nm`, or `1pm`, then the corresponding unit
is used for the resulting imported cells. Otherwise, an "anonymous unit" is used
that will display as `u"2.4μm"` if the database scale is 2.4μm, say.

Warnings are thrown if the GDSII file does not begin with a BGNLIB record
following the HEADER record, but loading will proceed.

Property values and attributes (PROPVALUE and PROPATTR records) will be ignored.

Encountering an ENDLIB record will discard the remainder of the GDSII file
without warning. If no ENDLIB record is present, a warning will be thrown.

The content of some records are currently discarded (mainly the more obscure
GDSII record types, but also BGNLIB and LIBNAME).

If `nounits` is true, `Cell{Float64}` objects will be returned, where 1.0
corresponds to one micron.
"""
function load(f::File{format"GDS"}; verbose::Bool=false, nounits::Bool=false)
    cells = Dict{String, Cell}()
    srefs = Dict{String, Vector{_SREF}}()
    arefs = Dict{String, Vector{_AREF}}()

    open(f) do s
        # Skip over GDSII header record
        skipmagic(s)
        version = ntoh(read(s, UInt16))
        verbose && @info(string("Reading GDSII v", repr(version)))

        # Record processing loop
        first = true
        token = UInt8(0)
        local dbs
        while !eof(s)
            bytes = ntoh(read(s, Int16)) - 4 # 2 for byte count, 2 for token
            bytes < 0 && error(
                string(
                    "expecting to read ",
                    bytes,
                    " bytes, which is less ",
                    "than zero. Possibly a malformed GDSII file?"
                )
            )
            token = ntoh(read(s, UInt16))
            infostr = string("Bytes: ", bytes, "; Token: ", repr(token))

            # Consistency check
            if first
                first = false
                if token != BGNLIB
                    @warn("GDSII file did not start with a BGNLIB record.")
                end
            end

            # Handle records
            if token == BGNLIB
                verbose && @info(string(infostr, " (BGNLIB)"))
                # ignore modification time, last access time
                skip(s, bytes)
            elseif token == LIBNAME
                verbose && @info(string(infostr, " (LIBNAME)"))
                # ignore library name
                skip(s, bytes)
            elseif token == UNITS
                verbose && @info(string(infostr, " (UNITS)"))
                # Ignored
                db_in_user = convert(Float64, ntoh(read(s, GDS64)))

                # This is the database scale in meters
                dbsm = convert(Float64, ntoh(read(s, GDS64))) * m
                dbsum = uconvert(μm, dbsm)  # and in μm

                # TODO: Look up all existing length units?
                dbs = if dbsm ≈ 1.0μm
                    1.0μm
                elseif dbsm ≈ 1.0nm
                    1.0nm
                elseif dbsm ≈ 1.0pm
                    1.0pm
                else
                    # If database scale is, say, 2.4μm, let's make a new unit
                    # displayed as `u"2.4μm"` such that one of the new unit
                    # equals the database scale
                    symb = gensym()
                    newunit = eval(:(@unit $symb "u\"$($dbsum)\"" $symb $dbsm false))
                    uconvert(newunit, dbsm)
                end
            elseif token == BGNSTR
                verbose && @info(string(infostr, " (BGNSTR)"))
                # ignore creation time, modification time of structure
                skip(s, bytes)
                c, r, a = cell(s, dbs, verbose, nounits)
                cells[c.name] = c
                srefs[c.name] = r
                arefs[c.name] = a
            elseif token == ENDLIB
                verbose && @info(string(infostr, " (ENDLIB)"))
                # TODO: Handle ENDLIB
                seekend(s)
            else
                verbose && @info(infostr)
                errstr = if haskey(GDSTokens, token)
                    string(
                        "unimplemented record type ",
                        repr(token),
                        " (",
                        GDSTokens[token],
                        "), skipping this record."
                    )
                else
                    string(
                        "unknown record type ",
                        repr(token),
                        ". Possibly a malformed GDSII file? Skipping this record."
                    )
                end
                @warn(errstr)
                skip(s, bytes)
            end
        end

        # Consistency check
        if token != ENDLIB
            @warn("GDSII file did not end with an ENDLIB record.")
        end

        # Up until this point, CellReferences and CellArrays were
        # not associated with Cell objects, only their names. We now
        # replace all of them with refs that are associated with objects.
        for c in values(cells)
            for r in srefs[c.name]
                !haskey(cells, r.name) && error("Missing cell: $(r.name)")
                push!(
                    c.refs,
                    CellReference(
                        cells[r.name],
                        r.origin,
                        xrefl=r.xrefl,
                        mag=r.mag,
                        rot=r.rot
                    )
                )
            end
            for x in arefs[c.name]
                !haskey(cells, x.name) && error("Missing cell: $(x.name)")
                push!(
                    c.refs,
                    CellArray(
                        cells[x.name],
                        x.origin,
                        deltacol=x.deltacol,
                        deltarow=x.deltarow,
                        col=x.col,
                        row=x.row,
                        xrefl=x.xrefl,
                        mag=x.mag,
                        rot=x.rot
                    )
                )
            end
        end
    end
    return cells
end

function cell(s, dbs, verbose, nounits)
    c = nounits ? Cell{U}() : Cell{typeof(dbs)}()
    c.dbscale = dbs
    srefs = _SREF[]
    arefs = _AREF[]

    while true
        bytes = ntoh(read(s, Int16)) - 4 # 2 for byte count, 2 for token
        bytes < 0 && error(
            string(
                "expecting to read ",
                bytes,
                " bytes, which is less ",
                "than zero. Possibly a malformed GDSII file?"
            )
        )
        token = ntoh(read(s, UInt16))

        infostr = string("\tBytes: ", bytes, "; Token: ", repr(token))

        if token == STRNAME
            c.name = sname(s, bytes)
            verbose && @info(string(infostr, " (STRNAME: ", c.name, ")"))
        elseif token == BOUNDARY
            verbose && @info(string(infostr, " (BOUNDARY)"))
            render!(c, boundary(s, dbs, verbose, nounits)...)
        elseif token == SREF
            verbose && @info(string(infostr, " (SREF)"))
            push!(srefs, sref(s, dbs, verbose, nounits))
        elseif token == AREF
            verbose && @info(string(infostr, " (AREF)"))
            push!(arefs, aref(s, dbs, verbose, nounits))
        elseif token == TEXT
            verbose && @info(string(infostr, " (TEXT)"))
            text!(c, text(s, dbs, verbose, nounits)...)
        elseif token == ENDSTR
            verbose && @info(string(infostr[2:end], " (ENDSTR)"))
            break
        else
            verbose && @info(infostr)
            errstr = if haskey(GDSTokens, token)
                string(
                    "unimplemented token ",
                    repr(token),
                    " (",
                    GDSTokens[token],
                    ") in BGNSTR tag."
                )
            else
                string(
                    "unknown token ",
                    repr(token),
                    " in BGNSTR tag. Possibly a ",
                    "malformed GDSII file?"
                )
            end
            error(errstr)
        end
    end
    return c, srefs, arefs
end

function boundary(s, dbs, verbose, nounits)
    haseflags, hasplex, haslayer, hasdt, hasxy = false, false, false, false, false
    haspropattr = false
    lyr, dt = DEFAULT_LAYER, DEFAULT_DATATYPE
    local xy
    T = nounits ? Float64 : typeof(dbs)
    while true
        bytes = ntoh(read(s, UInt16)) - 4
        bytes < 0 && error(
            string(
                "expecting to read ",
                bytes,
                " bytes, which is less ",
                "than zero. Possibly a malformed GDSII file?"
            )
        )
        token = ntoh(read(s, UInt16))
        infostr = string("\t\tBytes: ", bytes, "; Token: ", repr(token))

        if token == EFLAGS
            verbose && @info(string(infostr, " (EFLAGS)"))
            haseflags && error("Already read EFLAGS tag for this BOUNDARY tag.")
            @warn("Not implemented: EFLAGS")
            haseflags = true
            skip(s, bytes)
        elseif token == PLEX
            verbose && @info(string(infostr, " (PLEX)"))
            hasplex && error("Already read PLEX tag for this BOUNDARY tag.")
            @warn("Not implemented: PLEX")
            hasplex = true
            skip(s, bytes)
        elseif token == LAYER
            verbose && @info(string(infostr, " (LAYER)"))
            haslayer && error("Already read LAYER tag for this BOUNDARY tag.")
            lyr = Int(ntoh(read(s, UInt16)))
            haslayer = true
        elseif token == DATATYPE
            verbose && @info(string(infostr, " (DATATYPE)"))
            hasdt && error("Already read DATATYPE tag for this BOUNDARY tag.")
            dt = Int(ntoh(read(s, UInt16)))
            hasdt = true
        elseif token == XY
            verbose && @info(string(infostr, " (XY)"))
            hasxy && error("Already read XY tag for this BOUNDARY tag.")
            xy = Array{Point{T}}(undef, Int(floor(bytes / 8)) - 1)
            i = 1
            while i <= length(xy)
                # TODO: warn if last point not equal to first
                if nounits
                    xy[i] = Point(
                        ustrip(ntoh(read(s, Int32)) * dbs |> μm),
                        ustrip(ntoh(read(s, Int32)) * dbs |> μm)
                    )
                else
                    xy[i] = Point(ntoh(read(s, Int32)) * dbs, ntoh(read(s, Int32)) * dbs)
                end
                i += 1
            end
            read(s, Int32)
            read(s, Int32)
        elseif token == PROPATTR
            haspropattr && error("Already read PROPATTR tag for this BOUNDARY tag.")
            verbose && @info(string(infostr, " (PROPATTR: $(Int(ntoh(read(s, Int16)))))"))
            haspropattr = true
        elseif token == PROPVALUE
            verbose && @info(string(infostr, " (PROPVALUE: $(sname(s, bytes)))"))
            haspropattr || error("Did not yet read PROPATTR tag for this BOUNDARY tag.")
        elseif token == ENDEL
            verbose && @info(string(infostr, " (ENDEL)"))
            break
        else
            verbose && @info(infostr)
            errstr = if haskey(GDSTokens, token)
                string(
                    "unexpected token ",
                    repr(token),
                    " (",
                    GDSTokens[token],
                    ") in BOUNDARY tag."
                )
            else
                string(
                    "unknown token ",
                    repr(token),
                    " in BOUNDARY tag. Possibly a ",
                    "malformed GDSII file?"
                )
            end
            error(errstr)
        end
    end

    verbose && !haslayer && @warn("Did not read LAYER tag.")
    verbose && !hasdt && @warn("Did not read DATATYPE tag.")
    return Polygon(xy), GDSMeta(lyr, dt)
end

function sref(s, dbs, verbose, nounits)
    # SREF [EFLAGS] [PLEX] SNAME [<STRANS>] XY
    haseflags, hasplex, hassname, hasstrans, hasmag, hasangle, hasxy, haspropattr =
        false, false, false, false, false, false, false, false
    magflag = false
    angleflag = false

    local xy, str
    xrefl, mag, rot = false, 1.0, 0.0

    while true
        bytes = ntoh(read(s, UInt16)) - 4
        bytes < 0 && error(
            string(
                "expecting to read ",
                bytes,
                " bytes, which is less ",
                "than zero. Possibly a malformed GDSII file?"
            )
        )
        token = ntoh(read(s, UInt16))
        infostr = string("\t\tBytes: ", bytes, "; Token: ", repr(token))

        if token == EFLAGS
            verbose && @info(string(infostr, " (EFLAGS)"))
            haseflags && error("Already read EFLAGS tag for this SREF tag.")
            @warn("Not implemented: EFLAGS")
            haseflags = true
            skip(s, bytes)
        elseif token == PLEX
            verbose && @info(string(infostr, " (PLEX)"))
            hasplex && error("Already read PLEX tag for this SREF tag.")
            @warn("Not implemented: PLEX")
            hasplex = true
            skip(s, bytes)
        elseif token == SNAME
            hassname && error("Already read SNAME tag for this SREF tag.")
            hassname = true
            str = sname(s, bytes)
            verbose && @info(string(infostr, " (SNAME: ", str, ")"))
        elseif token == STRANS
            verbose && @info(string(infostr, " (STRANS)"))
            hasstrans && error("Already read STRANS tag for this SREF tag.")
            hasstrans = true
            xrefl, magflag, angleflag = strans(s)
        elseif token == MAG
            verbose && @info(string(infostr, " (MAG)"))
            hasmag && error("Already read MAG tag for this SREF tag.")
            hasmag = true
            mag = convert(Float64, ntoh(read(s, GDS64)))
        elseif token == ANGLE
            verbose && @info(string(infostr, " (ANGLE)"))
            hasangle && error("Already read ANGLE tag for this SREF tag.")
            hasangle = true
            rot = convert(Float64, ntoh(read(s, GDS64))) * °
        elseif token == XY
            verbose && @info(string(infostr, " (XY)"))
            hasxy && error("Already read XY tag for this SREF tag.")
            hasxy = true
            if nounits
                xy = Point(
                    ustrip(ntoh(read(s, Int32)) * dbs |> μm),
                    ustrip(ntoh(read(s, Int32)) * dbs |> μm)
                )
            else
                xy = Point(ntoh(read(s, Int32)) * dbs, ntoh(read(s, Int32)) * dbs)
            end
        elseif token == PROPATTR
            haspropattr && error("Already read PROPATTR tag for this BOUNDARY tag.")
            verbose && @info(string(infostr, " (PROPATTR: $(Int(ntoh(read(s, Int16)))))"))
            haspropattr = true
        elseif token == PROPVALUE
            verbose && @info(string(infostr, " (PROPVALUE: $(sname(s, bytes)))"))
            haspropattr || error("Did not yet read PROPATTR tag for this BOUNDARY tag.")
        elseif token == ENDEL
            verbose && @info(string(infostr, " (ENDEL)"))
            skip(s, bytes)
            break
        else
            verbose && @info(infostr)
            errstr = if haskey(GDSTokens, token)
                string(
                    "unexpected token ",
                    repr(token),
                    " (",
                    GDSTokens[token],
                    ") in SREF tag."
                )
            else
                string(
                    "unknown token ",
                    repr(token),
                    " in SREF tag. Possibly a ",
                    "malformed GDSII file?"
                )
            end
            error(errstr)
        end
    end

    # now validate what was read
    # if hasstrans
    #     if magflag
    #         hasmag || error("Missing MAG tag.")
    #     end
    #     if angleflag
    #         hasangle || error("Missing ANGLE tag.")
    #     end
    # end
    hassname || error("Missing SNAME tag.")
    hasxy || error("Missing XY tag.")

    return (name=str, origin=xy, xrefl=xrefl, mag=mag, rot=rot)
end

function aref(s, dbs, verbose, nounits)
    # AREF [EFLAGS] [PLEX] SNAME [<STRANS>] COLROW XY
    haseflags,
    hasplex,
    hassname,
    hasstrans,
    hasmag,
    hasangle,
    hascolrow,
    hasxy,
    haspropattr = false, false, false, false, false, false, false, false, false
    magflag = false
    angleflag = false
    local o, ec, er, str, col, row
    xrefl, mag, rot = false, 1.0, 0.0

    while true
        bytes = ntoh(read(s, UInt16)) - 4
        bytes < 0 && error(
            string(
                "expecting to read ",
                bytes,
                " bytes, which is less ",
                "than zero. Possibly a malformed GDSII file?"
            )
        )
        token = ntoh(read(s, UInt16))
        infostr = string("\t\tBytes: ", bytes, "; Token: ", repr(token))

        if token == EFLAGS
            verbose && @info(string(infostr, " (EFLAGS)"))
            haseflags && error("Already read EFLAGS tag for this AREF tag.")
            @warn("Not implemented: EFLAGS")
            haseflags = true
            skip(s, bytes)
        elseif token == PLEX
            verbose && @info(string(infostr, " (PLEX)"))
            hasplex && error("Already read PLEX tag for this AREF tag.")
            @warn("Not implemented: PLEX")
            hasplex = true
            skip(s, bytes)
        elseif token == SNAME
            hassname && error("Already read SNAME tag for this AREF tag.")
            hassname = true
            str = sname(s, bytes)
            verbose && @info(string(infostr, " (SNAME: ", str, ")"))
        elseif token == STRANS
            verbose && @info(string(infostr, " (STRANS)"))
            hasstrans && error("Already read STRANS tag for this AREF tag.")
            hasstrans = true
            xrefl, magflag, angleflag = strans(s)
        elseif token == MAG
            verbose && @info(string(infostr, " (MAG)"))
            hasmag && error("Already read MAG tag for this AREF tag.")
            hasmag = true
            mag = convert(Float64, ntoh(read(s, GDS64)))
        elseif token == ANGLE
            verbose && @info(string(infostr, " (ANGLE)"))
            hasangle && error("Already read ANGLE tag for this AREF tag.")
            hasangle = true
            rot = convert(Float64, ntoh(read(s, GDS64))) * °
        elseif token == COLROW
            verbose && @info(string(infostr, " (COLROW)"))
            hascolrow && error("Already read COLROW tag for this AREF tag.")
            hascolrow = true
            col = Int(ntoh(read(s, Int16)))
            row = Int(ntoh(read(s, Int16)))
        elseif token == XY
            verbose && @info(string(infostr, " (XY)"))
            hasxy && error("Already read XY tag for this AREF tag.")
            hasxy = true
            if nounits
                o = Point(
                    ustrip(ntoh(read(s, Int32)) * dbs |> μm),
                    ustrip(ntoh(read(s, Int32)) * dbs |> μm)
                )
                ec = Point(
                    ustrip(ntoh(read(s, Int32)) * dbs |> μm),
                    ustrip(ntoh(read(s, Int32)) * dbs |> μm)
                )
                er = Point(
                    ustrip(ntoh(read(s, Int32)) * dbs |> μm),
                    ustrip(ntoh(read(s, Int32)) * dbs |> μm)
                )
            else
                o = Point(ntoh(read(s, Int32)) * dbs, ntoh(read(s, Int32)) * dbs)
                ec = Point(ntoh(read(s, Int32)) * dbs, ntoh(read(s, Int32)) * dbs)
                er = Point(ntoh(read(s, Int32)) * dbs, ntoh(read(s, Int32)) * dbs)
            end
        elseif token == PROPATTR
            haspropattr && error("Already read PROPATTR tag for this BOUNDARY tag.")
            verbose && @info(string(infostr, " (PROPATTR: $(Int(ntoh(read(s, Int16)))))"))
            haspropattr = true
        elseif token == PROPVALUE
            verbose && @info(string(infostr, " (PROPVALUE: $(sname(s, bytes)))"))
            haspropattr || error("Did not yet read PROPATTR tag for this BOUNDARY tag.")
        elseif token == ENDEL
            verbose && @info(string(infostr, " (ENDEL)"))
            skip(s, bytes)
            break
        else
            verbose && @info(infostr)
            errstr = if haskey(GDSTokens, token)
                string(
                    "unexpected token ",
                    repr(token),
                    " (",
                    GDSTokens[token],
                    ") in AREF tag."
                )
            else
                string(
                    "unknown token ",
                    repr(token),
                    " in AREF tag. Possibly a ",
                    "malformed GDSII file?"
                )
            end
            error(errstr)
        end
    end

    # now validate what was read
    # if hasstrans
    #     if magflag
    #         hasmag || error("Missing MAG tag.")
    #     end
    #     if angleflag
    #         hasangle || error("Missing ANGLE tag.")
    #     end
    # end
    hassname || error("Missing SNAME tag.")
    hascolrow || error("Missing COLROW tag.")
    hasxy || error("Missing XY tag.")

    return (
        name=str,
        origin=o,
        deltacol=ec / col,
        deltarow=er / row,
        col=col,
        row=row,
        xrefl=xrefl,
        mag=mag,
        rot=rot
    )
end

function text(s, dbs, verbose, nounits)
    haseflags, hasplex, haslayer, hastt = false, false, false, false
    haspresentation, haspathtype, haswidth, hasstrans = false, false, false, false
    hasxy, hasstr, hasmag, hasangle = false, false, false, false
    xalign = LeftEdge()
    yalign = TopEdge()
    local origin, str
    width = Int32(0) * (nounits ? 1 : μm)
    xrefl, mag, rot = false, 1.0, 0.0

    lyr, dt = DEFAULT_LAYER, DEFAULT_DATATYPE
    T = nounits ? Float64 : typeof(dbs)
    while true
        bytes = ntoh(read(s, UInt16)) - 4
        bytes < 0 && error(
            string(
                "expecting to read ",
                bytes,
                " bytes, which is less ",
                "than zero. Possibly a malformed GDSII file?"
            )
        )
        token = ntoh(read(s, UInt16))
        infostr = string("\t\tBytes: ", bytes, "; Token: ", repr(token))

        if token == EFLAGS
            verbose && @info(string(infostr, " (EFLAGS)"))
            haseflags && error("Already read EFLAGS tag for this TEXT tag.")
            @warn("Not implemented: EFLAGS")
            haseflags = true
            skip(s, bytes)
        elseif token == PLEX
            verbose && @info(string(infostr, " (PLEX)"))
            hasplex && error("Already read PLEX tag for this TEXT tag.")
            @warn("Not implemented: PLEX")
            hasplex = true
            skip(s, bytes)
        elseif token == LAYER
            verbose && @info(string(infostr, " (LAYER)"))
            haslayer && error("Already read LAYER tag for this TEXT tag.")
            lyr = Int(ntoh(read(s, Int16)))
            haslayer = true
        elseif token == TEXTTYPE
            verbose && @info(string(infostr, " (TEXTTYPE)"))
            hastt && error("Already read TEXTTYPE tag for this TEXT tag.")
            dt = Int(ntoh(read(s, Int16)))      # will use TEXTTYPE for DATATYPE.
            hastt = true
        elseif token == PRESENTATION
            verbose && @info(string(infostr, " (PRESENTATION)"))
            haspresentation && error("Already read PRESENTATION tag for this TEXTTYPE tag.")
            skip(s, 1)
            flags = read(s, UInt8)
            xalign =
                Bool((flags >> 1) & 0b1) ? RightEdge() :
                Bool(flags & 0b1) ? XCenter() : LeftEdge()
            flags = flags >> 2
            yalign =
                Bool((flags >> 1) & 0b1) ? BottomEdge() :
                Bool(flags & 0b1) ? YCenter() : TopEdge()
            haspresentation = true
        elseif token == PATHTYPE
            verbose && @info(string(infostr, " (PATHTYPE)"))
            haspathtype && error("Already read PATHTYPE tag for this TEXTTYPE tag.")
            @warn("Not implemented: PATHTYPE")
            haspathtype = true
            skip(s, bytes)
        elseif token == WIDTH
            verbose && @info(string(infostr, " (WIDTH)"))
            haswidth && error("Already read WIDTH tag for this TEXTTYPE tag.")
            width = if nounits
                ustrip(ntoh(read(s, Int32)) * dbs |> μm)
            else
                ntoh(read(s, Int32)) * dbs
            end
            haswidth = true
        elseif token == STRANS
            verbose && @info(string(infostr, " (STRANS)"))
            hasstrans && error("Already read STRANS tag for this TEXTTYPE tag.")
            xrefl, magflag, angleflag = strans(s)
            hasstrans = true
        elseif token == MAG
            verbose && @info(string(infostr, " (MAG)"))
            hasmag && error("Already read MAG tag for this SREF tag.")
            hasmag = true
            mag = convert(Float64, ntoh(read(s, GDS64)))
        elseif token == ANGLE
            verbose && @info(string(infostr, " (ANGLE)"))
            hasangle && error("Already read ANGLE tag for this SREF tag.")
            hasangle = true
            rot = convert(Float64, ntoh(read(s, GDS64))) * °
        elseif token == XY
            verbose && @info(string(infostr, " (XY)"))
            hasxy && error("Already read XY tag for this TEXTTYPE tag.")
            origin = if nounits
                Point(
                    ustrip(ntoh(read(s, Int32)) * dbs |> μm),
                    ustrip(ntoh(read(s, Int32)) * dbs |> μm)
                )
            else
                Point(ntoh(read(s, Int32)) * dbs, ntoh(read(s, Int32)) * dbs)
            end
            hasxy = true
        elseif token == STRING
            verbose && @info(string(infostr, " (STRING)"))
            hasstr && error("Already read STRING tag for this TEXTTYPE tag.")
            str = sname(s, bytes)
            hasstr = true
        elseif token == ENDEL
            verbose && @info(string(infostr, " (ENDEL)"))
            break
        else
            verbose && @info(infostr)
            errstr = if haskey(GDSTokens, token)
                string(
                    "unexpected token ",
                    repr(token),
                    " (",
                    GDSTokens[token],
                    ") in TEXT tag."
                )
            else
                string(
                    "unknown token ",
                    repr(token),
                    " in TEXT tag. Possibly a ",
                    "malformed GDSII file?"
                )
            end
            error(errstr)
        end
    end

    verbose && !haslayer && @warn("Did not read LAYER tag.")
    verbose && !hasxy && @warn("Did not read XY tag.")
    verbose && !hasstr && @warn("Did not read STRING tag.")
    verbose && !hastt && @warn("Did not read TEXTTYPE tag.")

    can_scale = width >= zero(width)
    width = abs(width)

    kwargs =
        (; text=str, origin, width, can_scale, xrefl, mag, rot=Float64(rot), xalign, yalign)

    return Texts.Text(; kwargs...), GDSMeta(lyr, dt)
end

function sname(s, bytes)
    str = String(read(s, bytes))
    if str[end] == '\0'
        str = str[1:(end - 1)]
    end
    return str
end

function strans(s)
    bits = ntoh(read(s, UInt16))
    xrefl = (bits & 0x8000) != 0
    magflag = (bits & 0x0004) != 0
    angleflag = (bits & 0x0002) != 0
    return xrefl, magflag, angleflag
end

_SREF = @NamedTuple begin
    name::String
    origin::Point
    xrefl::Bool
    mag::Float64
    rot::Float64
end

_AREF = @NamedTuple begin
    name::String
    origin::Point
    deltacol::Point
    deltarow::Point
    col::Int
    row::Int
    xrefl::Bool
    mag::Float64
    rot::Float64
end

end
