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

#####
##### T-junction splitting
#####
# When two shapes share a boundary but their vertices don't line up — one shape
# has a vertex partway along an edge of the other — the pair forms a "T junction".
# This causes two kinds of downstream trouble:
#
#   * For **GDS output**, snapping to the manufacturing grid can round the two
#     sides of the shared boundary apart, opening a ~1 nm gap or overlap.
#   * For **3D meshing**, a mesher (e.g. TetGen) rejects the input with a
#     "vertex lies in segment" PLC error because the shared boundary isn't a
#     1:1 edge correspondence.
#
# [`split_t_junctions!`](@ref) fixes both by injecting each foreign vertex that
# lies on a target edge into that edge, restoring matching vertices on both
# sides. Straight edges get the foreign point inserted directly; curved edges
# (`Paths.Turn`) are split at the corresponding arclength with [`Paths.split`](@ref)
# so the sub-curves stay exact arcs.

# All tolerances below are lengths (in the coordinate type `T`), expressed as a
# multiple of `onenanometer(T)` so the same code is correct for any unit. Defaults
# are tied to the geometry tolerances they must stay consistent with:
#   * `atol` (coincidence) defaults to 1 nm, matching the default rendering
#     discretization tolerance and the GDS 1 nm grid: a foreign vertex within one
#     grid step of an edge is treated as lying on it.
# Angular guards use `rtol`, a *fraction of the segment length*, so a split is
# only made when it lands strictly interior to the edge/arc (never within `rtol`
# of an endpoint, where it would duplicate an existing vertex).

# Collect every vertex (exterior + holes) of a region's curvilinear polygons into
# `pts`, as `Point{T}`.
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

# Foreign points from `candidates` that lie on the arc of `turn`, excluding its
# endpoints, sorted along the direction of travel. Uses the segment's own
# `curvaturecenter` (unit-correct) and `pathlength_nearest`, so no manual
# trigonometry or unit stripping is needed.
function _points_on_turn(turn::Paths.Turn{T}, candidates, atol, rtol::Real) where {T}
    center = Paths.curvaturecenter(turn)
    r = abs(turn.r)
    L = pathlength(turn)
    on_arc = Tuple{T, Point{T}}[]  # (arclength, on-arc point)
    for c in candidates
        # Radial coincidence: is the candidate on the circle of this arc?
        d = hypot(getx(c) - getx(center), gety(c) - gety(center))
        abs(d - r) > atol && continue
        # Arclength of the nearest on-arc point; skip if it's outside (0, L) or
        # within rtol·L of either end (those are the existing arc endpoints).
        s = pathlength_nearest(turn, c)
        (s <= rtol * L || s >= (1 - rtol) * L) && continue
        # Snap to the exact point ON the arc at that arclength (NOT the foreign
        # `c`, which may be up to `atol` off-arc — using `c` would break the
        # `CurvilinearPolygon` constructor's tight point/endpoint agreement).
        push!(on_arc, (convert(T, s), turn(s)))
    end
    sort!(on_arc; by=first)  # by arclength = order of travel along the arc
    return on_arc
end

# Foreign points from `candidates` that lie on the straight edge p1→p2, excluding
# its endpoints, sorted along the edge. Returns the injected points as `Point{T}`.
function _points_on_edge(p1::Point{T}, p2::Point{T}, candidates, atol, rtol::Real) where {T}
    d = p2 - p1
    len = hypot(getx(d), gety(d))
    on_edge = Tuple{Float64, Point{T}}[]  # (parameter t∈(0,1), foreign point)
    len <= atol && return on_edge  # degenerate edge
    for c in candidates
        rel = c - p1
        # projection parameter t along the edge, as a unitless Float64
        t = Float64((getx(rel) * getx(d) + gety(rel) * gety(d)) / len^2)
        (t <= rtol || t >= 1 - rtol) && continue                # interior only
        # Perpendicular distance from the edge line (a length).
        cross = getx(rel) * gety(d) - gety(rel) * getx(d)       # length²
        perp = abs(cross) / len
        perp > atol && continue
        push!(on_edge, (t, c))  # a straight-edge split reuses the foreign point verbatim
    end
    sort!(on_edge; by=first)
    return on_edge
end

# Rebuild one `CurvilinearPolygon`, injecting foreign vertices onto its edges.
# Returns the (possibly rebuilt) polygon and the number of vertices inserted.
function _inject_edge_vertices(
    cpoly::CurvilinearPolygon{T},
    candidates;
    atol,
    rtol::Real
) where {T}
    pts = points(cpoly)
    n = length(pts)
    n < 3 && return cpoly, 0
    curve_at = Dict(csi => i for (i, csi) in enumerate(cpoly.curve_start_idx))
    new_points = Point{T}[]
    new_curves = eltype(cpoly.curves)[]
    new_csi = Int[]
    inserted = 0
    for i = 1:n
        push!(new_points, pts[i])
        if haskey(curve_at, i)
            # Curved edge starting at vertex i.
            seg = cpoly.curves[curve_at[i]]
            if seg isa Paths.Turn
                splits = _points_on_turn(seg, candidates, atol, rtol)
                if isempty(splits)
                    push!(new_curves, seg)
                    push!(new_csi, length(new_points))
                else
                    # Split the turn successively at each interior arclength. Work
                    # in remaining-arclength coordinates as the head is peeled off.
                    remaining = seg
                    consumed = zero(pathlength(seg))
                    for (s, on_pt) in splits
                        s_local = s - consumed
                        sub1, sub2 = Paths.split(remaining, s_local)
                        push!(new_curves, sub1)
                        push!(new_csi, length(new_points))
                        push!(new_points, on_pt)
                        remaining = sub2
                        consumed = s
                        inserted += 1
                    end
                    push!(new_curves, remaining)
                    push!(new_csi, length(new_points))
                end
            else
                push!(new_curves, seg)
                push!(new_csi, length(new_points))
            end
        else
            # Straight edge pts[i] → pts[i+1].
            p2 = pts[mod1(i + 1, n)]
            for (_, c) in _points_on_edge(pts[i], p2, candidates, atol, rtol)
                push!(new_points, c)
                inserted += 1
            end
        end
    end
    inserted == 0 && return cpoly, 0
    return CurvilinearPolygon{T}(new_points, new_curves, new_csi), inserted
end

"""
    split_t_junctions!(targets, sources...; atol=onenanometer(T), rtol=1e-6) -> Int

Inject every vertex of the `sources` that lies on an edge of `targets` into that
edge, so that a boundary shared between the two groups has matching vertices on
both sides. Modifies `targets` in place and returns the number of vertices
inserted.

`targets` and each of `sources` are iterables of [`CurvilinearRegion`](@ref).
A T junction occurs where a `sources` vertex lands partway along a `targets`
edge without a corresponding `targets` vertex there. This function eliminates
those junctions:

  - **Straight edges** get the foreign vertex inserted verbatim (the two copies,
    one per side, coincide and are treated as the same point downstream).
  - **Curved edges** (`Paths.Turn`) are split at the foreign vertex's arclength
    with [`Paths.split`](@ref), so the resulting sub-arcs remain exact. The
    injected vertex is the exact point on the arc at that arclength, not the
    (possibly slightly off-arc) foreign vertex.

Fixing T junctions avoids 1 nm gaps from manufacturing-grid snapping in GDS output
and "vertex lies in segment" PLC errors when meshing a solid model.

# Keywords

  - `atol`: coincidence tolerance (a length). A foreign vertex within `atol` of a
    target edge (perpendicular distance for straight edges, radial distance for
    arcs) is considered to lie on it. Defaults to `onenanometer(T)`, matching the
    default rendering discretization tolerance and the GDS 1 nm grid.
  - `rtol`: relative endpoint guard, as a fraction of edge/arc length. Splits
    within `rtol` of an endpoint are skipped, since those coincide with an
    existing vertex. Defaults to `1e-6`.

# Example

```julia
targets = union2d_curved(cs => :metal_negative) # Vector{<:CurvilinearRegion}
sources = union2d_curved(cs => :metal_positive)
split_t_junctions!(targets, sources)
```

A [`Polygon`](@ref)-vector method is also provided for GDS-style geometry.
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
    total = 0
    for (ri, region) in enumerate(targets)
        new_ext, n_ext = _inject_edge_vertices(region.exterior, candidates; atol, rtol)
        new_holes = CurvilinearPolygon{T}[]
        n_holes = 0
        for h in region.holes
            new_h, n_h = _inject_edge_vertices(h, candidates; atol, rtol)
            push!(new_holes, new_h)
            n_holes += n_h
        end
        if n_ext + n_holes > 0
            targets[ri] = CurvilinearRegion{T}(new_ext, new_holes)
            total += n_ext + n_holes
        end
    end
    return total
end

"""
    split_t_junctions!(targets::AbstractVector{<:Polygon}, sources...; atol, rtol) -> Int

`Polygon`-vector method of [`split_t_junctions!`](@ref): inject `sources` vertices
that lie on `targets` polygon edges. Useful for eliminating T junctions in 2D
layout geometry before GDS output (where grid snapping could otherwise open 1 nm
gaps along a shared straight boundary). Modifies `targets` in place; returns the
number of vertices inserted.
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
    total = 0
    for (pi, poly) in enumerate(targets)
        pts = points(poly)
        n = length(pts)
        n < 3 && continue
        new_points = Point{T}[]
        inserted = 0
        for i = 1:n
            push!(new_points, pts[i])
            p2 = pts[mod1(i + 1, n)]
            for (_, c) in _points_on_edge(pts[i], p2, candidates, atol, rtol)
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
