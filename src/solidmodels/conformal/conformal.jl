"""
    ConformalRender

Alternative render strategy for [`SolidModel`](@ref) that emits **shared OCC edge
entities** for adjacent faces, producing conformal geometry without relying on
`_fragment_and_map!` after render.

Motivation: at chip scale (~10⁵ faces), the stock render path creates a distinct
OCC edge per face boundary, then the built-in post-render `_fragment_and_map!` pass
reconciles coincident entities. This is the performance bottleneck for large
geometries.

[`render_conformal!`](@ref) takes a different path: an edge/curve cache
deduplicates OCC entities as they are created, so two adjacent faces requesting
the "same" line or arc receive the same OCC tag. The resulting model is conformal
by construction (assuming the geometry meets certain preconditions, listed below)
and `_fragment_and_map!` is skipped.

[`render_conformal!`](@ref) is an alternative to `render!`, producing a `SolidModel`
that downstream operations (postrender, meshing, save) consume interchangeably.

# Usage

```julia
sm = SolidModel("mymodel"; overwrite=true)
render_conformal!(sm, cs; postrender_ops=..., zmap=..., kwargs...)
```

Same kwargs as `render!`, except `_fragment_and_map!` is not called after
postrender operations (the cache already guarantees conformality on rendered
geometry if preconditions are met). If your postrender operations create new
overlapping entities, or preconditions are not met, use `render!` or
`render_conformal!(...; fragment_backstop=true)`.

# Design notes

  - **Two point-merge tolerances**: polygon vertices use a **relaxed** tolerance
    (default 2 nm) to support geometries with sliver edges, such as those arising from
    curve intersections calculated using the default discretization tolerance of 1 nm.
    Arc centers and BSpline control points use the strict tolerance
    (`POINT_MERGE_ATOL`) — merging those at the relaxed tolerance would corrupt
    geometry.
  - **Per-render cache**: the cache lives on a [`ConformalRenderContext`](@ref) struct
    passed through calls. There is no global mutable state — one render, one
    context.
"""
module ConformalRender

using ..SolidModels
using ..SolidModels:
    SolidModel,
    OpenCascade,
    kernel,
    STP_UNIT,
    POINT_MERGE_ATOL,
    _render_orchestrator!,
    _fragment_three_pass!,
    _add_curve!,
    _get_or_add_point!
import DeviceLayout
import DeviceLayout:
    AbstractCoordinateSystem,
    AbstractPolygon,
    CurvilinearPolygon,
    CurvilinearRegion,
    LineSegment,
    Meta,
    Point,
    Paths,
    getx,
    gety,
    points,
    coordinatetype,
    onenanometer
import DeviceLayout.Paths: bspline_approximation, pathlength
import Unitful: ustrip, Length, @u_str, °
import SpatialIndexing
import SpatialIndexing: RTree

export render_conformal!, ConformalRenderContext, add_conformal_loop!

"""
Entry in `endpoint_curve_index`: the signed OCC tag of the curve, plus a
midpoint sample used to distinguish geometrically-different curves that
happen to share both endpoints (e.g. two curves crossing to form a lens).
The midpoint is stored in STP-unit coordinates in the canonical (min-endpoint
→ max-endpoint) orientation.
"""
struct EndpointCurveEntry
    signed_tag::Int
    midpoint::NTuple{3, Float64}
end

"""
    ConformalRenderContext(; vertex_merge_atol=2e-3, center_merge_atol=POINT_MERGE_ATOL)

Per-render cache and settings for a `render_conformal!` call.

  - `vertex_merge_atol` (µm): tolerance for merging polygon-vertex OCC points.
    Default `2e-3` µm = 2 nm, chosen to absorb chord errors from curve intersections
    calculated using the default discretization tolerance of 1 nm. Also used as the
    tolerance for the curve-midpoint geometric check.
  - `center_merge_atol` (µm): tolerance for merging arc centers and BSpline control
    points. Kept strict (`POINT_MERGE_ATOL` = 1e-9 µm = 1 pm) because relaxing here
    would corrupt curve geometry.
  - `curve_cache`: exact dedup by `(type, geometry_key…)`. Same request → same tag.
  - `endpoint_curve_index`: `(min_pt, max_pt) → EndpointCurveEntry`, registered
    by arcs and splines. Enforces the "prefer curve" invariant subject to a
    midpoint match.
  - `point_coords`: `tag → (x, y, z)`, populated for every point emitted through
    the cached point helpers. Used to compute curve midpoints without a
    Gmsh round-trip.
  - `stats`: telemetry (hits, misses, arcs, splines, chord fallbacks,
    midpoint rejections).
"""
mutable struct ConformalRenderContext
    vertex_merge_atol::Float64
    center_merge_atol::Float64
    curve_cache::Dict{Tuple, Int}
    endpoint_curve_index::Dict{Tuple{Int, Int}, EndpointCurveEntry}
    point_coords::Dict{Int, NTuple{3, Float64}}
    stats::Dict{Symbol, Int}
end

ConformalRenderContext(;
    vertex_merge_atol::Float64=2e-3,
    center_merge_atol::Float64=POINT_MERGE_ATOL
) = ConformalRenderContext(
    vertex_merge_atol,
    center_merge_atol,
    Dict{Tuple, Int}(),
    Dict{Tuple{Int, Int}, EndpointCurveEntry}(),
    Dict{Int, NTuple{3, Float64}}(),
    Dict{Symbol, Int}(
        :hits => 0,
        :misses => 0,
        :arcs => 0,
        :splines => 0,
        :chord_fallbacks => 0,
        :midpoint_rejections => 0
    )
)

# Return true if two midpoints agree to within the context's vertex tolerance.
_midpoint_match(a::NTuple{3, Float64}, b::NTuple{3, Float64}, atol::Float64) =
    abs(a[1] - b[1]) <= atol && abs(a[2] - b[2]) <= atol && abs(a[3] - b[3]) <= atol

# ─── Point merge ─────────────────────────────────────────────────────────────

# Vertex-precision (relaxed) point insert. Used for polygon vertices where the
# two sides of a shared boundary may differ by ~1.5 nm.
function _cached_point_relaxed!(
    k,
    ctx::ConformalRenderContext,
    x::Float64,
    y::Float64,
    z::Float64,
    points_cache
)
    tag =
        isnothing(points_cache) ? k.add_point(x, y, z) :
        _get_or_add_point!(k, x, y, z, points_cache; atol=ctx.vertex_merge_atol)
    # Record coords for later midpoint computation; the tag returned by
    # `_get_or_add_point!` may correspond to a previously-inserted nearby point,
    # so `get!` preserves the first-writer coords rather than overwriting.
    get!(ctx.point_coords, tag, (x, y, z))
    return tag
end

# Strict point insert. Used for arc centers and BSpline control points where
# any merge would corrupt geometry.
function _cached_point_strict!(
    k,
    ctx::ConformalRenderContext,
    x::Float64,
    y::Float64,
    z::Float64,
    points_cache
)
    tag =
        isnothing(points_cache) ? k.add_point(x, y, z) :
        _get_or_add_point!(k, x, y, z, points_cache; atol=ctx.center_merge_atol)
    get!(ctx.point_coords, tag, (x, y, z))
    return tag
end

# ─── Edge/curve cache ────────────────────────────────────────────────────────

# Add a line, dedup on unordered endpoint pair. A cached curve on the same
# endpoints (arc or spline) is reused ONLY if its stored midpoint matches the
# line's midpoint at `vertex_merge_atol` — this prevents fusing genuinely
# different curves that happen to share endpoints (see preconditions 2-3).
function _cached_add_line!(k, ctx::ConformalRenderContext, p1::Integer, p2::Integer)
    p1 == p2 && error("degenerate edge: p1 == p2 == $p1")
    lo, hi = minmax(p1, p2)
    key = (:line, lo, hi)
    existing = get(ctx.curve_cache, key, nothing)
    if !isnothing(existing)
        ctx.stats[:hits] += 1
        return p1 < p2 ? existing : -existing
    end
    # Prefer-curve: a curve already spans these endpoints → reuse only if the
    # midpoint agrees. A line's midpoint is the average of its endpoints.
    existing_curve = get(ctx.endpoint_curve_index, (lo, hi), nothing)
    if !isnothing(existing_curve)
        lo_xyz = get(ctx.point_coords, lo, nothing)
        hi_xyz = get(ctx.point_coords, hi, nothing)
        if !isnothing(lo_xyz) && !isnothing(hi_xyz)
            line_mid = (
                0.5 * (lo_xyz[1] + hi_xyz[1]),
                0.5 * (lo_xyz[2] + hi_xyz[2]),
                0.5 * (lo_xyz[3] + hi_xyz[3])
            )
            if _midpoint_match(line_mid, existing_curve.midpoint, ctx.vertex_merge_atol)
                ctx.stats[:hits] += 1
                return p1 < p2 ? existing_curve.signed_tag : -existing_curve.signed_tag
            end
            ctx.stats[:midpoint_rejections] += 1
        else
            # Missing coord entry — err on the side of not fusing so we don't
            # silently collapse curves whose midpoints we can't verify.
            ctx.stats[:midpoint_rejections] += 1
        end
    end
    ctx.stats[:misses] += 1
    tag = k.addLine(p1, p2)
    ctx.curve_cache[key] = p1 < p2 ? tag : -tag
    return tag
end

# Midpoint of a circular arc (|α| < 180°, guaranteed by the caller-side arc
# splitting) whose endpoints are on a circle centered at `c` with radius
# `r = |p1 - c|`. Returned in the (min-endpoint, max-endpoint) orientation so
# it can be compared against a stored midpoint regardless of traversal
# direction.
function _arc_midpoint(
    p1_xyz::NTuple{3, Float64},
    p2_xyz::NTuple{3, Float64},
    center_xyz::NTuple{3, Float64}
)
    cx, cy, cz = center_xyz
    chord_mid = (
        0.5 * (p1_xyz[1] + p2_xyz[1]),
        0.5 * (p1_xyz[2] + p2_xyz[2]),
        0.5 * (p1_xyz[3] + p2_xyz[3])
    )
    dx = chord_mid[1] - cx
    dy = chord_mid[2] - cy
    dz = chord_mid[3] - cz
    n = sqrt(dx * dx + dy * dy + dz * dz)
    r = sqrt((p1_xyz[1] - cx)^2 + (p1_xyz[2] - cy)^2 + (p1_xyz[3] - cz)^2)
    n == 0.0 && return chord_mid  # semicircle degenerate; caller should split
    return (cx + r * dx / n, cy + r * dy / n, cz + r * dz / n)
end

# Add a circle arc. Registers in the endpoint index so subsequent requests on
# the same endpoints can reuse this arc — but only when the requester's own
# midpoint matches, so genuinely different curves are not silently fused.
function _cached_add_arc!(
    k,
    ctx::ConformalRenderContext,
    p1::Integer,
    center::Integer,
    p2::Integer
)
    lo, hi = minmax(p1, p2)
    # Exact arc (center in key): the same Turn requested again → same tag.
    key = (:arc, lo, center, hi)
    existing = get(ctx.curve_cache, key, nothing)
    if !isnothing(existing)
        ctx.stats[:hits] += 1
        return p1 < p2 ? existing : -existing
    end
    p1_xyz = get(ctx.point_coords, p1, nothing)
    p2_xyz = get(ctx.point_coords, p2, nothing)
    center_xyz = get(ctx.point_coords, center, nothing)
    have_coords = !isnothing(p1_xyz) && !isnothing(p2_xyz) && !isnothing(center_xyz)
    arc_mid = have_coords ? _arc_midpoint(p1_xyz, p2_xyz, center_xyz) : nothing
    # Any curve already on these endpoints → reuse only if its midpoint
    # matches this arc's midpoint.
    existing_curve = get(ctx.endpoint_curve_index, (lo, hi), nothing)
    if !isnothing(existing_curve) && !isnothing(arc_mid)
        if _midpoint_match(arc_mid, existing_curve.midpoint, ctx.vertex_merge_atol)
            ctx.stats[:hits] += 1
            return p1 < p2 ? existing_curve.signed_tag : -existing_curve.signed_tag
        end
        ctx.stats[:midpoint_rejections] += 1
    end
    # Conformality backstop: a chord was already created on these endpoints
    # (the other side rendered this boundary as a line because it did not
    # recover the arc). Reuse the chord so both faces share one tag ONLY when
    # the chord and arc midpoints agree (very tight arcs, r/chord ≈ 1).
    # Otherwise reusing the chord silently substitutes a line for an arc.
    existing_line = get(ctx.curve_cache, (:line, lo, hi), nothing)
    if !isnothing(existing_line) && !isnothing(arc_mid) && have_coords
        chord_mid = (
            0.5 * (p1_xyz[1] + p2_xyz[1]),
            0.5 * (p1_xyz[2] + p2_xyz[2]),
            0.5 * (p1_xyz[3] + p2_xyz[3])
        )
        if _midpoint_match(arc_mid, chord_mid, ctx.vertex_merge_atol)
            ctx.stats[:hits] += 1
            ctx.stats[:chord_fallbacks] += 1
            return p1 < p2 ? existing_line : -existing_line
        end
    end
    ctx.stats[:misses] += 1
    ctx.stats[:arcs] += 1
    tag = k.add_circle_arc(p1, center, p2, -1)
    signed_tag = p1 < p2 ? tag : -tag
    ctx.curve_cache[key] = signed_tag
    if !isnothing(arc_mid)
        ctx.endpoint_curve_index[(lo, hi)] = EndpointCurveEntry(signed_tag, arc_mid)
    end
    return tag
end

# Add an interpolating BSpline. Deduped by exact control-net; unified with its
# reversal; and participates in the prefer-curve invariant via
# `endpoint_curve_index` — a later request for a line (or arc) on the same
# endpoints will reuse this spline instead of creating a duplicate edge.
# Approximate midpoint of an interpolating BSpline from its control points.
# For our (endpoint-anchored) BSplines the middle interior control point is a
# good proxy for the geometric midpoint; when the control net is short we fall
# back to the chord midpoint.
function _spline_midpoint(ctx::ConformalRenderContext, pts::Vector{<:Integer})
    coords = [get(ctx.point_coords, p, nothing) for p in pts]
    all(!isnothing, coords) || return nothing
    n = length(coords)
    if n == 2
        return (
            0.5 * (coords[1][1] + coords[2][1]),
            0.5 * (coords[1][2] + coords[2][2]),
            0.5 * (coords[1][3] + coords[2][3])
        )
    elseif isodd(n)
        return coords[(n + 1) ÷ 2]
    else
        a = coords[n ÷ 2]
        b = coords[n ÷ 2 + 1]
        return (0.5 * (a[1] + b[1]), 0.5 * (a[2] + b[2]), 0.5 * (a[3] + b[3]))
    end
end

function _cached_add_spline!(
    k,
    ctx::ConformalRenderContext,
    pts::Vector{<:Integer},
    tangents
)
    p1, p2 = pts[1], pts[end]
    lo, hi = minmax(p1, p2)
    key = (:bspline, pts...)
    existing = get(ctx.curve_cache, key, nothing)
    if !isnothing(existing)
        ctx.stats[:hits] += 1
        return existing
    end
    rkey = (:bspline, reverse(pts)...)
    existing_r = get(ctx.curve_cache, rkey, nothing)
    if !isnothing(existing_r)
        ctx.stats[:hits] += 1
        return -existing_r
    end
    # Any curve already on these endpoints → reuse only if the midpoint agrees.
    spline_mid = _spline_midpoint(ctx, pts)
    existing_curve = get(ctx.endpoint_curve_index, (lo, hi), nothing)
    if !isnothing(existing_curve) && !isnothing(spline_mid)
        if _midpoint_match(spline_mid, existing_curve.midpoint, ctx.vertex_merge_atol)
            ctx.stats[:hits] += 1
            return p1 < p2 ? existing_curve.signed_tag : -existing_curve.signed_tag
        end
        ctx.stats[:midpoint_rejections] += 1
    end
    ctx.stats[:misses] += 1
    ctx.stats[:splines] += 1
    tag = k.addSpline(pts, -1, tangents)
    signed_tag = p1 < p2 ? tag : -tag
    ctx.curve_cache[key] = tag
    if !isnothing(spline_mid)
        ctx.endpoint_curve_index[(lo, hi)] = EndpointCurveEntry(signed_tag, spline_mid)
    end
    return tag
end

# ─── Primitive-to-OCC entity dispatch ────────────────────────────────────────

# CurvilinearPolygon → CurvilinearRegion path
_add_conformal!(
    ctx::ConformalRenderContext,
    x::CurvilinearPolygon,
    m::Meta,
    k;
    zmap=(_) -> zero(coordinatetype(x)),
    points_cache=nothing,
    kwargs...
) = _add_conformal!(
    ctx,
    CurvilinearRegion(x),
    m,
    k;
    zmap=zmap,
    points_cache=points_cache,
    kwargs...
)

# CurvilinearRegion: single add_plane_surface call with hole loops. Stock
# render! creates the outer surface, then a surface per hole, then k.cut()s
# each hole. The multi-loop form is one OCC call and preserves shared points
# naturally, which is what we need for conformal rendering.
function _add_conformal!(
    ctx::ConformalRenderContext,
    surf::CurvilinearRegion{T},
    m::Meta,
    k::OpenCascade;
    zmap=(_) -> zero(T),
    points_cache=nothing,
    atol=onenanometer(T),
    kwargs...
) where {T}
    z = zmap(m)
    outer_loop = _add_conformal_loop!(ctx, surf.exterior, k, z; points_cache, atol)
    hole_loops = _add_conformal_loop!.(Ref(ctx), surf.holes, k, z; points_cache, atol)
    surftag = k.add_plane_surface([outer_loop; hole_loops...])
    return (Int32(2), surftag)
end

# Plain polygon path (rectilinear).
function _add_conformal!(
    ctx::ConformalRenderContext,
    poly::AbstractPolygon{T},
    m::Meta,
    k::OpenCascade;
    zmap=(_) -> zero(T),
    points_cache=nothing,
    atol=onenanometer(T),
    kwargs...
) where {T}
    z = zmap(m)
    loop = _add_conformal_loop!(
        ctx,
        CurvilinearPolygon(points(poly)),
        k,
        z;
        points_cache,
        atol
    )
    surf = k.add_plane_surface([loop])
    return (Int32(2), surf)
end

# Line segment path (1D entity).
function _add_conformal!(
    ctx::ConformalRenderContext,
    line::LineSegment{T},
    m::Meta,
    k::OpenCascade;
    zmap=(_) -> zero(T),
    points_cache=nothing,
    atol=onenanometer(T),
    kwargs...
) where {T}
    z = zmap(m)
    p0 = _cached_point_relaxed!(
        k,
        ctx,
        Float64(ustrip(STP_UNIT, getx(line.p0))),
        Float64(ustrip(STP_UNIT, gety(line.p0))),
        Float64(ustrip(STP_UNIT, z)),
        points_cache
    )
    p1 = _cached_point_relaxed!(
        k,
        ctx,
        Float64(ustrip(STP_UNIT, getx(line.p1))),
        Float64(ustrip(STP_UNIT, gety(line.p1))),
        Float64(ustrip(STP_UNIT, z)),
        points_cache
    )
    linetag = _cached_add_line!(k, ctx, p0, p1)
    return (Int32(1), linetag)
end

# Broadcast dispatcher — top-level entry from render_conformal!'s metadata loop.
# `render_conformal!` guards `kernel(sm) isa OpenCascade` at entry so we don't
# need a per-primitive GmshNative rejection method here.
_add_conformal!(ctx::ConformalRenderContext, els::AbstractVector, m::Meta, k; kwargs...) =
    [_add_conformal!(ctx, el, m, k; kwargs...) for el in els]

# ─── Curve loop assembly ─────────────────────────────────────────────────────

"""
    add_conformal_loop!(ctx::ConformalRenderContext, cl::CurvilinearPolygon,
        k::OpenCascade, z; points_cache=nothing, atol=onenanometer(...))

Build an OCC curve loop for `cl` using the conformal edge/curve cache.

This is the public seam for callers that build OCC geometry themselves (rather
than using [`render_conformal!`](@ref)'s orchestrator). Typical usage:

```julia
ctx = ConformalRenderContext()
points_cache = SpatialIndexing.RTree{Float64, 3}(Int32)
for region in regions
    outer = add_conformal_loop!(ctx, region.exterior, k, z; points_cache)
    holes = [add_conformal_loop!(ctx, h, k, z; points_cache) for h in region.holes]
    k.add_plane_surface([outer; holes...])
end
```

Adjacent regions that share a boundary curve will resolve to the same OCC edge
tag via the cache, producing conformal geometry without `_fragment_and_map!`.
"""
function add_conformal_loop!(
    ctx::ConformalRenderContext,
    cl::CurvilinearPolygon,
    k::OpenCascade,
    z;
    points_cache=nothing,
    atol=onenanometer(coordinatetype(cl))
)
    return _add_conformal_loop!(ctx, cl, k, z; points_cache, atol)
end

function _add_conformal_loop!(
    ctx::ConformalRenderContext,
    cl::CurvilinearPolygon,
    k::OpenCascade,
    z;
    points_cache=nothing,
    atol=onenanometer(coordinatetype(cl))
)
    poly_pts = points(cl)
    pts = [
        _cached_point_relaxed!(
            k,
            ctx,
            Float64(ustrip(STP_UNIT, getx(p))),
            Float64(ustrip(STP_UNIT, gety(p))),
            Float64(ustrip(STP_UNIT, z)),
            points_cache
        ) for p in poly_pts
    ]
    n = length(pts)
    curve_set = Set(cl.curve_start_idx)
    curves_out = Int32[]
    for i = 1:n
        j = mod1(i + 1, n)
        if i in curve_set
            curve_idx = findfirst(isequal(i), cl.curve_start_idx)
            endpoints = (pts[i], pts[j])
            result = _add_conformal_curve!(
                ctx,
                endpoints,
                cl.curves[curve_idx],
                k,
                z,
                points_cache;
                atol
            )
            if result isa AbstractVector
                append!(curves_out, result)
            else
                push!(curves_out, result)
            end
        else
            # Drop zero-length edges that collapse when adjacent contour vertices
            # merge at the relaxed tolerance. The near-duplicate pair is
            # identical on both sides of a shared boundary, so both faces drop
            # the same edge → still conformal.
            pts[i] == pts[j] && continue
            push!(curves_out, _cached_add_line!(k, ctx, pts[i], pts[j]))
        end
    end
    return k.add_curve_loop(curves_out)
end

# ─── Curve dispatch (arcs, BSplines, offsets) ────────────────────────────────

# Circular arc: exact, cached by (endpoints, center) with strict-tolerance
# center dedup so a Turn traversed from both sides collapses to one OCC entity.
function _add_conformal_curve!(
    ctx::ConformalRenderContext,
    endpoints,
    seg::Paths.Turn,
    k::OpenCascade,
    z,
    points_cache;
    kwargs...
)
    center_pt =
        seg.p0 +
        Point(-seg.r * sign(seg.α) * sin(seg.α0), seg.r * sign(seg.α) * cos(seg.α0))
    cen = _cached_point_strict!(
        k,
        ctx,
        Float64(ustrip(STP_UNIT, getx(center_pt))),
        Float64(ustrip(STP_UNIT, gety(center_pt))),
        Float64(ustrip(STP_UNIT, z)),
        points_cache
    )

    if abs(seg.α) >= 180°
        n_180 = abs(seg.α) / 180°
        n_arcs = ceil(n_180) == n_180 ? Int(n_180 + 1) : Int(ceil(n_180))
        arclengths = range(zero(pathlength(seg)), pathlength(seg), length=n_arcs + 1)
        middle_pts = seg.(arclengths[(begin + 1):(end - 1)])
        middle_tags = [
            _cached_point_strict!(
                k,
                ctx,
                Float64(ustrip(STP_UNIT, getx(mp))),
                Float64(ustrip(STP_UNIT, gety(mp))),
                Float64(ustrip(STP_UNIT, z)),
                points_cache
            ) for mp in middle_pts
        ]
        tags = [endpoints[1]; middle_tags; endpoints[2]]
        return [
            _cached_add_arc!(k, ctx, tags[i], cen, tags[i + 1]) for i = 1:(length(tags) - 1)
        ]
    end

    try
        return _cached_add_arc!(k, ctx, endpoints[1], cen, endpoints[2])
    catch e
        if e isa ErrorException && contains(e.msg, "Could not create circle arc")
            ctx.stats[:chord_fallbacks] += 1
            return _cached_add_line!(k, ctx, endpoints[1], endpoints[2])
        end
        rethrow()
    end
end

# Interpolating BSpline: exact, cached by control-net; strict tolerance on
# intermediate control points so a spline traversed from both sides collapses
# to one OCC entity.
function _add_conformal_curve!(
    ctx::ConformalRenderContext,
    endpoints,
    seg::Paths.BSpline,
    k::OpenCascade,
    z,
    points_cache;
    kwargs...
)
    midpts = [
        _cached_point_strict!(
            k,
            ctx,
            Float64(ustrip(STP_UNIT, getx(p))),
            Float64(ustrip(STP_UNIT, gety(p))),
            Float64(ustrip(STP_UNIT, z)),
            points_cache
        ) for p in seg.p[2:(end - 1)]
    ]
    pts = [endpoints[1], midpts..., endpoints[2]]
    tangents = [
        ustrip(STP_UNIT, seg.t0.x),
        ustrip(STP_UNIT, seg.t0.y),
        0.0,
        ustrip(STP_UNIT, seg.t1.x),
        ustrip(STP_UNIT, seg.t1.y),
        0.0
    ]
    return _cached_add_spline!(k, ctx, pts, tangents)
end

# Offset segment: a constant offset of a Turn is still a circular arc (exact);
# general offset (variable, or offset of a BSpline) is approximated by a
# BSpline chain with join points at the RELAXED tolerance so sub-splines
# produced from opposite traversal directions unify.
function _add_conformal_curve!(
    ctx::ConformalRenderContext,
    endpoints,
    seg::Paths.OffsetSegment,
    k::OpenCascade,
    z,
    points_cache;
    kwargs...
)
    base = seg.seg
    off = seg.offset
    # Constant offset of a Turn: still a circular arc, exact.
    if base isa Paths.Turn && off isa DeviceLayout.Coordinate
        off_turn = Paths.Turn(
            base.α,
            base.r - sign(base.α) * off,
            base.p0 + Point(-sin(base.α0), cos(base.α0)) * off,
            base.α0
        )
        return _add_conformal_curve!(
            ctx,
            endpoints,
            off_turn,
            k,
            z,
            points_cache;
            kwargs...
        )
    end
    # General case (offset BSpline / variable offset). `bspline_approximation`
    # is NOT direction-symmetric: calling it on `seg` and on `Paths.reverse(seg)`
    # produces ulp-level different join coordinates on the SAME geometric curve.
    # The RELAXED merge unifies them; the strict merge does not.
    atol_local = onenanometer(coordinatetype(Paths.p0(seg)))
    approx = bspline_approximation(seg; atol=atol_local)
    newstarts = DeviceLayout.p0.(approx.segments)[2:end]
    newpts = [
        _cached_point_relaxed!(
            k,
            ctx,
            Float64(ustrip(STP_UNIT, getx(p))),
            Float64(ustrip(STP_UNIT, gety(p))),
            Float64(ustrip(STP_UNIT, z)),
            points_cache
        ) for p in newstarts
    ]
    starts = [endpoints[1], newpts...]
    stops = [newpts..., endpoints[2]]
    tags = Int32[]
    for (ep, sub) in zip([[s, e] for (s, e) in zip(starts, stops)], approx.segments)
        t = _add_conformal_curve!(ctx, ep, sub, k, z, points_cache; kwargs...)
        if t isa AbstractVector
            append!(tags, t)
        else
            push!(tags, t)
        end
    end
    return tags
end

# Unsupported segment types fail loud rather than routing through the stock
# `_add_curve!` — the stock fallback would BSpline-approximate anything it
# received, including a Straight, and the resulting edge would not participate
# in the cache and would break conformality with the caching side of a shared
# boundary. Straights should never reach here because they do not appear in
# `CurvilinearPolygon` unless the caller has hand-constructed one; any other
# `Paths.Segment` subtype landing here is a real gap we want visible.
_add_conformal_curve!(
    ctx::ConformalRenderContext,
    endpoints,
    seg::Paths.Segment,
    k::OpenCascade,
    z,
    points_cache;
    kwargs...
) = throw(
    ArgumentError(
        "ConformalRender: unsupported curve segment type $(typeof(seg)); " *
        "specialize `_add_conformal_curve!` for this type or preprocess it to " *
        "one of `Paths.Turn`, `Paths.BSpline`, or `Paths.OffsetSegment`."
    )
)

# ─── Public entry point ──────────────────────────────────────────────────────

"""
    render_conformal!(sm::SolidModel, cs::AbstractCoordinateSystem;
        context=ConformalRenderContext(),
        fragment_backstop=false, kwargs...)

Render `cs` into `sm` using the ConformalRender strategy. Delegates to the
same shared orchestrator as [`render!`](@ref); the only differences are:

  - OCC entities are emitted via the cached `_add_conformal!` path, so shared
    boundaries between adjacent faces resolve to a single OCC edge.
  - The post-render `_fragment_and_map!` pass is skipped by default because
    the cache already guarantees conformality on rendered geometry if preconditions are met (see below).

Accepts all of `render!`'s keyword arguments (`map_meta`, `postrender_ops`,
`retained_physical_groups`, `zmap`, `gmsh_options`, `skip_postrender`,
`auto_union`, `skip_unused_layers`, `curvature_sizing`, `meshing_parameters`) in addition to:

  - `context::ConformalRenderContext`: the edge/curve cache and merge tolerances.
    Pass an explicit context to customize tolerances or inspect cache stats
    after the render.
  - `fragment_backstop::Bool=false`: run the stock 3-pass `_fragment_and_map!`
    after postrender operations. Enable when your input violates preconditions 1-3
    (overlapping areas at the same z, overlapping edges, or intersecting edges),
    which the cache does not resolve on its own, or when postrender operations create
    non-conformal geometry.

Not supported on `GmshNative` kernel.

# Preconditions

To produce correct, conformal geometry:

 1. **No overlapping areas in the same plane.**
    The cache builds curve loops face-by-face; overlaps between faces at the
    same z height (whether within one physical group or across two) are not detected
    or resolved.
 2. **Shared boundaries share endpoints.**
    In other words, there should be no partially overlapping edges.
    If two faces share a boundary, the boundary should resolve to the same geometric curve with
    the same endpoints (or the reversed curve).
 3. **Boundaries intersect only at endpoints.**
    Curves with interior intersections will not produce conformal geometry.
    Additionally, if two distinct edges share endpoints and a midpoint,
    the cache will not distinguish them and they will collapse to a single curve.
 4. **Relaxed vertex merge is safe.**
    If you have small features such that merging vertices within 2nm meaningfully
    affects the geometry, use `ConformalRenderContext(; vertex_merge_atol=…)` to tighten
    the merge tolerance.

`fragment_backstop=true` helps with preconditions (1), (2), and non-midpoint
intersections in (3). It does not recover from distinct curves with the same endpoints
and midpoint being collapsed, or corruption of geometry by the relaxed vertex merge.
"""
function render_conformal!(
    sm::SolidModel,
    cs::AbstractCoordinateSystem{T};
    context::ConformalRenderContext=ConformalRenderContext(),
    fragment_backstop::Bool=false,
    kwargs...
) where {T}
    kernel(sm) isa OpenCascade || error(
        "render_conformal! is only implemented for OpenCascade kernel; " *
        "got $(typeof(kernel(sm))). Use render! instead."
    )
    return _render_orchestrator!(
        sm,
        cs;
        (emit!)=(els, meta, k; zmap, points_cache, kwargs...) -> _add_conformal!(
            context,
            els,
            meta,
            k;
            zmap=zmap,
            points_cache=points_cache,
            kwargs...
        ),
        (fragment!)=fragment_backstop ? _fragment_three_pass! : (_) -> nothing,
        kwargs...
    )
end

end # module ConformalRender
