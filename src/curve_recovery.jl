# Provenance-based curve recovery.
# Included in Curvilinear — needs CurvilinearRegion, discretize_curve, and the Polygons clip functions.

using .Polygons: clipperize, ClippedPolygon, union2d, difference2d, intersect2d, xor2d

# One discretized curve's footprint on the integer grid, paired with its source segment.
# The integer-grid coordinate type P matches whatever Polygons.clipperize(::Point{R}) produces.
struct ProvenanceRun{P}
    run::Vector{P}
    curve::Paths.Segment
end

# Returns (polys::Vector{Polygon{R}}, runs::Vector{ProvenanceRun}) for one operand.
# `R` is the promoted coordinate type clip will use; discretization uses clip's default atol.
function discretize_with_provenance(entities, ::Type{R}) where {R}
    polys = Polygon{R}[]
    runs = ProvenanceRun[]
    atol = DeviceLayout.onenanometer(R)
    for ent in entities
        _collect_provenance!(polys, runs, ent, R, atol)
    end
    return polys, runs
end

# CurvilinearPolygon: walk exactly like to_polygons(::CurvilinearPolygon), but also
# record each curve's full [start, interior…, end] run, snapped to the integer grid.
function _collect_provenance!(polys, runs, e::CurvilinearPolygon, ::Type{R}, atol) where {R}
    ec = convert(CurvilinearPolygon{R}, e)
    i = 1
    p = Point{R}[]
    for (csi, c) in zip(ec.curve_start_idx, ec.curves)
        append!(p, ec.p[i:csi])
        wrapped_end = mod1(csi + 1, length(ec.p))
        pp = DeviceLayout.discretize_curve(c, atol; rtol=nothing)
        run_pts = vcat([ec.p[csi]], pp[2:(end - 1)], [ec.p[wrapped_end]])
        push!(runs, ProvenanceRun(clipperize.(run_pts), c))
        append!(p, pp[2:(end - 1)])
        i = csi + 1
    end
    append!(p, ec.p[i:end])
    push!(polys, Polygon{R}(p))
    return nothing
end

# CurvilinearRegion: exterior + holes, each a CurvilinearPolygon.
function _collect_provenance!(polys, runs, e::CurvilinearRegion, ::Type{R}, atol) where {R}
    _collect_provenance!(polys, runs, e.exterior, R, atol)
    for h in e.holes
        _collect_provenance!(polys, runs, _reverse(h), R, atol)
    end
    return nothing
end

# Any other entity: no curves to recover; discretize to polygons.
function _collect_provenance!(polys, runs, e, ::Type{R}, atol) where {R}
    # Convert to polygons and append. to_polygons returns a polygon or array.
    poly_result = DeviceLayout.to_polygons(e)
    if poly_result isa Polygon
        push!(polys, convert(Polygon{R}, poly_result))
    else
        # It's a vector or other collection of polygons
        for poly in poly_result
            push!(polys, convert(Polygon{R}, poly))
        end
    end
    return nothing
end

# Search `contour` (treated as cyclic) for `run` as a contiguous block, forward or reversed.
# Returns (start, reversed) of the first hit (1-based start index into contour), or nothing.
# Exact integer equality — no tolerance.
function match_run(contour::AbstractVector{P}, run::AbstractVector{P}) where {P}
    n = length(contour)
    m = length(run)
    (m == 0 || m > n) && return nothing
    rev = reverse(run)
    for s = 1:n
        fwd_ok = true
        rev_ok = true
        for k = 0:(m - 1)
            cv = contour[mod1(s + k, n)]
            fwd_ok &= (cv == run[k + 1])
            rev_ok &= (cv == rev[k + 1])
            (fwd_ok || rev_ok) || break
        end
        fwd_ok && return (start=s, reversed=false)
        rev_ok && return (start=s, reversed=true)
    end
    return nothing
end

# Walk a ClippedPolygon's PolyNode tree, substituting known curves back into each contour
# wherever a ProvenanceRun's discretized integer-grid point-run survived a boolean op intact.
# Returns Vector{CurvilinearRegion{T}}: one region per outer contour (its direct children are
# holes; grandchildren start new regions), mirroring to_primitives(::SolidModel, ::ClippedPolygon).
#
# Each run matches at most once globally — `used` is shared across all contours.
# `report`, if given, collects (status::Symbol, curve, contour_index) tuples with
# status ∈ (:recovered, :clipped); :clipped runs (never matched) carry contour_index 0.
function substitute_curves(clipped::ClippedPolygon{T}, runs; report=nothing) where {T}
    out = CurvilinearRegion{T}[]
    contour_index = Ref(0)
    used = falses(length(runs))                  # shared across ALL contours
    function build_cpoly(node)
        pts = collect(node.contour)              # Vector{Point{T}}
        snapped = clipperize.(pts)
        n = length(pts)
        contour_index[] += 1
        ci = contour_index[]
        # Find each surviving run's span: (start, m, segment), start 1-based into `pts`,
        # m = number of contour vertices the run occupies (cyclically start … start+m-1).
        matched = Tuple{Int, Int, Paths.Segment}[]
        # match_run is exact and translation-sensitive: two geometrically distinct curves
        # produce distinct integer runs, so first-match-wins cannot misattribute. Only
        # overlapping (degenerate) curves could share a run, which is not handled.
        for (ri, pr) in enumerate(runs)
            used[ri] && continue
            hit = match_run(snapped, pr.run)
            isnothing(hit) && continue
            seg = hit.reversed ? reverse(pr.curve) : pr.curve
            push!(matched, (hit.start, length(pr.run), seg))
            used[ri] = true
            !isnothing(report) && push!(report, (:recovered, pr.curve, ci))
        end
        isempty(matched) && return CurvilinearPolygon{T}(pts, Paths.Segment[], Int[])

        # A curve replaces its discretized run: keep only the run's two endpoints, drop the
        # m-2 interior vertices, and point curve_start_idx at the (reduced-list) start vertex.
        # Mark interior positions to drop, and starts to tag.
        drop = falses(n)
        start_seg = Dict{Int, Paths.Segment}()
        for (s, m, seg) in matched
            start_seg[s] = seg
            for k = 1:(m - 2)                    # strictly-interior positions, cyclic
                drop[mod1(s + k, n)] = true
            end
        end
        # Single ordered pass: build reduced point list and record curve starts at their
        # index in the reduced list. (Starts/ends are never dropped, so they survive.)
        reduced = Point{T}[]
        curves = Paths.Segment[]
        csis = Int[]
        for i = 1:n
            drop[i] && continue
            push!(reduced, pts[i])
            if haskey(start_seg, i)
                push!(curves, start_seg[i])
                push!(csis, length(reduced))      # this vertex's index in `reduced`
            end
        end
        return CurvilinearPolygon{T}(reduced, curves, csis)
    end
    function add_region(node)
        ext = build_cpoly(node)
        # Holes must be CCW, but come out CW from Clipper
        holes =
            CurvilinearPolygon{T}[_reverse(build_cpoly(child)) for child in node.children]
        push!(out, CurvilinearRegion{T}(ext, holes))
        for child in node.children
            for gc in child.children
                add_region(gc)
            end
        end
    end
    for child in clipped.tree.children
        add_region(child)
    end
    if !isnothing(report)
        for (ri, pr) in enumerate(runs)
            used[ri] || push!(report, (:clipped, pr.curve, 0))
        end
    end
    return out
end

# Normalize a clip operand into a flat Vector of entities, preserving curve-bearing
# entities intact (unlike _normalize_clip_arg, which discretizes via to_polygons).
_as_entities(p::DeviceLayout.GeometryEntity) = [p]
_as_entities(p::AbstractArray) = collect(Iterators.flatten(_as_entities.(p)))
_as_entities(p::Union{GeometryStructure, GeometryReference}) =
    _as_entities(flat_elements(p))
_as_entities(p::Pair{<:Union{GeometryStructure, GeometryReference}}) =
    _as_entities(flat_elements(p))
function _as_entities(p::Paths.Node)
    iszero(pathlength(p.seg)) && p.sty isa ContinuousStyle && return []
    return _as_entities(pathtopolys(p)) # Use `islinear` dispatch on segment and style
end
# A Rounded-styled straight Polygon recovers as its exact-arc CurvilinearPolygon, so
# corners survive the clip. Mirrors to_primitives(::SolidModel, ::StyledEntity{Polygon,Rounded}).
function _as_entities(
    p::StyledEntity{T, <:Union{Polygon{T}, Polygons.Rectangle{T}}, <:Polygons.Rounded}
) where {T}
    return [
        round_to_curvilinearpolygon(
            p.ent,
            radius(p.sty),
            min_side_len=p.sty.min_side_len,
            corner_indices=cornerindices(p.ent, p.sty),
            min_angle=p.sty.min_angle
        )
    ]
end
# A geometrically-transparent style (e.g. MeshSized — a mesh-density hint applied via
# `to_polygons(ent, ::MeshSized) = to_polygons(ent)`) must NOT block curve recovery: a
# MeshSized-wrapped Node / Rounded-Polygon / CurvilinearPolygon carries the same curves as
# the bare entity. Without this, such a wrapped entity falls to the generic
# `_as_entities(::GeometryEntity) = [p]` and is discretized by `to_polygons`, silently losing
# its arcs through the boolean. Recurse to the inner entity (mirrors the render-side default
# `to_primitives(::SolidModel, ::StyledEntity) = to_primitives(sm, ent.ent)`). The specific
# Rounded method above is more specific and still wins for Rounded-styled Polygon/Rectangle.
_as_entities(p::StyledEntity) = _as_entities(p.ent)

# Promoted coordinate type matching what clip's promote_type would pick.
function _recover_coordtype(plus, minus)
    return promote_type(
        DeviceLayout.coordinatetype(plus),
        DeviceLayout.coordinatetype(minus)
    )
end

"""
    recover_curves(op, plus, minus; report=nothing)

Run a boolean operation `op` on `plus` and `minus`, then recover original curves from the
discretized result wherever they survived the operation intact. Returns
`Vector{CurvilinearRegion}` — one region per outer contour in the clipped result (each
disjoint piece becomes a separate region).

## Positional arguments

The first argument `op` must be one of the polygon clipping operations: `difference2d`,
`union2d`, `intersect2d`, or `xor2d`.

The second and third arguments (`plus` and `minus`) accept the same forms as the
corresponding clipping operation: a `GeometryEntity` or array of `GeometryEntity`, a
`GeometryStructure` or `GeometryReference` (whose flattened elements are used), or a pair
`geom => layer` selecting only elements in those layers from the flattened structure.

Curve-bearing entities have their curves tracked through discretization and recovered in
the result: `CurvilinearPolygon`, `CurvilinearRegion`, `Path` nodes (e.g. `Turn`/`BSpline`
segments rendered with a `Style`), and `Rounded`-styled `Polygon`/`Rectangle`. All other
entities are discretized via `to_polygons`.

## Keyword arguments

`report` may be a `Vector` that will be filled with `(status, curve, contour_index)` tuples
tracking recovery results. `status` is `:recovered` if the curve's entire discretized run
survived the boolean operation intact, or `:clipped` if it was cut and fell back to a
polyline. `contour_index` is the 1-based index of the output contour where the curve was
recovered, or `0` for `:clipped` curves.

## Return type

Returns `Vector{CurvilinearRegion}` (one region per outer contour). This differs from
`difference2d` and similar functions, which return a single `ClippedPolygon`. Callers
migrating from `difference2d(a, b)` to `recover_curves(difference2d, a, b)` must handle a
vector result.

## Limitations

**All-or-nothing recovery:** A curve is recovered only if its entire discretized run (the
sequence of integer-grid vertices produced by `discretize_curve`) survives the boolean
operation with exact integer equality. If the operation cuts through a curve, that curve is
reported `:clipped` and falls back to a polyline. Partial-curve recovery is not supported.

Additionally, curves can only be recovered on CurvilinearRegion/CurvilinearPolygon,
Path nodes, and `Rounded`-styled `Polygon`/`Rectangle` entities. `Rounded` applied to
other entities, styled Curvilinear entities, and nested styles do not yet support curve recovery.

See also [`difference2d`](@ref), [`union2d`](@ref), [`intersect2d`](@ref), [`xor2d`](@ref),
[`difference2d_curved`](@ref), [`union2d_curved`](@ref), [`intersect2d_curved`](@ref),
[`xor2d_curved`](@ref).
"""
function recover_curves(op, plus, minus; report=nothing)
    R = _recover_coordtype(plus, minus)
    pp, runs_p = discretize_with_provenance(_as_entities(plus), R)
    pm, runs_m = discretize_with_provenance(_as_entities(minus), R)
    # Annotate the result so a wrong `op` (not one of difference2d/union2d/intersect2d/
    # xor2d) fails here with a clear TypeError rather than deep inside substitute_curves.
    clipped = op(pp, pm)::ClippedPolygon
    return substitute_curves(clipped, vcat(runs_p, runs_m); report=report)
end

"""
    difference2d_curved(plus, minus; report=nothing)

Curve-preserving variant of [`difference2d`](@ref), returning `Vector{CurvilinearRegion}`.
See [`recover_curves`](@ref).
"""
difference2d_curved(p, m; kwargs...) = recover_curves(difference2d, p, m; kwargs...)
"""
    union2d_curved(p1, p2; report=nothing)
    union2d_curved(p; report=nothing)

Curve-preserving variant of [`union2d`](@ref), returning `Vector{CurvilinearRegion}`.
The single-argument form self-unions `p` (equivalent to `union2d_curved(p, [])`), which is
useful for merging a collection of overlapping curved entities into one region per piece.
See [`recover_curves`](@ref).
"""
union2d_curved(p, m; kwargs...) = recover_curves(union2d, p, m; kwargs...)
union2d_curved(p; kwargs...) = recover_curves(union2d, p, []; kwargs...)

"""
    intersect2d_curved(p1, p2; report=nothing)

Curve-preserving variant of [`intersect2d`](@ref), returning `Vector{CurvilinearRegion}`.
See [`recover_curves`](@ref).
"""
intersect2d_curved(p, m; kwargs...) = recover_curves(intersect2d, p, m; kwargs...)
"""
    xor2d_curved(p1, p2; report=nothing)

Curve-preserving variant of [`xor2d`](@ref), returning `Vector{CurvilinearRegion}`.
See [`recover_curves`](@ref).
"""
xor2d_curved(p, m; kwargs...) = recover_curves(xor2d, p, m; kwargs...)
