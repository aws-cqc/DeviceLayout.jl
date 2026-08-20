"""
    SourceLayer(material; level=1, height=0μm, thickness=0μm,
                contour_only=false, keep_interior=true, gds_meta=nothing,
                solidmodel=true)

Describes one symbol-keyed source layer. `isnothing(gds_meta)` hides the layer only
from artwork; `solidmodel=false` hides it only from solid-model geometry and metadata.
A paired level derives its effective thickness from its [`SourceStack`](@ref).
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
    SourceStack(layer_pairs...; levels)

Collection of source layers and assembly-level z coordinates. Length coordinates must be
either all unitful or all unitless.
"""
struct SourceStack{L <: SourceLayer, T <: Coordinate}
    layers::Dict{Symbol, L}
    levels::Dict{Int, T}

    function SourceStack(
        layers::Dict{Symbol, L},
        levels::Dict{Int, T}
    ) where {L <: SourceLayer, T <: Coordinate}

        # Check that all fields representing lengths are either all unitless or all unitful
        coordinates = Any[]
        for source_layer in values(layers)
            push!(coordinates, source_layer.height...)
            push!(coordinates, source_layer.thickness)
        end
        append!(coordinates, values(levels))
        all_unitless = all(c -> c isa Real, coordinates)
        all_unitful = all(c -> c isa Unitful.Quantity, coordinates)
        (all_unitless || all_unitful) ||
            throw(ArgumentError("SourceStack cannot mix unitful and unitless coordinates"))

        # Check all referenced levels exist
        for (name, layer) in layers
            for l in layer.level
                if !haskey(levels, l)
                    throw(
                        ArgumentError(
                            "Source layer $name references missing assembly level $l"
                        )
                    )
                end
            end
        end

        return new{L, T}(layers, levels)
    end
end

function SourceStack(layer_pairs::Pair{Symbol, <:SourceLayer}...; levels)
    return SourceStack(Dict(layer_pairs), Dict(levels))
end

"""
    sourcelayer(layer, stack::SourceStack)

Return the source layer identified by an `EntityMeta`, layer name, or source layer.
"""
function sourcelayer(layer::Symbol, stack::SourceStack)
    haskey(stack.layers, layer) ||
        throw(ArgumentError("layer $layer does not exist in SourceStack"))
    return stack.layers[layer]
end
sourcelayer(m::EntityMeta, stack::SourceStack) = sourcelayer(m.layer, stack)

"""
    layer_z(layer, stack::SourceStack)

Return the source z coordinate for a layer name or source layer.
"""
function layer_z(layer::SourceLayer, stack::SourceStack)
    return stack.levels[first(layer.level)] + first(layer.height)
end
layer_z(layer::Symbol, stack::SourceStack) = layer_z(sourcelayer(layer, stack), stack)

"""
    thickness(sl::SourceLayer, stack::SourceStack)

Return a source layer's explicit or level-pair-derived extrusion thickness.
"""
function thickness(layer::SourceLayer, stack::SourceStack)
    layer.level isa Pair || return layer.thickness
    source_z = stack.levels[first(layer.level)] + first(layer.height)
    destination_z = stack.levels[last(layer.level)] + last(layer.height)
    return destination_z - source_z
end
