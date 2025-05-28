"""
    GeometryEntity{T <: Coordinate}

A geometric entity that can be placed in a coordinate system.

New concrete `GeometryEntity` subtypes must implement the following:

```julia
to_polygons(::MyEntity)
transform(ent::MyEntity, f)
```

A subtype may also implement specialized transformations like
`transform(::MyEntity, ::ScaledIsometry)`, for example if
special handling is possible for angle-preserving transformations, as well as
specializations for

```
magnify
rotate
rotate90
reflect_across_xaxis
translate
```

which otherwise construct the corresponding `ScaledIsometry` and call `transform`.

New subtypes may also implement

```julia
footprint
halo
lowerleft
upperright
```

if there are better ways to calculate these than with `to_polygons` (the default),
which may be slow and expensive. The bounding rectangle returned by `bounds` is derived
from `lowerleft` and `upperright`. By default, `halo` is derived from `footprint` and
`offset`.

New subtypes may also implement any application functions required for valid styles.
Not all styles need be valid for any given entity type.
"""
abstract type GeometryEntity{T} <: AbstractGeometry{T} end

###### Array of GeometryEntity as a GeometryEntity
"""
    struct ArrayEntity{T, S} <: GeometryEntity{T}
        a::S
    end

A wrapper `GeometryEntity` for an `AbstractArray` `a` of `GeometryEntity{T}`.
"""
struct ArrayEntity{T, S <: AbstractArray{<:GeometryEntity{T}}} <: GeometryEntity{T}
    a::S
end

######## GeometryEntity API
# Include methods for ::Any to take arrays and iterators
"""
    bounds(geo::AbstractGeometry)
    bounds(geo0::AbstractGeometry, geo1::AbstractGeometry, geo::AbstractGeometry...)
    bounds(geos)

Return the minimum bounding `Rectangle` for `geo` or a collection/iterator `geos`.

If `geo` is empty or has no extent, a rectangle with zero width and height is returned.

For a collection or a structure that may contain multiple entities and references to other structures,
geometries with bounds having zero width and height are excluded from the calculation.
"""
function bounds(geo::AbstractGeometry)
    return Rectangle(lowerleft(geo), upperright(geo))
end

function bounds(geos)
    T = coordinatetype(geos)
    rects = filter(isproper, map(bounds, geos))
    isempty(rects) && return Rectangle(zero(Point{T}), zero(Point{T}))
    ll = lowerleft(rects)
    ur = upperright(rects)
    return Rectangle(ll, ur)
end

bounds(geo0::AbstractGeometry, geo1::AbstractGeometry, geo::AbstractGeometry...) =
    bounds([geo0, geo1, geo...])

"""
    center(geo::AbstractGeometry)
    center(geos)

Return the center of the bounding rectangle [`bounds(geo)`](@ref) or `bounds(geos)`.
Note that this point doesn't have to be in `ent`.

Will not throw an `InexactError` even if `geo` has integer coordinates, but instead return
floating point coordinates.

See also: [`lowerleft`](@ref), [`upperright`](@ref).
"""
center(geo) = (lowerleft(geo) + upperright(geo)) / 2

"""
    footprint(geo::AbstractGeometry)
    footprint(geos)

Return the footprint of `geo`.

By default, this falls back to [`bounds(geo)`](@ref), but it may be any single `GeometryEntity`
fully containing `geo`.

The footprint of a collection or iterator `geos` is `bounds(geos)`.
"""
footprint(geo) = bounds(geo)

"""
    offset(ent::GeometryEntity,
        delta;
        j::Clipper.JoinType=Clipper.JoinTypeMiter,
        e::Clipper.EndType=Clipper.EndTypeClosedPolygon)
    offset(ents,
        delta;
        j::Clipper.JoinType=Clipper.JoinTypeMiter,
        e::Clipper.EndType=Clipper.EndTypeClosedPolygon)

Return a `Vector` containing the result of offsetting boundaries outwards by `delta`.

Entities will be resolved into `Polygon`s using [`to_polygons`](@ref) before
offsetting using Clipper with options `j` and `e`.

Offsetting is specifically a polygon operation, as performed by Clipper. An alternative
method [`halo`](@ref) may be defined that produces an equivalent non-polygon `GeometryEntity`.
"""
function offset(
    ent,
    delta::Coordinate;
    j::Clipper.JoinType=Clipper.JoinTypeMiter,
    e::Clipper.EndType=Clipper.EndTypeClosedPolygon
)
    return offset(to_polygons(ent), delta, j=j, e=e)
end

"""
    halo(ent::GeometryEntity{T}, outer_delta, inner_delta=nothing)

Return the "halo" of `ent` using an offset of `outer_delta`.

By default, the halo is a vector containing [`offset(footprint(ent), outer_delta)`](@ref),
but it may contain any number of `GeometryEntity`s that together fully cover `ent` with
a margin of `outer_delta`. It is not guaranteed to cover [`footprint(ent)`](@ref).

If `inner_delta` is provided, then the offset at `inner_delta` is subtracted from the
result.

A `GeometryEntity` should implement a specialized `halo` if there is an efficient
non-`Polygon` representation of the halo. If it does not, then by default `offset` will be
used, which first resolves the entity into `Polygon`s using `to_polygons`.
"""
function halo(ent::GeometryEntity, outer_delta, inner_delta=nothing)
    isnothing(inner_delta) && return offset(to_polygons(footprint(ent)), outer_delta)
    return difference2d(
        offset(to_polygons(footprint(ent)), outer_delta),
        offset(to_polygons(footprint(ent)), inner_delta)
    )
end

halo(ents, outer_delta, inner_delta=nothing; kwargs...) =
    reduce(vcat, halo.(ents, outer_delta, inner_delta; kwargs...))

"""
    to_polygons(ent::GeometryEntity; kwargs...)

Return a single polygon, an iterator, or `Vector` of `Polygon`s equivalent to `ent`.

If `ent` is a `StyledEntity`, all styles will be applied before conversion to polygons.
"""
function to_polygons end

######## Coordinate transformation
### Simple transformations
"""
    magnify(geom, mag)

Returns a copy of `geom` magnified by a factor of `mag`.

The origin is the center of magnification.
"""
magnify(geom, mag) = transform(geom, mag=mag)

"""
    rotate(ent, rot)

Return a copy of `geom` rotated counterclockwise by `rot` around the origin.

Units are accepted (no units => radians).
"""
rotate(geom, rot) = transform(geom, rot=rot)

"""
    rotate90(geom, n)

Return a copy of `geom` rotated counterclockwise by `n` 90° turns.
"""
rotate90(geom, n) = rotate(geom, n * 90°)

"""
    reflect_across_xaxis(geom)

Return a copy of `geom` reflected across the x-axis.
"""
reflect_across_xaxis(geom) = transform(geom, xrefl=true)

"""
    translate(geom, displacement)

Return a copy of `geom` translated by `displacement`.
"""
translate(geom, displacement) = transform(geom, origin=displacement)
translate(geom, ::Nothing) = copy(geom)

"""
    reflect_across_line(geom, dir; through_pt=nothing)
    reflect_across_line(geom, p0, p1)

Return a copy of `geom` reflected across a line.

The line is specified through two points `p0` and `p1` that it passes through, or
by a direction `dir` (vector or angle made with the x-axis) and a point `through_pt` that it
passes through.
"""
reflect_across_line(geom, dir; through_pt=nothing) =
    Reflection(dir; through_pt=through_pt)(geom)
reflect_across_line(geom, p0, p1) = Reflection(p0, p1)(geom)

"""
    lowerleft(ent::AbstractGeometry)
    lowerleft(ents)

Return the lower-left-most corner of a rectangle bounding `ent` or `ents`.
Note that this point doesn't have to be in `ent`.

For iterable `ents`, entities with bounding rectanges of zero width and height
will be excluded.
"""
lowerleft(ent::GeometryEntity) = lowerleft(to_polygons(ent))
function lowerleft(ents)
    T = coordinatetype(ents)
    rects = filter(isproper, map(bounds, ents))
    isempty(rects) && return zero(Point{T})
    lls = map(lowerleft, rects)
    xmin = minimum(map(getx, lls))
    ymin = minimum(map(gety, lls))
    return Point(xmin, ymin)
end

"""
    upperright(ent::AbstractGeometry)
    upperright(ents)

Return the upper-right-most corner of a rectangle bounding `ent` or `ents`.
Note that this point doesn't have to be in `ent`.

For iterable `ents`, entities with bounding rectanges of zero width and height
will be excluded.
"""
upperright(ent::GeometryEntity) = upperright(to_polygons(ent))
function upperright(ents)
    T = coordinatetype(ents)
    rects = filter(isproper, map(bounds, ents))
    isempty(rects) && return zero(Point{T})
    urs = map(upperright, rects)
    xmax = maximum(map(getx, urs))
    ymax = maximum(map(gety, urs))
    return Point(xmax, ymax)
end

"""
    centered(ent::AbstractGeometry; on_pt=zero(Point{T}))

Centers a copy of `ent` on `on_pt`, with promoted coordinates if necessary.
This function will not throw an `InexactError()`, even if `ent` had integer
coordinates.
"""
centered(ent::AbstractGeometry{T}; on_pt=zero(Point{T})) where {T} =
    Translation(on_pt - center(ent))(ent)

"""
    +(ent::AbstractGeometry, p::Point)
    +(p::Point, ent::AbstractGeometry)

Translate an entity by `p`.
"""
Base.:+(ent::AbstractGeometry, p::Point) = translate(ent, p)
Base.:+(ent::AbstractGeometry, p::StaticArrays.Scalar{<:Point}) = translate(ent, p[1])
Base.:+(p::Point, ent::AbstractGeometry) = translate(ent, p)
Base.:+(p::StaticArrays.Scalar{<:Point}, ent::AbstractGeometry) = translate(ent, p[1])

"""
    -(ent::AbstractGeometry, p::Point)

Translate an entity by `-p`.
"""
Base.:-(ent::AbstractGeometry, p::Point) = translate(ent, -p)
Base.:-(ent::AbstractGeometry, p::StaticArrays.Scalar{<:Point}) = translate(ent, -p[1])

"""
    *(ent::AbstractGeometry, a::Real)
    *(a::Real, ent::AbstractGeometry)

Magnify an entity by `a`.
"""
Base.:*(ent::AbstractGeometry, a::Real) = magnify(ent, a)
Base.:*(a::Real, ent::AbstractGeometry) = magnify(ent, a)

"""
    /(ent::AbstractGeometry, a::Real)

Magnify an entity by `inv(a)`.
"""
Base.:/(ent::AbstractGeometry, a::Real) = magnify(ent, inv(a))

###### Angle-preserving transform
"""
    transform(geom::AbstractGeometry, f::Transformation)
    transform(
        geom::AbstractGeometry{S};
        origin=zero(Point{S}),
        rot=0°,
        xrefl=false,
        mag=1
    )

Return a new `AbstractGeometry` obtained by applying `f` to `geom`.

For generic `geom` and transformation, attempts to decompose `f` into a scaled isometry:
`translate ∘ magnify ∘ rotate ∘ reflect_across_xaxis`. In that case, if `f` does not preserve
angles, a `DomainError` will be thrown.

A concrete subtype of `AbstractGeometry` must implement

```
transform(ent::MyEntity, f::Transformation)
```

It is not, however, required that an arbitrary `Transformation` be valid on `MyEntity`. For
example, one might write

```julia
transform(ent::MyEntity, f::Transformation) = transform(ent, ScaledIsometry(f))
function transform(ent::MyEntity, f::ScaledIsometry)
    # ... create and return transformed entity
end
```

which will throw a `DomainError` if `!preserves_angles(f)` (`f` is not a scaled isometry).
"""
function transform(geom::GeometryEntity, f::Transformation)
    return error("Failed to apply $f: Transformation not implemented for $geom")
end

function transform(
    geom::AbstractGeometry{S};
    origin=zero(Point{S}),
    rot=0°,
    xrefl=false,
    mag=1
) where {S}
    return transform(
        geom,
        ScaledIsometry(isnothing(origin) ? zero(Point{S}) : origin, rot, xrefl, mag)
    )
end

(f::Translation{V})(ent::AbstractGeometry) where {V} = transform(ent, f)
(f::LinearMap{M})(ent::AbstractGeometry) where {M} = transform(ent, f)
(f::AffineMap{M, V})(ent::AbstractGeometry) where {M, V} = transform(ent, f)
(f::ScaledIsometry{T})(ent::AbstractGeometry) where {T} = transform(ent, f)
# IdentityTransformation is always valid, never copies
(f::IdentityTransformation)(ent::AbstractGeometry) = ent

#### Interface methods for ArrayEntity
# Iteration
Base.iterate(aent::ArrayEntity) = iterate(aent.a)
Base.iterate(aent::ArrayEntity, state) = iterate(aent.a, state)
Base.IteratorSize(::Type{ArrayEntity{T, S}}) where {T, S} = Base.IteratorSize(S)
Base.IteratorEltype(::Type{ArrayEntity{T, S}}) where {T, S} = Base.IteratorEltype(S)
Base.eltype(::Type{ArrayEntity{T, S}}) where {T, S} = Base.eltype{S}
Base.length(aent::ArrayEntity) = length(aent.a)
Base.size(aent::ArrayEntity) = size(aent.a)
Base.size(aent::ArrayEntity, dim) = size(aent.a, dim)
Base.isdone(aent::ArrayEntity) = Base.isdone(aent.a)
Base.isdone(aent::ArrayEntity, state) = Base.isdone(aent.a, state)
# Indexing
Base.getindex(aent::ArrayEntity, i) = getindex(aent.a, i)
Base.setindex!(aent::ArrayEntity, v, i) = setindex!(aent.a, v, i)
Base.firstindex(aent::ArrayEntity) = firstindex(aent.a)
Base.lastindex(aent::ArrayEntity) = lastindex(aent.a)
# GeometryEntity
to_polygons(aent::ArrayEntity) = reduce(vcat, to_polygons.(aent.a))
transform(aent::ArrayEntity, f::Transformation) = ArrayEntity(f.(aent.a))
lowerleft(aent::ArrayEntity) = lowerleft(aent.a)
upperright(aent::ArrayEntity) = upperright(aent.a)
halo(aent::ArrayEntity, outer_delta, inner_delta=nothing) =
    ArrayEntity(halo(aent.a, outer_delta, inner_delta))
