# GeomLaws — shared setup for property-based geometry laws.
#
# Provides Supposition.jl generators, exact (rational-arithmetic) predicates, and the
# region-equivalence check `≐` used by every law in test/laws/. Design rules that this
# file enforces (see the GeomLaws plan for rationale):
#
#   * Laws compare *regions*, never vertex lists: legitimate kernel differences (start
#     vertex, contour order, collinear-vertex stripping) must not fail a law.
#   * The oracle shares nothing with the clipping kernel: point-in-region, area, and
#     simplicity are computed exactly on the fm grid (`Polygons.SCALE`) with Rational/BigInt
#     arithmetic, so a disagreement is a kernel finding, not a tolerance artifact.
#   * Generated polygons are well-formed by construction *and* validated before use, so a
#     generator artifact can never masquerade as a kernel bug.

@testsnippet LawsSetup begin
    using Supposition
    using Supposition: Data
    using Random
    using DeviceLayout: Polygons

    # ---------------------------------------------------------------------------------
    # Budget. PR runs use a fixed seed and a small example count so they are deterministic
    # and fast; the nightly job raises GEOMLAWS_EXAMPLES and sets GEOMLAWS_SEED=random.
    # ---------------------------------------------------------------------------------
    const GEOMLAWS_EXAMPLES = parse(Int, get(ENV, "GEOMLAWS_EXAMPLES", "100"))
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

    # Laws known to fail on the current kernel, keyed by law id and generator family.
    # A generative check for a known-broken law is skipped (recorded as Broken) rather
    # than run with `broken=true`: the failure is probabilistic, so `broken=true` would
    # itself be flaky at PR budget. The deterministic reproducer lives in
    # test_ledger.jl; when the kernel changes, remove the entry here and see whether the
    # law now holds.
    const KNOWN_BROKEN = Set([:B8_int])  # ledger L3
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

    _gridcoord(x::Integer) = Int128(x)
    _gridcoord(x::AbstractFloat) = round(Int128, x * Polygons.SCALE)
    _gridcoord(x::Unitful.Quantity{<:Integer}) = Int128(Unitful.ustrip(x))
    _gridcoord(x::Unitful.Quantity{<:AbstractFloat}) =
        round(Int128, Unitful.ustrip(Polygons.USCALE, x))
    togrid(p::Point) = (_gridcoord(getx(p)), _gridcoord(gety(p)))
    togrid(p::Polygon) = togrid.(p.p)
    togrid(ps::AbstractVector{<:Polygon}) = togrid.(ps)
    togrid(cp::ClippedPolygon) = togrid(to_polygons(cp))

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

    # A polygon is simple when it has ≥3 vertices, no repeated consecutive vertices,
    # nonzero area, and no two non-adjacent edges touch. O(n²); fine for n ≲ 200.
    # `weak=true` relaxes "touch" to "cross or overlap": vertices may touch other
    # vertices or edges (pinch points), which Clipper permits in its output unless run
    # in strictly-simple mode.
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
                    segments_cross_or_overlap_exact(a, b, c, d) && return false
                else
                    segments_intersect_exact(a, b, c, d) && return false
                end
            end
        end
        return true
    end

    # Proper crossing (interiors meet at one point) or collinear overlap of positive
    # length. Excludes touching at endpoints and an endpoint lying on the other segment.
    function segments_cross_or_overlap_exact(a::GridPt, b::GridPt, c::GridPt, d::GridPt)
        o1 = orient_exact(a, b, c)
        o2 = orient_exact(a, b, d)
        o3 = orient_exact(c, d, a)
        o4 = orient_exact(c, d, b)
        (o1 * o2 < 0 && o3 * o4 < 0) && return true
        if o1 == 0 && o2 == 0
            # Collinear: overlap iff the projections share more than a point.
            k = a[1] == b[1] ? 2 : 1
            lo1, hi1 = minmax(a[k], b[k])
            lo2, hi2 = minmax(c[k], d[k])
            return min(hi1, hi2) > max(lo1, lo2)
        end
        return false
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

    # Region membership for a set of polygons under the even-odd rule. Every polygon
    # returned by `to_polygons(::ClippedPolygon)` is a simple polygon with holes cut
    # into keyholes, so the polygons are disjoint and even-odd equals union; the same
    # rule also handles the raw outer/hole contour list of a ClippedPolygon tree.
    function point_in_region_exact(q::GridPt, polys::Vector{Vector{GridPt}})
        inside = false
        for v in polys
            r = point_in_polygon_exact(q, v)
            ismissing(r) && return missing
            inside ⊻= r
        end
        return inside
    end

    # ---------------------------------------------------------------------------------
    # Region equivalence `≐`.
    #
    # Tier 1: canonical exact equality of the lattice representation (strip collinear
    #   vertices, normalize orientation and start vertex, sort contours).
    # Tier 2: sampled membership vote. Clipper rounds intersection vertices to the
    #   lattice, so each output boundary may sit up to ~√2/2 lattice units from the true
    #   boundary; sample points within `δ` lattice units of either region's boundary are
    #   excluded from the vote (default `δ = 2`, enough for one rounding step per
    #   operand). Features narrower than `2δ` are invisible to this tier by construction;
    #   the area laws (B5) are what bound those. Samples are drawn deterministically from
    #   the union bounding box plus points near every vertex of both regions, where
    #   clipping bugs concentrate.
    # Tier 3 (symmetric-difference area via the kernel under test) is deliberately not
    #   part of the verdict — it would be circular.
    # ---------------------------------------------------------------------------------
    const DEFAULT_δ = 2
    function strip_collinear(v::Vector{GridPt})
        n = length(v)
        n < 3 && return v
        out = GridPt[]
        for i = 1:n
            a, b, c = v[mod1(i - 1, n)], v[i], v[mod1(i + 1, n)]
            (b == a || orient_exact(a, b, c) == 0) && continue
            push!(out, b)
        end
        return out
    end

    function canonical_contour(v::Vector{GridPt})
        v = strip_collinear(v)
        isempty(v) && return v
        signed_area2_exact(v) < 0 && reverse!(v)
        _, i = findmin(v)
        return circshift(v, 1 - i)
    end

    canonical_region(polys::Vector{Vector{GridPt}}) =
        sort!(filter!(!isempty, canonical_contour.(polys)))

    # Distance from q to the boundary of a polygon set, in lattice units. Float64 is
    # adequate here: this only decides which sample points are *excluded*, never the
    # verdict, so a rounding error at the band edge is harmless.
    function _dist_point_segment(q::GridPt, a::GridPt, b::GridPt)
        ax, ay = Float64(a[1]), Float64(a[2])
        dx, dy = Float64(b[1] - a[1]), Float64(b[2] - a[2])
        qx, qy = Float64(q[1]) - ax, Float64(q[2]) - ay
        len2 = dx * dx + dy * dy
        t = len2 == 0 ? 0.0 : clamp((qx * dx + qy * dy) / len2, 0.0, 1.0)
        return hypot(qx - t * dx, qy - t * dy)
    end
    function boundary_distance(q::GridPt, polys::Vector{Vector{GridPt}})
        d = Inf
        for v in polys, i in eachindex(v)
            d = min(d, _dist_point_segment(q, v[i], v[mod1(i + 1, end)]))
        end
        return d
    end
    near_boundary(q, δ, regions...) = any(r -> boundary_distance(q, r) < δ, regions)

    function sample_points(polys::Vector{Vector{GridPt}}...; n=256, seed=GEOMLAWS_SEED)
        allpts = reduce(vcat, reduce(vcat, p; init=GridPt[]) for p in polys; init=GridPt[])
        isempty(allpts) && return GridPt[]
        xs, ys = first.(allpts), last.(allpts)
        lo = (minimum(xs) - 1, minimum(ys) - 1)
        hi = (maximum(xs) + 1, maximum(ys) + 1)
        rng = Random.Xoshiro(seed)
        pts = GridPt[]
        for _ = 1:n
            push!(pts, (rand(rng, lo[1]:hi[1]), rand(rng, lo[2]:hi[2])))
        end
        # Near-vertex probes at a few grid offsets.
        for p in allpts,
            d in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (2, 3), (-3, 2))

            push!(pts, (p[1] + d[1], p[2] + d[2]))
        end
        return pts
    end

    """
        region_equal(X, Y; δ=DEFAULT_δ, n=256) -> (equal::Bool, witness)

    Region equality of two polygon sets on the kernel lattice, ignoring points within `δ`
    lattice units of either boundary. `witness` is `nothing` on success or the first
    sample point where membership disagrees.
    """
    function region_equal(
        X::Vector{Vector{GridPt}},
        Y::Vector{Vector{GridPt}};
        δ=DEFAULT_δ,
        n=256
    )
        canonical_region(X) == canonical_region(Y) && return (true, nothing)
        for q in sample_points(X, Y; n)
            near_boundary(q, δ, X, Y) && continue
            a = point_in_region_exact(q, X)
            b = point_in_region_exact(q, Y)
            (ismissing(a) || ismissing(b)) && continue
            a == b || return (false, q)
        end
        return (true, nothing)
    end
    region_equal(X, Y; kwargs...) = region_equal(togrid(X), togrid(Y); kwargs...)

    ≐(X, Y) = first(region_equal(X, Y))

    # Region containment X ⊆ Y by sampled vote (points inside X must be inside Y).
    function region_subset(X, Y; δ=DEFAULT_δ, n=256)
        gX, gY = togrid(X), togrid(Y)
        for q in sample_points(gX, gY; n)
            near_boundary(q, δ, gX, gY) && continue
            a = point_in_region_exact(q, gX)
            b = point_in_region_exact(q, gY)
            (ismissing(a) || ismissing(b)) && continue
            (a && !b) && return (false, q)
        end
        return (true, nothing)
    end

    # Output validity (law B8): every contour simple; tree alternates outer/hole.
    # Strict simplicity is a known-broken law on Clipper1 (see test/laws/test_ledger.jl), so
    # the default checks weak simplicity.
    function valid_output(cp::ClippedPolygon; weak=true)
        function walk(node, expect_hole)
            for c in Clipper.children(node)
                Clipper.ishole(c) == expect_hole || return false
                is_simple_exact(togrid.(Clipper.contour(c)); weak) || return false
                walk(c, !expect_hole) || return false
            end
            return true
        end
        return walk(cp.tree, false)
    end

    # ---------------------------------------------------------------------------------
    # Generators.
    #
    # Simple polygons are produced by construction (star-shaped around a center) and
    # then validated exactly. Anything that fails validation is rejected via `reject!`,
    # and Supposition reports the rejection rate, so a leaky generator is visible rather
    # than silently distorting the input distribution.
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

    # Rectilinear polygon from a rectangle with random axis-aligned notches, on the grid.
    function notched_rectangle(w::Int, h::Int, notches::Vector{NTuple{3, Int}})
        # Start from a rectangle; each notch (side, offset, depth) cuts a unit-wide slot.
        r = Rectangle(Point(0, 0), Point(w, h))
        polys = union2d(to_polygons(r))
        for (side, off, depth) in notches
            slot = if side == 1
                Rectangle(Point(off, 0), Point(off + 1, depth))
            elseif side == 2
                Rectangle(Point(off, h - depth), Point(off + 1, h))
            elseif side == 3
                Rectangle(Point(0, off), Point(depth, off + 1))
            else
                Rectangle(Point(w - depth, off), Point(w, off + 1))
            end
            polys = difference2d(polys, to_polygons(slot))
        end
        ps = to_polygons(polys)
        return length(ps) == 1 ? ps[1] : nothing
    end

    function valid_polygon(p::Polygon)
        g = togrid(p)
        return length(g) >= 3 && is_simple_exact(g) && signed_area2_exact(g) > 0
    end

    # Integer star polygons.
    const gen_angles = Data.Vectors(
        Data.Floats{Float64}(; minimum=0.0, maximum=2π, nans=false, infs=false);
        min_size=3,
        max_size=12
    )
    const gen_radii = Data.Vectors(
        Data.Floats{Float64}(; minimum=0.2, maximum=1.0, nans=false, infs=false);
        min_size=3,
        max_size=12
    )

    """
        int_star_polygon = @composed ...

    Integer-coordinate star polygon on [-GRID_HALF, GRID_HALF]². Vertices are rounded to
    the grid, so small polygons frequently gain collinear triples and repeated
    vertices — exactly the degeneracies clipping must handle.
    """
    int_star_polygon = @composed function _int_star(θ=gen_angles, r=gen_radii)
        n = min(length(θ), length(r))
        p = star_polygon(Int, θ[1:n], r[1:n], GRID_HALF)
        valid_polygon(p) || reject!()
        return p
    end

    float_star_polygon = @composed function _float_star(
        θ=gen_angles,
        r=gen_radii,
        logscale=Data.Integers(-3, 3)
    )
        n = min(length(θ), length(r))
        scale = 10.0^logscale
        # Round to 1e-3 of the scale so vertices land on a coarse grid (cheap
        # collinearity) but still exercise float→fm rounding.
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

    notch = @composed function _notch(
        side=Data.Integers(1, 4),
        off=Data.Integers(1, 2GRID_HALF - 2),
        depth=Data.Integers(1, GRID_HALF ÷ 2)
    )
        return (side, off, depth)
    end

    int_rectilinear_polygon = @composed function _int_rectilinear(
        w=Data.Integers(3, 2GRID_HALF),
        h=Data.Integers(3, 2GRID_HALF),
        notches=Data.Vectors(notch; max_size=4)
    )
        ns = [
            (s, min(o, (s <= 2 ? w : h) - 2), min(d, (s <= 2 ? h : w) - 1)) for
            (s, o, d) in notches
        ]
        p = notched_rectangle(w, h, ns)
        (isnothing(p) || !valid_polygon(p)) && reject!()
        return p
    end

    int_polygon = int_star_polygon | int_rectilinear_polygon

    """
        degenerate_pair

    A polygon `A` and a partner `B` derived from it so that the pair shares structure
    the kernel finds hard: overlap, shared edge, touch at a vertex, collinear split,
    or a one-unit sliver along an edge.
    """
    degenerate_pair = @composed function _degenerate_pair(
        A=int_polygon,
        kind=Data.Integers(1, 5),
        k=Data.Integers(0, 2GRID_HALF),
        i=Data.Integers(1, 64)
    )
        n = length(A.p)
        idx = mod1(i, n)
        B = if kind == 1
            A + Point(k, 0)                    # overlap / disjoint by offset
        elseif kind == 2
            b = bounds(A)
            A + Point(width(b), 0)             # shared vertical edge (bbox-touching)
        elseif kind == 3
            b = bounds(A)
            A + Point(width(b), height(b))     # touch at a corner region
        elseif kind == 4
            # Insert a collinear midpoint on edge idx, then translate by one unit.
            a, c = A.p[idx], A.p[mod1(idx + 1, n)]
            m = Point((a.x + c.x) ÷ 2, (a.y + c.y) ÷ 2)
            make_polygon(vcat(A.p[1:idx], [m], A.p[(idx + 1):end])) + Point(1, 0)
        else
            # Unit-width sliver along edge idx.
            a, c = A.p[idx], A.p[mod1(idx + 1, n)]
            d = c - a
            nrm = Point(-sign(d.y), sign(d.x))
            make_polygon([a, c, c + nrm, a + nrm])
        end
        valid_polygon(B) || reject!()
        return (A, B)
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
end
