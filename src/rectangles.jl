module Rectangles

using ..Points
import Base: +, -, *, /, copy, ==, convert, isapprox
import DeviceLayout
import DeviceLayout: AbstractPolygon, Coordinate, GDSMeta, Meta
import DeviceLayout: bounds, center, centered, lowerleft, upperright, RotationPi
import Unitful: ustrip
import StaticArrays

export Rectangle
export height
export width
export isproper

"""
    struct Rectangle{T} <: AbstractPolygon{T}
        ll::Point{T}
        ur::Point{T}
        function Rectangle(a,b)
            # Ensure ll is lower-left, ur is upper-right.
            ll = Point(a.<b) .* a + Point(b.<a) .* b
            ur = Point(a.<b) .* b + Point(b.<a) .* a
            new(ll,ur)
        end
    end

A rectangle, defined by opposing lower-left and upper-right corner coordinates.
Lower-left and upper-right are guaranteed to be such by the inner constructor.
"""
struct Rectangle{T} <: AbstractPolygon{T}
    ll::Point{T}
    ur::Point{T}
    function Rectangle{T}(a, b) where {T}
        # Ensure ll is lower-left, ur is upper-right.
        ll = Point(a .<= b) .* a + Point(b .< a) .* b
        ur = Point(a .<= b) .* b + Point(b .< a) .* a
        return new{T}(ll, ur)
    end
end

"""
    Rectangle(ll::Point, ur::Point)

Convenience constructor for `Rectangle` objects.
"""
Rectangle(ll::Point, ur::Point) = rectangle(promote(ll, ur)...)
rectangle(ll::Point{T}, ur::Point{T}) where {T <: Coordinate} = Rectangle{T}(ll, ur)

"""
    Rectangle(width, height)

Constructs `Rectangle` objects by specifying the width and height rather than
the lower-left and upper-right corners.

The rectangle will sit with the lower-left corner at the origin. With centered
rectangles we would need to divide width and height by 2 to properly position.
If we wanted an object of `Rectangle{Int}` type, this would not be possible
if either `width` or `height` were odd numbers. This definition ensures type
stability in the constructor.

`Rectangle` has the special importance of being the return type of `bounds`.
"""
Rectangle(width, height) = Rectangle(Point(zero(width), zero(height)), Point(width, height))

convert(::Type{Rectangle{T}}, x::Rectangle) where {T} = Rectangle{T}(x.ll, x.ur)
convert(::Type{DeviceLayout.GeometryEntity{T}}, x::Rectangle) where {T} =
    convert(Rectangle{T}, x)

copy(p::Rectangle) = Rectangle(p.ll, p.ur)

==(r1::Rectangle, r2::Rectangle) = (r1.ll == r2.ll) && (r1.ur == r2.ur)

isapprox(r1::Rectangle, r2::Rectangle; kwargs...) =
    isapprox(r1.ll, r2.ll; kwargs...) && isapprox(r1.ur, r2.ur; kwargs...)

"""
    width(r::Rectangle)

Return the width of a rectangle.
"""
width(r::Rectangle) = getx(r.ur) - getx(r.ll)

"""
    height(r::Rectangle)

Return the height of a rectangle.
"""
height(r::Rectangle) = gety(r.ur) - gety(r.ll)

"""
    isproper(r::Rectangle)

Return `true` if the rectangle has a non-zero area. Otherwise, returns `false`.
Note that the upper-right and lower-left corners are enforced to be the `ur`
and `ll` fields of a `Rectangle` by the inner constructor.
"""
isproper(r::Rectangle) = (r.ur.x != r.ll.x) && (r.ur.y != r.ll.y)

"""
    bounds(r::Rectangle)

No-op (just returns `r`).
"""
bounds(r::Rectangle) = r

"""
    lowerleft(r::Rectangle)

Return the lower-left corner of a rectangle (Point object).
"""
lowerleft(r::Rectangle) = r.ll

"""
    upperright(r::Rectangle)

Return the upper-right corner of a rectangle (Point object).
"""
upperright(r::Rectangle) = r.ur

DeviceLayout.translate(r::Rectangle, p::Point) = Rectangle(r.ll + p, r.ur + p)
DeviceLayout.magnify(r::Rectangle, a::Real) = Rectangle(*(r.ll, a), *(r.ur, a))
function DeviceLayout.rotate90(r::Rectangle, n::Int)
    p1 = RotationPi(n / 2)(r.ll)
    p2 = RotationPi(n / 2)(r.ur)
    return Rectangle(p1, p2)
end # non-90-degree rotations convert rectangle to a polygon; see polygons.jl
DeviceLayout.reflect_across_xaxis(r::Rectangle) =
    Rectangle(Point(r.ll.x, -r.ur.y), Point(r.ur.x, -r.ll.y))

ustrip(r::Rectangle) = Rectangle(ustrip(r.ll), ustrip(r.ur))

end
