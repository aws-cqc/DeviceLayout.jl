# Transform, unit, and round-trip laws (catalog §4.3 T1, T4 and §4.4 D1).

@testitem "GeomLaws T1: equivariance under rigid transforms" setup =
    [CommonTestSetup, LawsSetup] tags = [:geomlaws] begin
    # T(A ∪ B) ≐ T(A) ∪ T(B), likewise for ∖ and offset. Quarter turns, reflections,
    # and integer translations map the integer lattice to itself, so the law is exact
    # there; floats are rotated with `cos(π/2) ≈ 6e-17` and re-round to the same fm
    # points, but the rotated inputs may round differently from the rotated outputs,
    # so the float variants are within one lattice unit. Arbitrary rotations are
    # float-only.
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
    @lawcheck function equivariant_float(
        pair=float_star_pair,
        t=rigid_transform,
        θ=Data.Floats{Float64}(; minimum=0.0, maximum=2π, nans=false, infs=false)
    )
        A, B = pair
        tf = t ∘ Rotation(θ)
        u, d = union2d([A], [B]), difference2d([A], [B])
        return first(region_within(union2d([tf(A)], [tf(B)]), transformed(tf, u), 1)) &&
               first(region_within(difference2d([tf(A)], [tf(B)]), transformed(tf, d), 1))
    end
end

@testitem "GeomLaws T4: coordinate-unit invariance" setup = [CommonTestSetup, LawsSetup] tags =
    [:geomlaws] begin
    # One integer polygon expressed in nm, μm, and mm (all exactly representable) must
    # give lattice-identical results, and identical to the unitless Float64 (μm) path:
    # `clipperize` maps every one of them to the same fm lattice.
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
