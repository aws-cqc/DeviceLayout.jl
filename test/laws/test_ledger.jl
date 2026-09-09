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

    # L5 — `to_polygons` silently drops a hole whose cut ray misses its parent.
    # Found by: B11 on kernel output (2026-09-09). Class: DeviceLayout bug, kernel-
    # independent. `interiorcuts` shoots a ray downward from the hole's lowest vertex
    # and joins the hole at the first parent edge it hits; when that vertex lies outside
    # the parent (L4) no edge is hit and the hole is skipped without warning, filling it
    # in. Here the xor of two triangles has a hole of area 156 out of 379.5; the keyhole
    # output has area 535.5 — the union. The fm-lattice case reproduces on random
    # stars at μm scale (`(-2,5),(-16,11),(-12,-4),(-11,-9),(19,-4),(17,-3)` xor
    # `(14,10),(21,14),(11,12),(18,20),(-1,12),(-2,4),(5,-5),(6,-11),(8,2),(13,-5)`,
    # both × 0.37, hole area 1.13 μm² lost). The `interiorcuts` fallback belongs in DL.
    @testset "> L5 interiorcuts drops a hole with no downward ray hit" begin
        A = Polygon(Point{Int}[(14, 2), (7, 7), (-1, 4), (-1, -15), (1, -14), (14, -3)])
        B = Polygon(Point{Int}[(16, 6), (8, 16), (4, 11), (7, 20), (-18, 4), (7, -9)])
        x = xor2d([A], [B])
        @test count(Clipper.ishole, tree_nodes(x)) == 1
        @test region_area_exact(togrid(x)) == 759 // 2
        @test_broken region_area_exact(togrid(to_polygons(x))) == 759 // 2
        @test_broken first(region_within(togrid(to_polygons(x)), togrid(x), 1))
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
        @test_broken first(region_within(togrid(to_polygons(xf)), togrid(xf), 1))
    end

    # L6 — Keyhole output has repeated consecutive vertices when a hole touches its
    # parent. Found by: B11 inspection on rectilinear pairs (2026-09-09). Class: DL
    # output hygiene, kernel-independent. When the hole's lowest vertex lies on a parent
    # edge the cut has zero length, and `interiorcuts` emits the cut vertex up to three
    # times in a row. The region is right; the polygon has zero-length edges. Recorded
    # as the aspiration for `to_polygons` output validity.
    @testset "> L6 zero-length keyhole cut" begin
        A = Polygon(Point{Int}[(0, 0), (3, 0), (3, 2), (0, 2)])
        B = Polygon(Point{Int}[(-12, 1), (1, 1), (1, 3), (-12, 3)])
        x = xor2d([A], [B])
        @test count(Clipper.ishole, tree_nodes(x)) == 1
        p = only(to_polygons(x))
        @test first(region_within(togrid([p]), togrid(x), 0))
        @test_broken all(i -> p.p[i] != p.p[mod1(i + 1, end)], eachindex(p.p))
    end

    # L7 — Small offsets leave the input vertex on the output boundary at a sharp
    # corner. Found by: O3 `round_oracle_small` (2026-09-09, Clipper1, integer lattice).
    # Class: kernel finding, |δ|·sin(angle) small relative to the lattice. Offsetting
    # the 4° tip below by δ = 2 returns, for every join type, a contour that passes
    # through the original vertex (-14,-7) — distance 0 from the input where the offset
    # boundary should be at distance 2 — flanked by the two edge-offset points. The
    # output is missing the bulge around the tip; the rest of the contour is correct,
    # and containment laws (O2, O4) still hold. Reproduces for δ ≤ 3 at tip angles below
    # ~5°; at δ ≥ 4, or with the same shape scaled ×10, the oracle holds within one
    # unit, so on the fm lattice this needs a tip angle below ~1e-9 rad.
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
end
