"""
    SourceLayer(material; level=1, height=0μm, thickness=0μm,
                contour_only=false, keep_interior=true, gds_meta=nothing,
                solidmodel=true)

Describes one symbol-keyed source layer. `isnothing(gds_meta)` hides the layer only
from artwork; `solidmodel=false` hides it only from solid-model geometry and metadata.
A paired level derives its effective thickness from [`StackLevels`](@ref).
"""
struct SourceLayer{T <: Coordinate}
    material::Material
    level::Union{Int, Pair{Int, Int}}
    height::Union{T, NTuple{2, T}}
    thickness::T
    contour_only::Bool
    keep_interior::Bool
    gds_meta::Union{GDSMeta, Nothing}
    solidmodel::Bool
end

function SourceLayer(
    material::Material;
    level::Union{Int, Pair{Int, Int}}=1,
    height::Union{Coordinate, NTuple{2, Coordinate}}=0μm,
    thickness::Coordinate=0μm,
    contour_only::Bool=false,
    keep_interior::Bool=true,
    gds_meta::Union{GDSMeta, Nothing}=nothing,
    solidmodel::Bool=true
)
    if height isa Tuple
        h1, h2 = height
        T = promote_type(typeof(h1), typeof(h2), typeof(thickness))
        converted_height = (convert(T, h1), convert(T, h2))
    else
        T = promote_type(typeof(height), typeof(thickness))
        converted_height = convert(T, height)
    end
    return SourceLayer{T}(
        material,
        level,
        converted_height,
        convert(T, thickness),
        contour_only,
        keep_interior,
        gds_meta,
        solidmodel
    )
end

"""
    first_level(sl::SourceLayer)

Return the first assembly level referenced by `sl`.
"""
first_level(sl::SourceLayer) = sl.level isa Pair ? first(sl.level) : sl.level

"""
    first_height(sl::SourceLayer)

Return the height associated with [`first_level`](@ref) for `sl`.
"""
first_height(sl::SourceLayer) = sl.height isa Tuple ? first(sl.height) : sl.height
_referenced_levels(sl::SourceLayer) =
    sl.level isa Pair ? (first(sl.level), last(sl.level)) : (sl.level,)

"""
    SourceStack()
    SourceStack(pairs::Pair{Symbol, <:SourceLayer}...)

Mapping from plain layer symbols to source-layer records.
"""
struct SourceStack
    layers::Dict{Symbol, SourceLayer}
end
SourceStack() = SourceStack(Dict{Symbol, SourceLayer}())
function SourceStack(pairs::Pair{Symbol, <:SourceLayer}...)
    return SourceStack(Dict{Symbol, SourceLayer}(pairs))
end

Base.getindex(s::SourceStack, k::Symbol) = s.layers[k]
Base.haskey(s::SourceStack, k::Symbol) = haskey(s.layers, k)
Base.keys(s::SourceStack) = keys(s.layers)
Base.values(s::SourceStack) = values(s.layers)
Base.length(s::SourceStack) = length(s.layers)
Base.iterate(s::SourceStack, state...) = iterate(s.layers, state...)

"""
    StackLevels(pairs::Pair{Int}...)

Mapping from assembly level indices to z coordinates.
"""
struct StackLevels{T <: Coordinate}
    levels::Dict{Int, T}
end
function StackLevels(pairs::Pair{Int}...)
    isempty(pairs) && return StackLevels(Dict{Int, Int}())
    T = promote_type(typeof.(last.(pairs))...)
    return StackLevels(Dict{Int, T}(k => convert(T, v) for (k, v) in pairs))
end

Base.getindex(s::StackLevels, k::Int) = s.levels[k]
Base.haskey(s::StackLevels, k::Int) = haskey(s.levels, k)
Base.keys(s::StackLevels) = keys(s.levels)
Base.length(s::StackLevels) = length(s.levels)
Base.iterate(s::StackLevels, state...) = iterate(s.levels, state...)

# SolidModels interprets unitless coordinates in STP units (microns). Keep that public
# Coordinate behavior when serializing metadata and evaluating locator positions.
_micron_value(value::Real) = Float64(value)
_micron_value(value) = Float64(ustrip(μm, value))

_stack_z(level_value::Real, height::Real) = level_value + height
_stack_z(level_value::Real, height) = level_value + _micron_value(height)
_stack_z(level_value, height::Real) = level_value + height * μm
_stack_z(level_value, height) = level_value + height
_subtract_height(delta::Real, height::Real) = delta - height
_subtract_height(delta::Real, height) = delta - _micron_value(height)
_subtract_height(delta, height::Real) = delta - height * μm
_subtract_height(delta, height) = delta - height

"""
    resolve_thickness(sl::SourceLayer, levels::StackLevels)

Resolve a source layer's explicit or level-pair-derived extrusion thickness.
"""
function resolve_thickness(sl::SourceLayer, levels::StackLevels)
    if sl.level isa Pair
        source_level, destination_level = first(sl.level), last(sl.level)
        if sl.height isa Tuple
            source_height, destination_height = sl.height
            return _stack_z(levels[destination_level], destination_height) -
                   _stack_z(levels[source_level], source_height)
        end
        return _subtract_height(levels[destination_level] - levels[source_level], sl.height)
    end
    return sl.thickness
end

function _validate_source_layer(layer_name::Symbol, sl::SourceLayer, levels::StackLevels)
    for idx in _referenced_levels(sl)
        haskey(levels, idx) || throw(
            ArgumentError(
                "Source layer :$layer_name references missing assembly level $idx"
            )
        )
    end
    return nothing
end

function _validate_stack(stack::SourceStack, levels::StackLevels)
    for (layer_name, source_layer) in stack
        _validate_source_layer(layer_name, source_layer, levels)
    end
    return nothing
end

function _require_source_layer(stack::SourceStack, m::EntityMeta; context="entity")
    haskey(stack, m.layer) || throw(
        ArgumentError(
            "$context references layer :$(m.layer), which is absent from SourceStack " *
            "(entity name=$(repr(m.name)), index=$(m.index))"
        )
    )
    return stack[m.layer]
end
