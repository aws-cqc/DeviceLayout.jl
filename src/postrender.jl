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
# conformal. `split_t_junctions!` has three methods sharing one RTree-based core:
#
#   - `split_t_junctions!(targets, sources...)` — asymmetric. Inject the
#     `sources` vertices that lie on `targets` edges. General 2D operation (also
#     closes ~1 nm grid-snap gaps in GDS output).
#   - `split_t_junctions!(regions)` — self-noding. Every region's vertices
#     become sources for every other region's edges. Shorthand for the same
#     regions on both sides.
#   - `split_t_junctions!(groups::AbstractDict)` — symmetric all-pairs.
#     For each group, inject the vertices owned by *other* groups onto its
#     edges. Prepares adjacent physical groups for `render_conformal!`.
#
# The core (`_VertexIndex` + `_node_contour`) does the geometry once: it projects
# candidate points onto straight edges (perpendicular distance) and curved edges
# (`Paths.Turn`/`Paths.BSpline`, via `pathlength_nearest`), splits curves natively
# with `Paths.split` at the exact on-curve point, guards endpoints, and drops
# near-coincident duplicates. A per-candidate "owner" tag lets the Dict method
# restrict injection to foreign vertices while the other methods accept all.

# A spatial index of candidate vertices for on-edge queries. Each vertex is
# stored as an `atol`-padded `Rect` in an `RTree` (see `mbr_spatial_index`
# idiom in `src/entities.jl`), and only the RTree query is authoritative for
# on-edge coincidence: it returns every candidate whose padded Rect intersects
# the padded edge bbox, which is a strict superset of the true within-`atol`
# hits (further filtered by perpendicular/on-curve residual in `_points_on_*`).
# `owner[i]` tags which group contributed vertex `i` (used to filter out
# same-group vertices in the Dict method); `pts[i]` is the original `Point`
# (reused verbatim so an injected copy is bit-identical to its partner and the
# render-time point merge unifies them). Coordinates are indexed in nm so
# `atol` means the same physical distance regardless of the input unit.
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
# `atol` is a length; it sets the padding of each vertex's query Rect and the
# effective coincidence tolerance for on-edge tests downstream. Correctness is
# provided by the RTree query in `_query_bbox` (all within-`atol` candidates
# are returned) plus the perpendicular/on-curve residual in `_points_on_*`,
# NOT by the nm-cell hash: two candidates within `atol` of each other can hash
# to adjacent cells (opposite side of a cell boundary), and two candidates in
# the same cell can be up to `sqrt(2)*atol` apart. The hash is a best-effort
# fast path for bit-identical Clipper output on a group's own edges, where
# multiple copies of the same integer-nm point collapse to a single slot;
# other near-coincident cases are handled downstream by the per-edge dedup in
# `_points_on_straight`/`_points_on_curve`.
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
            # else: a vertex already hashes to this nm cell — keep the first Point.
            # A shared-cell duplicate is treated as the same candidate for
            # owner-filter purposes: shared vertices between groups are not
            # "foreign" and shouldn't be injected across a boundary they already
            # sit on.
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
    exclude_owner::Int
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
        # RTree query padding lets candidates OUTSIDE the segment (before p1 or
        # after p2) reach here; drop those explicitly so the endpoint check
        # below only judges candidates that project onto the segment interior.
        (t < 0 || t > 1) && continue
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
# `(arclength, on-curve Point, candidate index)` sorted along travel, excluding
# endpoints and this contour's own owner. The injected point is the EXACT point
# on the curve at that arclength (`curve(s)`), not the possibly-off-curve
# candidate — so the `CurvilinearPolygon` point/endpoint agreement is preserved.
function _points_on_curve(idx::_VertexIndex{T}, curve, exclude_owner::Int) where {T}
    L = pathlength(curve)                      # a length, in the curve's unit
    L_nm = _nm(L)
    L_nm <= 0 && return Tuple{T, Point{T}, Int}[]
    disc = discretize_curve(curve, onenanometer(T); rtol=nothing)
    isempty(disc) && return Tuple{T, Point{T}, Int}[]
    atol_nm = idx.atol_nm
    # The polyline approximates the curve to within 1 nm, so widen the
    # perpendicular test by that slop before the exact on-curve residual check.
    perp_tol = atol_nm + 1.0
    tol2 = perp_tol * perp_tol
    seen = Set{Int}()
    # (arclength as `T`, arclength in nm, candidate index) for qualifying candidates.
    found = Tuple{T, Float64, Int}[]
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
            push!(found, (convert(T, s), s_nm, i))
        end
    end
    isempty(found) && return Tuple{T, Point{T}, Int}[]
    sort!(found; by=x -> x[2])                 # by arclength = order of travel
    out = Tuple{T, Point{T}, Int}[]
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

# Collect per-edge candidate hits for a closed contour, and index-only sets for
# corner-adjacency lookup. Returns `(straight_hits, curve_hits, index_sets)`.
# `edge_extractor(k)` returns `pts[k], pts[k+1]` for straight edges (indexed by
# start vertex). Curves are indexed by start vertex too, via `curve_at`.
function _collect_contour_hits(
    pts::Vector{Point{T}},
    curve_at::Dict{Int, Int},
    curves,
    idx::_VertexIndex{T},
    exclude_owner::Int
) where {T}
    n = length(pts)
    straight_hits = Dict{Int, Vector{Tuple{Float64, Point{T}, Int}}}()
    curve_hits = Dict{Int, Vector{Tuple{T, Point{T}, Int}}}()
    index_sets = Dict{Int, Set{Int}}()
    for i = 1:n
        if haskey(curve_at, i)
            hits = _points_on_curve(idx, curves[curve_at[i]], exclude_owner)
            if !isempty(hits)
                curve_hits[i] = hits
                index_sets[i] = Set{Int}(h[3] for h in hits)
            end
        else
            p2 = pts[mod1(i + 1, n)]
            hits = _points_on_straight(idx, pts[i], p2, exclude_owner)
            if !isempty(hits)
                straight_hits[i] = hits
                index_sets[i] = Set{Int}(h[3] for h in hits)
            end
        end
    end
    return straight_hits, curve_hits, index_sets
end

# Build a corner-adjacency skip set for a closed contour: if the same
# candidate `ci` was hit on edge `prev_k` AND edge `k` (which share vertex
# `pts[k]`), and `ci` sits within `2·atol` of that shared corner, keep it on
# whichever edge is geometrically nearer in perpendicular distance and skip
# it on the other. Returned as `Set{(candidate_index, edge_index)}`.
#
# The problematic case: a candidate a few nm off a sharp corner can be within
# `atol` perpendicular of BOTH adjacent edges. Without this filter it would
# inject twice, producing identical non-consecutive vertices around the corner
# (a zero-length loopback in the CurvilinearPolygon). Non-adjacent edges
# hosting the same candidate keep both injections — those are legitimate
# parallel T-junctions on real geometry, not corner artifacts.
function _corner_skip_set(
    pts::Vector{Point{T}},
    index_sets::Dict{Int, Set{Int}},
    idx::_VertexIndex{T}
) where {T}
    n = length(pts)
    atol_nm = idx.atol_nm
    corner_range_sq = (2 * atol_nm)^2
    corner_skip = Set{Tuple{Int, Int}}()
    for k = 1:n
        prev_k = mod1(k - 1, n)
        (haskey(index_sets, prev_k) && haskey(index_sets, k)) || continue
        prev_indices = index_sets[prev_k]
        cur_indices = index_sets[k]
        corner_x = _nm(getx(pts[k]))
        corner_y = _nm(gety(pts[k]))
        for ci in cur_indices
            (ci in prev_indices) || continue
            cx = _nm(getx(idx.pts[ci]))
            cy = _nm(gety(idx.pts[ci]))
            ((cx - corner_x)^2 + (cy - corner_y)^2) <= corner_range_sq || continue
            perp_prev = _perp_to_edge(pts[prev_k], pts[k], idx.pts[ci])
            perp_cur = _perp_to_edge(pts[k], pts[mod1(k + 1, n)], idx.pts[ci])
            if perp_prev <= perp_cur
                push!(corner_skip, (ci, k))            # keep on prev, skip on cur
            else
                push!(corner_skip, (ci, prev_k))       # keep on cur, skip on prev
            end
        end
    end
    return corner_skip
end

# Split `curve` (a `Paths.Turn`/`Paths.BSpline`) at each interior arclength in
# `splits`, appending sub-curves + on-curve breakpoints into `new_curves`/
# `new_points`/`new_csi`. `start_idx` is the position of the curve's start
# vertex in `new_points`. Returns the injection count.
function _emit_split_curve!(
    new_curves,
    new_points::Vector{Point{T}},
    new_csi::Vector{Int},
    curve,
    splits::Vector{<:Tuple{T, Point{T}, Int}},
    start_idx::Int
) where {T}
    remaining = curve
    consumed = zero(pathlength(curve))
    acc_idx = start_idx
    n_inj = 0
    for (s, on_pt, _) in splits
        sub1, sub2 = Paths.split(remaining, s - consumed)
        push!(new_curves, sub1)
        push!(new_csi, acc_idx)
        push!(new_points, on_pt)
        acc_idx = length(new_points)
        remaining = sub2
        consumed = s
        n_inj += 1
    end
    push!(new_curves, remaining)
    push!(new_csi, acc_idx)
    return n_inj
end

# Rebuild one contour, injecting foreign vertices onto its edges. Straight edges
# get the foreign point verbatim; `Paths.Turn`/`Paths.BSpline` curves are split at
# the foreign arclength via `Paths.split`, staying native. `exclude_owner` (0 for
# none) restricts injection to vertices NOT solely owned by this contour's group.
# Returns `(new_cpoly, n_injected)`.
function _node_contour(
    cpoly::CurvilinearPolygon{T},
    idx::_VertexIndex{T},
    exclude_owner::Int
) where {T}
    pts = points(cpoly)
    n = length(pts)
    n < 3 && return cpoly, 0
    curve_at = Dict{Int, Int}()   # start-vertex index → position in cpoly.curves
    for (k, csi) in enumerate(cpoly.curve_start_idx)
        curve_at[csi] = k
    end
    straight_hits, curve_hits, index_sets =
        _collect_contour_hits(pts, curve_at, cpoly.curves, idx, exclude_owner)
    isempty(straight_hits) && isempty(curve_hits) && return cpoly, 0
    corner_skip = _corner_skip_set(pts, index_sets, idx)
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
                Tuple{T, Point{T}, Int}[]
            else
                Tuple{T, Point{T}, Int}[h for h in all_hits if !((h[3], i) in corner_skip)]
            end
            if isempty(splits)
                push!(new_curves, seg)
                push!(new_csi, start_idx)
            else
                n_injected += _emit_split_curve!(
                    new_curves,
                    new_points,
                    new_csi,
                    seg,
                    splits,
                    start_idx
                )
            end
        else
            all_hits = get(straight_hits, i, nothing)
            all_hits === nothing && continue
            for (_, c, ci) in all_hits
                (ci, i) in corner_skip && continue
                push!(new_points, c)
                n_injected += 1
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
function _node_region(region::CurvilinearRegion{T}, idx, exclude_owner) where {T}
    new_ext, n_ext = _node_contour(region.exterior, idx, exclude_owner)
    new_holes = CurvilinearPolygon{T}[]
    n_holes = 0
    for h in region.holes
        h_new, n_h = _node_contour(h, idx, exclude_owner)
        push!(new_holes, h_new)
        n_holes += n_h
    end
    total = n_ext + n_holes
    total == 0 && return region, 0
    return CurvilinearRegion{T}(new_ext, new_holes), total
end

# Node a plain Polygon: collect straight-edge hits, apply corner-skip, rebuild.
# Returns `(new_polygon, n_injected)`.
function _node_polygon(poly::Polygon{T}, idx::_VertexIndex{T}, exclude_owner::Int) where {T}
    pts = points(poly)
    n = length(pts)
    n < 3 && return poly, 0
    edge_hits = Dict{Int, Vector{Tuple{Float64, Point{T}, Int}}}()
    index_sets = Dict{Int, Set{Int}}()
    for i = 1:n
        p2 = pts[mod1(i + 1, n)]
        hits = _points_on_straight(idx, pts[i], p2, exclude_owner)
        if !isempty(hits)
            edge_hits[i] = hits
            index_sets[i] = Set{Int}(h[3] for h in hits)
        end
    end
    isempty(edge_hits) && return poly, 0
    corner_skip = _corner_skip_set(pts, index_sets, idx)
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
    inserted == 0 && return poly, 0
    return Polygon{T}(new_points), inserted
end

"""
    split_t_junctions!(targets, sources...; atol=2nm) -> Int

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

`atol` sets the perpendicular distance between point and edge within which a
point is injected, and defaults to two nanometers. It must be ≥ the maximum
coordinate drift between two groups' copies of the same logical vertex and ≪
the minimum feature size. Curves are internally discretized with 1 nm tolerance
to calculate point-edge distances (approximate for curves other than circular
arcs). The 2 nm default covers the typical drift caused by this discretization
while remaining far below any real feature. By DeviceLayout convention, lengths
without units are presumed to be in microns.

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
    atol=onenanometer(T) * 2
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
        new_region, n = _node_region(region, idx, 0)
        if n > 0
            targets[ri] = new_region
            total += n
        end
    end
    return total
end

"""
    split_t_junctions!(regions::AbstractVector{CurvilinearRegion}; atol=2nm) -> Int

Self-noding: inject each region's vertices onto every other region's edges in
the same collection. Equivalent to `split_t_junctions!(regions, regions; atol=atol)`.
"""
split_t_junctions!(
    regions::AbstractVector{CurvilinearRegion{T}};
    atol=onenanometer(T) * 2
) where {T} = split_t_junctions!(regions, regions; atol)

"""
    split_t_junctions!(targets::AbstractVector{<:Polygon}, sources...; atol=2nm) -> Int

[`Polygon`](@ref)-vector method of [`split_t_junctions!`](@ref): inject `sources`
vertices that lie on `targets` polygon edges. Useful for eliminating T junctions
in 2D layout geometry before GDS output (where grid snapping could otherwise open
1 nm gaps along a shared straight boundary). Modifies `targets` in place; returns
the number of vertices inserted.
"""
function split_t_junctions!(
    targets::AbstractVector{<:Polygon{T}},
    sources...;
    atol=onenanometer(T) * 2
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
    for (pi, poly) in enumerate(targets)
        new_poly, n = _node_polygon(poly, idx, 0)
        if n > 0
            targets[pi] = new_poly
            total += n
        end
    end
    return total
end

"""
    split_t_junctions!(regions::AbstractVector{<:Polygon}; atol=2nm) -> Int

Self-noding [`Polygon`](@ref)-vector method. Equivalent to
`split_t_junctions!(regions, regions; atol=atol)`.
"""
split_t_junctions!(
    regions::AbstractVector{<:Polygon{T}};
    atol=onenanometer(T) * 2
) where {T} = split_t_junctions!(regions, regions; atol)

"""
    split_t_junctions!(groups::AbstractDict{Symbol, <:AbstractVector}; atol=2nm) -> Int

Symmetric all-pairs form: for each entry in `groups`, inject onto its regions'
edges the vertices owned by *other* groups. Every group is noded against every
other in a single pass over a shared spatial index — the caller does not need
to know the adjacency graph. Both sides of every shared boundary end up with
the identical ordered vertex sequence, which is what
[`SolidModels.render_conformal!`](@ref) needs its shared-edge cache to resolve
a boundary to one OCC curve on both sides.

Modifies each group's regions in place and returns the total number of
vertices injected across all groups. Foreign-only (never injects a group's own
vertices back onto itself) avoids re-perturbing the within-group vertex sets
that Clipper has already made consistent for each group's own edges.

`atol` has the same meaning and default (2 nm) as the two-argument method
above.

```julia
groups = Dict(:metal => metal_regions, :ground => gnd_regions, :ports => port_regions)
split_t_junctions!(groups; atol=2nm)
```
"""
function split_t_junctions!(
    groups::AbstractDict{Symbol, <:AbstractVector};
    atol=nothing
) where {}
    isempty(groups) && return 0
    T = _noding_coordinate_type(groups)
    isnothing(T) && return 0
    atol_length = isnothing(atol) ? onenanometer(T) * 2 : atol
    # Sort keys so ownership assignment is independent of Dict iteration order —
    # makes group→owner mapping deterministic across runs.
    names = sort!(collect(keys(groups)))
    owner_of = Dict(name => i for (i, name) in enumerate(names))
    indexed = Tuple{Int, Vector{Point{T}}}[]
    for name in names
        verts = Point{T}[]
        for region in groups[name]
            _collect_region_vertices!(verts, region)
        end
        push!(indexed, (owner_of[name], verts))
    end
    idx = _build_vertex_index(indexed, T; atol=atol_length)
    total = 0
    for name in names
        regions = groups[name]
        oid = owner_of[name]
        for (ri, region) in enumerate(regions)
            new_region, n = _node_region(region, idx, oid)
            if n > 0
                regions[ri] = new_region
                total += n
            end
        end
    end
    return total
end

# Coordinate type of the first non-empty group, or `nothing` if all are empty.
function _noding_coordinate_type(groups::AbstractDict{Symbol, <:AbstractVector})
    for (_, regions) in groups
        isempty(regions) || return coordinatetype(regions[1])
    end
    return nothing
end
