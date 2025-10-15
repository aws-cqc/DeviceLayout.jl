module Cells
using Dates

using Unitful
import Unitful: Length

import ..Texts

import DeviceLayout
import DeviceLayout: Coordinate, GDSMeta, Polygon, Point
import DeviceLayout:
    AbstractCoordinateSystem,
    ArrayReference,
    CoordinateSystem,
    CoordinateSystems,
    GeometryReference,
    GeometryStructure,
    StructureReference,
    Transformation,
    Transformations,
    UPREFERRED
import DeviceLayout:
    aref, sref, gdslayer, layer, nm, elements, element_metadata, refs, render!
import DeviceLayout: flatten, flatten!, order!, traverse!, uniquename # to re-export

export Cell, CellArray, CellReference
export cell, dbscale, layers, gdslayers, flatten, flatten!, order!, traverse!, uniquename

# Avoid circular definitions
abstract type AbstractCell{S} <: AbstractCoordinateSystem{S} end

"""
    const CellRef

Alias for structure or array references to `Cell`s.
"""
const CellRef = GeometryReference{S, T} where {S, T <: AbstractCell}

"""
    const CellReference

Alias for [`StructureReference`](@ref)s to `Cell`s.
"""
const CellReference = StructureReference{S, T} where {S, T <: AbstractCell}

"""
    const CellArray

Alias for [`ArrayReference`](@ref)s to `Cell`s.
"""
const CellArray = ArrayReference{S, T} where {S, T <: AbstractCell}
cell(r::CellRef) = r.structure

"""
    mutable struct Cell{S<:Coordinate}

A cell has a name and contains polygons and references to `CellArray` or
`CellReference` objects. It also records the time of its own creation. As
currently implemented it mirrors the notion of cells in GDSII files.

To add elements, use `render!`. To add references, use `addref!` or `addarr!`.
To add text, use `text!`.
"""
mutable struct Cell{S} <: AbstractCell{S}
    name::String
    elements::Vector{Polygon{S}}
    element_metadata::Vector{GDSMeta}
    refs::Vector{CellRef}
    texts::Vector{Texts.Text{S}}
    text_metadata::Vector{GDSMeta}
    dbscale::Length
    create::DateTime
    Cell{S}(w, x, xm, y, z, zm, d=_dbscale(S), t=now()) where {S} =
        new{S}(w, x, xm, y, z, zm, d, t)
    Cell{S}() where {S} = begin # "uninitialized" constructor used when loading from GDS
        c = new{S}()
        c.elements = Polygon{S}[]
        c.element_metadata = GDSMeta[]
        c.refs = CellRef[]
        c.texts = Texts.Text{S}[]
        c.text_metadata = GDSMeta[]
        c.dbscale = _dbscale(S)
        c.create = now()
        c
    end
end
Cell{S}(w, x, xm, y=CellRef[]) where {S} = Cell{S}(w, x, xm, y, Texts.Text{S}[], GDSMeta[])
Cell{S}(w) where {S} = Cell{S}(w, Polygon{S}[], GDSMeta[])

Base.copy(c::Cell{S}) where {S} = Cell{S}(
    c.name,
    copy(c.elements),
    copy(c.element_metadata),
    copy(c.refs),
    copy(c.texts),
    copy(c.text_metadata),
    c.dbscale,
    c.create
)

(::Type{<:CellReference})(
    c::Cell{S},
    origin::Point{T}=zero(Point{S});
    kwargs...
) where {S, T} = sref(c, origin; kwargs...)

(::Type{<:CellArray})(c::Cell{S}, origin::Point{T}=zero(Point{S}); kwargs...) where {S, T} =
    aref(c, origin; kwargs...)

# Do NOT define a convert method like this or otherwise cells will
# be copied when referenced by CellRefs!
# Base.convert{T}(::Type{Cell{T}}, x::Cell) =
#     Cell{T}(x.name, convert(Vector{Polygon{T}}, x.elements),
#                     convert(Vector{CellRef}, x.refs),
#                     x.create)

"""
    dbscale(c::Cell)

Give the database scale for a cell. The database scale is the
smallest increment of length that will be represented in the output CAD file.
This is different from the working coordinate type `T` of the `Cell`.

The database scale defaults to `1nm` (`1.0nm` if `T <: FloatCoordinate`), but can be changed
by updating `c.dbscale` to a new `Unitful.Length` quantity.
"""
dbscale(c::Cell) = c.dbscale

_dbscale(::Type{T}) where {T <: Coordinate} =
    ifelse(T <: DeviceLayout.FloatCoordinate, 1.0 * Unitful.nm, 1 * Unitful.nm)

"""
    dbscale(cell::Cell...)

Choose an appropriate database scale for a GDSII file given [`Cell`](@ref)s of
different types. The smallest database scale of all cells considered is returned.
"""
dbscale(c0::Cell, c1::Cell, c2::Cell...) =
    minimum([dbscale(c0); dbscale(c1); map(dbscale, collect(c2))])

"""
    Cell(name::AbstractString)

Convenience constructor for `Cell{typeof(1.0UPREFERRED)}`.

[`DeviceLayout.UPREFERRED`](@ref) is a constant set according to the `unit` preference in `Project.toml` or `LocalPreferences.toml`.
The default (`"PreferNanometers"`) gives `const UPREFERRED = DeviceLayout.nm`, with mixed-unit operations
preferring conversion to `nm`.

Unit preference does not affect the database scale for GDS export.
"""
Cell(name::AbstractString) = Cell{typeof(1.0UPREFERRED)}(name)

"""
    Cell(name::AbstractString, unit::DeviceLayout.CoordinateUnits)

Convenience constructor for `Cell{typeof(1.0unit)}`.
"""
Cell(name::AbstractString, unit::DeviceLayout.CoordinateUnits) = Cell{typeof(1.0unit)}(name)

"""
    Cell(name::AbstractString, unit::DeviceLayout.CoordinateUnits, dbscale::Unitful.LengthUnits)

Convenience constructor for `Cell{typeof(1.0unit)}` with `dbscale` set to `1.0dbscale`.
"""
function Cell(
    name::AbstractString,
    unit::DeviceLayout.CoordinateUnits,
    dbscale::Unitful.LengthUnits
)
    c = Cell{typeof(1.0unit)}(name)
    c.dbscale = 1.0dbscale
    return c
end

Cell(
    name::AbstractString,
    elements::AbstractVector{Polygon{S}},
    metadata::AbstractVector{GDSMeta}
) where {S} = Cell{S}(name, elements, metadata)
Cell(
    name::AbstractString,
    elements::AbstractVector{Polygon{S}},
    metadata::AbstractVector{GDSMeta},
    refs
) where {S} = Cell{S}(name, elements, metadata, refs)

function DeviceLayout.CoordinateSystem{S}(x::Cell) where {S}
    return CoordinateSystem(
        x.name,
        copy(x.elements),
        copy(x.element_metadata),
        copy(x.refs)
    )
end

function DeviceLayout.flatten!(
    c::Cell;
    depth::Integer=-1,
    metadata_filter=nothing,
    max_copy=Inf
)
    depth == 0 && return c
    cflat = flatten(c; depth=depth, metadata_filter=metadata_filter, max_copy=max_copy)
    c.elements = elements(cflat)
    c.element_metadata = element_metadata(cflat)
    c.texts = cflat.texts
    c.text_metadata = cflat.text_metadata
    c.refs = refs(cflat)
    return c
end

function DeviceLayout.transform(r::Cell, f::Transformation)
    n = copy(r)
    for (ia, ib) in zip(eachindex(r.elements), eachindex(n.elements))
        @inbounds n.elements[ib] = f(r.elements[ia])
    end
    for (ia, ib) in zip(eachindex(r.refs), eachindex(n.refs))
        @inbounds n.refs[ib] = f(r.refs[ia])
    end
    # Cell also needs to transform texts
    for (ia, ib) in zip(eachindex(r.texts), eachindex(n.texts))
        @inbounds n.texts[ib] = f(r.texts[ia])
    end
    return n
end

# Appending Cell needs to handle texts
function CoordinateSystems.append_coordsys!(
    cs::AbstractCoordinateSystem,
    geom::Cell;
    transformation=Transformations.IdentityTransformation(),
    metadata_filter=nothing,
    addrefs=true
)
    if isnothing(metadata_filter)
        render!(cs, transformation.(elements(geom)), element_metadata(geom))
        render!(cs, transformation.(geom.texts), geom.text_metadata)
    else
        idx = findall(metadata_filter, element_metadata(geom))
        render!(cs, transformation.(elements(geom)[idx]), element_metadata(geom)[idx])
        text_idx = findall(metadata_filter, geom.text_metadata)
        render!(cs, transformation.(geom.texts[text_idx]), geom.text_metadata[text_idx])
    end

    return addrefs && append!(cs.refs, transformation.(refs(geom)))
end

"""
    gdslayers(x::Cell)

Returns the unique GDS layers of elements in cell `x`. Does *not* return the layers
in referenced or arrayed cells.
"""
gdslayers(x::Cell) = unique(map(gdslayer, x.element_metadata))

"""
    gdslayers(x::GeometryStructure)

Returns the unique GDS layers of elements in `x`, using [`DeviceLayout.default_meta_map`](@ref). Does *not* return the layers
in referenced structures.
"""
gdslayers(x::GeometryStructure) =
    unique(map(gdslayer ∘ DeviceLayout.default_meta_map, element_metadata(x)))
layers(x::Cell) = unique(map(gdslayer, x.element_metadata))

@deprecate layers(x) gdslayers(x)

"""
    text!(c::Cell{S}, str::String, origin::Point=zero(Point{S}), meta::Meta=GDSMeta(); kwargs...) where {S}

Annotate cell `c` with string `str` as a text element. See also [`polytext!`](@ref DeviceLayout.PolyText.polytext!) for
rendering strings as polygons.
"""
function text!(
    c::Cell{S},
    text::String,
    origin::Point=zero(Point{S}),
    meta::GDSMeta=GDSMeta();
    kwargs...
) where {S}
    return text!(c, Texts.Text(; text, origin, kwargs...), meta)
end

function text!(
    c::Cell{S},
    text::String,
    meta::GDSMeta;
    origin=zero(Point{S}),
    kwargs...
) where {S}
    return text!(c, Texts.Text(; text, origin, kwargs...), meta)
end

"""
    text!(c::Cell, text::Texts.Text, meta)

Annotate cell `c` with `Texts.Text` object.
"""
function text!(c::Cell, text::Texts.Text, meta)
    push!(c.texts, text)
    push!(c.text_metadata, meta)
    return c
end

function text!(c::Cell{S}, texts::Vector{Texts.Text{S}}, meta::Vector{GDSMeta}) where {S}
    append!(c.texts, texts)
    append!(c.text_metadata, meta)
    return c
end

Base.isempty(c::Cell) = isempty(elements(c)) && isempty(refs(c)) && isempty(c.texts)

end # module
