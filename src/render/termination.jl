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
    t0, tr, t1 = zero(T), s.rounding, pathlength(f)
    c0 = _cpw_corners(f, s, t0)
    c1 = _cpw_corners(f, s, t1)
    if iszero(tr)
        pts = if s.initial
            [
                c1[1], # start at corner 1 (see diagram)
                c1[2],
                c1[3], # omitting corners 3, 4
                c1[4],
                c0[4],
                c0[1]
            ]
        else
            [
                c0[4], # start at corner 1 (see diagram)
                c0[3],
                c0[2], # omitting corners 3, 4
                c0[1],
                c1[1],
                c1[4]
            ]
        end
        return Polygon(pts)
    else
        ctr_initial = _cpw_corners(f, s, t1 - tr)
        ctr_final = _cpw_corners(f, s, tr)
        pts = if s.initial
            [
                c1[1], # start at corner 1 (see diagram)
                c1[2],
                ctr_initial[2],
                ctr_initial[3],
                c1[3],
                c1[4],
                c0[4],
                c0[1]
            ]
        else
            [
                c0[4], # start at corner 1 (see diagram)
                c0[3],
                ctr_final[3],
                ctr_final[2],
                c0[2],
                c0[1],
                c1[1],
                c1[4]
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
    t0, tr, t1 = zero(T), s.rounding, pathlength(f)
    if !isapprox(tr, t1)
        throw(ArgumentError("Termination rounding ≠ termination path length."))
    end

    c0 = _cpw_corners(f, s, t0)
    c1 = _cpw_corners(f, s, t1)
    poly1 = Polygon([
        c0[3],
        c1[3],
        c1[4],
        c0[4] # for path with α=0°, start at corner 1 (see diagram)
    ])

    poly2 = Polygon([c0[1], c1[1], c1[2], c0[2]])
    iszero(tr) && return [poly1, poly2]
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
    if !isapprox(s.rounding, pathlength(f))
        throw(ArgumentError("Termination rounding ≠ termination path length."))
    end
    poly = to_polygons(f, Paths.SimpleTrace(s.width))
    iszero(s.rounding) && return poly
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

# Generic segments—just draw as though straight for length `_termlength` (either gap or rounding + gap)
function _poly(
    f::Paths.Segment{T},
    s::Union{Paths.TraceTermination, Paths.CPWOpenTermination, Paths.CPWShortTermination}
) where {T}
    straight = if s.initial
        p = p1(f) - Paths._termlength(s) * Point(cos(α1(f)), sin(α1(f)))
        Paths.Straight{T}(Paths._termlength(s), p, α1(f))
    else
        Paths.Straight{T}(Paths._termlength(s), p0(f), α0(f))
    end
    return __poly(straight, s)
end
