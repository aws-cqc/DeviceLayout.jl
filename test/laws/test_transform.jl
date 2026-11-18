# Transform, unit, and round-trip laws. README.md lists every law.

@testitem "GeomLaws T1: equivariance under rigid transforms" setup =
    [CommonTestSetup, LawsSetup] tags = [:geomlaws] begin
    # T(A ∪ B) ≐ T(A) ∪ T(B), likewise for ∖ and offset. Quarter turns, reflections,
    # and integer translations map the integer lattice to itself, so the law is exact
    # there. Floats are rotated with `cos(π/2) ≈ 6e-17`, and the rotated output is
    # rounded twice (by the kernel, then onto the lattice after rotating) where the
    # union of the rotated inputs is rounded once, so the float variants are within two
    # lattice units. Arbitrary rotations are float-only; the far variant also moves the
    # pair up to 1 cm from the origin, where Float64 still resolves about 0.002 fm.
    # Transform the tree contours, not the keyhole polygons, so the comparison is
    # contour-to-contour.
    transformed(t, cp::ClippedPolygon) = [t(p) for p in contour_polygons(cp)]
    transformed(t, ps::Vector{<:Polygon}) = [t(p) for p in ps]
    transformed_exact(t, cp::ClippedPolygon) =
        [apply_exact(t, p) for p in contour_polygons(cp)]
    @lawcheck function equivariant_int(
        pair=int_rectilinear_pair,
        t=rigid_transform,
        δ=Data.Integers(1, 4)
    )
        A, B = pair
        tA, tB = apply_exact(t, A), apply_exact(t, B)
        u, d, o = union2d([A], [B]), difference2d([A], [B]), offset([A], δ)
        return region_same(union2d([tA], [tB]), transformed_exact(t, u)) &&
               region_same(difference2d([tA], [tB]), transformed_exact(t, d)) &&
               region_same(offset([tA], δ), [apply_exact(t, p) for p in o])
    end
    @lawcheck function equivariant_int_star(pair=int_pair, t=rigid_transform)
        A, B = pair
        tA, tB = apply_exact(t, A), apply_exact(t, B)
        return first(
            region_within(union2d([tA], [tB]), transformed_exact(t, union2d([A], [B])), 1)
        )
    end
    function equivariant_within(A, B, tf, tol)
        u, d = union2d([A], [B]), difference2d([A], [B])
        return first(region_within(union2d([tf(A)], [tf(B)]), transformed(tf, u), tol)) &&
               first(region_within(difference2d([tf(A)], [tf(B)]), transformed(tf, d), tol))
    end
    @lawcheck function equivariant_float(
        pair=float_star_pair,
        t=rigid_transform,
        θ=gen_turn
    )
        return equivariant_within(pair..., t ∘ Rotation(θ), 2)
    end
    @lawcheck function equivariant_far(
        pair=float_star_pair,
        t=rigid_transform,
        θ=gen_turn,
        far=Data.Vectors(Data.Integers(-10, 10); min_size=2, max_size=2)
    )
        tf = Translation(Point(1000.0far[1], 1000.0far[2])) ∘ t ∘ Rotation(θ)
        return equivariant_within(pair..., tf, 2)
    end
end

@testitem "GeomLaws T2: coordinate-unit invariance" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    # One integer polygon expressed in nm, μm, and mm must give lattice-identical
    # results, and identical to the unitless Float64 (μm) path: `clipperize` maps every
    # one of them to the same fm lattice points. The mm coordinates are not exact, but
    # they are off by far less than half a lattice unit.
    @lawcheck function unit_invariant(pair=int_pair, δ=Data.Integers(1, 4))
        A, B = pair
        Af, Bf = Polygon(Point{Float64}.(A.p)), Polygon(Point{Float64}.(B.p))
        ref_u = canonical_region(togrid(union2d([Af], [Bf])))
        ref_o = canonical_region(togrid(offset([Af], Float64(δ))))
        for u in UNIT_CHOICES
            Au, Bu = with_unit(A, u), with_unit(B, u)
            canonical_region(togrid(union2d([Au], [Bu]))) == ref_u || return false
            canonical_region(togrid(offset([Au], Float64(δ) * Unitful.μm))) == ref_o ||
                return false
        end
        return true
    end
end

@testitem "GeomLaws D1: prescale round trip" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    # declipperize(clipperize(A)) lands on the same lattice points as A for every
    # coordinate type: exact for integers, within the fm lattice for floats and
    # quantities.
    @lawcheck function round_trip(A=int_polygon, u=Data.SampledFrom(collect(UNIT_CHOICES)))
        Af = Polygon(Point{Float64}.(A.p))
        Au = with_unit(A, u)
        Aq = Polygon([Point(q.x * Unitful.nm, q.y * Unitful.nm) for q in A.p])  # Quantity{Int}
        rt(p) =
            Polygons.declipperize(Polygons.clipperize([p])[1], eltype(p.p).parameters[1])
        return togrid(rt(A)) == togrid(A) &&
               togrid(rt(Af)) == togrid(Af) &&
               togrid(rt(Au)) == togrid(Au) &&
               togrid(rt(Aq)) == togrid(Aq)
    end
end
