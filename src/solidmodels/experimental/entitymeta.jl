# Material classification for source layers.
@enum Material METAL DIELECTRIC NULL

# Internal hierarchy for functional roles attached to EntityMeta.
abstract type Role end

"""
    Generic()

Generic role for geometry without specialized terminal, locator, or port behavior.
"""
struct Generic <: Role end

abstract type Locator <: Role end

"""
    Terminal()

Locator role identifying a named electrostatic terminal on a connected metal component.
"""
struct Terminal <: Locator end

"""
    Ground()

Locator role designating a connected metal component as ground.
"""
struct Ground <: Locator end

"""
    Tag()

Locator role assigning a name to the surface containing the locator position.
"""
struct Tag <: Locator end

abstract type Port <: Role end

"""
    WavePort()

Role for geometry representing a wave port.
"""
struct WavePort <: Port end

"""
    LumpedPort()

Role for a rendered lumped-port surface. Its in-plane direction is carried by a
[`DeviceLayout.WithDirection`](@ref) style on the placed geometry.
"""
struct LumpedPort <: Port end

Base.show(io::IO, r::Role) = print(io, nameof(typeof(r)))

"""
    EntityMeta(layer::Symbol; name="", index=1, role=Generic())

Experimental entity metadata for the simulation-agnostic solid-model pipeline. Resolve
`layer` exclusively through a [`SourceStack`](@ref); `name`, `index`, and `role` determine
physical-group identity and behavior. `role` may be a role instance or role type. The
standard `level(::Meta) = 1` default is intentionally retained because z placement comes
from the stack.
"""
struct EntityMeta <: DeviceLayout.Meta
    layer::Symbol
    name::String
    index::Int
    role::Role
end

_resolve_role(r::Role) = r
_resolve_role(::Type{R}) where {R <: Role} = R()

function EntityMeta(
    layer::Symbol;
    name::String="",
    index::Int=1,
    role::Union{Role, Type{<:Role}}=Generic()
)
    return EntityMeta(layer, name, index, _resolve_role(role))
end

DeviceLayout.layer(m::EntityMeta) = m.layer
DeviceLayout.layerindex(m::EntityMeta) = m.index
DeviceLayout.name(m::EntityMeta) = m.name
Base.broadcastable(m::EntityMeta) = Ref(m)

islocator(meta::EntityMeta) = meta.role isa Locator
islocator(::Nothing) = false

# Return the stable physical-group name for an EntityMeta.
function pgname(m::EntityMeta)
    return string(m.layer, "__", m.name, "__i", m.index, "__r", m.role)
end

# Preserve the prototype compiler spelling within the SolidModelsExperimental namespace.
map_meta(m::EntityMeta) = pgname(m)
