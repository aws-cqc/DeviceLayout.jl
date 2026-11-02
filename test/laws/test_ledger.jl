# GeomLaws ledger: shrunk counterexamples that graduated from generative runs.
#
# Each entry is a deterministic reproducer for a law violation found by the property
# suite, with a classification. Entries whose law is known to fail on the current
# kernel are asserted with `@test_broken`, so a kernel change that fixes them fails
# loudly here and prompts an update. Generated inputs are synthetic by construction;
# nothing here derives from a design corpus.

@testitem "GeomLaws ledger" setup = [CommonTestSetup, LawsSetup] tags = [:geomlaws] begin
    # L1 — Integer-lattice polygon vanishes under the identity union.
    # Found by: B3 `union_self` (2026-09-08, Clipper 0.6 / Clipper1 engine).
    # Class: kernel finding. A valid counterclockwise triangle of area 2 is dropped
    # entirely by `union2d([A])`, `union2d([A],[A])`, and `intersect2d([A],[A])`. The
    # apex (11,-4) lies 0.24 lattice units from the opposite edge; scaling the same
    # shape by 10 (or using Float64 coordinates, which are prescaled to fm) restores it.
    # Integer inputs bypass `prescale` (src/clipping.jl `clipperize`), so the kernel's
    # intersection rounding acts at unit scale. Expected to change under Clipper2.
    @testset "> L1 thin integer triangle survives identity ops" begin
        A = Polygon(Point{Int}[(8, 7), (12, -9), (11, -4)])
        @test valid_polygon(A)
        @test_broken !isempty(to_polygons(union2d([A])))
        @test_broken !isempty(to_polygons(union2d([A], [A])))
        @test_broken !isempty(to_polygons(intersect2d([A], [A])))
        # The same shape at 10× survives.
        A10 = Polygon(A.p .* 10)
        @test union2d([A10], [A10]) ≐ [A10]
        # And the Float64 path, which uses the fm lattice, survives at unit scale.
        Af = Polygon(Point{Float64}.(A.p))
        @test union2d([Af], [Af]) ≐ [Af]
    end

    # L2 — Union output has a pinch point (vertex repeated non-consecutively).
    # Found by: B8 `union_valid` with strict simplicity (2026-09-08, Clipper1).
    # Class: tolerance. Two overlapping triangles whose true overlap is sub-lattice
    # collapse to a single shared vertex (11,-3) after rounding. The region is correct
    # within one lattice unit; the contour is weakly but not strictly simple. B8 is
    # therefore stated with weak simplicity; strict simplicity is recorded here as the
    # aspiration.
    @testset "> L2 pinch point in integer union output" begin
        A = Polygon(Point{Int}[(7, 0), (-4, -3), (14, -5)])
        B = Polygon(Point{Int}[(21, 0), (10, -3), (28, -5)])
        u = union2d([A], [B])
        @test valid_output(u; weak=true)
        @test_broken valid_output(u; weak=false)
        @test u ≐ union2d([B], [A])
    end

    # L3 — Union output self-crosses after lattice rounding.
    # Found by: B8 `union_valid` with weak simplicity (2026-09-08, Clipper1, random seed).
    # Class: kernel finding (documented Clipper1 behavior: output is not guaranteed
    # simple unless `StrictlySimple` is set, which DL does not do). The true
    # intersection of the two long edges is off-lattice; rounding puts (0,5) on the
    # wrong side, so edge (-4,9)→(0,5) crosses edge (-5,9)→(10,-2). Consequences: the
    # union has area 12 but re-unioning it yields 14.5 (the crossing loop is
    # re-interpreted under the positive fill rule). B8 is marked broken for the integer
    # generators until this is characterized on Clipper2; the fm-lattice float
    # generators (including fm-perturbed pairs) have not reproduced it.
    @testset "> L3 self-crossing integer union output" begin
        A = Polygon(Point{Int}[(8, 0), (-5, 9), (10, -2)])
        B = Polygon(Point{Int}[(9, 0), (-4, 9), (3, 3), (11, -2)])
        u = union2d([A], [B])
        @test_broken valid_output(u; weak=true)
        @test_broken u ≐ union2d(u)
        @test u ≐ union2d([B], [A])
    end

    # L4 — Hole vertex outside its parent contour after rounding.
    # Found by: B8 `nested_int` (2026-09-09, Clipper1). Class: kernel finding, both
    # lattices (integer stars ≈ 1 % of hole-bearing results; fm-lattice floats ≈ 0.3 %).
    # B's vertex (4,4) lies just outside A, so the true xor has a hairline spike there;
    # Clipper drops the spike from the outer contour but keeps (4,4) in the hole, which
    # now pokes 0.4 units outside its parent. The tree is still a valid description of
    # the region within one lattice unit, but consumers that assume nesting break — see
    # L5.
    @testset "> L4 hole vertex outside parent" begin
        A = Polygon(Point{Int}[(18, 1), (5, 17), (3, -14)])
        B = Polygon(Point{Int}[(16, 10), (7, 10), (4, 4)])
        x = xor2d([A], [B])
        @test count(Clipper.ishole, tree_nodes(x)) == 1
        @test valid_output(x; weak=true)
        @test_broken valid_output(x; weak=true, nested=true)
        @test first(region_within(x, xor2d([B], [A]), 1))
    end

    # L5 — `to_polygons` cannot cut a hole whose lowest vertex lies outside its parent.
    # Found by: B11 on kernel output (2026-09-09). Class: DeviceLayout, kernel-
    # independent. `interiorcuts` shoots a ray downward from the hole's lowest vertex
    # and joins the hole at the first parent edge it hits; when that vertex lies outside
    # the parent (L4) no edge is hit. Until #350 the hole was skipped without warning,
    # filling it in; `to_polygons` now throws instead. Here the xor of two triangles has
    # a hole of area 156 out of 379.5. The fm-lattice case reproduces on random
    # stars at μm scale (`(-2,5),(-16,11),(-12,-4),(-11,-9),(19,-4),(17,-3)` xor
    # `(14,10),(21,14),(11,12),(18,20),(-1,12),(-2,4),(5,-5),(6,-11),(8,2),(13,-5)`,
    # both × 0.37, hole area 1.13 μm²). Throwing is #350's chosen behavior, so this entry
    # pins it rather than marking it broken.
    @testset "> L5 interiorcuts throws on a hole with no downward ray hit" begin
        A = Polygon(Point{Int}[(14, 2), (7, 7), (-1, 4), (-1, -15), (1, -14), (14, -3)])
        B = Polygon(Point{Int}[(16, 6), (8, 16), (4, 11), (7, 20), (-18, 4), (7, -9)])
        x = xor2d([A], [B])
        @test count(Clipper.ishole, tree_nodes(x)) == 1
        @test region_area_exact(togrid(x)) == 759 // 2
        @test_throws ErrorException to_polygons(x)
        # Moving B's offending vertex one unit up puts the hole inside its parent, and
        # the cut succeeds.
        B2 = Polygon(Point{Int}[(16, 6), (8, 16), (4, 11), (7, 20), (-18, 4), (7, -8)])
        x2 = xor2d([A], [B2])
        @test count(Clipper.ishole, tree_nodes(x2)) == 1
        @test valid_output(x2; weak=true, nested=true)
        @test first(region_within(togrid(to_polygons(x2)), togrid(x2), 1))
        # The fm-lattice instance.
        Af = Polygon(
            Point{Float64}[(-2, 5), (-16, 11), (-12, -4), (-11, -9), (19, -4), (17, -3)] .* 0.37
        )
        Bf = Polygon(
            Point{Float64}[
                (14, 10),
                (21, 14),
                (11, 12),
                (18, 20),
                (-1, 12),
                (-2, 4),
                (5, -5),
                (6, -11),
                (8, 2),
                (13, -5)
            ] .* 0.37
        )
        xf = xor2d([Af], [Bf])
        @test count(Clipper.ishole, tree_nodes(xf)) == 1
        @test_broken valid_output(xf; weak=true, nested=true)
        @test_throws ErrorException to_polygons(xf)
    end

    # L6 — Keyhole output had repeated consecutive vertices when a hole touches its
    # parent. Found by: B11 inspection on rectilinear pairs (2026-09-09). Class: DL
    # output hygiene, kernel-independent. When the hole's lowest vertex lies on a parent
    # edge the cut has zero length, and `interiorcuts` emitted the cut vertex up to three
    # times in a row. Fixed by #350, which drops consecutive repeated points; kept as a
    # regression.
    @testset "> L6 zero-length keyhole cut (fixed)" begin
        A = Polygon(Point{Int}[(0, 0), (3, 0), (3, 2), (0, 2)])
        B = Polygon(Point{Int}[(-12, 1), (1, 1), (1, 3), (-12, 3)])
        x = xor2d([A], [B])
        @test count(Clipper.ishole, tree_nodes(x)) == 1
        p = only(to_polygons(x))
        @test first(region_within(togrid([p]), togrid(x), 0))
        @test all(i -> p.p[i] != p.p[mod1(i + 1, end)], eachindex(p.p))
        # A strictly interior hole can also have a sub-lattice cut: rounding the
        # parent intersection lands on the hole vertex. Construct the tree directly
        # so changes to the clipping kernel cannot bypass this DL regression.
        outer = Polygon(Point{Int}[(31, 0), (20, 1), (-100, -3)])
        hole = Polygon(Point{Int}[(-22, -1), (7, 0), (4, 0)])
        cp = holed_tree(outer, [hole])
        @test contour_contained(togrid(hole), togrid(outer); strict=true)
        out = togrid(to_polygons(cp))
        @test valid_keyholes(out)
        @test all(v -> is_simple_exact(v; weak=true), out)
        # The attachment can also coincide with an existing parent vertex even when
        # the hole has ample clearance: the parent endpoint was emitted twice.
        outer = Polygon(Point{Int}[(20, 0), (-4, 20), (0, -20)])
        hole = Polygon(Point{Int}[(4, 0), (-1, 4), (0, -4)])
        cp = holed_tree(outer, [hole])
        @test valid_output(cp; nested=true)
        out = togrid(to_polygons(cp))
        @test valid_keyholes(out)
        @test all(v -> is_simple_exact(v; weak=true), out)
    end

    # L11 — A keyhole cut rounded onto the lattice can make the keyhole polygon
    # self-intersect. Found by: B11 at 5000 examples (2026-09-21, both kernels; the tree
    # is built directly). Class: DL, kernel-independent. The hole's lowest vertex (20,-9)
    # lies 0.4 above the parent edge (-79,32)–(86,-37), so on the lattice the cut has
    # zero length, and the pinch lifts that edge through the hole vertex (-19,7), which
    # was 0.09 above it. `interiorcuts` warns. In a sample of 5000 valid B11 trees,
    # 226 warned, 6 of those gave invalid output, and none gave invalid output unwarned.
    @testset "> L11 keyhole pinch crosses a nearby hole vertex" begin
        outer = Polygon(Point{Int}[(-8, 66), (-79, 32), (86, -37)])
        hole = Polygon(Point{Int}[(20, -9), (-2, 16), (-19, 7)])
        cp = holed_tree(outer, [hole])
        @test valid_output(cp; nested=true)
        out, warned = keyholes_warned(cp)
        @test warned
        @test first(region_within(out, togrid(cp), 1))
        @test_broken valid_keyholes(out)
    end

    # L7 — Small offsets leave the input vertex on the output boundary at a sharp
    # corner. Found by: O3 `round_oracle_small` (2026-09-09, Clipper1, integer lattice).
    # Class: kernel finding. `OffsetPoint` treats the 14.5° turn at (4,1) as collinear
    # while sin(turn)·δ < 1 and returns before advancing its previous-normal index, so the
    # tip is joined against the normal of the edge before (4,1); with that stale normal
    # the tip looks reflex and the join degenerates to the vertex itself (L10 is the
    # mirrored case of the same mechanism). Offsetting
    # the 4° tip below by δ = 2 returns, for every join type, a contour that passes
    # through the original vertex (-14,-7) — distance 0 from the input where the offset
    # boundary should be at distance 2 — flanked by the two edge-offset points. The
    # output is missing the bulge around the tip; the rest of the contour is correct,
    # and `A ⊆ offset(A, δ)` holds only because the boundary passes through the vertex.
    # Reproduces exactly while sin(14.5°)·δ < 1, i.e. δ ≤ 3, whatever the tip angle; at
    # δ ≥ 4, or with the same shape scaled ×10, the oracle holds within one unit, so on
    # the fm lattice this needs a turn below ~1e-9 rad ahead of the tip.
    @testset "> L7 small offset leaves the input vertex in place at a sharp corner" begin
        A = Polygon(Point{Int}[(16, 3), (4, 1), (-14, -7)])
        tip = (Int128(-14), Int128(-7))
        for j in (Clipper.JoinTypeRound, Clipper.JoinTypeMiter, Clipper.JoinTypeSquare)
            o = offset([A], 2; j)
            @test tip in only(togrid(o))
            @test_broken all(
                q -> offset_class(q, togrid([A]), 2, 1) == :band,
                only(togrid(o))
            )
            @test first(region_subset_within([A], o, 1))
        end
        o4 = offset([A], 4; j=Clipper.JoinTypeRound)
        @test all(q -> offset_class(q, togrid([A]), 4, 1) == :band, only(togrid(o4)))
        A10 = Polygon(A.p .* 10)
        o20 = offset([A10], 20; j=Clipper.JoinTypeRound)
        @test all(q -> offset_class(q, togrid([A10]), 20, 1) == :band, only(togrid(o20)))
    end

    # L10 — Square and miter offsets cut a sharp tip inside the input when the tip
    # follows a near-collinear vertex. Found by: O4 `join_order_int` (2026-09-21,
    # Clipper1, seed 2 at 5000 examples). Class: kernel defect, the antiparallel case of
    # L7's mechanism. The 9° turn at (11,0) has sin·δ < 1, so `OffsetPoint` skips it
    # without advancing its previous-normal index; at the tip (-8,-3) the stale incoming
    # normal (0,1) is exactly opposite the outgoing (0,-1), the cross product is IEEE
    # -0.0, `atan2(-0.0, -1) = -π`, and `DoSquare` mirrors both join points through the
    # vertex: the tip is cut δ inside the input, for every δ with sin(9°)·δ < 1 and at
    # any scale. Round joins take their rotation sense from the step sign and are
    # unaffected. Correct on Clipper2.
    @testset "> L10 offset cuts a sharp tip inside the input after a near-collinear vertex" begin
        A = Polygon(Point{Int}[(18, 0), (11, 0), (-8, -3), (19, -3)])
        for j in (Clipper.JoinTypeSquare, Clipper.JoinTypeMiter)
            o = offset([A], 3; j)
            @test_broken first(region_subset_within([A], o, 0))
            # The tip vertices land at (-5, 0) and (-5, -6) instead of (-11, 0) and (-11, -6).
            @test_broken minimum(first, only(togrid(o))) <= -10
        end
        @test first(region_subset_within([A], offset([A], 3; j=Clipper.JoinTypeRound), 0))
        # With sin(9°)·δ ≥ 1 the turn at (11,0) is not skipped and the joins are right.
        @test first(region_subset_within([A], offset([A], 7; j=Clipper.JoinTypeSquare), 0))
        @test minimum(first, only(togrid(offset([A], 7; j=Clipper.JoinTypeSquare)))) <= -14
    end

    # L9 — A micro-edge created by one offset misdirects the next.
    # Found by: O6 `closing_float` (2026-09-09, Clipper1, fm lattice). Class: kernel
    # finding, tolerance amplification. `A` has a nearly straight vertex (turn 0.08°).
    # Growing by δ ≈ 98 nm with miter joins emits two offset points there that round to
    # lattice points 1 fm apart — a horizontal edge whose direction has nothing to do
    # with the geometry. Shrinking back offsets that edge by δ along its own normal,
    # cutting a 110 nm notch and leaving A's vertex 38 fm outside the result. The same
    # mechanism applies to any offset of an offset (halos of halos, `offset` after
    # `to_polygons` of a discretized curve whose vertices nearly coincide).
    @testset "> L9 micro-edge from one offset misdirects the next" begin
        A = Polygon(
            Point{Float64}[
                (0.0002, 0.0),
                (-0.000275, -0.000117),
                (-0.000269, -0.00017),
                (-0.000233, -0.000492)
            ]
        )
        δ = 0.2 * 0.000492
        j = Clipper.JoinTypeMiter
        grown = offset([A], δ; j)
        @test min_edge_length(grown) == 1
        back = offset(grown, -δ; j)
        @test_broken first(region_subset_within([A], back, 2))
        # The derived tolerance |δ|/(2L) says so: with L = 1 fm it is ~5e4 fm.
        @test offset_tol(grown, δ) > 10_000
        # Removing the micro-edge before shrinking restores the closing law at 2.
        cleaned = [Polygon(strip_short_edges(p.p)) for p in grown]
        @test first(region_subset_within([A], offset(cleaned, -δ; j), 2))
    end

    # L8 — Self-crossing output on the fm lattice from a 2 fm feature.
    # Found by: B8 `valid_float_perturbed` (2026-09-09, Clipper1). Class: kernel
    # finding; L3 at the scale float users actually hit. `B` is a 2 fm-wide sliver along
    # one edge of `A` (coordinates ~0.4 μm). `A ∖ B` should be `A` shaved by 2 fm along
    # that edge; Clipper1 returns a quadrilateral that keeps both A's original vertex and
    # the sliver's vertex 2 fm away, and the two edges leaving them cross. The region is
    # right within 1 fm; the contour is not simple. Slivers this thin arise whenever two
    # float-computed entities are meant to share an edge but differ by a few ulps, so
    # this is the mechanism by which `difference2d` output can carry self-crossings into
    # GDS and SolidModel rendering.
    @testset "> L8 fm-scale self-crossing difference output" begin
        A = Polygon(
            Point{Float64}[(-0.000199, -2.1e-5), (-0.0004, -0.000427), (4.0e-6, -0.0002)]
        )
        B = Polygon(
            Point{Float64}[
                (4.0e-6, -0.0002),
                (-0.000199, -2.1e-5),
                (-0.00019900132275439176, -2.1001500106935892e-5),
                (3.9986772456082525e-6, -0.0002000015001069359)
            ]
        )
        @test valid_polygon(A) && valid_polygon(B)
        d = difference2d([A], [B])
        @test first(region_within(d, [A], 2))
        @test_broken valid_output(d; weak=true)
        @test_broken valid_output(xor2d([A], [B]); weak=true)
        @test valid_output(union2d([A], [B]); weak=true)
        @test valid_output(intersect2d([A], [B]); weak=true)
    end

    # L12 — A taper's halo is short of δ along its slanted sides and overhangs at its
    # narrow end. Found by: O7 `halo_offsets_taper` (2026-10-30). Class: DeviceLayout,
    # tracked in #8 for 2.0.
    # `halo(::TaperTrace, δ)` is the taper with both widths increased by 2δ, which
    # keeps δ only along the path's normal: a side slanted at α from the path ends up
    # δ·cos α from the taper. For 10 → 2 μm over 10 μm at δ = 2 μm (tan α = 0.4) that is
    # 143 nm short, so anything kept out by the halo can come 143 nm closer than δ. At
    # the narrow end, the square extension's corner (12, -3) lies 0.65 μm beyond the
    # miter offset's corner (12, -2.354), outside every offset of the taper.
    @testset "> L12 taper halo keeps δ only along the path normal" begin
        pa = Path(Point(0.0, 0.0))
        straight!(pa, 10.0, Paths.TaperTrace(10.0, 2.0))
        H = togrid(path_region(halo(pa, 2.0, nothing)))
        # 1.95 μm out from the middle of the lower side, so within δ of the taper.
        n = Point(0.4, -1.0) / hypot(0.4, 1.0)
        q = togrid(Point(5.0, -3.0) + 1.95 * n)
        @test offset_class(q, togrid(path_region(pa)), _gridcoord(2.0), HALO_TOL) == :in
        @test_broken point_in_region_exact(q, H) === true
        miter = togrid(offset(path_polygons(pa), 2.0; j=Clipper.JoinTypeMiter))
        q2 = togrid(Point(11.9, -2.9))
        @test point_in_region_exact(q2, miter) === false
        @test_broken point_in_region_exact(q2, H) === false
        @test_broken halo_is_offset(pa, pa, 2.0)
        # A uniform trace keeps δ everywhere.
        pu = Path(Point(0.0, 0.0))
        straight!(pu, 10.0, Paths.Trace(6.0))
        @test halo_is_offset(pu, pu, 2.0)
    end

    # L13 — A path halo with an inner offset is open at the path's ends. Found by: O7
    # `halo_inner` (2026-10-30). Class: DeviceLayout, tracked in #8 for 2.0.
    # `halo(pa, δ, δi)` is documented as offsetting by δ, then subtracting the offset by
    # δi, so it should be the band `halo(pa, δ) ∖ halo(pa, δi)`. Each path end instead
    # gets one straight extension, δ long, styled as a CPW whose trace is the inner
    # offset's width: it covers the two side bands but not the cap between δi and δ
    # beyond the end, so the band does not close around the end.
    @testset "> L13 inner-offset halo is open at the ends" begin
        pa = Path(Point(0.0, 0.0))
        straight!(pa, 10.0, Paths.Trace(4.0))
        X = togrid(path_region(halo(pa, 2.0, 1.0)))
        # 1.5 μm before the start, on the centerline: beyond δi, within δ.
        q = togrid(Point(-1.5, 0.0))
        @test point_in_region_exact(q, togrid(path_region(halo(pa, 2.0, nothing)))) === true
        @test point_in_region_exact(q, togrid(path_region(halo(pa, 1.0, nothing)))) ===
              false
        @test_broken point_in_region_exact(q, X) === true
        @test_broken inner_halo_is_difference(pa, 2.0, 1.0)
        # Along the sides the band is right.
        @test point_in_region_exact(togrid(Point(5.0, 3.5)), X) === true
        @test point_in_region_exact(togrid(Point(5.0, 2.5)), X) === false
    end

    # L14 — A keyhole cut attached next to another hole's cut can cross that hole without
    # a warning. Found by: B11 `keyhole_multi` (2026-10-30). Class: DL, kernel-independent;
    # L11's mechanism where #350's check does not look. Hole B is cut first, from its
    # lowest vertex (3,10) down to the outer contour. Hole A's ray from (5,32) then meets
    # B's edge (7,11)–(3,10) at y = 10.5, and the attachment rounds to (5,10), below B's
    # other edge (3,10)–(21,13), which passes 0.33 below the hit point: the cut crosses
    # it. The kink check looks at the hit edge's neighbors in the contour as spliced so
    # far, and across (3,10) that neighbor is now B's own cut, not the edge it crosses.
    # Region within 1.
    @testset "> L14 cut beside another hole's cut crosses it unwarned" begin
        outer = Polygon(Point{Int}[(0, 0), (24, 0), (24, 48), (0, 48)])
        A = Polygon(Point{Int}[(15, 36), (8, 34), (5, 32)])
        B = Polygon(Point{Int}[(3, 10), (21, 13), (15, 15), (10, 20), (7, 11)])
        cp = holed_tree(outer, [A, B])
        @test valid_output(cp; nested=true)
        out, warned = keyholes_warned(cp)
        @test first(region_within(out, togrid(cp), 1))
        @test_broken warned || valid_keyholes(out)
        # Either hole alone is cut validly.
        for h in (A, B)
            out1, _ = keyholes_warned(holed_tree(outer, [h]))
            @test valid_keyholes(out1)
        end
    end

    # L15 — After a cut that `interiorcuts` flags, a later hole of a valid tree can fail
    # to attach. Found by: sampling 20 000 `int_multi_holed_polygon` trees (2026-11-02,
    # 2 trees). Class: DL, kernel-independent. The sliver hole (32,9),(35,8),(39,7) is
    # cut first. The second hole's ray from (38,32) meets the sliver's edge (39,7)–(32,9)
    # at y ≈ 7.29, and the attachment rounds to (38,7), which lays (32,9)–(38,7) onto the
    # collinear edge (32,9)–(35,8). That cut is flagged, but the third hole's ray from
    # (33,52) meets the two overlapping edges at the same point and takes the one facing
    # the exterior, so `to_polygons` throws before emitting the warning. Accepted: the
    # B11 laws treat this error as they would the warning.
    @testset "> L15 hole after a flagged cut fails to attach" begin
        outer = Polygon(Point{Int}[(24, 0), (48, 0), (48, 64), (24, 64)])
        H = [
            Polygon(Point{Int}[(32, 9), (35, 8), (39, 7)]),
            Polygon(Point{Int}[(44, 33), (42, 33), (38, 32)]),
            Polygon(Point{Int}[(33, 52), (36, 60), (30, 60)])
        ]
        cp = difference2d([outer], H)
        @test valid_output(cp; nested=true)
        @test count(Clipper.ishole, tree_nodes(cp)) == 3
        @test_throws r"\(33, ?52\).*could not be\s+attached" to_polygons(cp)
        # The first two holes alone are cut with the warning, and without the second
        # hole the third attaches.
        @test last(keyholes_warned(difference2d([outer], H[1:2])))
        @test valid_keyholes(first(keyholes_warned(difference2d([outer], H[[1, 3]]))))
        @test keyholes_warned(cp) == (nothing, true)
    end
end
