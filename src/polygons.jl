module Polygons

using LinearAlgebra

import Base: +, -, *, /, ==, isapprox
import Base: convert, getindex
import Base: copy, promote_rule

using ForwardDiff
import CoordinateTransformations: AffineMap, LinearMap, Translation, Transformation
import Clipper
import Clipper: children, contour
import StaticArrays

import DeviceLayout
import DeviceLayout:
    AbstractGeometry,
    AbstractPolygon,
    Coordinate,
    GeometryEntity,
    GeometryEntityStyle,
    GeometryReference,
    GeometryStructure,
    Reflection,
    Rotation,
    ScaledIsometry,
    Transformation,
    Translation,
    Meta,
    GDSMeta
import DeviceLayout:
    bounds,
    center,
    flat_elements,
    halo,
    isapprox_cardinal,
    lowerleft,
    mag,
    magnify,
    offset,
    orientation,
    origin,
    preserves_angles,
    reflect_across_xaxis,
    reflect_across_line,
    rotate,
    rotated_direction,
    rotate90,
    rotation,
    to_polygons,
    transform,
    translate,
    upperright,
    xrefl
import Unitful
import Unitful: Quantity, Length, dimension, unit, ustrip, uconvert, °
using ..Points
using ..Rectangles
import ..libcclipper

import IntervalTrees
import IntervalTrees: IntervalTree, IntervalValue
import IntervalSets.(..)
import IntervalSets.endpoints

export Polygon, ClippedPolygon, Ellipse, Circle
export circle,
    circle_polygon,
    clip,
    cliptree,
    circularapprox,
    circularequality,
    difference2d,
    gridpoints_in_polygon,
    intersect2d,
    offset,
    perimeter,
    points,
    radius,
    rounded_corner,
    sweep_poly,
    unfold,
    union2d,
    xor2d

const USCALE = 1.0 * Unitful.fm
const SCALE  = 10.0^9

clipper() = (DeviceLayout._clip[])::Clipper.Clip
coffset() = (DeviceLayout._coffset[])::Clipper.ClipperOffset

@inline unsafe_round(x::Number) = round(ustrip(x)) * unit(x)
@inline unsafe_round(x::Point) = unsafe_round.(x)

"""
    struct Polygon{T} <: AbstractPolygon{T}
        p::Vector{Point{T}}
        Polygon(x) = new(x)
        Polygon(x::AbstractPolygon) = convert(Polygon{T}, x)
    end

Polygon defined by list of coordinates. The first point should not be repeated
at the end (although this is true for the GDS format).
"""
struct Polygon{T} <: AbstractPolygon{T}
    p::Vector{Point{T}}
    Polygon{T}(x) where {T} = new{T}(x)
    Polygon{T}(x::AbstractPolygon) where {T} = convert(Polygon{T}, x)
end

"""
    Polygon(p0::Point, p1::Point, p2::Point, p3::Point...)

Convenience constructor for a `Polygon{T}` object.
"""
Polygon(p0::Point, p1::Point, p2::Point, p3::Point...) = Polygon([p0, p1, p2, p3...])

"""
    Polygon{T}(parr::AbstractVector{Point{T}})

Convenience constructor for a `Polygon{T}` object.
"""
Polygon(parr::AbstractVector{Point{T}}) where {T} = Polygon{T}(parr)

Polygon(parr::AbstractVector{Point}) =
    error("polygon creation failed. Perhaps you mixed units and unitless numbers?")

==(p1::Polygon, p2::Polygon) = (p1.p == p2.p)
isapprox(p1::Polygon, p2::Polygon; kwargs...) = isapprox(p1.p, p2.p; kwargs...)
copy(p::Polygon) = Polygon(copy(p.p))

"""
    struct Ellipse{T} <: GeometryEntity{T}
        center::Point{T}
        radii::NTuple{2, T}
        angle::typeof(1.0°)
        Ellipse{T}(c, r, a) where {T} = new{T}(c, r[1] < r[2] ? (r[2], r[1]) : r, a)
    end
    Ellipse(center::Point{T}, radii, angle) where {T} = Ellipse{T}(center, radii, angle)
    Ellipse(center::Point{T}; r::T) where {T} = Ellipse{T}(center, (r, r), 0.0°)

Represent an ellipse with a centroid, radii and major axis angle. The major axis radius is
stored first within radii, and the axis angle is defined from the x-axis.
"""
struct Ellipse{T} <: GeometryEntity{T}
    center::Point{T}
    radii::NTuple{2, T}
    angle::typeof(1.0°)
    Ellipse{T}(c, r, a) where {T} = new{T}(c, r[1] < r[2] ? (r[2], r[1]) : r, a)
end
Ellipse(center::Point{T}, radii, angle) where {T} = Ellipse{T}(center, radii, angle)
Ellipse(center::Point{T}; r::T) where {T} = Ellipse{T}(center, (r, r), 0.0°)
copy(e::Ellipse) = Ellipse(e.center, e.radii, e.angle)

"""
    Circle(center::Point{T}, r::T)

Construct an Ellipse with major and minor radii equal to `r` at `center`.
"""
Circle(center::Point{T}, r::T) where {T} = Ellipse(center, (r, r), 0.0°)
Circle(r::T) where {T <: Coordinate} = Circle(zero(Point{T}), r)

center(e::Ellipse) = e.center
r1(e::Ellipse) = e.radii[1]
r2(e::Ellipse) = e.radii[2]
angle(e::Ellipse) = e.angle

convert(::Type{GeometryEntity{T}}, e::Ellipse) where {T} = convert(Ellipse{T}, e)
convert(::Type{GeometryEntity{T}}, e::Ellipse{T}) where {T} = e
function convert(::Type{Ellipse{T}}, e::Ellipse{S}) where {T, S}
    return Ellipse{T}(convert(Point{T}, e.center), convert(NTuple{2, T}, e.radii), e.angle)
end

"""
    ellipse_curvature(e::Ellipse, θ)

Compute the curvature of an ellipse at parameter θ.
For an ellipse with semi-major axis `a` and semi-minor axis `b`,
the curvature is κ(φ) = ab / (a²sin²φ + b²cos²φ)^(3/2)
where φ is the angle measured from the major axis of the ellipse.

Since θ in the ellipse parameterization is measured from the global x-axis,
we need φ = θ - e.angle to get the angle relative to the ellipse's major axis.
"""
function ellipse_curvature(e::Ellipse, θ)
    a, b = e.radii[1], e.radii[2]  # a is major axis, b is minor axis
    φ = θ - e.angle  # Convert from global angle θ to ellipse-relative angle φ
    return (a * b) / (a^2 * sin(φ)^2 + b^2 * cos(φ)^2)^1.5
end

# Distance from centroid at θ from major axis
function _ellipse_r(φ, a, b)
    return (a * b) / sqrt((b * cos(φ))^2 + (a * sin(φ))^2)
end

# Point at θ from x axis with major axis at θ1
function _ellipse_p(θ, θ1, a, b)
    return _ellipse_r(θ - θ1, a, b) * Point(cos(θ), sin(θ))
end

function to_polygons(
    e::Ellipse;
    atol=DeviceLayout.onenanometer(eltype(e.center)),
    Δθ=nothing,
    kwargs...
)
    if !isnothing(Δθ) # Use Δθ-based discretization
        θs = ((0.0°):Δθ:(360° - Δθ))
    else # Use tolerance-based discretization
        # t_scale is used to approximately convert "t" (θ) to arclength, use the larger radius to be safe
        θs = (DeviceLayout.discretization_grid(
            Base.Fix1(ellipse_curvature, e),
            atol,
            (0.0, 2π);
            t_scale=e.radii[1]
        )[1:(end - 1)])
    end
    return Polygon([e.center + _ellipse_p(θ, e.angle, e.radii[1], e.radii[2]) for θ in θs])
end

DeviceLayout.magnify(e::Ellipse, mag) = Ellipse(mag .* e.center, mag .* e.radii, e.angle)
function DeviceLayout.rotate(e::Ellipse, rot)
    Rot = Rotation(rot)
    return Ellipse(Rot(e.center), e.radii, rotated_direction(e.angle, Rot))
end
function DeviceLayout.reflect_across_xaxis(e::Ellipse)
    Refl = Reflection(0)
    return Ellipse(Refl(e.center), e.radii, rotated_direction(e.angle, Refl))
end
DeviceLayout.translate(e::Ellipse{T}, tra::Point{T}) where {T} =
    Ellipse(Translation(tra)(e.center), e.radii, e.angle)

function DeviceLayout.reflect_across_line(e::Ellipse, dir; through_pt=nothing)
    Refl = Reflection(dir; through_pt=through_pt)
    return Ellipse(Refl(e.center), e.radii, rotated_direction(e.angle, Refl))
end
function DeviceLayout.reflect_across_line(e::Ellipse, p0, p1)
    Refl = Reflection(p0, p1)
    return Ellipse(Refl(e.center), e.radii, rotated_direction(e.angle, Refl))
end

function transform(e::Ellipse{T}, f::ScaledIsometry) where {T}
    # `translate ∘ magnify ∘ rotate ∘ reflect_across_xaxis`
    Rot = Rotation(rotation(f))
    Tra = Translation(isnothing(origin(f)) ? zero(Point{T}) : origin(f))
    if xrefl(f)
        Refl = Reflection(0)
        return Ellipse(
            Tra(mag(f) .* (Rot ∘ Refl)(e.center)),
            mag(f) .* e.radii,
            rotated_direction(e.angle, Rot ∘ Refl)
        )
    else
        return Ellipse(
            Tra(mag(f) .* Rot(e.center)),
            mag(f) .* e.radii,
            rotated_direction(e.angle, Rot)
        )
    end
end

function transform(e::Ellipse, f::Transformation)
    preserves_angles(f) && return transform(e, ScaledIsometry(f))

    # Assemble the origin, major and minor end points, apply transforms to them.
    a, b = e.radii
    p1 = e.center + Rotation(e.angle)(Point(a, zero(a)))
    p2 = e.center + Rotation(e.angle + 90°)(Point(b, zero(b)))
    center, p1, p2 = f.([e.center, p1, p2])

    # center -> p1 and center -> p2 are no longer orthogonal (angles aren't preserved).
    new_major = p1 - center
    new_minor = p2 - center
    M = ustrip([new_major.x new_minor.x; new_major.y new_minor.y])
    cov = M * M'
    vals, vecs = eigen(cov) # real valued

    @assert vals[2] >= vals[1]
    θ = ((atand(vecs[2, 2], vecs[1, 2]) + 180) % 180)°
    return Ellipse(center, (sqrt(vals[2]), sqrt(vals[1])) .* oneunit(a), θ)
end

"""
    struct ClippedPolygon{T} <: AbstractPolygon{T}
        tree::Clipper.PolyNode{Point{T}}
    end

Collection of polygons defined by a call to Clipper.
"""
struct ClippedPolygon{T} <: AbstractPolygon{T}
    tree::Clipper.PolyNode{Point{T}}
end

"""
    circularequality(x, y)

Compare two arrays for equality, modulo circularshifts.
circularequality([1, 2, 3], [2, 3, 1]) == true
circularequality([1, 2, 3], [3, 2, 1]) == false
"""
function circularequality(x, y)
    if length(x) != length(y)
        return false
    end
    return circshift(x, 1 - findmin(x)[2]) == circshift(y, 1 - findmin(y)[2])
end

"""
    circularapprox(x, y)

Compare two arrays approximately, modulo circularshifts.
circularapprox([1, 2, 3], [2+1e-12, 3, 1]) == true
circularapprox([1, 2, 3], [3, 2, 1]) == false
"""
function circularapprox(x, y; kwargs...)
    if length(x) != length(y)
        return false
    end
    return isapprox(
        circshift(x, 1 - findmin(x)[2]),
        circshift(y, 1 - findmin(y)[2]);
        kwargs...
    )
end

ClippedPolygon{T}(x::Clipper.PolyNode{Point}) where {T} =
    ClippedPolygon{T}(recast(Clipper.PolyNode{Point{T}}, x))
function ==(p1::ClippedPolygon, p2::ClippedPolygon)
    function children_equal(l, r)
        # recursively check contours of all children in the tree
        for (x, y) in zip(Clipper.children(l), Clipper.children(r))
            (!circularequality(x.contour, y.contour) || !children_equal(x, y)) &&
                return false
        end
        return true
    end
    return children_equal(p1.tree, p2.tree)
end

function isapprox(p1::ClippedPolygon, p2::ClippedPolygon; kwargs...)
    function children_approx(l, r)
        # recursively check contours of all children in the tree
        for (x, y) in zip(Clipper.children(l), Clipper.children(r))
            (!circularapprox(x.contour, y.contour; kwargs...) || !children_approx(x, y)) &&
                return false
        end
        return true
    end
    return children_approx(p1.tree, p2.tree)
end

"""
    Base.getindex(p::ClippedPolygon, indices::Int...)

Return the `Clipper.PolyNode` corresponding to the indices location within `p.tree`.
"""
function Base.getindex(p::ClippedPolygon, indices::Int...)
    node = p.tree
    for i ∈ filter(x -> x != 0, indices)
        node = node.children[i]
    end
    return node
end

copy(p::ClippedPolygon) = ClippedPolygon(deepcopy(p.tree))

Base.broadcastable(x::Polygon) = Ref(x)
Base.broadcastable(x::ClippedPolygon) = Ref(x)

to_polygons(p::Polygon; kwargs...) = p
to_polygons(p::Rectangle; kwargs...) = convert(Polygon, p)
function to_polygons(p::ClippedPolygon{Int})
    return interiorcuts(p.tree, Polygon{Int}[])
end
function to_polygons(p::ClippedPolygon{T}; kwargs...) where {T}
    pc = clipperize(p)
    S = typeof(pc).parameters[1]
    pci = recast(Clipper.PolyNode{Point{Int64}}, pc.tree)
    o = interiorcuts(pci, Polygon{S}[])
    return declipperize.(o, T)
end
# Broadcast equivalent
to_polygons(p::Vector{<:ClippedPolygon}; kwargs...) = [to_polygons.(p; kwargs...)...]

"""
    points(x::Polygon)

Return the array of `Point` objects defining the polygon.
"""
points(x::Polygon) = x.p

"""
    points{T}(x::Rectangle{T})

Return the array of `Point` objects defining the rectangle.
"""
points(x::Rectangle{T}) where {T} = points(convert(Polygon{T}, x))

"""
    points(x::ClippedPolygon)

Return the array of `Point` objects that define the keyhole polygon.
"""
points(x::ClippedPolygon) = vcat(points.(to_polygons(x))...)

"""
    points(x::Clipper.PolyNode)

Return the array of `Point` objects that make up the contour of the `PolyNode`
"""
points(x::Clipper.PolyNode) = x.contour

function DeviceLayout.transform(r::Rectangle, f::Transformation)
    preserves_angles(f) && return transform(r, ScaledIsometry(f))
    return f(convert(Polygon, r))
end

function DeviceLayout.transform(r::Rectangle, f::ScaledIsometry)
    rotd = uconvert(°, rotation(f))
    if isapprox_cardinal(rotd)
        return translate(
            magnify(
                rotate90(
                    xrefl(f) ? reflect_across_xaxis(r) : r,
                    Int(round(uconvert(Unitful.NoUnits, rotd / 90°)))
                ),
                mag(f)
            ),
            origin(f)
        )
    end
    return f(convert(Polygon, r)) # transformations may turn a rectangle into a polygon
end

DeviceLayout.transform(p::Polygon, f::Transformation) =
    xrefl(f) ? Polygon(reverse(f.(points(p)))) : Polygon(f.(points(p)))
DeviceLayout.translate(p::Polygon, dp::Point) = Polygon(points(p) .+ dp)
DeviceLayout.magnify(p::Polygon, mag) = Polygon(mag * points(p))

function DeviceLayout.transform(c::ClippedPolygon, f::Transformation)
    T = typeof(f.(c.tree.contour)).parameters[1]
    t = convert(Clipper.PolyNode{T}, c.tree)
    if t === c.tree
        # convert can return the original if the types match.
        # To avoid modifying c, perform a deep copy before mutation.
        t = deepcopy(t)
    end
    function apply!(x)
        x.contour .= f.(xrefl(f) ? reverse(x.contour) : x.contour)
        for y in x.children
            apply!(y)
        end
        return nothing
    end
    apply!(t)
    return ClippedPolygon(t)
end

DeviceLayout.lowerleft(x::Polygon) = lowerleft(x.p)
DeviceLayout.upperright(x::Polygon) = upperright(x.p)
DeviceLayout.footprint(x::Polygon) = x

# ClippedPolygon footprint = outer contour if there's only one
function DeviceLayout.footprint(x::ClippedPolygon{T}) where {T}
    isempty(x.tree.children) && return Rectangle(zero(T), zero(T))
    if length(x.tree.children) == 1
        return Polygon(x.tree.children[1].contour)
    else
        return bounds(to_polygons(x))
    end
end

function convert(::Type{Polygon{T}}, s::Rectangle) where {T}
    ll = convert(Point{T}, s.ll)
    ur = convert(Point{T}, s.ur)
    lr = Point(T(getx(ur)), T(gety(ll)))
    ul = Point(T(getx(ll)), T(gety(ur)))
    return Polygon{T}(Point{T}[ll, lr, ur, ul])
end
convert(::Type{Polygon}, s::Rectangle{T}) where {T} = convert(Polygon{T}, s)
convert(::Type{AbstractPolygon{T}}, s::Rectangle) where {T} = convert(Rectangle{T}, s)
convert(::Type{Polygon{T}}, p::Polygon{T}) where {T} = p
function convert(::Type{Polygon{T}}, p::Polygon{S}) where {S, T}
    return Polygon{T}(convert(Array{Point{T}, 1}, p.p))
end
convert(::Type{AbstractPolygon{T}}, p::Polygon) where {T} = convert(Polygon{T}, p)
convert(::Type{GeometryEntity{T}}, p::Polygon) where {T} = convert(Polygon{T}, p)
convert(::Type{GeometryEntity{T}}, p::ClippedPolygon) where {T} =
    convert(ClippedPolygon{T}, p)
function convert(::Type{ClippedPolygon{T}}, p::ClippedPolygon{S}) where {T, S}
    return ClippedPolygon{T}(convert(Clipper.PolyNode{Point{T}}, p.tree))
end
convert(::Type{ClippedPolygon{T}}, p::ClippedPolygon{T}) where {T} = p

"""
    perimeter(poly::AbstractPolygon)

The (Euclidean) perimeter of an `AbstractPolygon`.
"""
function perimeter(p::AbstractPolygon)
    return sum(norm.(points(p) .- circshift(points(p), -1)))
end
"""
    perimeter(poly::ClippedPolygon)

The (Euclidean) perimeter of the outermost contour of a `ClippedPolygon`
"""
function perimeter(p::ClippedPolygon)
    return sum(norm.(points(p[1]) .- circshift(points(p[1]), -1)))
end

"""
    perimeter(poly::Ellipse)

Approximate (Euclidean) perimeter of an `Ellipse` using Ramanujan's approximation formula
https://arxiv.org/pdf/math/0506384.pdf
"""
function perimeter(e::Ellipse)
    a = maximum(e.radii)
    b = minimum(e.radii)
    return π * ((a + b) + 3 * (a - b)^2 / (10 * (a + b) + sqrt(a^2 + 14 * a * b + b^2)))
end

"""
    circle_polygon(r, Δθ=10°)

Return a circular `Polygon` centered about the origin with radius `r` and angular step `Δθ`.
"""
circle_polygon(r, Δθ=10°) =
    Polygon([Point(r * cos(a), r * sin(a)) for a in ((0°):Δθ:(360° - Δθ))])
function circle(r, α=10°)
    @warn """"
        `circle(r, α)` is deprecated. Use `Circle(r)` or `Circle(center, r)` to create an \
        exact circle that will be discretized at render time according to rendering keyword \
        `atol` (default 1nm) or `Δθ` (if provided). To construct the polygon directly, use \
        `circle_polygon(r, α)`.
    """
    return circle_polygon(r, α)
end

"""
    struct Rounded{T <: Coordinate} <: GeometryEntityStyle
        abs_r::T = zero(T)
        rel_r::Float64 = 0.0
        min_side_len::T = r
        min_angle::Float64 = 1e-3
        p0::Vector{Point{T}} = []
        inverse_selection::Bool = false
    end

Rounded polygon style defined by either radius absolute radius `abs_r` or relative radius
`rel_r`. Only one of `abs_r` or `rel_r` can be non-zero at once. Can't handle shapes
with interior cuts, or shapes with too sharp of angles relative to segment length. If
`rel_r` is non-zero the radius of curvature at each vertex is calculated with
`rel_r * min(l₁, l₂)` where `l₁` and `l₂` denote the length of the two attached line segments.

Example usage:

```julia
r = Rectangle(10μm, 10μm)
rsty = Rounded(1μm)
# Create a rounded rectangle StyledEntity with different options for syntax
rounded_rect = rsty(r)
rounded_rect = styled(r, rsty)
rounded_rect = Rounded(r, 1μm)
# Turn the result into a plain Polygon
rounded_rect_discretized_poly = to_polygons(rounded_rect)
```

## Keyword arguments

  - `min_side_len`: The minimum side length that will get rounded (e.g. for 90-degree angles,
    it makes sense to have `min_side_len = 2 * rounding_radius`). This currently uses exact
    comparison, so it may result in very short straight edges or failure to round a corner
    due to floating point imprecision.
  - `min_angle`: If adjacent sides are collinear within the tolerance set by `min_angle`,
    rounding will not be performed.
  - `p0`: set of target points used to select vertices to attempt to round when
    applied to a polygon. Selected vertices where `min_side_len` and
    `min_angle` are satisfied will be rounded. If empty, all vertices will be selected.
    Otherwise, for each point in `p0`, the nearest point in the styled polygon will be
    selected. Note that for a `ClippedPolygon`, the same `p0` will be used for every
    contour; for different rounding styles on different contours, use `StyleDict`.
  - `inverse_selection`: If true, the selection from `p0` is inverted;
    that is, all corners will be rounded except those selected by `p0`.
"""
Base.@kwdef struct Rounded{T <: Coordinate} <: GeometryEntityStyle
    abs_r::T = zero(T)
    rel_r::Float64 = 0.0
    min_side_len::T = abs_r
    min_angle::Float64 = 1e-3
    p0::Vector{Point{T}} = []
    inverse_selection::Bool = false
    function Rounded{T}(
        abs_r::Coordinate,
        rel_r,
        min_side_len,
        min_angle,
        p0,
        inverse_selection
    ) where {T}
        if !iszero(abs_r) && !iszero(rel_r)
            throw(ArgumentError("`abs_r` and `rel_r` cannot both be non-zero"))
        end
        return new{T}(abs_r, rel_r, min_side_len, min_angle, p0, inverse_selection)
    end
end
Rounded(r::Coordinate; kwargs...) = Rounded{float(typeof(r))}(; abs_r=r, kwargs...)
p0(r::Rounded) = r.p0

function RelativeRounded(r::Float64; kwargs...)
    # if missing, type won't matter
    T = haskey(kwargs, :p0) ? eltype(eltype(kwargs[:p0])) : typeof(1.0Unitful.μm)
    S =
        haskey(kwargs, :min_side_len) ? eltype(eltype(kwargs[:min_side_len])) :
        typeof(1.0Unitful.μm)
    return Rounded{promote_type(T, S)}(; rel_r=r, kwargs...)
end

radius(s::Rounded) = iszero(s.abs_r) ? s.rel_r : s.abs_r

function transform(sty::Rounded{T}, f::Transformation) where {T}
    return Rounded{T}(
        abs_r=mag(f) * sty.abs_r,
        rel_r=sty.rel_r,
        min_side_len=mag(f) * sty.min_side_len,
        min_angle=sty.min_angle,
        p0=f.(sty.p0),
        inverse_selection=sty.inverse_selection
    )
end

# Helper to compute corner_indices for a given AbstractPolygon
cornerindices(p, x) = cornerindices(points(p), x)
cornerindices(p::Point, x) = cornerindices([p], x)
cornerindices(p::Vector{<:Point}, p0::Point) = cornerindices(p, [p0])
function cornerindices(p::Vector{<:Point}, p0::Vector{<:Point})
    return map(p0) do px
        idx = findfirst(p_idx -> isapprox(px, p_idx), p)
        !isnothing(idx) && return idx
        return findmin(norm.(p .- px))[2]
    end
end

function cornerindices(p::Vector{<:Point}, r)
    corner_indices = isempty(p0(r)) ? eachindex(p) : cornerindices(p, p0(r))
    return r.inverse_selection ? setdiff(eachindex(p), corner_indices) : corner_indices
end

function to_polygons(
    ent::AbstractPolygon{S},
    sty::Rounded{T};
    atol=_round_atol(S, T),
    kwargs...
) where {S, T}
    return to_polygons(
        _round_poly(
            ent,
            radius(sty),
            min_side_len=sty.min_side_len,
            min_angle=sty.min_angle,
            corner_indices=cornerindices(ent, sty),
            atol=atol
        )
    )
end

function _round_atol(T, S)
    V = promote_type(T, S)
    r = oneunit(V)
    return r isa Unitful.Length ? 1.0Unitful.nm : 0.001
end

"""
    _round_poly(
        pol::AbstractPolygon{T},
        radius::S;
        atol           = _round_atol(T, (S <: Length) ? S : T),
        corner_indices = eachindex(points(pol)),
        min_angle      = 1e-3,
        relative::Bool = (T <: Length) && (S <: Real),
        min_side_len   = relative ? zero(T) : radius
    ) where {T, S <: Coordinate}

Return a `Polygon` created by rounding the corners of a polygon `p` with rounding `radius`.
Points corresponding to those not included in `corner_indices` will be present in the
returned polygon by construction. Used internally to produce a `Polygon` from an `AbstractPolygon`
styled with the [`Rounded`](@ref) style.

In the case of a ClippedPolygon, rounding is applied to all the component Polygons, with the
same `corner_indices` rounded on each contour if specified. Rounding may
cause clashes between "positive" and "negative" regions. If this occurs it is treated as a
user error and the rounding parameters should be adjusted.

Handles absolute and relative rounding; however, if `AbstractPolygon{T}` is not dimensional,
namely `T <: Real`, then the `relative` keyword argument must be used, and incurs a
performance penalty. For `T<:Length`, the `relative` keyword should not be set, as relative
vs absolute is inferred from the type of `radius`.

## Keyword arguments

  - `atol`: tolerance is approximately the maximum distance from any segment to the actual
    circle. Defaults to 1.0nm (or 0.001 when not using units).
  - `corner_indices`: indices of vertices in `p` to consider for rounding (default all)
  - `min_angle`: if adjacent sides are collinear within the tolerance set by `min_angle`,
    rounding will not be performed.
  - `relative`: whether or not the radius parameter is a relative or absolute length scale.
    Only necessary in the case where `T<:Real`, otherwise can be deduced from the types.
    Note: setting this in the case of `T<:Length` will result in performance degradation due
    to type instability.
  - `min_side_len`: the minimum side length that will get rounded (e.g. for 90-degree angles,
    it makes sense to have `min_side_len = 2 * rounding_radius`).

Applying the [`DeviceLayout.ToTolerance`](@ref) style on top of `Rounded` allows you to control the
tolerance of the polygon discretization when rendering to a `Cell`, overriding the global `atol`
option (default `1nm`).
"""
function _round_poly(
    pol::AbstractPolygon{T},
    radius::S;
    atol           = _round_atol(T, (S <: Length) ? S : T),
    corner_indices = eachindex(points(pol)),
    min_angle      = 1e-3,
    relative::Bool = (T <: Length) && (S <: Real),
    min_side_len   = relative ? zero(T) : radius
) where {T, S <: Coordinate}
    iszero(radius) && return pol
    # If radius is dimensional, non-relative rounding.
    V = ((S <: Length && T <: Length) || (S <: Real && T <: Real)) ? promote_type(T, S) : T
    # Tie break for Real, Real introduces a type instability for non-dimensional.
    relative = ((T <: Length) && (S <: Real)) || (relative && T <: Real && S <: Real)

    poly = points(pol)
    len = length(poly)
    new_polygon = Point{float(V)}[]
    for i in eachindex(poly)
        if !(i in corner_indices)
            push!(new_polygon, poly[i])
        else
            p0 = poly[mod1(i - 1, len)] # handles the cyclic boundary condition
            p1 = poly[i]
            p2 = poly[mod1(i + 1, len)]
            radius_dim = relative ? radius * min(norm(p0 - p1), norm(p1 - p2)) : radius
            append!(
                new_polygon,
                rounded_corner(
                    p0,
                    p1,
                    p2,
                    radius_dim,
                    atol=atol,
                    min_side_len=min_side_len,
                    min_angle=min_angle
                ) # Includes endpoints -- may duplicate points
            )
        end
    end
    return Polygon(new_polygon...)
end

# Perform rounding by creating Polygons of each contour, dispatching
# then reingesting the points.
function round_node!(n::Clipper.PolyNode, radius::S; kwargs...) where {S <: Coordinate}
    n.contour = points(_round_poly(Polygon(contour(n)), radius; kwargs...))
    round_node!.(n.children, Ref(radius); kwargs...)
    return nothing
end

function _round_poly(
    pol::ClippedPolygon{T},
    radius::S;
    kwargs...
) where {T, S <: Coordinate}
    V = ((S <: Length && T <: Length) || (S <: Real && T <: Real)) ? promote_type(T, S) : T
    new_pol = T == V ? deepcopy(pol) : convert(ClippedPolygon{V}, pol)
    round_node!.(new_pol.tree.children, Ref(radius); kwargs...)
    return new_pol
end

"""
    rounded_corner(p0::Point{T}, p1::Point{T}, p2::Point{T}, radius::S;
        atol, min_side_len, min_angle)

A vector of points in a circular arc rounding the corner defined by `p0, p1, p2` with `radius`.

## Keyword arguments

  - `atol`: tolerance is approximately the maximum distance from any segment to the actual
    circle. Defaults to 1.0nm (or 0.001 when not using units).
  - `min_side_len`: the minimum side length that will get rounded (e.g. for 90-degree angles,
    it makes sense to have `min_side_len = 2 * rounding_radius`).
  - `min_angle`: if adjacent sides are collinear within the tolerance set by `min_angle`,
    rounding will not be performed.
"""
function rounded_corner(
    p0::Point{T},
    p1::Point{T},
    p2::Point{T},
    radius::S;
    atol=_round_atol(T, S),
    min_side_len=radius,
    min_angle=1e-3
) where {T, S <: Coordinate}
    V = promote_type(T, S)
    rad = convert(V, radius)

    v1 = (p1 - p0) / norm(p1 - p0)
    v2 = (p2 - p1) / norm(p2 - p1)
    α1 = atan(v1.y, v1.x)
    α2 = atan(v2.y, v2.x)

    l1 = min_side_len - norm(p1 - p0)
    l2 = min_side_len - norm(p2 - p1)
    if (l1 > zero(l1) && !isapprox(l1, zero(l1), atol=atol)) ||
       (l2 > zero(l2) && !isapprox(l2, zero(l2), atol=atol)) # checks that the side lengths against min_side_len
        return [p1]
    elseif isapprox(rem2pi(α1 - α2, RoundNearest), 0, atol=min_angle) # checks if the points are collinear, within tolerance
        return [p1]
    end

    dir = orientation(p0, p1, p2) # checks the direction of the corner
    # pcircle is the origin of the rounding circle, determined by the intersection
    # of lines parallel to v1, v2 and offset by a distance rad
    k =
        inv([v1.x -v2.x; v1.y -v2.y]) *
        [p2.x - p0.x + dir * rad * (v1.y - v2.y), p2.y - p0.y + dir * rad * (v2.x - v1.x)]
    pcircle = p0 + k[1] * v1 + dir * rad * [-v1.y, v1.x]
    return DeviceLayout.circular_arc(
        [α1 - dir * π / 2, α2 - dir * π / 2],
        rad,
        atol,
        center=pcircle
    )
end

"""
    sweep_poly(poly::Polygon, displacement::Point)

Return a `Polygon` corresponding to the boundary formed by `poly` swept by `displacement`.

This is the result you would get by painting with a brush shaped like `poly` and moving it
along a line by `displacement`.
"""
function sweep_poly(poly::Polygon{T}, displacement::Point) where {T}
    segments = [[poly.p[i], poly.p[mod1(i + 1, length(poly.p))]] for i in eachindex(poly.p)]
    swept_segments = [
        Polygon{T}([
            first(seg),
            last(seg),
            last(seg) + displacement,
            first(seg) + displacement
        ]) for seg in segments
    ]
    for sw in swept_segments
        orientation(sw) != orientation(poly) && reverse!(sw.p)
    end
    return union2d(swept_segments, poly)
end
function sweep_poly(p::ClippedPolygon, displacement::Point)
    return union2d(p, sweep_poly.(to_polygons(p), Ref(displacement)))
end

function halo(
    polys::AbstractArray{S},
    outer_delta,
    inner_delta=nothing
) where {T, S <: AbstractPolygon{T}}
    isnothing(inner_delta) && return offset(polys, convert(T, outer_delta))
    return difference2d(
        offset(polys, convert(T, outer_delta)),
        offset(polys, convert(T, inner_delta))
    )
end

function halo(polys::AbstractPolygon{T}, outer_delta, inner_delta=nothing) where {T}
    isnothing(inner_delta) && return offset(polys, convert(T, outer_delta))
    return difference2d(
        offset(polys, convert(T, outer_delta)),
        offset(polys, convert(T, inner_delta))
    )
end

# Polygon promotion.
for X in (:Real, :Length)
    @eval promote_rule(::Type{Polygon{S}}, ::Type{Polygon{T}}) where {S <: $X, T <: $X} =
        Polygon{promote_type(S, T)}
    @eval promote_rule(::Type{Rectangle{S}}, ::Type{Polygon{T}}) where {S <: $X, T <: $X} =
        Polygon{promote_type(S, T)}
    @eval promote_rule(
        ::Type{Rectangle{S}},
        ::Type{Rectangle{T}}
    ) where {S <: $X, T <: $X} = Rectangle{promote_type(S, T)}
end

# Clipping polygons one at a time
"""
    clip(op::Clipper.ClipType, s, c; kwargs...) where {S<:Coordinate, T<:Coordinate}
    clip(op::Clipper.ClipType, s::AbstractVector{A}, c::AbstractVector{B};
        kwargs...) where {S, T, A<:Polygon{S}, B<:Polygon{T}}
    clip(op::Clipper.ClipType,
        s::AbstractVector{Polygon{T}}, c::AbstractVector{Polygon{T}};
        pfs::Clipper.PolyFillType=Clipper.PolyFillTypeEvenOdd,
        pfc::Clipper.PolyFillType=Clipper.PolyFillTypeEvenOdd) where {T}

Return the `ClippedPolygon` resulting from a polygon clipping operation.

Uses the [`Clipper`](http://www.angusj.com/delphi/clipper.php) library and the
[`Clipper.jl`](https://github.com/Voxel8/Clipper.jl) wrapper to perform polygon clipping.

## Positional arguments

The first argument must be one of the following types to specify a clipping operation:

  - `Clipper.ClipTypeDifference`
  - `Clipper.ClipTypeIntersection`
  - `Clipper.ClipTypeUnion`
  - `Clipper.ClipTypeXor`

Note that these are types; you should not follow them with `()`.

The second and third argument may be a `GeometryEntity` or array of `GeometryEntity`. All entities
are first converted to polygons using [`to_polygons`](@ref).
Each can also be a `GeometryStructure` or `GeometryReference`, in which case
`elements(flatten(p))` will be converted to polygons.
Each can also be a pair `geom => layer`, where `geom` is a
`GeometryStructure` or `GeometryReference`, while `layer` is a `DeviceLayout.Meta`, a layer name `Symbol`, and/or a collection
of either, in which case only the elements in those layers will be taken from the flattened structure.

## Keyword arguments

`pfs` and `pfc` specify polygon fill rules for the `s` and `c` arguments, respectively.
These arguments may include:

  - `Clipper.PolyFillTypeNegative`
  - `Clipper.PolyFillTypePositive`
  - `Clipper.PolyFillTypeEvenOdd`
  - `Clipper.PolyFillTypeNonZero`

See the [`Clipper` docs](http://www.angusj.com/delphi/clipper/documentation/Docs/Units/ClipperLib/Types/PolyFillType.htm)
for further information.

See also [union2d](@ref), [difference2d](@ref), and [intersect2d](@ref).
"""
function clip(op::Clipper.ClipType, s, c; kwargs...)
    return clip(op, _normalize_clip_arg(s), _normalize_clip_arg(c); kwargs...)
end

# Clipping requires an AbstractVector{Polygon{T}}
_normalize_clip_arg(p::Polygon) = [p]
_normalize_clip_arg(p::GeometryEntity) = _normalize_clip_arg(to_polygons(p))
_normalize_clip_arg(p::AbstractArray{Polygon{T}}) where {T} = p
_normalize_clip_arg(p::AbstractArray{<:GeometryEntity{T}}) where {T} =
    reduce(vcat, to_polygons.(p); init=Polygon{T}[])
_normalize_clip_arg(p::Union{GeometryStructure, GeometryReference}) =
    _normalize_clip_arg(flat_elements(p))
_normalize_clip_arg(p::Pair{<:Union{GeometryStructure, GeometryReference}}) =
    _normalize_clip_arg(flat_elements(p))

# Clipping arrays of AbstractPolygons
function clip(
    op::Clipper.ClipType,
    s::AbstractVector{A},
    c::AbstractVector{B};
    kwargs...
) where {S, T, A <: Polygon{S}, B <: Polygon{T}}
    dimension(S) != dimension(T) && throw(Unitful.DimensionError(oneunit(S), oneunit(T)))
    R = promote_type(S, T)

    return clip(
        op,
        convert(Vector{Polygon{R}}, s),
        convert(Vector{Polygon{R}}, c);
        kwargs...
    )
end

# Clipping two identically-typed arrays of <: Polygon
function clip(
    op::Clipper.ClipType,
    s::AbstractVector{Polygon{T}},
    c::AbstractVector{Polygon{T}};
    pfs::Clipper.PolyFillType=Clipper.PolyFillTypeEvenOdd,
    pfc::Clipper.PolyFillType=Clipper.PolyFillTypeEvenOdd
) where {T}
    sc, cc = clipperize(s), clipperize(c)
    polys = _clip(op, sc, cc; pfs, pfc)
    return declipperize(polys, T)
end

"""
    cliptree(op::Clipper.ClipType, s::AbstractPolygon{S}, c::AbstractPolygon{T};
        kwargs...) where {S<:Coordinate, T<:Coordinate}
    cliptree(op::Clipper.ClipType, s::AbstractVector{A}, c::AbstractVector{B};
        kwargs...) where {S, T, A<:AbstractPolygon{S}, B<:AbstractPolygon{T}}
    cliptree(op::Clipper.ClipType,
        s::AbstractVector{Polygon{T}}, c::AbstractVector{Polygon{T}};
        pfs::Clipper.PolyFillType=Clipper.PolyFillTypeEvenOdd,
        pfc::Clipper.PolyFillType=Clipper.PolyFillTypeEvenOdd) where {T}

Return a `Clipper.PolyNode` representing parent-child relationships between polygons and
interior holes. The units and number type may need to be converted.

Uses the [`Clipper`](http://www.angusj.com/delphi/clipper.php) library and the
[`Clipper.jl`](https://github.com/Voxel8/Clipper.jl) wrapper to perform polygon clipping.

## Positional arguments

The first argument must be one of the following types to specify a clipping operation:

  - `Clipper.ClipTypeDifference`
  - `Clipper.ClipTypeIntersection`
  - `Clipper.ClipTypeUnion`
  - `Clipper.ClipTypeXor`

Note that these are types; you should not follow them with `()`. The second and third
arguments are `AbstractPolygon`s or vectors thereof.

## Keyword arguments

`pfs` and `pfc` specify polygon fill rules for the `s` and `c` arguments, respectively.
These arguments may include:

  - `Clipper.PolyFillTypeNegative`
  - `Clipper.PolyFillTypePositive`
  - `Clipper.PolyFillTypeEvenOdd`
  - `Clipper.PolyFillTypeNonZero`

See the [`Clipper` docs](http://www.angusj.com/delphi/clipper/documentation/Docs/Units/ClipperLib/Types/PolyFillType.htm)
for further information.
"""
function cliptree(
    op::Clipper.ClipType,
    s::AbstractPolygon{S},
    c::AbstractPolygon{T};
    kwargs...
) where {S <: Coordinate, T <: Coordinate}
    dimension(S) != dimension(T) && throw(Unitful.DimensionError(oneunit(S), oneunit(T)))
    R = promote_type(S, T)
    return cliptree(op, Polygon{R}[s], Polygon{R}[c]; kwargs...)::Vector{Polygon{R}}
end

function cliptree(
    op::Clipper.ClipType,
    s::AbstractVector{A},
    c::AbstractVector{B};
    kwargs...
) where {S, T, A <: AbstractPolygon{S}, B <: AbstractPolygon{T}}
    dimension(S) != dimension(T) && throw(Unitful.DimensionError(oneunit(S), oneunit(T)))
    R = promote_type(S, T)
    return cliptree(
        op,
        convert(Vector{Polygon{R}}, s),
        convert(Vector{Polygon{R}}, c);
        kwargs...
    )::Vector{Polygon{R}}
end

function cliptree(
    op::Clipper.ClipType,
    s::AbstractVector{Polygon{T}},
    c::AbstractVector{Polygon{T}};
    pfs::Clipper.PolyFillType=Clipper.PolyFillTypeEvenOdd,
    pfc::Clipper.PolyFillType=Clipper.PolyFillTypeEvenOdd
) where {T}
    sc, cc = clipperize(s), clipperize(c)
    cpoly = _clip(op, sc, cc; pfs, pfc)
    return declipperize(cpoly, T).tree
end

"""
    union2d(p1, p2)

Return the geometric union of p1 and p2 as a `ClippedPolygon`.

Each of `p1` and `p2` may be a `GeometryEntity` or array of `GeometryEntity`. All entities
are first converted to polygons using [`to_polygons`](@ref).

Each of `p1` and `p2` can also be a `GeometryStructure` or `GeometryReference`, in which case
`elements(flatten(p))` will be converted to polygons.

Each can also be a pair `geom => layer`, where `geom` is a
`GeometryStructure` or `GeometryReference`, while `layer` is a `DeviceLayout.Meta`, a layer name `Symbol`, and/or a collection
of either, in which case only the elements in those layers will used.

This is not implemented as a method of `union` because you can have a set union of arrays of
polygons, which is a distinct operation.

The Clipper polyfill rule is PolyFillTypePositive, meaning as long as a
region lies within more non-hole (by orientation) than hole polygons, it lies
in the union.
"""
function union2d(p1, p2)
    return clip(
        Clipper.ClipTypeUnion,
        p1,
        p2,
        pfs=Clipper.PolyFillTypePositive,
        pfc=Clipper.PolyFillTypePositive
    )
end

"""
    union2d(p)

Return the geometric union of `p` or all entities in `p`.
"""
union2d(p::AbstractGeometry{T}) where {T} = union2d(p, Polygon{T}[])
union2d(p::AbstractArray{<:AbstractGeometry{T}}) where {T} = union2d(p, Polygon{T}[])

"""
    difference2d(p1, p2)

Return the geometric union of `p1` minus the geometric union of `p2` as a `ClippedPolygon`.

Each of `p1` and `p2` may be a `GeometryEntity` or array of `GeometryEntity`. All entities
are first converted to polygons using [`to_polygons`](@ref).

Each of `p1` and `p2` can also be a `GeometryStructure` or `GeometryReference`, in which case
`elements(flatten(p))` will be converted to polygons.

Each can also be a pair `geom => layer`, where `geom` is a
`GeometryStructure` or `GeometryReference`, while `layer` is a `DeviceLayout.Meta`, a layer name `Symbol`, and/or a collection
of either, in which case only the elements in those layers will be used.
"""
function difference2d(plus, minus)
    return clip(
        Clipper.ClipTypeDifference,
        plus,
        minus,
        pfs=Clipper.PolyFillTypePositive,
        pfc=Clipper.PolyFillTypePositive
    )
end

"""
    intersect2d(p1, p2)

Return the geometric union of `p1` intersected with the geometric union of `p2`  as a `ClippedPolygon`.

Each of `p1` and `p2` may be a `GeometryEntity` or array of `GeometryEntity`. All entities
are first converted to polygons using [`to_polygons`](@ref).

Each of `p1` and `p2` can also be a `GeometryStructure` or `GeometryReference`, in which case
`elements(flatten(p))` will be converted to polygons.

Each can also be a pair `geom => layer`, where `geom` is a
`GeometryStructure` or `GeometryReference`, while `layer` is a `DeviceLayout.Meta`, a layer name `Symbol`, and/or a collection
of either, in which case only the elements in those layers will be used.
"""
function intersect2d(plus, minus)
    return clip(
        Clipper.ClipTypeIntersection,
        plus,
        minus,
        pfs=Clipper.PolyFillTypePositive,
        pfc=Clipper.PolyFillTypePositive
    )
end

"""
    xor2d(p1, p2)

Return the symmetric difference (XOR) of `p1` and `p2` as a `ClippedPolygon`.

The XOR operation returns regions that are in either `p1` or `p2`, but not in both.
This is useful for finding non-overlapping regions between two sets of polygons.

Each of `p1` and `p2` may be a `GeometryEntity` or array of `GeometryEntity`. All entities
are first converted to polygons using [`to_polygons`](@ref).

Each of `p1` and `p2` can also be a `GeometryStructure` or `GeometryReference`, in which case
`elements(flatten(p))` will be converted to polygons.

Each can also be a pair `geom => layer`, where `geom` is a
`GeometryStructure` or `GeometryReference`, while `layer` is a `DeviceLayout.Meta`, a layer name `Symbol`, and/or a collection
of either, in which case only the elements in those layers will be used.
"""
function xor2d(p1, p2)
    return clip(
        Clipper.ClipTypeXor,
        p1,
        p2,
        pfs=Clipper.PolyFillTypePositive,
        pfc=Clipper.PolyFillTypePositive
    )
end

function add_path!(
    c::Clipper.Clip,
    path::Vector{Point{T}},
    polyType::Clipper.PolyType,
    closed::Bool
) where {T <: Union{Int64, Unitful.Quantity{Int64}}}
    return ccall(
        (:add_path, libcclipper),
        Cuchar,
        (Ptr{Cvoid}, Ptr{Clipper.IntPoint}, Csize_t, Cint, Cuchar),
        c.clipper_ptr,
        path,
        length(path),
        Int(polyType),
        closed
    ) == 1 ? true : false
end

# Clipping two identically-typed arrays of "Int64-based" Polygons.
# Internal method which should not be called by user (but does the heavy lifting)
function _clip(
    op::Clipper.ClipType,
    s::AbstractVector{Polygon{T}},
    c::AbstractVector{Polygon{T}};
    pfs::Clipper.PolyFillType=Clipper.PolyFillTypeEvenOdd,
    pfc::Clipper.PolyFillType=Clipper.PolyFillTypeEvenOdd
) where {T <: Union{Int64, Unitful.Quantity{Int64}}}
    clip = clipper()
    Clipper.clear!(clip)
    for s0 in s
        add_path!(clip, s0.p, Clipper.PolyTypeSubject, true)
    end
    for c0 in c
        add_path!(clip, c0.p, Clipper.PolyTypeClip, true)
    end
    result =
        convert(Clipper.PolyNode{Point{Int64}}, Clipper.execute_pt(clip, op, pfs, pfc)[2])

    return ClippedPolygon(recast(Clipper.PolyNode{Point{T}}, result))
end

#    recast(::Type{Clipper.PolyNode{T}}, x::Clipper.PolyNode}) where {T}
#  Creates a `Clipper.PolyNode{T}` by reinterpreting vectors of points in `x`.
recast(::Type{Clipper.PolyNode{T}}, x::Clipper.PolyNode{T}) where {T} = x
function recast(::Type{Clipper.PolyNode{S}}, x::Clipper.PolyNode{T}) where {S, T}
    pn = Clipper.PolyNode{S}(
        reinterpret(S, Clipper.contour(x)),
        Clipper.ishole(x),
        Clipper.isopen(x)
    )
    pn.children = [recast(y, pn) for y in Clipper.children(x)]
    return pn.parent = pn
end
#    recast(x::Clipper.PolyNode, parent::Clipper.PolyNode{S}) where {S}
#  Creates a `Clipper.PolyNode{S}` from `x` given a new `parent` node.
function recast(x::Clipper.PolyNode, parent::Clipper.PolyNode{S}) where {S}
    pn = Clipper.PolyNode{S}(
        reinterpret(S, Clipper.contour(x)),
        Clipper.ishole(x),
        Clipper.isopen(x)
    )
    pn.children = [recast(y, pn) for y in Clipper.children(x)]
    pn.parent = parent
    return pn
end

#   Int64like(x::Point{T}) where {T}
#   Int64like(x::Polygon{T}) where {T}
# Converts Points or Polygons to an Int64-based representation (possibly with units).
Int64like(x::Point{T}) where {T} = convert(Point{typeof(Int64(1) * unit(T))}, x)
Int64like(x::Polygon{T}) where {T} = convert(Polygon{typeof(Int64(1) * unit(T))}, x)

#   prescale(x::Point{<:Real})
# Since the Clipper library works on Int64-based points, we multiply floating-point-based
# `x` by `10.0^9` before rounding to retain high resolution. Since` 1.0` is interpreted
# to mean `1.0 um`, this yields `fm` resolution, which is more than sufficient for most uses.
prescale(x::Point{<:Real}) = x * SCALE  # 2^29.897...

#   prescale(x::Point{<:Quantity})
# Since the Clipper library works on Int64-based points, we unit-convert `x` to `fm` before
# rounding to retain high resolution, which is more than sufficient for most uses.
prescale(x::Point{<:Quantity}) = convert(Point{typeof(USCALE)}, x)

#   clipperize(A::AbstractVector{Polygon{T}}) where {T}
#   clipperize(A::AbstractVector{Polygon{T}}) where {S<:Integer, T<:Union{S, Unitful.Quantity{S}}}
#   clipperize(A::AbstractVector{Polygon{T}}) where {T <: Union{Int64, Unitful.Quantity{Int64}}}
# Prepare a vector of Polygons for being operated upon by the Clipper library,
# which expects Int64-based points (Quantity{Int64} is okay after using `reinterpret`).
function clipperize(A::AbstractVector{Polygon{T}}) where {T}
    return [Polygon(clipperize.(points(x))) for x in A]
end

# Already Integer-based, so no need to do rounding or scaling. Just convert to Int64-like.
function clipperize(
    A::AbstractVector{Polygon{T}}
) where {S <: Integer, T <: Union{S, Unitful.Quantity{S}}}
    return Int64like.(A)
end

# Already Int64-based, so just pass through, nothing to do here.
function clipperize(
    A::AbstractVector{Polygon{T}}
) where {T <: Union{Int64, Unitful.Quantity{Int64}}}
    return A
end

function clipperize(x::Point{T}) where {S <: Real, T <: Union{S, Unitful.Quantity{S}}}
    return Int64like(unsafe_round(prescale(x)))
end
function clipperize(
    x::Point{T}
) where {S <: Integer, D, U, T <: Union{S, Unitful.Quantity{S, D, U}}}
    return Int64like(x)
end

unscale(p::Point, ::Type{T}) where {T <: Quantity} = convert(Point{T}, p)
unscale(p::Point, ::Type{T}) where {T} = convert(Point{T}, p ./ SCALE)

# Declipperize methods are used to get back to the original type.
declipperize(p, ::Type{T}) where {T} = Polygon{T}((x -> unscale(x, T)).(points(p)))
declipperize(p, ::Type{T}) where {T <: Union{Int64, Unitful.Quantity{Int64}}} =
    Polygon{T}(reinterpret(Point{T}, points(p)))

# Prepare a ClippedPolygon for use with Clipper.
function clipperize(p::ClippedPolygon)
    R = typeof(clipperize(p.tree.children[1].contour[1]))
    t = deepcopy(p.tree)
    function prescale(p::Clipper.PolyNode)
        Clipper.contour(p) .= (x -> unsafe_round(x * SCALE)).(Clipper.contour(p))
        for x in p.children
            prescale(x)
        end
    end
    prescale(t)
    x = ClippedPolygon(convert(Clipper.PolyNode{R}, t))
    return x
end
function clipperize(p::ClippedPolygon{T}) where {T <: Quantity}
    return ClippedPolygon(clipperize(p.tree))
end

# Prepare the data within a Clipper.PolyNode for use with Clipper.
function clipperize(p::Clipper.PolyNode)
    # Create a tree by clipperizing contours recursively.
    function buildtree(p)
        T = typeof(clipperize.(p.contour)).parameters[1]
        return Clipper.PolyNode{T}(
            clipperize.(p.contour),
            p.hole,
            p.open,
            buildtree.(p.children)
        )
    end
    t = buildtree(p)

    # Inform children of their heritage.
    function labelchildren(node, parent)
        for c ∈ node.children
            c.parent = parent
            labelchildren(c, node)
        end
    end
    labelchildren(t, t)
    return t
end

# Convert a "clipperized" ClippedPolygon to a given type.
# Real valued clipping: convert the integer value back to float by dividing.
function declipperize(p::ClippedPolygon, ::Type{T}) where {T}
    x = ClippedPolygon(convert(Clipper.PolyNode{Point{T}}, p.tree))
    function unscale(p::Clipper.PolyNode)
        Clipper.contour(p) .= (x -> x / SCALE).(Clipper.contour(p))
        for x in p.children
            unscale(x)
        end
    end
    unscale(x.tree)
    return x
end
# Unitful quantities and integers use conversion directly. Extra methods resolve type
# ambiguities for aqua.
function declipperize(
    p::ClippedPolygon{T},
    ::Type{T}
) where {T <: Union{Int, Quantity{Int}}}
    return ClippedPolygon(convert(Clipper.PolyNode{Point{T}}, p.tree))
end
function declipperize(p::ClippedPolygon, ::Type{T}) where {T <: Union{Int, Quantity{Int}}}
    return ClippedPolygon(convert(Clipper.PolyNode{Point{T}}, p.tree))
end
function declipperize(p::ClippedPolygon{<:Quantity}, ::Type{T}) where {T}
    return ClippedPolygon(convert(Clipper.PolyNode{Point{T}}, p.tree))
end
function declipperize(
    p::ClippedPolygon{<:Quantity},
    ::Type{T}
) where {T <: Union{Int, Quantity{Int}}}
    return ClippedPolygon(convert(Clipper.PolyNode{Point{T}}, p.tree))
end

"""
    offset{S<:Coordinate}(s::AbstractPolygon{S}, delta::Coordinate;
        j::Clipper.JoinType=Clipper.JoinTypeMiter,
        e::Clipper.EndType=Clipper.EndTypeClosedPolygon)
    offset{S<:AbstractPolygon}(subject::AbstractVector{S}, delta::Coordinate;
        j::Clipper.JoinType=Clipper.JoinTypeMiter,
        e::Clipper.EndType=Clipper.EndTypeClosedPolygon)
    offset{S<:Polygon}(s::AbstractVector{S}, delta::Coordinate;
        j::Clipper.JoinType=Clipper.JoinTypeMiter,
        e::Clipper.EndType=Clipper.EndTypeClosedPolygon)

Using the [`Clipper`](http://www.angusj.com/delphi/clipper.php) library and
the [`Clipper.jl`](https://github.com/Voxel8/Clipper.jl) wrapper, perform
polygon offsetting.

The orientations of polygons must be consistent, such that outer polygons share the same
orientation, and any holes have the opposite orientation. Additionally, any holes should be
contained within outer polygons; offsetting hole edges may create positive artifacts at
corners.

The first argument should be an [`AbstractPolygon`](@ref). The second argument
is how much to offset the polygon. Keyword arguments include a
[join type](http://www.angusj.com/delphi/clipper/documentation/Docs/Units/ClipperLib/Types/JoinType.htm):

  - `Clipper.JoinTypeMiter`
  - `Clipper.JoinTypeRound`
  - `Clipper.JoinTypeSquare`

and also an
[end type](http://www.angusj.com/delphi/clipper/documentation/Docs/Units/ClipperLib/Types/EndType.htm):

  - `Clipper.EndTypeClosedPolygon`
  - `Clipper.EndTypeClosedLine`
  - `Clipper.EndTypeOpenSquare`
  - `Clipper.EndTypeOpenRound`
  - `Clipper.EndTypeOpenButt`
"""
function offset end

function offset(
    s::AbstractPolygon{T},
    delta::Coordinate;
    j::Clipper.JoinType=Clipper.JoinTypeMiter,
    e::Clipper.EndType=Clipper.EndTypeClosedPolygon
) where {T <: Coordinate}
    dimension(T) != dimension(delta) && throw(Unitful.DimensionError(oneunit(T), delta))
    S = promote_type(T, typeof(delta))
    return offset(Polygon{S}[s], convert(S, delta); j=j, e=e)
end

function offset(
    s::AbstractVector{A},
    delta::Coordinate;
    j::Clipper.JoinType=Clipper.JoinTypeMiter,
    e::Clipper.EndType=Clipper.EndTypeClosedPolygon
) where {T, A <: AbstractPolygon{T}}
    dimension(T) != dimension(delta) && throw(Unitful.DimensionError(oneunit(T), delta))
    S = promote_type(T, typeof(delta))

    mask = typeof.(s) .<: ClippedPolygon
    return offset(
        convert(
            Vector{Polygon{S}},
            [s[.!mask]..., reduce(vcat, to_polygons.(s[mask]); init=Polygon{S}[])...]
        ),
        convert(S, delta);
        j=j,
        e=e
    )
end

prescaledelta(x::Real) = x * SCALE
prescaledelta(x::Integer) = x
prescaledelta(x::Length{<:Real}) = convert(typeof(USCALE), x)
prescaledelta(x::Length{<:Integer}) = x

function offset(
    s::AbstractVector{Polygon{T}},
    delta::T;
    j::Clipper.JoinType=Clipper.JoinTypeMiter,
    e::Clipper.EndType=Clipper.EndTypeClosedPolygon
) where {T <: Coordinate}
    sc = clipperize(s)
    d = prescaledelta(delta)
    polys = _offset(sc, d, j=j, e=e)
    return declipperize.(polys, T)
end

function offset(
    s::ClippedPolygon,
    delta::T;
    j::Clipper.JoinType=Clipper.JoinTypeMiter,
    e::Clipper.EndType=Clipper.EndTypeClosedPolygon
) where {T <: Coordinate}
    return offset(to_polygons(s), delta, j=j, e=e)
end

function add_path!(
    c::Clipper.ClipperOffset,
    path::Vector{Point{T}},
    joinType::Clipper.JoinType,
    endType::Clipper.EndType
) where {T <: Union{Int64, Unitful.Quantity{Int64}}}
    return ccall(
        (:add_offset_path, libcclipper),
        Cvoid,
        (Ptr{Cvoid}, Ptr{Clipper.IntPoint}, Csize_t, Cint, Cint),
        c.clipper_ptr,
        path,
        length(path),
        Int(joinType),
        Int(endType)
    )
end

function _offset(
    s::AbstractVector{Polygon{T}},
    delta;
    j::Clipper.JoinType=Clipper.JoinTypeMiter,
    e::Clipper.EndType=Clipper.EndTypeClosedPolygon
) where {T <: Union{Int64, Unitful.Quantity{Int64}}}
    c = coffset()
    Clipper.clear!(c)
    for s0 in s
        add_path!(c, s0.p, j, e)
    end
    result = Clipper.execute(c, Float64(ustrip(delta))) #TODO: fix in clipper
    return [Polygon(reinterpret(Point{T}, p)) for p in result]
end

### cutting algorithm

abstract type D1{T} end
Δy(d1::D1) = d1.p1.y - d1.p0.y
Δx(d1::D1) = d1.p1.x - d1.p0.x

ab(p0, p1) = Point(gety(p1) - gety(p0), getx(p0) - getx(p1))

"""
    LineSegment{T} <: D1{T}

Represents a line segment. By construction, `p0.x <= p1.x`.
"""
struct LineSegment{T} <: D1{T}
    p0::Point{T}
    p1::Point{T}
    function LineSegment(p0::Point{T}, p1::Point{T}) where {T}
        if p1.x < p0.x
            return new{T}(p1, p0)
        else
            return new{T}(p0, p1)
        end
    end
end
LineSegment(p0::Point{S}, p1::Point{T}) where {S, T} = LineSegment(promote(p0, p1)...)

struct LineSegmentView{T} <: AbstractVector{T}
    v::Vector{Point{T}}
end
Base.size(v::LineSegmentView) = size(v.v)
Base.length(v::LineSegmentView) = length(v.v)
Base.firstindex(v::LineSegmentView) = firstindex(v.v)
Base.lastindex(v::LineSegmentView) = lastindex(v.v)
function Base.getindex(v::LineSegmentView, i)
    @boundscheck checkbounds(v.v, i)
    return LineSegment(v.v[i], v.v[ifelse(i == length(v), 1, i + 1)])
end

"""
    Ray{T} <: D1{T}

Represents a ray. The ray starts at `p0` and goes toward `p1`.
"""
struct Ray{T} <: D1{T}
    p0::Point{T}
    p1::Point{T}
end
Ray(p0::Point{S}, p1::Point{T}) where {S, T} = Ray(promote(p0, p1)...)

struct Line{T} <: D1{T}
    p0::Point{T}
    p1::Point{T}
end
Line(p0::Point{S}, p1::Point{T}) where {S, T} = Line(promote(p0, p1)...)
Line(seg::LineSegment) = Line(seg.p0, seg.p1)

Base.promote_rule(::Type{Line{S}}, ::Type{Line{T}}) where {S, T} = Line{promote_type(S, T)}
Base.convert(::Type{Line{S}}, L::Line) where {S} = Line{S}(L.p0, L.p1)

"""
    segmentize(vertices, closed=true)

Make an array of `LineSegment` out of an array of points. If `closed`, a segment should go
between the first and last point, otherwise nah.
"""
function segmentize(vertices, closed=true)
    l = length(vertices)
    if closed
        return [LineSegment(vertices[i], vertices[i == l ? 1 : i + 1]) for i = 1:l]
    else
        return [LineSegment(vertices[i], vertices[i + 1]) for i = 1:(l - 1)]
    end
end

"""
    uniqueray(v::Vector{Point{T}}) where {T <: Real}

Given an array of points (thought to indicate a polygon or a hole in a polygon),
find the lowest / most negative y-coordinate[s] `miny`, then the lowest / most negative
x-coordinate `minx` of the points having that y-coordinate. This `Point(minx,miny)` ∈ `v`.
Return a ray pointing in -ŷ direction from that point.
"""
function uniqueray(v::Vector{Point{T}}) where {T <: Real}
    nopts = reinterpret(T, v)
    yarr = view(nopts, 2:2:length(nopts))
    miny, indy = findmin(yarr)
    xarr = view(nopts, (findall(x -> x == miny, yarr) .* 2) .- 1)
    minx, indx = findmin(xarr)
    indv = findall(x -> x == Point(minx, miny), v)[1]
    return Ray(Point(minx, miny), Point(minx, miny - 1)), indv
end

"""
    unfold(v::Vector{Point{T}}, direction; through_pt=nothing) where {T}
    unfold(v::Vector{Point{T}}, p0, p1) where {T}

Return a vector of twice the length of `v`, where the first half is `v` and the second half
is `v` in reverse order and reflected about an axis.

This can be used to construct polygons that have a mirror symmetry. The symmetry axis
can be defined in either of two ways: as a line with a given `direction` passing through
point `through_pt` (defaults to origin), or by two points `p0`, `p1`. `direction` can
be passed either as an angle or as a `Point` representing a vector.

As a trivial example, to draw a centered square:

```julia
uy = Point(0μm, 1μm) # could also be passed as 90°
pts = [Point(-1μm, -1μm), Point(-1μm, 1μm)]
square = Polygon(unfold(pts, uy))
```
"""
function unfold(v::Vector{Point{T}}, direction; through_pt=nothing) where {T}
    N = length(v)
    _reflect = Reflection(direction; through_pt=through_pt)
    v_ref = [_reflect(v[N - i + 1]) for i in eachindex(v)]
    return vcat(v, v_ref)
end
function unfold(v::Vector{Point{T}}, p0, p1) where {T}
    return unfold(v, p1 - p0; through_pt=p0)
end

"""
    orientation(p::Polygon)

Return 1 if the points in the polygon contour are going counter-clockwise, -1 if clockwise.
Clipper considers clockwise-oriented polygons to be holes for some polygon fill types.
"""
function orientation(p::Polygon)
    return ccall(
        (:orientation, libcclipper),
        Cuchar,
        (Ptr{Clipper.IntPoint}, Csize_t),
        reinterpret(Clipper.IntPoint, clipperize.(p.p)),
        length(p.p)
    ) == 1 ? 1 : -1
end

"""
    ishole(p::Polygon)

Return `true` if Clipper would consider this polygon to be a hole, for applicable
polygon fill rules.
"""
ishole(p::Polygon) = orientation(p) == -1

"""
    orientation(p1::Point, p2::Point, p3::Point)

Return 1 if the path `p1`--`p2`--`p3` is going counter-clockwise (increasing angle),
-1 if the path is going clockwise (decreasing angle), 0 if `p1`, `p2`, `p3` are colinear.
"""
function orientation(p1::Point, p2::Point, p3::Point)
    return sign((p3.y - p2.y) * (p2.x - p1.x) - (p2.y - p1.y) * (p3.x - p2.x))
end

isparallel(A::D1, B::D1) = Δy(A) * Δx(B) == Δy(B) * Δx(A)
isdegenerate(A::D1, B::D1) =
    orientation(A.p0, A.p1, B.p0) == orientation(A.p0, A.p1, B.p1) == 0
iscolinear(A::D1, B::Point) = orientation(A.p0, A.p1, B) == orientation(B, A.p1, A.p0) == 0
iscolinear(A::Point, B::D1) = iscolinear(B, A)

"""
    intersects(A::LineSegment, B::LineSegment)

Return two `Bool`s:

 1. Does `A` intersect `B`?
 2. Did an intersection happen at a single point? (`false` if no intersection)
"""
function intersects(A::LineSegment, B::LineSegment)
    sb0 = orientation(A.p0, A.p1, B.p0)
    sb1 = orientation(A.p0, A.p1, B.p1)
    sb = sb0 == sb1

    sa0 = orientation(B.p0, B.p1, A.p0)
    sa1 = orientation(B.p0, B.p1, A.p1)
    sa = sa0 == sa1

    if sa == false && sb == false
        return true, true
    else
        # Test for special case of colinearity
        if sb0 == sb1 == sa0 == sa1 == 0
            y0, y1 = minmax(A.p0.y, A.p1.y)
            xinter = intersect(A.p0.x .. A.p1.x, B.p0.x .. B.p1.x)
            yinter = intersect(A.p0.y .. A.p1.y, B.p0.y .. B.p1.y)
            if !isempty(xinter) && !isempty(yinter)
                if reduce(==, endpoints(xinter)) && reduce(==, endpoints(yinter))
                    return true, true
                else
                    return true, false
                end
            else
                return false, false
            end
        else
            return false, false
        end
    end
end

"""
    intersects_at_endpoint(A::LineSegment, B::LineSegment)

Return three `Bool`s:

 1. Does `A` intersect `B`?
 2. Did an intersection happen at a single point? (`false` if no intersection)
 3. Did an endpoint of `A` intersect an endpoint of `B`?
"""
function intersects_at_endpoint(A::LineSegment, B::LineSegment)
    A_intersects_B, atapoint = intersects(A, B)
    if A_intersects_B
        if atapoint
            if (A.p1 == B.p0) || (A.p1 == B.p1) || (A.p0 == B.p0) || (A.p0 == B.p1)
                return A_intersects_B, atapoint, true
            else
                return A_intersects_B, atapoint, false
            end
        else
            return A_intersects_B, atapoint, false
        end
    else
        return A_intersects_B, atapoint, false
    end
end

"""
    intersects(p::Point, A::Ray)

Does `p` intersect `A`?
"""
function intersects(p::Point, A::Ray)
    correctdir = sign(dot(A.p1 - A.p0, p - A.p0)) >= 0
    return iscolinear(p, A) && correctdir
end

"""
    in_bounds(p::Point, A::Ray)

Is `p` in the halfspace defined by `A`?
"""
function in_bounds(p::Point, A::Ray)
    return sign(dot(A.p1 - A.p0, p - A.p0)) >= 0
end

"""
    intersects(p::Point, A::LineSegment)

Does `p` intersect `A`?
"""
function intersects(p::Point, A::LineSegment)
    if iscolinear(p, A)
        y0, y1 = minmax(A.p0.y, A.p1.y)
        xinter = intersect(A.p0.x .. A.p1.x, p.x .. p.x)
        yinter = intersect(y0 .. y1, p.y .. p.y)
        if !isempty(xinter) && !isempty(yinter)
            return true
        else
            return false
        end
    else
        return false
    end
end

"""
    in_bounds(p::Point, A::LineSegment)

Is `p` in the rectangle defined by the endpoints of `A`?
"""
function in_bounds(p::Point, A::LineSegment)
    y0, y1 = minmax(A.p0.y, A.p1.y)
    xinter = intersect(A.p0.x .. A.p1.x, p.x .. p.x)
    yinter = intersect(y0 .. y1, p.y .. p.y)
    return !isempty(xinter) && !isempty(yinter)
end

function intersection(A::Ray{T}, B::LineSegment{T}) where {T}
    fT = float(T)
    if isparallel(A, B)
        if isdegenerate(A, B)
            # correct direction?
            dist0 = dot(A.p1 - A.p0, B.p0 - A.p0)
            dist1 = dot(A.p1 - A.p0, B.p1 - A.p0)
            if sign(dist0) >= 0
                if sign(dist1) >= 0
                    # Both in correct direction
                    return true, Point{fT}(min(dist0, dist1) == dist0 ? B.p0 : B.p1)
                else
                    return true, Point{fT}(B.p0)
                end
            else
                if sign(dist1) >= 0
                    return true, Point{fT}(B.p1)
                else
                    # Neither in correct direction
                    return false, zero(Point{fT})
                end
            end
        else
            # no intersection
            return false, zero(Point{fT})
        end
    else
        tf, w = intersection(Line(A.p0, A.p1), Line(B.p0, B.p1), false)
        if tf && in_bounds(w, A) && in_bounds(w, B)
            return true, w
        else
            return false, zero(Point{fT})
        end
    end
end

function intersection(A::Line{T}, B::Line{T}, checkparallel=true) where {T}
    if checkparallel
        # parallel checking goes here!
    else
        u = A.p1 - A.p0
        v = B.p1 - B.p0
        w = A.p0 - B.p0
        vp = Point{float(T)}(-v.y, v.x)     # need float or hit overflow

        vp = vp / max(abs(vp.x), abs(vp.y))   # scale this, since its magnitude cancels out
        # dot products will be smaller than maxintfloat(Float64) (assuming |w| and |u| are)
        i = dot(-vp, w) / dot(vp, u)
        return true, A.p0 + i * u
    end
end

mutable struct InteriorCutNode{T}
    point::T
    prev::InteriorCutNode{T}
    next::InteriorCutNode{T}

    InteriorCutNode{T}(point, prev, next) where {T} = new{T}(point, prev, next)
    function InteriorCutNode{T}(point) where {T}
        node = new{T}(point)
        node.prev = node
        node.next = node
        return node
    end
end
segment(n::InteriorCutNode) = LineSegment(n.point, n.next.point)

InteriorCutNode(val::T) where {T} = InteriorCutNode{T}(val)

"""
    interiorcuts(nodeortree::Clipper.PolyNode, outpolys::Vector{Polygon{T}}) where {T}

Clipper gives polygons with holes as separate contours. The GDSII format doesn't support
this. This function makes cuts between the inner/outer contours so that ultimately there
is just one contour with one or more overlapping edges.

Example:
┌────────────┐               ┌────────────┐
│ ┌──┐       │   becomes...  │ ┌──┐       │
│ └──┘  ┌──┐ │               │ ├──┘  ┌──┐ │
│       └──┘ │               │ │     ├──┘ │
└────────────┘               └─┴─────┴────┘
"""
function interiorcuts(nodeortree::Clipper.PolyNode, outpolys::Vector{Polygon{T}}) where {T}
    # Assumes we have first element an enclosing polygon with the rest being holes.
    # We also assume no hole collision.

    minpt = Point(-Inf, -Inf)
    for enclosing in children(nodeortree)
        enclosing_contour = contour(enclosing)

        # If a contour is empty, the PolyNode is effectively removed. This also effectively
        # removes any further nodes, as they are no longer well defined.
        isempty(enclosing_contour) && continue

        # No need to copy a large array of points, make a view giving line segments.
        segs = LineSegmentView(enclosing_contour)

        # note to self: the problem has to do with segments reordering points...

        # Construct an interval tree of the x-extents of each line segment.
        arr = reshape(reinterpret(Int, xinterval.(segs)), 2, :)
        nodes = map(InteriorCutNode, enclosing_contour)
        node1 = first(nodes)
        for i in eachindex(nodes)
            i == firstindex(nodes) || (nodes[i].prev = nodes[i - 1])
            i == lastindex(nodes) || (nodes[i].next = nodes[i + 1])
        end
        IVT = IntervalValue{Int, InteriorCutNode{Point{Int}}}
        iv = sort!(IVT.(view(arr, 1, :), view(arr, 2, :), nodes))
        itree = IntervalTree{Int, IVT}()
        for v in iv
            # We should be able to to bulk insertion, but it appears like this
            # results in some broken trees for large enough initial insertion.
            # see comments in merge request 21.
            push!(itree, v)
        end
        loop_node = InteriorCutNode(enclosing_contour[1])
        loop_node.prev = last(nodes)
        last(nodes).next = loop_node

        for hole in children(enclosing)
            # process all the holes.
            interiorcuts(hole, outpolys)

            # Intersect the unique ray with the line segments of the polygon.
            hole_contour = contour(hole)
            ray, m = uniqueray(hole_contour)
            x0 = ray.p0.x

            # Find nearest intersection of the ray with the enclosing polygon.
            best_intersection_point = minpt
            local best_node

            # See which segments could possibly intersect with a line defined by `x = x0`
            for interval in IntervalTrees.intersect(itree, (x0, x0))
                # Retrieve the segment index from the node.
                node = IntervalTrees.value(interval)
                seg = segment(node)

                # this is how we'll mark a "deleted" segment even though we don't
                # actually remove it from the interval tree
                (node.prev == node) && (node.next == node) && continue

                # See if it actually intersected with the segment
                intersected, intersection_point = intersection(ray, seg)
                if intersected
                    if gety(intersection_point) > gety(best_intersection_point)
                        best_intersection_point = intersection_point
                        best_node = node
                    end
                end
            end

            # Since the polygon was enclosing, an intersection had to happen *somewhere*.
            if best_intersection_point != minpt
                w = Point{Int64}(
                    round(getx(best_intersection_point)),
                    round(gety(best_intersection_point))
                )

                # We are going to replace `best_node`
                # need to do all of the following...
                last_node = best_node.next
                n0 = best_node.prev

                first_node = InteriorCutNode(best_node.point)
                first_node.prev = n0
                n0.next = first_node
                n0, p0 = first_node, w

                for r in (m:length(hole_contour), 1:m)
                    for i in r
                        n = InteriorCutNode(p0)
                        n.prev = n0
                        n0.next = n
                        push!(itree, IntervalValue(xinterval(segment(n0))..., n0))
                        n0, p0 = n, hole_contour[i]
                    end
                end

                n = InteriorCutNode(p0)
                n.prev = n0
                n0.next = n
                push!(itree, IntervalValue(xinterval(segment(n0))..., n0))
                n0, p0 = n, w

                n = InteriorCutNode(p0)
                n.prev = n0
                n0.next = n
                push!(itree, IntervalValue(xinterval(segment(n0))..., n0))

                n.next = last_node
                last_node.prev = n
                push!(itree, IntervalValue(xinterval(segment(n))..., n))

                # serving the purpose of delete!(itree, best_node)
                best_node.prev = best_node
                best_node.next = best_node

                # in case we deleted node1...
                if best_node === node1
                    node1 = first_node
                end
            end
        end
        n = node1
        p = Point{Int}[]
        while n.next != n
            push!(p, n.point)
            n = n.next
        end
        push!(outpolys, Polygon(reinterpret(Point{T}, p)))
    end
    return outpolys
end

xinterval(l::LineSegment) = (l.p0.x, l.p1.x)
yinterval(l::LineSegment) = swap((l.p0.y, l.p1.y))
swap(x) = x[1] > x[2] ? (x[2], x[1]) : x

"""
    gridpoints_in_polygon(poly::AbstractArray{<:AbstractPolygon},
        dx::Coordinate, dy::Coordinate; b=nothing)

Return a `BitArray` for the gridpoints in `b` with `true` for gridpoints in `poly`.

Only grid points in the bounding box `b` will be considered; if `b` is `nothing`, then
bounds(poly) is used. `dx` and `dy` are the distances between adjacent points on the
rectangular grid. The grid points represented by the `BitArray` start from the lower left
point `p0 = (m*dx, n*dy)` with `m` and `n` integers and `p0` lying in `b`.

All polygons should have the same orientation (clockwise or counterclockwise).
A mix (for example to represent "holes") may not give the desired behavior on
polygon or hole edges.
"""
function gridpoints_in_polygon(
    poly::AbstractArray{<:AbstractPolygon},
    dx::Coordinate,
    dy::Coordinate;
    b=nothing
)
    isnothing(b) && (b = bounds(poly))
    # Prepare grid
    grid_x = (Int(ceil(b.ll.x / dx)):Int(floor(b.ur.x / dx))) * dx
    grid_y = (Int(ceil(b.ll.y / dy)):Int(floor(b.ur.y / dy))) * dy

    return gridpoints_in_polygon(poly, grid_x, grid_y)
end

"""
    gridpoints_in_polygon(poly::AbstractArray{<:AbstractPolygon},
        grid_x::AbstractArray, grid_y::AbstractArray)

Return a `BitArray` with `true` for points lying in some polygon in `poly`.

The `BitArray` values correspond to points `(x, y)` with `x ∈ grid_x`, `y ∈ grid_y`,
starting from the lower left.

All polygons should have the same orientation (clockwise or counterclockwise).
A mix (for example to represent "holes") may not give the desired behavior on
polygon or hole edges.
"""
function gridpoints_in_polygon(
    poly::AbstractArray{<:AbstractPolygon{T}},
    grid_x::AbstractArray,
    grid_y::AbstractArray
) where {T}
    in_poly = falses(length(grid_x), length(grid_y))
    isempty(poly) && return in_poly

    fT = float(T)
    grid_x = convert.(fT, sort(grid_x))
    grid_y = convert.(fT, sort(grid_y))

    # Segment endpoints
    p0s = points.(poly)
    p1s = map(p0s) do p_poly
        return view(p_poly, ((1:length(p_poly)) .% length(p_poly)) .+ 1)
    end
    # Polygon edges as point pairs
    edges = zip(Iterators.flatten(p0s), Iterators.flatten(p1s))
    edge_ys = map(edges) do (p0, p1)
        return (p0.y, p1.y)
    end

    # y-IntervalValues with (y0, y1) => edge (where y0 <= y1)
    edge_iv = sort!( # IntervalTree requires sorted IntervalValues
        map(zip(edge_ys, edges)) do (ys, edge)
            return IntervalValue{fT, Tuple{Point{T}, Point{T}}}(minimum(ys), maximum(ys), edge)
        end
    )
    edge_tree = IntervalTrees.IntervalMap{fT, Tuple{Point{T}, Point{T}}}(edge_iv)

    # For each grid y value, look at the edges containing that value
    grid_count = zeros(Int32, length(grid_x))
    for (iy, y) in enumerate(grid_y)
        for i2 in intersect(edge_tree, (y, y))
            edge = i2.value
            # Count horizontal edges only if grid point lies on them
            if last(edge).y == first(edge).y
                if first(edge).y == y
                    in_poly[
                        findall(
                            in(
                                ustrip(min(first(edge).x, last(edge).x)) ..
                                ustrip(max(first(edge).x, last(edge).x))
                            ),
                            ustrip.(grid_x)
                        ),
                        iy
                    ] .= true
                end
                continue
            end
            # This counts as one edge to the right:
            # .     |_
            #         |
            first(i2) == y && continue
            # Find x of edge at y
            x =
                first(edge).x +
                (last(edge).x - first(edge).x) * (y - first(edge).y) /
                (last(edge).y - first(edge).y)
            ix = findfirst(grid_x .>= x) # The first index to the right of x
            x_right_minidx = isnothing(ix) ? length(grid_x) + 1 : ix
            # If the grid point lies on the edge, it's in the polygon
            x_right_minidx <= length(grid_x) &&
                x == grid_x[x_right_minidx] &&
                (in_poly[x_right_minidx, iy] = true)
            # Add edge count to all grid points to the left (sign depending on direction)
            s = sign(last(edge).y - first(edge).y)
            @. grid_count[1:(x_right_minidx - 1)] = grid_count[1:(x_right_minidx - 1)] + s
        end
        @. in_poly[:, iy] = (grid_count != 0) || in_poly[:, iy]
        grid_count .= 0
    end

    return in_poly
end

"""
    getkey(n::Clipper.PolyNode)

Given a `Clipper.PolyNode` compute the key that maps to its location within its
corresponding tree.
"""
function getkey(n::Clipper.PolyNode)
    node = n
    parent = n.parent
    key = Int[]
    # discover indices from leaf to root
    while parent != node
        push!(key, findfirst(x -> x == node, children(parent)))
        node = parent
        parent = parent.parent
    end
    reverse!(key) # store indices from root to leaf
    return key
end

"""
    struct StyleDict{S} <: GeometryEntityStyle where {S}
        styles::Dict{Vector{Int}, GeometryEntityStyle},
        default::S
    end

Style used for applying differing styles to different Polygons at different levels within a
`ClippedPolygon` or `CurvilinearRegion`. Styles are stored by the sequence of child indices
required to find the corresponding `Clipper.PolyNode` within the `ClippedPolygon`. For a
`CurvilinearRegion` only dictionaries of depth 2 (a single parent and one set of holes) are valid.
"""
struct StyleDict{S} <: GeometryEntityStyle where {S}
    styles::Dict{Vector{Int}, GeometryEntityStyle}
    default::S
    StyleDict{S}(s::Dict{Vector{Int}, GeometryEntityStyle}, d) where {S} = new(s, d)
end
StyleDict() = StyleDict{DeviceLayout.Plain}(
    Dict{Vector{Int}, GeometryEntityStyle}(),
    DeviceLayout.Plain()
)
StyleDict(d::S) where {S <: GeometryEntityStyle} =
    StyleDict{S}(Dict{Vector{Int}, GeometryEntityStyle}(), d)
DeviceLayout.Polygons.StyleDict(e::DeviceLayout.GeometryEntity, a::Any) =
    MethodError(DeviceLayout.Polygons.StyleDict, e, a)

"""
    addstyle!(d::StyleDict, s::GeometryEntityStyle, indices::Vector{Int})
    addstyle!(d::StyleDict, s::GeometryEntityStyle, indices::Int...)
    addstyle!(d::StyleDict, s::GeometryEntityStyle, node::Clipper.PolyNode)

Insert a `GeometryEntityStyle` into a `StyleDict` at location specified by `indices` or by a
particular `node` in the tree defined by a `ClippedPolygon`.
"""
function addstyle!(d::StyleDict, s::GeometryEntityStyle, indices::Vector{Int})
    return d.styles[indices] = s
end
addstyle!(d::StyleDict, s::GeometryEntityStyle, indices::Int...) =
    addstyle!(d, s, [indices...])
addstyle!(d::StyleDict, s::GeometryEntityStyle, node::Clipper.PolyNode) =
    addstyle!(d, s, getkey(n))

# Accessors for a StyleDict
Base.getindex(d::StyleDict, indices::Vector{Int}) = get(d.styles, indices, d.default)
Base.getindex(d::StyleDict, indices::Int...) = d[collect(indices)]
Base.getindex(d::StyleDict, n::Clipper.PolyNode) = d[getkey(n)]
Base.setindex!(d::StyleDict, s::GeometryEntityStyle, indices::Vector{Int}) =
    addstyle!(d, s, indices)
Base.setindex!(d::StyleDict, s::GeometryEntityStyle, indices::Int...) =
    addstyle!(d, s, indices...)
Base.setindex!(d::StyleDict, s::GeometryEntityStyle, n::Clipper.PolyNode) =
    addstyle!(d, s, getkey(n))

function to_polygons(p::ClippedPolygon, s::StyleDict; kwargs...)
    p = deepcopy(p) # deepcopy so as not to modify
    function stylenode!(n::Clipper.PolyNode)
        n.contour = points.(to_polygons(Polygon(n.contour), s[n]))
        return stylenode!.(n.children)
    end
    stylenode!.(p.tree.children)
    return to_polygons(p; kwargs...)
end

function transform(d::StyleDict, f::Transformation)
    newdict = StyleDict(transform(d.default, f))
    for (idx, s) in pairs(d.styles)
        newdict[idx] = transform(s, f)
    end
    return newdict
end

end # module
