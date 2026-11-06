# Fixed fixtures for the exact predicates, the generators' guaranteed degeneracies, and
# the region comparisons. These are deterministic and independent of the kernel.

@testitem "GeomLaws exact predicate sanity" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    g(x, y) = (Int128(x), Int128(y))
    square = [g(0, 0), g(4, 0), g(4, 4), g(0, 4)]
    crossing = [g(0, 0), g(4, 4), g(0, 4), g(4, 0)]
    # Two squares joined by a zero-width bridge traversed in both directions.
    bridge =
        [g(0, 0), g(2, 0), g(6, 0), g(6, 2), g(4, 2), g(4, 0), g(2, 0), g(2, 2), g(0, 2)]

    @test orient_exact(g(0, 0), g(4, 0), g(2, 1)) > 0
    @test segments_intersect_exact(g(0, 0), g(4, 4), g(0, 4), g(4, 0))
    @test !segments_intersect_exact(g(0, 0), g(1, 0), g(2, 0), g(3, 0))
    @test segments_cross_exact(g(0, 0), g(4, 4), g(0, 4), g(4, 0))
    @test !segments_cross_exact(g(0, 0), g(4, 0), g(2, 0), g(6, 0))  # collinear overlap
    @test !segments_cross_exact(g(0, 0), g(4, 0), g(2, 0), g(2, 3))  # T-junction
    @test is_simple_exact(square)
    @test !is_simple_exact(crossing)
    @test !is_simple_exact(crossing; weak=true)
    @test !is_simple_exact(bridge)
    @test is_simple_exact(bridge; weak=true)
    @test point_in_polygon_exact(g(2, 2), square) === true
    @test point_in_polygon_exact(g(5, 2), square) === false
    @test ismissing(point_in_polygon_exact(g(0, 2), square))
    @test area_exact(square) == 16
    @test region_area_exact([square, reverse(square)]) == 0
    @test within_segment_distance_exact(g(2, 1), g(0, 0), g(4, 0), 1)
    @test !within_segment_distance_exact(g(2, 2), g(0, 0), g(4, 0), 1)
    @test within_segment_distance_exact(g(5, 0), g(0, 0), g(4, 0), 1)
    @test !within_segment_distance_exact(g(6, 0), g(0, 0), g(4, 0), 1)

    same_a, same_b = degenerate_pair_polygons(4, 3, 1, 0)
    overlap_a, overlap_b = degenerate_pair_polygons(4, 3, 1, 2)
    disjoint_a, disjoint_b = degenerate_pair_polygons(4, 3, 1, 5)
    edge_a, edge_b = degenerate_pair_polygons(4, 3, 2, 0)
    corner_a, corner_b = degenerate_pair_polygons(4, 3, 3, 0)
    collinear_a, collinear_b = degenerate_pair_polygons(4, 3, 4, 1)
    sliver_a, sliver_b = degenerate_pair_polygons(4, 3, 5, 0)
    @test togrid(same_a) == togrid(same_b)
    @test point_in_polygon_exact(g(3, 1), togrid(overlap_a)) === true
    @test point_in_polygon_exact(g(3, 1), togrid(overlap_b)) === true
    @test maximum(first, togrid(disjoint_a)) < minimum(first, togrid(disjoint_b))
    @test intersect(Set(togrid(edge_a)), Set(togrid(edge_b))) == Set([g(4, 0), g(4, 3)])
    @test intersect(Set(togrid(corner_a)), Set(togrid(corner_b))) == Set([g(4, 3)])
    @test length(collinear_b.p) == 5
    @test on_segment_exact(
        togrid(collinear_b.p[2]),
        togrid(collinear_a.p[1]),
        togrid(collinear_a.p[2])
    )
    @test togrid(collinear_b.p[2]) ∉ (togrid(collinear_a.p[1]), togrid(collinear_a.p[2]))
    @test intersect(Set(togrid(sliver_a)), Set(togrid(sliver_b))) == Set([g(0, 0), g(4, 0)])
    @test area_exact(togrid(sliver_b)) == 4

    # Staircase generator produces the expected outline.
    stair = staircase_polygon(6, [3, 0], [2, 4])
    @test togrid(stair) == [g(0, 0), g(6, 0), g(6, 2), g(3, 2), g(3, 4), g(0, 4)]
    @test valid_polygon(stair)

    # Unit-typed float coordinates land on the fm lattice.
    @test togrid(Point(1.5Unitful.nm, -2.0Unitful.μm)) == g(1_500_000, -2_000_000_000)
    @test togrid(Point(3Unitful.nm, 4Unitful.nm)) == g(3, 4)
end

@testitem "GeomLaws region comparison fixtures" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    g(x, y) = (Int128(x), Int128(y))
    square = [g(0, 0), g(10, 0), g(10, 10), g(0, 10)]
    shifted = [g(1, 0), g(11, 0), g(11, 10), g(1, 10)]
    with_collinear = [g(0, 0), g(5, 0), g(10, 0), g(10, 10), g(0, 10)]
    hole = reverse([g(3, 3), g(7, 3), g(7, 7), g(3, 7)])
    shift(v, dx, dy) = [(q[1] + dx, q[2] + dy) for q in v]

    # Exact comparison ignores start vertex, orientation, and collinear vertices only.
    @test first(region_equal([square], [with_collinear]))
    @test first(region_equal([square], [reverse(circshift(square, 2))]))
    @test !first(region_equal([square], [shifted]))
    @test !first(region_equal([square, hole], [square]))

    # Within-tolerance comparison: a sub-tolerance shift passes, a larger one fails;
    # a missing 4-wide hole fails at tol 1 and passes at tol 2 (the closed band
    # includes its center, exactly 2 from its boundary); a
    # sub-tolerance needle passes at tol 1; a thin triangle of area 2 is still
    # distinguishable from nothing.
    @test first(region_within([square], [shifted], 1))
    @test !first(region_within([square], [shift(shifted, 2, 0)], 1))
    @test !first(region_within([square, hole], [square], 1))
    @test first(region_within([square, hole], [square], 2))
    @test first(region_within([square, hole], [square], 3))
    needle = [g(0, 10), g(0, 11), g(40, 10)]
    @test first(region_within([square, needle], [square], 1))
    @test !first(region_within([square, needle], [square], 0))
    thin = [g(8, 7), g(12, -9), g(11, -4)]
    @test !first(region_equal([thin], Vector{Vector{GridPt}}()))
    @test !first(region_within([thin], Vector{Vector{GridPt}}(), 0))
    @test !first(region_within([square], Vector{Vector{GridPt}}(), 3))

    # Containment.
    inner = [g(2, 2), g(8, 2), g(8, 8), g(2, 8)]
    @test first(region_subset_within([inner], [square], 0))
    @test !first(region_subset_within([square], [inner], 1))
    @test first(region_subset_within([square], [shifted], 1))
    @test !first(region_subset_within([square], [shift(shifted, 2, 0)], 1))

    # Offset oracle classification around a square, δ = 3, tol = 1.
    A = [square]
    @test offset_class(g(5, 5), A, 3, 1) == :in
    @test offset_class(g(12, 5), A, 3, 1) == :in      # dist 2 ≤ δ − tol
    @test offset_class(g(13, 5), A, 3, 1) == :band    # dist 3
    @test offset_class(g(15, 5), A, 3, 1) == :out     # dist 5 > δ + tol
    @test offset_class(g(5, 5), A, -3, 1) == :in      # 5 from every edge ≥ δ + tol
    @test offset_class(g(3, 5), A, -3, 1) == :band    # dist 3
    @test offset_class(g(1, 5), A, -3, 1) == :out
    @test offset_class(g(12, 5), A, -3, 1) == :out
    # δ ≤ tol: the band reaches across ∂A by tol − |δ|.
    @test offset_class(g(10, 5), A, 1, 2) == :band    # on ∂A, 1 from the offset
    @test offset_class(g(9, 5), A, 1, 2) == :band     # 1 inside, ≥ 2 from the offset
    @test offset_class(g(8, 5), A, 1, 2) == :in
    @test offset_class(g(11, 5), A, -1, 2) == :band
    @test offset_class(g(12, 5), A, -1, 2) == :out
end
