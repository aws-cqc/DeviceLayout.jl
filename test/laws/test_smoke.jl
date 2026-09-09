# Phase-0 smoke laws: B1 (commutativity), B3 (idempotence), B7 (point-membership oracle)
# over `union2d`. These exist to prove the harness end-to-end — generators, exact
# predicates, region equality, shrinking — before the full catalog lands.

@testitem "GeomLaws smoke: union2d commutativity (B1)" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    @check config = LAWS function union_commutes(pair=degenerate_pair)
        A, B = pair
        return union2d([A], [B]) ≐ union2d([B], [A])
    end
end

@testitem "GeomLaws smoke: union2d idempotence (B3)" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    @law :B3_int @check config = LAWS function union_self(A=int_polygon)
        return union2d([A], [A]) ≐ [A]
    end
    @law :B3_int @check config = LAWS function union_normal_form(pair=degenerate_pair)
        A, B = pair
        u = union2d([A], [B])
        return union2d(u) ≐ u
    end
end

@testitem "GeomLaws smoke: union2d membership oracle (B7)" setup =
    [CommonTestSetup, LawsSetup] tags = [:geomlaws] begin
    # For every sampled point off both boundaries, membership in the union must equal
    # the disjunction of memberships in the operands. This is the load-bearing law: the
    # right-hand side never touches the clipping kernel.
    @check config = LAWS function union_membership(pair=degenerate_pair)
        A, B = pair
        gA, gB = [togrid(A)], [togrid(B)]
        gU = togrid(union2d([A], [B]))
        saw_a_interior = false
        saw_b_interior = false
        for q in sample_points(gA, gB, gU)
            near_boundary(q, DEFAULT_δ, gA, gB, gU) && continue
            a = point_in_region_exact(q, gA)
            b = point_in_region_exact(q, gB)
            u = point_in_region_exact(q, gU)
            (ismissing(a) || ismissing(b) || ismissing(u)) && continue
            saw_a_interior |= a
            saw_b_interior |= b
            (a | b) == u || return false
        end
        (saw_a_interior && saw_b_interior) || reject!()
        return true
    end

    # B8 on the same inputs: output contours are simple and the tree alternates. Known
    # broken on the integer lattice with Clipper1 (ledger L3): rounding an intersection
    # vertex can leave a self-crossing in the output.
    @law :B8_int @check config = LAWS function union_valid(pair=degenerate_pair)
        A, B = pair
        return valid_output(union2d([A], [B]))
    end
end

@testitem "GeomLaws exact predicate sanity" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    g(x, y) = (Int128(x), Int128(y))
    square = [g(0, 0), g(4, 0), g(4, 4), g(0, 4)]
    crossing = [g(0, 0), g(4, 4), g(0, 4), g(4, 0)]

    @test orient_exact(g(0, 0), g(4, 0), g(2, 1)) > 0
    @test segments_intersect_exact(g(0, 0), g(4, 4), g(0, 4), g(4, 0))
    @test !segments_intersect_exact(g(0, 0), g(1, 0), g(2, 0), g(3, 0))
    @test is_simple_exact(square)
    @test !is_simple_exact(crossing)
    @test point_in_polygon_exact(g(2, 2), square) === true
    @test point_in_polygon_exact(g(5, 2), square) === false
    @test ismissing(point_in_polygon_exact(g(0, 2), square))
    @test area_exact(square) == 16

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

    # The former sampled comparator missed this thin triangle entirely. Canonical
    # comparison must reject its disappearance.
    thin = [g(8, 7), g(12, -9), g(11, -4)]
    @test !first(region_equal([thin], Vector{Vector{GridPt}}()))
end
