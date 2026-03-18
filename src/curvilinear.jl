module Curvilinear

using LinearAlgebra

import Base: convert

import CoordinateTransformations: Transformation

import DeviceLayout
import DeviceLayout:
    AbstractPolygon,
    GeometryEntity,
    GeometryEntityStyle,
    Paths,
    Reflection,
    Rotation,
    ScaledIsometry,
    Transformation,
    Translation
import DeviceLayout:
    to_polygons, points, rotation, origin, mag, xrefl, transform, perimeter, isapprox_angle
using DeviceLayout.Paths
import DeviceLayout.Polygons: cornerindices

using ..Points
using ..Polygons
using ..Paths

export CurvilinearPolygon, CurvilinearRegion, pathtopolys, line_arc_cornerindices

"""
    struct CurvilinearPolygon{T} <: GeometryEntity{T}
        p::Vector{Point{T}}
        curves::Vector{<:Paths.Segment}
        curve_start_idx::Vector{Int}
    end

A curvilinear polygon defined by a list of coordinates and curves between them. Straight
sections are implicit, whereas any curve is specified by the start index. A `Polygon` can be
represented using a `CurvilinearPolygon` with an empty `curves` and `curve_start_idx`.

The key distinction between `CurvilinearPolygon` and `Polygon` comes in their interaction
with boolean operations. A `Polygon` can be differenced using `Clipper` (see
`difference2d`), however a `CurvilinearPolygon` cannot directly. This is because `Clipper`
will discretize the curved sections of a `CurvilinearPolygon`. This is particularly
important for representing a geometry precisely for purposes of rendering to `SolidModel`.

See `CurvilinearRegion{T} <: GeometryEntity{T}` for the means of representing a difference
operation between `CurvilinearPolygon`.
"""
struct CurvilinearPolygon{T} <: GeometryEntity{T}
    p::Vector{Point{T}}
    curves::Vector{<:Paths.Segment} # Only need to store non-line-segment curves
    curve_start_idx::Vector{Int} # And the indices at which they start
    # A negative start idx like -3 means that the corresponding curve
    # between p[3] and p[4] is actually parameterized from p[4] to p[3]
    function CurvilinearPolygon{T}(p, c, csi) where {T} # Make sure you don't have zero-length curves
        # Don't treat duplicates in any different fashion -> view as user error
        # Some endpoint pairs may be identical; delete the duplicates
        # Maybe inefficient but least confusing to iterate to find them and then delete
        dup_idx = Int[]
        for (idx, endpoints) in enumerate(zip(p, circshift(p, -1)))
            isapprox(
                endpoints[1],
                endpoints[2];
                atol=1e-3 * DeviceLayout.onenanometer(T)
            ) && push!(dup_idx, idx)
        end
        deleteat!(p, dup_idx)
        # Some curves may be between duplicated points; delete them
        dup_curve_idx = Int[] # Again, just iterate to find them, then delete
        for (curve_idx, start_idx) in enumerate(csi)
            (start_idx in dup_idx) && push!(dup_curve_idx, curve_idx)
        end
        deleteat!(c, dup_curve_idx)
        deleteat!(csi, dup_curve_idx)
        # Update remaining curve start indices to account for lost points
        for (curve_idx, start_idx) in enumerate(csi)
            csi[curve_idx] = start_idx - count(dup_idx .< start_idx)
        end
        return new{T}(p, c, csi)
    end
end
CurvilinearPolygon(points::Vector{Point{T}}, curves, curve_start_idx) where {T} =
    CurvilinearPolygon{T}(points, curves, curve_start_idx)
function CurvilinearPolygon(points::Vector{Point{T}}) where {T}
    # Straight segments are implicit
    return CurvilinearPolygon{T}(points, Paths.Segment[], Int[])
end
CurvilinearPolygon(p::Polygon{T}) where {T} = CurvilinearPolygon{T}(points(p))

### Conversion methods
function to_polygons(
    e::CurvilinearPolygon{T};
    atol=DeviceLayout.onenanometer(T),
    kwargs...
) where {T}
    i = 1
    p = Point{T}[]

    # TODO: Use ToTolerance
    for (idx, (csi, c)) ∈ enumerate(zip(e.curve_start_idx, e.curves))
        # Add the points from current to start of curve
        append!(p, e.p[i:abs(csi)])

        # Discretize segment with 181 pts (1° over 180° turn).
        wrapped_i = mod1(abs(csi) + 1, length(e.p))
        pp = c.(range(zero(T), pathlength(c), 181))

        # Remove the calculated points corresponding to start and end.
        term_p = csi < 0 ? popfirst!(pp) : pop!(pp)
        init_p = csi < 0 ? pop!(pp) : popfirst!(pp)

        # Add interior points and bump counter.
        append!(p, csi < 0 ? reverse(pp) : pp)
        i = abs(csi) + 1

        # Ensure that the calculated start and end points match the non-calculated points.
        @assert !isapprox(init_p, term_p; atol=1e-3 * DeviceLayout.onenanometer(T)) "Curve $idx must have non-zero length!"
        @assert isapprox(term_p, e.p[wrapped_i]; atol=1e-3 * DeviceLayout.onenanometer(T)) "Curve $idx must $(csi < 0 ? "start" : "end") at point $(wrapped_i)!"
        @assert isapprox(init_p, e.p[abs(csi)]; atol=1e-3 * DeviceLayout.onenanometer(T)) "Curve $idx must $(csi < 0 ? "end" : "start") at point $(abs(csi))!"
    end
    append!(p, e.p[i:end])

    return Polygon{T}(p)
end

function transform(e::CurvilinearPolygon, f::Transformation)
    # If the transformation is a reflection, have to fix the winding.
    # curve_start_idx are shifted forward 1, reversed, then negated.
    # Reverse ordering of curve_start_idx and curves to ensure consecutive.
    csi_rev = (i, N) -> mod1(i + 1, N) - N - 1
    return CurvilinearPolygon(
        f.(xrefl(f) ? reverse(e.p) : e.p),
        isempty(e.curves) ? deepcopy(e.curves) :
        transform.(xrefl(f) ? reverse(e.curves) : e.curves, Ref(f)),
        xrefl(f) ? reverse(csi_rev.(e.curve_start_idx, length(e.p))) : e.curve_start_idx
    )
end

convert(::Type{GeometryEntity{T}}, e::CurvilinearPolygon) where {T} =
    convert(CurvilinearPolygon{T}, e)
convert(::Type{GeometryEntity{T}}, e::CurvilinearPolygon{T}) where {T} = e
function convert(::Type{CurvilinearPolygon{T}}, e::CurvilinearPolygon{S}) where {T, S}
    return CurvilinearPolygon{T}(
        convert(Vector{Point{T}}, e.p),
        e.curves,
        e.curve_start_idx
    )
end

### Utility methods -- accessing members or derived information
points(e::CurvilinearPolygon) = e.p

"""
    struct CurvilinearRegion{T} <: GeometryEntity{T}
        exterior::CurvilinearPolygon{T}
        holes::Vector{CurvilinearPolygon{T}}
    end

A curvilinear region made up of an exterior::CurvilinearPolygon{T} and optional interior
holes made up of CurvilinearPolygon{T}. These holes cannot intersect each other or the
exterior.
"""
struct CurvilinearRegion{T} <: GeometryEntity{T}
    exterior::CurvilinearPolygon{T}
    holes::Vector{CurvilinearPolygon{T}}
    CurvilinearRegion{T}(ext::CurvilinearPolygon, holes=CurvilinearPolygon{T}[]) where {T} =
        new(ext, holes)
end
CurvilinearRegion(x) = CurvilinearRegion(CurvilinearPolygon(x))
CurvilinearRegion(ext::CurvilinearPolygon{T}) where {T} = CurvilinearRegion{T}(ext)
CurvilinearRegion(
    exterior::CurvilinearPolygon{T},
    holes::Vector{CurvilinearPolygon{T}}
) where {T} = CurvilinearRegion{T}(exterior, holes)
CurvilinearRegion(exterior::Vector{Point{T}}, holes::Vector{Vector{Point{T}}}) where {T} =
    CurvilinearRegion{T}(CurvilinearPolygon(exterior), CurvilinearPolygon.(holes))
CurvilinearRegion(points::Vector{Point{T}}, segments) where {T} =
    CurvilinearRegion(CurvilinearPolygon(points, segments))
CurvilinearRegion(points::Vector{Point{T}}, curves, curve_start_idx) where {T} =
    CurvilinearRegion(CurvilinearPolygon(points, curves, curve_start_idx))

to_polygons(e::CurvilinearRegion{T}; kwargs...) where {T} =
    difference2d(to_polygons(e.exterior), to_polygons.(e.holes))
to_polygons(e::CurvilinearRegion, sty::Polygons.Rounded; kwargs...) = difference2d(
    to_polygons(e.exterior, sty; kwargs...),
    [to_polygons(h, sty; kwargs...) for h in e.holes]
)

function transform(e::CurvilinearRegion{T}, f::Transformation) where {T}
    return CurvilinearRegion{T}(transform(e.exterior, f), transform.(e.holes, Ref(f)))
end

convert(::Type{GeometryEntity{T}}, e::CurvilinearRegion) where {T} =
    convert(CurvilinearRegion{T}, e)
convert(::Type{GeometryEntity{T}}, e::CurvilinearRegion{T}) where {T} = e
function convert(::Type{CurvilinearRegion{T}}, e::CurvilinearRegion{S}) where {T, S}
    return CurvilinearRegion{T}(
        convert(CurvilinearPolygon{T}, e.exterior),
        convert.(CurvilinearPolygon{T}, e.holes)
    )
end

points(e::CurvilinearRegion) = vcat(points(e.exterior), points.(e.holes))

### Construction from Paths

"""
    pathtopolys(f::Paths.Segment{T}, s::Paths.Style; kwargs...)

Given a path node represented with a segment and style, construct an equivalent set of
polygons. For some linear segments and styles, a set of `Polygon{T}` is sufficient, for others
such as curves then `CurvilinearRegion{T}` is necessary.

This is particularly helpful if a Path is being used within the construction of a component
rather than as part of the SchematicGraph.
"""
function pathtopolys(f::Paths.Segment{T}, s::Paths.Style; kwargs...) where {T}
    @warn "Discretizing path segment ($f, $s) for CurvilinearRegion construction"
    return to_polygons(f, s; kwargs...)
end

# NoRender and friends — effectively the same as above but without the warning
pathtopolys(seg::Paths.Segment{T}, s::Paths.NoRenderContinuous; kwargs...) where {T} =
    Polygon{T}[]
pathtopolys(seg::Paths.Segment{T}, s::Paths.NoRenderDiscrete; kwargs...) where {T} =
    Polygon{T}[]
pathtopolys(seg::Paths.Segment{T}, s::Paths.SimpleNoRender; kwargs...) where {T} =
    Polygon{T}[]
pathtopolys(seg::Paths.Segment{T}, s::Paths.NoRender; kwargs...) where {T} = Polygon{T}[]

pathtopolys(p::Paths.Path; kwargs...) =
    vcat(pathtopolys.(filter(x -> !iszero(pathlength(x)), p.nodes)))

function pathtopolys(
    f::Paths.CompoundSegment{T},
    s::Paths.CompoundStyle;
    kwargs...
) where {T}
    return vcat(pathtopolys.(f.segments, s.styles; kwargs...)...)
end

# 4-----3
# trace->
# 1-----2
function corner_points(seg::Paths.Segment{T}, sty::Paths.Trace, clip::Bool) where {T}
    dir0 = Paths.α0(seg)
    dir1 = Paths.α1(seg)
    dp0, dm0 = dir0 + π / 2, dir0 - π / 2
    dp1, dm1 = dir1 + π / 2, dir1 - π / 2

    ext0 = Paths.Paths.extent(sty, zero(T))
    ext1 = Paths.Paths.extent(sty, pathlength(seg))
    if !clip
        tangents = [
            ext0 * Point(cos(dm0), sin(dm0)),
            ext1 * Point(cos(dm1), sin(dm1)),
            ext1 * Point(cos(dp1), sin(dp1)),
            ext0 * Point(cos(dp0), sin(dp0))
        ]
    else
        rad0 = Paths.curvatureradius(seg, zero(T))
        rad1 = Paths.curvatureradius(seg, pathlength(seg))
        ext0m = rad0 < zero(T) ? -max(-ext0, rad0) : ext0
        ext0p = rad0 > zero(T) ? min(ext0, rad0) : ext0
        ext1m = rad1 < zero(T) ? -max(-ext1, rad1) : ext1
        ext1p = rad1 > zero(T) ? min(ext1, rad1) : ext1
        tangents = [
            ext0m * Point(cos(dm0), sin(dm0)),
            ext1m * Point(cos(dm1), sin(dm1)),
            ext1p * Point(cos(dp1), sin(dp1)),
            ext0p * Point(cos(dp0), sin(dp0))
        ]
    end
    a, b = Paths.p0(seg), Paths.p1(seg)
    origins = [a, b, b, a]
    return origins .+ tangents
end

# 8-----7
# 5-----6
# trace->
# 4-----3
# 1-----2
function corner_points(seg::Paths.Segment{T}, sty::Paths.CPW, clip::Bool) where {T}
    dir0 = Paths.α0(seg)
    dir1 = Paths.α1(seg)
    dp0, dm0 = dir0 + π / 2, dir0 - π / 2
    dp1, dm1 = dir1 + π / 2, dir1 - π / 2

    ext00 = Paths.Paths.extent(sty, zero(T))
    ext01 = Paths.Paths.extent(sty, pathlength(seg))
    ext11 = Paths.trace(sty, pathlength(seg)) / 2
    ext10 = Paths.trace(sty, zero(T)) / 2

    if !clip
        tangents = [
            ext00 * Point(cos(dm0), sin(dm0)),
            ext01 * Point(cos(dm1), sin(dm1)),
            ext11 * Point(cos(dm1), sin(dm1)),
            ext10 * Point(cos(dm0), sin(dm0)),
            ext10 * Point(cos(dp0), sin(dp0)),
            ext11 * Point(cos(dp1), sin(dp1)),
            ext01 * Point(cos(dp1), sin(dp1)),
            ext00 * Point(cos(dp0), sin(dp0))
        ]
    else
        rad0 = Paths.curvatureradius(seg, zero(T))
        rad1 = Paths.curvatureradius(seg, pathlength(seg))
        # Ambiguous if inner points are identical

        ext00m = rad0 < zero(T) ? -max(-ext00, rad0) : ext00
        ext00p = rad0 > zero(T) ? min(ext00, rad0) : ext00
        ext10m = rad0 < zero(T) ? -max(-ext10, rad0) : ext10
        ext10p = rad0 > zero(T) ? min(ext10, rad0) : ext10

        ext01m = rad1 < zero(T) ? -max(-ext01, rad1) : ext01
        ext01p = rad1 > zero(T) ? min(ext01, rad1) : ext01
        ext11m = rad1 < zero(T) ? -max(-ext11, rad1) : ext11
        ext11p = rad1 > zero(T) ? min(ext11, rad1) : ext11

        tangents = [
            ext00m * Point(cos(dm0), sin(dm0)),
            ext01m * Point(cos(dm1), sin(dm1)),
            ext11m * Point(cos(dm1), sin(dm1)),
            ext10m * Point(cos(dm0), sin(dm0)),
            ext10p * Point(cos(dp0), sin(dp0)),
            ext11p * Point(cos(dp1), sin(dp1)),
            ext01p * Point(cos(dp1), sin(dp1)),
            ext00p * Point(cos(dp0), sin(dp0))
        ]
    end

    a, b = Paths.p0(seg), Paths.p1(seg)
    origins = [a, b, b, a, a, b, b, a]
    return origins .+ tangents
end

# Traces generate one surface
# SimpleTrace can use constant offset
function pathtopolys(seg::Paths.Segment{T}, sty::Paths.SimpleTrace; kwargs...) where {T}
    pts = corner_points(seg, sty, true)
    # Check if the points are degenerate
    if isapprox(pts[1], pts[2])
        return CurvilinearPolygon(pts[2:end], [Paths.offset(seg, Paths.extent(sty))], [-2])
    elseif isapprox(pts[3], pts[4])
        return CurvilinearPolygon(pts[1:3], [Paths.offset(seg, -Paths.extent(sty))], [1])
    end
    return CurvilinearPolygon(
        pts,
        [Paths.offset(seg, -Paths.extent(sty)), Paths.offset(seg, Paths.extent(sty))],
        [1, -3]
    )
end

function pathtopolys(seg::Paths.Segment{T}, sty::Paths.Trace; kwargs...) where {T}
    pts = corner_points(seg, sty, false)
    return CurvilinearPolygon(
        pts,
        [
            Paths.offset(seg, t -> -Paths.extent(sty, t)),
            Paths.offset(seg, t -> Paths.extent(sty, t))
        ],
        [1, -3]
    )
end

# CPWs generate two surfaces
function pathtopolys(seg::Paths.Segment{T}, sty::Paths.SimpleCPW; kwargs...) where {T}
    pts = corner_points(seg, sty, true)
    return [
        isapprox(pts[1], pts[2]) ?
        CurvilinearPolygon(pts[2:4], [Paths.offset(seg, -Paths.trace(sty) / 2)], [-2]) :
        CurvilinearPolygon(
            pts[1:4],
            [
                Paths.offset(seg, -Paths.extent(sty)),
                Paths.offset(seg, -Paths.trace(sty) / 2)
            ],
            [1, -3]
        ),
        isapprox(pts[7], pts[8]) ?
        CurvilinearPolygon(pts[5:7], [Paths.offset(seg, Paths.trace(sty) / 2)], [1]) :
        CurvilinearPolygon(
            pts[5:8],
            [Paths.offset(seg, Paths.trace(sty) / 2), Paths.offset(seg, Paths.extent(sty))],
            [1, -3]
        )
    ]
end

function pathtopolys(seg::Paths.Segment{T}, sty::Paths.CPW; kwargs...) where {T}
    pts = corner_points(seg, sty, false)
    return [
        CurvilinearPolygon(
            pts[1:4],
            [
                Paths.offset(seg, t -> -Paths.extent(sty, t)),
                Paths.offset(seg, t -> -Paths.trace(sty, t) / 2)
            ],
            [1, -3]
        ),
        CurvilinearPolygon(
            pts[5:end],
            [
                Paths.offset(seg, t -> Paths.trace(sty, t) / 2),
                Paths.offset(seg, t -> Paths.extent(sty, t))
            ],
            [1, -3]
        )
    ]
end

# Terminations are only used with Straight and generate one or two [Rounded] Polygons
function pathtopolys(
    seg::Paths.Straight{T},
    sty::Union{Paths.TraceTermination, Paths.CPWOpenTermination, Paths.CPWShortTermination};
    kwargs...
) where {T}
    p = DeviceLayout._poly(seg, sty)
    return p isa Vector ? CurvilinearPolygon.(p) : CurvilinearPolygon(p)
end

# Types that together can use straight lines only
const LinearSegment{T} =
    Union{Paths.Straight{T}, Paths.ConstantOffset{T, Paths.Straight{T}}}
const LinearStyle =
    Union{Paths.SimpleTrace, Paths.SimpleCPW, Paths.TaperTrace, Paths.TaperCPW}
islinear(::LinearSegment{T}, ::LinearStyle) where {T} = Val(true)
islinear(::Paths.Segment{T}, ::Paths.Style) where {T} = Val(false)

# Dispatch node->primitive based on kernel and requirements for representing node exactly
function pathtopolys(node::Paths.Node; kwargs...)
    return pathtopolys(node, islinear(node.seg, node.sty); kwargs...)
end
# A linear path can be exactly represented using plain Polygons.
function pathtopolys(node::Paths.Node, ::Val{true}; kwargs...)
    return to_polygons(node.seg, node.sty; kwargs...)
end

function pathtopolys(node::Paths.Node, ::Val{false}; kwargs...)
    return pathtopolys(node.seg, node.sty; kwargs...)
end

## Helper methods
function perimeter(p::CurvilinearRegion)
    return sum(norm.(points(p.exterior) .- circshift(points(p.exterior), -1)))
end

function perimeter(p::CurvilinearPolygon)
    return sum(norm.(points(p) .- circshift(points(p), -1)))
end

# Only indices that don't start or end a curve are available for rounding.
# cornerindices(p::CurvilinearPolygon, s::GeometryEntityStyle) = cornerindices(p, p0(s))
function cornerindices(p::CurvilinearPolygon{T}) where {T}
    curve_bound_ind =
        vcat((x -> [abs(x), (abs(x) % length(p.p)) + 1]).(p.curve_start_idx)...)
    valid_ind = setdiff(1:length(p.p), curve_bound_ind)
    return valid_ind
end
function cornerindices(p::CurvilinearPolygon, p0::Vector{<:Point}; tol)
    isempty(p0) && return Int[]
    valid_ind = cornerindices(p)
    return isempty(valid_ind) ? Int[] : valid_ind[cornerindices(p.p[valid_ind], p0; tol)]
end
function cornerindices(p::CurvilinearPolygon, r::Polygons.Rounded)
    ss = cornerindices(p)
    isempty(ss) && return Int[]
    if isempty(p0(r))
        selected = ss
    else
        # Match p0 against all roundable vertices (straight-straight + line-arc) jointly,
        # so a p0 point targeting a line-arc corner doesn't accidentally claim a
        # straight-straight corner for inverse_selection.
        la = line_arc_cornerindices(p)
        all_roundable = vcat(ss, la)
        roundable_pts = p.p[all_roundable]
        matched = Polygons.cornerindices(roundable_pts, p0(r); tol=r.selection_tolerance)
        matched_orig = isempty(matched) ? Int[] : all_roundable[matched]
        selected = filter(i -> i in ss, matched_orig)
    end
    return r.inverse_selection ? setdiff(ss, selected) : selected
end

"""
    line_arc_cornerindices(p::CurvilinearPolygon)

Return indices of vertices where one edge is straight and the other is a curve (line-arc
corners). These are the vertices at curve boundaries that can be fillet-rounded.
"""
line_arc_cornerindices(::AbstractPolygon) = Int[]
line_arc_cornerindices(::AbstractPolygon, ::Polygons.Rounded) = Int[]

function line_arc_cornerindices(p::CurvilinearPolygon)
    indices = Int[]
    n = length(p.p)
    for i = 1:n
        edge = edge_type_at_vertex(p, i)
        is_line_arc = (edge.incoming == :straight) != (edge.outgoing == :straight)
        if is_line_arc
            push!(indices, i)
        end
    end
    return indices
end
function line_arc_cornerindices(p::CurvilinearPolygon, sty::Polygons.Rounded)
    all_la = line_arc_cornerindices(p)
    isempty(all_la) && return Int[]
    if isempty(p0(sty))
        selected = all_la
    else
        # Match each p0 point to the closest roundable vertex across ALL corner types
        # (straight-straight and line-arc). Only select line-arc corners where the
        # line-arc vertex is genuinely the closest match for that p0 point.
        straight = cornerindices(p)
        all_roundable = vcat(straight, all_la)
        roundable_pts = p.p[all_roundable]
        matched =
            Polygons.cornerindices(roundable_pts, p0(sty); tol=sty.selection_tolerance)
        matched_orig = isempty(matched) ? Int[] : all_roundable[matched]
        selected = filter(i -> i in all_la, matched_orig)
    end
    return sty.inverse_selection ? setdiff(all_la, selected) : selected
end

"""
    edge_type_at_vertex(p::CurvilinearPolygon, i::Int)

For vertex `i`, determine whether the incoming and outgoing edges are straight or curved.

Returns a NamedTuple `(incoming=..., outgoing=...)` where each field is either
`:straight` or the `Paths.Segment` (e.g., `Paths.Turn`) for that edge.

  - **Outgoing edge** (from `p[i]` to `p[i+1]`): curved if any
    `abs(curve_start_idx[k]) == i`
  - **Incoming edge** (from `p[i-1]` to `p[i]`): curved if any
    `abs(curve_start_idx[k]) == mod1(i-1, n)`
"""
function edge_type_at_vertex(p::CurvilinearPolygon, i::Int)
    n = length(p.p)
    prev_i = mod1(i - 1, n)

    incoming = :straight
    outgoing = :straight
    # k = index into curves array, csi = vertex index where curve k starts
    for (k, csi) in enumerate(p.curve_start_idx)
        if abs(csi) == prev_i
            incoming = p.curves[k]
        end
        if abs(csi) == i
            outgoing = p.curves[k]
        end
    end
    return (; incoming=incoming, outgoing=outgoing)
end

"""
    to_polygons(ent::CurvilinearPolygon{S}, sty::Polygons.Rounded{T}; kwargs...)

Apply rounding to a CurvilinearPolygon, handling both straight-straight corners
(using the existing `rounded_corner`) and line-arc corners (using `rounded_corner_line_arc`).

Works on the CurvilinearPolygon's vertex list directly (before curve discretization),
so that arc geometry (center, radius, tangent) is available for the fillet computation.
After rounding all corners, discretizes the remaining curves to produce a plain Polygon.
"""
function to_polygons(
    ent::CurvilinearPolygon{S},
    sty::Polygons.Rounded{T};
    atol=Polygons._round_atol(S, T),
    kwargs...
) where {S, T}
    rad = Polygons.radius(sty)
    iszero(rad) && return to_polygons(ent; kwargs...)

    V = promote_type(float(S), float(T))
    poly = ent.p
    n = length(poly)

    # Get corner indices for both straight-straight and line-arc corners
    straight_corners = cornerindices(ent, sty)
    la_corners = line_arc_cornerindices(ent, sty)

    # Round corners, tracking which original vertex maps to which output range.
    # Also track T_arc for each line-arc corner so we can trim the curves.
    rounded_pts = Point{V}[]
    vertex_ranges = Vector{UnitRange{Int}}(undef, n)
    # For each curve, track trim points: trim_start[k] and trim_end[k]
    # are the T_arc points where the fillet meets the curve at its start/end vertex.
    trim_start = Dict{Int, Point{V}}()  # curve index k → T_arc at curve start vertex
    trim_end = Dict{Int, Point{V}}()    # curve index k → T_arc at curve end vertex

    for i in eachindex(poly)
        start_idx = length(rounded_pts) + 1
        edges = edge_type_at_vertex(ent, i)
        is_line_arc = (edges.incoming == :straight) != (edges.outgoing == :straight)

        if i in straight_corners &&
           edges.incoming == :straight &&
           edges.outgoing == :straight
            # Straight-straight corner: use existing rounded_corner
            append!(
                rounded_pts,
                Polygons.rounded_corner(
                    poly[mod1(i - 1, n)],
                    poly[i],
                    poly[mod1(i + 1, n)],
                    rad,
                    atol=atol,
                    min_side_len=sty.min_side_len,
                    min_angle=sty.min_angle
                )
            )
        elseif i in la_corners &&
               edges.incoming == :straight &&
               edges.outgoing isa Paths.Turn
            # Straight → arc: line is incoming, arc is outgoing
            result = rounded_corner_line_arc(
                poly[mod1(i - 1, n)],
                poly[i],
                edges.outgoing,
                true,
                rad,
                atol=atol,
                min_side_len=sty.min_side_len,
                min_angle=sty.min_angle
            )
            append!(rounded_pts, result.points)
            # Record trim point for the curve starting at this vertex
            if !isnothing(result.T_arc)
                curve_k = findfirst(
                    k -> abs(ent.curve_start_idx[k]) == i,
                    eachindex(ent.curve_start_idx)
                )
                !isnothing(curve_k) && (trim_start[curve_k] = result.T_arc)
            end
        elseif i in la_corners &&
               edges.incoming isa Paths.Turn &&
               edges.outgoing == :straight
            # Arc → straight: arc is incoming, line is outgoing
            result = rounded_corner_line_arc(
                poly[mod1(i + 1, n)],
                poly[i],
                edges.incoming,
                false,
                rad,
                atol=atol,
                min_side_len=sty.min_side_len,
                min_angle=sty.min_angle
            )
            append!(rounded_pts, result.points)
            # Record trim point for the curve ending at this vertex
            if !isnothing(result.T_arc)
                prev_i = mod1(i - 1, n)
                curve_k = findfirst(
                    k -> abs(ent.curve_start_idx[k]) == prev_i,
                    eachindex(ent.curve_start_idx)
                )
                !isnothing(curve_k) && (trim_end[curve_k] = result.T_arc)
            end
        else
            # Non-corner vertex or arc-arc corner: pass through
            push!(rounded_pts, poly[i])
        end
        vertex_ranges[i] = start_idx:length(rounded_pts)
    end

    # Assemble final polygon: interleave rounded vertex points with discretized curves.
    # Curves are trimmed at fillet tangent points when applicable.
    final_points = Point{V}[]
    for i = 1:n
        append!(final_points, rounded_pts[vertex_ranges[i]])

        # If there's a curve starting at vertex i, discretize it (possibly trimmed)
        curve_k =
            findfirst(k -> abs(ent.curve_start_idx[k]) == i, eachindex(ent.curve_start_idx))
        if !isnothing(curve_k)
            c = ent.curves[curve_k]
            csi = ent.curve_start_idx[curve_k]
            arc_len = pathlength(c)

            # Determine trim parameters: find t values for trim points on the arc
            t_start = zero(S)
            t_end = arc_len
            if haskey(trim_start, curve_k)
                # Find the arc parameter closest to T_arc at the start
                T_s = trim_start[curve_k]
                t_start = Paths.pathlength_nearest(c, T_s)
            end
            if haskey(trim_end, curve_k)
                # Find the arc parameter closest to T_arc at the end
                T_e = trim_end[curve_k]
                t_end = Paths.pathlength_nearest(c, T_e)
            end

            # Discretize the trimmed portion of the curve.
            # t_end <= t_start means both fillets overlap (radius too large for arc);
            # the arc is dropped and the fillets connect directly.
            if t_end > t_start
                npts = max(2, Int(ceil(181 * (t_end - t_start) / arc_len)))
                # Remove endpoints (already present as fillet tangent points or vertex points)
                inner = range(t_start, t_end, npts)[(begin + 1):(end - 1)]
                pp = c.(csi < 0 ? reverse(inner) : inner)
                append!(final_points, pp)
            end
        end
    end

    return Polygon(final_points)
end

"""
    rounded_corner_line_arc(
        p_line::Point, p_corner::Point,
        arc_curve::Paths.Turn, arc_is_outgoing::Bool,
        radius;
        atol, min_side_len, min_angle
    )

Compute a fillet arc at the corner where a straight edge meets a circular arc,
using bisection to find the fillet center.

  - `p_line`: the far endpoint of the straight edge (not the corner)
  - `p_corner`: the vertex where the straight edge meets the arc
  - `arc_curve`: the `Paths.Turn` representing the circular arc
  - `arc_is_outgoing`: `true` if the arc leaves from `p_corner`, `false` if it arrives
  - `radius`: fillet radius

Returns a NamedTuple `(; points, T_arc)` where:

  - `points`: vector of discretized fillet arc points (including endpoints)
  - `T_arc`: the tangent point on the existing arc (for trimming), or `nothing` if no fillet

If the fillet cannot be computed, returns `(; points=[p_corner], T_arc=nothing)`.
"""
function rounded_corner_line_arc(
    p_line::Point{T},
    p_corner::Point{T},
    arc_curve::Paths.Turn,
    arc_is_outgoing::Bool,
    radius::S;
    atol=Polygons._round_atol(T, S),
    min_side_len=radius,
    min_angle=1e-3
) where {T, S <: DeviceLayout.Coordinate}
    V = promote_type(T, S)
    r = convert(V, radius)

    # Check straight edge length against min_side_len
    line_len = norm(p_corner - p_line)
    if line_len < min_side_len && !isapprox(line_len, min_side_len, atol=atol)
        return (; points=[p_corner], T_arc=nothing)
    end

    # Line direction: always from p_line toward p_corner.
    # This determines the normal and bisection bracket for both cases.
    v_line = (p_corner - p_line) / line_len
    α_line = atan(v_line.y, v_line.x)

    arc_len = Paths.pathlength(arc_curve)
    α_arc = if arc_is_outgoing
        # Arc starts at p_corner: tangent at t=0
        Paths.direction(arc_curve, zero(arc_len))
    else
        # Arc ends at p_corner: tangent at t=pathlength
        Paths.direction(arc_curve, arc_len)
    end

    # Check if line and arc tangent are nearly parallel (already smooth)
    if isapprox_angle(α_line, α_arc; atol=min_angle)
        return (; points=[p_corner], T_arc=nothing)
    end

    ## Arc geometry
    O = Paths.curvaturecenter(arc_curve)           # arc center
    R = arc_curve.r                                # arc radius

    # Determine which side of the line the polygon interior is on,
    # using the arc tangent direction at the corner as a proxy for the "next" point.
    # Use a coordinate-derived offset to avoid both collinear degeneracy and
    # Unitful ContextUnits mismatches (atol may have different unit context).
    offset_scale = line_len * 1e-6
    p_virtual = p_corner + Point(cos(α_arc), sin(α_arc)) * offset_scale
    turn_sign = DeviceLayout.orientation(p_line, p_corner, p_virtual)
    # For arc_is_outgoing=false, p_line is the NEXT vertex (not the previous),
    # so orientation(p_line, p_corner, p_virtual) gives the reverse winding.
    # Negate to get the correct polygon interior side.
    if !arc_is_outgoing
        turn_sign = -turn_sign
    end
    # If orientation is degenerate (collinear), skip this corner
    if iszero(turn_sign)
        return (; points=[p_corner], T_arc=nothing)
    end

    ## Find the fillet center C_f
    #
    # The fillet is a small rounding arc of radius r that replaces the sharp
    # corner where the straight edge meets the curved arc. C_f is the center
    # of this rounding arc. Once found, the two tangent points follow:
    #   T_line: where the fillet meets the straight edge (foot of perpendicular)
    #   T_arc:  where the fillet meets the curved arc
    #
    # C_f must satisfy two distance constraints:
    #   (1) |C_f to straight edge| = r   → fillet is tangent to the line
    #   (2) |C_f to arc center O|  = D   → fillet is tangent to the arc
    # where D = R + r (external tangency) or |R - r| (internal tangency).
    #
    # Constraint (1) means C_f lies on a line parallel to the straight edge,
    # offset by r toward the polygon interior.
    # Constraint (2) means C_f lies on a circle of radius D centered at O.
    # The intersection of this parallel line with this circle gives C_f
    # analytically (quadratic formula), avoiding iterative bisection.

    # n_line: unit vector perpendicular to v_line, pointing left when facing
    # along v_line. fillet_side: +1 or -1, selects which side of the straight
    # edge the polygon interior (and thus the fillet center) is on.
    n_line = Point(-v_line.y, v_line.x)
    fillet_side = sign(turn_sign)

    # p_offset: a reference point on the parallel line, obtained by shifting
    # p_corner by r toward the interior. The fillet center C_f lies somewhere
    # along this parallel line, but not necessarily at p_offset — it slides
    # along the line direction v_line until constraint (2) is also satisfied.
    p_offset = p_corner + (r * fillet_side) * n_line

    function solve_for_D(D_val)
        # Parameterize the parallel line: C_f(s) = p_offset + s * v_line.
        # Substitute into |C_f - O|² = D² and expand (|v_line| = 1):
        #   s² + 2bs + c = 0
        #   b = w · v_line,  c = |w|² - D²,  w = p_offset - O
        # The discriminant b² - c determines 0 or 2 solutions.
        w = p_offset - O
        b = w.x * v_line.x + w.y * v_line.y
        c = w.x * w.x + w.y * w.y - D_val * D_val
        disc = b * b - c
        disc < zero(disc) && return Point{V}[]
        sq = sqrt(disc)
        s1 = -b + sq
        s2 = -b - sq
        return [p_offset + s * v_line for s in (s1, s2)]
    end

    # Validate that C_f projects onto the actual line segment (between p_line
    # and p_corner), not onto the extension beyond the corner. The wrong
    # tangency type typically overshoots past the corner.
    function validate_t_line(cf)
        t = (cf - p_line).x * v_line.x + (cf - p_line).y * v_line.y
        return -atol < t < line_len + atol
    end

    # Try both tangency types (external and internal). For each, solve the
    # quadratic, discard candidates that project outside the line segment,
    # and pick the one closest to the corner.
    function find_best_center(D_val)
        candidates = solve_for_D(D_val)
        isempty(candidates) && return nothing
        valid = filter(validate_t_line, candidates)
        isempty(valid) && return nothing
        _, idx = findmin(cf -> norm(cf - p_corner), valid)
        return valid[idx]
    end

    C_f_ext = find_best_center(R + r)
    C_f_int = abs(R - r) > zero(R) ? find_best_center(abs(R - r)) : nothing
    ext_ok = !isnothing(C_f_ext)
    int_ok = !isnothing(C_f_int)

    C_f = if ext_ok && int_ok
        norm(C_f_ext - p_corner) < norm(C_f_int - p_corner) ? C_f_ext : C_f_int
    elseif ext_ok
        C_f_ext
    elseif int_ok
        C_f_int
    else
        return (; points=[p_corner], T_arc=nothing)
    end

    # Tangent point on line: foot of perpendicular from C_f to line
    t_proj = (C_f - p_line).x * v_line.x + (C_f - p_line).y * v_line.y
    T_line = p_line + t_proj * v_line

    # Tangent point on arc: point on the arc in the direction of the fillet center
    cf_dir = (C_f - O) / norm(C_f - O)
    T_arc = O + R * cf_dir

    ## Fillet arc angles
    # The fillet arc must follow the polygon winding order:
    #   arc_is_outgoing=true:  polygon goes ...line → T_line → [fillet] → T_arc → arc...
    #   arc_is_outgoing=false: polygon goes ...arc → T_arc → [fillet] → T_line → line...
    α_T_line = atan((T_line - C_f).y, (T_line - C_f).x)
    α_T_arc = atan((T_arc - C_f).y, (T_arc - C_f).x)

    fillet_pts = if arc_is_outgoing
        DeviceLayout.circular_arc([α_T_line, α_T_arc], r, atol, center=C_f)
    else
        DeviceLayout.circular_arc([α_T_arc, α_T_line], r, atol, center=C_f)
    end
    return (; points=fillet_pts, T_arc=T_arc)
end

end # module
