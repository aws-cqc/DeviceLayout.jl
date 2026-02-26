```@meta
DocTestSetup = quote
    using Unitful, DeviceLayout
    using Unitful: °
end
```

# Coordinate Transformations

Affine coordinate transformation functionality is largely provided by the
[`CoordinateTransformations.jl`](https://github.com/FugroRoames/CoordinateTransformations.jl)
package. DeviceLayout.jl also provides convenience constructors for `Reflection`
across a specified line and `Rotation` around a specified point.

Transformations in DeviceLayout.jl are usually represented with the `ScaledIsometry`
type, which represents transformations restricted to those that preserve angles. 

Transformations can be inverted with `inv` and composed with `compose` or the infix operator `∘` (which can be entered with `\circ` followed by `Tab`).

See [Transformations API](@ref api-transformations) for the full set of constructors, as well as functions for applying simple transformations, inspecting transformations, and aligning geometries by their bounding boxes.

## Applying transformations

Coordinate transformations can be applied to any `AbstractGeometry` object, creating a new
object with its coordinates transformed. Here's an example with a `Rectangle`:

```jldoctest
julia> r = Rectangle(2, 1)
Rectangle{Int64}((0,0), (2,1))

julia> trans = Translation(10, 10)
Translation(10, 10)

julia> trans = Rotation(90°) ∘ trans
AffineMap([0.0 -1.0; 1.0 0.0], [-10.0, 10.0])

julia> trans(r)
Rectangle{Float64}((-11.0,10.0), (-10.0,12.0))
```

## Implementation details

Geometry objects implement specializations of the [`transform`](@ref) function (and optionally other transformation interface functions) that determine how
they behave under transformations.

This allows special handling for certain types paired with certain transformations.
For example, a `Rectangle` is by definition axis-aligned. If a transformed `Rectangle`
would still be axis-aligned (for example, the result of a translation or 90° rotation),
the result will still be a `Rectangle`, as in the example above; otherwise, it will be a `Polygon`. Here is the full set of transformation specializations for `Rectangle`:

```julia
DeviceLayout.translate(r::Rectangle, p::Point) = Rectangle(r.ll + p, r.ur + p)
DeviceLayout.magnify(r::Rectangle, a::Real) = Rectangle(*(r.ll, a), *(r.ur, a))
function DeviceLayout.rotate90(r::Rectangle, n::Int)
    p1 = RotationPi(n / 2)(r.ll)
    p2 = RotationPi(n / 2)(r.ur)
    return Rectangle(p1, p2)
end # non-90-degree rotations convert rectangle to a polygon; see polygons.jl
DeviceLayout.reflect_across_xaxis(r::Rectangle) =
    Rectangle(Point(r.ll.x, -r.ur.y), Point(r.ur.x, -r.ll.y))

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
```

"Chiral" geometry objects (those that can be either left- or right-handed)
may also implement special handling for transformations that include a reflection (which
changes handedness).
