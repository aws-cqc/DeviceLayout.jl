# Material classification for source layers.
@enum Material METAL DIELECTRIC NULL

"""
    LayerRef(layer)

Opt-in reference from placed geometry to a symbol-keyed [`SourceLayer`](@ref). The active
experimental rendering target resolves the layer through its [`SourceStack`](@ref).
"""
struct LayerRef <: DeviceLayout.Meta
    layer::Symbol
end

DeviceLayout.layer(meta::LayerRef) = meta.layer
Base.broadcastable(meta::LayerRef) = Ref(meta)

"""
    LocatorMeta

Abstract metadata for an annotation that selects finalized geometry on a required source
layer rather than creating geometry itself. Place it on a [`Locator`](@ref) point entity.
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

Metadata for locators identifying a named electrostatic terminal on a connected metal component.
"""
struct Terminal <: LocatorMeta
    layer::Symbol
    name::String
    Terminal(layer::Symbol, name::AbstractString) = new(layer, _locator_name(name))
end

"""
    Ground(layer)

Metadata for locators designating a connected metal component as ground.
"""
struct Ground <: LocatorMeta
    layer::Symbol
end

"""
    Tag(layer, name)

Metadata for locators assigning a name to the surface containing the locator position.
"""
struct Tag <: LocatorMeta
    layer::Symbol
    name::String
    Tag(layer::Symbol, name::AbstractString) = new(layer, _locator_name(name))
end

"""
    Port

Abstract locator metadata for selecting a finalized port surface.
"""
abstract type Port <: LocatorMeta end

"""
    WavePort(layer, name; index=1)

Metadata for locators selecting a named wave-port surface. `index` distinguishes ports sharing a name.
"""
struct WavePort <: Port
    layer::Symbol
    name::String
    index::Int
    WavePort(layer::Symbol, name::AbstractString, index::Int) =
        new(layer, _locator_name(name), _port_index(index))
end
WavePort(layer::Symbol, name::AbstractString; index::Int=1) = WavePort(layer, name, index)

"""
    LumpedPort(layer, name; index=1)

Metadata for locators selecting a named lumped-port surface. `index` distinguishes ports sharing a name.
The selected port geometry, rather than the locator geometry, carries its in-plane
[`DeviceLayout.WithDirection`](@ref) style.
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
DeviceLayout.layerindex(port::Port) = port.index
Base.broadcastable(lm::LocatorMeta) = Ref(lm)
