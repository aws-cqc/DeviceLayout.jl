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
    # Walk in ascending start-index order — must match to_polygons(::CurvilinearPolygon) exactly
    # so the Clipper polygon and these provenance runs share the same point ordering. See the
    # note there: an out-of-order (e.g. wrap-seam-first) curve list otherwise emits the wrong
    # `ec.p[i:csi]` spans and a sub-µm near-pinch.
    order =
        issorted(ec.curve_start_idx) ? eachindex(ec.curve_start_idx) :
        sortperm(ec.curve_start_idx)
    for idx in order
        csi = ec.curve_start_idx[idx]
        c = ec.curves[idx]
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

# Count, in already-clipperized integer space, runs of short edges that fit a circle — a cheap
# proxy for "this discretized polygon CONTAINS curve geometry we are about to lose". Used only to
# warn on the silent-discretization path below; not exact, just enough to flag a likely loss.
function _count_arclike_runs(pts; short_nm=6000.0, min_run=4, resid_nm=2.0)
    n = length(pts)
    n < min_run + 1 && return 0
    xy = [
        (
            Float64(DeviceLayout.ustrip(getx(p))) / 1000,
            Float64(DeviceLayout.ustrip(gety(p))) / 1000
        ) for p in pts
    ]  # → ~nm scale-agnostic
    # edge lengths in the same units as xy
    el = [
        hypot(xy[mod1(i + 1, n)][1] - xy[i][1], xy[mod1(i + 1, n)][2] - xy[i][2]) for
        i = 1:n
    ]
    short = short_nm / 1000
    cnt = 0
    i = 1
    while i <= n
        if !(0 < el[i] < short)
            i += 1
            continue
        end
        j = i
        while j < n && 0 < el[mod1(j + 1, n)] < short
            j += 1
        end
        rl = j - i + 1
        if rl >= min_run
            vx = [xy[mod1(i + k, n)][1] for k = 0:rl]
            vy = [xy[mod1(i + k, n)][2] for k = 0:rl]
            m = length(vx)
            sx = sum(vx)
            sy = sum(vy)
            sxx = sum(vx .^ 2)
            syy = sum(vy .^ 2)
            sxy = sum(vx .* vy)
            sxxx = sum(vx .^ 3)
            syyy = sum(vy .^ 3)
            sxyy = sum(vx .* vy .^ 2)
            sxxy = sum(vx .^ 2 .* vy)
            A = m * sxx - sx^2
            B = m * sxy - sx * sy
            Cc = m * syy - sy^2
            D = 0.5 * (m * sxxx + m * sxyy - sx * sxx - sx * syy)
            E = 0.5 * (m * syyy + m * sxxy - sy * syy - sy * sxx)
            den = A * Cc - B^2
            if abs(den) > 1e-12
                cx = (D * Cc - B * E) / den
                cy = (A * E - B * D) / den
                r = sqrt(max(0.0, (sxx + syy - 2cx * sx - 2cy * sy) / m + cx^2 + cy^2))
                if 1e-3 < r < 1e5
                    mr = maximum(abs(hypot(vx[k] - cx, vy[k] - cy) - r) for k = 1:m)
                    mr < resid_nm / 1000 && (cnt += 1)
                end
            end
        end
        i = j + 1
    end
    return cnt
end

# Module-level switch for the silent-discretization warning (default ON; set false to silence).
const warn_on_curve_loss = Ref(true)
# Track per-(entity-type) loss counts so a run can report which entity classes lost curves.
const _curve_loss_log = Dict{String, Int}()
curve_loss_log() = _curve_loss_log
reset_curve_loss_log!() = empty!(_curve_loss_log)

# Any other entity: no curves to recover; discretize to polygons. THIS is the silent-loss path —
# a curve-bearing entity whose (type, style) combination has no `_as_entities`/`_collect_provenance!`
# method falls here and is discretized to polyline with NO provenance, so its curves can never be
# recovered downstream. We detect the likely-loss case (the discretized polygon contains short-edge
# runs that fit a circle) and warn once per entity type, and tally it in `_curve_loss_log`, so such
# losses are observable instead of silent. (Plain rectilinear polygons fit nothing → no warning.)
function _collect_provenance!(polys, runs, e, ::Type{R}, atol) where {R}
    # Convert to polygons and append. to_polygons returns a polygon or array.
    poly_result = DeviceLayout.to_polygons(e)
    polylist = poly_result isa Polygon ? (poly_result,) : poly_result
    arclike = 0
    for poly in polylist
        push!(polys, convert(Polygon{R}, poly))
        warn_on_curve_loss[] && (arclike += _count_arclike_runs(points(poly)))
    end
    if warn_on_curve_loss[] && arclike > 0
        key = string(nameof(typeof(e)))
        e isa StyledEntity && (
            key =
                "Styled{" *
                string(nameof(typeof(e.ent))) *
                "," *
                string(nameof(typeof(e.sty))) *
                "}"
        )
        first_seen = !haskey(_curve_loss_log, key)
        _curve_loss_log[key] = get(_curve_loss_log, key, 0) + arclike
        first_seen &&
            @warn "recover_curves: discretizing a curve-bearing entity with no provenance — its arcs are LOST. " *
                  "Add an _as_entities method for this (type, style) to recover them." entity_type =
                key arclike_runs = arclike
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

# Find ALL maximal contiguous sub-blocks of `run` that exist in `contour` (treated as cyclic),
# considering forward and reversed orientations. Returns a Vector of named-tuples
# `(contour_start, run_lo, run_hi, reversed)` where:
#   - `contour_start` is the 1-based start position in the contour
#   - `run_lo`, `run_hi` are 1-based inclusive indices into `run` (or `reverse(run)` if reversed)
#   - `reversed::Bool` indicates orientation
# Each returned block has length ≥ `min_len` (default 3 — meaningful sub-arc, not a single edge).
# Sub-blocks that are subsumed by a larger block at the same contour position are dropped.
#
# Used by `substitute_curves` for partial recovery: when a curve is "genuinely cut" by a
# boolean operation (e.g. a Turn arc bisected by another polygon's edge), the run survives
# as multiple disjoint contiguous sub-blocks. Each sub-block becomes a sub-curve via the
# original segment's `Paths.split` interface.
function match_run_partial(
    contour::AbstractVector{P},
    run::AbstractVector{P};
    min_len::Int=3
) where {P}
    n = length(contour)
    m = length(run)
    (m == 0 || n == 0) && return NamedTuple{
        (:contour_start, :run_lo, :run_hi, :reversed),
        Tuple{Int, Int, Int, Bool}
    }[]
    # Build a position lookup: for each run point value, what indices in run have that value?
    # Run is short (typically 50-200 points for an arc), contour can be longer; this trades a
    # bit of memory for fast search.
    run_pos = Dict{P, Vector{Int}}()
    for (i, v) in enumerate(run)
        push!(get!(run_pos, v, Int[]), i)
    end
    rev_run = reverse(run)
    rev_pos = Dict{P, Vector{Int}}()
    for (i, v) in enumerate(rev_run)
        push!(get!(rev_pos, v, Int[]), i)
    end

    matches = NamedTuple{
        (:contour_start, :run_lo, :run_hi, :reversed),
        Tuple{Int, Int, Int, Bool}
    }[]

    # Try to extend a contiguous run-match starting at contour position s, run position r0,
    # in the given orientation. Returns the longest extension length k such that
    # contour[s..s+k-1] == run[r0..r0+k-1] (orientation-respecting).
    extend_match(s::Int, r0::Int, src::AbstractVector{P}) = begin
        m_local = length(src)
        k = 0
        while r0 + k <= m_local && contour[mod1(s + k, n)] == src[r0 + k]
            k += 1
        end
        k
    end

    for orient in (false, true)
        src = orient ? rev_run : run
        pos_lookup = orient ? rev_pos : run_pos
        s = 1
        while s <= n
            cv = contour[s]
            candidates = get(pos_lookup, cv, nothing)
            if candidates === nothing
                s += 1
                continue
            end
            best_k = 0
            best_r0 = 0
            for r0 in candidates
                k = extend_match(s, r0, src)
                if k > best_k
                    best_k = k
                    best_r0 = r0
                end
            end
            if best_k >= min_len
                run_lo = orient ? (m + 1 - (best_r0 + best_k - 1)) : best_r0
                run_hi = orient ? (m + 1 - best_r0) : (best_r0 + best_k - 1)
                push!(
                    matches,
                    (contour_start=s, run_lo=run_lo, run_hi=run_hi, reversed=orient)
                )
                s += best_k                # skip the matched block; no overlap
            else
                s += 1
            end
        end
    end

    # Drop entries that are subsumed by a longer entry covering the same contour range.
    # Sort by length descending; keep an entry only if no kept entry already covers its
    # contour_start..contour_start+(hi-lo).
    isempty(matches) && return matches
    by_len = sort(matches; by=t -> -(t.run_hi - t.run_lo + 1))
    kept = empty(by_len)
    for t in by_len
        len = t.run_hi - t.run_lo + 1
        overlap = false
        for kt in kept
            klen = kt.run_hi - kt.run_lo + 1
            # Check cyclic overlap of [t.contour_start, t.contour_start+len-1]
            # with [kt.contour_start, kt.contour_start+klen-1].
            for i = 0:(len - 1)
                pos = mod1(t.contour_start + i, n)
                # Is pos inside kt's span?
                for j = 0:(klen - 1)
                    if mod1(kt.contour_start + j, n) == pos
                        overlap = true
                        break
                    end
                end
                overlap && break
            end
            overlap && break
        end
        overlap || push!(kept, t)
    end
    return kept
end

# Given a curve and a sub-run [run_lo, run_hi] of its full discretization (length m),
# return the corresponding sub-segment (the same kind of curve restricted to the
# parametric range `t ∈ [(run_lo-1)/(m-1), (run_hi-1)/(m-1)] * pathlength(curve)`).
# Reversed sub-runs return a reversed sub-segment.
function _sub_curve(curve::Paths.Segment, m::Int, run_lo::Int, run_hi::Int, reversed::Bool)
    pl = Paths.pathlength(curve)
    t_lo = (run_lo - 1) / (m - 1) * pl
    t_hi = (run_hi - 1) / (m - 1) * pl
    # Take three-way split: pre, middle (the surviving sub-arc), post
    if t_lo > zero(pl)
        _, rest = Paths.split(curve, t_lo)
    else
        rest = curve
    end
    mid_len = t_hi - t_lo
    if mid_len < Paths.pathlength(rest)
        mid, _ = Paths.split(rest, mid_len)
    else
        mid = rest
    end
    return reversed ? Paths.reverse(mid) : mid
end

# Walk a ClippedPolygon's PolyNode tree, substituting known curves back into each contour
# wherever a ProvenanceRun's discretized integer-grid point-run survived a boolean op intact.
# Returns Vector{CurvilinearRegion{T}}: one region per outer contour (its direct children are
# holes; grandchildren start new regions), mirroring to_primitives(::SolidModel, ::ClippedPolygon).
#
# Each run matches at most once globally — `used` is shared across all contours.
# `report`, if given, collects (status::Symbol, curve, contour_index) tuples with
# status ∈ (:recovered, :clipped); :clipped runs (never matched) carry contour_index 0.
# When true, `substitute_curves` falls back to longest-contiguous-substring matching
# for curves whose full run was cut by another polygon's edge — recovering each surviving
# sub-block as a sub-segment via `Paths.split`, instead of dropping the whole curve to polyline.
const substitute_curves_partial = Ref(false)

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
            if !isnothing(hit)
                seg = hit.reversed ? reverse(pr.curve) : pr.curve
                push!(matched, (hit.start, length(pr.run), seg))
                used[ri] = true
                !isnothing(report) && push!(report, (:recovered, pr.curve, ci))
                continue
            end
            # Partial recovery: the full run didn't match (curve was cut by a boolean edge).
            # Try longest-contiguous-substring matching: each surviving sub-block of the
            # original run becomes a sub-segment of the original curve via Paths.split.
            substitute_curves_partial[] || continue
            partial_matches = match_run_partial(snapped, pr.run; min_len=3)
            isempty(partial_matches) && continue
            m_full = length(pr.run)
            for pm in partial_matches
                sub_len = pm.run_hi - pm.run_lo + 1
                # sub_len includes both endpoints; the contour occupies sub_len positions.
                sub_seg = _sub_curve(pr.curve, m_full, pm.run_lo, pm.run_hi, pm.reversed)
                push!(matched, (pm.contour_start, sub_len, sub_seg))
            end
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
    # Paths.-qualified: ContinuousStyle is defined in the Paths submodule but is NOT in scope
    # unqualified inside Curvilinear (a bare `ContinuousStyle` throws UndefVarError on the L1
    # zero-length-node path). Qualifying is robust and needs no import.
    iszero(pathlength(p.seg)) && p.sty isa Paths.ContinuousStyle && return []
    return _as_entities(pathtopolys(p.seg, p.sty)) # Use `islinear` dispatch on segment and style
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
# A Rounded- or StyleDict{Rounded}-styled ClippedPolygon (e.g. the output of a non-curved
# `difference2d`/`union2d` followed by post-clip rounding) recovers as exact fillet arcs
# per contour, so its corners survive the clip instead of discretizing. The render
# path already does this conversion (`to_curvilinear_regions` walks the clipped tree, applying
# `styled_loop`+`round_to_curvilinearpolygon` per contour → CurvilinearRegions with arcs); we
# reuse that exact function so boolean recovery matches the render. `SolidModels` loads after
# this file, but `_as_entities` only runs at boolean time (all modules loaded), so the qualified
# name resolves at call time. Returns a Vector{CurvilinearRegion}; `_as_entities(::AbstractArray)`
# flattens it, and `_collect_provenance!(::CurvilinearRegion)` records each contour's curve runs.
function _as_entities(p::StyledEntity{T, ClippedPolygon{T}, <:Polygons.StyleDict}) where {T}
    return DeviceLayout.SolidModels.to_curvilinear_regions(p.ent, p.sty)
end
function _as_entities(p::StyledEntity{T, ClippedPolygon{T}, <:Polygons.Rounded}) where {T}
    return DeviceLayout.SolidModels.to_curvilinear_regions(p.ent, Polygons.StyleDict(p.sty))
end
# A geometrically-transparent style (e.g. MeshSized — a mesh-density hint applied via
# `to_polygons(ent, ::MeshSized) = to_polygons(ent)`) must NOT block curve recovery: a
# MeshSized-wrapped Node / Rounded-Polygon / CurvilinearPolygon carries the same curves as
# the bare entity. Without this, such a wrapped entity falls to the generic
# `_as_entities(::GeometryEntity) = [p]` and is discretized by `to_polygons`, silently losing
# its arcs through the boolean. Recurse to the inner entity (mirrors the render-side default
# `to_primitives(::SolidModel, ::StyledEntity) = to_primitives(sm, ent.ent)`). The specific
# Rounded / ClippedPolygon methods above are more specific and still win.
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
