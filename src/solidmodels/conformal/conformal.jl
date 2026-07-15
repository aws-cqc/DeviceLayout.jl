"""
    ConformalRender

Alternative render strategy for [`SolidModel`](@ref) that emits **shared OCC edge
entities** for adjacent faces, producing conformal geometry without relying on
`_fragment_and_map!` after render.

Motivation: at chip scale (~10⁵ faces), the stock render path creates a distinct
OCC edge/point per face boundary, then the post-render `_fragment_and_map!` pass
reconciles coincident entities. That reconciliation is `O(N²)` and, at production
scale, non-manifold artifacts can survive it.

`render_conformal!` takes a different path: an in-process **edge/curve cache**
deduplicates OCC entities as they are created, so two adjacent faces requesting
the "same" line or arc receive the same OCC tag. The resulting model is conformal
by construction and `_fragment_and_map!` is skipped.

The stock [`render!`](@ref) is left unchanged; `render_conformal!` is a parallel
entry point that shares the [`SolidModel`](@ref) type and produces a `SolidModel`
that downstream operations (postrender, meshing, save) consume interchangeably.

# Usage

```julia
sm = SolidModel("mymodel"; overwrite=true)
render_conformal!(sm, cs; postrender_ops=..., zmap=..., kwargs...)
```

Same kwargs as `render!`, except `_fragment_and_map!` is not called after
postrender operations (the cache already guarantees conformality on rendered
geometry). If your postrender operations create new overlapping entities, use
`render!` instead (or call `_fragment_and_map!` explicitly).

# Design notes

  - **Two point-merge tolerances**: polygon vertices use a **relaxed** tolerance
    (default 2 nm) because Clipper's integer-grid output and DeviceLayout's
    `discretize_curve` float drift can leave the two sides of a shared boundary
    ~1.5 nm apart. Arc centers and BSpline control points use the strict tolerance
    (`POINT_MERGE_ATOL`) — merging those at the relaxed tolerance would corrupt
    geometry.
  - **Prefer-curve invariant**: when a curve (arc or spline) exists on endpoints
    `(e1, e2)`, every subsequent request on `(e1, e2)` — line or arc — returns
    that curve. This is the "curve wins" rule that makes adjacent faces resolve
    to one OCC entity even when one side computed a line and the other an arc.
  - **Per-render cache**: the cache lives on a `ConformalRenderContext` struct
    passed through calls. There is no global mutable state; nested/parallel
    renders are safe.

# Preconditions

For the cache to produce correct geometry:

 1. **Shared endpoints ⟹ shared curve geometry.** If two faces share a boundary,
    the CurvilinearPolygon points on both sides must resolve to the same OCC
    point tags AND the curves spanning those tags must be the same geometric
    curve. Callers can meet this by having both faces reference the same
    `Paths.Segment` object (the "coordinated recovery" pattern from
    `union2d_curved` where both operands are matched against the same
    boolean-recovery ProvenanceRun), or by an upstream mutual-noding pass.
 2. **No distinct co-endpoint edges.** The prefer-curve rule fuses curve
    requests on shared endpoints into a single OCC tag. If your geometry
    genuinely has two distinct edges spanning the same two points (say, a
    figure-8 pinch or a self-crossing offset curve), the cache will wrongly
    merge them.
 3. **Relaxed vertex merge is safe iff features > 500× the merge tolerance.**
    The default 2 nm merge is 500× smaller than a 1 µm minimum feature. If
    you have features ~10× smaller, use `ConformalRenderContext(; vertex_merge_atol=…)` to tighten.

When any of these are uncertain, `render_conformal!(..., fragment_backstop=true)`
runs the stock 3-pass `_fragment_and_map!` after postrender as a safety net.
"""
module ConformalRender

using ..SolidModels
using ..SolidModels:
    SolidModel,
    OpenCascade,
    GmshNative,
    kernel,
    gmsh,
    STP_UNIT,
    POINT_MERGE_ATOL,
    _synchronize!,
    _add_curve!,
    _get_or_add_point!,
    _postrender!,
    _fragment_and_map!,
    _get_or_add_points!,
    _stp_float,
    _collect_mesh_control_points!,
    _used_group_names,
    sizeandgrading,
    to_primitives,
    clear_mesh_control_points!,
    finalize_size_fields!,
    set_gmsh_option,
    dimgroupdict,
    dimtags,
    hasgroup,
    remove_group!,
    reindex_physical_groups!
import ..SolidModels: gmsh_meshsize
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
    flatten,
    elements,
    element_metadata,
    coordinatetype,
    onenanometer,
    layer
import DeviceLayout.Paths: bspline_approximation, pathlength
import Unitful: ustrip, Length, @u_str, °
import SpatialIndexing
import SpatialIndexing: RTree

export render_conformal!, ConformalRenderContext, add_conformal_loop!

"""
    ConformalRenderContext(; vertex_merge_atol=2e-3, center_merge_atol=POINT_MERGE_ATOL)

Per-render cache and settings for a `render_conformal!` call.

  - `vertex_merge_atol` (µm): tolerance for merging polygon-vertex OCC points.
    Default `2e-3` µm = 2 nm, chosen to absorb Clipper integer-grid + float-drift
    divergence between the two sides of a shared boundary (~1.5 nm observed) while
    staying 500× below typical minimum feature size (1 µm).
  - `center_merge_atol` (µm): tolerance for merging arc centers and BSpline control
    points. Kept strict (`POINT_MERGE_ATOL` = 1e-9 µm = 1 pm) because relaxing here
    would corrupt curve geometry.
  - `curve_cache`: exact dedup by `(type, geometry_key…)`. Same request → same tag.
  - `endpoint_curve_index`: `(min_pt, max_pt) → tag`, registered by arcs and
    splines. Enforces the "prefer curve" invariant.
  - `stats`: telemetry (hits, misses, arcs, splines, chord fallbacks).
"""
mutable struct ConformalRenderContext
    vertex_merge_atol::Float64
    center_merge_atol::Float64
    curve_cache::Dict{Tuple, Int}
    endpoint_curve_index::Dict{Tuple{Int, Int}, Int}
    stats::Dict{Symbol, Int}
end

ConformalRenderContext(;
    vertex_merge_atol::Float64=2e-3,
    center_merge_atol::Float64=POINT_MERGE_ATOL
) = ConformalRenderContext(
    vertex_merge_atol,
    center_merge_atol,
    Dict{Tuple, Int}(),
    Dict{Tuple{Int, Int}, Int}(),
    Dict{Symbol, Int}(
        :hits => 0,
        :misses => 0,
        :arcs => 0,
        :splines => 0,
        :chord_fallbacks => 0
    )
)

# ─── Point merge ─────────────────────────────────────────────────────────────

# Vertex-precision (relaxed) point insert. Used for polygon vertices where the
# two sides of a shared boundary may differ by ~1.5 nm.
function _cached_point_relaxed!(
    k,
    ctx::ConformalRenderContext,
    x::Float64,
    y::Float64,
    z::Float64,
    points_tree
)
    points_tree === nothing && return k.add_point(x, y, z)
    return _get_or_add_point!(k, x, y, z, points_tree; atol=ctx.vertex_merge_atol)
end

# Strict point insert. Used for arc centers and BSpline control points where
# any merge would corrupt geometry.
function _cached_point_strict!(
    k,
    ctx::ConformalRenderContext,
    x::Float64,
    y::Float64,
    z::Float64,
    points_tree
)
    points_tree === nothing && return k.add_point(x, y, z)
    return _get_or_add_point!(k, x, y, z, points_tree; atol=ctx.center_merge_atol)
end

# ─── Edge/curve cache ────────────────────────────────────────────────────────

# Add a line, dedup on unordered endpoint pair.
function _cached_add_line!(k, ctx::ConformalRenderContext, p1::Integer, p2::Integer)
    p1 == p2 && error("degenerate edge: p1 == p2 == $p1")
    lo, hi = minmax(p1, p2)
    key = (:line, lo, hi)
    existing = get(ctx.curve_cache, key, nothing)
    if existing !== nothing
        ctx.stats[:hits] += 1
        return p1 < p2 ? existing : -existing
    end
    # Prefer-curve: a curve already spans these endpoints → reuse it.
    existing_curve = get(ctx.endpoint_curve_index, (lo, hi), nothing)
    if existing_curve !== nothing
        ctx.stats[:hits] += 1
        return p1 < p2 ? existing_curve : -existing_curve
    end
    ctx.stats[:misses] += 1
    tag = k.addLine(p1, p2)
    ctx.curve_cache[key] = p1 < p2 ? tag : -tag
    return tag
end

# Add a circle arc. Registers in the endpoint index so subsequent line requests
# on the same endpoints reuse this arc (curve wins).
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
    if existing !== nothing
        ctx.stats[:hits] += 1
        return p1 < p2 ? existing : -existing
    end
    # Any curve already on these endpoints → reuse (handles float-jittered
    # center of the coordinated Turn applied to the other side).
    existing_curve = get(ctx.endpoint_curve_index, (lo, hi), nothing)
    if existing_curve !== nothing
        ctx.stats[:hits] += 1
        return p1 < p2 ? existing_curve : -existing_curve
    end
    # Conformality backstop: a chord was already created on these endpoints
    # (the other side rendered this boundary as a line because it did not
    # recover the arc). Reuse the chord so both faces share one tag; accuracy
    # is lost in this one-sided cell only.
    existing_line = get(ctx.curve_cache, (:line, lo, hi), nothing)
    if existing_line !== nothing
        ctx.stats[:hits] += 1
        return p1 < p2 ? existing_line : -existing_line
    end
    ctx.stats[:misses] += 1
    ctx.stats[:arcs] += 1
    tag = k.add_circle_arc(p1, center, p2, -1)
    signed_tag = p1 < p2 ? tag : -tag
    ctx.curve_cache[key] = signed_tag
    ctx.endpoint_curve_index[(lo, hi)] = signed_tag
    return tag
end

# Add an interpolating BSpline. Deduped by exact control-net; also unified with
# its reversal.
function _cached_add_spline!(
    k,
    ctx::ConformalRenderContext,
    pts::Vector{<:Integer},
    tangents
)
    key = (:bspline, pts...)
    existing = get(ctx.curve_cache, key, nothing)
    if existing !== nothing
        ctx.stats[:hits] += 1
        return existing
    end
    rkey = (:bspline, reverse(pts)...)
    existing_r = get(ctx.curve_cache, rkey, nothing)
    if existing_r !== nothing
        ctx.stats[:hits] += 1
        return -existing_r
    end
    ctx.stats[:misses] += 1
    ctx.stats[:splines] += 1
    tag = k.addSpline(pts, -1, tangents)
    ctx.curve_cache[key] = tag
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
    points_tree=nothing,
    kwargs...
) = _add_conformal!(
    ctx,
    CurvilinearRegion(x),
    m,
    k;
    zmap=zmap,
    points_tree=points_tree,
    kwargs...
)

# CurvilinearRegion: single add_plane_surface call with hole loops (PATCH 1).
# Stock DL creates outer surface, then per-hole surface, then k.cut() each hole.
# The multi-loop form is one OCC call and preserves shared points naturally.
function _add_conformal!(
    ctx::ConformalRenderContext,
    surf::CurvilinearRegion{T},
    m::Meta,
    k::OpenCascade;
    zmap=(_) -> zero(T),
    points_tree=nothing,
    atol=onenanometer(T),
    kwargs...
) where {T}
    z = zmap(m)
    outer_loop = _add_conformal_loop!(ctx, surf.exterior, k, z; points_tree, atol)
    hole_loops = _add_conformal_loop!.(Ref(ctx), surf.holes, k, z; points_tree, atol)
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
    points_tree=nothing,
    atol=onenanometer(T),
    kwargs...
) where {T}
    z = zmap(m)
    loop =
        _add_conformal_loop!(ctx, CurvilinearPolygon(points(poly)), k, z; points_tree, atol)
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
    points_tree=nothing,
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
        points_tree
    )
    p1 = _cached_point_relaxed!(
        k,
        ctx,
        Float64(ustrip(STP_UNIT, getx(line.p1))),
        Float64(ustrip(STP_UNIT, gety(line.p1))),
        Float64(ustrip(STP_UNIT, z)),
        points_tree
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

# PATCH 3 without the (disabled) short-edge batching from DTP. The batching was
# gated off in production (`SHORT_EDGE_BATCH_THRESHOLD=0.0`); reproducing it
# here would be dead code.
"""
    add_conformal_loop!(ctx::ConformalRenderContext, cl::CurvilinearPolygon,
        k::OpenCascade, z; points_tree=nothing, atol=onenanometer(...))

Build an OCC curve loop for `cl` using the conformal edge/curve cache.

This is the public seam for callers that build OCC geometry themselves (rather
than using [`render_conformal!`](@ref)'s orchestrator). Typical usage:

```julia
ctx = ConformalRenderContext()
points_tree = SpatialIndexing.RTree{Float64, 3}(Int32)
for region in regions
    outer = add_conformal_loop!(ctx, region.exterior, k, z; points_tree)
    holes = [add_conformal_loop!(ctx, h, k, z; points_tree) for h in region.holes]
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
    points_tree=nothing,
    atol=onenanometer(coordinatetype(cl))
)
    return _add_conformal_loop!(ctx, cl, k, z; points_tree, atol)
end

function _add_conformal_loop!(
    ctx::ConformalRenderContext,
    cl::CurvilinearPolygon,
    k::OpenCascade,
    z;
    points_tree=nothing,
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
            points_tree
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
                points_tree;
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

# PATCH 4a: exact circular arc, cached, with strict-tolerance center.
function _add_conformal_curve!(
    ctx::ConformalRenderContext,
    endpoints,
    seg::Paths.Turn,
    k::OpenCascade,
    z,
    points_tree;
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
        points_tree
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
                points_tree
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

# PATCH 4b: exact interpolating BSpline, cached, with strict-tolerance
# intermediate control points.
function _add_conformal_curve!(
    ctx::ConformalRenderContext,
    endpoints,
    seg::Paths.BSpline,
    k::OpenCascade,
    z,
    points_tree;
    kwargs...
)
    midpts = [
        _cached_point_strict!(
            k,
            ctx,
            Float64(ustrip(STP_UNIT, getx(p))),
            Float64(ustrip(STP_UNIT, gety(p))),
            Float64(ustrip(STP_UNIT, z)),
            points_tree
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

# PATCH 4c: offset segments — constant offset of a Turn is still a circular
# arc (exact); general offset (BSpline or variable) is approximated by a
# BSpline chain with join points at the RELAXED tolerance to unify sub-splines
# produced from opposite traversal directions.
function _add_conformal_curve!(
    ctx::ConformalRenderContext,
    endpoints,
    seg::Paths.OffsetSegment,
    k::OpenCascade,
    z,
    points_tree;
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
        return _add_conformal_curve!(ctx, endpoints, off_turn, k, z, points_tree; kwargs...)
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
            points_tree
        ) for p in newstarts
    ]
    starts = [endpoints[1], newpts...]
    stops = [newpts..., endpoints[2]]
    tags = Int32[]
    for (ep, sub) in zip([[s, e] for (s, e) in zip(starts, stops)], approx.segments)
        t = _add_conformal_curve!(ctx, ep, sub, k, z, points_tree; kwargs...)
        if t isa AbstractVector
            append!(tags, t)
        else
            push!(tags, t)
        end
    end
    return tags
end

# Fallback: any segment type not specialized above (e.g. Straight) is handled
# by DL's stock `_add_curve!` — those types don't benefit from caching (they're
# already exact-and-cheap in stock DL).
_add_conformal_curve!(
    ctx::ConformalRenderContext,
    endpoints,
    seg::Paths.Segment,
    k::OpenCascade,
    z,
    points_tree;
    kwargs...
) = _add_curve!(endpoints, seg, k, z; kwargs...)

# ─── Public entry point ──────────────────────────────────────────────────────

"""
    render_conformal!(sm::SolidModel, cs::AbstractCoordinateSystem;
        context=ConformalRenderContext(),
        map_meta=layer, postrender_ops=[], retained_physical_groups=[],
        zmap=(_)->zero(T), gmsh_options=..., skip_postrender=false,
        auto_union=false, skip_unused_layers=false,
        fragment_backstop=false, kwargs...)

Render `cs` into `sm` using the ConformalRender strategy. Same semantics as
[`render!`](@ref) but without the post-render `_fragment_and_map!` pass by
default.

The `context::ConformalRenderContext` holds the edge/curve cache and merge
tolerances; pass an explicit context if you need custom tolerances or want to
inspect cache statistics after the render.

`fragment_backstop=true` runs the stock 3-pass `_fragment_and_map!` sequence
after postrender operations. Faces already resolved to a single OCC entity
by the cache pass through as no-ops, so this is safe to combine with
cache-resolved regions. Enable when the input geometry may not fully meet
the "shared endpoints ⟹ shared curve" precondition, or when `postrender_ops`
introduce overlapping entities that need reconciliation.

Not supported on `GmshNative` kernel.
"""
function render_conformal!(
    sm::SolidModel,
    cs::AbstractCoordinateSystem{T};
    context::ConformalRenderContext=ConformalRenderContext(),
    map_meta=layer,
    postrender_ops=[],
    retained_physical_groups=[],
    zmap=(_) -> zero(T),
    gmsh_options=Dict{String, Union{String, Int, Float64}}(),
    skip_postrender::Bool=false,
    auto_union::Bool=false,
    skip_unused_layers::Bool=false,
    fragment_backstop::Bool=false,
    kwargs...
) where {T}
    kernel(sm) isa OpenCascade || error(
        "render_conformal! is only implemented for OpenCascade kernel; " *
        "got $(typeof(kernel(sm))). Use render! instead."
    )
    gmsh.model.set_current(SolidModels.name(sm))
    set_gmsh_option(gmsh_options)

    flat = flatten(cs)
    clear_mesh_control_points!()
    points_tree = RTree{Float64, 3}(Int32)

    used_names = if skip_unused_layers
        _used_group_names(postrender_ops, retained_physical_groups)
    else
        nothing
    end

    for meta in unique(element_metadata(flat))
        mapped_name = map_meta(meta)
        isnothing(mapped_name) && continue
        if !isnothing(used_names) &&
           string(mapped_name) ∉ used_names &&
           string(layer(meta)) ∉ used_names
            continue
        end
        idx = (element_metadata(flat) .== meta)
        els = to_primitives.(sm, elements(flat)[idx]; kwargs...)
        meshsizes = sizeandgrading.(elements(flat)[idx]; kwargs...)

        group_dimtags_unflattened = _add_conformal!(
            context,
            els,
            meta,
            kernel(sm);
            zmap=zmap,
            points_tree=points_tree,
            kwargs...
        )

        group_dimtags = reduce(vcat, group_dimtags_unflattened, init=Tuple{Int32, Int32}[])
        for dim in unique(first.(group_dimtags))
            if hasgroup(sm, mapped_name, dim)
                append!(group_dimtags, dimtags(sm[mapped_name, dim]))
            end
        end
        sm[mapped_name] = group_dimtags

        z_of_meta = _stp_float(zmap(meta))
        for (prims, (h, α)) in zip(els, meshsizes)
            _collect_mesh_control_points!(prims, h, α, z_of_meta)
        end
    end

    _synchronize!(sm)
    finalize_size_fields!()
    _synchronize!(sm)
    skip_postrender && return nothing

    if auto_union
        auto_union_ops = Tuple[]
        for groupname in collect(keys(dimgroupdict(sm, 2)))
            push!(auto_union_ops, (groupname, SolidModels.union_geom!, (groupname, 2)))
        end
        _postrender!(sm, auto_union_ops)
        _synchronize!(sm)
    end
    _postrender!(sm, postrender_ops)
    _synchronize!(sm)

    # By default, no `_fragment_and_map!` pass: the conformal cache already
    # deduplicates shared edges during render. But if the input geometry
    # doesn't fully meet the cache's preconditions (see "Failure modes for the
    # 'prefer curve' invariant" in the module docstring), or if `postrender_ops`
    # introduce overlapping entities that need reconciliation, users can opt
    # into the stock 3-pass fragment as a safety net via `fragment_backstop=true`.
    # Faces already resolved to a single OCC entity by the cache pass through
    # fragment as no-ops, so this is compatible with cache-resolved regions.
    if fragment_backstop
        _fragment_and_map!(sm, [0, 1])
        _fragment_and_map!(sm, [1, 2])
        _fragment_and_map!(sm, [2, 3])
    end

    gmsh.model.mesh.setSizeCallback(gmsh_meshsize)

    if !isempty(retained_physical_groups)
        for d = 0:3
            retain_groups = getindex.(filter(x -> x[2] == d, retained_physical_groups), 1)
            all_groups = keys(dimgroupdict(sm, d))
            for k in setdiff(all_groups, retain_groups)
                remove_group!(sm[k, d], remove_entities=false)
            end
        end
        reindex_physical_groups!(sm)
    end

    return _synchronize!(sm)
end

end # module ConformalRender
