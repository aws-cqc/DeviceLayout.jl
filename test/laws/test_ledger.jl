# GeomLaws ledger: shrunk counterexamples that graduated from generative runs.
#
# Each entry is a deterministic reproducer for a law violation found by the property
# suite, with a classification. Entries whose law is known to fail on the current
# kernel are asserted with `@test_broken`, so a kernel change that fixes them fails
# loudly here and prompts an update. Generated inputs are synthetic by construction;
# nothing here derives from a design corpus.

@testitem "GeomLaws ledger" setup = [CommonTestSetup, LawsSetup] tags = [:geomlaws] begin
    # L1 — Integer-lattice polygon vanishes under the identity union.
    # Found by: B3 self-union (Clipper1); O1 zero offset (Clipper2).
    # Class: kernel finding. A valid counterclockwise triangle of area 2 is dropped
    # entirely by `union2d([A])` and `intersect2d([A],[A])`, and on Clipper1 also by
    # `union2d([A],[A])`. The apex (11,-4) lies 0.24 lattice units from the opposite
    # edge. The kernel sweeps the plane along the y values of the vertices and rounds
    # each edge's x there to the lattice, so at the apex's y the opposite edge passes
    # through the apex, and the triangle looks degenerate. Clipper2 also discards any
    # output triangle with an edge shorter than two units in both x and y
    # (`IsVerySmallTriangle`), whatever its area: `A2` has area 13. Scaling either shape
    # by 10 (or using Float64 coordinates, which are prescaled to fm) restores it.
    # Integer inputs bypass `prescale` (src/clipping.jl `clipperize`), so this acts at
    # unit scale.
    @testset "> L1 thin integer triangle survives identity ops" begin
        A = Polygon(Point{Int}[(8, 7), (12, -9), (11, -4)])
        @test valid_polygon(A)
        @test_broken !isempty(to_polygons(union2d([A])))
        @test !isempty(to_polygons(union2d([A], [A])))
        @test_broken !isempty(to_polygons(intersect2d([A], [A])))
        A2 = Polygon(Point{Int}[(19, 0), (-7, 13), (19, -1)])
        @test valid_polygon(A2)
        @test_broken union2d([A2], [A2]) ≐ [A2]
        @test_broken offset([A2], 0) ≐ [A2]
        # The same shapes at 10× survive.
        for P in (A, A2)
            P10 = Polygon(P.p .* 10)
            @test union2d([P10], [P10]) ≐ [P10]
        end
        # And the Float64 path, which uses the fm lattice, survives at unit scale.
        Af = Polygon(Point{Float64}.(A.p))
        @test union2d([Af], [Af]) ≐ [Af]
    end

    # L2 — Union output has a pinch point (vertex repeated non-consecutively).
    # Found by: B8 with strict simplicity (Clipper1, Clipper2).
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

    # L3 — Output self-crosses after lattice rounding.
    # Found by: B8 with weak simplicity (Clipper1, Clipper2).
    # Class: kernel finding. On Clipper1, the true intersection of two long edges of
    # `A ∪ B` is off-lattice; rounding put (0,5) on the wrong side, so edge (-4,9)→(0,5)
    # crossed edge (-5,9)→(10,-2), and re-unioning the union changed its area from 12 to
    # 14.5. Clipper2 gets that union right, but not `C ∖ D`: D's apex (-2,-12) lies 0.38
    # units outside C's edge (-3,-14)–(0,-4), and at its y that edge rounds onto it (L1's
    # mechanism). The output keeps the apex as a vertex and the edge unsplit, so the edge
    # crosses both of D's edges into it. The region is right within the oracle's
    # tolerance. The fm-lattice float generators (other than fm-perturbed pairs, L8) have
    # not reproduced it.
    @testset "> L3 self-crossing integer output" begin
        A = Polygon(Point{Int}[(8, 0), (-5, 9), (10, -2)])
        B = Polygon(Point{Int}[(9, 0), (-4, 9), (3, 3), (11, -2)])
        u = union2d([A], [B])
        @test valid_output(u; weak=true)
        @test u ≐ union2d(u)
        @test u ≐ union2d([B], [A])
        C = Polygon(Point{Int}[(4, 0), (-8, -1), (-3, -14), (0, -4)])
        D = Polygon(Point{Int}[(-5, 8), (-9, 8), (-2, -12)])
        @test valid_polygon(C) && valid_polygon(D)
        @test_broken valid_output(difference2d([C], [D]); weak=true)
        @test_broken valid_output(xor2d([C], [D]); weak=true)
        @test valid_output(union2d([C], [D]); weak=true)
        @test boolean_oracle_holds([C], [D])
    end

    # L4 — Hole vertex outside its parent contour after rounding.
    # Found by: B8 `nested_int` (Clipper1, Clipper2). Class: kernel finding, on the
    # integer lattice (on Clipper1 also on the fm lattice, ≈ 0.3 % of hole-bearing
    # results). B's vertex (-5,-5) lies 0.45 units outside A's edge (-7,0)–(-4,-6), so
    # the true difference has a hairline notch there; at that y the edge rounds onto
    # the vertex (L1's mechanism), so the kernel drops the notch from the outer contour
    # but keeps (-5,-5) in the hole, which now pokes outside its parent. The tree is
    # still a valid description of the region within one lattice unit, but consumers
    # that assume nesting break — see L5.
    @testset "> L4 hole vertex outside parent" begin
        A = Polygon(Point{Int}[(4, 0), (-7, 0), (-4, -6)])
        B = Polygon(Point{Int}[(-5, -5), (-2, -2), (-5, -2)])
        for x in (difference2d([A], [B]), xor2d([A], [B]))
            @test count(Clipper.ishole, tree_nodes(x)) == 1
            @test valid_output(x; weak=true)
            @test_broken valid_output(x; weak=true, nested=true)
        end
        @test first(region_within(xor2d([A], [B]), xor2d([B], [A]), 1))
    end

    # L5 — `to_polygons` cannot cut a hole whose lowest vertex lies outside its parent.
    # Found by: B11 on kernel output. Class: DeviceLayout, kernel-independent.
    # `interiorcuts` shoots a ray downward from the hole's lowest vertex and joins the
    # hole at the first parent edge it hits; when that vertex lies outside the parent
    # (L4) no edge is hit, and `to_polygons` throws (#350) rather than skip the hole,
    # which would fill it in. The tree below is Clipper1's xor of two triangles, with a
    # hole of area 156 out of 379.5 whose lowest vertex (7,-9) is 0.06 units outside its
    # parent; it is built directly, since Clipper2 returns a different tree for that xor.
    # Clipper2's L4 output fails the same way. An fm-lattice instance is pinned by
    # "Keyhole cut edge cases" in test_clipping.jl. Throwing is #350's chosen behavior,
    # so this entry pins it rather than marking it broken.
    @testset "> L5 interiorcuts throws on a hole with no downward ray hit" begin
        outer = Polygon(
            Point{Int}[
                (1, -14),
                (14, -3),
                (14, 2),
                (16, 6),
                (8, 16),
                (4, 11),
                (7, 20),
                (-18, 4),
                (-1, -5),
                (-1, -15)
            ]
        )
        hole = Polygon(Point{Int}[(7, -9), (14, 2), (7, 7), (-1, 4), (-1, -5)])
        cp = holed_tree(outer, [hole])
        @test !valid_output(cp; nested=true)
        @test region_area_exact(togrid(cp)) == 759 // 2
        @test_throws ErrorException to_polygons(cp)
        A = Polygon(Point{Int}[(4, 0), (-7, 0), (-4, -6)])
        B = Polygon(Point{Int}[(-5, -5), (-2, -2), (-5, -2)])
        @test_throws ErrorException to_polygons(difference2d([A], [B]))
        # Moving the hole's lowest vertex one unit up (Clipper1's xor after moving the
        # offending vertex) puts the hole inside its parent, and the cut succeeds. Its
        # attachment is close enough to another edge that `interiorcuts` may warn.
        outer2 = Polygon(copy(outer.p))
        outer2.p[9] = Point(-1, -4)
        hole2 = Polygon(Point{Int}[(7, -8), (14, 2), (7, 7), (-1, 4), (-1, -4)])
        cp2 = holed_tree(outer2, [hole2])
        @test valid_output(cp2; weak=true, nested=true)
        @test first(region_within(first(keyholes_warned(cp2)), togrid(cp2), 1))
    end

    # L6 — Keyhole output had repeated consecutive vertices when a hole touches its
    # parent. Found by: B11 inspection on rectilinear pairs. Class: DL
    # output hygiene, kernel-independent. When the hole's lowest vertex lies on a parent
    # edge the cut has zero length, and `interiorcuts` emitted the cut vertex up to three
    # times in a row. Fixed by #350, which drops consecutive repeated points; kept as a
    # regression. The first tree is Clipper1's xor of two rectangles; Clipper2 returns
    # two outer contours touching at vertices instead, so it is built directly.
    @testset "> L6 zero-length keyhole cut (fixed)" begin
        outer = Polygon(
            Point{Int}[(3, 2), (1, 2), (1, 3), (-12, 3), (-12, 1), (0, 1), (0, 0), (3, 0)]
        )
        hole = Polygon(Point{Int}[(1, 1), (1, 2), (0, 2), (0, 1)])
        x = holed_tree(outer, [hole])
        @test valid_output(x; nested=true)
        p = only(to_polygons(x))
        @test first(region_within(togrid([p]), togrid(x), 0))
        @test all(i -> p.p[i] != p.p[mod1(i + 1, end)], eachindex(p.p))
        # A strictly interior hole can also have a sub-lattice cut: rounding the
        # parent intersection lands on the hole vertex. Construct the tree directly
        # so changes to the clipping kernel cannot bypass this DL regression. The cut
        # may warn, but its output must be valid.
        outer = Polygon(Point{Int}[(31, 0), (20, 1), (-100, -3)])
        hole = Polygon(Point{Int}[(-22, -1), (7, 0), (4, 0)])
        cp = holed_tree(outer, [hole])
        @test contour_contained(togrid(hole), togrid(outer); strict=true)
        out, _ = keyholes_warned(cp)
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
    # self-intersect. Found by: B11 at 5000 examples (both kernels; the tree is built
    # directly). Class: DL, kernel-independent. The hole's lowest vertex (20,-9)
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
    # corner. Found by: O3 on integer polygons (Clipper1). Class: Clipper1 defect, correct
    # on Clipper2; kept as a regression.
    # Clipper1's `OffsetPoint` treated the 14.5° turn at (4,1) as collinear while
    # sin(turn)·δ < 1 and returned before advancing its previous-normal index, so the
    # tip was joined against the normal of the edge before (4,1); with that stale normal
    # the tip looked reflex and the join degenerated to the vertex itself (L10 is the
    # mirrored case of the same mechanism). Offsetting the 4° tip below by δ = 2
    # returned, for every join type, a contour through the original vertex (-14,-7),
    # at distance 0 from the input where the offset boundary should be at distance 2. It
    # reproduced while sin(14.5°)·δ < 1, i.e. δ ≤ 3, whatever the tip angle.
    @testset "> L7 small offset leaves the input vertex in place at a sharp corner" begin
        A = Polygon(Point{Int}[(16, 3), (4, 1), (-14, -7)])
        tip = (Int128(-14), Int128(-7))
        for j in (Clipper.JoinTypeRound, Clipper.JoinTypeMiter, Clipper.JoinTypeSquare)
            o = offset([A], 2; j)
            @test !(tip in only(togrid(o)))
            @test first(region_subset_within([A], o, 0))
        end
        o = offset([A], 2; j=Clipper.JoinTypeRound)
        @test all(q -> offset_class(q, togrid([A]), 2, 1) == :band, only(togrid(o)))
    end

    # L10 — Square and miter offsets cut a sharp tip inside the input when the tip
    # follows a near-collinear vertex. Found by: O4 `join_order_int` (Clipper1, 5000
    # examples). Class: Clipper1 defect, the antiparallel case of L7's mechanism. The 9°
    # turn at (11,0) has sin·δ < 1, so Clipper1's `OffsetPoint` skipped it without
    # advancing its previous-normal index; at the tip (-8,-3) the stale incoming normal
    # (0,1) was exactly opposite the outgoing (0,-1), the cross product was IEEE -0.0,
    # `atan2(-0.0, -1) = -π`, and `DoSquare` mirrored both join points through the
    # vertex: the tip was cut δ inside the input, for every δ with sin(9°)·δ < 1 and at
    # any scale. Round joins took their rotation sense from the step sign and were
    # unaffected. Correct on Clipper2; kept as a regression.
    @testset "> L10 offset cuts a sharp tip inside the input after a near-collinear vertex" begin
        A = Polygon(Point{Int}[(18, 0), (11, 0), (-8, -3), (19, -3)])
        for j in (Clipper.JoinTypeSquare, Clipper.JoinTypeMiter)
            o = offset([A], 3; j)
            @test first(region_subset_within([A], o, 0))
            # Clipper1 put the tip vertices at (-5, 0) and (-5, -6) instead of (-11, 0)
            # and (-11, -6).
            @test minimum(first, only(togrid(o))) <= -10
        end
        @test first(region_subset_within([A], offset([A], 3; j=Clipper.JoinTypeRound), 0))
        # With sin(9°)·δ ≥ 1 the turn at (11,0) is not skipped and the joins are right.
        @test first(region_subset_within([A], offset([A], 7; j=Clipper.JoinTypeSquare), 0))
        @test minimum(first, only(togrid(offset([A], 7; j=Clipper.JoinTypeSquare)))) <= -14
    end

    # L9 — A micro-edge created by one offset misdirects the next.
    # Found by: O6 closing with miter joins on floats (Clipper1, Clipper2). Class: kernel
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

    # L8 — Invalid output on the fm lattice from a feature a few fm wide.
    # Found by: B8 `valid_float_perturbed` (Clipper1, Clipper2). Class: kernel
    # finding; L3 at the scale float users actually hit. On Clipper1, `B` is a 2 fm-wide
    # sliver along one edge of `A` (coordinates ~0.4 μm), and `A ∖ B` was a
    # quadrilateral that kept both A's original vertex and the sliver's vertex 2 fm away,
    # with the two edges leaving them crossing. Clipper2 gets that right, but on `C` and
    # its copy `D` with one vertex moved 5 fm, `D ∖ C` is a sub-fm-thick sliver whose
    # vertex at the crossing of the two operands' edges rounds across its opposite edge,
    # and it comes back clockwise, as an outer contour; `xor2d` includes it. The region is
    # right within a few fm; the contours are not valid. Slivers this thin arise
    # whenever two float-computed entities are meant to share an edge but differ by a few
    # ulps, so this is the mechanism by which output with invalid contours can reach GDS
    # and SolidModel rendering.
    @testset "> L8 fm-scale invalid output" begin
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
        @test valid_output(d; weak=true)
        @test valid_output(xor2d([A], [B]); weak=true)
        C = Polygon(Point{Float64}[(5.66, 0.0), (4.6, 0.26), (-2.06, -0.24)])
        D = Polygon(Point{Float64}[(5.66, 0.0), (4.6, 0.26), (-2.059999995, -0.24)])
        @test valid_polygon(C) && valid_polygon(D)
        @test_broken valid_output(difference2d([D], [C]); weak=true)
        @test_broken valid_output(xor2d([C], [D]); weak=true)
        @test valid_output(difference2d([C], [D]); weak=true)
        @test valid_output(union2d([C], [D]); weak=true)
        @test valid_output(intersect2d([C], [D]); weak=true)
        @test boolean_oracle_holds([C], [D]; tol=7)
    end

    # L12 — A taper's halo is short of δ along its slanted sides and overhangs at its
    # narrow end. Found by: O7 `halo_offsets_taper`. Class: DeviceLayout,
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
    # `halo_inner`. Class: DeviceLayout, tracked in #8 for 2.0.
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
    # a warning. Found by: B11 `keyhole_multi`. Class: DL, kernel-independent;
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
    # to attach. Found by: sampling 20 000 `int_multi_holed_polygon` trees (2 of them
    # fail). Class: DL, kernel-independent. The sliver hole (32,9),(35,8),(39,7) is
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

    # L16 — Clipper2 fills a hole bounded by near-coincident edges.
    # Found by: B6 absorption `(A ∖ B) ∪ B` on floats (about once in 1000 draws), B12 on
    # floats (about once in 5000), and B9 mixed fill rules on integers (Clipper2). The
    # same absorption on U shapes and combs at μm scale, at random rotations, fills a hole
    # up to once in 100 trials.
    # Class: kernel defect, Clipper2 only; Clipper1 gets every case below right. In the
    # first case, the subject's edges v₁v₂ and v₄v₅ run along the clip edge c₂c₃ less
    # than one unit inside it, and the concavity v₂v₃v₄ between them encloses, with that
    # edge, a triangle that is in neither operand. `FixSelfIntersects` sees the touching
    # point as a two-edge self-intersection and `DoSplitOp` deletes the split-off loop
    # whenever its orientation is opposite to the parent's, however large: the hole is
    # filled and v₃, v₄ vanish. Reproduces on Clipper2's `main` of 2026-04. The two
    # operands overlap only in the sub-unit sliver along the shared edge, so their
    # even-odd region is the union within 1. The other cases clip the contours of an
    # xor, whose edges lie within a unit of the operands' by construction, against a
    # third polygon or an operand, and a region that is in neither comes back filled:
    # (5,4) is in neither `X` nor `E`, and `xor2d(Y, [G])` should be `F`.
    @testset "> L16 hole beside near-coincident edges is filled" begin
        S = Polygon(
            Point{Int}[
                (9035040, -1518829),
                (8467159, -916142),
                (3130000, 0),
                (3351655, 4512897),
                (2983653, 4903454),
                (-4290000, 1480000),
                (2860000, -7470000)
            ]
        )
        C = Polygon(Point{Int}[(6864912, 5923282), (-155381, 8234882), (9645694, -2166911)])
        for out in (union2d([S], [C]), union2d([C], [S]), union2d([S, C]))
            @test_broken first(region_within(out, [S, C], 1))
        end
        X = contour_polygons(
            xor2d(
                [Polygon(Point{Int}[(0, 0), (11, 0), (11, 18), (0, 18)])],
                [Polygon(Point{Int}[(26, -1), (2, 7), (5, -6)])]
            )
        )
        E = Polygon(Point{Int}[(10, 5), (-6, -8), (12, -5)])
        q = (Int128(5), Int128(4))
        @test point_in_region_exact(q, togrid(X)) === false
        @test point_in_region_exact(q, togrid([E])) === false
        @test_broken point_in_region_exact(q, togrid(union2d(X, [E]))) === false
        F = Polygon(
            Point{Float64}[
                (-0.446, 0.85),
                (-0.31, 0.162),
                (-0.586, -0.468),
                (0.336, -0.098)
            ]
        )
        G = Polygon(
            Point{Float64}[
                (-0.3132253280374344, -0.12353529006272923),
                (-0.3711301384424146, 0.5622453428396417),
                (-0.37370117117610696, -0.8161135210513555)
            ]
        )
        Y = contour_polygons(xor2d([F], [G]))
        @test_broken first(region_within(xor2d(Y, [G]), [F], 1))
        # A U closed by a bar, at μm scale: subtracting the bar and unioning it back fills
        # the 219 μm² hole between them.
        U = Polygon(
            Point{Float64}[
                (47.267758229050706, 61.96569684050057),
                (-44.492021236286824, -26.649533107540208),
                (44.12320871175395, -118.40931257287771),
                (62.475164604821465, -100.68626658326959),
                (-8.41701935361116, -27.278443010999553),
                (46.638848325591354, 25.890694957824913),
                (117.53103228402398, -47.51712861444511),
                (135.88298817709148, -29.79408262483696)
            ]
        )
        bar = Polygon(
            Point{Float64}[
                (50.76387910755797, 52.75822245030438),
                (-13.638664811382881, -57.35457627464138),
                (30.406454678595416, -83.11559384221772),
                (94.80899859753626, 26.997204882728038)
            ]
        )
        @test count(Clipper.ishole, tree_nodes(union2d(U, bar))) == 1
        @test_broken first(
            region_within(union2d(difference2d(U, bar), bar), union2d(U, bar), 1)
        )
    end

    # L17 — Clipper2 can miss an overlap thinner than a lattice unit.
    # Found by: B9 `single_rule` on integer pairs (Clipper2). Class: kernel finding, at
    # unit scale. A and B overlap in a quadrilateral of area 5.5 whose width is at most
    # 0.43: B's edge (4,-10)–(9,25) passes 0.43 and 0.29 units outside A's vertices
    # (5,-6) and (7,9), and at their y values it rounds onto them (L1's mechanism), so
    # the sweep sees the operands touch instead of overlap. `union2d` returns A and B
    # unchanged, overlapping, and `intersect2d` returns nothing. With both operands
    # reversed, the Negative fill rule merges them. Every point of the overlap is within
    # half a unit of a boundary, so the region laws hold within 1; B8 doesn't check
    # whether sibling contours overlap.
    @testset "> L17 thin overlap is missed" begin
        A = Polygon(Point{Int}[(7, 9), (2, 9), (-9, -6), (-4, -15), (5, -6)])
        B = Polygon(Point{Int}[(9, 13), (9, 25), (4, -10), (25, 1)])
        @test valid_polygon(A) && valid_polygon(B)
        @test_broken length(togrid(union2d([A], [B]))) == 1
        @test_broken !isempty(togrid(intersect2d([A], [B])))
        rev(p) = Polygon(reverse(p.p))
        merged = clip(
            Clipper.ClipTypeUnion,
            [rev(A), rev(B)],
            Polygon{Int}[];
            pfs=Clipper.PolyFillTypeNegative
        )
        @test length(togrid(merged)) == 1
        @test first(region_within(merged, union2d([A], [B]), 1))
        @test boolean_oracle_holds([A], [B])
        # At 10× the overlap is found.
        A10, B10 = Polygon(A.p .* 10), Polygon(B.p .* 10)
        @test length(togrid(union2d([A10], [B10]))) == 1
    end

    # L18 — Clipper2 can nest a contour under a neighbour it touches.
    # Found by: absorption `(A ∖ B) ∪ B` on rotated rectangles, U shapes and combs at μm
    # scale, and a plane minus a shape and a piece cut against it, outside the generated
    # laws. Class: kernel defect, Clipper2 only; fixed in DeviceLayout's shim. The piece of
    # `A ∖ B` that touches B along a nearly coincident edge comes back as a child of B with
    # `ishole` set but counterclockwise, like B, and `to_polygons` then throws because the
    # "hole" isn't inside B. In the mirror cases, a hole of a plane comes back as a child of
    # a neighbouring hole, clockwise like it and partly outside it, or a hole of an island
    # comes back beside the island, clockwise like the hole around both and inside it, at
    # any depth including the root; consumers that go by depth treat either as material. A
    # true child has the opposite orientation to its parent, so the shim attaches a node
    # oriented like its parent beside the parent when it is flagged as a hole or lies partly
    # outside the parent, and otherwise under a sibling that contains it. With that, for a
    # comb minus a U unioned back with the U, `to_polygons` still throws about once in 1000
    # trials, on trees that nest correctly (Clipper1: 4 in 1000). For a plane minus a comb's
    # pieces and a U, 4 of the 9 trees in 10 000 that needed the sibling move still throw in
    # `to_polygons`: the hole's lowest vertex lies just outside its island, which the hole
    # nearly fills, so no keyhole cut reaches it (as in L19).
    @testset "> L18 contour nested under a neighbour it touches" begin
        A = Polygon(
            Point{Float64}[
                (20.103222954218815, 39.09326033342996),
                (-168.14658928964525, 85.21387420529285),
                (-186.59483483839043, 9.913949307747231),
                (1.6549774054736552, -36.20666456411566)
            ]
        )
        B = Polygon(
            Point{Float64}[
                (-37.41587988899361, 51.92843219112405),
                (-147.23835387857935, -107.7716837780709),
                (-83.35830749090137, -151.7006733739052),
                (26.46416649868437, 7.999442595289757)
            ]
        )
        cp = union2d(difference2d(A, B), B)
        @test length(cp.tree.children) == 3
        @test all(n -> !Clipper.ishole(n) && isempty(n.children), cp.tree.children)
        @test valid_output(cp; nested=true)
        @test first(region_within(cp, union2d(A, B), 1))
        # The mirror case: the 365 μm² hole left by `A2 ∖ B2` comes back inside the hole
        # left by B2.
        A2 = Polygon(
            Point{Float64}[
                (-45.31872318955714, 13.721805051480462),
                (-61.351396016038926, 0.07044269190108565),
                (-27.03725703774435, -40.22937128053924),
                (-11.004584211262568, -26.57800892095987)
            ]
        )
        B2 = Polygon(
            Point{Float64}[
                (42.05319579763629, 12.108205228605362),
                (-14.081270556288025, 137.77770536165895),
                (-189.0701021267614, 59.61311755232425),
                (-132.9356357728371, -66.05638258072935)
            ]
        )
        plane = Rectangle(2000.0, 2000.0) - Point(1000.0, 1000.0)
        cp2 = difference2d(plane, vcat(to_polygons(difference2d(A2, B2)), [B2]))
        holes = only(cp2.tree.children).children
        @test length(holes) == 2
        @test all(n -> Clipper.ishole(n) && isempty(n.children), holes)
        @test first(region_within(cp2, difference2d(plane, union2d(A2, B2)), 1))
        # A hole of an island: the 401 μm² hole comes back as a child of the plane's
        # hole, beside the island it belongs in.
        A3 = Polygon(
            Point{Float64}[
                (24.476143292413504, 66.67475482532764),
                (-50.15399697559974, -27.295145480976124),
                (4.036662303914788, -70.33293194306289),
                (14.140541157620092, -57.6107196414387),
                (-28.30388058360647, -23.901700712853586),
                (-19.750224370308466, -13.13143793790184),
                (22.6941973709181, -46.84045686648695),
                (32.7980762246234, -34.118244564862756),
                (-9.646345516603162, -0.4092256362776412),
                (-1.09268930330515, 10.3610371386741),
                (41.35173243792141, -23.347981789911017),
                (51.45561129162672, -10.62576948828681),
                (9.011189550400154, 23.083249440298303),
                (17.564845763698163, 33.853512215250035),
                (60.00926750492472, 0.14449328666492378),
                (78.66680257192803, 23.63696836324086)
            ]
        )
        B3 = Polygon(
            Point{Float64}[
                (50.003712792212035, -88.4508994953358),
                (76.38248926921426, 20.144325593536042),
                (-23.484488660420347, 44.402930758575664),
                (-30.2992619612302, 16.348110203259967),
                (41.512895413088714, -1.0957216609697973),
                (28.763665537706196, -53.58130563921025),
                (-43.04849183661272, -36.137473774980485),
                (-49.86326513742257, -64.19229433029618)
            ]
        )
        cp3 = difference2d(plane, vcat(to_polygons(difference2d(A3, B3)), [B3]))
        island = only(only(only(cp3.tree.children).children).children)
        @test !Clipper.ishole(island) && Clipper.ishole(only(island.children))
        @test first(region_within(cp3, difference2d(plane, union2d(A3, B3)), 1))
        # The same at the top level: the outline of `A4 ∪ B4` minus the pieces of
        # `A4 ∖ B4` and B4 has its islands at the root, and the 201 μm² hole comes back
        # at the root beside its island. `to_polygons` then throws, as with Clipper1.
        A4 = Polygon(
            Point{Float64}[
                (41.658104777104676, -52.58012418677782),
                (57.17152910133508, 66.41287420277607),
                (-30.131803599011096, 77.79483501921035),
                (-32.991792185844986, 55.85779454416037),
                (39.43741571580696, 46.415011768254885),
                (38.41904822158324, 38.603802645916396),
                (-34.0101596800687, 48.046585421821874),
                (-36.87014826690259, 26.10954494677189),
                (35.55905963474935, 16.666762170866413),
                (34.54069214052564, 8.855553048527922),
                (-37.8885157611263, 18.2983358244334),
                (-40.74850434796019, -3.6387046506165817),
                (31.680703553691757, -13.081487426522063),
                (30.662336059468043, -20.892696548860552),
                (-41.7668718421839, -11.449913772955075),
                (-45.64522792324151, -41.19816337034355)
            ]
        )
        B4 = Polygon(
            Point{Float64}[
                (75.79649139865269, 39.3436361235687),
                (-39.52469126651005, 72.52533030436923),
                (-63.82264237099339, -11.920883998052963),
                (-43.63935620600667, -17.728278733456463),
                (-23.489116874123386, 52.302787735820395),
                (-14.842107372819427, 49.814758926023764),
                (-34.99234670470271, -20.216307543253095),
                (-14.80906053971599, -26.0237022786566),
                (5.341178792167295, 44.00736419062026),
                (13.988188293471255, 41.51933538082363),
                (-6.162051038412031, -28.511731088453224),
                (14.021235126574691, -34.31912582385673),
                (34.17147445845798, 35.71194064542012),
                (42.818483959761934, 33.2239118356235),
                (22.668244627878654, -36.80715463365336),
                (51.498540294169345, -45.10257817885349)
            ]
        )
        u4 = union2d(A4, B4)
        outline = Polygon(only(u4.tree.children).contour)
        cp4 = difference2d(outline, vcat(to_polygons(difference2d(A4, B4)), [B4]))
        @test length(cp4.tree.children) == 7
        @test count(n -> !isempty(n.children), cp4.tree.children) == 2
        @test all(
            n -> !Clipper.ishole(n) && all(Clipper.ishole, n.children),
            cp4.tree.children
        )
        @test first(region_within(cp4, difference2d(outline, u4), 1))
    end

    # L19 — Clipper2 can leave a sub-unit sliver hole beside a hole it touches, which
    # `to_polygons` can't attach.
    # Found by: a plane minus running-bond walls of 9–64 abutting rotated bricks, outside
    # the generated laws. Class: kernel finding, mostly Clipper2: `to_polygons` threw for
    # 79 of 1000 walls (64 on a build that, like x86_64's, doesn't fuse multiply-adds), and
    # 2 on Clipper1. Where the corner shared by two bricks lies on the edge of a third, the
    # plane comes back with the bricks' hole and, beside it, a 3-vertex hole under a fm wide
    # along the third brick's edge. Its lowest vertex lies just inside the other hole, so no
    # keyhole cut reaches it. The region is right; the failure is loud.
    @testset "> L19 sliver hole beside a hole" begin
        bricks = [
            Polygon(
                Point{Float64}[
                    (-17.096323034336404, 1.1925670686004954),
                    (-25.644484551504608, 1.7888506029007432),
                    (-25.80546482003053, -0.5189195387845454),
                    (-17.257303302862326, -1.115203073084793)
                ]
            ),
            Polygon(
                Point{Float64}[
                    (-25.644484551504608, 1.7888506029007432),
                    (-34.19264606867281, 2.385134137200991),
                    (-34.353626337198726, 0.07736399551570228),
                    (-25.80546482003053, -0.5189195387845454)
                ]
            ),
            Polygon(
                Point{Float64}[
                    (-21.531384061446424, -0.8170613059346695),
                    (-30.079545578614628, -0.2207777716344218),
                    (-30.24052584714055, -2.52854791331971),
                    (-21.692364329972346, -3.124831447619958)
                ]
            )
        ]
        plane = Rectangle(100.0, 100.0) - Point(50.0, 50.0)
        cp = difference2d(plane, bricks)
        @test first(region_within(cp, difference2d(plane, union2d(bricks)), 1))
        @test_broken length(only(cp.tree.children).children) == 1
        @test_broken !isempty(to_polygons(cp))
    end

    # L20 — Clipper2 can return a contour oriented like the hole around it, inside no
    # island; at the top level, a clockwise contour at the root.
    # Found by: a plane minus the pieces of a comb `A ∖ B` and a rotated rectangle B,
    # outside the generated laws. Class: kernel defect, Clipper2 only. In that pattern it
    # happened about once in 1000 trials for two combs, and up to 4 times in 10 000 for a
    # comb or U against a U or a rectangle, never on Clipper1. Where the 29 μm² hole of
    # `A ∪ B` should leave an island, the plane's hole holds a clockwise contour of 83 μm²
    # and no island, so the shim leaves it in place. Read as an island it adds 54 μm² too
    # much; dropped, the area would be 29 μm² short. No error is raised. One level up (the
    # outline of `A ∪ B` minus the same pieces) it happened about 4 times in 1000 for two
    # combs or two U shapes, and 13 in 5000 for a comb against a rectangle, where Clipper1
    # never gave too much area.
    @testset "> L20 contour oriented like the hole around it" begin
        A = Polygon(
            Point{Float64}[
                (11.487715495361364, 101.25670249925746),
                (-67.84964056689019, 11.225685993546943),
                (-4.30911515379515, -44.76765368802283),
                (8.824166113857412, -29.86417415116503),
                (-43.4624822360238, 16.211996022623296),
                (-36.761424488113484, 23.81627061219313),
                (15.525223861767735, -22.259899561595205),
                (28.658505129420302, -7.356420024737403),
                (-23.628143220460913, 38.719750149050924),
                (-16.927085472550594, 46.32402473862075),
                (35.359562877330625, 0.2478545648324264),
                (48.49284414498319, 15.151334101690221),
                (-3.793804204898029, 61.22750427547855),
                (2.907253543012292, 68.83177886504839),
                (55.19390189289351, 22.755608691260054),
                (75.0282409084564, 45.26336281768768)
            ]
        )
        B = Polygon(
            Point{Float64}[
                (-35.67004143144544, 63.84985989359336),
                (-43.717920404400395, -88.57348860290764),
                (27.10612566959908, -92.31296393133226),
                (35.154004642554035, 60.110384565168744)
            ]
        )
        pieces = vcat(to_polygons(difference2d(A, B)), [B])
        u = union2d(A, B)
        plane = Rectangle(2000.0, 2000.0) - Point(1000.0, 1000.0)
        cp = difference2d(plane, pieces)
        @test_broken first(region_within(cp, difference2d(plane, u), 1))
        # At the top level: the outline of `A ∪ B` minus the same pieces has the same
        # clockwise 83 μm² contour at the root, beside the 50 μm² island, where 79 μm² are
        # expected.
        outline = Polygon(only(u.tree.children).contour)
        cp2 = difference2d(outline, pieces)
        @test_broken first(region_within(cp2, difference2d(outline, u), 1))
    end
end
