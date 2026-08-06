"""
Material classification for source layers.
"""
@enum Material METAL DIELECTRIC NULL

abstract type Role end
struct Generic <: Role end
abstract type Locator <: Role end
struct Terminal <: Locator end
struct Ground <: Locator end
struct Tag <: Locator end
abstract type Port <: Role end
struct WavePort <: Port end

"""
A rendered lumped-port surface with a three-dimensional orientation vector.
"""
struct LumpedPort <: Port
    direction::Vector{Float64}
    function LumpedPort(direction::Vector{Float64})
        length(direction) == 3 || throw(ArgumentError("direction must have 3 components"))
        return new(direction)
    end
end
LumpedPort(direction::AbstractVector{<:Real}) = LumpedPort(Float64.(direction))

function LumpedPort(direction::String)
    directions = Dict(
        "+X" => [1.0, 0.0, 0.0],
        "-X" => [-1.0, 0.0, 0.0],
        "+Y" => [0.0, 1.0, 0.0],
        "-Y" => [0.0, -1.0, 0.0],
        "+Z" => [0.0, 0.0, 1.0],
        "-Z" => [0.0, 0.0, -1.0]
    )
    haskey(directions, direction) || throw(
        ArgumentError(
            "direction must be one of: $(join(sort!(collect(keys(directions))), ", "))"
        )
    )
    return LumpedPort(directions[direction])
end

Base.:(==)(a::LumpedPort, b::LumpedPort) = a.direction == b.direction
Base.hash(p::LumpedPort, h::UInt) = hash((LumpedPort, p.direction), h)

Base.show(io::IO, ::Generic) = print(io, "Generic")
Base.show(io::IO, ::Terminal) = print(io, "Terminal")
Base.show(io::IO, ::Ground) = print(io, "Ground")
Base.show(io::IO, ::Tag) = print(io, "Tag")
Base.show(io::IO, ::WavePort) = print(io, "WavePort")
Base.show(io::IO, ::LumpedPort) = print(io, "LumpedPort")

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

function EntityMeta(layer::Symbol; name::String="", index::Int=1, role=Generic())
    resolved_role = role isa Type{<:Role} ? role() : role
    resolved_role isa Role || throw(ArgumentError("role must be a Role or Role type"))
    return EntityMeta(layer, name, index, resolved_role)
end

DeviceLayout.layer(m::EntityMeta) = m.layer
DeviceLayout.layerindex(m::EntityMeta) = m.index
DeviceLayout.name(m::EntityMeta) = m.name
Base.broadcastable(m::EntityMeta) = Ref(m)

"""
Return the stable physical-group name for an `EntityMeta`.
"""
function physical_group_name(m::EntityMeta)::String
    return "$(m.layer)__$(m.name)__i$(m.index)__r$(string(m.role))"
end

# Retained as the prototype compiler spelling, within the Experimental namespace.
map_meta(m::EntityMeta) = physical_group_name(m)
