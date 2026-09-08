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
    @check config = LAWS function union_self(A=int_polygon)
        return union2d([A], [A]) ≐ [A]
    end
    @check config = LAWS function union_normal_form(pair=degenerate_pair)
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
        for q in sample_points(gA, gB, gU)
            near_boundary(q, DEFAULT_δ, gA, gB, gU) && continue
            a = point_in_region_exact(q, gA)
            b = point_in_region_exact(q, gB)
            u = point_in_region_exact(q, gU)
            (ismissing(a) || ismissing(b) || ismissing(u)) && continue
            (a | b) == u || return false
        end
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

@testitem "GeomLaws smoke: generators are well-formed" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    # Guards against the arc-fuzz failure mode: a generator artifact reported as a bug.
    @check config = LAWS function polygons_valid(A=int_polygon)
        return valid_polygon(A) && A.p[1] != A.p[end]
    end
    @check config = LAWS function float_polygons_valid(A=float_star_polygon)
        return valid_polygon(A)
    end
    @check config = LAWS function pairs_valid(pair=degenerate_pair)
        A, B = pair
        return valid_polygon(A) && valid_polygon(B)
    end
end
