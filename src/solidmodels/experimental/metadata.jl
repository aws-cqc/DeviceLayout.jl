"""
    Material

Material of a [`SourceLayer`](@ref): `METAL`, `DIELECTRIC`, or `NULL`. Terminal selection
uses the 2D `METAL` layers; the other materials are treated alike.
"""
@enum Material METAL DIELECTRIC NULL

"""
    LayerRef(layer::Symbol) <: DeviceLayout.Meta

Metadata for placing entities on a [`SourceLayer`](@ref).
"""
struct LayerRef <: DeviceLayout.Meta
    layer::Symbol
end

DeviceLayout.layer(meta::LayerRef) = meta.layer
Base.broadcastable(meta::LayerRef) = Ref(meta)

"""
    LocatorMeta <: DeviceLayout.Meta

Abstract supertype of all metadata used for placing [`Locator`](@ref)s.
"""
abstract type LocatorMeta <: DeviceLayout.Meta end

function _locator_name(name::AbstractString)
    isempty(name) && throw(ArgumentError("locator name must be nonempty"))
    return String(name)
end

function _port_index(index::Int)
    index >= 1 || throw(ArgumentError("port index must be positive"))
    return index
end

"""
    Terminal(layer, name)

Locator metadata naming the terminal formed by the contiguous surface of 2D metal
containing the locator. The resulting selection can be used in electrostatics simulations.
"""
struct Terminal <: LocatorMeta
    layer::Symbol
    name::String
    Terminal(layer::Symbol, name::AbstractString) = new(layer, _locator_name(name))
end

"""
    Ground(layer)

Locator metadata for marking a contiguous surface of 2D metal as ground. The resulting
selection can be used in electrostatics simulations.
"""
struct Ground <: LocatorMeta
    layer::Symbol
end

"""
    Tag(layer, name)

Locator metadata naming the surface containing the locator. The resulting selection
can be used for any purpose, for example for computing surface integrals of field
solutions over the specified surface.
"""
struct Tag <: LocatorMeta
    layer::Symbol
    name::String
    Tag(layer::Symbol, name::AbstractString) = new(layer, _locator_name(name))
end

"""
    Port

Abstract supertype of locator metadata types used for selecting ports.
"""
abstract type Port <: LocatorMeta end

"""
    WavePort(layer, name)

Locator metadata naming the wave port formed by the boundary patch intersecting the locator's
(x, y) position. Create the patch by extruding a `LineSegment` on the simulation boundary,
with the locator placed on the segment.
"""
struct WavePort <: Port
    layer::Symbol
    name::String
    WavePort(layer::Symbol, name::AbstractString) = new(layer, _locator_name(name))
end

"""
    LumpedPort(layer, name; kwargs...)

Locator metadata naming the lumped port surface containing the locator. The port direction is
the [`DeviceLayout.WithDirection`](@ref) style of the selected port entity.

# Keywords

  - `index`: Distinguishes ports sharing `name`; a port with `index` other than `1` is
    serialized as `name_index`. Default is `1`. Useful for multi-element ports.
"""
struct LumpedPort <: Port
    layer::Symbol
    name::String
    index::Int
    LumpedPort(layer::Symbol, name::AbstractString, index::Int) =
        new(layer, _locator_name(name), _port_index(index))
end
LumpedPort(layer::Symbol, name::AbstractString; index::Int=1) =
    LumpedPort(layer, name, index)

DeviceLayout.layer(lm::LocatorMeta) = lm.layer
DeviceLayout.name(lm::Union{Terminal, Tag, Port}) = lm.name
DeviceLayout.layerindex(port::LumpedPort) = port.index
Base.broadcastable(lm::LocatorMeta) = Ref(lm)

DeviceLayout.SchematicDrivenLayout.is_experimental_meta(::Union{LayerRef, LocatorMeta}) = true
