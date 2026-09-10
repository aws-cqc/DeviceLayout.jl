# Offsetting and halo laws (catalog §4.2) over `offset` and `halo`.
#
# Round joins are exercised only on integer polygons. Clipper's arc tolerance is a
# fixed 0.25 lattice units, so on the fm lattice a round join at δ = 1 μm produces
# ~1.4·10⁵ vertices per full turn (`offset([10 μm square], 1.0; j=JoinTypeRound)` has
# 140 164 vertices), and shrinking such an output back hangs in Clipper1's
# intersection fixup for minutes. Both are recorded in the phase-1 report; laws that
# would trip them are stated on the integer lattice, where the same joins give a
# dozen vertices.
#
# Tolerances: an offset is a raw outline whose vertices are rounded to the lattice,
# followed by a union that rounds again, so a single offset result can sit two lattice
# units from the true offset curve and every tolerance here is 2 per offset result.

@testitem "GeomLaws O1: zero offset" setup = [CommonTestSetup, LawsSetup] tags = [:geomlaws] begin
    for gen in (int_thick_polygon, int_rectilinear_polygon, float_polygon)
        @lawcheck function zero_offset(A=gen)
            return offset([A], zero(eltype(A.p).parameters[1])) ≐ [A] &&
                   offset([A], zero(eltype(A.p).parameters[1]); j=Clipper.JoinTypeRound) ≐
                   [A]
        end
    end
    # `offset` unions its result, so thin integer polygons vanish exactly as in B3.
    @law :O1_int_thin @lawcheck function zero_offset_thin(A=int_polygon)
        return offset([A], 0) ≐ [A]
    end
end

@testitem "GeomLaws O2: monotonicity" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    # offset(A, δ₁) ⊆ offset(A, δ₂) for δ₁ < δ₂, including δ = 0 (A itself), for every
    # join type. Containment is checked at one lattice unit: each side rounds once.
    joins = (Clipper.JoinTypeMiter, Clipper.JoinTypeSquare, Clipper.JoinTypeRound)
    @lawcheck function monotone_int(
        A=int_thick_polygon,
        δ=Data.Integers(1, 6),
        j=Data.SampledFrom(joins)
    )
        o1, o2 = offset([A], δ; j), offset([A], 2δ; j)
        i1, i2 = offset([A], -δ; j), offset([A], -2δ; j)
        return first(region_subset_within(o1, o2, 2)) &&
               first(region_subset_within([A], o1, 2)) &&
               first(region_subset_within(i1, [A], 2)) &&
               first(region_subset_within(i2, i1, 2))
    end
    @lawcheck function monotone_float(
        A=float_polygon,
        f=Data.SampledFrom([0.05, 0.2]),
        j=Data.SampledFrom(joins[1:2])
    )
        δ = f * maximum(p -> max(abs(p.x), abs(p.y)), A.p)
        o1, o2 = offset([A], δ; j), offset([A], 2δ; j)
        i1 = offset([A], -δ; j)
        return first(region_subset_within(o1, o2, 2)) &&
               first(region_subset_within([A], o1, 2)) &&
               first(region_subset_within(i1, [A], 2))
    end
end

@testitem "GeomLaws O3: round-join distance oracle" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    # q ∈ offset(A, δ) ⟺ dist(q, A) ≤ δ for δ > 0, and q ∈ offset(A, −δ) ⟺ q ∈ A with
    # dist(q, ∂A) ≥ δ. This is a sampled membership oracle, with an additional vertex
    # check. O8 separately certifies entire output chords; matching these samples does
    # not establish an exhaustive discretization bound.
    function offset_oracle(A, out, δ, tol)
        gA, gO = togrid([A]), togrid(out)
        nvertices(gO) <= MAX_VERTICES || return false
        for v in gO, q in v
            offset_class(q, gA, δ, tol) == :band || return false
        end
        for q in sample_points(gA, gO; step=tol + 1)
            near_boundary(q, tol, gO) && continue
            c = offset_class(q, gA, δ, tol)
            c == :band && continue
            m = point_in_region_exact(q, gO)
            ismissing(m) && continue
            (c == :in) == m || return false
        end
        return true
    end
    # Holds wherever |δ|·sin(turn) ≥ 1 at every vertex; below that Clipper can leave
    # the original vertex of a sharp corner in the output (ledger L7), a genuine
    # deviation of up to δ from the offset curve rather than a discretization artifact.
    @lawcheck function round_oracle(
        A=int_thick_polygon,
        δ=Data.Integers(1, 8),
        sgn=Data.SampledFrom([1, -1])
    )
        well_conditioned_offset(A, δ) || reject!()
        return offset_oracle(A, offset([A], sgn * δ; j=Clipper.JoinTypeRound), sgn * δ, 2)
    end
    @lawcheck function round_oracle_rectilinear(
        A=int_rectilinear_polygon,
        δ=Data.Integers(1, 8),
        sgn=Data.SampledFrom([1, -1])
    )
        return offset_oracle(A, offset([A], sgn * δ; j=Clipper.JoinTypeRound), sgn * δ, 2)
    end
    @law :O3_int_sharp @lawcheck function round_oracle_sharp(
        A=int_thick_polygon,
        δ=Data.Integers(1, 8)
    )
        well_conditioned_offset(A, δ) && reject!()
        return offset_oracle(A, offset([A], δ; j=Clipper.JoinTypeRound), δ, 2)
    end
end

@testitem "GeomLaws O8: full-chord round-offset bound" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    # Two lattice units is the conformance budget, including rounding; this is not a
    # measurement of Clipper's unrounded 0.25 arc tolerance. Positive convex offsets
    # have no merging fronts: source-distance residual equals offset-boundary distance
    # outside A. Nonconvex inputs and erosion remain in the sampled O3 law.
    for gen in (int_convex_polygon, int_rectangle_polygon)
        @lawcheck function round_chords(A=gen, δ=Data.Integers(3, 8))
            well_conditioned_offset(A, δ) || reject!()
            out = offset([A], δ; j=Clipper.JoinTypeRound)
            return round_chords_within(A, out, δ, 2)
        end
    end
end

@testitem "GeomLaws O4: join ordering" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    # At convex corners round ⊆ square ⊆ miter for δ > 0. (Miter is limited to 2δ, so
    # very sharp corners get a square-like cut farther out than the square join's;
    # containment still holds.)
    @lawcheck function join_order_int(A=int_thick_polygon, δ=Data.Integers(1, 6))
        r = offset([A], δ; j=Clipper.JoinTypeRound)
        s = offset([A], δ; j=Clipper.JoinTypeSquare)
        m = offset([A], δ; j=Clipper.JoinTypeMiter)
        return first(region_subset_within(r, s, 2)) && first(region_subset_within(s, m, 2))
    end
    @lawcheck function join_order_float(A=float_polygon, f=Data.SampledFrom([0.05, 0.2]))
        δ = f * maximum(p -> max(abs(p.x), abs(p.y)), A.p)
        s = offset([A], δ; j=Clipper.JoinTypeSquare)
        m = offset([A], δ; j=Clipper.JoinTypeMiter)
        return first(region_subset_within(s, m, 2))
    end
end

@testitem "GeomLaws O5: semigroup" setup = [CommonTestSetup, LawsSetup] tags = [:geomlaws] begin
    # offset(offset(A, δ), δ) agrees with offset(A, 2δ) for δ > 0: exactly true for
    # round joins (Minkowski sum with a disk), and for miter joins as long as no corner
    # hits the miter limit (2δ, i.e. corners sharper than 60°), where the clamp depends
    # on δ. Both sides are offset results, and the left side offsets an offset: within
    # `offset_tol`. Stated away from the L7 regime.
    function semigroup_holds(A, δ, j)
        well_conditioned_offset(A, δ) || reject!()
        o = offset([A], δ; j)
        return first(region_within(offset(o, δ; j), offset([A], 2δ; j), offset_tol(o, δ)))
    end
    @lawcheck function semigroup_round(A=int_thick_polygon, δ=Data.Integers(1, 6))
        return semigroup_holds(A, δ, Clipper.JoinTypeRound)
    end
    @lawcheck function semigroup_miter_int(A=int_thick_polygon, δ=Data.Integers(1, 6))
        min_corner_angle(A) >= π / 3 || reject!()
        return semigroup_holds(A, δ, Clipper.JoinTypeMiter)
    end
    @lawcheck function semigroup_miter_float(
        A=float_polygon | float_rectangle_polygon,
        f=Data.SampledFrom([0.05, 0.2])
    )
        min_corner_angle(A) >= π / 3 || reject!()
        δ = f * maximum(p -> max(abs(p.x), abs(p.y)), A.p)
        return semigroup_holds(A, δ, Clipper.JoinTypeMiter)
    end
end

@testitem "GeomLaws O6: opening and closing" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    # Grow-then-shrink contains A and shrink-then-grow is contained in A — for round
    # joins, where they are the morphological closing and opening. Neither is a theorem
    # for miter or square joins: erosion with those joins cuts deeper than a disk at a
    # concave vertex of the grown polygon, and when such a vertex sits within δ of A
    # (a short edge next to a reflex vertex) the closing clips A — e.g. the 9-gon
    # `(20,0),(37.1,0),(28.1,2.7),(19,6.4),(23.1,25.7),(14.2,55.6),(-3.4,19.7),
    # (-45.7,-36.4),(20,-0.8)` at δ = 11.12 loses a 0.48 μm-deep sliver of itself.
    # Round joins are integer-only (see the header), stated away from the L7 regime,
    # within `offset_tol` of the first result.
    @lawcheck function closing_round(A=int_thick_polygon, δ=Data.Integers(1, 6))
        well_conditioned_offset(A, δ) || reject!()
        j = Clipper.JoinTypeRound
        o = offset([A], δ; j)
        return first(region_subset_within([A], offset(o, -δ; j), offset_tol(o, δ)))
    end
    @lawcheck function opening_round(A=int_thick_polygon, δ=Data.Integers(1, 6))
        well_conditioned_offset(A, δ) || reject!()
        j = Clipper.JoinTypeRound
        i = offset([A], -δ; j)
        return first(region_subset_within(offset(i, δ; j), [A], offset_tol(i, δ)))
    end
end

@testitem "GeomLaws O7: halo" setup = [CommonTestSetup, LawsSetup] tags = [:geomlaws] begin
    # halo(A, δ) is offset(A, δ) and halo(A, δo, δi) is offset(A, δo) ∖ offset(A, δi),
    # exactly (same calls, same rounding).
    @lawcheck function halo_int(A=int_thick_polygon, δ=Data.Integers(1, 6))
        return halo([A], δ) ≐ offset([A], δ) &&
               halo([A], δ, -δ) ≐ difference2d(offset([A], δ), offset([A], -δ))
    end
    @lawcheck function halo_float(A=float_polygon, f=Data.SampledFrom([0.05, 0.2]))
        δ = f * maximum(p -> max(abs(p.x), abs(p.y)), A.p)
        return halo([A], δ) ≐ offset([A], δ) &&
               halo([A], δ, δ / 2) ≐ difference2d(offset([A], δ), offset([A], δ / 2))
    end
end
