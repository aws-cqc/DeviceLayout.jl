@testitem "GeomLaws oracle regressions" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    # No integer sample can see the interior of these disjoint unit-height strips.
    strip = GridPt[(0, 0), (40, 0), (40, 1), (0, 1)]
    shifted = GridPt[(0, 10), (40, 10), (40, 11), (0, 11)]
    @test region_area_exact([strip]) == region_area_exact([shifted])
    @test !region_same([strip], [shifted])
    @test !first(region_subset_within([strip], [shifted], 0))
    @test region_same([strip], [reverse(strip)])

    # Every interior lattice point is in the 1-unit band, but this rational witness
    # is farther than 1 from all edges. Matching lattice probes cannot certify it.
    thin = GridPt[(0, 0), (3, 0), (4, 5)]
    q = (Exact(43 // 20), Exact(51 // 50))
    @test point_in_polygon_rational(q, thin) === true
    @test all(e -> distance2(q, e[1], e[2]) > 1, exact_edges([thin]))
    @test !first(region_within([thin], GridRegion(), 1))
    @test !first(region_subset_within([thin], GridRegion(), 1))
    @test first(region_within([thin], GridRegion(), 2))
    @test region_within([thin], GridRegion(), 1; max_work=0) == (false, :inconclusive)
    # A bounded-work check, not a wall-clock threshold: split across the narrow
    # direction before bisecting a femtometer sliver's 1e11-long edges.
    sliver = [GridPt[(0, 0), (10^11, 0), (10^11, 2), (0, 2)]]
    @test first(region_within(sliver, GridRegion(), 1; max_work=64))
    @test_throws ArgumentError region_within([strip], [strip], -1)

    square = GridPt[(0, 0), (10, 0), (10, 10), (0, 10)]
    duplicate = GridPt[(0, 0), (10, 0), (10, 0), (10, 10), (0, 10), (0, 0)]
    triangle = GridPt[(0, 0), (10, 10), (0, 10)]
    @test region_same([duplicate], [square])
    @test !region_same([duplicate], [triangle])
    # Equivalent decompositions force the exact sweep, with vertical and coincident
    # edges; the shared diagonal is not a region boundary.
    other = GridPt[(0, 0), (10, 0), (10, 10)]
    @test region_same([triangle, other], [square])
    left = GridPt[(0, 0), (5, 0), (5, 10), (0, 10)]
    right = GridPt[(5, 0), (10, 0), (10, 10), (5, 10)]
    @test region_same([left, right], [square])
    @test region_same([square, reverse(square)], GridRegion())
    @test !region_same([left, right], [triangle])
    strips = [GridPt[(i, 0), (i + 1, 0), (i + 1, 10), (i, 10)] for i = 0:9]
    @test region_same(strips, [square])
    @test !first(region_within(strips, GridRegion(), 1))
    @test !first(region_subset_within(strips, GridRegion(), 1))
    @test region_within(strips, [square], 1) == region_within([square], [square], 1)
    subdivided = [GridPt[(i, 0), (i + 1, 0), (i + 1, 5), (i + 1, 10), (i, 10)] for i = 0:9]
    @test region_same(subdivided, [square])
    @test !first(region_within(subdivided, GridRegion(), 1))

    θ = [0.6082478595757238, 1.3951372083580535, 4.057799532087344, 4.059211377176152]
    r = [0.38015513150338376, 0.9624178267229142, 0.9900099239051925, 0.2164413841023663]
    outer = star_polygon(Int, θ, r, 100)
    hole = star_polygon(Int, θ, r, 100 * 0.5660105962850379)
    @test valid_polygon(outer) && valid_polygon(hole)
    @test all(p -> point_in_polygon_exact(p, togrid(outer)) === true, togrid(hole))
    @test !contour_contained(togrid(hole), togrid(outer); strict=true)
    @test !contour_contained(togrid(hole), togrid(outer))
    @test !valid_output(holed_tree(outer, [hole]); nested=true)
    parent = rectangle_polygon(10, 10)
    child = rectangle_polygon(3, 3) + Point(2, 2)
    cp = holed_tree(parent, [child])
    @test valid_output(cp; nested=true)
    reverse!(cp.tree.children[1].children[1].contour)
    @test !valid_output(cp; nested=true) # A hole with outer winding is invalid.
    touching = rectangle_polygon(3, 3)
    @test contour_contained(togrid(touching), togrid(parent))
    @test !contour_contained(togrid(touching), togrid(parent); strict=true)
    # A parent edge whose endpoint lies on the line of a child edge, one unit past its
    # end, without meeting it, is no contact.
    notched =
        GridPt[(-10, -10), (-10, 30), (30, 30), (30, -10), (13, -10), (11, 0), (9, -10)]
    @test contour_contained(square, notched; strict=true)
    # Keyhole validity rejects any zero-length edge, including at a cut endpoint.
    bad = GridPt[
        (0, 0),
        (1, 0),
        (1, 20),
        (1, 20),
        (2, 24),
        (5, 21),
        (1, 20),
        (1, 0),
        (40, 0),
        (40, 40),
        (0, 40)
    ]
    @test !valid_keyholes([bad])
    @test valid_keyholes([dedupe_contour(bad)])
    @test !valid_keyholes([reverse(dedupe_contour(bad))]) # clockwise
    concave = Polygon(
        Point{Int}[
            (0, 0),
            (10, 0),
            (40, 0),
            (40, 40),
            (0, 40),
            (0, 20),
            (10, 20),
            (20, 20),
            (20, 10),
            (0, 10)
        ]
    )
    high_hole = Polygon(Point{Int}[(10, 30), (15, 31), (12, 35)])
    high_tree = holed_tree(concave, [high_hole])
    out = only(togrid(to_polygons(high_tree)))
    @test valid_keyholes([out])
    idx = findfirst(==((10, 0)), out)
    insert!(out, idx, out[idx])
    @test !valid_keyholes([out])

    small = Polygon(Point{Float64}[(0, 0), (0.1, 0), (0.1, 0.1), (0, 0.1)])
    @test lattice_delta(small, 0.02) == 20_000_000
    @test well_conditioned_offset(small, 0.02)
    @test lattice_delta(parent, 2) == 2
    @test lattice_delta(parent, 2.0) == 2e9 # Offset promotes integer coordinates.
    units = Polygon([Point(p.x * Unitful.μm, p.y * Unitful.μm) for p in small.p])
    @test lattice_delta(units, 20.0Unitful.nm) ≈ 20_000_000
    @test well_conditioned_offset(units, 20.0Unitful.nm)

    A = rectangle_polygon(40, 40)
    bevel = Polygon(
        Point{Int}[
            (-8, 0),
            (0, -8),
            (40, -8),
            (48, 0),
            (48, 40),
            (40, 48),
            (0, 48),
            (-8, 40)
        ]
    )
    @test all(p -> offset_class(p, togrid([A]), 8, 2) == :band, togrid(bevel))
    @test !round_chords_within(A, [bevel], 8, 2)
    @test round_chords_within(A, offset([A], 8; j=Clipper.JoinTypeRound), 8, 2)
    @test_throws ArgumentError round_chords_within(A, [bevel], -8, 2)
    @test_throws ArgumentError round_chords_within(A, [bevel], 2, 2)
    notch = Polygon(
        Point{Int}[
            (0, 0),
            (40, 0),
            (40, 40),
            (28, 40),
            (28, 10),
            (12, 10),
            (12, 40),
            (0, 40)
        ]
    )
    fake = Polygon(Point{Int}[(19, 20), (21, 20), (21, 30), (19, 30)])
    @test_throws ArgumentError round_chords_within(notch, [fake], 8, 2)

    config = Supposition.CheckConfig(;
        rng=Random.Xoshiro(1),
        max_examples=5,
        db=false,
        record=false
    )
    starved = @check config = config function starvation(x=Data.Integers(1, 100))
        reject!()
        return true
    end
    @test !budget_satisfied(starved)
    filled = @check config = config function sufficient(x=Data.Integers(1, 100))
        return true
    end
    @test budget_satisfied(filled)
end
