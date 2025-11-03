"""
    abstract type GeometryEntityStyle

A style that can be used with a `GeometryEntity` to create a modified entity.

May use `(sty::MyStyle)(ent)`, `styled(ent, sty)`, or
`MyStyle(ent, style_args...; style_kwargs...)` to create a `StyledEntity`.

A `GeometryEntityStyle` should implement `to_polygons(::MyEntity, ::MyStyle; kwargs...)` for
any entity type it can be applied to. As a fallback, it can implement
`to_polygons(::Polygon, ::MyStyle; kwargs...)`, in which case entities will be converted to
polygons before applying the style.

Unless implemented by the style, `lowerleft` and `upperright` (and hence `bounds`)
of a styled entity will use the underlying entity's bounds. Similarly, `footprint` and
`halo` will fall back to using the underlying entity. Exceptions include the `NoRender`
style, in which case the entity is treated as a zero-area `Rectangle`
(ignored in collective `bounds` calculations), as well as `OptionalStyle`, in which
case the default style is used (in case it has special behavior).
"""
abstract type GeometryEntityStyle end

Base.broadcastable(x::GeometryEntityStyle) = Ref(x)

"""
    StyledEntity{T, U <: GeometryEntity{T}, S <: GeometryEntityStyle} <: GeometryEntity

`GeometryEntity` composing another `GeometryEntity` with a `GeometryEntityStyle`.

The use of a `StyledEntity` allows the composition of operations like rounding on geometric
entities without committing to a particular representation of those entities.
"""
struct StyledEntity{T, U <: GeometryEntity{T}, S <: GeometryEntityStyle} <:
       GeometryEntity{T}
    ent::U
    sty::S
end

Base.convert(::Type{GeometryEntity{T}}, e::StyledEntity) where {T} =
    StyledEntity(convert(GeometryEntity{T}, e.ent), e.sty)
Base.copy(ent::StyledEntity) = styled(ent.ent, ent.sty)

"""
    style(styled_ent::StyledEntity)

Return the `GeometryEntityStyle` of `styled_ent`.
"""
style(styled_ent::StyledEntity) = styled_ent.sty
style(::GeometryEntity) = Plain()

"""
    entity(styled_ent::StyledEntity)

Return the `GeometryEntity` styled by `styled_ent`.
"""
entity(styled_ent::StyledEntity) = styled_ent.ent
entity(ent::GeometryEntity) = ent

"""
    styled(ent, sty)

Return `StyledEntity(ent, sty)`.
"""
styled(ent, sty) = StyledEntity(ent, sty)
(s::GeometryEntityStyle)(ent::GeometryEntity) = StyledEntity(ent, s)
(T::Type{<:GeometryEntityStyle})(x::GeometryEntity, args...; kwargs...) =
    styled(x, T(args...; kwargs...))

"""
    unstyled(styled_ent::StyledEntity)

Return the unstyled entity referenced by `styled_ent`.

If `styled_ent.ent` is itself a `StyledEntity`, apply `unstyled` recursively until
the original plain `GeometyEntity` is found.
"""
unstyled(styled_ent::StyledEntity) = unstyled(styled_ent.ent)
unstyled(ent::GeometryEntity) = ent

"""
    unstyled_type(::GeometryEntity)
    unstyled_type(::Type{GeometryEntity})

Return the type of the unstyled entity beneath all styles.
"""
unstyled_type(::Type{StyledEntity{T, U, V}}) where {T, U, V} = unstyled_type(U)
unstyled_type(::Type{T}) where {T <: GeometryEntity} = T
unstyled_type(::T) where {T <: GeometryEntity} = unstyled_type(T)

lowerleft(ent::StyledEntity{T, U, V}) where {T, U, V} = lowerleft(ent.ent)
upperright(ent::StyledEntity{T, U, V}) where {T, U, V} = upperright(ent.ent)
footprint(ent::StyledEntity{T, U, V}) where {T, U, V} = footprint(ent.ent)
halo(ent::StyledEntity{T, U, V}, outer_delta, inner_delta=nothing) where {T, U, V} =
    halo(ent.ent, outer_delta, inner_delta)

"""
    to_polygons(styled_ent::StyledEntity)

Return an unstyled `Polygon` or Vector{<:Polygon} resulting from the application of styles.
"""
function to_polygons(styled_ent::StyledEntity; kwargs...)
    return to_polygons(styled_ent.ent, styled_ent.sty; kwargs...)
end

# Dispatch directly on array entity to avoid ambiguity
function to_polygons(
    styled_ent::StyledEntity{T, U};
    kwargs...
) where {T, U <: ArrayEntity{T}}
    return to_polygons.(styled_ent.ent.a, styled_ent.sty; kwargs...)
end

# If a style has no specialization for `ent`, convert `ent` to polygons first
function to_polygons(ent::GeometryEntity, sty::GeometryEntityStyle; kwargs...)
    return to_polygons.(to_polygons(ent; kwargs...), sty; kwargs...)
end

# default no transform
transform(sty::GeometryEntityStyle, f::Transformation) = sty
transform(ent::StyledEntity, f::Transformation) =
    StyledEntity(f(ent.ent), transform(ent.sty, f))

###### Generic styles
"""
    Plain <: GeometryEntityStyle

Plain style. Does not affect rendering of the styled entity.
"""
struct Plain <: GeometryEntityStyle end
to_polygons(ent::GeometryEntity, ::Plain; kwargs...) = to_polygons(ent; kwargs...)

"""
    NoRender <: GeometryEntityStyle

Style that marks an entity to be skipped when rendering.

`NoRender`-styled entities have zero-area `bounds` and `footprint` and empty `halo`.
"""
struct NoRender <: GeometryEntityStyle end
to_polygons(::GeometryEntity{T}, ::NoRender; kwargs...) where {T} = Polygon{T}[]
lowerleft(::StyledEntity{T, U, NoRender}) where {T, U} = zero(Point{T})
upperright(::StyledEntity{T, U, NoRender}) where {T, U} = zero(Point{T})
footprint(ent::StyledEntity{T, U, NoRender}) where {T, U} = bounds(ent)
halo(::StyledEntity{T, U, NoRender}, outer_delta, inner_delta=nothing) where {T, U} =
    Polygon{T}[]

"""
    struct MeshSized{T, S} <: GeometryEntityStyle where {T, S <: Real}
        h::T
        α::S
    end

Style that annotates a GeometryEntity with a mesh size to use in SolidModel rendering. The
generated mesh will include a size field defined as:

```
mesh size = h * max(s_g, (d/h)^α)
```

where d is the distance away from the styled entity, and `s_g` is the global mesh scale
parameter specified in [`mesh_scale`](@ref). A smaller value of `h` will give a finer mesh
attached to the styled entity, and a larger value of `α` will give a more rapid increase in
size away from the styled entity.

If `α < 0`, the size field will use [`mesh_grading_default`](@ref) used in rendering.

See also [`meshsized_entity`](@ref).
"""
struct MeshSized{T, S} <: GeometryEntityStyle where {T <: Coordinate, S <: Real}
    h::T
    α::S
    MeshSized(h::T, α::S=-1.0) where {T <: Coordinate, S <: Real} = new{T, S}(h, α) # Silence Aqua
end

"""
    meshsized_entity(ent::GeometryEntity, h::T, α::S=-1.0) where {T, S <: Real}

Create a [`MeshSized`](@ref) entity, specifying a mesh size use in SolidModel rendering. The
generated mesh will include a size field defined as:

```
mesh size = h * max(s_g, (d/h)^α)
```

where d is the distance away from the styled entity, and `s_g` is the global mesh scale
parameter specified in [`mesh_scale`](@ref). A smaller value of `h` will give a finer mesh
attached to the styled entity, and a larger value of `α` will give a more rapid increase in
size away from the styled entity.

If `α < 0`, the size field will use [`mesh_grading_default`](@ref) used in rendering.
"""
meshsized_entity(ent::GeometryEntity, h::T, α::S=-1.0) where {T, S <: Real} =
    MeshSized(h, α)(ent)
to_polygons(ent::GeometryEntity, ::MeshSized; kwargs...) = to_polygons(ent; kwargs...)

"""
    struct OptionalStyle <: GeometryEntityStyle
        true_style::GeometryEntityStyle
        false_style::GeometryEntityStyle
        flag::Symbol
        default::Bool
    end
    OptionalStyle(true_style::GeometryEntityStyle, flag::Symbol;
        false_style::GeometryEntityStyle=Plain(), default::Bool=true)

Style that depends on a Boolean rendering option `flag` with default `default`.

`lowerleft`, `upperright`, `bounds`, `footprint`, and `halo` are forwarded to the
underlying entity styled with the default style.

# Examples

```julia
sty = OptionalStyle(Rounded(1μm), :rounding)
p = Rectangle(4μm, 4μm)
rounded_rect = to_polygons(sty(p))
plain_rect = to_polygons(sty(p), rounding=false)
```
"""
struct OptionalStyle <: GeometryEntityStyle
    true_style::GeometryEntityStyle
    false_style::GeometryEntityStyle
    flag::Symbol
    default::Bool
    OptionalStyle(a::GeometryEntityStyle, b, c, d) = new(a, b, c, d) # Silence Aqua
end
function OptionalStyle(
    true_style::GeometryEntityStyle,
    flag::Symbol;
    false_style::GeometryEntityStyle=Plain(),
    default::Bool=true
)
    return OptionalStyle(true_style, false_style, flag, default)
end

function to_polygons(ent::GeometryEntity, opt::OptionalStyle; kwargs...)
    sty = get(kwargs, opt.flag, opt.default) ? opt.true_style : opt.false_style
    return to_polygons(ent, sty; kwargs...)
end

function transform(sty::OptionalStyle, f::Transformation)
    return OptionalStyle(
        transform(sty.true_style, f),
        sty.flag,
        false_style=transform(sty.false_style, f),
        default=sty.default
    )
end

default_style(sty::OptionalStyle) = sty.default ? sty.true_style : sty.false_style

# Apply default style for interface functions
function lowerleft(ent::StyledEntity{T, U, OptionalStyle}) where {T, U}
    return lowerleft(default_style(ent.sty)(ent.ent))
end
function upperright(ent::StyledEntity{T, U, OptionalStyle}) where {T, U}
    return upperright(default_style(ent.sty)(ent.ent))
end
function footprint(ent::StyledEntity{T, U, OptionalStyle}) where {T, U}
    return footprint(default_style(ent.sty)(ent.ent))
end
function halo(
    ent::StyledEntity{T, U, OptionalStyle},
    outer_delta,
    inner_delta=nothing
) where {T, U}
    return halo(default_style(ent.sty)(ent.ent), outer_delta, inner_delta)
end

"""
    optional_entity(ent::GeometryEntity, flag::Symbol;
        true_style::GeometryEntityStyle=Plain(), default=true)

Return an entity to be rendered or not based on the rendering option `flag`.

# Example

```julia
julia> c = Cell();

julia> ent = optional_entity(Rectangle(2, 2), :optional_entities; default=false);

julia> render!(c, ent);

julia> length(elements(c))
0

julia> render!(c, ent; optional_entities=true);

julia> length(elements(c))
1
```
"""
optional_entity(
    ent::GeometryEntity,
    flag::Symbol;
    true_style::GeometryEntityStyle=Plain(),
    default=true
) = OptionalStyle(true_style, NoRender(), flag, default)(ent)

"""
    struct ToTolerance{T<:Coordinate} <: GeometryEntityStyle
        atol::T
    end

Style for rendering an entity to absolute tolerance `atol`.

Equivalent to passing or overriding the keyword `atol` when rendering this entity.
"""
struct ToTolerance{T <: Coordinate} <: GeometryEntityStyle
    atol::T
    ToTolerance(atol::T) where {T <: Coordinate} = new{T}(atol) # Silence Aqua
end
to_polygons(ent::GeometryEntity, sty::ToTolerance; kwargs...) =
    to_polygons(ent; merge((; kwargs...), (; atol=sty.atol))...)
