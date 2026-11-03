# GeomLaws — shared definitions for the property-based geometry laws.
#
# Supposition.jl generators, exact lattice predicates, and the region comparisons used
# by the laws in test/laws/. Generators do not call the clipping kernel, and laws
# compare regions rather than vertex order. This file is included by the `LawsSetup`
# testsnippet and by the differential harness in test/laws/differential/, so it must
# not depend on TestItemRunner; it expects `Supposition`, `Data`, `Random`, `Test`,
# `Unitful`, `Clipper`, `DeviceLayout`, and `Polygons` to be in scope.

# ---------------------------------------------------------------------------------
# Budget. PR runs use a fixed seed and a small example count so they are deterministic
# and take a few minutes. The scheduled exploration workflow (`explore.jl`) raises
# GEOMLAWS_EXAMPLES and draws a fresh seed per run.
# ---------------------------------------------------------------------------------
const GEOMLAWS_EXAMPLES = parse(Int, get(ENV, "GEOMLAWS_EXAMPLES", "50"))
const GEOMLAWS_SEED = let s = get(ENV, "GEOMLAWS_SEED", "20260908")
    s == "random" ? rand(UInt32) : parse(UInt32, s)
end
# Database recording of failing examples is handled by graduation into fixed
# testitems instead; keep the test directory clean.
const LAWS = Supposition.CheckConfig(;
    rng=Random.Xoshiro(GEOMLAWS_SEED),
    max_examples=GEOMLAWS_EXAMPLES,
    db=false
)

# Supposition caps attempts as well as valid examples. A search that exhausts
# its attempts without covering the requested budget is not a passing law.
budget_satisfied(report) = Supposition.num_testcases(report) >= report.config.max_examples
function check_budget(report)
    if Supposition.results(report).ispass
        valid = Supposition.num_testcases(report)
        calls = something(report.final_state).calls
        @testset "$(report.description): $valid valid / $calls attempts" begin
            @test budget_satisfied(report)
        end
    end
    return report
end
# `rng` must be passed to `@check` explicitly: `SuppositionReport` defaults it to a
# fresh `RandomDevice` seed and merges that over `config`, so `LAWS.rng` alone would be
# ignored and every run would be randomly seeded. `TestState` copies the RNG per check.
macro lawcheck(def)
    return esc(:(check_budget(@check config = LAWS rng = LAWS.rng $def)))
end

# Laws known to fail on the current kernel, keyed by law id and generator family.
# A generative check for a known-broken law is skipped (recorded as Broken) rather
# than run with `broken=true`: the failure is probabilistic, so `broken=true` would
# itself be flaky at PR budget. The deterministic reproducer lives in
# test_ledger.jl; when the kernel changes, remove the entry here and see whether the
# law now holds. `GEOMLAWS_RUN_BROKEN=1` runs them anyway, which is how a candidate
# kernel's status on each ledgered law is recorded.
const KNOWN_BROKEN =
    get(ENV, "GEOMLAWS_RUN_BROKEN", "0") == "1" ? Set{Symbol}() :
    Set([
        :B3_int_thin,   # L1: thin integer polygons vanish under identity ops
        :B8_int,        # L3: integer output may self-cross after rounding
        :B8_nested,     # L4: a hole vertex may land outside its parent after rounding
        :B8_float_perturbed,  # L8: fm-scale self-crossing from a ≤ 2 fm feature
        :B11_multi,     # L14: a cut next to another hole's cut can cross it unwarned
        :O1_int_thin,   # L1 again, through offset's internal union
        :O3_int_sharp,  # L7: small offsets leave the input vertex in place at sharp corners
        :O7_taper,      # L12 (#8): taper halos are short of δ at the sides, long at the ends
        :O7_inner       # L13 (#8): halos with an inner offset are open at path ends
    ])
macro law(id, check)
    return quote
        if $(esc(id)) in KNOWN_BROKEN
            @test_broken false
        else
            $(esc(check))
        end
    end
end

# ---------------------------------------------------------------------------------
# Exact geometry on the kernel lattice.
#
# `clipperize` feeds integer coordinates to Clipper unchanged and prescales floats to
# a 1 fm lattice (`Polygons.SCALE`), so the kernel's rounding step depends on the
# coordinate type. `togrid` maps onto that same lattice, so exact predicates below
# see exactly what the kernel saw, and tolerances are expressed in lattice units.
# ---------------------------------------------------------------------------------
const GridPt = Tuple{Int128, Int128}
const GridRegion = Vector{Vector{GridPt}}

_gridcoord(x::Integer) = Int128(x)
_gridcoord(x::AbstractFloat) = round(Int128, x * Polygons.SCALE)
_gridcoord(x::Unitful.Quantity{<:Integer}) = Int128(Unitful.ustrip(x))
_gridcoord(x::Unitful.Quantity{<:AbstractFloat}) =
    round(Int128, Unitful.ustrip(Unitful.unit(Polygons.USCALE), x))
togrid(p::Point) = (_gridcoord(getx(p)), _gridcoord(gety(p)))
togrid(p::Polygon) = togrid.(p.p)
togrid(ps::AbstractVector{<:Polygon}) = togrid.(ps)
# A ClippedPolygon is compared through its tree contours, not through
# `to_polygons`, so that the keyhole-cut step is tested separately (law B11).
togrid(cp::ClippedPolygon) =
    Vector{GridPt}[togrid.(Clipper.contour(n)) for n in tree_nodes(cp)]
togrid(g::GridRegion) = g
togrid(cps::AbstractVector{<:ClippedPolygon}) =
    reduce(vcat, togrid.(cps); init=Vector{GridPt}[])

contour_polygons(cp::ClippedPolygon{T}) where {T} =
    [Polygon{T}(Clipper.contour(n)) for n in tree_nodes(cp)]

function tree_nodes(cp::ClippedPolygon)
    out = Clipper.PolyNode[]
    walk(n) =
        for c in Clipper.children(n)
            push!(out, c)
            walk(c)
        end
    walk(cp.tree)
    return out
end

# Twice the signed area of triangle (a, b, c); positive for counterclockwise.
orient_exact(a::GridPt, b::GridPt, c::GridPt) =
    sign((b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1]))

function on_segment_exact(q::GridPt, a::GridPt, b::GridPt)
    orient_exact(a, b, q) == 0 || return false
    return min(a[1], b[1]) <= q[1] <= max(a[1], b[1]) &&
           min(a[2], b[2]) <= q[2] <= max(a[2], b[2])
end

# Closed segments; touching counts as intersecting.
function segments_intersect_exact(a::GridPt, b::GridPt, c::GridPt, d::GridPt)
    o1 = orient_exact(a, b, c)
    o2 = orient_exact(a, b, d)
    o3 = orient_exact(c, d, a)
    o4 = orient_exact(c, d, b)
    (o1 != o2 && o3 != o4) && return true
    o1 == 0 && on_segment_exact(c, a, b) && return true
    o2 == 0 && on_segment_exact(d, a, b) && return true
    o3 == 0 && on_segment_exact(a, c, d) && return true
    o4 == 0 && on_segment_exact(b, c, d) && return true
    return false
end

signed_area2_exact(v::Vector{GridPt}) = sum(
    v[i][1] * v[mod1(i + 1, end)][2] - v[mod1(i + 1, end)][1] * v[i][2] for
    i in eachindex(v)
)
area_exact(v::Vector{GridPt}) = abs(signed_area2_exact(v)) // 2
# Signed area of a contour list under the even-odd rule the tree encodes: outer
# contours are counterclockwise and holes clockwise, so the signed sum is the region
# area. Used for the area laws, where it must not pass through `to_polygons`.
region_area_exact(polys::GridRegion) =
    sum(signed_area2_exact(v) for v in polys; init=Int128(0)) // 2

# Squared distance from q to segment ab compared against tol², exactly. The cross
# product fits Int128 at the generated coordinate ranges (≤ 1e11 lattice units); its
# square does not, so the final comparison is done in BigInt.
function within_segment_distance_exact(q::GridPt, a::GridPt, b::GridPt, tol::Integer)
    tol >= 0 || return false
    dx, dy = b[1] - a[1], b[2] - a[2]
    len2 = dx * dx + dy * dy
    qx, qy = q[1] - a[1], q[2] - a[2]
    if len2 == 0
        return qx * qx + qy * qy <= Int128(tol)^2
    end
    dot = qx * dx + qy * dy
    if dot <= 0
        return qx * qx + qy * qy <= Int128(tol)^2
    elseif dot >= len2
        rx, ry = q[1] - b[1], q[2] - b[2]
        return rx * rx + ry * ry <= Int128(tol)^2
    end
    cross = qx * dy - qy * dx
    return BigInt(cross)^2 <= BigInt(tol)^2 * BigInt(len2)
end
function within_boundary_distance_exact(q::GridPt, polys::GridRegion, tol::Integer)
    for v in polys, i in eachindex(v)
        within_segment_distance_exact(q, v[i], v[mod1(i + 1, end)], tol) && return true
    end
    return false
end

# A polygon is simple when it has ≥3 vertices, no repeated consecutive vertices,
# nonzero area, and no two non-adjacent edges touch. O(n²); fine for n ≲ 200.
# `weak=true` relaxes "touch" to "properly cross": vertices may touch other vertices
# or edges (pinch points) and edges may overlap collinearly (a zero-width bridge
# traversed in both directions, as in a keyhole cut). Clipper permits both in its
# output unless run in strictly-simple mode, and both still describe the region
# unambiguously under the even-odd and positive fill rules; a proper crossing does
# not.
function is_simple_exact(v::Vector{GridPt}; weak=false)
    n = length(v)
    n >= 3 || return false
    any(i -> v[i] == v[mod1(i + 1, n)], 1:n) && return false
    signed_area2_exact(v) == 0 && return false
    for i = 1:n
        a, b = v[i], v[mod1(i + 1, n)]
        for j = (i + 2):n
            # Skip the edge adjacent to edge i (wraps for i == 1).
            (i == 1 && j == n) && continue
            c, d = v[j], v[mod1(j + 1, n)]
            if weak
                segments_cross_exact(a, b, c, d) && return false
            else
                segments_intersect_exact(a, b, c, d) && return false
            end
        end
    end
    return true
end

# Proper crossing: the segments' interiors meet at a single point. Excludes
# touching at endpoints, an endpoint lying on the other segment, and collinear
# overlap.
function segments_cross_exact(a::GridPt, b::GridPt, c::GridPt, d::GridPt)
    o1 = orient_exact(a, b, c)
    o2 = orient_exact(a, b, d)
    o3 = orient_exact(c, d, a)
    o4 = orient_exact(c, d, b)
    return o1 * o2 < 0 && o3 * o4 < 0
end

# Ray-crossing test; points on the boundary return `missing` so callers can
# exclude them rather than guess.
function point_in_polygon_exact(q::GridPt, v::Vector{GridPt})
    n = length(v)
    inside = false
    for i = 1:n
        a, b = v[i], v[mod1(i + 1, n)]
        on_segment_exact(q, a, b) && return missing
        if (a[2] > q[2]) != (b[2] > q[2])
            # Exact comparison of q.x against the crossing x-coordinate, via cross
            # product to avoid division.
            o = orient_exact(a, b, q)
            if (b[2] > a[2] ? o : -o) > 0
                inside = !inside
            end
        end
    end
    return inside
end

# Region membership for a set of contours under the even-odd rule. This is the
# right rule both for a ClippedPolygon tree (outer/hole contours nest and
# alternate) and for the keyhole polygons `to_polygons` produces from it.
function point_in_region_exact(q::GridPt, polys::GridRegion)
    inside = false
    for v in polys
        r = point_in_polygon_exact(q, v)
        ismissing(r) && return missing
        inside ⊻= r
    end
    return inside
end

# ---------------------------------------------------------------------------------
# Region comparisons.
#
# `≐` compares canonical contours. `region_same` also accepts equivalent regions
# represented by different contour decompositions, using an exact rational sweep.
# `region_within(X, Y, tol)` certifies that every region disagreement lies within
# `tol` of either boundary. Thin slivers may disappear, but equal total areas or
# matching samples alone never establish equality. The bounded certificate can be
# inconclusive; that is a non-pass, not a rejected generator example.
# `region_subset_within` applies the same certificate to X ∖ Y only.
# Tolerances are stated per law in lattice units.
# ---------------------------------------------------------------------------------
function dedupe_contour(v::Vector{GridPt})
    v = [p for (i, p) in enumerate(v) if i == 1 || p != v[i - 1]]
    length(v) > 1 && first(v) == last(v) && pop!(v)
    return v
end
function strip_collinear(v::Vector{GridPt})
    v = dedupe_contour(v)
    n = length(v)
    n < 3 && return v
    return [
        v[i] for i = 1:n if !on_segment_exact(v[i], v[mod1(i - 1, n)], v[mod1(i + 1, n)])
    ]
end

function canonical_contour(v::Vector{GridPt})
    v = strip_collinear(v)
    isempty(v) && return v
    signed_area2_exact(v) < 0 && reverse!(v)
    _, i = findmin(v)
    return circshift(v, 1 - i)
end

canonical_region(polys::GridRegion) = sort!(filter!(!isempty, canonical_contour.(polys)))

function region_equal(X::GridRegion, Y::GridRegion)
    canonical_region(X) == canonical_region(Y) && return (true, nothing)
    return (false, :canonical_mismatch)
end
region_equal(X, Y) = region_equal(togrid(X), togrid(Y))

≐(X, Y) = first(region_equal(X, Y))

# Distance from q to the boundary of a polygon set, in lattice units. Float64 is
# sufficient for choosing diagnostic probes at the generated coordinate ranges.
function _dist_point_segment(q::GridPt, a::GridPt, b::GridPt)
    ax, ay = Float64(a[1]), Float64(a[2])
    dx, dy = Float64(b[1] - a[1]), Float64(b[2] - a[2])
    qx, qy = Float64(q[1]) - ax, Float64(q[2]) - ay
    len2 = dx * dx + dy * dy
    t = len2 == 0 ? 0.0 : clamp((qx * dx + qy * dy) / len2, 0.0, 1.0)
    return hypot(qx - t * dx, qy - t * dy)
end
function boundary_distance(q::GridPt, polys::GridRegion)
    d = Inf
    for v in polys, i in eachindex(v)
        d = min(d, _dist_point_segment(q, v[i], v[mod1(i + 1, end)]))
    end
    return d
end
near_boundary(q, δ, regions...) = any(r -> boundary_distance(q, r) < δ, regions)
perimeter_exact(v::Vector{GridPt}) = sum(
    hypot(
        Float64(v[i][1] - v[mod1(i + 1, end)][1]),
        Float64(v[i][2] - v[mod1(i + 1, end)][2])
    ) for i in eachindex(v);
    init=0.0
)
perimeter_exact(polys::GridRegion) = sum(perimeter_exact, polys; init=0.0)

# Probe points for membership votes: uniform over the joint bounding box, plus
# points around every vertex and on both sides of every edge midpoint of every
# region at one and three times `step` (which callers set just above the band).
function sample_points(polys::GridRegion...; n=256, step=1, seed=GEOMLAWS_SEED)
    allpts = reduce(vcat, reduce(vcat, p; init=GridPt[]) for p in polys; init=GridPt[])
    isempty(allpts) && return GridPt[]
    xs, ys = first.(allpts), last.(allpts)
    lo = (minimum(xs) - step, minimum(ys) - step)
    hi = (maximum(xs) + step, maximum(ys) + step)
    rng = Random.Xoshiro(seed)
    pts = GridPt[]
    for _ = 1:n
        push!(pts, (rand(rng, lo[1]:hi[1]), rand(rng, lo[2]:hi[2])))
    end
    dirs = ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1))
    for region in polys, v in region, i in eachindex(v)
        a, b = v[i], v[mod1(i + 1, end)]
        m = ((a[1] + b[1]) ÷ 2, (a[2] + b[2]) ÷ 2)
        for k in (1, 3), d in dirs
            push!(pts, (a[1] + k * step * d[1], a[2] + k * step * d[2]))
            push!(pts, (m[1] + k * step * d[1], m[2] + k * step * d[2]))
        end
    end
    return pts
end

# Laws never run on outputs this large: boundary arrangements are O(n²), and an
# output this size from a ≤ 24-vertex input is itself a finding (see the round-join
# note in test_offset.jl).
const MAX_VERTICES = 4000
nvertices(polys::GridRegion) = sum(length, polys; init=0)

include("region_oracle.jl")

function comparison_result(result)
    if !first(result) && Test.get_testset() isa Supposition.SuppositionReport
        event!("region certificate", last(result))
    end
    return result
end
region_within(X, Y, tol; kwargs...) =
    comparison_result(region_certificate(togrid(X), togrid(Y), tol; kwargs...))
region_subset_within(X, Y, tol; kwargs...) =
    comparison_result(region_certificate(togrid(X), togrid(Y), tol; subset=true, kwargs...))
region_same(X, Y) = first(region_within(X, Y, 0))
# Output validity (law B8): every contour simple; tree alternates outer/hole; every
# hole vertex lies inside or on its parent contour (`nested=true`).
# Strict simplicity is a known-broken law on Clipper1 (see test/laws/test_ledger.jl), so
# the default checks weak simplicity.
function valid_output(cp::ClippedPolygon; weak=true, nested=false)
    function walk(node, expect_hole)
        parent = togrid.(Clipper.contour(node))
        for c in Clipper.children(node)
            Clipper.ishole(c) == expect_hole || return false
            g = togrid.(Clipper.contour(c))
            is_simple_exact(g; weak) || return false
            (signed_area2_exact(g) < 0) == expect_hole || return false
            if nested && !isempty(parent)
                contour_contained(g, parent) || return false
            end
            walk(c, !expect_hole) || return false
        end
        return true
    end
    return walk(cp.tree, false)
end

# Keyhole polygons are weakly simple (each cut is traversed in both directions),
# counterclockwise, and free of zero-length edges, including at cut endpoints.
function valid_keyholes(out::GridRegion)
    for v in out
        for i in eachindex(v)
            v[i] == v[mod1(i + 1, end)] && return false
        end
        is_simple_exact(v; weak=true) && signed_area2_exact(v) > 0 || return false
    end
    return true
end

# Keyhole polygons of a tree, and whether `to_polygons` warned while cutting them.
# `interiorcuts` warns when rounding a cut's attachment point to the lattice may make the
# keyhole polygon self-intersect, so invalid output is acceptable only with a warning.
# A flagged cut can also make a later hole of the same contour fail to attach (ledger
# L15), and the error comes before the warning is emitted. That error is accepted as the
# warning would be, giving `(nothing, true)`; any other error is rethrown.
function keyholes_warned(cp::ClippedPolygon)
    r = _keyholes_or_unattached(cp)
    isnothing(r) || return r
    failed = filter(
        !isnothing,
        map(_unattached_after_warning, filter(!Clipper.ishole, tree_nodes(cp)))
    )
    !isempty(failed) && all(failed) || return _keyholes_logged(cp)
    return nothing, true
end
function _keyholes_logged(cp::ClippedPolygon)
    logs, out = Test.collect_test_logs(; min_level=Base.CoreLogging.Warn) do
        return togrid(to_polygons(cp))
    end
    return out, !isempty(logs)
end
# `nothing` if `to_polygons` throws for a hole it cannot attach.
function _keyholes_or_unattached(cp::ClippedPolygon)
    try
        return _keyholes_logged(cp)
    catch e
        e isa ErrorException && occursin("could not be attached", e.msg) || rethrow()
        return nothing
    end
end
# `nothing` if contour `E` and its holes are cut, else whether the hole that fails to
# attach follows a warned cut. `interiorcuts` cuts each contour's holes in order of their
# lowest vertex, each cut depending only on the holes before it, so cutting those holes
# alone reproduces the warning that the error preempted.
function _unattached_after_warning(E::Clipper.PolyNode)
    holes = sort(Clipper.children(E); by=h -> minimum(gety, Clipper.contour(h)))
    for m in eachindex(holes)
        isnothing(_keyholes_or_unattached(_contour_with_holes(E, holes[1:m]))) || continue
        return m > 1 && last(_keyholes_logged(_contour_with_holes(E, holes[1:(m - 1)])))
    end
    return nothing
end
function _contour_with_holes(E::N, holes) where {N <: Clipper.PolyNode}
    function node(n, parent)
        c = N(Clipper.contour(n), Clipper.ishole(n), false)
        c.parent = parent
        c.children = N[]
        return c
    end
    root = N(empty(Clipper.contour(E)), false, false)
    root.parent = root
    e = node(E, root)
    e.children = [node(h, e) for h in holes]
    root.children = [e]
    return ClippedPolygon(root)
end

# Exact point-to-region distance oracle for the offset laws: 0 inside, else the
# distance to the boundary, compared against δ ± tol without floating point.
# Returns :in, :out, or :band; :band means possibly within `tol` of the exact offset
# boundary. A point of A is at least δ + dist(q, ∂A) from the boundary of a positive
# offset, so when δ ≤ tol the band reaches into A (and symmetrically out of A for
# erosion).
function offset_class(q::GridPt, A::GridRegion, δ::Integer, tol::Integer)
    inside = point_in_region_exact(q, A)
    if δ >= 0
        if ismissing(inside) || inside
            δ <= tol && within_boundary_distance_exact(q, A, tol - δ) && return :band
            return :in
        end
        within_boundary_distance_exact(q, A, δ - tol) && return :in
        within_boundary_distance_exact(q, A, δ + tol) && return :band
        return :out
    else
        if ismissing(inside) || !inside
            -δ <= tol && within_boundary_distance_exact(q, A, tol + δ) && return :band
            return :out
        end
        within_boundary_distance_exact(q, A, -δ - tol) && return :out
        within_boundary_distance_exact(q, A, -δ + tol) && return :band
        return :in
    end
end

# Membership oracle for the four boolean operations (law B7): at probes off every
# boundary, membership in each result must equal the Boolean combination of
# memberships in the operands, which are contour lists read under the even-odd rule
# (for a valid tree, the same region as the positive rule the operations use). The
# right-hand side never touches the clipping kernel. Examples where no probe lands
# inside both operands are rejected rather than passed.
function boolean_oracle_holds(As::Vector{<:Polygon}, Bs::Vector{<:Polygon}; tol=1)
    gA, gB = togrid(As), togrid(Bs)
    results = (
        (togrid(union2d(As, Bs)), |),
        (togrid(intersect2d(As, Bs)), &),
        (togrid(difference2d(As, Bs)), (a, b) -> a & !b),
        (togrid(xor2d(As, Bs)), ⊻)
    )
    saw_a = saw_b = false
    for q in sample_points(gA, gB, first.(results)...; step=tol + 1)
        near_boundary(q, tol, gA, gB, first.(results)...) && continue
        a = point_in_region_exact(q, gA)
        b = point_in_region_exact(q, gB)
        (ismissing(a) || ismissing(b)) && continue
        saw_a |= a
        saw_b |= b
        for (g, op) in results
            r = point_in_region_exact(q, g)
            ismissing(r) && continue
            op(a, b) == r || return false
        end
    end
    (saw_a && saw_b) || reject!()
    return true
end

# Round joins discretize arcs into chords inside the true arc. Float laws pass
# `atol = |δ| / 200`, which keeps the arc error small next to the features at every
# scale and the chords few enough for exact comparisons.
# `arc_lattice_tol` is the error bound in lattice units: Clipper1 rounds each corner's
# number of chords to the nearest integer (at least one), so a chord can span up to 1.5
# times the angle `atol` implies, and its sagitta reach 2.25 atol.
round_atol(δ) = abs(δ) / 200
arc_lattice_tol(atol::AbstractFloat) = ceil(Int, 2.25 * Float64(_gridcoord(atol)))

# ---------------------------------------------------------------------------------
# Generators.
#
# Simple polygons are produced by construction (star-shaped around a center) and
# then validated exactly. Anything that fails validation is rejected via `reject!`,
# and `@lawcheck` enforces the valid-example budget, so generator starvation is a
# test failure rather than a silent reduction of coverage.
# ---------------------------------------------------------------------------------
const GRID_HALF = 20  # integer polygons live on [-20, 20]²: degeneracy-rich, and
# since the kernel's lattice for integers is 1 unit, its intersection rounding is
# exercised at full strength

function make_polygon(pts::Vector{<:Point})
    # Drop repeated consecutive vertices, including the closing duplicate.
    out = eltype(pts)[]
    for p in pts
        (isempty(out) || p != out[end]) && push!(out, p)
    end
    length(out) > 1 && out[1] == out[end] && pop!(out)
    # DL's clipping uses the positive fill rule, under which a clockwise contour is a
    # hole (`Polygons.ishole`). Generated operands are therefore always
    # counterclockwise; orientation-sensitive behavior gets its own laws.
    length(out) >= 3 && signed_area2_exact(togrid.(out)) < 0 && reverse!(out)
    return Polygon(out)
end

# Star-shaped polygon: vertices sorted by angle about the origin at random radii.
# Star-shaped ⇒ simple, provided no two vertices are collinear with the center at
# the same angle (validated afterward).
function star_polygon(
    ::Type{T},
    angles::Vector{Float64},
    radii::Vector{Float64},
    scale
) where {T}
    pts = [
        Point(T(round(r * cos(θ) * scale)), T(round(r * sin(θ) * scale))) for
        (θ, r) in zip(sort(angles), radii)
    ]
    return make_polygon(pts)
end

rectangle_polygon(w::Int, h::Int) = make_polygon(Point{Int}[(0, 0), (w, 0), (w, h), (0, h)])

# Rectilinear staircase polygon: a rectangle whose top edge is a skyline of `k`
# steps. Simple by construction; collinear duplicates are stripped by `make_polygon`
# only when consecutive, so flat steps leave collinear vertices in place — a
# degeneracy worth keeping. On the integer lattice every intersection of two
# rectilinear polygons is a lattice point, so the boolean laws hold exactly here.
function staircase_polygon(w::Int, xs::Vector{Int}, hs::Vector{Int})
    pts = Point{Int}[(0, 0), (w, 0)]
    xprev = w
    for (x, h) in zip(xs, hs)
        push!(pts, Point(xprev, h))
        push!(pts, Point(x, h))
        xprev = x
    end
    pts[end] == Point(0, hs[end]) || push!(pts, Point(0, hs[end]))
    return make_polygon(pts)
end
int_rectilinear_polygon = @composed function _int_rectilinear(
    w=Data.Integers(3, 2GRID_HALF),
    nsteps=Data.Integers(0, 5),
    breaks=Data.Vectors(Data.Integers(1, 2GRID_HALF - 1); min_size=5, max_size=5),
    hs=Data.Vectors(Data.Integers(1, 2GRID_HALF); min_size=6, max_size=6)
)
    xs = sort(unique(filter(x -> x < w, breaks[1:nsteps])); rev=true)
    push!(xs, 0)
    hs = hs[1:min(length(hs), length(xs))]
    # Adjacent equal heights collapse into one step, which is fine.
    xs = xs[1:length(hs)]
    xs[end] = 0
    p = staircase_polygon(w, xs, hs)
    valid_polygon(p) || reject!()
    return p
end

function valid_polygon(p::Polygon)
    g = togrid(p)
    return length(g) >= 3 && is_simple_exact(g) && signed_area2_exact(g) > 0
end

# Smallest distance from a vertex to a non-adjacent edge, in lattice units. On the
# integer lattice, features thinner than one unit are at the mercy of the kernel's
# intersection rounding (ledger L1), so laws that must hold exactly are stated for
# "thick" polygons and the thin ones are ledgered separately.
function min_thickness(g::Vector{GridPt})
    n = length(g)
    d = Inf
    for i = 1:n, j = 1:n
        (j == i || mod1(j + 1, n) == i) && continue
        d = min(d, _dist_point_segment(g[i], g[j], g[mod1(j + 1, n)]))
    end
    return d
end
const THICK = 1.5
is_thick(p::Polygon, t=THICK) = min_thickness(togrid(p)) >= t

# Smallest |sin| of the turn angle over all vertices: near zero both at a spike and
# at a nearly straight vertex. Clipper's offset misplaces a vertex when
# |δ|·sin(turn) is below a lattice unit (ledger L7), so offset laws that compose
# operations are stated away from that regime.
function min_turn_sine(p::Polygon)
    g = togrid(p)
    n = length(g)
    smin = 1.0
    for i = 1:n
        a, b, c = g[mod1(i - 1, n)], g[i], g[mod1(i + 1, n)]
        u = (Float64(b[1] - a[1]), Float64(b[2] - a[2]))
        v = (Float64(c[1] - b[1]), Float64(c[2] - b[2]))
        smin = min(smin, abs(u[1] * v[2] - u[2] * v[1]) / (hypot(u...) * hypot(v...)))
    end
    return smin
end
function lattice_delta(::Polygon{T}, δ) where {T}
    S = promote_type(T, typeof(δ))
    return Unitful.ustrip(Polygons.prescaledelta(convert(S, δ)))
end
well_conditioned_offset(p::Polygon, δ) = abs(lattice_delta(p, δ)) * min_turn_sine(p) >= 1

# Shortest edge, in lattice units. An edge of length L whose endpoints are rounded
# by half a unit has its direction wrong by ~1/(2L); offsetting it by δ moves the
# intersections at its ends by ~|δ|/(2L). Laws that offset an offset result
# therefore carry the tolerance `offset_tol` below instead of a fixed 2; at L = 1
# (ledger L9) that tolerance is |δ| and the law says nothing, which is the truth.
function min_edge_length(polys::GridRegion)
    d = Inf
    for v in polys, i in eachindex(v)
        a, b = v[i], v[mod1(i + 1, end)]
        d = min(d, hypot(Float64(b[1] - a[1]), Float64(b[2] - a[2])))
    end
    return d
end
min_edge_length(x) = min_edge_length(togrid(x))
offset_tol(first_result, δ) =
    2 + ceil(Int, Float64(abs(_gridcoord(δ))) / (2 * min_edge_length(first_result)))
# Drop vertices closer than `tol` lattice units to their predecessor.
function strip_short_edges(pts::Vector{<:Point}; tol=4)
    g = togrid.(pts)
    keep = [
        i for i in eachindex(pts) if hypot(
            Float64(g[i][1] - g[mod1(i - 1, end)][1]),
            Float64(g[i][2] - g[mod1(i - 1, end)][2])
        ) >= tol
    ]
    return pts[keep]
end

# Smallest interior angle, for laws that depend on the miter limit.
function min_corner_angle(p::Polygon)
    g = togrid(p)
    n = length(g)
    θmin = Float64(π)
    for i = 1:n
        a, b, c = g[mod1(i - 1, n)], g[i], g[mod1(i + 1, n)]
        u = (Float64(a[1] - b[1]), Float64(a[2] - b[2]))
        v = (Float64(c[1] - b[1]), Float64(c[2] - b[2]))
        cosθ = (u[1] * v[1] + u[2] * v[2]) / (hypot(u...) * hypot(v...))
        θmin = min(θmin, acos(clamp(cosθ, -1.0, 1.0)))
    end
    return θmin
end

# Star polygon parameters. The vertex count is drawn on its own: the shorter of two
# independently sized vectors, at the sizes Supposition favors with small budgets, is
# usually 3, and triangles are convex. Angles, radii, and other continuous parameters
# are drawn on integer grids, not with `Data.Floats`, which draws bit patterns: about a
# quarter of its draws on [0, 2π] land within 1e-3 of zero, piling vertices onto the
# +x axis.
const gen_nverts = Data.Integers(3, 12)
const gen_angles = map(
    v -> 2π .* v ./ 3600,
    Data.Vectors(Data.Integers(0, 3599); min_size=12, max_size=12)
)
const gen_radii =
    map(v -> v ./ 100, Data.Vectors(Data.Integers(20, 100); min_size=12, max_size=12))
# Fraction in [lo, hi] at a resolution of 0.01.
grid_fraction(lo, hi) =
    map(i -> i / 100, Data.Integers(round(Int, 100lo), round(Int, 100hi)))
const gen_turn = map(k -> 2π * k / 3600, Data.Integers(0, 3599))

"""
    int_star_polygon = @composed ...

Integer-coordinate star polygon on [-GRID_HALF, GRID_HALF]². Vertices are rounded to
the grid, so small polygons frequently gain collinear triples and repeated
vertices — exactly the degeneracies clipping must handle.
"""
int_star_polygon = @composed function _int_star(n=gen_nverts, θ=gen_angles, r=gen_radii)
    p = star_polygon(Int, θ[1:n], r[1:n], GRID_HALF)
    valid_polygon(p) || reject!()
    return p
end

int_thick_star_polygon =
    @composed function _int_thick_star(n=gen_nverts, θ=gen_angles, r=gen_radii)
        p = star_polygon(Int, θ[1:n], r[1:n], GRID_HALF)
        (valid_polygon(p) && is_thick(p)) || reject!()
        return p
    end

# Float coordinates spanning nm to 100 μm feature scales. Vertices are rounded to
# 1e-3 of the scale so they land on a coarse grid (cheap collinearity) while the
# kernel still rounds their fm images; the cap at 1e2 keeps lattice coordinates
# below ~1e11 so the exact predicates stay in Int128.
float_star_polygon = @composed function _float_star(
    n=gen_nverts,
    θ=gen_angles,
    r=gen_radii,
    logscale=Data.Integers(-3, 2)
)
    scale = 10.0^logscale
    pts = [
        Point(
            round(rr * cos(tt) * scale; digits=3 - logscale),
            round(rr * sin(tt) * scale; digits=3 - logscale)
        ) for (tt, rr) in zip(sort(θ[1:n]), r[1:n])
    ]
    p = make_polygon(pts)
    valid_polygon(p) || reject!()
    return p
end

int_convex_polygon = @composed function _int_convex(
    n=Data.Integers(3, 12),
    radius=Data.Integers(5, GRID_HALF),
    θ=gen_turn
)
    p = make_polygon([
        Point(
            round(Int, radius * cos(θ + 2π * i / n)),
            round(Int, radius * sin(θ + 2π * i / n))
        ) for i = 1:n
    ])
    is_convex_exact(togrid(p)) || reject!()
    return p
end

int_rectangle_polygon = @composed function _int_rectangle(
    w=Data.Integers(3, 2GRID_HALF),
    h=Data.Integers(3, 2GRID_HALF)
)
    return rectangle_polygon(w, h)
end

# Rectangles keep the miter-law angle precondition well represented at every
# float scale; unconstrained float stars alone starve that conditional law.
float_rectangle_polygon = @composed function _float_rectangle(
    A=int_rectangle_polygon,
    logscale=Data.Integers(-3, 2)
)
    return Polygon(Point{Float64}.(A.p) .* (10.0^logscale / (2GRID_HALF)))
end

int_polygon = int_star_polygon | int_rectangle_polygon
int_thick_polygon = int_thick_star_polygon | int_rectangle_polygon
float_polygon = float_star_polygon

"""
    degenerate_pair

A rectangle `A` and a partner `B` that is translated (overlapping through disjoint),
edge-sharing, vertex-touching, collinear-vertex-equivalent, or a one-unit-wide sliver.
Each case is guaranteed by construction.
"""
function degenerate_pair_polygons(w, h, kind, k)
    A = rectangle_polygon(w, h)
    B = if kind == 1
        A + Point(k, 0)
    elseif kind == 2
        A + Point(w, 0)
    elseif kind == 3
        A + Point(w, h)
    elseif kind == 4
        split = Point(1 + mod(k, w - 1), 0)
        make_polygon(vcat(A.p[1:1], [split], A.p[2:end]))
    else
        make_polygon(Point{Int}[(0, 0), (0, -1), (w, -1), (w, 0)])
    end
    return (A, B)
end

degenerate_pair = @composed function _degenerate_pair(
    w=Data.Integers(3, 2GRID_HALF),
    h=Data.Integers(3, 2GRID_HALF),
    kind=Data.Integers(1, 5),
    k=Data.Integers(0, 2GRID_HALF)
)
    return degenerate_pair_polygons(w, h, kind, k)
end

# Two star polygons, the second translated by up to half the grid so the pair ranges
# from identical through heavily overlapping to disjoint.
int_star_pair = @composed function _int_star_pair(
    A=int_thick_polygon,
    B=int_thick_polygon,
    dx=Data.Integers(-GRID_HALF ÷ 2, GRID_HALF ÷ 2),
    dy=Data.Integers(-GRID_HALF ÷ 2, GRID_HALF ÷ 2)
)
    return (A, B + Point(dx, dy))
end
int_pair = int_star_pair | degenerate_pair

int_rectilinear_pair = @composed function _int_rectilinear_pair(
    A=int_rectilinear_polygon,
    B=int_rectilinear_polygon,
    dx=Data.Integers(-GRID_HALF, GRID_HALF),
    dy=Data.Integers(-GRID_HALF, GRID_HALF)
)
    return (A, B + Point(dx, dy))
end
int_rectilinear_triple = @composed function _int_rectilinear_triple(
    pair=int_rectilinear_pair,
    C=int_rectilinear_polygon,
    dx=Data.Integers(-GRID_HALF, GRID_HALF),
    dy=Data.Integers(-GRID_HALF, GRID_HALF)
)
    return (pair..., C + Point(dx, dy))
end

# Float pairs: independent stars at the same scale (`float_star_pair`), or `B`
# derived from `A` by moving one vertex `kfm` lattice units or attaching a
# `kfm`-wide sliver along an edge (`float_perturbed_pair`, which also returns
# `kfm`). Near-coincident edges meeting at an angle of order kfm/length make every
# intersection ill-conditioned by geometry — rounding an endpoint by half a unit
# moves the intersection along the edge by up to half the edge length — so laws on
# perturbed pairs are stated within `kfm + 2` rather than within 1 or 2.
function _fm_offset(A::Polygon{Float64}, i, kfm)
    return A.p[mod1(i, length(A.p))] + Point(kfm / Polygons.SCALE, 0.0)
end
float_star_pair = @composed function _float_star_pair(
    A=float_star_polygon,
    m=gen_nverts,
    r=gen_radii,
    θ=gen_angles,
    shift=grid_fraction(-0.5, 0.5)
)
    scale = maximum(p -> max(abs(p.x), abs(p.y)), A.p)
    pts = [
        Point(rr * cos(tt), rr * sin(tt)) * scale for (tt, rr) in zip(sort(θ[1:m]), r[1:m])
    ]
    B = make_polygon(pts) + Point(shift * scale, shift * scale)
    valid_polygon(B) || reject!()
    return (A, B)
end
float_perturbed_pair = @composed function _float_perturbed_pair(
    A=float_star_polygon,
    kind=Data.Integers(1, 2),
    i=Data.Integers(1, 12),
    kfm=Data.Integers(1, 10)
)
    n = length(A.p)
    idx = mod1(i, n)
    B = if kind == 1
        pts = copy(A.p)
        pts[idx] = _fm_offset(A, idx, kfm)
        make_polygon(pts)
    else
        a, c = A.p[idx], A.p[mod1(idx + 1, n)]
        d = c - a
        nrm = Point(-d.y, d.x) / hypot(d.x, d.y) * (kfm / Polygons.SCALE)
        make_polygon([a, c, c + nrm, a + nrm])
    end
    valid_polygon(B) || reject!()
    return (A, B, kfm)
end

# A float star pair moved to where layouts live: up to 1 cm from the origin, about
# 1e13 lattice units, where Float64 resolves only about 2 fm. The exact predicates stay
# exact in Int128 up to about 1e18 lattice units.
float_far_pair = @composed function _float_far_pair(
    pair=float_star_pair,
    x=Data.Integers(-10, 10),
    y=Data.Integers(-10, 10)
)
    A, B = pair
    d = Point(1000.0x, 1000.0y)
    return (A + d, B + d)
end

int_triple = @composed function _int_triple(
    pair=int_star_pair,
    C=int_thick_polygon,
    dx=Data.Integers(-GRID_HALF ÷ 2, GRID_HALF ÷ 2),
    dy=Data.Integers(-GRID_HALF ÷ 2, GRID_HALF ÷ 2)
)
    return (pair..., C + Point(dx, dy))
end
float_triple = @composed function _float_triple(pair=float_star_pair, other=float_star_pair)
    A, B = pair
    C, _ = other
    scale = maximum(p -> max(abs(p.x), abs(p.y)), A.p)
    cscale = maximum(p -> max(abs(p.x), abs(p.y)), C.p)
    return (A, B, Polygon(C.p .* (scale / cscale)))
end

# A set of several polygons spread over a region several times the polygon size,
# for the tiled and identity laws.
int_polygon_set = @composed function _int_polygon_set(
    polys=Data.Vectors(int_thick_polygon; min_size=2, max_size=6),
    offsets=Data.Vectors(Data.Integers(-2GRID_HALF, 2GRID_HALF); min_size=12, max_size=12)
)
    return [p + Point(offsets[2i - 1], offsets[2i]) for (i, p) in enumerate(polys)]
end
# Float version at unit scale: `clip_tiled` builds its tiles in Float64, so integer
# inputs would be promoted and the comparison would cross lattices.
float_polygon_set = @composed function _float_polygon_set(set=int_polygon_set)
    return [Polygon(Point{Float64}.(p.p)) for p in set]
end

# Rectilinear shapes whose offsets change topology, which convex stars and rectangles
# never do. A dumbbell (two lobes joined by a neck `neck` wide) splits under erosion
# by more than `neck / 2`; a box with an internal cavity reached through a mouth
# `mouth` wide encloses a hole once grown by more than `mouth / 2`. Each returns the
# shape and that width, so laws can draw δ around the threshold. `scale` keeps the
# lattice tolerance small relative to the features.
int_necked_polygon = @composed function _int_necked(
    w1=Data.Integers(4, 16),
    h1=Data.Integers(4, 20),
    w2=Data.Integers(4, 16),
    h2=Data.Integers(4, 20),
    len=Data.Integers(1, 10),
    neck=Data.Integers(1, 8),
    y0=Data.Integers(0, 16),
    b=Data.Integers(0, 20),
    scale=Data.Integers(1, 4)
)
    (y0 + neck <= h1 && neck <= h2) || reject!()
    # Lobe 2 spans the neck's height: its bottom lies in [y0 + neck - h2, y0].
    yb = y0 + neck - h2 + mod(b, h2 - neck + 1)
    x2, x3 = w1 + len, w1 + len + w2
    pts = Point{Int}[
        (0, 0),
        (w1, 0),
        (w1, y0),
        (x2, y0),
        (x2, yb),
        (x3, yb),
        (x3, yb + h2),
        (x2, yb + h2),
        (x2, y0 + neck),
        (w1, y0 + neck),
        (w1, h1),
        (0, h1)
    ]
    p = make_polygon(pts .* scale)
    valid_polygon(p) || reject!()
    return (p, neck * scale)
end
int_cavity_polygon = @composed function _int_cavity(
    mouth_length=Data.Integers(1, 8),
    cw=Data.Integers(2, 20),
    ch=Data.Integers(3, 20),
    wall=Data.Vectors(Data.Integers(1, 8); min_size=3, max_size=3),
    mouth=Data.Integers(1, 8),
    at=Data.Integers(0, 20),
    scale=Data.Integers(1, 4)
)
    ch >= mouth + 2 || reject!()
    cx0, cx1 = mouth_length, mouth_length + cw
    cy0, cy1 = wall[1], wall[1] + ch
    my = cy0 + 1 + mod(at, ch - mouth - 1)
    W, H = cx1 + wall[2], cy1 + wall[3]
    pts = Point{Int}[
        (0, 0),
        (W, 0),
        (W, H),
        (0, H),
        (0, my + mouth),
        (cx0, my + mouth),
        (cx0, cy1),
        (cx1, cy1),
        (cx1, cy0),
        (cx0, cy0),
        (cx0, my),
        (0, my)
    ]
    p = make_polygon(pts .* scale)
    valid_polygon(p) || reject!()
    return (p, mouth * scale)
end

# A polygon with holes, built directly as a ClippedPolygon tree. `islands[i]` lists
# polygons inside `holes[i]`. Outer and island contours are counterclockwise and holes
# clockwise, as Clipper returns them. Exercises `to_polygons`' keyhole cutting on trees
# of known validity.
function holed_tree(
    outer::Polygon{Int},
    holes::Vector{Polygon{Int}},
    islands=[Polygon{Int}[] for _ in holes]
)
    function node(pts, ishole, parent)
        n = Clipper.PolyNode{Point{Int}}(pts, ishole, false)
        n.parent = parent
        n.children = Clipper.PolyNode{Point{Int}}[]
        return n
    end
    root = Clipper.PolyNode{Point{Int}}(Point{Int}[], false, false)
    root.parent = root
    o = node(outer.p, false, root)
    o.children = map(zip(holes, islands)) do (h, is)
        hn = node(reverse(h.p), true, o)
        hn.children = [node(i.p, false, hn) for i in is]
        return hn
    end
    root.children = [o]
    return ClippedPolygon(root)
end
# A star and a copy scaled toward the center (star-shaped about the origin ⇒ the copy
# is strictly inside).
int_holed_polygon = @composed function _int_holed(
    n=gen_nverts,
    θ=gen_angles,
    r=gen_radii,
    shrink=grid_fraction(0.2, 0.6)
)
    big = 5GRID_HALF
    outer = star_polygon(Int, θ[1:n], r[1:n], big)
    hole = star_polygon(Int, θ[1:n], r[1:n], big * shrink)
    (valid_polygon(outer) && valid_polygon(hole)) || reject!()
    contour_contained(togrid(hole), togrid(outer); strict=true) || reject!()
    return holed_tree(outer, [hole])
end

# Several holes, some with islands. Each hole is a star in its own cell of a
# `rows × cols` grid, so holes are disjoint by construction and need not resemble
# the outer contour. Holes stacked in a column make the keyhole ray from an upper hole
# meet the hole below it, holes in one row tie for lowest vertex, and the outer
# contour's zigzag bottom edge puts the lowest cuts on non-axis-aligned edges.
const HOLE_CELL = 24
hole_shape = @composed function _hole_shape(
    n=gen_nverts,
    θ=gen_angles,
    r=gen_radii,
    island=Data.Booleans()
)
    return (θ[1:n], r[1:n], island)
end
int_multi_holed_polygon = @composed function _int_multi_holed(
    rows=Data.Integers(2, 3),
    cols=Data.Integers(1, 2),
    shapes=Data.Vectors(hole_shape; min_size=6, max_size=6),
    present=Data.Vectors(Data.Booleans(); min_size=6, max_size=6),
    zig=Data.Vectors(Data.Integers(2, 8); min_size=5, max_size=5)
)
    W, H = cols * HOLE_CELL, rows * HOLE_CELL
    bottom = [Point(round(Int, W * i / 6), -zig[i]) for i = 1:5]
    outer =
        make_polygon(vcat([Point(0, 0)], bottom, Point{Int}[(W, 0), (W, H), (0, H)]))
    holes, islands = Polygon{Int}[], Vector{Polygon{Int}}[]
    for i = 1:rows, j = 1:cols
        k = (i - 1) * cols + j
        (k <= 2 || present[k]) || continue
        θ, r, island = shapes[k]
        c = Point(round(Int, (j - 0.5) * HOLE_CELL), round(Int, (i - 0.5) * HOLE_CELL))
        hole = star_polygon(Int, θ, r, HOLE_CELL ÷ 2 - 2) + c
        valid_polygon(hole) || reject!()
        push!(holes, hole)
        inner = star_polygon(Int, θ, r, 0.4 * (HOLE_CELL ÷ 2 - 2)) + c
        keep =
            island &&
            valid_polygon(inner) &&
            contour_contained(togrid(inner), togrid(hole); strict=true)
        push!(islands, keep ? [inner] : Polygon{Int}[])
    end
    return holed_tree(outer, holes, islands)
end

# Rigid transformations only: magnification is out of scope for equivariance laws.
rigid_transform = @composed function _rigid(
    dx=Data.Integers(-GRID_HALF, GRID_HALF),
    dy=Data.Integers(-GRID_HALF, GRID_HALF),
    quarter_turns=Data.Integers(0, 3),
    reflect=Data.Booleans()
)
    t = Translation(Point(dx, dy)) ∘ Rotation(quarter_turns * π / 2)
    return reflect ? t ∘ XReflection() : t
end
# Integer-exact rigid transforms: quarter turns and reflections keep integer
# coordinates integer, so the law can be stated exactly.
function apply_exact(t, p::Polygon{Int})
    return Polygon(Point{Int}[Point(round(Int, q.x), round(Int, q.y)) for q in t(p).p])
end

# Lengths: fixed unit choices for the unit-invariance law. The nm/μm/mm images of
# one integer polygon are exactly representable, and `clipperize` maps all three to
# the same fm lattice.
const UNIT_CHOICES = (Unitful.nm, Unitful.μm, Unitful.mm)
with_unit(p::Polygon{Int}, u) = Polygon([
    Point(
        Unitful.uconvert(u, float(q.x) * Unitful.μm),
        Unitful.uconvert(u, float(q.y) * Unitful.μm)
    ) for q in p.p
])

# Paths for the halo laws: one to three straight or turning segments of one style, in
# μm on a coarse grid, each returned with its footprint (the same segments as a trace
# of the full width), which is what a halo offsets. The tangent stays within 90° of the
# start direction, so the centerline never crosses itself: a path that overlapped
# itself could bury an end, and the halo's square end extension would then reach past
# every offset of the footprint. Turn radii exceed the halo's half-width: on a tighter
# turn a trace's inner edge collapses to the turn's center, and the halo's collapses
# there too instead of reaching δ past it. The footprint carries a 1 nm straight lead
# at each end so that its miter offset has the true end corners, rather than corners
# turned by the first chord of an arc. `δi` is an inner offset in (0, δ).
path_case = @composed function _path_case(
    nseg=Data.Integers(1, 3),
    turn=Data.Vectors(Data.Integers(-6, 6); min_size=3, max_size=3),
    len=Data.Vectors(Data.Integers(1, 20); min_size=3, max_size=3),
    slack=Data.Vectors(Data.Integers(1, 20); min_size=3, max_size=3),
    w=Data.Integers(1, 10),
    gap=Data.Integers(0, 5),
    δ=Data.SampledFrom([0.5, 1.0, 2.0, 5.0]),
    inner=grid_fraction(0.1, 0.9)
)
    all(k -> abs(sum(turn[1:k])) <= 6, 1:nseg) || reject!()
    halfwidth = w / 2 + gap
    sty, fpsty = if gap == 0
        Paths.Trace(Float64(w)), Paths.Trace(Float64(w))
    else
        Paths.CPW(Float64(w), Float64(gap)), Paths.Trace(2halfwidth)
    end
    function build(s, lead)
        p = Path(Point(0.0, 0.0))
        lead > 0 && straight!(p, lead, s)
        for i = 1:nseg
            if turn[i] == 0
                straight!(p, Float64(len[i]), s)
            else
                turn!(p, turn[i] * π / 12, halfwidth + δ + slack[i], s)
            end
        end
        lead > 0 && straight!(p, lead, s)
        return p
    end
    return (build(sty, 0.0), build(fpsty, 0.001), δ, inner * δ)
end
# A straight taper between two widths, which is its own footprint.
taper_case = @composed function _taper_case(
    w=Data.Vectors(Data.Integers(1, 10); min_size=2, max_size=2),
    len=Data.Integers(1, 20),
    δ=Data.SampledFrom([0.5, 1.0, 2.0, 5.0])
)
    w[1] == w[2] && reject!()
    pa = Path(Point(0.0, 0.0))
    straight!(pa, Float64(len), Paths.TaperTrace(Float64(w[1]), Float64(w[2])))
    return (pa, pa, δ)
end
# Path geometry is discretized to `HALO_ATOL` (10 nm), and halo comparisons hold within
# three of those.
const HALO_ATOL = 0.01
const HALO_TOL = 3 * _gridcoord(HALO_ATOL) + 2
path_polygons(pa) = reduce(
    vcat,
    [vcat(to_polygons(n; atol=HALO_ATOL)) for n in pa];
    init=Polygon{Float64}[]
)
path_region(pa) = union2d(path_polygons(pa))
# The halo of a path is documented as equivalent to offsetting its geometry by δ: it
# covers every point within δ of the footprint, decided exactly from the footprint, and
# nothing that the miter-join offset of the footprint leaves out, since a halo squares
# off path ends. Sampled like B7 and O3: an exact certificate between two discretized
# curves costs about a second per example.
function halo_is_offset(pa, fp, δ)
    gF = togrid(path_region(fp))
    gH = togrid(path_region(halo(pa, δ, nothing)))
    gM = togrid(offset(to_polygons(path_region(fp)), δ; j=Clipper.JoinTypeMiter))
    for q in sample_points(gF, gH, gM; step=HALO_TOL + 1)
        near_boundary(q, HALO_TOL, gH, gM) && continue
        h = point_in_region_exact(q, gH)
        ismissing(h) && continue
        !h && offset_class(q, gF, _gridcoord(δ), HALO_TOL) == :in && return false
        h && point_in_region_exact(q, gM) === false && return false
    end
    return true
end
# With an inner offset δi, the halo is the region between the two offsets.
function inner_halo_is_difference(pa, δ, δi)
    gX = togrid(path_region(halo(pa, δ, δi)))
    gO = togrid(path_region(halo(pa, δ, nothing)))
    gI = togrid(path_region(halo(pa, δi, nothing)))
    for q in sample_points(gX, gO, gI; step=HALO_TOL + 1)
        near_boundary(q, HALO_TOL, gX, gO, gI) && continue
        x, o, i = point_in_region_exact.(Ref(q), (gX, gO, gI))
        any(ismissing, (x, o, i)) && continue
        x == (o && !i) || return false
    end
    return true
end
