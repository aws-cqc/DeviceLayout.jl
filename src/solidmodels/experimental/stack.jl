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

Collection of source layers and assembly-level z coordinates. Layer heights, explicit
thicknesses, and level coordinates are converted to one common coordinate type `T`.
Unitful and unitless coordinates cannot be mixed in the same stack.
"""
struct SourceStack{T <: Coordinate}
    layers::Dict{Symbol, SourceLayer{T}}
    levels::Dict{Int, T}
end

function SourceStack(layer_pairs::Pair{Symbol, <:SourceLayer}...; levels)
    level_dict = levels isa AbstractDict ? levels : Dict(levels)
    return SourceStack(Dict{Symbol, SourceLayer}(layer_pairs), level_dict)
end

function SourceStack(
    layers::AbstractDict{<:Symbol, <:SourceLayer},
    levels::AbstractDict{<:Integer}
)
    coordinates = Any[]
    for source_layer in values(layers)
        if source_layer.height isa Tuple
            append!(coordinates, source_layer.height)
        else
            push!(coordinates, source_layer.height)
        end
        push!(coordinates, source_layer.thickness)
    end
    append!(coordinates, values(levels))
    isempty(coordinates) && throw(ArgumentError("SourceStack requires coordinate values"))

    all_unitless = all(coordinate -> coordinate isa Real, coordinates)
    all_unitful = all(coordinate -> !(coordinate isa Real), coordinates)
    (all_unitless || all_unitful) ||
        throw(ArgumentError("SourceStack cannot mix unitful and unitless coordinates"))

    T = promote_type(typeof.(coordinates)...)

    converted_layers = Dict{Symbol, SourceLayer{T}}()
    for (layer_name, source_layer) in layers
        converted_height = if source_layer.height isa Tuple
            convert.(T, source_layer.height)
        else
            convert(T, source_layer.height)
        end
        converted_layers[layer_name] = SourceLayer{T}(
            source_layer.material,
            source_layer.level,
            converted_height,
            convert(T, source_layer.thickness),
            source_layer.contour_only,
            source_layer.keep_interior,
            source_layer.gds_meta,
            source_layer.solidmodel
        )
    end
    converted_levels = Dict{Int, T}(level => convert(T, z) for (level, z) in levels)
    return SourceStack{T}(converted_layers, converted_levels)
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
function layer_z(source_layer::SourceLayer{T}, stack::SourceStack{T}) where {T}
    return stack.levels[first(source_layer.level)] + first(source_layer.height)
end
layer_z(layer::Symbol, stack::SourceStack) = layer_z(sourcelayer(layer, stack), stack)

"""
    thickness(source_layer::SourceLayer, stack::SourceStack)

Return a source layer's explicit or level-pair-derived extrusion thickness.
"""
function thickness(source_layer::SourceLayer{T}, stack::SourceStack{T}) where {T}
    source_layer.level isa Pair || return source_layer.thickness

    source_z = stack.levels[first(source_layer.level)] + first(source_layer.height)
    destination_z = stack.levels[last(source_layer.level)]
    if source_layer.height isa Tuple
        destination_z += last(source_layer.height)
    end
    return destination_z - source_z
end

function _validate_source_layer(
    layer_name::Symbol,
    source_layer::SourceLayer,
    stack::SourceStack
)
    for level in (first(source_layer.level), last(source_layer.level))
        haskey(stack.levels, level) || throw(
            ArgumentError(
                "Source layer :$layer_name references missing assembly level $level"
            )
        )
    end
    return nothing
end

function _validate_stack(stack::SourceStack)
    for (layer_name, source_layer) in stack.layers
        _validate_source_layer(layer_name, source_layer, stack)
    end
    return nothing
end
