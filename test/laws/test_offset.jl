# Offsetting and halo laws over `offset` and `halo`. README.md lists every law.
#
# Round joins discretize arcs into chords inside the true arc, to a tolerance `atol`:
# 1 nm by default for floating-point coordinates, a quarter unit for integers. Float laws
# pass `atol = |δ| / 200` (`round_atol`), which keeps the arc error small next to the
# features at every scale, and widen their tolerance by `arc_lattice_tol`; O8 pins the
# 1 nm default.
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
    # join type. Containment is checked within two lattice units, one for each side's
    # rounding.
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
    # Offsets that change topology: erosion splits a dumbbell once δ exceeds half its
    # neck, and growth closes a cavity's mouth into a hole. δ is drawn around each
    # threshold.
    @lawcheck function round_oracle_splits(
        shape=int_necked_polygon,
        dk=Data.Integers(-1, 2)
    )
        A, neck = shape
        δ = max(1, cld(neck, 2) + dk)
        return offset_oracle(A, offset([A], -δ; j=Clipper.JoinTypeRound), -δ, 2)
    end
    @lawcheck function round_oracle_encloses(
        shape=int_cavity_polygon,
        dk=Data.Integers(-1, 2)
    )
        A, mouth = shape
        δ = max(1, cld(mouth, 2) + dk)
        return offset_oracle(A, offset([A], δ; j=Clipper.JoinTypeRound), δ, 2)
    end
    @lawcheck function round_oracle_float(
        A=float_polygon,
        f=Data.SampledFrom([0.05, 0.2]),
        sgn=Data.SampledFrom([1, -1])
    )
        δ = sgn * f * maximum(p -> max(abs(p.x), abs(p.y)), A.p)
        well_conditioned_offset(A, δ) || reject!()
        atol = round_atol(δ)
        out = offset([A], δ; j=Clipper.JoinTypeRound, atol)
        return offset_oracle(A, out, _gridcoord(δ), 2 + arc_lattice_tol(atol))
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
    # Floating-point coordinates at the default `atol` of 1 nm, with δ well above it.
    @lawcheck function round_chords_float(
        A=int_convex_polygon,
        logscale=Data.Integers(0, 1),
        f=Data.SampledFrom([0.05, 0.2])
    )
        Af = Polygon(Point{Float64}.(A.p) .* (10.0^logscale / GRID_HALF))
        is_convex_exact(togrid(Af)) || reject!()
        δ = f * 10.0^logscale
        out = offset([Af], δ; j=Clipper.JoinTypeRound)
        return round_chords_within(Af, out, _gridcoord(δ), 2 + arc_lattice_tol(0.001))
    end
end

@testitem "GeomLaws O4: join ordering" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    # At convex corners round ⊆ square ⊆ miter for δ > 0. (A miter reaching more than
    # 2δ from its vertex, at corners sharper than 60°, is replaced by the square join;
    # containment still holds.) Stated away from the L7/L10 regime — a turn with
    # sin·δ < 1 followed by a sharp tip — where the kernel's square and miter joins are
    # wrong (see `well_conditioned_offset`).
    @lawcheck function join_order_int(A=int_thick_polygon, δ=Data.Integers(1, 6))
        well_conditioned_offset(A, δ) || reject!()
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
    # Stated away from the L7 regime, within `offset_tol` of the first result plus, on
    # floats, both arc discretizations.
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
    @lawcheck function closing_round_float(A=float_polygon, f=Data.SampledFrom([0.05, 0.2]))
        δ = f * maximum(p -> max(abs(p.x), abs(p.y)), A.p)
        well_conditioned_offset(A, δ) || reject!()
        j, atol = Clipper.JoinTypeRound, round_atol(δ)
        o = offset([A], δ; j, atol)
        tol = offset_tol(o, δ) + 2 * arc_lattice_tol(atol)
        return first(region_subset_within([A], offset(o, -δ; j, atol), tol))
    end
    @lawcheck function opening_round_float(A=float_polygon, f=Data.SampledFrom([0.05, 0.2]))
        δ = f * maximum(p -> max(abs(p.x), abs(p.y)), A.p)
        well_conditioned_offset(A, δ) || reject!()
        j, atol = Clipper.JoinTypeRound, round_atol(δ)
        i = offset([A], -δ; j, atol)
        tol = offset_tol(i, δ) + 2 * arc_lattice_tol(atol)
        return first(region_subset_within(offset(i, δ; j, atol), [A], tol))
    end
end

@testitem "GeomLaws O7: path halos" setup = [CommonTestSetup, LawsSetup] tags = [:geomlaws] begin
    # `halo(pa, δ)` is documented as equivalent to offsetting the path's geometry by δ
    # (`halo_is_offset`). Halos of polygons are `offset` itself and need no law.
    # A `Path` prints without its segments, so each check records them for the
    # counterexample.
    record(pa) = event!("path", [(n.seg, n.sty) for n in pa])
    @lawcheck function halo_offsets(case=path_case)
        pa, fp, δ, _ = case
        record(pa)
        return halo_is_offset(pa, fp, δ)
    end
    # A taper's halo is a taper with both widths increased by 2δ, which keeps δ only
    # along the path's normal: the slanted sides are δ·cos α from the taper, and the
    # square end extension at the narrow end overhangs the miter corner (ledger L12).
    @law :O7_taper @lawcheck function halo_offsets_taper(case=taper_case)
        record(first(case))
        return halo_is_offset(case...)
    end
    # With an inner offset, the halo is the region between the two offsets (ledger L13).
    @law :O7_inner @lawcheck function halo_inner(case=path_case)
        pa, _, δ, δi = case
        record(pa)
        return inner_halo_is_difference(pa, δ, δi)
    end
end

@testitem "GeomLaws O3 reproducer: erosion at sharp tips" setup =
    [CommonTestSetup, LawsSetup] tags = [:geomlaws] begin
    # Erosion of a convex polygon does not depend on the join type: q ∈ offset(A, −δ)
    # iff q ∈ A and dist(q, ∂A) ≥ δ, so the inset of a thin triangle is the triangle
    # bounded by the three inset edges. The differential harness found Clipper2
    # misclassifying tips sharper than acos(0.999) ≈ 2.6° in its concavity test: the
    # inset's tip vertex lands 0.5 δ short of the exact one (a sub-unit-thick sliver,
    # inside the region tolerance) or, on the second triangle, the inset vanishes for
    # every join type. Clipper1 is exact on both.
    for (A, δ, expected) in (
        (
            Polygon(Point{Int}[(0, 0), (1000, 0), (0, 40)]),
            10,
            Polygon(Point{Int}[(10, 10), (500, 10), (10, 30)])
        ),
        (
            Polygon(Point{Int}[(0, 0), (200, 0), (0, 8)]),
            3,
            Polygon(Point{Int}[(3, 3), (50, 3), (3, 5)])
        )
    )
        for j in (Clipper.JoinTypeMiter, Clipper.JoinTypeSquare, Clipper.JoinTypeRound)
            out = offset([A], -δ; j)
            @test !isempty(out)
            @test first(region_within(out, [expected], 2))
        end
    end
end
