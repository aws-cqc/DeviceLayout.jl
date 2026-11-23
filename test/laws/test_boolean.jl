# Boolean-algebra laws over `union2d`, `intersect2d`, `difference2d`, `xor2d`, `clip`,
# `clip_tiled`, and the keyhole cuts of `to_polygons`. README.md lists every law.
#
# Verdict conventions, from calibration at ≥ 1000 examples per family on Clipper1, and
# at 3 × 5000 on Clipper2:
#   * rectilinear integer inputs: every intersection is a lattice point, so the laws
#     hold with no tolerance (`≐`, or `region_same` where the kernel may split or merge
#     contours that touch at a vertex);
#   * identities, self-union, and single-rule fill laws hold with no tolerance on
#     every family — one operation, one rounding, same inputs — except where an
#     integer overlap thinner than a unit is missed (B9, ledger L17). Commutativity is
#     also one operation per side, but it needs a tolerance on stars (B1 explains why);
#   * laws that compose operations (associativity, duality, absorption, mixed fill
#     rules, tiling) hold within one lattice unit on float stars, because each side
#     rounds intersection vertices independently. On integer stars they hold within
#     two: Clipper2's rounded intersection points depend on how the operands are
#     grouped, so the two sides can round the same vertex in opposite directions.

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
    # Within one unit on floats, two on integers (see the verdict conventions above).
    for (gen, tol) in ((int_triple, 2), (float_triple, 1))
        @lawcheck function associates(triple=gen)
            A, B, C = triple
            return first(
                       region_within(
                           union2d(union2d([A], [B]), [C]),
                           union2d([A], union2d([B], [C])),
                           tol
                       )
                   ) &&
                   first(
                       region_within(
                           intersect2d(intersect2d([A], [B]), [C]),
                           intersect2d([A], intersect2d([B], [C])),
                           tol
                       )
                   ) &&
                   first(
                       region_within(
                           union2d([A, B, C]),
                           union2d(union2d([A], [B]), [C]),
                           tol
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
    dual(A, B, C, tol) = first(
        region_within(
            difference2d([A], union2d([B], [C])),
            difference2d(difference2d([A], [B]), [C]),
            tol
        )
    )
    absorb(A, B, tol) =
        first(region_within(union2d(difference2d([A], [B]), [B]), union2d([A], [B]), tol))
    # Within two units on integers (see the verdict conventions above).
    @lawcheck function duality(triple=int_triple)
        return dual(triple..., 2) && absorb(triple[1], triple[2], 2)
    end
    @lawcheck function duality_float(triple=float_triple)
        return dual(triple..., 1)
    end
    # Absorption on floats fails about once in 1000 draws, where Clipper2 fills a hole
    # (ledger L16).
    @law :B6_float @lawcheck function absorption_float(triple=float_triple)
        return absorb(triple[1], triple[2], 1)
    end
end

@testitem "GeomLaws B7: point-membership oracle" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    # For every sampled point off all boundaries, membership in each result must equal
    # the corresponding Boolean combination of memberships in the operands
    # (`boolean_oracle_holds`, which never touches the clipping kernel).
    for gen in (int_pair, int_rectilinear_pair, float_star_pair, float_far_pair)
        @lawcheck function membership(pair=gen)
            A, B = pair
            return boolean_oracle_holds([A], [B])
        end
    end
    @lawcheck function membership_perturbed(triple=float_perturbed_pair)
        A, B, kfm = triple
        return boolean_oracle_holds([A], [B]; tol=kfm + 2)
    end
end

@testitem "GeomLaws B8: output validity" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    # Every output contour is weakly simple (no proper self-crossing), the tree
    # alternates outer/hole, and (`nested`) every hole vertex lies inside or on its
    # parent. Neither is guaranteed when intersection rounding is coarse relative to the
    # geometry: integer inputs (ledger L3, L4) and, rarely, fm-lattice floats (L8; on
    # Clipper1 also L4).
    results(A, B) =
        (union2d([A], [B]), intersect2d([A], [B]), difference2d([A], [B]), xor2d([A], [B]))
    @lawcheck function valid_rectilinear(pair=int_rectilinear_pair)
        return all(c -> valid_output(c; weak=true, nested=true), results(pair...))
    end
    for gen in (float_star_pair, float_far_pair)
        @lawcheck function valid_float(pair=gen)
            return all(c -> valid_output(c; weak=true), results(pair...))
        end
    end
    # Features a few fm wide reproduce L3 on the fm lattice (ledger L8).
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
    @lawcheck function nested_float(pair=float_star_pair)
        return all(c -> valid_output(c; weak=true, nested=true), results(pair...))
    end
end

@testitem "GeomLaws B9: fill rules" setup = [CommonTestSetup, LawsSetup] tags = [:geomlaws] begin
    # Single-rule laws pin what each PolyFillType means for two overlapping simple
    # contours: Positive and NonZero give the union, EvenOdd the symmetric difference,
    # Negative nothing; reversing both contours swaps Positive and Negative. Mixed
    # rules (`pfs ≠ pfc`) must equal normalizing each operand under its own rule first,
    # which is how a kernel with a single fill rule per operation, such as Clipper2
    # (#199), has to implement them.
    # Reversed contours are swept in the opposite direction, so on integer stars an
    # overlap thinner than a unit can be missed in one direction and not the other
    # (ledger L17): within 1 there.
    rev(p) = Polygon(reverse(p.p))
    for (gen, tol) in ((int_pair, 1), (int_rectilinear_pair, 0), (float_star_pair, 0))
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
                   first(
                       region_within(
                           clip(U, [rev(A), rev(B)], ∅; pfs=Clipper.PolyFillTypeNegative),
                           u,
                           tol
                       )
                   ) &&
                   first(
                       region_within(
                           clip(U, [rev(A), rev(B)], ∅; pfs=Clipper.PolyFillTypeNonZero),
                           u,
                           tol
                       )
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
    function mixed_holds(A, B, C, tol)
        mixed = clip(
            Clipper.ClipTypeUnion,
            [A, B],
            [C];
            pfs=Clipper.PolyFillTypeEvenOdd,
            pfc=Clipper.PolyFillTypePositive
        )
        return first(region_within(mixed, union2d(xor2d([A], [B]), [C]), tol))
    end
    # Mixed rules take two operations on each side: within two units on integers (see
    # the verdict conventions above). About once in 10 000 draws, the union on the right
    # fills a hole that the xor leaves between two contours touching at vertices (ledger
    # L16).
    @law :B9_mixed_int @lawcheck function mixed_rules(triple=int_triple)
        return mixed_holds(triple..., 2)
    end
    @lawcheck function mixed_rules(triple=float_triple)
        return mixed_holds(triple..., 1)
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
    # Several holes, some with islands: holes stacked in a column, so a later hole's ray
    # meets an earlier one, holes tied for lowest vertex, and islands that are cut
    # separately. The kernel variant rebuilds the tree by unioning its contours (holes
    # clockwise), on both lattices. On these trees a cut can cross another hole without
    # a warning (ledger L14), so validity is checked separately from the region, and a
    # hole after a warned cut can fail to attach (L15), which leaves no output to check.
    @lawcheck function keyhole_multi(cp=int_multi_holed_polygon)
        event!("tree", togrid(cp))
        out, _ = keyholes_warned(cp)
        return isnothing(out) || first(region_within(out, togrid(cp), 1))
    end
    @law :B11_multi @lawcheck function keyhole_multi_valid(cp=int_multi_holed_polygon)
        event!("tree", togrid(cp))
        out, warned = keyholes_warned(cp)
        return warned || valid_keyholes(out)
    end
    for floating in (false, true)
        @lawcheck function keyhole_multi_kernel(cp=int_multi_holed_polygon)
            polys = contour_polygons(cp)
            floating && (polys = [Polygon(Point{Float64}.(p.p)) for p in polys])
            c = union2d(polys)
            valid_output(c; weak=true, nested=true) || reject!()
            event!("tree", togrid(c))
            out, _ = keyholes_warned(c)
            return isnothing(out) || first(region_within(out, togrid(c), 1))
        end
    end
end

@testitem "GeomLaws B12: kernel output as operand" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    # A result's rounded intersection vertices lie within a lattice unit of its operands'
    # edges, so clipping it against an operand again reaches near-coincident edges that
    # independent operands almost never produce. B6's absorption law is one such
    # combination; it found the Clipper2 hole fill of ledger L16. The first result
    # must be a valid tree, whose contours (holes clockwise) then describe it under the
    # positive fill rule, and the second operation is checked against the membership
    # oracle.
    function as_operand_holds(A, B, op, other)
        X = op([A], [B])
        valid_output(X; weak=true, nested=true) || reject!()
        Xp = contour_polygons(X)
        isempty(Xp) && reject!()
        return boolean_oracle_holds(Xp, [other ? A : B])
    end
    ops = Data.SampledFrom([union2d, intersect2d, difference2d, xor2d])
    @lawcheck function output_as_operand(pair=int_pair, op=ops, other=Data.Booleans())
        return as_operand_holds(pair..., op, other)
    end
    # On floats, Clipper2 gets about one draw in 5000 grossly wrong (ledger L16).
    @law :B12_float @lawcheck function output_as_operand(
        pair=float_star_pair,
        op=ops,
        other=Data.Booleans()
    )
        return as_operand_holds(pair..., op, other)
    end
end
