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
    # within δ; the contour is weakly but not strictly simple. B8 is therefore stated
    # with weak simplicity; strict simplicity is recorded here as the aspiration.
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
    # re-interpreted under the positive fill rule). Region-equal within δ, so B3 passes;
    # B8 is marked broken for the integer generators until this is characterized on
    # Clipper2 and on the fm lattice.
    @testset "> L3 self-crossing integer union output" begin
        A = Polygon(Point{Int}[(8, 0), (-5, 9), (10, -2)])
        B = Polygon(Point{Int}[(9, 0), (-4, 9), (3, 3), (11, -2)])
        u = union2d([A], [B])
        @test_broken valid_output(u; weak=true)
        @test u ≐ union2d(u)
        @test u ≐ union2d([B], [A])
    end
end
