# Post-render passes: operations applied to the rendered geometry of a layer as a whole,
# as opposed to entity styles like `Rounded`, which are applied to entities as they are
# created. The distinguishing feature is that these passes see the union of a layer's
# flattened geometry, so they can handle results that emerge only after composition
# (e.g. corners where separately-rendered polygons meet).

"""
    round_layer(geom::Union{Cell,CoordinateSystem}, layer::DeviceLayout.Meta, radius;
        min_side_len=radius, min_angle=1e-3)

Return the geometry of `geom` in `layer` as a `Vector{CurvilinearRegion}` with corners
rounded to `radius`.

The elements of `geom` matching `layer` (using [`layer_inclusion`](@ref) semantics,
including elements inside references) are flattened and unioned before rounding, so
corners are rounded correctly even where separately-drawn shapes meet. Rounding is
symbolic: the fillets in the result are true arcs, and any holes in the unioned geometry
are preserved as holes of the resulting regions (with their corners rounded too).

For `CoordinateSystem` input, the union preserves curves already present in the input
(arcs from paths, `Rounded` entities, circles, ...) using [`union2d_curved`](@ref), and
corners between straight edges and arcs are rounded natively. Curve recovery is currently
all-or-nothing: an input curve cut by the union falls back to a polyline, as described in
[`Curvilinear.recover_curves`](@ref). For `Cell` input, elements are already plain polygons,
which are unioned with [`union2d`](@ref), then converted to rounded `CurvilinearRegion`s.

# Keyword arguments

  - `min_side_len`: the minimum side length adjacent to a corner for that corner to be
    rounded. Defaults to `radius`.
  - `min_angle`: corners where adjacent sides are collinear within this tolerance (in
    radians) are not rounded.
"""
function round_layer(
    geom::Union{Cell, CoordinateSystem},
    layer::Meta,
    radius::Coordinate;
    min_side_len=radius,
    min_angle::Real=1e-3
)
    sty = Rounded(radius; min_side_len, min_angle)
    return _rounded_regions(geom, layer, sty)
end

"""
    round_layer!(geom::Union{Cell,CoordinateSystem}, layer::DeviceLayout.Meta, radius;
        target_layer::DeviceLayout.Meta, remap_originals=nothing,
        min_side_len=radius, min_angle=1e-3, kwargs...)

Round the corners of the geometry of `geom` in `layer` to `radius`, rendering the result
into `geom` itself with metadata `target_layer`.

The rounded result is computed as in [`round_layer`](@ref) (flatten, union, round
symbolically) and rendered at the top level of `geom`. The original elements are left in
place; if `remap_originals` is set to a `DeviceLayout.Meta`, the elements of
`geom` matching `layer` are retagged with that metadata instead, including elements
inside references (which may be shared by structures outside `geom`, making this operation
unsafe). Text elements are unaffected.

For a `CoordinateSystem` target, the rounded regions are placed symbolically (arcs stay
exact). For a `Cell` target, they are discretized on render; keyword arguments (e.g.
`atol`) are forwarded to `render!` to control the discretization, and `target_layer` and
`remap_originals` must be `GDSMeta`. Rendering to an integer coordinate type may throw an
`InexactError` if a discretized point is not representable; in that case `geom` is left
unchanged.

See [`round_layer`](@ref) for the rounding keyword arguments.
"""
function round_layer!(
    geom::Union{Cell, CoordinateSystem},
    layer::Meta,
    radius::Coordinate;
    target_layer::Meta,
    remap_originals::Union{Meta, Nothing}=nothing,
    min_side_len=radius,
    min_angle::Real=1e-3,
    kwargs...
)
    regions = round_layer(geom, layer, radius; min_side_len, min_angle)

    # Stage rendering so conversion or discretization failures leave `geom` unchanged.
    staged = coordsys_type(geom)("round_layer_staging")
    for r in regions
        render!(staged, r, target_layer; kwargs...)
    end

    # Remap before adding new elements in case `layer == target_layer`
    !isnothing(remap_originals) &&
        map_metadata!(geom, m -> m == layer ? remap_originals : m)

    append!(elements(geom), elements(staged))
    append!(element_metadata(geom), element_metadata(staged))
    return geom
end

function _rounded_regions(cell::Cell{S}, layer, sty) where {S}
    polys = flat_elements(cell, layer)
    isempty(polys) && return CurvilinearRegion{S}[]
    return to_curvilinear(union2d(polys), sty)
end

function _rounded_regions(cs::CoordinateSystem{S}, layer, sty) where {S}
    ents = flat_elements(cs, layer)
    isempty(ents) && return CurvilinearRegion{S}[]
    # Curve-preserving union: arcs already present in the input survive symbolically
    # rather than being discretized, and line-arc corners are rounded natively.
    return [to_curvilinear(r, sty) for r in union2d_curved(ents)]
end

# ─────────────────────────────────────────────────────────────────────────────
# Vertex noding: injecting foreign vertices onto edges to make shared boundaries
# conformal. Two public entry points share one RTree-based core:
#
#   - `split_t_junctions!(targets, sources...)` — asymmetric. Inject the
#     `sources` vertices that lie on `targets` edges. A general 2D-geometry
#     operation (also closes ~1 nm grid-snap gaps in GDS output).
#   - `mutual_node!(groups)` — symmetric all-pairs (in the ConformalRender
#     submodule). Inject, into each group's edges, the vertices owned by *other*
#     groups. Prepares adjacent physical groups for `render_conformal!`.
#
# The core (`_VertexIndex` + `_node_contour`) does the geometry once: it projects
# candidate points onto straight edges (perpendicular distance) and curved edges
# (`Paths.Turn`/`Paths.BSpline`, via `pathlength_nearest`), splits curves natively
# with `Paths.split` at the exact on-curve point, guards endpoints, and drops
# near-coincident duplicates. A per-candidate "owner" tag lets `mutual_node!`
# restrict injection to foreign vertices while `split_t_junctions!` accepts all.

# A spatial index of candidate vertices for on-edge queries. Each unique vertex
# (deduplicated on an integer-nm grid so bit-identical copies collapse) is stored
# as an `atol`-padded `Rect` in an `RTree`, following the `mbr_spatial_index`
# idiom in `src/entities.jl`. `owner[i]` tags which group contributed vertex `i`
# (used by `mutual_node!`); `pts[i]` is the original `Point` (reused verbatim so
# an injected copy is bit-identical to its partner and the render-time point
# merge unifies them). Coordinates are indexed in nm so `atol` means the same
# physical distance regardless of the input unit.
struct _VertexIndex{T}
    tree::SpatialIndexing.RTree{
        Float64,
        2,
        SpatialIndexing.SpatialElem{Float64, 2, Nothing, Int}
    }
    pts::Vector{Point{T}}
    owner::Vector{Int}
    atol_nm::Float64
end

# Interpret unitful lengths as-is; bare `Real` coordinates mean microns, per
# DeviceLayout's user-facing convention.
_nm(x) = Float64(ustrip(Unitful.nm, x))
_nm(x::Real) = Float64(1000 * x)

# Perpendicular distance in nm from point `p` to the line segment (p1, p2).
# For corner-shared dedup — a Real-valued helper used only when comparing which
# adjacent edge a candidate is geometrically nearer to.
function _perp_to_edge(p1, p2, p)
    x1 = _nm(getx(p1))
    y1 = _nm(gety(p1))
    dx = _nm(getx(p2)) - x1
    dy = _nm(gety(p2)) - y1
    len_sq = dx * dx + dy * dy
    len_sq <= 0 && return Inf
    px = _nm(getx(p))
    py = _nm(gety(p))
    return abs((px - x1) * dy - (py - y1) * dx) / sqrt(len_sq)
end

# Build an index over `groups`, an iterable of `(owner_id, vertices)` pairs.
# `atol` is a length; it sets both the padding of each vertex's query Rect and
# the coincidence tolerance. Vertices within `atol` of an existing indexed vertex
# collapse onto it (first owner wins the `pts` slot; later owners are OR-ed into
# a shared slot only when they hash to the same nm cell — exact grid coincidence,
# which is what bit-identical Clipper output produces).
function _build_vertex_index(groups, ::Type{T}; atol) where {T}
    atol_nm = _nm(atol)
    cell = max(atol_nm, 1.0)
    slot = Dict{Tuple{Int, Int}, Int}()   # nm-grid key → index into pts/owner
    pts = Point{T}[]
    owner = Int[]
    for (oid, verts) in groups
        for p in verts
            key = (round(Int, _nm(getx(p)) / cell), round(Int, _nm(gety(p)) / cell))
            i = get(slot, key, 0)
            if i == 0
                push!(pts, p)
                push!(owner, oid)
                slot[key] = length(pts)
            end
            # else: a vertex already occupies this cell; keep the first Point.
            # (owner stays the first contributor; foreign-eligibility below still
            # holds because a shared vertex is by definition not "foreign".)
        end
    end
    tree = SpatialIndexing.RTree{Float64, 2}(Int)
    elems = [
        SpatialIndexing.SpatialElem(
            SpatialIndexing.Rect(
                (_nm(getx(p)) - atol_nm, _nm(gety(p)) - atol_nm),
                (_nm(getx(p)) + atol_nm, _nm(gety(p)) + atol_nm)
            ),
            nothing,
            i
        ) for (i, p) in enumerate(pts)
    ]
    isempty(elems) || SpatialIndexing.load!(tree, elems)
    return _VertexIndex{T}(tree, pts, owner, atol_nm)
end

# Candidate indices whose padded Rect intersects the bbox of segment a→b (nm),
# itself padded by `atol_nm`. `exclude_owner` (or 0 for none) drops candidates
# contributed only-by that owner — the "foreign vertices only" filter.
function _query_bbox(idx::_VertexIndex, axmin, aymin, axmax, aymax, exclude_owner::Int)
    pad = idx.atol_nm
    box = SpatialIndexing.Rect(
        (min(axmin, axmax) - pad, min(aymin, aymax) - pad),
        (max(axmin, axmax) + pad, max(aymin, aymax) + pad)
    )
    hits = Int[]
    for x in SpatialIndexing.intersects_with(idx.tree, box)
        i = x.val
        (exclude_owner != 0 && idx.owner[i] == exclude_owner) && continue
        push!(hits, i)
    end
    return hits
end

# Foreign points on the straight edge p1→p2, as `(t, Point, i)` sorted by
# parameter. `i` is the candidate's index in `idx.pts`, useful for cross-edge
# dedup by the caller. Excludes candidates within `atol` Euclidean distance of
# either endpoint (they would collapse onto an existing vertex under render-time
# point merging) and this contour's own owner.
function _points_on_straight(
    idx::_VertexIndex{T},
    p1::Point{T},
    p2::Point{T},
    exclude_owner::Int,
    rtol::Real
) where {T}
    x1 = _nm(getx(p1))
    y1 = _nm(gety(p1))
    x2 = _nm(getx(p2))
    y2 = _nm(gety(p2))
    dx = x2 - x1
    dy = y2 - y1
    len_sq = dx * dx + dy * dy
    atol_nm = idx.atol_nm
    len_sq <= (2 * atol_nm)^2 && return Tuple{Float64, Point{T}, Int}[]  # degenerate
    len = sqrt(len_sq)
    found = Tuple{Float64, Point{T}, Int}[]
    atol_sq = atol_nm * atol_nm
    for i in _query_bbox(idx, x1, y1, x2, y2, exclude_owner)
        px = _nm(getx(idx.pts[i]))
        py = _nm(gety(idx.pts[i]))
        t = ((px - x1) * dx + (py - y1) * dy) / len_sq
        perp = abs((px - x1) * dy - (py - y1) * dx) / len
        perp > atol_nm && continue
        # Endpoint guard: exclude candidates within `atol` Euclidean distance of
        # either endpoint (they collapse onto an existing vertex under render-time
        # point merging). Absolute in physical distance — matches the atol-based
        # merging convention elsewhere in DeviceLayout — while still admitting
        # legitimate T-junctions a few nm inside a very short edge.
        along = t * len
        (along * along + perp * perp) <= atol_sq && continue
        ((len - along)^2 + perp * perp) <= atol_sq && continue
        push!(found, (t, idx.pts[i], i))                     # reuse foreign Point
    end
    sort!(found; by=first)
    # Drop candidates closer than atol *along* the edge to the previous kept one —
    # two near-coincident injections would make a sub-tolerance-length edge.
    isempty(found) && return found
    min_dt = atol_nm / len
    kept = Tuple{Float64, Point{T}, Int}[found[1]]
    for k = 2:length(found)
        found[k][1] - kept[end][1] < min_dt && continue
        push!(kept, found[k])
    end
    return kept
end

# Foreign points on a curved edge (`Paths.Turn`, `Paths.BSpline`, …), as
# `(arclength, on-curve Point)` sorted along travel, excluding endpoints and this
# contour's own owner. The injected point is the EXACT point on the curve at that
# arclength (`curve(s)`), not the possibly-off-curve candidate — so the
# `CurvilinearPolygon` point/endpoint agreement is preserved.
function _points_on_curve(idx::_VertexIndex{T}, curve, exclude_owner::Int) where {T}
    L = pathlength(curve)                      # a length, in the curve's unit
    L_nm = _nm(L)
    L_nm <= 0 && return Tuple{typeof(L), Point{T}, Int}[]
    disc = discretize_curve(curve, onenanometer(T); rtol=nothing)
    isempty(disc) && return Tuple{typeof(L), Point{T}, Int}[]
    atol_nm = idx.atol_nm
    # The polyline approximates the curve to within 1 nm, so widen the
    # perpendicular test by that slop before the exact on-curve residual check.
    perp_tol = atol_nm + 1.0
    tol2 = perp_tol * perp_tol
    seen = Set{Int}()
    # (arclength as a length, arclength in nm, candidate index) for qualifying candidates.
    found = Tuple{typeof(L), Float64, Int}[]
    nd = length(disc)
    for j = 1:(nd - 1)
        ax = _nm(getx(disc[j]))
        ay = _nm(gety(disc[j]))
        bx = _nm(getx(disc[j + 1]))
        by = _nm(gety(disc[j + 1]))
        vx = bx - ax
        vy = by - ay
        seg_len2 = vx * vx + vy * vy
        seg_len2 == 0 && continue
        for i in _query_bbox(idx, ax, ay, bx, by, exclude_owner)
            i in seen && continue
            px = _nm(getx(idx.pts[i]))
            py = _nm(gety(idx.pts[i]))
            t = clamp(((px - ax) * vx + (py - ay) * vy) / seg_len2, 0.0, 1.0)
            qx = ax + t * vx
            qy = ay + t * vy
            (px - qx)^2 + (py - qy)^2 > tol2 && continue
            push!(seen, i)
            V = idx.pts[i]
            s = pathlength_nearest(curve, V)   # a length in the curve's unit
            s_nm = _nm(s)
            (s_nm <= atol_nm || s_nm >= L_nm - atol_nm) && continue
            cs_pt = curve(s)                   # exact point on the curve at s
            resid = hypot(_nm(getx(cs_pt) - getx(V)), _nm(gety(cs_pt) - gety(V)))
            resid > atol_nm && continue
            push!(found, (s, s_nm, i))
        end
    end
    isempty(found) && return Tuple{typeof(L), Point{T}, Int}[]
    sort!(found; by=x -> x[2])                 # by arclength = order of travel
    out = Tuple{typeof(L), Point{T}, Int}[]
    prev = -Inf
    for (s, s_nm, i) in found
        s_nm - prev < atol_nm && continue      # de-dup co-located along the curve
        push!(out, (s, curve(s), i))           # exact on-curve point
        prev = s_nm
    end
    return out
end

# Collect every vertex of a region (exterior + holes) into `pts`.
function _collect_region_vertices!(
    pts::Vector{Point{T}},
    region::CurvilinearRegion{T}
) where {T}
    append!(pts, points(region.exterior))
    for h in region.holes
        append!(pts, points(h))
    end
    return pts
end

# Rebuild one contour, injecting foreign vertices onto its edges. Straight edges
# get the foreign point verbatim; `Paths.Turn`/`Paths.BSpline` curves are split at
# the foreign arclength via `Paths.split`, staying native. `exclude_owner` (0 for
# none) restricts injection to vertices NOT solely owned by this contour's group.
# Returns `(new_cpoly, n_injected)`.
function _node_contour(
    cpoly::CurvilinearPolygon{T},
    idx::_VertexIndex{T},
    exclude_owner::Int,
    rtol::Real
) where {T}
    pts = points(cpoly)
    n = length(pts)
    n < 3 && return cpoly, 0
    curve_at = Dict{Int, Int}()   # start-vertex index → position in cpoly.curves
    for (k, csi) in enumerate(cpoly.curve_start_idx)
        curve_at[csi] = k
    end
    # First-pass: collect hits per edge with candidate indices, so pass 2 can
    # apply corner-vertex dedup — a candidate landing on TWO adjacent edges of
    # the same contour near their shared corner would inject twice, creating a
    # zero-length loopback (identical non-consecutive vertices around the
    # corner). Detection: candidate index seen on edge k-1 AND edge k, with the
    # candidate within `atol` Euclidean of the shared vertex `pts[k]`.
    atol_nm = idx.atol_nm
    atol_sq = atol_nm * atol_nm
    straight_hits = Dict{Int, Vector{Tuple{Float64, Point{T}, Int}}}()
    curve_hits = Dict{Int, Vector{Tuple{Any, Point{T}, Int}}}()
    for i = 1:n
        if haskey(curve_at, i)
            hits = _points_on_curve(idx, cpoly.curves[curve_at[i]], exclude_owner)
            isempty(hits) || (
                curve_hits[i] = Tuple{Any, Point{T}, Int}[
                    (s, on_pt, ci) for (s, on_pt, ci) in hits
                ]
            )
        else
            p2 = pts[mod1(i + 1, n)]
            hits = _points_on_straight(idx, pts[i], p2, exclude_owner, rtol)
            isempty(hits) || (straight_hits[i] = hits)
        end
    end
    # Build the corner-shared skip set: if a candidate ci was injected on both
    # edge k-1 AND edge k (which share pts[k]), keep it on the edge where it's
    # geometrically closer (smaller perp/on-curve residual) and skip it on the
    # other. This eliminates the corner double-injection Greg reported (source
    # vertex just off a sharp corner that lands within `atol` perp of BOTH
    # adjacent edges), without affecting the common case where a candidate
    # only touches one edge or where the two edges are non-adjacent.
    # We use "closer to the shared corner vertex" as the tie-break because
    # among two adjacent edges near a sharp corner, the edge whose interior
    # the candidate ACTUALLY belongs to has the candidate farther from the
    # shared corner (along its own arclength). Farther-from-corner = winner.
    corner_skip = Set{Tuple{Int, Int}}()
    for k = 1:n
        prev_k = mod1(k - 1, n)
        prev_hits_s = get(straight_hits, prev_k, nothing)
        prev_hits_c = get(curve_hits, prev_k, nothing)
        cur_hits_s = get(straight_hits, k, nothing)
        cur_hits_c = get(curve_hits, k, nothing)
        (prev_hits_s === nothing && prev_hits_c === nothing) && continue
        (cur_hits_s === nothing && cur_hits_c === nothing) && continue
        corner_x = _nm(getx(pts[k]))
        corner_y = _nm(gety(pts[k]))
        prev_indices = Set{Int}()
        prev_hits_s !== nothing && (
            for t in prev_hits_s
                push!(prev_indices, t[3])
            end
        )
        prev_hits_c !== nothing && (
            for t in prev_hits_c
                push!(prev_indices, t[3])
            end
        )
        cur_iter = cur_hits_s !== nothing ? cur_hits_s : cur_hits_c
        for tup in cur_iter
            ci = tup[3]
            (ci in prev_indices) || continue
            # Only dedup if the candidate is close enough to the shared corner
            # that both edges' perp checks trivially pass. Threshold: within
            # 2·atol of the corner (candidate that's 2·atol away has ≤ atol
            # perp only if it's essentially on-edge, not the corner-doubling
            # case). Farther candidates on both edges are legitimately on both.
            cx = _nm(getx(idx.pts[ci]))
            cy = _nm(gety(idx.pts[ci]))
            d2 = (cx - corner_x)^2 + (cy - corner_y)^2
            d2 <= (2 * atol_nm)^2 || continue
            # Winner = the edge whose interior the candidate is farther from
            # the shared corner along that edge. Compute along-edge distances.
            # For simplicity: pick the edge with SMALLER perp distance (that's
            # the edge the candidate is more genuinely "on").
            perp_prev = _perp_to_edge(pts[prev_k], pts[k], idx.pts[ci])
            perp_cur = _perp_to_edge(pts[k], pts[mod1(k + 1, n)], idx.pts[ci])
            if perp_prev <= perp_cur
                push!(corner_skip, (ci, k))            # keep on prev, skip on cur
            else
                push!(corner_skip, (ci, prev_k))       # keep on cur, skip on prev
            end
        end
    end
    new_points = Point{T}[]
    new_curves = eltype(cpoly.curves)[]
    new_csi = Int[]
    n_injected = 0
    for i = 1:n
        push!(new_points, pts[i])
        start_idx = length(new_points)
        if haskey(curve_at, i)
            seg = cpoly.curves[curve_at[i]]
            all_hits = get(curve_hits, i, nothing)
            splits = if all_hits === nothing
                Tuple{Any, Point{T}, Int}[]
            else
                [h for h in all_hits if !((h[3], i) in corner_skip)]
            end
            if isempty(splits)
                push!(new_curves, seg)
                push!(new_csi, start_idx)
            else
                # Split successively at each interior arclength, working in
                # remaining-arclength coordinates as the head is peeled off.
                remaining = seg
                consumed = zero(pathlength(seg))
                acc_idx = start_idx
                for (s, on_pt, _) in splits
                    sub1, sub2 = Paths.split(remaining, s - consumed)
                    push!(new_curves, sub1)
                    push!(new_csi, acc_idx)
                    push!(new_points, on_pt)
                    acc_idx = length(new_points)
                    remaining = sub2
                    consumed = s
                    n_injected += 1
                end
                push!(new_curves, remaining)
                push!(new_csi, acc_idx)
            end
        else
            all_hits = get(straight_hits, i, nothing)
            if all_hits !== nothing
                for (_, c, ci) in all_hits
                    (ci, i) in corner_skip && continue
                    push!(new_points, c)
                    n_injected += 1
                end
            end
        end
    end
    n_injected == 0 && return cpoly, 0
    if !isempty(new_csi)
        perm = sortperm(new_csi)
        new_curves = new_curves[perm]
        new_csi = new_csi[perm]
    end
    return CurvilinearPolygon{T}(new_points, new_curves, new_csi), n_injected
end

# Node every contour (exterior + holes) of `region` against `idx`.
function _node_region(region::CurvilinearRegion{T}, idx, exclude_owner, rtol) where {T}
    new_ext, n_ext = _node_contour(region.exterior, idx, exclude_owner, rtol)
    new_holes = CurvilinearPolygon{T}[]
    n_holes = 0
    for h in region.holes
        h_new, n_h = _node_contour(h, idx, exclude_owner, rtol)
        push!(new_holes, h_new)
        n_holes += n_h
    end
    total = n_ext + n_holes
    total == 0 && return region, 0
    return CurvilinearRegion{T}(new_ext, new_holes), total
end

"""
    split_t_junctions!(targets, sources...; atol=onenanometer(T), rtol=1e-6) -> Int

Inject every vertex of the `sources` that lies on an edge of `targets` into that
edge, so a boundary shared between the two groups has matching vertices on both
sides. Modifies `targets` in place and returns the number of vertices inserted.

`targets` and each of `sources` are iterables of [`CurvilinearRegion`](@ref) (a
[`Polygon`](@ref)-vector method is also provided). A T junction occurs where a
`sources` vertex lands partway along a `targets` edge without a corresponding
`targets` vertex there; this eliminates them:

  - **Straight edges** get the foreign vertex inserted verbatim (the two copies,
    one per side, coincide and merge downstream).
  - **Curved edges** (`Paths.Turn`, `Paths.BSpline`) are split at the foreign
    vertex's arclength with [`Paths.split`](@ref), so sub-curves stay exact. The
    injected vertex is the exact on-curve point at that arclength, not the
    (possibly slightly off-curve) source vertex.

Candidate lookup uses an `RTree` of the `sources` vertices (see
[`mbr_spatial_index`](@ref)), so cost scales with the number of on-edge hits
rather than the product of edge and vertex counts.

Fixing T junctions avoids ~1 nm gaps from manufacturing-grid snapping in GDS
output and "vertex lies in segment" PLC errors when meshing a solid model.

# Keywords

  - `atol`: coincidence tolerance (a length). A source vertex within `atol` of a
    target edge (perpendicular distance for straight edges, on-curve residual for
    curves) is considered to lie on it. Defaults to `onenanometer(T)`, matching
    the default render discretization tolerance and the GDS 1 nm grid.
  - `rtol`: relative endpoint guard, as a fraction of edge/curve length. Splits
    within `rtol` of an endpoint are skipped, since those coincide with an
    existing vertex. Defaults to `1e-6`.

# Example

```julia
targets = union2d_curved(cs => :metal_negative) # Vector{<:CurvilinearRegion}
sources = union2d_curved(cs => :metal_positive)
split_t_junctions!(targets, sources)
```
"""
function split_t_junctions!(
    targets::AbstractVector{CurvilinearRegion{T}},
    sources...;
    atol=onenanometer(T),
    rtol::Real=1e-6
) where {T}
    isempty(targets) && return 0
    candidates = Point{T}[]
    for group in sources
        for region in group
            _collect_region_vertices!(candidates, region)
        end
    end
    isempty(candidates) && return 0
    idx = _build_vertex_index(((0, candidates),), T; atol)
    total = 0
    for (ri, region) in enumerate(targets)
        new_region, n = _node_region(region, idx, 0, rtol)
        if n > 0
            targets[ri] = new_region
            total += n
        end
    end
    return total
end

"""
    split_t_junctions!(targets::AbstractVector{<:Polygon}, sources...; atol, rtol) -> Int

[`Polygon`](@ref)-vector method of [`split_t_junctions!`](@ref): inject `sources`
vertices that lie on `targets` polygon edges. Useful for eliminating T junctions
in 2D layout geometry before GDS output (where grid snapping could otherwise open
1 nm gaps along a shared straight boundary). Modifies `targets` in place; returns
the number of vertices inserted.
"""
function split_t_junctions!(
    targets::AbstractVector{<:Polygon{T}},
    sources...;
    atol=onenanometer(T),
    rtol::Real=1e-6
) where {T}
    isempty(targets) && return 0
    candidates = Point{T}[]
    for group in sources
        for poly in group
            append!(candidates, points(poly))
        end
    end
    isempty(candidates) && return 0
    idx = _build_vertex_index(((0, candidates),), T; atol)
    total = 0
    atol_nm_poly = _nm(atol)
    atol_sq_poly = atol_nm_poly * atol_nm_poly
    for (pi, poly) in enumerate(targets)
        pts = points(poly)
        n = length(pts)
        n < 3 && continue
        # First pass: collect per-edge hits with candidate indices, for the
        # corner-vertex dedup below.
        edge_hits = Dict{Int, Vector{Tuple{Float64, Point{T}, Int}}}()
        for i = 1:n
            p2 = pts[mod1(i + 1, n)]
            hits = _points_on_straight(idx, pts[i], p2, 0, rtol)
            isempty(hits) || (edge_hits[i] = hits)
        end
        corner_skip = Set{Tuple{Int, Int}}()
        for k = 1:n
            prev_k = mod1(k - 1, n)
            (haskey(edge_hits, prev_k) && haskey(edge_hits, k)) || continue
            corner_x = _nm(getx(pts[k]))
            corner_y = _nm(gety(pts[k]))
            prev_indices = Set(t[3] for t in edge_hits[prev_k])
            for (_, _, ci) in edge_hits[k]
                (ci in prev_indices) || continue
                cx = _nm(getx(idx.pts[ci]))
                cy = _nm(gety(idx.pts[ci]))
                ((cx - corner_x)^2 + (cy - corner_y)^2) <= atol_sq_poly || continue
                push!(corner_skip, (ci, k))
            end
        end
        new_points = Point{T}[]
        inserted = 0
        for i = 1:n
            push!(new_points, pts[i])
            hits = get(edge_hits, i, nothing)
            hits === nothing && continue
            for (_, c, ci) in hits
                (ci, i) in corner_skip && continue
                push!(new_points, c)
                inserted += 1
            end
        end
        if inserted > 0
            targets[pi] = Polygon{T}(new_points)
            total += inserted
        end
    end
    return total
end
