# All-pairs symmetric noding for [`render_conformal!`](@ref).
#
# After boolean operations hand back a `Dict{Symbol, Vector{CurvilinearRegion}}`
# (one entry per physical group), adjacent groups that share a boundary must
# carry the *same* vertex sequence along it for the shared-edge cache in
# `render_conformal!` to resolve the boundary to a single OCC curve entity on
# both sides. Clipper does not guarantee this: two independent booleans can put
# a vertex at a location on one side of a shared edge but not the other, leaving
# a T-junction the mesher rejects ("vertex lies in segment").
#
# `mutual_node!` fixes this for every group at once. It builds a single spatial
# hash of every group's vertices, then injects, into each group's edges, every
# vertex owned by a *different* group that lies on the edge interior. The result
# is symmetric by construction — if group A has a vertex on group B's edge, B
# gets it injected, and vice versa — so both sides of every shared boundary end
# up with the identical ordered vertex sequence.
#
# Straight edges get the foreign vertex inserted verbatim (bit-exact — the
# render-time point merge unifies the two copies into one OCC point). Curved
# edges (`Paths.Turn`, `Paths.BSpline`, …) are split at the foreign vertex's
# arclength via `Paths.split`, so curves stay native and exact — never
# discretized.

# Integer-nm key for a vertex (Clipper emits on an integer grid, so exact
# coincidences hash exactly; near-coincidences are caught by the tolerance
# checks downstream). Coordinates are converted to nm so the key, the cell
# size, and `node_tol` are all in the same unit regardless of the input's unit.
_vertex_key(p) = (
    round(Int, Float64(ustrip(u"nm", getx(p)))),
    round(Int, Float64(ustrip(u"nm", gety(p))))
)

# Spatial-hash cell size (nm). Larger than any node tolerance, far smaller than
# feature size, so a candidate for edge (x1,y1)→(x2,y2) is always found within
# the edge's bounding-box cell range.
const _NODE_CELL = 100.0

# Build the global vertex index across every group:
#   owners : nm-key → Set of group names owning a vertex there
#   point  : nm-key → a representative original `Point` (reused bit-exact, so an
#            injected vertex is identical to the partner's copy and the render
#            cache merges them into one OCC point)
#   cells  : (cx, cy) → Vector of nm-keys in that cell
function _build_vertex_index(groups)
    owners = Dict{Tuple{Int, Int}, Set{Symbol}}()
    point = Dict{Tuple{Int, Int}, Any}()
    cells = Dict{Tuple{Int, Int}, Vector{Tuple{Int, Int}}}()
    index_cpoly! = function (cpoly, name)
        for p in points(cpoly)
            key = _vertex_key(p)
            g = get!(Set{Symbol}, owners, key)
            if isempty(g)
                point[key] = p
                cx = floor(Int, key[1] / _NODE_CELL)
                cy = floor(Int, key[2] / _NODE_CELL)
                push!(get!(Vector{Tuple{Int, Int}}, cells, (cx, cy)), key)
            end
            push!(g, name)
        end
    end
    for (name, regions) in groups
        for region in regions
            index_cpoly!(region.exterior, name)
            for hole in region.holes
                index_cpoly!(hole, name)
            end
        end
    end
    return owners, point, cells
end

# Foreign on-edge vertices for a straight edge p1→p2, as `(t, Point)` sorted by
# parameter, excluding this group's own vertices and the edge endpoints.
function _foreign_points_on_edge(
    p1::Point{T},
    p2::Point{T},
    group::Symbol,
    owners,
    point,
    cells,
    node_tol::Float64
) where {T}
    x1 = Float64(ustrip(u"nm", getx(p1)))
    y1 = Float64(ustrip(u"nm", gety(p1)))
    x2 = Float64(ustrip(u"nm", getx(p2)))
    y2 = Float64(ustrip(u"nm", gety(p2)))
    dx = x2 - x1
    dy = y2 - y1
    len_sq = dx * dx + dy * dy
    len_sq <= (2 * node_tol)^2 && return Tuple{Float64, Point{T}}[]
    len = sqrt(len_sq)
    end_t = node_tol / len
    xmin = min(x1, x2) - node_tol
    xmax = max(x1, x2) + node_tol
    ymin = min(y1, y2) - node_tol
    ymax = max(y1, y2) + node_tol
    cx0 = floor(Int, xmin / _NODE_CELL)
    cx1 = floor(Int, xmax / _NODE_CELL)
    cy0 = floor(Int, ymin / _NODE_CELL)
    cy1 = floor(Int, ymax / _NODE_CELL)
    found = Tuple{Float64, Point{T}}[]
    for cx = cx0:cx1, cy = cy0:cy1
        keys = get(cells, (cx, cy), nothing)
        keys === nothing && continue
        for key in keys
            os = owners[key]
            (length(os) == 1 && group in os) && continue  # only this group owns it
            px = Float64(key[1])
            py = Float64(key[2])
            t = ((px - x1) * dx + (py - y1) * dy) / len_sq
            (t <= end_t || t >= 1.0 - end_t) && continue
            perp = abs((px - x1) * dy - (py - y1) * dx) / len
            perp > node_tol && continue
            push!(found, (t, point[key]))
        end
    end
    sort!(found; by=first)
    # Drop candidates closer than node_tol *along* the edge to the previous
    # kept one — two near-coincident foreign vertices would otherwise inject a
    # sub-tolerance-length edge that the render-time point merge then collapses
    # to a degenerate (zero-length) edge.
    isempty(found) && return found
    min_dt = node_tol / len
    kept = Tuple{Float64, Point{T}}[found[1]]
    for k = 2:length(found)
        found[k][1] - kept[end][1] < min_dt && continue
        push!(kept, found[k])
    end
    return kept
end

# Foreign on-curve vertices for a curved edge, as `Point`s sorted by arclength.
# A candidate qualifies when `pathlength_nearest` projects it strictly interior
# (> node_tol from either end) with residual ≤ node_tol. The curve's discretized
# bounding box supplies candidate cells; the curve itself is never replaced.
function _foreign_points_on_curve(
    curve,
    group::Symbol,
    owners,
    point,
    cells,
    node_tol::Float64
)
    T = coordinatetype(Paths.p0(curve))
    atol = onenanometer(T)
    disc = DeviceLayout.discretize_curve(curve, atol; rtol=nothing)
    isempty(disc) && return Point{T}[]
    L_nm = Float64(ustrip(u"nm", pathlength(curve)))
    # The polyline approximates the curve to within `atol` (1 nm), so widen the
    # perpendicular tolerance by that slop to avoid rejecting a candidate that
    # is within node_tol of the true curve but slightly further from the chord.
    atol_nm = 1.0
    perp_tol = node_tol + atol_nm
    tol2 = perp_tol * perp_tol
    seen = Set{Tuple{Int, Int}}()
    found = Tuple{Float64, Point{T}}[]
    nd = length(disc)
    for j = 1:(nd - 1)
        ax = Float64(ustrip(u"nm", getx(disc[j])))
        ay = Float64(ustrip(u"nm", gety(disc[j])))
        bx = Float64(ustrip(u"nm", getx(disc[j + 1])))
        by = Float64(ustrip(u"nm", gety(disc[j + 1])))
        sxmin = min(ax, bx) - perp_tol
        sxmax = max(ax, bx) + perp_tol
        symin = min(ay, by) - perp_tol
        symax = max(ay, by) + perp_tol
        cx0 = floor(Int, sxmin / _NODE_CELL)
        cx1 = floor(Int, sxmax / _NODE_CELL)
        cy0 = floor(Int, symin / _NODE_CELL)
        cy1 = floor(Int, symax / _NODE_CELL)
        vx = bx - ax
        vy = by - ay
        seg_len2 = vx * vx + vy * vy
        for cx = cx0:cx1, cy = cy0:cy1
            keys = get(cells, (cx, cy), nothing)
            keys === nothing && continue
            for key in keys
                key in seen && continue
                os = owners[key]
                (length(os) == 1 && group in os) && continue
                px = Float64(key[1])
                py = Float64(key[2])
                # Cheap perpendicular-distance-to-segment pre-filter. Don't mark
                # `seen` on a miss — a later segment sharing this cell may still
                # be within tolerance of the same candidate. `seg_len2 > 0` here:
                # `discretize_curve` never emits coincident consecutive points.
                t = ((px - ax) * vx + (py - ay) * vy) / seg_len2
                t = clamp(t, 0.0, 1.0)
                qx = ax + t * vx
                qy = ay + t * vy
                d2 = (px - qx)^2 + (py - qy)^2
                d2 > tol2 && continue
                push!(seen, key)
                V = point[key]
                s = Paths.pathlength_nearest(curve, V)
                s_nm = Float64(ustrip(u"nm", s))
                (s_nm <= node_tol || s_nm >= L_nm - node_tol) && continue
                cs_pt = curve(s)
                resid = sqrt(
                    Float64(ustrip(u"nm", getx(cs_pt) - getx(V)))^2 +
                    Float64(ustrip(u"nm", gety(cs_pt) - gety(V)))^2
                )
                resid > node_tol && continue
                push!(found, (s_nm, V))
            end
        end
    end
    isempty(found) && return Point{T}[]
    sort!(found; by=first)
    out = Point{T}[]
    prev_s = -Inf
    for (s_nm, V) in found
        s_nm - prev_s < node_tol && continue  # de-dup co-located along the curve
        push!(out, V)
        prev_s = s_nm
    end
    return out
end

# Node one contour against the global vertex index. Straight edges get foreign
# vertices inserted verbatim; curved edges are split at the foreign arclength
# via `Paths.split` (staying native/exact). Returns (new_cpoly, n_injected).
function _node_contour!(
    cpoly::CurvilinearPolygon{T},
    group::Symbol,
    owners,
    point,
    cells,
    node_tol::Float64
) where {T}
    pts = points(cpoly)
    n = length(pts)
    n < 3 && return cpoly, 0
    curve_at = Dict{Int, Any}()
    for (ci, csi) in enumerate(cpoly.curve_start_idx)
        curve_at[csi] = cpoly.curves[ci]
    end
    new_points = Point{T}[]
    new_curves = typeof(cpoly.curves)()
    new_csis = Int[]
    n_injected = 0
    for i = 1:n
        push!(new_points, pts[i])
        start_idx = length(new_points)
        if haskey(curve_at, i)
            curve = curve_at[i]
            splits = _foreign_points_on_curve(curve, group, owners, point, cells, node_tol)
            if isempty(splits)
                push!(new_curves, curve)
                push!(new_csis, start_idx)
            else
                remaining = curve
                acc_idx = start_idx
                for V in splits
                    l = pathlength(remaining)
                    s = Paths.pathlength_nearest(remaining, V)
                    s_nm = Float64(ustrip(u"nm", s))
                    l_nm = Float64(ustrip(u"nm", l))
                    (s_nm <= node_tol || s_nm >= l_nm - node_tol) && continue
                    s1, s2 = Paths.split(remaining, s)
                    push!(new_curves, s1)
                    push!(new_csis, acc_idx)
                    push!(new_points, V)  # bit-exact foreign Point
                    acc_idx = length(new_points)
                    remaining = s2
                    n_injected += 1
                end
                push!(new_curves, remaining)
                push!(new_csis, acc_idx)
            end
        else
            p2 = pts[mod1(i + 1, n)]
            for (_, V) in
                _foreign_points_on_edge(pts[i], p2, group, owners, point, cells, node_tol)
                push!(new_points, V)
                n_injected += 1
            end
        end
    end
    n_injected == 0 && return cpoly, 0
    if !isempty(new_csis)
        perm = sortperm(new_csis)
        new_curves = new_curves[perm]
        new_csis = new_csis[perm]
    end
    return CurvilinearPolygon{T}(new_points, new_curves, new_csis), n_injected
end

"""
    mutual_node!(groups::AbstractDict{Symbol, <:AbstractVector}; node_tol=2.0) -> Int

Symmetric all-pairs noding across a collection of named region groups. For every
edge of every group, inject the vertices owned by *other* groups that lie on the
edge interior (perpendicular distance ≤ `node_tol` nm, strictly between the
endpoints). Straight edges get the foreign vertex inserted verbatim; curved
edges (`Paths.Turn`, `Paths.BSpline`, …) are split at the foreign vertex's
arclength via [`Paths.split`](@ref), so curves stay native and exact. Modifies
each group's regions in place and returns the total number of vertices injected.

Makes adjacent groups conformal for [`render_conformal!`](@ref): both sides of
every shared boundary end up with the identical ordered vertex sequence, which
is what the shared-edge cache needs to resolve a boundary to one OCC curve on
both sides. Every group is noded against every other in a single pass over a
shared spatial index — the caller does not need to know the adjacency graph.

`node_tol` (nm) must be ≥ the maximum coordinate drift between two groups'
copies of the same logical vertex and ≪ the minimum feature size. The default
2 nm covers the ≤ ~1.5 nm drift `discretize_curve` can introduce and is far
below any real feature, so it never bridges two genuinely distinct vertices.
Coordinates are interpreted in nm regardless of the input Points' unit, so the
tolerance means the same physical distance whether the geometry is expressed in
nm or µm.

```julia
groups = Dict(:metal => metal_regions, :ground => gnd_regions, :ports => port_regions)
mutual_node!(groups)
for (name, regions) in groups
    add_conformal_loop!.(Ref(ctx), regions, k, z; points_cache)
end
```
"""
function mutual_node!(groups::AbstractDict{Symbol, <:AbstractVector}; node_tol::Float64=2.0)
    owners, point, cells = _build_vertex_index(groups)
    isempty(cells) && return 0
    total = 0
    for (name, regions) in groups
        isempty(regions) && continue
        T = coordinatetype(regions[1])
        for (ri, region) in enumerate(regions)
            new_ext, n_ext =
                _node_contour!(region.exterior, name, owners, point, cells, node_tol)
            new_holes = CurvilinearPolygon{T}[]
            n_holes = 0
            for hole in region.holes
                h_new, n_h = _node_contour!(hole, name, owners, point, cells, node_tol)
                push!(new_holes, h_new)
                n_holes += n_h
            end
            if n_ext + n_holes > 0
                regions[ri] = CurvilinearRegion{T}(new_ext, new_holes)
                total += n_ext + n_holes
            end
        end
    end
    return total
end
