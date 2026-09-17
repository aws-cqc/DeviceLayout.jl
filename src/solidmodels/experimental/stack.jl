"""
    SourceLayer(material; level=1, offset=0μm, thickness=0μm, gds_meta=nothing,
                solidmodel=true)

Describe one symbol-keyed source layer. Set `material` to `METAL`, `DIELECTRIC`, or
`NULL` to classify the solid-model region.
`level` selects the assembly level at which the layer's 2D geometry is placed; `offset`
displaces it from that level. `thickness` declares the layer's extrusion distance, or a
level pair `level=a => b` declares that the layer spans from level `a` to level `b` (with
`offset` then a pair of displacements at each end). Declared thicknesses are built by an
explicit [`Extrude`](@ref) operation, which validates against the declaration.
`gds_meta=nothing` hides the layer only from artwork; `solidmodel=false` hides it only from
solid-model geometry and metadata.
"""
struct SourceLayer{T <: Coordinate}
    material::Material
    level::Union{Int, Pair{Int, Int}}
    offset::Union{T, NTuple{2, T}}
    thickness::T
    gds_meta::Union{GDSMeta, Nothing}
    solidmodel::Bool
end

function SourceLayer(
    material::Material;
    level::Union{Int, Pair{Int, Int}}=1,
    offset::Union{Coordinate, NTuple{2, Coordinate}}=0μm,
    thickness::Coordinate=0μm,
    gds_meta::Union{GDSMeta, Nothing}=nothing,
    solidmodel::Bool=true
)
    if offset isa Tuple
        o1, o2 = offset
        T = promote_type(typeof(o1), typeof(o2), typeof(thickness))
        converted_offset = (convert(T, o1), convert(T, o2))
    else
        T = promote_type(typeof(offset), typeof(thickness))
        converted_offset = convert(T, offset)
    end
    return SourceLayer{T}(
        material,
        level,
        converted_offset,
        convert(T, thickness),
        gds_meta,
        solidmodel
    )
end

"""
    SourceStack(layer_pairs...; levels)

Collect symbol-keyed [`SourceLayer`](@ref) pairs and assembly-level z coordinates. Every
level referenced by a source layer must be present in `levels`. Length coordinates must be
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
            push!(coordinates, source_layer.offset...)
            push!(coordinates, source_layer.thickness)
        end
        append!(coordinates, values(levels))
        all_unitless = all(c -> c isa Real, coordinates)
        all_unitful = all(c -> c isa Unitful.Quantity, coordinates)
        (all_unitless || all_unitful) ||
            throw(ArgumentError("source stack cannot mix unitful and unitless coordinates"))

        # Check all referenced levels exist
        for (name, layer) in layers
            for l in layer.level
                if !haskey(levels, l)
                    throw(
                        ArgumentError(
                            "source layer $name references missing assembly level $l"
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

# Return the source layer identified by a layer symbol, layer reference, or locator metadata.
function sourcelayer(layer::Symbol, stack::SourceStack)
    haskey(stack.layers, layer) ||
        throw(ArgumentError("layer $layer does not exist in source stack"))
    return stack.layers[layer]
end
sourcelayer(meta::Union{LayerRef, LocatorMeta}, stack::SourceStack) =
    sourcelayer(layer(meta), stack)

# Return the source z coordinate for a layer symbol or SourceLayer.
function layer_z(layer::SourceLayer, stack::SourceStack)
    return stack.levels[first(layer.level)] + first(layer.offset)
end
layer_z(layer::Symbol, stack::SourceStack) = layer_z(sourcelayer(layer, stack), stack)

# Return a source layer's explicit or level-pair-derived extrusion thickness.
function thickness(layer::SourceLayer, stack::SourceStack)
    layer.level isa Pair || return layer.thickness
    source_z = stack.levels[first(layer.level)] + first(layer.offset)
    destination_z = stack.levels[last(layer.level)] + last(layer.offset)
    return destination_z - source_z
end
