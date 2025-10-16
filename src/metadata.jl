"""
    struct SemanticMeta <: DeviceLayout.Meta
        layer::Symbol
        index::Int = 1
        level::Int = 1
    end
    SemanticMeta(layer::String; kwargs...)
    SemanticMeta(meta::Meta; kwargs...)

DeviceLayout-native representation of an object's layer information and attributes.

Semantic metadata refers to the meaning of an element without reference to a fixed encoding.
For example, "this polygon is in the negative of the ground plane" is semantic, while
"this polygon is in GDS layer 1, datatype 2" is not. The semantic metadata is used in the
final `render` step, where a layout is converted from a `CoordinateSystem` to a
representation corresponding to a particular output format (e.g., a `Cell` for GDSII).
A call to `render!(cell::Cell{S}, cs::CoordinateSystem; map_meta = default_meta_map, kwargs...)`
will use the `map_meta` function to map each `GeometryEntity`'s metadata to `GDSMeta`.

By default, [`DeviceLayout.default_meta_map`](@ref) is used, which:

  - Passes GDSMeta through unchanged
  - Converts other metadata types to GDSMeta using a hash-based layer assignment (0-255)

The `level` and `index` fields do not have a strict interpretation imposed by DeviceLayout. (In
this sense they are similar to GDS `datatype`.) The suggested use is as follows:

  - `index` distinguishes numbered instances within a layer, for example in greyscale
    lithography or port numbering
  - `level` distinguishes instances of a layer occurring in different contexts, such as in
    a 3D stack where equivalent layers may be present in multiple levels
"""
struct SemanticMeta <: DeviceLayout.Meta
    layer::Symbol
    index::Int
    level::Int
end
SemanticMeta(layer::Symbol; index::Int=1, level::Int=1) = SemanticMeta(layer, index, level)
SemanticMeta(layer::String; kwargs...) = SemanticMeta(Symbol(layer); kwargs...)
SemanticMeta(meta::SemanticMeta; index=layerindex(meta), level=level(meta)) =
    SemanticMeta(layer(meta); index=index, level=level)
SemanticMeta(meta::Meta; index=layerindex(meta), level=level(meta)) =
    SemanticMeta(layername(meta); index=index, level=level)

const UNDEF_META = SemanticMeta(:undefined)
const NORENDER_META = SemanticMeta(:norender)

"""
    layer(m::Meta)

The layer specified by `m`, as a `Symbol`.

For example, `layer(GDSMeta(1, 2))` is `:GDS1_2`, and `layername(SemanticMeta(:base))` is `:base`.
"""
layer(s::SemanticMeta) = s.layer

"""
    level(m::Meta)

The `level` specified by metadata `s`. Defaults to `1` for metadata types without a `level`.
"""
level(s::SemanticMeta) = s.level
level(::Meta) = 1

"""
    layerindex(m::Meta)

The `index` specified by metadata `m`. Defaults to `1` for metadata types without an `index`.
"""
layerindex(s::SemanticMeta) = s.index
layerindex(::Meta) = 1

"""
    layername(m::Meta)

The layer specified by `m`, as a `String`.

For example, `layer(GDSMeta(1, 2))` is `"GDS1_2"`, and `layername(SemanticMeta(:base))` is `"base"`.
"""
layername(meta::Meta) = String(layer(meta))

Base.convert(::Type{SemanticMeta}, x::Meta) = SemanticMeta(x)

"""
    struct GDSMeta <: DeviceLayout.Meta
        layer::Int
        datatype::Int
        GDSMeta() = new(DEFAULT_LAYER, DEFAULT_DATATYPE)
        GDSMeta(l) = new(l, DEFAULT_DATATYPE)
        GDSMeta(l, d) = new(l, d)
    end

Metadata associated with GDSII format. Default layer and datatype are 0.
"""
struct GDSMeta <: Meta
    layer::Int
    datatype::Int
    GDSMeta() = new(DEFAULT_LAYER, DEFAULT_DATATYPE)
    GDSMeta(l) = new(l, DEFAULT_DATATYPE)
    GDSMeta(l, d) = new(l, d)
end
gdslayer(x::GDSMeta) = x.layer
datatype(x::GDSMeta) = x.datatype
layername(x::GDSMeta) = "GDS$(gdslayer(x))_$(datatype(x))"
layer(x::GDSMeta) = Symbol(layername(x))

Base.broadcastable(x::Meta) = Ref(x)

"""
    layer_included(m::Meta, only_layers, ignore_layers)

Return whether `m` or `layer(m)` is included based on inclusion/exclusion rules.

Both `only_layers` and `ignore_layers` are collections of `DeviceLayout.Meta` and/or layer name `Symbol`s.

If `only_layers` is empty, then only `ignore_layers` is used, and `layer_included` checks that neither `m` nor `layer(m)` is in `ignore_layers`.
Otherwise, `layer_included` also checks that `m` or `layer(m)` is in `only_layers`.
"""
function layer_included(m::Meta, only_layers, ignore_layers)
    return layer_inclusion(only_layers, ignore_layers)(m)
end

trivial_inclusion(m) = true

"""
    layer_inclusion(only_layers, ignore_layers)

Return a function `f(m::Meta)` that returns a `Bool` based on inclusion/exclusion rules.

Both `only_layers` and `ignore_layers` are  `DeviceLayout.Meta`, layer name `Symbol`s, and/or collections of either.

If `only_layers` is empty, then only `ignore_layers` is used, and `f(m)` checks that neither `m` nor `layer(m)` is in `ignore_layers`.
Otherwise, `f(m)` also checks that `m` or `layer(m)` is in `only_layers`.
"""
function layer_inclusion(only_layers, ignore_layers)
    isempty(only_layers) && isempty(ignore_layers) && return trivial_inclusion
    isempty(only_layers) && return m -> !(layer(m) in ignore_layers || m in ignore_layers)
    return m -> (
        (layer(m) in only_layers || m in only_layers) &&
        !(layer(m) in ignore_layers || m in ignore_layers)
    )
end

layer_inclusion(only_layers::Union{Symbol, Meta}, ignore_layers) =
    layer_inclusion([only_layers], ignore_layers)
layer_inclusion(only_layers, ignore_layers::Union{Symbol, Meta}) =
    layer_inclusion(only_layers, [ignore_layers])
layer_inclusion(only_layers::Union{Symbol, Meta}, ignore_layers::Union{Symbol, Meta}) =
    layer_inclusion([only_layers], [ignore_layers])

"""
    hash_to_gdslayer(meta::Meta) -> Int

Convert metadata `m` to a GDS layer number (0-255) by hashing `(layer(m), level(m))`.

Values are repeatable for different metadata, but only probably distinct.
"""
function hash_to_gdslayer(meta::Meta)
    h = hash((layer(meta), level(meta)))
    return Int(h % UInt8)
end

"""
    default_meta_map(meta::Meta) -> GDSMeta

Default metadata mapping function for rendering to Cell.

This map is for convenient graphical display and should not be relied on in production workflows.

GDSMeta passes through unchanged.

Other Meta types are converted to GDSMeta using a
layer in (0-255) based on the hash of `(layer(m), level(m))` and datatype
`layerindex(m)-1` (clamped to 0-255). This means that other metadata
types are not guaranteed to be mapped to unique GDSMeta.

# Examples

```julia
julia> default_meta_map(GDSMeta(10, 2))
GDSMeta(10, 2)

julia> default_meta_map(SemanticMeta(:metal))
GDSMeta(63, 0)  # Hash-based layer, datatype from index

julia> default_meta_map(SemanticMeta(:metal, index=5))
GDSMeta(63, 4)  # Same layer, different datatype
```
"""
function default_meta_map(meta::GDSMeta)
    return meta
end

function default_meta_map(meta::Meta)
    layer_num = hash_to_gdslayer(meta)
    # Use layerindex-1 as datatype (0-based), clamped to valid range
    datatype_num = clamp(layerindex(meta) - 1, 0, 255)
    return GDSMeta(layer_num, datatype_num)
end
