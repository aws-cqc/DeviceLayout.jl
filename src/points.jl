module Points

import DeviceLayout: PointTypes, InverseLength, Coordinate
import StaticArrays
import Clipper: IntPoint
import Base: convert, *, summary, show, isapprox
import ForwardDiff: ForwardDiff, extract_derivative
import Unitful:
    Unitful, Length, DimensionlessQuantity, Quantity, NoUnits, Units, ustrip, unit

export Point, round
export getx, gety, lowerleft, upperright

"""
    struct Point{T<:PointTypes} <: StaticArrays.FieldVector{2,T}
        x::T
        y::T
    end

2D Cartesian coordinate in the plane.
"""
struct Point{T <: PointTypes} <: StaticArrays.FieldVector{2, T}
    x::T
    y::T
    Point{T}(x, y) where {T} = new{T}(x, y)
end

StaticArrays.similar_type(
    ::Type{P},
    ::Type{T},
    ::StaticArrays.Size{(2,)}
) where {P <: Point, T} = Point{T}

Point(x::Number, y::Number) = error("Cannot use `Point` with this combination of types.")
Point(x::Length, y::Length) = Point{promote_type(typeof(x), typeof(y))}(x, y)
Point(x::InverseLength, y::InverseLength) = Point{promote_type(typeof(x), typeof(y))}(x, y)
Point(x::Real, y::Real) = Point{promote_type(typeof(x), typeof(y))}(x, y)
Point(x::DimensionlessQuantity, y::DimensionlessQuantity) = Point(NoUnits(x), NoUnits(y))

convert(::Type{Point{T}}, x::IntPoint) where {T <: Real} = Point{T}(x.X, x.Y)

const Dimless = Union{Real, DimensionlessQuantity{<:Real}}
Base.promote_rule(::Type{Point{S}}, ::Type{Point{T}}) where {S <: Dimless, T <: Dimless} =
    Point{promote_type(S, T)}
Base.promote_rule(::Type{Point{S}}, ::Type{Point{T}}) where {S <: Length, T <: Length} =
    Point{promote_type(S, T)}
Base.promote_rule(
    ::Type{Point{S}},
    ::Type{Point{T}}
) where {S <: InverseLength, T <: InverseLength} = Point{promote_type(S, T)}
show(io::IO, p::Point) = print(io, "(", string(getx(p)), ",", string(gety(p)), ")")

"""
    getx(p::Point)

Get the x-coordinate of a point. You can also use `p.x` or `p[1]`.
"""
@inline getx(p::Point) = p.x

"""
    gety(p::Point)

Get the y-coordinate of a point. You can also use `p.y` or `p[2]`.
"""
@inline gety(p::Point) = p.y

for f in (:+, :-)
    @eval Base.Broadcast.broadcasted(
        ::typeof($f),
        a::AbstractArray,
        p::Point{T}
    ) where {T} = Base.Broadcast.broadcasted($f, a, StaticArrays.Scalar{typeof(p)}((p,)))
    @eval Base.Broadcast.broadcasted(
        ::typeof($f),
        p::Point{T},
        a::AbstractArray
    ) where {T} = Base.Broadcast.broadcasted($f, StaticArrays.Scalar{typeof(p)}((p,)), a)
    @eval Base.Broadcast.broadcasted(
        ::typeof($f),
        p1::Point{T},
        p2::Point{S}
    ) where {T, S} = ($f)(p1, p2)
end

"""
    lowerleft{T}(A::AbstractArray{Point{T}})

Return the lower-left [`Point`](@ref) of the smallest bounding rectangle
(with sides parallel to the x- and y-axes) that contains all points in `A`.

Example:

```jldoctest
julia> lowerleft([Point(2, 0), Point(1, 1), Point(0, 2), Point(-1, 3)])
2-element Point{Int64} with indices SOneTo(2):
 -1
  0
```
"""
function lowerleft(A::AbstractArray{Point{T}}) where {T}
    B = reshape(reinterpret(T, vec(A)), (2 * length(A),))
    @inbounds Bx = view(B, 1:2:length(B))
    @inbounds By = view(B, 2:2:length(B))
    return Point(minimum(Bx), minimum(By))
end

"""
    upperright{T}(A::AbstractArray{Point{T}})

Return the upper-right [`Point`](@ref) of the smallest bounding rectangle
(with sides parallel to the x- and y-axes) that contains all points in `A`.

Example:

```jldoctest
julia> upperright([Point(2, 0), Point(1, 1), Point(0, 2), Point(-1, 3)])
2-element Point{Int64} with indices SOneTo(2):
 2
 3
```
"""
function upperright(A::AbstractArray{Point{T}}) where {T}
    B = reshape(reinterpret(T, vec(A)), (2 * length(A),))
    @inbounds Bx = view(B, 1:2:length(B))
    @inbounds By = view(B, 2:2:length(B))
    return Point(maximum(Bx), maximum(By))
end

function isapprox(
    x::AbstractArray{S},
    y::AbstractArray{T};
    kwargs...
) where {S <: Point, T <: Point}
    return all(ab -> isapprox(ab[1], ab[2]; kwargs...), zip(x, y))
end

ForwardDiff.extract_derivative(::Type{T}, x::Point{S}) where {T, S} = Point(
    unit(S) * ForwardDiff.partials(T, ustrip(getx(x)), 1),
    unit(S) * ForwardDiff.partials(T, ustrip(gety(x)), 1)
)

"""
    ustrip(p::Point{T})
    ustrip(u::Units, p::Point{T})

Strip units from `p`.

As with `Unitful` quantities in general, it is safest to use `ustrip` with the `u::Units`
argument, even if it is `Unitful.NoUnits`, unless you really only want the underlying number
as it is stored. For example

```julia
ustrip(1nm / mm) == 1
Point(1nm, 1nm) / μm === Point{typeof(1nm / μm)}(1 // 1000, 1 // 1000)
# But the `Point` constructor simplifies `DimensionlessQuantity` automatically:
Point(1nm / μm, 1nm / μm) === Point(1 // 1000, 1 // 1000)
# so:
ustrip(Point(1nm, 1nm) / μm) == Point(1, 1)
ustrip(Point(1nm / μm, 1nm / μm)) == Point(1 // 1000, 1 // 1000)
```
"""
ustrip(p::Point{T}) where {T} = Point(ustrip(getx(p)), ustrip(gety(p)))
ustrip(u::Units, p::Point{T}) where {T} = Point(ustrip(u, getx(p)), ustrip(u, gety(p)))
ustrip(v::AbstractArray{Point{T}}) where {T <: Quantity} =
    reinterpret(Point{Unitful.numtype(T)}, v)
ustrip(v::AbstractArray{Point{T}}) where {T} = v
ustrip(u::Units, v::AbstractArray{Point{T}}) where {T} = ustrip.(u, v)

"""
    round(precision::Type{T}, p::Point, r::RoundingMode=RoundNearest) where {T <: Number}

Round `p` to the closest point in units of `precision`.

Example: `round(typeof(1.0μm), Point(1.2μm, 2.8μm))` is `Point(1.0μm, 3.0μm)`.
"""
function Base.round(
    precision::Type{T},
    p::Point,
    r::RoundingMode=RoundNearest
) where {T <: Number}
    return Point(round(precision, p.x, r), round(precision, p.y, r))
end

end
