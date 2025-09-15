"""
    abstract type Hook{T} <: AbstractGeometry{T}

Contains information describing how one component can attach to others.
"""
abstract type Hook{T} <: AbstractGeometry{T} end
getp(h::Hook) = h.p

"""
    PointHook(p::Point, in_direction)
    PointHook(x, y, in_direction)

`Hook` defined by a point and a direction (an angle CCW from the positive x axis).

Attaching two `PointHook`s will match the points, oriented so the angles
are opposite. By convention, hooks point inward.
"""
struct PointHook{T} <: Hook{T}
    p::Point{T}
    in_direction::typeof(1.0°)
end
PointHook(p, in_direction) = PointHook{eltype(p)}(p, in_direction) # Otherwise can't infer if in_direction is in degrees
PointHook(x, y, in_direction) = PointHook(Point(promote(x, y)...), in_direction)

"""
    in_direction(h::Hook)

The inward-pointing direction stored by the PointHook (angle CCW from the positive x axis)
"""
in_direction(h::Hook) = h.in_direction

"""
    out_direction(h::PointHook)

The outward-pointing angle opposite to the direction stored by the PointHook
"""
out_direction(h::Hook) = in_direction(h) + 180°

"""
    compass(;p0=Point(0μm, 0μm))

An 8-point compass of `PointHook`s at `p0`.

The `NamedTuple` `(:east = PointHook(p0, 0°), :northeast = PointHook(p0, 45°), ...`
for all cardinal and primary intercardinal directions (every 45°). (The `in_direction` of
each hook points in its compass direction.)
"""
function compass(prefix=""; p0=Point(0μm, 0μm))
    α = (0°):(45°):(315°)
    names_str =
        prefix .* (
            "east",
            "northeast",
            "north",
            "northwest",
            "west",
            "southwest",
            "south",
            "southeast"
        )
    names = Symbol.(names_str)
    return NamedTuple{names}(PointHook.(Ref(p0), α))
end

"""
    transformation(h1::Hook, h2::Hook)

Return a `CoordinateTransformation` to align `h2` to `h1`.

Given hooks `h1, h2` relative to  `CoordinateSystem`s `h1cs, h2cs` respectively, if you
reference `h2cs` inside `h1cs` with `push!(h1cs.refs, sref(h2cs, origin, rot=rotation, xrefl=xrefl))`,
then relative to `h1cs`, `h2` will lie on top of `h1` with its `in_direction` pointing
opposite to that of `h1` (and matching handedness, if applicable).
"""
function transformation(h1::PointHook, h2::PointHook)
    rot = Rotation(180° + (h1.in_direction - h2.in_direction), around_pt=h1.p)
    return rot ∘ Translation(h1.p - h2.p)
end

DeviceLayout.transform(x::PointHook, f::Transformation) =
    PointHook(f(x.p), rotated_direction(in_direction(x), f))
# Bit of a hack to treat hook vector like single hook with this syntax
(f::ScaledIsometry{T})(v::Vector{<:Hook}) where {T} = f.(v)

"""
    HandedPointHook{T} <: Hook{T}
        h::PointHook{T}
        right_handed::Bool

A `PointHook` augmented with handedness.

In addition to translation and rotation, which are used to fuse one `PointHook` to another,
a `HandedPointHook` being fused to another `HandedPointHook` will apply a reflection if
necessary to match its handedness.
"""
struct HandedPointHook{T} <: Hook{T}
    h::PointHook{T}
    right_handed::Bool
end
HandedPointHook(h::PointHook) = HandedPointHook(h, true)
HandedPointHook(p0::Point, in_direction) =
    HandedPointHook(PointHook(p0, in_direction), true)
HandedPointHook(p0::Point, in_direction, rh::Bool) =
    HandedPointHook(PointHook(p0, in_direction), rh)
HandedPointHook(x0::Coordinate, y0::Coordinate, in_direction, right_handed=true) =
    HandedPointHook(PointHook(x0, y0, in_direction), right_handed)

function transformation(h1::HandedPointHook, h2::HandedPointHook)
    f = transformation(h1.h, h2.h)
    h1.right_handed == h2.right_handed && return f
    return Reflection(h1.in_direction; through_pt=h1.p) ∘ f
end
transformation(h1::PointHook, h2::HandedPointHook) = transformation(h1, h2.h)
transformation(h1::HandedPointHook, h2::PointHook) = transformation(h1.h, h2)

function Base.getproperty(h::HandedPointHook, s::Symbol)
    if s in (:p, :in_direction)
        return getfield(h.h, s)
    else
        return getfield(h, s)
    end
end

in_direction(h::HandedPointHook) = h.h.in_direction
function Base.propertynames(h::HandedPointHook)
    return vcat(fieldnames(h), fieldnames(h.h))
end

DeviceLayout.transform(x::HandedPointHook, f::Transformation) =
    HandedPointHook(f(x.h), xrefl(f) ⊻ x.right_handed)

Base.keys(h::Hook) = error(
    "No method matching keys(::Hook). You might be missing a leading semicolon in a `hooks` method returning a single hook: `return (hookname=h)` should be `return (; hookname=h)`."
)
