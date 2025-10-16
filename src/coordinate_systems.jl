module CoordinateSystems

using Dates
using LinearAlgebra
using Unitful

import StaticArrays

import DeviceLayout:
    AbstractCoordinateSystem,
    ArrayReference,
    Coordinate,
    CoordinateUnits,
    CoordSysRef,
    GeometryEntity,
    GeometryReference,
    GeometryStructure,
    Meta,
    Point,
    SemanticMeta,
    StructureReference,
    Transformation,
    Transformations,
    UPREFERRED,
    aref,
    coordinatetype,
    coordsys_type,
    elements,
    element_metadata,
    flatten,
    halo,
    name,
    origin,
    refs,
    render!,
    rotation,
    sref,
    structure,
    transform,
    transformation,
    uniquename,
    xrefl,
    mag

export CoordinateSystem, CoordinateSystemReference, CoordinateSystemArray
export addarr!, addref!, coordsys, elements, flatten!, name, place!, traverse!

include("coordsys_interface.jl")

"""
    mutable struct CoordinateSystem{S<:Coordinate} <: AbstractCoordinateSystem{S}
        name::String
        elements::Vector{GeometryEntity{S}}
        meta::Vector{Meta}
        refs::Vector{GeometryReference}
        create::DateTime

        CoordinateSystem{S}(x, y, ym, z, t) where {S} = new{S}(x, y, ym, z, t)
        CoordinateSystem{S}(x, y, ym, z) where {S} = new{S}(x, y, ym, z, now())
        CoordinateSystem{S}(x, y, ym) where {S} = new{S}(x, y, ym, GeometryReference[], now())
        CoordinateSystem{S}(x) where {S} =
            new{S}(x, GeometryEntity{S}[], Meta[], GeometryReference[], now())
        CoordinateSystem{S}() where {S} = begin
            c = new{S}()
            c.elements = GeometryEntity{S}[]
            c.meta = Meta[]
            c.refs = GeometryReference[]
            c.create = now()
            c
        end
    end

A `CoordinateSystem` has a name and contains geometry entities (Polygons, Rectangles)
and references to `GeometryStructure` objects. It also records the time of its own creation.

To add elements, use `place!`, or use `render!` to be agnostic between `CoordinateSystem` and
`Cell`. To add references, use `addref!` or `addarr!`.
"""
mutable struct CoordinateSystem{S} <: AbstractCoordinateSystem{S}
    name::String
    elements::Vector{GeometryEntity{S}}
    element_metadata::Vector{<:Meta}
    refs::Vector{GeometryReference}
    create::DateTime

    CoordinateSystem{S}(x, y, ym, z, t) where {S} = new{S}(x, y, ym, z, t)
    CoordinateSystem{S}(x, y, ym, z) where {S} = new{S}(x, y, ym, z, now())
    CoordinateSystem{S}(x, y, ym) where {S} = new{S}(x, y, ym, GeometryReference[], now())
    CoordinateSystem{S}(x) where {S} =
        new{S}(x, GeometryEntity{S}[], Meta[], GeometryReference[], now())
end
Base.copy(c::CoordinateSystem{S}) where {S} = CoordinateSystem{S}(
    c.name,
    copy(c.elements),
    copy(c.element_metadata),
    copy(c.refs),
    c.create
)

"""
    CoordinateSystem(name::AbstractString)

Convenience constructor for `CoordinateSystem{typeof(1.0UPREFERRED)}`.

[`DeviceLayout.UPREFERRED`](@ref) is a constant set according to the `unit` preference in `Project.toml` or `LocalPreferences.toml`.
The default (`"PreferNanometers"`) gives `const UPREFERRED = DeviceLayout.nm`, with mixed-unit operations
preferring conversion to `nm`.
"""
CoordinateSystem(name::AbstractString) = CoordinateSystem{typeof(1.0UPREFERRED)}(name)

"""
    CoordinateSystem(name::AbstractString, unit::DeviceLayout.CoordinateUnits)

Convenience constructor for `CoordinateSystem{typeof(1.0unit)}`.
"""
CoordinateSystem(name::AbstractString, unit::CoordinateUnits) =
    CoordinateSystem{typeof(1.0unit)}(name)

CoordinateSystem(
    name::AbstractString,
    elements::AbstractArray{<:GeometryEntity{S}},
    meta::AbstractArray{<:Meta}
) where {S} = CoordinateSystem{S}(name, elements, meta)
CoordinateSystem(
    name::AbstractString,
    elements::AbstractArray{<:GeometryEntity{S}},
    meta::AbstractArray{<:Meta},
    refs
) where {S} = CoordinateSystem{S}(name, elements, meta, refs)

"""
    place!(cs::CoordinateSystem, ent::GeometryEntity, metadata)

Place `ent` in `cs` with metadata `metadata`.
"""
function place!(cs::CoordinateSystem, ent::GeometryEntity, metadata::Meta)
    push!(cs.elements, ent)
    push!(cs.element_metadata, metadata)
    return cs
end
place!(cs::CoordinateSystem, geom, layer::Union{Symbol, String}) =
    place!(cs, geom, SemanticMeta(layer))

function place!(cs::CoordinateSystem, ents::Vector, metadata::Vector{<:Meta})
    append!(cs.elements, ents)
    append!(cs.element_metadata, metadata)
    return cs
end

"""
    place!(cs::CoordinateSystem, s::GeometryStructure)

Place a reference to `s` in `cs`.
"""
function place!(cs::CoordinateSystem, s::GeometryStructure)
    addref!(cs, s)
    return cs
end

"""
    const CoordinateSystemReference

Alias for [`StructureReference`](@ref)s to `CoordinateSystem`s.
"""
const CoordinateSystemReference = StructureReference{S, T} where {S, T <: CoordinateSystem}

"""
    const CoordinateSystemArray

Alias for [`ArrayReference`](@ref)s to `CoordinateSystem`s.
"""
const CoordinateSystemArray = ArrayReference{S, T} where {S, T <: CoordinateSystem}

(::Type{<:CoordinateSystemReference})(
    c::CoordinateSystem{S},
    origin::Point{T}=zero(Point{S});
    kwargs...
) where {S, T} = sref(c, origin; kwargs...)

(::Type{<:CoordinateSystemArray})(
    c::CoordinateSystem{S},
    origin::Point{T}=zero(Point{S});
    kwargs...
) where {S, T} = aref(c, origin; kwargs...)

Base.isempty(cs::CoordinateSystem) = isempty(cs.elements) && isempty(cs.refs)

end #module
