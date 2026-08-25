# Geometry preprocessing for [`render_conformal!`](@ref).
#
# After boolean operations (e.g. [`union2d_curved`](@ref)) hand back a
# `Vector{CurvilinearRegion}` (or `Dict{Symbol,Vector{CurvilinearRegion}}` if
# multiple layers were computed together), a self-touching contour can make OCC
# or the mesher reject the geometry: Clipper's union can produce polygons where
# two non-adjacent vertices coincide — a zero-width neck or figure-8 — which OCC
# rejects with "Curve loop is not closed". [`split_pinches`](@ref) detects these
# and splits them into simple sub-polygons.
#
# It operates on `CurvilinearRegion` (or `Vector{CurvilinearRegion}`) and
# preserves native curve segments (`Paths.Turn`, `Paths.BSpline`) — arcs are
# carried through to each sub-polygon by remapping curve indices rather than
# discretized.

"""
    find_pinch_points(pts; atol_nm=2.0) -> Vector{Tuple{Int,Int}}

Return `(i, j)` index pairs where non-adjacent contour vertices coincide
within `atol_nm`. Uses a hash grid for O(n) detection. Adjacent vertices
(including the wraparound pair) are excluded — those are joined by a real
edge, not a pinch.

`atol_nm` should match the point-merge tolerance used at render time (see
[`ConformalRenderContext`](@ref)'s `vertex_merge_atol`), so pinch detection
predicts OCC's behaviour after the two vertices merge.
"""
function find_pinch_points(pts; atol_nm::Float64=2.0)
    n = length(pts)
    n < 4 && return Tuple{Int, Int}[]
    cell = max(atol_nm, 1.0)
    # `cell`, `tol2`, and `atol_nm` are all in nm, so coordinates must be too —
    # strip to nm explicitly rather than to the Point's storage unit, so the
    # tolerance is the same physical distance whether the input is nm- or
    # µm-based (µm coordinates stripped bare would be 1000× too close together).
    coords =
        [(Float64(ustrip(u"nm", getx(p))), Float64(ustrip(u"nm", gety(p)))) for p in pts]
    grid = Dict{Tuple{Int, Int}, Vector{Int}}()
    pinches = Tuple{Int, Int}[]
    tol2 = atol_nm * atol_nm
    for i = 1:n
        x, y = coords[i]
        ci = (floor(Int, x / cell), floor(Int, y / cell))
        for dcx = -1:1, dcy = -1:1
            for j in get(grid, (ci[1] + dcx, ci[2] + dcy), Int[])
                # j < i (only earlier points are in the grid). Skip adjacency.
                (j == i - 1 || (j == 1 && i == n)) && continue
                xj, yj = coords[j]
                dx = x - xj
                dy = y - yj
                dx * dx + dy * dy <= tol2 && push!(pinches, (j, i))
            end
        end
        push!(get!(Vector{Int}, grid, ci), i)
    end
    return pinches
end

# Split a contour at a pinch (vertices i and j coincide, i < j) into two
# simple loops. Each lobe keeps exactly one copy of the pinch point.
function _split_at_pinch(cpoly::CurvilinearPolygon, i::Int, j::Int)
    pts = points(cpoly)
    curves = cpoly.curves
    csis = cpoly.curve_start_idx
    n = length(pts)
    idx1 = collect(i:(j - 1))
    idx2 = vcat(collect(j:n), collect(1:(i - 1)))
    pts1 = pts[idx1]
    pts2 = pts[idx2]
    pos1 = Dict(k => p for (p, k) in enumerate(idx1))
    pos2 = Dict(k => p for (p, k) in enumerate(idx2))
    curves1 = typeof(curves)()
    curves2 = typeof(curves)()
    csis1 = Int[]
    csis2 = Int[]
    for (ci, csi) in enumerate(csis)
        if haskey(pos1, csi)
            push!(curves1, curves[ci])
            push!(csis1, pos1[csi])
        elseif haskey(pos2, csi)
            push!(curves2, curves[ci])
            push!(csis2, pos2[csi])
        end
    end
    return CurvilinearPolygon(pts1, curves1, csis1),
    CurvilinearPolygon(pts2, curves2, csis2)
end

# Repeatedly split a contour at its first remaining pinch until no pinches
# remain. Drop sub-loops with < 3 vertices — those are zero-area slivers
# produced when several collinear pinches carve off a 2-point piece.
function _split_cpoly_at_pinches(cpoly::CurvilinearPolygon)
    results = typeof(cpoly)[]
    queue = typeof(cpoly)[cpoly]
    while !isempty(queue)
        cp = popfirst!(queue)
        length(points(cp)) < 3 && continue
        pinches = find_pinch_points(points(cp))
        if isempty(pinches)
            push!(results, cp)
        else
            cp1, cp2 = _split_at_pinch(cp, pinches[1]...)
            push!(queue, cp1)
            push!(queue, cp2)
        end
    end
    return results
end

# Ray-cast point-in-polygon. Coordinates are stripped to nm (matching the
# `px`/`py` the caller passes), so the test is unit-invariant.
function _point_in_poly(px::Float64, py::Float64, poly_pts)
    n = length(poly_pts)
    inside = false
    j = n
    for i = 1:n
        xi = Float64(ustrip(u"nm", getx(poly_pts[i])))
        yi = Float64(ustrip(u"nm", gety(poly_pts[i])))
        xj = Float64(ustrip(u"nm", getx(poly_pts[j])))
        yj = Float64(ustrip(u"nm", gety(poly_pts[j])))
        if ((yi > py) != (yj > py)) && (px < (xj - xi) * (py - yi) / (yj - yi) + xi)
            inside = !inside
        end
        j = i
    end
    return inside
end

function _split_all_pinches(region::CurvilinearRegion)
    ext_pieces = _split_cpoly_at_pinches(region.exterior)
    simple_holes = eltype(region.holes)[]
    for h in region.holes
        append!(simple_holes, _split_cpoly_at_pinches(h))
    end
    if length(ext_pieces) == 1
        return [CurvilinearRegion(ext_pieces[1], simple_holes)]
    end
    # Multiple exterior pieces — assign each hole to the piece that contains
    # it. Sort pieces largest-first so a representative-vertex test resolves
    # nesting sanely.
    order = sortperm(ext_pieces; by=cp -> length(points(cp)), rev=true)
    ext_pieces = ext_pieces[order]
    hole_buckets = [eltype(region.holes)[] for _ in ext_pieces]
    for h in simple_holes
        hp = points(h)
        isempty(hp) && continue
        hx = Float64(ustrip(u"nm", getx(hp[1])))
        hy = Float64(ustrip(u"nm", gety(hp[1])))
        assigned = false
        for (pi, ext) in enumerate(ext_pieces)
            if _point_in_poly(hx, hy, points(ext))
                push!(hole_buckets[pi], h)
                assigned = true
                break
            end
        end
        assigned || push!(hole_buckets[1], h)
    end
    return [
        CurvilinearRegion(ext_pieces[pi], hole_buckets[pi]) for pi in eachindex(ext_pieces)
    ]
end

"""
    split_pinches(regions::Vector{<:CurvilinearRegion}) -> Vector{CurvilinearRegion}

Split every self-touching region (on the exterior AND every hole) into simple
sub-regions. A region is left untouched only if neither its exterior nor any
hole has a pinch. Returns an expanded vector.

Pinches are detected at a 2 nm tolerance (matching the default
`ConformalRenderContext` `vertex_merge_atol`). Sub-loops with fewer than
three vertices are dropped — those are zero-area slivers.

Curves (`Paths.Turn`, `Paths.BSpline`, `Paths.OffsetSegment`) are preserved
by remapping `curve_start_idx` to the new vertex indices within each lobe.
"""
function split_pinches(regions)
    result = CurvilinearRegion[]
    for r in regions
        clean =
            isempty(find_pinch_points(points(r.exterior))) &&
            all(h -> isempty(find_pinch_points(points(h))), r.holes)
        if clean
            push!(result, r)
        else
            append!(result, _split_all_pinches(r))
        end
    end
    return result
end
