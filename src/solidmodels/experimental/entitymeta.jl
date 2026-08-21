"""
    @enum Material METAL DIELECTRIC NULL

Material classification for source layers.
"""
@enum Material METAL DIELECTRIC NULL

"""
    abstract type Role

Supertype for functional roles attached to [`EntityMeta`](@ref).
"""
abstract type Role end
struct Generic <: Role end
abstract type Locator <: Role end
struct Terminal <: Locator end
struct Ground <: Locator end
struct Tag <: Locator end
abstract type Port <: Role end
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

Experimental entity metadata for the simulation-agnostic solid-model pipeline. `layer`
is resolved exclusively through a [`SourceStack`](@ref). The standard `level(::Meta) = 1`
default is intentionally retained; z placement comes from the stack.
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

"""
    physical_group_name(m::EntityMeta) -> String

Return the stable physical-group name for `m`.
"""
function physical_group_name(m::EntityMeta)
    return string(m.layer, "__", m.name, "__i", m.index, "__r", m.role)
end

# Preserve the prototype compiler spelling within the SolidModelsExperimental namespace.
map_meta(m::EntityMeta) = physical_group_name(m)
