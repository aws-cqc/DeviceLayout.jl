module PolyText

import DeviceLayout
import DeviceLayout:
    AbstractCoordinateSystem,
    CoordinateSystem,
    Coordinate,
    CoordSysRef,
    GDSMeta,
    Meta,
    Plain,
    Rounded,
    NoRender,
    OptionalStyle,
    StyledEntity
import DeviceLayout:
    width,
    height,
    bounds,
    push!,
    render!,
    sref,
    intersect2d,
    center,
    elements,
    styled,
    reset_uniquename!

using ..Polygons
using ..Rectangles
using ..Points
using ..Cells

using FileIO

using Unitful
import Unitful: Length
import DeviceLayout: μm, nm

export polytext, polytext!
export characters_demo
export scripted_demo
export referenced_characters_demo

"""
    abstract type PolyText.Style{T}

Can be considered something like a font for rendering text as polygons, where
`T <: DeviceLayout.Coordinate`.
"""
abstract type Style{T} end

const somekwargs = """
- `scripting`: boolean parameter for allocating special characters `^`, `_`, `{`, and `}` 
  for superscripting and subscripting. Follows the same usage as LaTeX.
- `linelimit`: sets the maximum number of characters per line and continues on a new line 
  if `str` is longer than `linelimit`.
- `verbose`: prints out information about the character dictionary.
"""

"""
    polytext(str::String, sty::PolyText.Style;
        scripting=false, linelimit=typemax(Int), verbose=false) where {T}

Renders the string `str` to a new coordinate system in a given style.

# Keyword args

$somekwargs
"""
function polytext(
    str::String,
    sty::Style{T};
    scripting=false,
    linelimit=typemax(Int),
    verbose=false
) where {T}
    c = default_top(sty)(uniquename("polytext"))
    return polytext!(c, str, sty; scripting, linelimit, verbose)
end

"""
    polytext!(c::AbstractCoordinateSystem, str::String, sty::PolyText.Style;
        scripting=false, linelimit=typemax(Int), verbose=false)

Renders the string `str` to cell or coordinate system `c` in a given style.

# Keyword args

$somekwargs
"""
function polytext!(
    c::AbstractCoordinateSystem,
    str::String,
    sty::Style;
    scripting=false,
    linelimit=typemax(Int),
    verbose=false
)
    # For DotMatrix this is necessary because there is no clean way to convert a 
    # CoordinateSystemReference to a CellReference, it will make a new Cell each
    # time you need a new reference and prevent reuse of pixels. So we first convert
    # the pixel and avoid the issue.
    sty = promotestyle(c, sty)
    hpos = 1
    vpos = 1
    subscript = -1
    superscript = +1
    waitforend = false
    existing_chars = Dict{Char, CoordSysRef}()
    for s in str
        if subscript == 0
            offset = -0.3
        elseif superscript == 0
            offset = +0.3
        else
            offset = 0.0
        end
        if s == '\n'
            vpos += 1
            hpos = 1
        elseif s == ' '
            hpos += 1
        elseif s == '_' && scripting
            subscript = +1
        elseif s == '^' && scripting
            superscript = -1
        elseif s == '{' && scripting
            waitforend = true
        elseif s == '}' && scripting
            subscript = -1
            superscript = +1
            waitforend = false
        else
            # If horizontal position is beyond limit, reset before starting to write.
            if hpos > linelimit
                vpos += 1
                hpos = 1
            end

            renderchar!(sty, c, s, existing_chars, hpos, vpos, offset, verbose)
            hpos += 1
        end
        if !waitforend
            subscript -= 1
            superscript += 1
        end
    end
    return c
end

promotestyle(c, sty) = sty

include("dotmatrix.jl")

abstract type FontDerived{T} <: Style{T} end

function renderchar!(sty::FontDerived, c, s, existing_chars, hpos, vpos, offset, verbose)
    charwidth = sty.charwidth
    scale = charwidth isa Length ? charwidth / 100.0μm : charwidth / 100.0
    if !haskey(existing_chars, s)
        verbose &&
            println("Character '", s, "' not found. Adding to CoordSysRef dictionary.")
        if haskey(chardict(sty), s)
            s_cs = drawchar(sty, c, s)
            crs = sref(s_cs, Point(0.5charwidth, charwidth); scale)
            push!(
                c.refs,
                crs + Point(charwidth * (hpos - 1), -2charwidth * (vpos - offset))
            )
            existing_chars[s] = crs
        else
            @warn string(
                "Cannot render '",
                s,
                "' character. Replacing with a blank character."
            )
        end
    else
        cr = existing_chars[s]
        verbose && println("Character '", s, "' already in dictionary.")
        push!(c.refs, cr + Point(charwidth * (hpos - 1), -2charwidth * (vpos - offset)))
    end
end

function drawchar(sty::FontDerived, c, s)
    dict = chardict(sty)
    # Glyph cells are named by codepoint rather than by the character itself: GDS readers
    # (and the GDS writer's duplicate check) compare cell names case-insensitively, so
    # `_A` and `_a` would collide, and characters outside the GDSII name charset
    # (`/`, `"`, `α`, ...) would make the name itself invalid.
    cs = typeof(c)(uniquename(string(name(sty), "_U", string(UInt32(s); base=16, pad=4))))
    render!(cs, union2d(elements(dict[s])), sty.meta)
    return cs
end

function chardict(sty::FontDerived)
    dictref = fontdictref(sty)
    if !isassigned(dictref)
        gds = load(joinpath(dirname(dirname(pathof(DeviceLayout))), "deps", fontfile(sty)))
        dictref[] = Dict(c => begin
            cell = gds[string(i)]
            cell.name = uniquename(cell.name)
            cell
        end for (i, c) in enumerate(chars))
    end
    return dictref[]
end

const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#\$%^&*()-=_+{}[]\\|:;/\"\'`~≈.,?<>÷√°αβϵμσρθΩΣπħ∞γδΞΓϕωΠχΔκ□νη░█λτψΨΛΘΦ†∠⟂≡±∓∇∂≠ "

"""
    PolyTextSansMono(charwidth, meta)

PolyText style derived from the Noto Sans Mono Regular font (Open Font License).
"""
struct PolyTextSansMono{T, S} <: FontDerived{T}
    charwidth::T
    meta::S
end

const sansmono_dict = Ref{Dict{Char, Cell}}()
fontfile(::PolyTextSansMono) = joinpath("PolyTextSansMono", "PolyTextSansMono.gds")
fontdictref(::PolyTextSansMono) = sansmono_dict
name(::PolyTextSansMono) = "PolyTextSansMono"

"""
    PolyTextComic(charwidth, meta)

PolyText style derived from the Comic Neue Regular font (Open Font License).
"""
struct PolyTextComic{T, S} <: FontDerived{T}
    charwidth::T
    meta::S
end

const comic_dict = Ref{Dict{Char, Cell}}()
fontfile(::PolyTextComic) = joinpath("PolyTextComic", "PolyTextComic.gds")
fontdictref(::PolyTextComic) = comic_dict
name(::PolyTextComic) = "PolyTextComic"

include("examples.jl")

# utility function for constructing font GDS files.
function format_gds(file_in, file_out, cell_name)
    cell = load(file_in)[cell_name]
    cells = []
    polys = elements(cell)
    for (i, char) in enumerate(chars)
        bounding_box =
            Rectangle(Point(0, 0)μm, Point(100μm, -200μm)) + (i - 1) * Point(100, 0)μm
        char_poly = intersect2d(polys, bounding_box) .- Ref(center(bounding_box))
        c = Cell(string(i), nm)
        render!.(c, char_poly, GDSMeta(0))
        push!(cells, c)
    end
    return save(file_out, cells...)
end

end
