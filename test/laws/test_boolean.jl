# Boolean-algebra laws (catalog §4.1) over `union2d`, `intersect2d`, `difference2d`,
# `xor2d`, `clip`, and `clip_tiled`.
#
# Verdict conventions, from calibration at ≥ 1000 examples per family on Clipper1:
#   * rectilinear integer inputs: every intersection is a lattice point, so the laws
#     hold with no tolerance (`≐`, or `region_same` where the kernel may split or merge
#     contours that touch at a vertex);
#   * commutativity, identities, self-union, and single-rule fill laws hold with no
#     tolerance on every family — one operation, one rounding, same inputs;
#   * laws that compose operations (associativity, duality, absorption, mixed fill
#     rules, tiling) hold within one lattice unit on integer and float stars, because
#     each side rounds intersection vertices independently.

@testitem "GeomLaws B1: commutativity" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    # Rectilinear intersections are lattice-exact, so the two operand orders must agree
    # exactly.
    @lawcheck function commutes(pair=int_rectilinear_pair)
        A, B = pair
        return region_same(union2d([A], [B]), union2d([B], [A])) &&
               region_same(intersect2d([A], [B]), intersect2d([B], [A])) &&
               region_same(xor2d([A], [B]), xor2d([B], [A]))
    end
    # On stars an edge crossing can round onto an existing vertex, leaving a sub-unit
    # sliver that the kernel keeps or collapses depending on which operand it swept first;
    # both outputs are within its one-unit rounding of the exact result.
    for gen in (int_pair, float_star_pair)
        @lawcheck function commutes(pair=gen)
            A, B = pair
            return first(region_within(union2d([A], [B]), union2d([B], [A]), 1)) &&
                   first(region_within(intersect2d([A], [B]), intersect2d([B], [A]), 1)) &&
                   first(region_within(xor2d([A], [B]), xor2d([B], [A]), 1))
        end
    end
    # Near-coincident edges (B is A with one vertex moved kfm lattice units) make every
    # intersection ill-conditioned by geometry; see `float_perturbed_pair`.
    @lawcheck function commutes_perturbed(triple=float_perturbed_pair)
        A, B, kfm = triple
        tol = kfm + 2
        return first(region_within(union2d([A], [B]), union2d([B], [A]), tol)) &&
               first(region_within(intersect2d([A], [B]), intersect2d([B], [A]), tol)) &&
               first(region_within(xor2d([A], [B]), xor2d([B], [A]), tol))
    end
end

@testitem "GeomLaws B2: associativity" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    # Two operands touching along an edge may come back as one merged contour or as
    # two contours sharing the edge, depending on the order the kernel saw them; both
    # describe the same region, so the exact variant compares regions at tolerance 0
    # rather than canonical contours.
    @lawcheck function associates_exact(triple=int_rectilinear_triple)
        A, B, C = triple
        return region_same(
                   union2d(union2d([A], [B]), [C]),
                   union2d([A], union2d([B], [C]))
               ) &&
               region_same(
                   intersect2d(intersect2d([A], [B]), [C]),
                   intersect2d([A], intersect2d([B], [C]))
               ) &&
               region_same(union2d([A, B, C]), union2d(union2d([A], [B]), [C]))
    end
    for gen in (int_triple, float_triple)
        @lawcheck function associates(triple=gen)
            A, B, C = triple
            return first(
                       region_within(
                           union2d(union2d([A], [B]), [C]),
                           union2d([A], union2d([B], [C])),
                           1
                       )
                   ) &&
                   first(
                       region_within(
                           intersect2d(intersect2d([A], [B]), [C]),
                           intersect2d([A], intersect2d([B], [C])),
                           1
                       )
                   ) &&
                   first(
                       region_within(
                           union2d([A, B, C]),
                           union2d(union2d([A], [B]), [C]),
                           1
                       )
                   )
        end
    end
end

@testitem "GeomLaws B3: idempotence and normal form" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    # Self-union is the identity and union output is a fixed point of union: this is
    # the normal form `clip_tiled` and autofill rely on.
    for gen in (int_thick_polygon, int_rectilinear_polygon, float_polygon)
        @lawcheck function self_union(A=gen)
            return union2d([A], [A]) ≐ [A] && intersect2d([A], [A]) ≐ [A]
        end
    end
    @lawcheck function normal_form_exact(pair=int_rectilinear_pair)
        A, B = pair
        u = union2d([A], [B])
        return region_same(union2d(u), u)
    end
    # A rounded intersection vertex can leave a sub-unit spike in the union; re-union
    # may drop it. Within 1.
    for gen in (int_pair, float_star_pair)
        @lawcheck function normal_form(pair=gen)
            A, B = pair
            u = union2d([A], [B])
            # A self-crossing output (B8, ledger L3) is re-interpreted by the fill rule
            # on re-union; that is B8's finding, not this law's.
            valid_output(u; weak=true) || reject!()
            return first(region_within(union2d(u), u, 1))
        end
    end
    @lawcheck function union_of_set(polys=int_polygon_set)
        folded =
            foldl((acc, p) -> union2d(acc, [p]), polys[2:end]; init=union2d([polys[1]]))
        return first(region_within(union2d(polys), folded, 1))
    end
    # Thin integer polygons (a vertex within a lattice unit of a non-adjacent edge) may
    # vanish under the identity union: ledger L1.
    @law :B3_int_thin @lawcheck function self_union_thin(A=int_polygon)
        return union2d([A], [A]) ≐ [A]
    end
end

@testitem "GeomLaws B4: identity and annihilator" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    for gen in (int_thick_polygon, int_rectilinear_polygon, float_polygon)
        @lawcheck function identities(A=gen)
            T = eltype(A.p).parameters[1]
            ∅ = Polygon{T}[]
            return union2d([A], ∅) ≐ [A] &&
                   difference2d([A], ∅) ≐ [A] &&
                   isempty(togrid(intersect2d([A], ∅))) &&
                   isempty(togrid(difference2d([A], [A]))) &&
                   isempty(togrid(xor2d([A], [A])))
        end
    end
end

@testitem "GeomLaws B5: area partition" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    # area(A∩B) + area(A⊕B) = area(A∪B) and area(A∖B) + area(A∩B) = area(A), on the tree
    # contours (so the keyhole step is not involved). Exact for rectilinear integer
    # inputs; otherwise each output rounds its intersection vertices independently, so
    # the residual is bounded by half a lattice unit along the input perimeters
    # (calibrated maximum 0.11 of the perimeter sum).
    @lawcheck function partition_exact(pair=int_rectilinear_pair)
        A, B = pair
        a(x) = region_area_exact(togrid(x))
        u, i, d, x = union2d([A], [B]),
        intersect2d([A], [B]),
        difference2d([A], [B]),
        xor2d([A], [B])
        return a(i) + a(x) == a(u) && a(d) + a(i) == a([A])
    end
    for gen in (int_pair, float_star_pair)
        @lawcheck function partition(pair=gen)
            A, B = pair
            a(x) = region_area_exact(togrid(x))
            u, i, d, x = union2d([A], [B]),
            intersect2d([A], [B]),
            difference2d([A], [B]),
            xor2d([A], [B])
            budget = (perimeter_exact(togrid(A)) + perimeter_exact(togrid(B))) / 2
            return Float64(abs(a(i) + a(x) - a(u))) <= budget &&
                   Float64(abs(a(d) + a(i) - a([A]))) <= budget
        end
    end
end

@testitem "GeomLaws B6: difference–union duality and absorption" setup =
    [CommonTestSetup, LawsSetup] tags = [:geomlaws] begin
    @lawcheck function duality_exact(triple=int_rectilinear_triple)
        A, B, C = triple
        return region_same(
            difference2d([A], union2d([B], [C])),
            difference2d(difference2d([A], [B]), [C])
        ) && region_same(union2d(difference2d([A], [B]), [B]), union2d([A], [B]))
    end
    for gen in (int_triple, float_triple)
        @lawcheck function duality(triple=gen)
            A, B, C = triple
            return first(
                region_within(
                    difference2d([A], union2d([B], [C])),
                    difference2d(difference2d([A], [B]), [C]),
                    1
                )
            ) && first(
                region_within(union2d(difference2d([A], [B]), [B]), union2d([A], [B]), 1)
            )
        end
    end
end

@testitem "GeomLaws B6 fixed: hole beside a coincident edge" setup =
    [CommonTestSetup, LawsSetup] tags = [:geomlaws] begin
    # The subject's edges v₁v₂ and v₄v₅ run along the clip edge c₂c₃ less than one unit
    # inside it, and the concavity v₂v₃v₄ between them encloses, with that edge, a
    # triangle that is in neither operand. Found by the B6 absorption law as
    # `(A ∖ B) ∪ B` at 5000 examples on Clipper2 2.0.1 (and its `main` of 2026-04):
    # `FixSelfIntersects` sees the touching point as a two-edge self-intersection and
    # `DoSplitOp` deletes the split-off loop whenever its orientation is opposite to
    # the parent's, however large — the hole is filled and v₃, v₄ vanish. Clipper1
    # returns the region correctly. The two operands overlap only in the sub-unit
    # sliver along the shared edge, so their even-odd region is the union within 1.
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
        @test first(region_within(out, [S, C], 1))
    end
end

@testitem "GeomLaws B7: point-membership oracle" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    # For every sampled point off all boundaries, membership in each result must equal
    # the corresponding Boolean combination of memberships in the operands. The
    # right-hand side never touches the clipping kernel. Examples where no probe
    # lands inside both operands are rejected rather than passed.
    function oracle_holds(A, B; tol=1)
        gA, gB = [togrid(A)], [togrid(B)]
        results = (
            (togrid(union2d([A], [B])), |),
            (togrid(intersect2d([A], [B])), &),
            (togrid(difference2d([A], [B])), (a, b) -> a & !b),
            (togrid(xor2d([A], [B])), ⊻)
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
    for gen in (int_pair, int_rectilinear_pair, float_star_pair)
        @lawcheck function membership(pair=gen)
            return oracle_holds(pair...)
        end
    end
    @lawcheck function membership_perturbed(triple=float_perturbed_pair)
        A, B, kfm = triple
        return oracle_holds(A, B; tol=kfm + 2)
    end
end

@testitem "GeomLaws B8: output validity" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    # Every output contour is weakly simple (no proper self-crossing), the tree
    # alternates outer/hole, and (`nested`) every hole vertex lies inside or on its
    # parent. Clipper1 guarantees neither when intersection rounding is coarse relative
    # to the geometry: integer inputs (ledger L3, L4) and, rarely, fm-lattice floats.
    results(A, B) =
        (union2d([A], [B]), intersect2d([A], [B]), difference2d([A], [B]), xor2d([A], [B]))
    @lawcheck function valid_rectilinear(pair=int_rectilinear_pair)
        return all(c -> valid_output(c; weak=true, nested=true), results(pair...))
    end
    @lawcheck function valid_float(pair=float_star_pair)
        return all(c -> valid_output(c; weak=true), results(pair...))
    end
    # Features one or two fm wide reproduce L3 on the fm lattice (ledger L8).
    @law :B8_float_perturbed @lawcheck function valid_float_perturbed(
        triple=float_perturbed_pair
    )
        A, B, _ = triple
        return all(c -> valid_output(c; weak=true), results(A, B))
    end
    @law :B8_int @lawcheck function valid_int(pair=int_pair)
        return all(c -> valid_output(c; weak=true), results(pair...))
    end
    @law :B8_nested @lawcheck function nested_int(pair=int_pair)
        return all(c -> valid_output(c; weak=true, nested=true), results(pair...))
    end
    @law :B8_nested @lawcheck function nested_float(pair=float_star_pair)
        return all(c -> valid_output(c; weak=true, nested=true), results(pair...))
    end
end

@testitem "GeomLaws B9: fill rules" setup = [CommonTestSetup, LawsSetup] tags = [:geomlaws] begin
    # Single-rule laws pin what each PolyFillType means for two overlapping simple
    # contours: Positive and NonZero give the union, EvenOdd the symmetric difference,
    # Negative nothing; reversing both contours swaps Positive and Negative. Mixed
    # rules (`pfs ≠ pfc`) must equal normalizing each operand under its own rule first,
    # which is how the Clipper2 shim implements them (`_normalize_clip_fill`).
    rev(p) = Polygon(reverse(p.p))
    for gen in (int_pair, int_rectilinear_pair, float_star_pair)
        @lawcheck function single_rule(pair=gen)
            A, B = pair
            T = eltype(A.p).parameters[1]
            ∅ = Polygon{T}[]
            U = Clipper.ClipTypeUnion
            u, x = union2d([A], [B]), xor2d([A], [B])
            return region_same(clip(U, [A, B], ∅; pfs=Clipper.PolyFillTypePositive), u) &&
                   region_same(clip(U, [A, B], ∅; pfs=Clipper.PolyFillTypeNonZero), u) &&
                   region_same(clip(U, [A, B], ∅; pfs=Clipper.PolyFillTypeEvenOdd), x) &&
                   isempty(togrid(clip(U, [A, B], ∅; pfs=Clipper.PolyFillTypeNegative))) &&
                   region_same(
                       clip(U, [rev(A), rev(B)], ∅; pfs=Clipper.PolyFillTypeNegative),
                       u
                   ) &&
                   region_same(
                       clip(U, [rev(A), rev(B)], ∅; pfs=Clipper.PolyFillTypeNonZero),
                       u
                   ) &&
                   isempty(
                       togrid(
                           clip(U, [rev(A), rev(B)], ∅; pfs=Clipper.PolyFillTypePositive)
                       )
                   ) &&
                   clip(
                       U,
                       [A],
                       [B];
                       pfs=Clipper.PolyFillTypePositive,
                       pfc=Clipper.PolyFillTypeNegative
                   ) ≐ union2d([A])
        end
    end
    @lawcheck function mixed_rules_exact(triple=int_rectilinear_triple)
        A, B, C = triple
        mixed = clip(
            Clipper.ClipTypeUnion,
            [A, B],
            [C];
            pfs=Clipper.PolyFillTypeEvenOdd,
            pfc=Clipper.PolyFillTypePositive
        )
        return region_same(mixed, union2d(xor2d([A], [B]), [C]))
    end
    for gen in (int_triple, float_triple)
        @lawcheck function mixed_rules(triple=gen)
            A, B, C = triple
            mixed = clip(
                Clipper.ClipTypeUnion,
                [A, B],
                [C];
                pfs=Clipper.PolyFillTypeEvenOdd,
                pfc=Clipper.PolyFillTypePositive
            )
            return first(region_within(mixed, union2d(xor2d([A], [B]), [C]), 1))
        end
    end
end

@testitem "GeomLaws B10: tiled clipping" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    # `clip_tiled` splits entities at tile edges with `intersect2d` before clipping, so
    # each tile edge adds a rounding step at the seam: within one lattice unit.
    @lawcheck function tiled(
        polys=float_polygon_set,
        tile=Data.SampledFrom([7.0, 15.0, 40.0])
    )
        length(polys) >= 2 || reject!()
        a = polys[1:cld(end, 2)]
        b = polys[(cld(end, 2) + 1):end]
        tu = collect(Polygons.clip_tiled(Clipper.ClipTypeUnion, a, b, tile))
        td = collect(Polygons.clip_tiled(Clipper.ClipTypeDifference, a, b, tile))
        return first(region_within(union2d(tu), union2d(a, b), 1)) &&
               first(region_within(union2d(td), difference2d(a, b), 1))
    end
end

@testitem "GeomLaws B11: keyhole cuts" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    # `to_polygons(::ClippedPolygon)` cuts each hole into its parent along a ray from
    # the hole's lowest vertex (`interiorcuts`). The cut point is rounded to the
    # lattice, so the keyhole polygons agree with the tree within one unit. The rounded
    # cut can make a keyhole polygon self-intersect; `to_polygons` then warns, and the
    # law accepts that output only with the warning (ledger L11). Trees whose holes are
    # not nested in their parents (ledger L4) are rejected here: that is B8's finding,
    # and on such trees `to_polygons` throws (ledger L5).
    @lawcheck function keyhole_built(cp=int_holed_polygon)
        out, warned = keyholes_warned(cp)
        event!("tree", togrid(cp))
        event!("keyhole", out)
        return (warned || valid_keyholes(out)) && first(region_within(out, togrid(cp), 1))
    end
    # The direct tree guarantees a hole without conditioning on a rare overlap of
    # unrelated stars. Clipping its outer/hole contours still exercises kernel trees.
    for floating in (false, true)
        @lawcheck function keyhole_kernel(cp=int_holed_polygon)
            outer, hole = contour_polygons(cp)
            if floating
                outer = Polygon(Point{Float64}.(outer.p))
                hole = Polygon(Point{Float64}.(hole.p))
            end
            c = difference2d([outer], [Polygon(reverse(hole.p))])
            valid_output(c; weak=true, nested=true) || reject!()
            # Integer clipping may erase a thin hole (L1). B11 needs a hole to cut;
            # budget enforcement prevents this precondition from starving the check.
            any(Clipper.ishole, tree_nodes(c)) || reject!()
            out, warned = keyholes_warned(c)
            event!("tree", togrid(c))
            event!("keyhole", out)
            return (warned || valid_keyholes(out)) &&
                   first(region_within(out, togrid(c), 1))
        end
    end
end
