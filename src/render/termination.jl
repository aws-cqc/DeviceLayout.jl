# # Open termination
# 
# 1--------8
# |        |   Rounding will be applied to corners 3,4,7,8.
# 2--3     |
#    |     |
# 5--4     |
# |        |
# 6--------7
# 
# Reversed:
# 7--------6
# |        |   Rounding will be applied to corners 3,4,7,8.
# |     4--5
# |     |
# |     3--2
# |        |
# 8--------1
# 
# If there is no rounding, points 3 and 4 are omitted, but 2 and 5 are still present.
# If 2 and 5 were omitted, rounding points to a grid (e.g. 1nm) with a non-grid-aligned Path
# could result in gaps between the 1--6 line segment and the points on the previous segment
# corresponding to 2 and 5.

function __poly(f::Paths.Straight{T}, s::Paths.CPWOpenTermination) where {T}
    g = cpw_points(f, s)

    t0, tr, t1 = zero(T), s.rounding, pathlength(f)
    if iszero(tr)
        pts = if s.initial
            [
                g(t1, -1, 1),  # start at corner 1 (see diagram)
                g(t1, -1, -1),
                g(t1, 1, -1),  # omitting corners 3, 4
                g(t1, 1, 1),
                g(t0, 1, 1),
                g(t0, -1, 1)
            ]
        else
            [
                g(t0, 1, 1),   # start at corner 1 (see diagram)
                g(t0, 1, -1),
                g(t0, -1, -1), # omitting corners 3, 4
                g(t0, -1, 1),
                g(t1, -1, 1),
                g(t1, 1, 1)
            ]
        end
        return Polygon(pts)
    else
        pts = if s.initial
            [
                g(t1, -1, 1),  # start at corner 1 (see diagram)
                g(t1, -1, -1),
                g(t1 - tr, -1, -1),
                g(t1 - tr, 1, -1),
                g(t1, 1, -1),
                g(t1, 1, 1),
                g(t0, 1, 1),
                g(t0, -1, 1)
            ]
        else
            [
                g(t0, 1, 1),   # start at corner 1 (see diagram)
                g(t0, 1, -1),
                g(tr, 1, -1),
                g(tr, -1, -1),
                g(t0, -1, -1),
                g(t0, -1, 1),
                g(t1, -1, 1),
                g(t1, 1, 1)
            ]
        end

        # Note, `min_side_len` is needed to make sure rounding happens consistently;
        # it can happen that length of the side is one grid unit smaller than expected.
        return Polygons.Rounded(tr; p0=pts[[3, 4, 7, 8]], min_side_len=zero(tr))(
            Polygon(pts)
        )
    end
end

function to_polygons(f::Paths.Segment{T}, s::Paths.CPWOpenTermination; kwargs...) where {T}
    return to_polygons(_poly(f, s); kwargs...)
end

# Disambiguate from compound fallback
function to_polygons(
    f::Paths.CompoundSegment{T},
    s::Paths.CPWOpenTermination;
    kwargs...
) where {T}
    return to_polygons(_poly(f, s); kwargs...)
end

# reproducer for `min_side_len` issue noted above:
# p = Path(Point(0.0μm, 0.0μm); α0=10°)
# straight!(p, 10μm, Paths.CPW(10μm, 6μm))
# terminate!(p; rounding=1μm)
# c = Cell("test", nm)
# render!(c, p)
# c

# # Shorted termination
#
# 4--------3
# |        |   Rounding will be applied to corners 2,3,6,7.
# 1--------2
# 
# 8--------7
# |        |
# 5--------6

function __poly(f::Paths.Straight{T}, s::Paths.CPWShortTermination) where {T}
    g = cpw_points(f, s)

    t0, tr, t1 = zero(T), s.rounding, pathlength(f)
    if !isapprox(tr, t1)
        throw(ArgumentError("Termination rounding ≠ termination path length."))
    end

    poly1 = Polygon([
        g(t0, 1, -1),   # for path with α=0°, start at corner 1 (see diagram)
        g(t1, 1, -1),
        g(t1, 1, 1),
        g(t0, 1, 1)
    ])

    poly2 = Polygon([g(t0, -1, 1), g(t1, -1, 1), g(t1, -1, -1), g(t0, -1, -1)])
    round_idx = s.initial ? [1, 4] : [2, 3]
    round1 = Polygons.Rounded(tr; p0=points(poly1)[round_idx], min_side_len=zero(T))
    round2 = Polygons.Rounded(tr; p0=points(poly2)[round_idx], min_side_len=zero(T))
    return [round1(poly1), round2(poly2)]
end

function to_polygons(f::Paths.Segment{T}, s::Paths.CPWShortTermination; kwargs...) where {T}
    return to_polygons.(_poly(f, s); kwargs...)
end

# Disambiguate from compound fallback
function to_polygons(
    f::Paths.CompoundSegment{T},
    s::Paths.CPWShortTermination;
    kwargs...
) where {T}
    return to_polygons.(_poly(f, s); kwargs...)
end

function __poly(f::Paths.Straight{T}, s::Paths.TraceTermination) where {T}
    iszero(s.rounding) && return Polygon{T}[]
    if !isapprox(s.rounding, pathlength(f))
        throw(ArgumentError("Termination rounding ≠ termination path length."))
    end
    poly = to_polygons(f, Paths.SimpleTrace(s.width))
    round_idx = s.initial ? [1, 4] : [2, 3]
    return Polygons.Rounded(s.rounding; p0=points(poly)[round_idx], min_side_len=zero(T))(
        poly
    )
end

function to_polygons(f::Paths.Segment{T}, s::Paths.TraceTermination; kwargs...) where {T}
    return to_polygons(_poly(f, s); kwargs...)
end

# Disambiguate from compound fallback
function to_polygons(
    f::Paths.CompoundSegment{T},
    s::Paths.TraceTermination;
    kwargs...
) where {T}
    return to_polygons(_poly(f, s); kwargs...)
end

## Generic segments—just draw as though straight for length `_polylength`
function _poly(
    f::Paths.Segment{T},
    s::Union{Paths.TraceTermination, Paths.CPWOpenTermination, Paths.CPWShortTermination}
) where {T}
    straight = if s.initial
        p = p1(f) - _polylength(s) * Point(cos(α1(f)), sin(α1(f)))
        Paths.Straight{T}(_polylength(s), p, α1(f))
    else
        Paths.Straight{T}(_polylength(s), p0(f), α0(f))
    end
    return __poly(straight, s)
end

_polylength(s::Paths.TraceTermination) = s.rounding
_polylength(s::Paths.CPWOpenTermination) = s.rounding + s.gap
_polylength(s::Paths.CPWShortTermination) = s.rounding
