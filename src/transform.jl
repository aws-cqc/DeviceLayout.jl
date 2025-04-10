module Transformations

import LinearAlgebra: det, norm, I
import CoordinateTransformations
import CoordinateTransformations:
    LinearMap,
    AffineMap,
    Translation,
    ∘,
    compose,
    recenter,
    IdentityTransformation,
    AbstractAffineMap,
    Transformation,
    @SMatrix
import Unitful: °, uconvert, NoUnits
import StaticArrays

import DeviceLayout: Coordinate, Point, getx, gety

export Reflection,
    Rotation, RotationPi, ScaledIsometry, Translation, XReflection, YReflection
export ∘,
    compose,
    isapprox_angle,
    isapprox_cardinal,
    mag,
    origin,
    preserves_angles,
    rotated_direction,
    rotation,
    xrefl

## Affine transformations

# Translation already defined for 2D by the CoordinateTransformations package
# Still need 2D rotation, reflections.

"""
    Rotation(Θ; around_pt=nothing)

Construct a rotation about the origin or `around_pt`. Units accepted (no units ⇒ radians).
"""
function Rotation(Θ; around_pt=nothing)
    rot = LinearMap(@SMatrix [cos(Θ) -sin(Θ); sin(Θ) cos(Θ)])
    isnothing(around_pt) && return rot
    return recenter(rot, around_pt)
end

"""
    RotationPi(Θ_over_pi=1; around_pt=nothing)

Construct a rotation about the origin or `around_pt`, with rotation in units of `pi` (`180°`).

This may be useful if you know your rotation will be a multiple of 90° but not necessarily
which one, since it can be slightly more precise than `Rotation` (as `sincospi` is to `sincos`).
"""
function RotationPi(Θ_over_pi=1; around_pt=nothing)
    s, c = sincospi(Θ_over_pi)
    rot = LinearMap(@SMatrix [c -s; s c])
    isnothing(around_pt) && return rot
    return recenter(rot, around_pt)
end

"""
    XReflection()

Construct a reflection about the x-axis (y-coordinate changes sign).

Example:

```jldoctest
julia> trans = XReflection()
LinearMap([1 0; 0 -1])

julia> trans(Point(1, 1))
2-element Point{Int64} with indices SOneTo(2):
  1
 -1
```
"""
XReflection() = LinearMap(@SMatrix [1 0; 0 -1])

"""
    YReflection()

Construct a reflection about the y-axis (x-coordinate changes sign).

Example:

```jldoctest
julia> trans = YReflection()
LinearMap([-1 0; 0 1])

julia> trans(Point(1, 1))
2-element Point{Int64} with indices SOneTo(2):
 -1
  1
```
"""
YReflection() = LinearMap(@SMatrix [-1 0; 0 1])

"""
    Reflection(α; through_pt=nothing)
    Reflection(vec::Point; through_pt=nothing)
    Reflection(p1::Point, p2::Point)

Construct a reflection across a line.

The line can be specified by two points `p1, p2` or by a direction and point `through_pt`
the line passes through. The direction can be a vector or an angle made with the positive x
axis (units accepted; no units => radians), and the `through_pt` is the origin by default.
"""
function Reflection(α; through_pt=nothing)
    s2a, c2a = sincos(2 * α)
    refl = LinearMap(StaticArrays.@SMatrix [c2a s2a; s2a -c2a])
    isnothing(through_pt) && return refl
    return recenter(refl, through_pt)
end
Reflection(vec::Point; through_pt=nothing) =
    Reflection(atan(gety(vec), getx(vec)); through_pt=through_pt)
Reflection(p1::Point, p2::Point) = Reflection(p2 - p1; through_pt=p1)

"""
    origin(f::Transformation)

Return the transformed origin if it is translated, or `nothing` otherwise.

It's necessary to return `nothing` rather than a `zero(Point{T})` if there's no translation,
because such transformations (e.g., `LinearMap`s) may not supply a coordinate type `T`.
"""
origin(f::Union{Translation, AffineMap}) = Point(f.translation)
origin(f) = nothing # We don't have a coordinate type

"""
    xrefl(f::Transformation)

Return `true` if `f` applies a reflection (has negative determinant) and `false` otherwise.
"""
xrefl(f::Union{Translation, IdentityTransformation}) = false
xrefl(f) = det(f.linear) < 0

"""
    mag(f::Translation)

Return the magnification (uniform scaling factor) for `f`, if it is well defined.

Throws a `DomainError` if `f` does not preserve angles ("scaling" depends on direction).
"""
mag(f::Union{Translation, IdentityTransformation}) = 1
mag(f) = begin
    preserves_angles(f) || throw(
        DomainError(
            f,
            "Transformation does not preserve angles, so it doesn't apply a well-defined magnification"
        )
    )
    return norm(f.linear[:, 1])
end

"""
    rotation(f::Transformation; α0=0)

Return the change in angle when applying `f` to a line originally at `α0` CCW from the `x`-axis.

By default, `α0` is taken to be `0`, and the result is equivalent to the rotation when
decomposing the linear part of `f` into reflection across the `x`-axis followed by rotation.

Units are accepted for `α0` (no units => radians).

If `f` does not preserve angles, a `DomainError` is thrown.
"""
rotation(f; α0=0) = begin
    preserves_angles(f) || throw(
        DomainError(
            f,
            "Transformation does not preserve angles, so it doesn't apply a well-defined rotation"
        )
    )
    rx = atan(f.linear[2, 1], f.linear[1, 1])
    return xrefl(f) ? rx - 2 * α0 : rx
end
rotation(f::Union{Translation, IdentityTransformation}; α0=0) = 0

"""
    preserves_angles(f::Transformation)

Return `true` if `f`` is angle-preserving (has equal-magnitude eigenvalues) and `false` otherwise.

Uses approximate equality to allow for floating point imprecision.
"""
preserves_angles(f::Union{Translation, IdentityTransformation}) = true
function preserves_angles(f)
    return abs.(f.linear * f.linear' / det(f.linear)) ≈ I
end

"""
    rotated_direction(angle, trans)

Return the new direction that `angle` maps to under the transformation `trans`.
"""
function rotated_direction(angle, f)
    return angle + rotation(f, α0=angle)
end

###### Angle testing
"""
    isapprox_angle(α1, α2; atol=1e-9)

Test whether angles `α1` and `α2` are approximately equivalent.

Units may be used for one or both angles (no units => radians).
"""
function isapprox_angle(α1, α2; atol=1e-9, kwargs...)
    return isapprox(
        rem2pi(uconvert(NoUnits, α2 - α1), RoundNearest),
        0;
        atol=uconvert(NoUnits, atol),
        kwargs...
    )
end

"""
    isapprox_cardinal(α; atol=1e-9)

Test whether `α` is approximately a cardinal direction (0°, 90°, 180°, or 270°).

Units may be used. If `α` has no units, it is treated as an angle in radians.
"""
function isapprox_cardinal(α; atol=1e-9, kwargs...)
    return isapprox(
        rem2pi(uconvert(NoUnits, 4 * α), RoundNearest),
        0;
        atol=uconvert(NoUnits, 4 * atol),
        kwargs...
    )
end

###### Angle-preserving transform - extend CoordinateTransformations
"""
    struct ScaledIsometry{T<:Union{Point, Nothing}} <: AbstractAffineMap
    ScaledIsometry(origin=nothing, rotation=0°, xrefl=false, mag=1.0)

A coordinate transformation that preserves angles.

The equivalent transformation of `f::ScaledIsometry` is
the composition of the following transformations, ordered with reflection applied first:

 1. If `xrefl(f)` is `true`, a reflection across the `x`-axis
 2. Rotation by `rotation(f)`
 3. Magnification by `mag(f)`
 4. Translation by `origin(f)`

May be also be constructed as

```julia
ScaledIsometry(f::Transformation) = ScaledIsometry(origin(f), rotation(f), xrefl(f), mag(f))
```

but a `DomainError` will be thrown if `f` is not a scaled isometry (does not preserve angles).

`Transformation` compositions (with `compose` or `∘`) involving a `ScaledIsometry` will
return a `ScaledIsometry` if the other transformation also preserves angles.
"""
struct ScaledIsometry{T <: Union{<:Point, Nothing}} <: AbstractAffineMap
    origin::T
    rotation::typeof(1.0°)
    xrefl::Bool
    mag::Float64
    # If mag is negative, add a pi rotation and use abs(mag)
    function ScaledIsometry{T}(origin, rotation, xrefl, mag) where {T}
        mag > 0 && return new{T}(origin, rotation, xrefl, mag)
        return new{T}(origin, rotation + 180°, xrefl, abs(mag))
    end
end
ScaledIsometry(origin=nothing, rotation=0°, xrefl=false, mag=1.0) =
    ScaledIsometry{typeof(origin)}(origin, rotation, xrefl, mag)
ScaledIsometry(f::Transformation) = ScaledIsometry(origin(f), rotation(f), xrefl(f), mag(f))
ScaledIsometry(f::ScaledIsometry) = f
preserves_angles(::ScaledIsometry) = true

"""
    rounding_safe(precision, f::Transformation)

`true` when applying `f` gives the same results before or after rounding to `precision`.

Specifically, if `f` preserves angles, translates by integer `precision`, scales by an
integer multiplier, and rotates by a multiple of 90°, it is "rounding safe".

`precision` should either be an integer type like `Int32` or unitful type like `typeof(1nm)`.
"""
function rounding_safe(precision, f::ScaledIsometry)
    return (
        (isnothing(f.origin) || f.origin ≈ round(precision, f.origin)) &&
        isinteger(f.mag) &&
        isapprox_cardinal(f.rotation)
    )
end
rounding_safe(precision, f::Transformation) =
    preserves_angles(f) && rounding_safe(precision, ScaledIsometry(f))

### Our methods
origin(f::ScaledIsometry) = f.origin
rotation(f::ScaledIsometry; α0=0°) = xrefl(f) ? f.rotation - 2 * α0 : f.rotation
xrefl(f::ScaledIsometry) = f.xrefl
mag(f::ScaledIsometry) = isinteger(f.mag) ? Int(f.mag) : f.mag

# Fall back to generic affine representation, mainly for points, tuples, SVector
(f::ScaledIsometry{T})(x) where {T} = affine(f)(x)

"""
    affine(sty::ScaledIsometry)
    affine(origin, rot, xrefl, mag)

Return the `CoordinateTransformations.AffineMap` or `LinearMap` corresponding to the input.
"""
affine(f::ScaledIsometry) = affine(origin(f), rotation(f), xrefl(f), mag(f))
affine(f::ScaledIsometry{Nothing}) = linearmap(rotation(f), xrefl(f), mag(f))
affine(origin, rot, xrefl, mag) = Translation(origin) ∘ linearmap(rot, xrefl, mag)
affine(::Nothing, rot, xrefl, mag) = linearmap(rot, xrefl, mag)

function linearmap(rot, xrefl, mag)
    rd = uconvert(°, rot) # so for example cos(pi/2) is exactly zero
    sgn = xrefl ? -1 : 1
    lin = LinearMap(
        StaticArrays.@SMatrix [
            mag*cos(rd) -mag*sgn*sin(rd)
            mag*sin(rd)  mag*sgn*cos(rd)
        ]
    )
    return lin
end

### CoordinateTransformations methods
# Apply f2 then f1 as single ScaledIsometry
CoordinateTransformations.compose(f1::ScaledIsometry, f2::ScaledIsometry{Nothing}) =
    ScaledIsometry(
        origin(f1),
        rotated_direction(rotation(f2), f1), # Angle the x-axis ends up at
        xrefl(f1) ⊻ xrefl(f2),
        mag(f1) * mag(f2)
    )
CoordinateTransformations.compose(f1::ScaledIsometry, f2::ScaledIsometry) = ScaledIsometry(
    f1(origin(f2)),
    rotated_direction(rotation(f2), f1),
    xrefl(f1) ⊻ xrefl(f2),
    mag(f1) * mag(f2)
)
CoordinateTransformations.compose(f1::ScaledIsometry, f2::Translation) =
    ScaledIsometry(f1(origin(f2)), f1.rotation, f1.xrefl, f1.mag)
CoordinateTransformations.compose(f1::Translation, f2::ScaledIsometry{Nothing}) =
    ScaledIsometry(origin(f1), f2.rotation, f2.xrefl, f2.mag)
CoordinateTransformations.compose(f1::Translation, f2::ScaledIsometry) =
    ScaledIsometry(f1(origin(f2)), f2.rotation, f2.xrefl, f2.mag)
function CoordinateTransformations.compose(f1::ScaledIsometry, f2::Transformation)
    preserves_angles(f2) && return compose(f1, ScaledIsometry(f2))
    return compose(affine(f1), f2)
end
function CoordinateTransformations.compose(f1::Transformation, f2::ScaledIsometry)
    preserves_angles(f1) && return compose(ScaledIsometry(f1), f2)
    return compose(f1, affine(f2))
end
CoordinateTransformations.compose(::IdentityTransformation, f2::ScaledIsometry) = f2
CoordinateTransformations.compose(f1::ScaledIsometry, ::IdentityTransformation) = f1

CoordinateTransformations.transform_deriv(f::ScaledIsometry, x) =
    transform_deriv(affine(f), x)
CoordinateTransformations.transform_deriv_params(f::ScaledIsometry, x) =
    transform_deriv_params(affine(f), x)

### Base methods
Base.:(==)(t1::Transformation, t2::ScaledIsometry) = (t1 == affine(t2))
Base.:(==)(t1::ScaledIsometry, t2::Transformation) = (affine(t1) == t2)
function Base.:(==)(t1::ScaledIsometry, t2::ScaledIsometry)
    z1 = isnothing(t1.origin) || iszero(t1.origin)
    z2 = isnothing(t2.origin) || iszero(t2.origin)
    return ((z1 && z2) || t1.origin == t2.origin) &&
           t1.rotation % 360° == t2.rotation % 360° &&
           t1.xrefl == t2.xrefl &&
           t1.mag == t2.mag
end

function Base.convert(
    ::Type{ScaledIsometry{Point{S}}},
    f::ScaledIsometry
) where {S <: Coordinate}
    orig = isnothing(f.origin) ? zero(Point{S}) : convert(Point{S}, f.origin)
    return ScaledIsometry(orig, f.rotation, f.xrefl, f.mag)
end
Base.convert(::Type{ScaledIsometry{Point{S}}}, f::Transformation) where {S <: Coordinate} =
    convert(ScaledIsometry{Point{S}}, ScaledIsometry(f))

Base.isapprox(t1::Transformation, t2::ScaledIsometry; kwargs...) =
    isapprox(t1, affine(t2), kwargs...)
Base.isapprox(t1::ScaledIsometry, t2::Transformation; kwargs...) =
    isapprox(affine(t1), t2; kwargs...)
function Base.isapprox(t1::ScaledIsometry, t2::ScaledIsometry; kwargs...)
    z1 = isnothing(t1.origin) || isapprox(t1.origin, zero(t1.origin); kwargs...)
    z2 = isnothing(t2.origin) || isapprox(t2.origin, zero(t2.origin); kwargs...)
    z1 ⊻ z2 && return false
    return ((z1 && z2) || t1.origin ≈ t2.origin) &&
           isapprox_angle(t1.rotation, t2.rotation) &&
           t1.xrefl == t2.xrefl &&
           t1.mag ≈ t2.mag
end

Base.inv(f::ScaledIsometry{Nothing}) =
    ScaledIsometry(nothing, f.xrefl ? f.rotation : -f.rotation, f.xrefl, inv(f.mag))
Base.inv(f::ScaledIsometry) =
    ScaledIsometry(nothing, f.xrefl ? f.rotation : -f.rotation, f.xrefl, inv(f.mag)) ∘
    Translation(-f.origin)

function as_string(f::ScaledIsometry)
    s = String[]
    !isnothing(f.origin) && !iszero(f.origin) && push!(s, "Translation($(f.origin))")
    f.mag != 1 && push!(s, "Magnification($(f.mag))")
    !iszero(f.rotation % 360°) && push!(s, "Rotation($(f.rotation))")
    f.xrefl && push!(s, "XReflection()")
    isempty(s) && return "ScaledIsometry(IdentityTransformation)"
    return join(s, " ∘ ")
end

Base.show(io::IO, trans::ScaledIsometry) = print(io, as_string(trans))

end # module
