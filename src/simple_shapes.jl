#
# Note: further additions to this 'library' of shapes should
# be entered in alphabetical order, neatly documented, and added
# to the package documentation. In addition, you should also make
# sure your new function(s) are being exported by the top-level
# DeviceLayout module.
#
module SimpleShapes

using DeviceLayout
using DeviceLayout: Coordinate, AbstractCoordinateSystem
import DeviceLayout: Meta, GDSMeta
import DeviceLayout: cm, μm, nm
using Unitful: NoUnits, ustrip, unit

export circular_arc,
    draw_pixels,
    hatching_unit,
    radial_cut,
    radial_stub,
    simple_cross,
    simple_ell,
    simple_tee,
    checkerboard!,
    grating!,
    interdigit!

"""
    circular_arc(θ, r::T, tolerance; θ_0=0, center=zero(Point{T})) where
                {T <: Coordinate}

Discretizes a circular arc to meet a tolerance, ignoring rounding to a grid.

`θ` is the angular position of the end of the arc and `r` is its radius.
The maximum distance between any segment and the actual circle will be roughly
equal to the tolerance (for small tolerance). Returns an array of Points.
Includes both endpoints.

If `θ > θ_0`, the arc is drawn counterclockwise.
"""
function circular_arc(
    θ,
    r::T,
    tolerance;
    θ_0=0,
    center=zero(Point{T})
) where {T <: Coordinate}
    iszero(r) && return [center]
    dθ_max = 2 * sqrt(2 * tolerance / abs(r)) # r - r cos dθ/2 ≈ tolerance
    return circular_arc(θ_0, θ, dθ_max, r, center)
end

"""
    circular_arc(θ_0, θ_1, dθ_max, r, center)

Discretizes a circular arc from `θ_0` to `θ_1` with a maximum angular step `dθ_max`.

If `θ_1 > θ_0`, the arc is drawn counterclockwise.
"""
function circular_arc(θ_0, θ_1, dθ_max, r, center)
    iszero(r) && return [center]
    θs = range(θ_0, stop=θ_1, length=1 + Int(ceil(abs(θ_1 - θ_0) / dθ_max)))
    return Translation(center).(Point.(r * cos.(θs), r * sin.(θs)))
end

# modifying circular_arc so that it draws the shorter arc from θ1 to θ2, which may be clockwise. Inputting θ as a
# vector [θ1, θ2] because I think that's less likely to get accidentally used in a way that intends to call the
# original circular_arc
"""
    circular_arc(θ::Vector, r::T, tolerance; center=zero(Point{T})) where {T <: Coordinate}

Discretizes a circular arc of radius `r` from θ[1] to θ[2], choosing the shorter direction (defaults to
counterclockwise for a semicircle). `r` is its radius. The maximum distance between any segment and the actual
circle will be roughly equal to the tolerance (for small tolerance). Returns an array of Points, including
both endpoints.
"""
function circular_arc(
    θ::Vector,
    r::T,
    tolerance;
    center=zero(Point{T})
) where {T <: Coordinate}
    θ1, θ2 = θ
    θ1, θ2 = mod2pi(θ1), mod2pi(θ2) # limits to [0, 2π)
    arc = if θ1 < θ2 && (θ2 - θ1 <= π)
        circular_arc(θ2, r, tolerance; θ_0=θ1, center=center)
    elseif θ1 > θ2 && (θ1 - θ2 < π)
        reverse(circular_arc(θ1, r, tolerance; θ_0=θ2, center=center))
    elseif θ1 < θ2 && (θ2 - θ1 > π)
        reverse(circular_arc(θ1, r, tolerance; θ_0=θ2 - 2π, center=center))
    elseif θ1 > θ2 && (θ1 - θ2 >= π)
        circular_arc(θ2, r, tolerance; θ_0=θ1 - 2π, center=center)
    end
    return arc
end

"""
    draw_pixels(pixpattern::AbstractMatrix{Int}, pixsize)

Given a matrix `pixpattern`, make a bitmap of `Rectangle` where the presence of
a pixel corresponds to a positive value in the matrix. Returns an array of
polygons.
"""
function draw_pixels(pixpattern::AbstractMatrix{Int}, pixsize)
    s = size(pixpattern)
    pattern::Array{Polygon{typeof(pixsize)}} = []
    for i = 1:s[1], j = 1:s[2]
        pixpattern[i, j] <= 0 && continue
        r = Rectangle(pixsize, pixsize)
        r += Point((j - 1) * pixsize, (s[1] - i) * pixsize)
        push!(pattern, Polygon{typeof(pixsize)}(r))
    end
    return union2d(pattern)
end

const DEFAULT_HATCHING_PIXSIZE = 2.0 # previously in um
# hatching unit is 2x2 pixels
"""
    hatching_unit(w1, w2, pixsize=DEFAULT_HATCHING_PIXSIZE)
"""
function hatching_unit(w1, w2, pixsize=DEFAULT_HATCHING_PIXSIZE)
    pixpattern = [-1 1; 1 1]
    res = draw_pixels(pixpattern, pixsize)
    h1 = pixsize - w1
    h2 = pixsize - w2
    r1 = Rectangle(pixsize, h1) + Point(zero(h1), pixsize - h1)
    r2 = Rectangle(h2, 2 * pixsize) + Point(2 * pixsize - h2, zero(h1))

    return difference2d(res, [r1, r2])
end

"""
    radial_cut(r, Θ, h; narc::Int=197)

Renders a polygon representing a radial cut (like a radial stub with no metal).
The polygon has to be subtracted from a ground plane.

The parameter `h` is made available in the method signature rather than `a`
because the focus of the arc (top of polygon) can easily centered in a waveguide.
If it is desirable to control `a` instead, use trig: `a/2 = h*tan(Θ/2)`.

Parameters as follows, where X marks the origin and (*nothing above the origin
is part of the resulting polygon*):

```
                       Λ
                      /│\\
                     / │ \\
                    /  |  \\
              .    /   │Θ/2\\
             .    /    │----\\
            /    /   h │     \\
           /    /      │      \\
          /    /       │       \\
         r    /        │        \\
        /    /         │         \\
       /    /----------X----------\\
      /    /{--------- a ---------}\\
     .    /                         \\
    .    /                           \\
        /                             \\
       /                               \\
      /                                 \\
      --┐                             ┌--
        └--┐                       ┌--┘
           └--┐                 ┌--┘
              └--┐           ┌--┘
                 └-----------┘
                 (circular arc)
```
"""
function radial_cut(r, Θ, h; narc::Int=197)
    p = Path(Point(h * tan(Θ / 2), -h), α0=(Θ - π) / 2)
    straight!(p, r - h * sec(Θ / 2), Paths.Trace(r))
    turn!(p, -π / 2, zero(h))
    turn!(p, -Θ, r)
    turn!(p, -π / 2, zero(h))
    straight!(p, r - h * sec(Θ / 2))

    seg = segment(p[3])
    pts = map(seg, range(pathlength(seg), stop=zero(h), length=narc))
    push!(pts, Paths.p1(p))
    h != zero(h) && push!(pts, Paths.p0(p))
    poly = Polygon(pts) + Point(zero(h), h) # + Point(0.0, (r-h)/2)
    return poly
end

"""
    radial_stub(r, Θ, h, t; narc::Int=197)

See also the documentation for `radial_cut`.

Return a polygon for a radial stub. The polygon has to be subtracted from a
ground plane, and will leave a defect in the ground plane of uniform width `t`
that outlines the (metallic) radial stub. `r` refers to the radius of the
actual stub, not the radius of the circular arc bounding the ground plane defect.
Likewise `h` has an analogous meaning to that in `radial_cut` except it refers here
to the radial stub, not the ground plane defect.
"""
function radial_stub(r, Θ, h, t; narc::Int=197)
    # inner ring (bottom)
    pts = [
        Point(r * cos(α), r * sin(α)) for
        α in range(-(Θ + π) / 2, stop=(Θ - π) / 2, length=narc)
    ]
    # top right
    push!(pts, Point(h * tan(Θ / 2), -h), Point(h * tan(Θ / 2) + t * sec(Θ / 2), -h))
    # outer ring (bottom)
    R = r + t # outer ring radius
    a2 = R^2 / sin(Θ / 2)^2
    a1 = 2 * R * t * csc(Θ / 2)
    a0 = R^2 - (R^2 - t^2) * csc(Θ / 2)^2
    ϕ = 2 * acos((-a1 + sqrt(a1^2 - 4 * a0 * a2)) / (2 * a2))
    append!(
        pts,
        [
            Point(R * cos(α), R * sin(α)) for
            α in range((ϕ - π) / 2, stop=-(ϕ + π) / 2, length=narc)
        ]
    )
    # top left
    push!(pts, Point(-h * tan(Θ / 2) - t * sec(Θ / 2), -h), Point(-h * tan(Θ / 2), -h))

    # move to origin
    return Polygon(reverse(pts)) + Point(zero(h), h)
end

"""
    simple_cross(lv_x, lv_y; lh_x=lv_y, lh_y=lv_x)

A simple cross centered at the origin. The only required inputs are
`lv_x` and `lv_y`, the length of the vertical strip along the x and
y directions, respectively. The corresponding dimensions of the horizontal
strip are given as keyword arguments, with the defaults producing identical
horizontal and vertical strips.

    _ |<--------- lh_x ----------->|
    |            |▓▓▓▓|
    |            |▓▓▓▓|
    lv_y         |▓▓▓▓|
    |            |<  >| lv_x
    |            |▓▓▓▓|
    | |▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓| lh_y
    | |▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓|
    |            |▓▓▓▓|
    |            |▓▓▓▓|
    |            |▓▓▓▓|
    |            |▓▓▓▓|
    _            |▓▓▓▓|
"""
function simple_cross(lv_x, lv_y; lh_x=lv_y, lh_y=lv_x)
    return 0.5 * Polygon(
        Point(-lv_x, -lh_y),
        Point(-lv_x, -lv_y),
        Point(lv_x, -lv_y),
        Point(lv_x, -lh_y),
        Point(lh_x, -lh_y),
        Point(lh_x, lh_y),
        Point(lv_x, lh_y),
        Point(lv_x, lv_y),
        Point(-lv_x, lv_y),
        Point(-lv_x, lh_y),
        Point(-lh_x, lh_y),
        Point(-lh_x, -lh_y)
    )
end

"""
    simple_ell(w1, h1; w2=h1, h2=w1)

Return an L-shaped polygon with its bottom left corner at the origin.

Note that the parameters describe the L as two overlapping rectangles.
The result is identical if you switch "rectangle 1" and "rectangle 2".
By default, the rectangles have the same "stroke width" and length.

    _           |<------w2------->|
    |           |▓▓▓▓|
    |           |▓▓▓▓|
    h1          |▓▓▓▓|
    |           |<w1>|
    |           |▓▓▓▓|
    v           |▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓| h2
                ^ (x,y) = (0,0) at the lower-left corner of the L.
"""
function simple_ell(w1, h1; w2=h1, h2=w1)
    return Polygon(
        Point(zero(w1), zero(w1)),
        Point(w2, zero(w1)),
        Point(w2, h2),
        Point(w1, h2),
        Point(w1, h1),
        Point(zero(w1), h1)
    )
end

"""
    simple_tee(w1, h1; w2=h1, h2=w1)

Parameters are named in typical handwritten stroke order (like `cross`,
vertical stem first). Note that `h1` is the full height of the T.

    _    _______w2________
    |   |▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓| h2
    |          |▓▓▓▓|
    h1         |▓▓▓▓|
    |          |<w1>|
    v          |▓▓▓▓|
                 ^ (x,y) = (0,0) at center of baseline of T.
"""
function simple_tee(w1, h1; w2=h1, h2=w1)
    return Polygon(
        Point(w1 / 2, zero(w1)),
        Point(w1 / 2, h1 - h2),
        Point(w2 / 2, h1 - h2),
        Point(w2 / 2, h1),
        Point(-w2 / 2, h1),
        Point(-w2 / 2, h1 - h2),
        Point(-w1 / 2, h1 - h2),
        Point(-w1 / 2, zero(w1))
    )
end

### Compound shapes -- methods render to a CoordinateSystem rather than return a single entity

"""
    checkerboard!(c::Cell{T,S}, pixsize, rows::Integer, alt, meta::Meta=GDSMeta()) where {T,S}

In cell `c`, generate a checkerboard pattern suitable for contrast curve measurement,
or getting the base dose for PEC.

  - `pixsize`: length of one side of a square
  - `rows`: number of rows == number of columns
  - `alt`: the square nearest `Point(zero(T), zero(T))` is filled (unfilled) if `false`
    (`true`). Use this to create a full tiling of the checkerboard, if you wish.
"""
function checkerboard!(
    c::AbstractCoordinateSystem{S},
    pixsize,
    rows::Integer,
    alt,
    meta::Meta=GDSMeta()
) where {S}
    r = Rectangle(pixsize, pixsize)
    cs = typeof(c)(uniquename("checkerboard"))
    render!(cs, r, meta)

    r1 = Int(ceil(rows / 2))
    r2 = Int(floor(rows / 2))
    a1 = aref(
        cs,
        Point(zero(S), ifelse(alt, pixsize, zero(S)));
        dc = Point(2 * pixsize, zero(S)),
        dr = Point(zero(S), 2 * pixsize),
        nc = r1,
        nr = r1
    )
    a2 = aref(
        cs,
        Point(pixsize, ifelse(alt, zero(S), pixsize));
        dc = Point(2 * pixsize, zero(S)),
        dr = Point(zero(S), 2 * pixsize),
        nc = r2,
        nr = r2
    )

    push!(c.refs, a1)
    push!(c.refs, a2)
    return c
end

"""
    grating!(c::Cell{T,S}, line, space, size, meta::Meta=GDSMeta()) where {T,S}

Generate a square grating suitable e.g. for obtaining the base dose for PEC.
"""
function grating!(
    c::AbstractCoordinateSystem{S},
    line,
    space,
    size,
    meta::Meta=GDSMeta()
) where {S}
    r = Rectangle(line, size)
    cs = typeof(c)(uniquename("grating"))
    render!(cs, r, meta)

    a = aref(
        cs,
        Point(zero(S), zero(S));
        dc=Point(line + space, zero(S)),
        dr=Point(zero(S), zero(S)),
        nc=Int(floor(NoUnits(size / (line + space)))),
        nr=1
    )

    push!(c.refs, a)
    return c
end

"""
    interdigit!(c::AbstractCoordinateSystem{T}, width, length, fingergap, fingeroffset, npairs::Integer,
        skiplast, meta::Meta=GDSMeta(0,0)) where {T}

Creates interdigitated fingers, e.g. for a lumped element capacitor.

  - `width`: finger width
  - `length`: finger length
  - `fingeroffset`: x-offset at ends of fingers
  - `fingergap`: gap between fingers
  - `npairs`: number of fingers
  - `skiplast`: should we skip the last finger, leaving an odd number?
"""
function interdigit!(
    c::AbstractCoordinateSystem{T},
    width,
    length,
    fingergap,
    fingeroffset,
    npairs::Integer,
    skiplast,
    meta::Meta=GDSMeta(0, 0)
) where {T}
    for i = 1:npairs
        render!(
            c,
            Rectangle(
                Point(zero(T), (i - 1) * 2 * (width + fingergap)),
                Point(length, (i - 1) * 2 * (width + fingergap) + width)
            ),
            meta
        )
    end
    for i = 1:(npairs - skiplast)
        render!(
            c,
            Rectangle(
                Point(fingeroffset, (2i - 1) * (width + fingergap)),
                Point(fingeroffset + length, width + (2i - 1) * (width + fingergap))
            ),
            meta
        )
    end
    return c
end

end # module
