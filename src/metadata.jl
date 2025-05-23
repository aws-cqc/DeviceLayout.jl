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
For example, “this polygon is in the negative of the ground plane” is semantic, while
“this polygon is in GDS layer 1, datatype 2” is not. The semantic metadata is used in the
final `render` step, where a layout is converted from a `CoordinateSystem` to a
representation corresponding to a particular output format (e.g., a `Cell` for GDSII).
A call to `render!(cell::Cell{S}, cs::CoordinateSystem; map_meta = identity, kwargs...)`
will use the `map_meta` function to map each `GeometryEntity`'s metadata to `GDSMeta`.

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
