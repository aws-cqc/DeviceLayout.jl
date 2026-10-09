@testitem "Postrender" setup = [CommonTestSetup] begin
    import DeviceLayout: CurvilinearRegion, SemanticMeta, coordinatetype

    # Square ring built from four overlapping rectangles: union has one hole.
    ring_polys(T) = [
        Polygon(Point{T}[p(0μm, 0μm), p(10μm, 0μm), p(10μm, 30μm), p(0μm, 30μm)]),
        Polygon(Point{T}[p(20μm, 0μm), p(30μm, 0μm), p(30μm, 30μm), p(20μm, 30μm)]),
        Polygon(Point{T}[p(0μm, 0μm), p(30μm, 0μm), p(30μm, 10μm), p(0μm, 10μm)]),
        Polygon(Point{T}[p(0μm, 20μm), p(30μm, 20μm), p(30μm, 30μm), p(0μm, 30μm)])
    ]

    @testset "round_layer on Cell: union-first, holes, filtering" begin
        c = Cell{typeof(1.0nm)}("rounding")
        # Two adjacent squares sharing a full edge: union-first means the shared edge
        # must not produce rounded-apart corners.
        render!(
            c,
            Polygon(p(0μm, 0μm), p(10μm, 0μm), p(10μm, 10μm), p(0μm, 10μm)),
            GDSMeta(1)
        )
        render!(
            c,
            Polygon(p(10μm, 0μm), p(20μm, 0μm), p(20μm, 10μm), p(10μm, 10μm)),
            GDSMeta(1)
        )
        # Unrelated layer must not participate.
        render!(
            c,
            Polygon(p(0μm, 20μm), p(1μm, 20μm), p(1μm, 21μm), p(0μm, 21μm)),
            GDSMeta(2)
        )

        regions = round_layer(c, GDSMeta(1), 1μm)
        @test regions isa Vector{<:CurvilinearRegion}
        @test length(regions) == 1
        r = only(regions)
        # Only the four outer corners of the merged 20×10 rectangle are rounded.
        @test length(r.exterior.curves) == 4
        @test all(t -> t isa Paths.Turn, r.exterior.curves)
        @test isempty(r.holes)
        # Input cell is untouched by the out-of-place pass.
        @test length(elements(c)) == 3

        # Empty selection.
        @test isempty(round_layer(c, GDSMeta(99), 1μm))

        # Holes are preserved and their corners rounded.
        cring = Cell{typeof(1.0nm)}("ring")
        for poly in ring_polys(typeof(1.0μm))
            render!(cring, poly, GDSMeta(1))
        end
        ring_regions = round_layer(cring, GDSMeta(1), 1μm)
        @test length(ring_regions) == 1
        ring = only(ring_regions)
        @test length(ring.holes) == 1
        @test length(ring.exterior.curves) == 4
        @test length(only(ring.holes).curves) == 4
    end

    @testset "round_layer on Cell: references are flattened" begin
        sub = Cell{typeof(1.0nm)}("sub")
        render!(
            sub,
            Polygon(p(0μm, 0μm), p(10μm, 0μm), p(10μm, 10μm), p(0μm, 10μm)),
            GDSMeta(1)
        )
        top = Cell{typeof(1.0nm)}("top")
        render!(
            top,
            Polygon(p(10μm, 0μm), p(20μm, 0μm), p(20μm, 10μm), p(10μm, 10μm)),
            GDSMeta(1)
        )
        addref!(top, sub)
        regions = round_layer(top, GDSMeta(1), 1μm)
        # The referenced square merges with the top-level square across the shared edge.
        @test length(regions) == 1
        @test length(only(regions).exterior.curves) == 4
    end

    @testset "round_layer on CoordinateSystem: semantic filter, curve preservation" begin
        cs = CoordinateSystem{typeof(1.0nm)}("semantic")
        place!(
            cs,
            Polygon(p(0μm, 0μm), p(10μm, 0μm), p(10μm, 10μm), p(0μm, 10μm)),
            SemanticMeta(:metal)
        )
        place!(
            cs,
            Polygon(p(10μm, 0μm), p(20μm, 0μm), p(20μm, 10μm), p(10μm, 10μm)),
            SemanticMeta(:metal)
        )
        place!(
            cs,
            Polygon(p(0μm, 20μm), p(1μm, 20μm), p(1μm, 21μm), p(0μm, 21μm)),
            SemanticMeta(:other)
        )
        regions = round_layer(cs, SemanticMeta(:metal), 1μm)
        @test length(regions) == 1
        @test length(only(regions).exterior.curves) == 4

        # Curves already present in the input survive the union symbolically: a
        # pre-rounded square keeps its four arcs (its corners are already round, so the
        # pass adds none; tangent line-arc joints are collinear within min_angle).
        cs2 = CoordinateSystem{typeof(1.0nm)}("curved")
        sq = Polygon(p(0μm, 0μm), p(10μm, 0μm), p(10μm, 10μm), p(0μm, 10μm))
        place!(cs2, Polygons.Rounded(2μm)(sq), SemanticMeta(:metal))
        regions2 = round_layer(cs2, SemanticMeta(:metal), 1μm)
        @test length(regions2) == 1
        preserved_curves = only(regions2).exterior.curves
        @test length(preserved_curves) == 4
        @test all(c -> c.r ≈ 2μm, preserved_curves)
    end

    @testset "round_layer! on Cell: render, remap, atol forwarding" begin
        T = typeof(1.0nm)
        c = Cell{T}("inplace")
        render!(
            c,
            Polygon(p(0μm, 0μm), p(10μm, 0μm), p(10μm, 10μm), p(0μm, 10μm)),
            GDSMeta(1)
        )
        render!(
            c,
            Polygon(p(10μm, 0μm), p(20μm, 0μm), p(20μm, 10μm), p(10μm, 10μm)),
            GDSMeta(1)
        )
        round_layer!(
            c,
            GDSMeta(1),
            1μm;
            target_layer=GDSMeta(2),
            remap_originals=GDSMeta(3)
        )
        # Originals retagged (not deleted), rounded result rendered on the target layer.
        @test count(==(GDSMeta(3)), element_metadata(c)) == 2
        @test count(==(GDSMeta(1)), element_metadata(c)) == 0
        new_idx = findall(==(GDSMeta(2)), element_metadata(c))
        @test length(new_idx) == 1
        @test length(points(elements(c)[only(new_idx)])) > 4 # discretized fillets

        # remap with target_layer == layer must not retag the newly rendered elements.
        c2 = Cell{T}("inplace2")
        render!(
            c2,
            Polygon(p(0μm, 0μm), p(10μm, 0μm), p(10μm, 10μm), p(0μm, 10μm)),
            GDSMeta(1)
        )
        round_layer!(
            c2,
            GDSMeta(1),
            1μm;
            target_layer=GDSMeta(1),
            remap_originals=GDSMeta(3)
        )
        @test count(==(GDSMeta(1)), element_metadata(c2)) == 1
        @test count(==(GDSMeta(3)), element_metadata(c2)) == 1

        # atol is forwarded to discretization.
        fine = Cell{T}("fine")
        coarse = Cell{T}("coarse")
        for cc in (fine, coarse)
            render!(
                cc,
                Polygon(p(0μm, 0μm), p(10μm, 0μm), p(10μm, 10μm), p(0μm, 10μm)),
                GDSMeta(1)
            )
        end
        round_layer!(fine, GDSMeta(1), 2μm; target_layer=GDSMeta(2), atol=1nm)
        round_layer!(coarse, GDSMeta(1), 2μm; target_layer=GDSMeta(2), atol=100nm)
        np(cell) = length(
            points(elements(cell)[only(findall(==(GDSMeta(2)), element_metadata(cell)))])
        )
        @test np(fine) > np(coarse)
    end

    @testset "round_layer! on CoordinateSystem: symbolic placement" begin
        cs = CoordinateSystem{typeof(1.0nm)}("inplace_cs")
        place!(
            cs,
            Polygon(p(0μm, 0μm), p(10μm, 0μm), p(10μm, 10μm), p(0μm, 10μm)),
            SemanticMeta(:metal)
        )
        round_layer!(
            cs,
            SemanticMeta(:metal),
            1μm;
            target_layer=SemanticMeta(:metal_rounded),
            remap_originals=SemanticMeta(:metal_original)
        )
        @test count(==(SemanticMeta(:metal_original)), element_metadata(cs)) == 1
        idx = findall(==(SemanticMeta(:metal_rounded)), element_metadata(cs))
        @test length(idx) == 1
        @test elements(cs)[only(idx)] isa CurvilinearRegion # stays symbolic
    end
end

@testitem "split_t_junctions!" setup = [CommonTestSetup] begin
    import DeviceLayout: CurvilinearPolygon, CurvilinearRegion, coordinatetype
    import DeviceLayout.SolidModels

    # A rectangle target with a bottom edge (0,0)→(10,0). Built for coordinate
    # type T (via convert) so the same test runs across unit conventions.
    pT(T, x, y) = convert(Point{T}, p(x * μm, y * μm))
    rect_region(T) = CurvilinearRegion(
        CurvilinearPolygon(
            Point{T}[pT(T, 0, 0), pT(T, 10, 0), pT(T, 10, 10), pT(T, 0, 10)]
        )
    )
    # A 90° arc region: quarter circle radius R (µm) centered at origin, (R,0)→(0,R).
    arc_region(T, R=10) = begin
        turn = Paths.Turn(90°, convert(T, R * μm); α0=90°, p0=pT(T, R, 0))
        CurvilinearRegion(
            CurvilinearPolygon(
                Point{T}[pT(T, R, 0), pT(T, 0, R), pT(T, R, R)],
                [turn],
                [1]
            )
        )
    end

    @testset "injects a foreign vertex on a straight edge" begin
        target = [rect_region(typeof(1.0μm))]
        # Source triangle with a vertex exactly on the target's bottom edge at (5,0).
        source = [
            CurvilinearRegion(
                CurvilinearPolygon(
                    Point{typeof(1.0μm)}[
                        p(4.0μm, -5.0μm),
                        p(5.0μm, 0.0μm),
                        p(6.0μm, -5.0μm)
                    ]
                )
            )
        ]
        n = split_t_junctions!(target, source)
        @test n == 1
        @test length(points(target[1].exterior)) == 5
        @test any(
            q ->
                isapprox(getx(q), 5.0μm; atol=1e-6μm) &&
                    isapprox(gety(q), 0.0μm; atol=1e-6μm),
            points(target[1].exterior)
        )
    end

    @testset "no-op when no source vertex lies on a target edge" begin
        target = [rect_region(typeof(1.0μm))]
        source = [
            CurvilinearRegion(
                CurvilinearPolygon(
                    Point{typeof(1.0μm)}[
                        p(20.0μm, 20.0μm),
                        p(25.0μm, 25.0μm),
                        p(20.0μm, 25.0μm)
                    ]
                )
            )
        ]
        @test split_t_junctions!(target, source) == 0
        @test length(points(target[1].exterior)) == 4
    end

    @testset "no-op on empty target or empty sources" begin
        empty_t = CurvilinearRegion{typeof(1.0μm)}[]
        src = [
            CurvilinearRegion(
                CurvilinearPolygon(
                    Point{typeof(1.0μm)}[p(0μm, 0μm), p(5μm, 5μm), p(0μm, 5μm)]
                )
            )
        ]
        @test split_t_junctions!(empty_t, src) == 0
        @test split_t_junctions!([rect_region(typeof(1.0μm))]) == 0                # no sources
        @test split_t_junctions!(
            [rect_region(typeof(1.0μm))],
            CurvilinearRegion{typeof(1.0μm)}[]
        ) == 0                                                                     # empty source group
    end

    @testset "picks up vertices from source holes" begin
        target = [rect_region(typeof(1.0μm))]
        # Source exterior is far away; its HOLE has a vertex on the target's edge.
        source = [
            CurvilinearRegion(
                CurvilinearPolygon(
                    Point{typeof(1.0μm)}[
                        p(100.0μm, 100.0μm),
                        p(110.0μm, 100.0μm),
                        p(110.0μm, 110.0μm),
                        p(100.0μm, 110.0μm)
                    ]
                ),
                [
                    CurvilinearPolygon(
                        Point{typeof(1.0μm)}[
                            p(102.0μm, 102.0μm),
                            p(5.0μm, 0.0μm),
                            p(108.0μm, 102.0μm)
                        ]
                    )
                ]
            )
        ]
        @test split_t_junctions!(target, source) == 1
    end

    @testset "splits a Turn at a foreign on-arc point, using the EXACT arc point" begin
        target = [arc_region(typeof(1.0μm))]
        R = 10.0
        # Foreign point near 45° on the arc, deliberately a hair OFF the circle
        # (radius 10 + 0.5 nm) to check we snap to the exact on-arc point, not this.
        off = (R + 5e-4)
        src_pt = p((off * cospi(0.25))μm, (off * sinpi(0.25))μm)
        source = [
            CurvilinearRegion(
                CurvilinearPolygon(
                    Point{typeof(1.0μm)}[src_pt, p(20.0μm, 20.0μm), p(20.0μm, 0.0μm)]
                )
            )
        ]
        n = split_t_junctions!(target, source)
        @test n == 1
        @test length(target[1].exterior.curves) == 2   # arc split into two sub-Turns
        # The injected vertex must lie EXACTLY on radius R (the true arc), not at the
        # off-arc source radius — this is what keeps CurvilinearPolygon consistent.
        injected = only(
            filter(
                q ->
                    !any(
                        o -> isapprox(getx(q), getx(o)) && isapprox(gety(q), gety(o)),
                        (p(R * 1μm, 0.0μm), p(0.0μm, R * 1μm), p(R * 1μm, R * 1μm))
                    ),
                points(target[1].exterior)
            )
        )
        r_injected = hypot(getx(injected), gety(injected))
        @test isapprox(r_injected, R * 1μm; atol=1e-6μm)   # on the true arc
        @test !isapprox(r_injected, off * 1μm; atol=1e-6μm) # NOT the off-arc source
    end

    @testset "splits multiple foreign points on one arc, ordered along travel" begin
        target = [arc_region(typeof(1.0μm))]
        R = 10.0
        # Two on-arc points at 30° and 60°.
        a = p((R * cospi(1 / 6))μm, (R * sinpi(1 / 6))μm)
        b = p((R * cospi(1 / 3))μm, (R * sinpi(1 / 3))μm)
        source = [
            CurvilinearRegion(
                CurvilinearPolygon(
                    Point{typeof(1.0μm)}[a, b, p(20.0μm, 20.0μm), p(20.0μm, 0.0μm)]
                )
            )
        ]
        n = split_t_junctions!(target, source)
        @test n == 2
        @test length(target[1].exterior.curves) == 3   # arc split into three sub-Turns
    end

    @testset "orders points correctly on a clockwise arc (hole winding)" begin
        # A CW arc (negative α) — the case where naive angle sorting reverses order.
        # Two on-arc points must still be injected in travel order without error.
        T = typeof(1.0μm)
        R = 10.0μm
        turn = Paths.Turn(-90°, R; α0=0°, p0=p(0.0μm, 0.0μm))
        # endpoints of this CW quarter arc
        e0 = turn(zero(pathlength(turn)))
        e1 = turn(pathlength(turn))
        target = [
            CurvilinearRegion(
                CurvilinearPolygon(Point{T}[e0, e1, p(getx(e1), gety(e0))], [turn], [1])
            )
        ]
        c = Paths.curvaturecenter(turn)
        pa = turn(pathlength(turn) * 0.3)   # two interior on-arc points
        pb = turn(pathlength(turn) * 0.7)
        source = [
            CurvilinearRegion(
                CurvilinearPolygon(Point{T}[pa, pb, p(getx(pa) + 1μm, gety(pa) - 1μm)])
            )
        ]
        n = split_t_junctions!(target, source)
        @test n == 2
        @test length(target[1].exterior.curves) == 3
    end

    @testset "result is invariant across coordinate types (nm vs μm)" begin
        # Same geometry in two coordinate conventions must inject the same number
        # of vertices and land them at the same physical location.
        function run(T)
            target = [rect_region(T)]
            source = [
                CurvilinearRegion(
                    CurvilinearPolygon(Point{T}[pT(T, 4, -5), pT(T, 5, 0), pT(T, 6, -5)])
                )
            ]
            n = split_t_junctions!(target, source)
            return n, points(target[1].exterior)
        end
        n_um, pts_um = run(typeof(1.0μm))
        n_nm, pts_nm = run(typeof(1.0nm))
        @test n_um == n_nm == 1
        @test length(pts_um) == length(pts_nm) == 5
        # The injected (5,0) vertex is at the same physical point regardless of units.
        onedge(pts) = any(
            q ->
                isapprox(getx(q), 5.0μm; atol=1e-6μm) &&
                    isapprox(gety(q), 0.0μm; atol=1e-6μm),
            pts
        )
        @test onedge(pts_um)
        @test onedge(pts_nm)
    end

    @testset "Polygon-vector method injects on straight edges (GDS gap fix)" begin
        T = typeof(1.0μm)
        target = [Polygon(Point{T}[p(0μm, 0μm), p(10μm, 0μm), p(10μm, 10μm), p(0μm, 10μm)])]
        source = [Polygon(Point{T}[p(4μm, -5μm), p(5μm, 0μm), p(6μm, -5μm)])]
        n = split_t_junctions!(target, source)
        @test n == 1
        @test length(points(target[1])) == 5
        @test any(
            q ->
                isapprox(getx(q), 5.0μm; atol=1e-6μm) &&
                    isapprox(gety(q), 0.0μm; atol=1e-6μm),
            points(target[1])
        )
    end

    @testset "leaves an arc untouched when no foreign point lies on it" begin
        # A target carrying a Turn arc, with sources that share no boundary:
        # the arc is carried through unchanged (the isempty(splits) branch).
        target = [arc_region(typeof(1.0μm))]
        source = [
            CurvilinearRegion(
                CurvilinearPolygon(
                    Point{typeof(1.0μm)}[
                        p(100.0μm, 100.0μm),
                        p(110.0μm, 100.0μm),
                        p(110.0μm, 110.0μm)
                    ]
                )
            )
        ]
        @test split_t_junctions!(target, source) == 0
        # The single Turn survives, unmodified.
        @test length(target[1].exterior.curves) == 1
        @test target[1].exterior.curves[1] isa Paths.Turn
    end

    @testset "leaves a BSpline untouched when no source vertex lies on it" begin
        # A BSpline edge with a source vertex only on the STRAIGHT bottom edge:
        # the spline's own edge has no foreign point, so it is carried through
        # unsplit. (A vertex ON the spline WOULD split it — see the next testset.)
        T = typeof(1.0μm)
        pp =
            Point{T}[p(0.0μm, 0.0μm), p(10.0μm, 0.0μm), p(10.0μm, 10.0μm), p(0.0μm, 10.0μm)]
        spline_pts = [pp[2], p(15.0μm, 5.0μm), pp[3]]
        seg = Paths.BSpline(spline_pts, p(1.0μm, 0.0μm), p(-1.0μm, 0.0μm))
        target = [CurvilinearRegion(CurvilinearPolygon(pp, [seg], [2]))]
        # A source vertex on the straight bottom edge (0,0)→(10,0) at x=5.
        source = [
            CurvilinearRegion(
                CurvilinearPolygon(
                    Point{T}[p(4.0μm, -5.0μm), p(5.0μm, 0.0μm), p(6.0μm, -5.0μm)]
                )
            )
        ]
        n = split_t_junctions!(target, source)
        @test n == 1                                   # the straight edge got the vertex
        # The BSpline is still present and was NOT split.
        @test count(c -> c isa Paths.BSpline, target[1].exterior.curves) == 1
    end

    @testset "injects into a TARGET region's hole edge" begin
        # The target region has a hole; a source vertex lands on the hole's edge
        # and must be injected there (the hole loop of split_t_junctions!).
        T = typeof(1.0μm)
        ext = CurvilinearPolygon(
            Point{T}[p(0μm, 0μm), p(30μm, 0μm), p(30μm, 30μm), p(0μm, 30μm)]
        )
        # Square hole (10,10)-(20,20); right edge x=20, y∈[10,20].
        hole = CurvilinearPolygon(
            Point{T}[p(10μm, 10μm), p(10μm, 20μm), p(20μm, 20μm), p(20μm, 10μm)]
        )
        target = [CurvilinearRegion(ext, [hole])]
        # Source has a vertex at (20,15) — interior to the hole's right edge.
        source = [
            CurvilinearRegion(
                CurvilinearPolygon(
                    Point{T}[p(20.0μm, 15.0μm), p(25.0μm, 12.0μm), p(25.0μm, 18.0μm)]
                )
            )
        ]
        n = split_t_junctions!(target, source)
        @test n >= 1
        # The injected vertex is on the hole, not the exterior.
        @test any(
            q ->
                isapprox(getx(q), 20.0μm; atol=1e-6μm) &&
                    isapprox(gety(q), 15.0μm; atol=1e-6μm),
            points(target[1].holes[1])
        )
    end

    @testset "splits a BSpline at a foreign on-curve vertex" begin
        # The shared noding core handles BSpline as well as Turn: a source vertex
        # lying ON the spline splits it into two native BSpline sub-curves (curve
        # preserved, not discretized to chords).
        T = typeof(1.0μm)
        pp =
            Point{T}[p(0.0μm, 0.0μm), p(10.0μm, 0.0μm), p(10.0μm, 10.0μm), p(0.0μm, 10.0μm)]
        spline_pts = [pp[2], p(15.0μm, 5.0μm), pp[3]]
        seg = Paths.BSpline(spline_pts, p(1.0μm, 0.0μm), p(-1.0μm, 0.0μm))
        mid = seg(pathlength(seg) / 2)          # exact on-curve midpoint
        target = [CurvilinearRegion(CurvilinearPolygon(pp, [seg], [2]))]
        source = [
            CurvilinearRegion(
                CurvilinearPolygon(Point{T}[mid, p(25.0μm, 3.0μm), p(25.0μm, 7.0μm)])
            )
        ]
        n = split_t_junctions!(target, source)
        @test n == 1
        # The single BSpline became two native BSpline sub-curves.
        @test count(c -> c isa Paths.BSpline, target[1].exterior.curves) == 2
        @test any(
            q ->
                isapprox(getx(q), getx(mid); atol=1e-6μm) &&
                    isapprox(gety(q), gety(mid); atol=1e-6μm),
            points(target[1].exterior)
        )
    end

    @testset "shared core: (targets, sources) and Dict method agree on a fixture" begin
        # All methods are thin wrappers over the same RTree noding core. On a
        # shared fixture, the asymmetric split_t_junctions!(A, B) must inject
        # into A exactly what the symmetric split_t_junctions!(::Dict) injects
        # into A from B.
        T = typeof(1.0μm)
        mkA() = CurvilinearRegion(
            CurvilinearPolygon(
                Point{T}[
                    p(0.0μm, 0.0μm),
                    p(10.0μm, 0.0μm),
                    p(10.0μm, 10.0μm),
                    p(0.0μm, 10.0μm)
                ]
            )
        )
        mkB() = CurvilinearRegion(
            CurvilinearPolygon(
                Point{T}[
                    p(10.0μm, 0.0μm),
                    p(20.0μm, 0.0μm),
                    p(20.0μm, 10.0μm),
                    p(10.0μm, 10.0μm),
                    p(10.0μm, 5.0μm)  # extra vertex on A's right edge
                ]
            )
        )
        tA = [mkA()]
        n_asym = split_t_junctions!(tA, [mkB()])
        groups = Dict(:a => [mkA()], :b => [mkB()])
        split_t_junctions!(groups)
        onA =
            q ->
                isapprox(getx(q), 10.0μm; atol=1e-6μm) &&
                    isapprox(gety(q), 5.0μm; atol=1e-6μm)
        @test n_asym == 1
        @test any(onA, points(tA[1].exterior))                 # via (targets, sources)
        @test any(onA, points(groups[:a][1].exterior))         # via Dict method
    end

    @testset "corner vertex within tolerance of two edges goes to one edge only" begin
        # Regression for a 30° corner at the origin: a source vertex 3 nm along
        # the bottom edge is also within 1.5 nm perpendicular of the second edge
        # (30° above +x), so both edges' perp tests admit it at the default
        # 2 nm atol. Without corner-shared dedup this would inject the same
        # candidate onto both edges of the target, producing identical
        # non-consecutive vertices around the corner (a zero-length loopback).
        T = typeof(1.0μm)
        c30 = cosd(30) * 10.0μm
        s30 = sind(30) * 10.0μm
        # Target: closed triangle whose 30° corner is at the origin.
        target = [
            CurvilinearRegion(
                CurvilinearPolygon(
                    Point{T}[p(0.0μm, 0.0μm), p(10.0μm, 0.0μm), p(c30, s30)]
                )
            )
        ]
        # Source vertex 3 nm = 0.003 μm along the bottom edge — within default
        # 2 nm atol of the second edge in perpendicular distance too.
        source = [
            CurvilinearRegion(
                CurvilinearPolygon(
                    Point{T}[p(0.003μm, 0.0μm), p(0.1μm, -0.05μm), p(0.05μm, -0.05μm)]
                )
            )
        ]
        n = split_t_junctions!(target, source)
        @test n == 1                                            # NOT 2 (pre-fix behaviour)
        ext_pts = points(target[1].exterior)
        @test length(ext_pts) == 4                              # 3 corners + 1 injection
        near_candidate =
            q ->
                isapprox(getx(q), 0.003μm; atol=1e-9μm) &&
                    isapprox(gety(q), 0.0μm; atol=1e-9μm)
        @test count(near_candidate, ext_pts) == 1               # not 2
    end

    @testset "self-noding (single-vector method) is equivalent to (v, v)" begin
        # A ring of two boxes that meet at x=10 with A carrying an extra vertex
        # at (10, 5) on the seam and B not — self-noding must inject (10, 5)
        # onto B's left edge.
        T = typeof(1.0μm)
        A = CurvilinearRegion(
            CurvilinearPolygon(
                Point{T}[
                    p(0μm, 0μm),
                    p(10μm, 0μm),
                    p(10μm, 5μm),
                    p(10μm, 10μm),
                    p(0μm, 10μm)
                ]
            )
        )
        B = CurvilinearRegion(
            CurvilinearPolygon(
                Point{T}[p(10μm, 0μm), p(20μm, 0μm), p(20μm, 10μm), p(10μm, 10μm)]
            )
        )
        regions = [A, B]
        n = split_t_junctions!(regions)                          # single-argument form
        @test n == 1                                             # A's extra vertex → B
        # B (index 2) picked up (10, 5).
        b_pts = points(regions[2].exterior)
        @test any(
            q ->
                isapprox(getx(q), 10μm; atol=1e-6μm) && isapprox(gety(q), 5μm; atol=1e-6μm),
            b_pts
        )
    end

    # ─── AbstractDict (symmetric all-pairs) method ─────────────────────────

    @testset "Dict method makes two adjacent groups symmetric on a shared edge" begin
        T = typeof(1.0μm)
        A = CurvilinearRegion(
            CurvilinearPolygon(
                Point{T}[p(0μm, 0μm), p(10μm, 0μm), p(10μm, 10μm), p(0μm, 10μm)]
            )
        )
        B = CurvilinearRegion(
            CurvilinearPolygon(
                Point{T}[
                    p(10μm, 0μm),
                    p(20μm, 0μm),
                    p(20μm, 10μm),
                    p(10μm, 10μm),
                    p(10μm, 5μm)
                ]
            )
        )
        groups = Dict(:a => [A], :b => [B])
        n = split_t_junctions!(groups)
        @test n == 1
        a_pts = points(groups[:a][1].exterior)
        @test any(
            q ->
                isapprox(getx(q), 10μm; atol=1e-6μm) && isapprox(gety(q), 5μm; atol=1e-6μm),
            a_pts
        )
        @test length(a_pts) == 5
        b_pts = points(groups[:b][1].exterior)
        @test any(
            q ->
                isapprox(getx(q), 10μm; atol=1e-6μm) && isapprox(gety(q), 5μm; atol=1e-6μm),
            b_pts
        )
    end

    @testset "Dict method is idempotent" begin
        T = typeof(1.0μm)
        A = CurvilinearRegion(
            CurvilinearPolygon(
                Point{T}[p(0μm, 0μm), p(10μm, 0μm), p(10μm, 10μm), p(0μm, 10μm)]
            )
        )
        B = CurvilinearRegion(
            CurvilinearPolygon(
                Point{T}[
                    p(10μm, 0μm),
                    p(20μm, 0μm),
                    p(20μm, 10μm),
                    p(10μm, 10μm),
                    p(10μm, 5μm)
                ]
            )
        )
        groups = Dict(:a => [A], :b => [B])
        @test split_t_junctions!(groups) == 1
        @test split_t_junctions!(groups) == 0
    end

    @testset "Dict method no-op when groups don't touch" begin
        T = typeof(1.0μm)
        A = CurvilinearRegion(
            CurvilinearPolygon(
                Point{T}[p(0μm, 0μm), p(10μm, 0μm), p(10μm, 10μm), p(0μm, 10μm)]
            )
        )
        B = CurvilinearRegion(
            CurvilinearPolygon(
                Point{T}[
                    p(100μm, 100μm),
                    p(110μm, 100μm),
                    p(110μm, 110μm),
                    p(100μm, 110μm)
                ]
            )
        )
        groups = Dict(:a => [A], :b => [B])
        @test split_t_junctions!(groups) == 0
    end

    @testset "Dict method splits a Turn at a foreign vertex on the arc" begin
        T = typeof(1.0μm)
        R = 10.0μm
        turn = Paths.Turn(90°, R, α0=90°, p0=p(R, 0.0μm))
        A = CurvilinearRegion(
            CurvilinearPolygon(Point{T}[p(R, 0.0μm), p(0.0μm, R), p(R, R)], [turn], [1])
        )
        mid = p(R * cos(π / 4), R * sin(π / 4))
        B = CurvilinearRegion(
            CurvilinearPolygon(Point{T}[mid, p(20.0μm, 20.0μm), p(20.0μm, 0.0μm)])
        )
        groups = Dict(:a => [A], :b => [B])
        n = split_t_junctions!(groups)
        @test n >= 1
        @test length(groups[:a][1].exterior.curves) >= 2
        @test all(c -> c isa Paths.Turn, groups[:a][1].exterior.curves)
    end

    @testset "Dict method injects across three groups meeting at a boundary" begin
        T = typeof(1.0μm)
        bottom = CurvilinearRegion(
            CurvilinearPolygon(
                Point{T}[
                    p(0μm, 0μm),
                    p(10μm, 0μm),
                    p(10μm, 10μm),
                    p(5μm, 10μm),
                    p(0μm, 10μm)
                ]
            )
        )
        middle = CurvilinearRegion(
            CurvilinearPolygon(
                Point{T}[p(0μm, 10μm), p(10μm, 10μm), p(10μm, 20μm), p(0μm, 20μm)]
            )
        )
        groups = Dict(:bottom => [bottom], :middle => [middle])
        n = split_t_junctions!(groups)
        @test n == 1
        @test any(
            q ->
                isapprox(getx(q), 5μm; atol=1e-6μm) && isapprox(gety(q), 10μm; atol=1e-6μm),
            points(groups[:middle][1].exterior)
        )
    end

    @testset "Dict method empty groups is a no-op" begin
        T = typeof(1.0μm)
        groups = Dict{Symbol, Vector{CurvilinearRegion{T}}}()
        @test split_t_junctions!(groups) == 0
        groups2 = Dict(:a => CurvilinearRegion{T}[])
        @test split_t_junctions!(groups2) == 0
    end

    @testset "Dict method atol is unit-safe (same physical distance regardless of input unit)" begin
        function build_pair(u, x_off)
            T = typeof(1.0u)
            A = CurvilinearRegion(
                CurvilinearPolygon(
                    Point{T}[
                        Point(0.0u, 0.0u),
                        Point(10000.0u, 0.0u),
                        Point(10000.0u, 10000.0u),
                        Point(0.0u, 10000.0u)
                    ]
                )
            )
            B = CurvilinearRegion(
                CurvilinearPolygon(
                    Point{T}[
                        Point(10000.0u, 0.0u),
                        Point(20000.0u, 0.0u),
                        Point(20000.0u, 10000.0u),
                        Point(10000.0u, 10000.0u),
                        Point((10000.0 + x_off)u, 5000.0u)
                    ]
                )
            )
            return Dict(:a => [A], :b => [B])
        end
        @test split_t_junctions!(build_pair(nm, 1.0)) == 1
        @test split_t_junctions!(build_pair(μm, 0.001)) == 1
        @test split_t_junctions!(build_pair(nm, 5.0)) == 0
        @test split_t_junctions!(build_pair(μm, 0.005)) == 0
    end

    @testset "Dict method dedups near-coincident foreign vertices on an edge" begin
        T = typeof(1.0nm)
        A = CurvilinearRegion(
            CurvilinearPolygon(
                Point{T}[
                    Point(0.0nm, 0.0nm),
                    Point(10000.0nm, 0.0nm),
                    Point(10000.0nm, 10000.0nm),
                    Point(0.0nm, 10000.0nm)
                ]
            )
        )
        B = CurvilinearRegion(
            CurvilinearPolygon(
                Point{T}[
                    Point(0.0nm, -10000.0nm),
                    Point(10000.0nm, -10000.0nm),
                    Point(10000.0nm, 0.0nm),
                    Point(5001.0nm, 0.0nm),
                    Point(5000.0nm, 0.0nm),
                    Point(0.0nm, 0.0nm)
                ]
            )
        )
        groups = Dict(:a => [A], :b => [B])
        @test split_t_junctions!(groups) == 1
    end

    @testset "Dict method keeps two well-separated foreign vertices on one edge" begin
        T = typeof(1.0μm)
        A = CurvilinearRegion(
            CurvilinearPolygon(
                Point{T}[p(0μm, 0μm), p(20μm, 0μm), p(20μm, 20μm), p(0μm, 20μm)]
            )
        )
        B = CurvilinearRegion(
            CurvilinearPolygon(
                Point{T}[
                    p(0μm, -20μm),
                    p(20μm, -20μm),
                    p(20μm, 0μm),
                    p(15μm, 0μm),
                    p(5μm, 0μm),
                    p(0μm, 0μm)
                ]
            )
        )
        groups = Dict(:a => [A], :b => [B])
        @test split_t_junctions!(groups) == 2
        a_pts = points(groups[:a][1].exterior)
        @test any(
            q -> isapprox(getx(q), 5μm; atol=1e-6μm) && isapprox(gety(q), 0μm; atol=1e-6μm),
            a_pts
        )
        @test any(
            q ->
                isapprox(getx(q), 15μm; atol=1e-6μm) && isapprox(gety(q), 0μm; atol=1e-6μm),
            a_pts
        )
    end

    @testset "Dict method injects a foreign vertex into a hole edge" begin
        T = typeof(1.0μm)
        ext = CurvilinearPolygon(
            Point{T}[p(0μm, 0μm), p(30μm, 0μm), p(30μm, 30μm), p(0μm, 30μm)]
        )
        hole = CurvilinearPolygon(
            Point{T}[p(10μm, 10μm), p(10μm, 20μm), p(20μm, 20μm), p(20μm, 10μm)]
        )
        A = CurvilinearRegion(ext, [hole])
        B = CurvilinearRegion(
            CurvilinearPolygon(Point{T}[p(20μm, 15μm), p(25μm, 12μm), p(25μm, 18μm)])
        )
        groups = Dict(:a => [A], :b => [B])
        n = split_t_junctions!(groups)
        @test n >= 1
        hole_pts = points(groups[:a][1].holes[1])
        @test any(
            q ->
                isapprox(getx(q), 20μm; atol=1e-6μm) &&
                    isapprox(gety(q), 15μm; atol=1e-6μm),
            hole_pts
        )
    end

    @testset "Dict method leaves an untouched curve intact (no foreign split)" begin
        T = typeof(1.0μm)
        R = 10.0μm
        turn = Paths.Turn(90°, R, α0=90°, p0=p(R, 0.0μm))
        A = CurvilinearRegion(
            CurvilinearPolygon(Point{T}[p(R, 0.0μm), p(0.0μm, R), p(R, R)], [turn], [1])
        )
        B = CurvilinearRegion(
            CurvilinearPolygon(Point{T}[p(100μm, 100μm), p(110μm, 100μm), p(110μm, 110μm)])
        )
        groups = Dict(:a => [A], :b => [B])
        @test split_t_junctions!(groups) == 0
        @test length(groups[:a][1].exterior.curves) == 1
        @test groups[:a][1].exterior.curves[1] isa Paths.Turn
    end

    @testset "Dict method works with `Vector{Polygon}` values" begin
        # The `AbstractDict` method also nodes plain-`Polygon` groups (the
        # `_collect_region_vertices!(::Polygon)` + `_node_region(::Polygon)`
        # plumbing routes both through the same code path).
        T = typeof(1.0μm)
        A = Polygon(Point{T}[p(0μm, 0μm), p(10μm, 0μm), p(10μm, 10μm), p(0μm, 10μm)])
        B = Polygon(
            Point{T}[
                p(10μm, 0μm),
                p(20μm, 0μm),
                p(20μm, 10μm),
                p(10μm, 10μm),
                p(10μm, 5μm)
            ]
        )
        groups = Dict(:a => [A], :b => [B])
        n = split_t_junctions!(groups)
        @test n == 1
        @test any(
            q ->
                isapprox(getx(q), 10μm; atol=1e-6μm) && isapprox(gety(q), 5μm; atol=1e-6μm),
            points(groups[:a][1])
        )
    end

    @testset "Dict method key type only needs to be sortable" begin
        # `AbstractDict` docs promise any sortable key type — verify a
        # `String`-keyed dict works exactly like the `Symbol`-keyed one.
        T = typeof(1.0μm)
        A = CurvilinearRegion(
            CurvilinearPolygon(
                Point{T}[p(0μm, 0μm), p(10μm, 0μm), p(10μm, 10μm), p(0μm, 10μm)]
            )
        )
        B = CurvilinearRegion(
            CurvilinearPolygon(
                Point{T}[
                    p(10μm, 0μm),
                    p(20μm, 0μm),
                    p(20μm, 10μm),
                    p(10μm, 10μm),
                    p(10μm, 5μm)
                ]
            )
        )
        groups = Dict("a" => [A], "b" => [B])
        @test split_t_junctions!(groups) == 1
    end

    @testset "Dict method works with SemanticMeta keys" begin
        # SemanticMeta is totally ordered (Base.isless on (layer, index, level)),
        # so it can key the all-pairs Dict directly — the shape the target-driven
        # conformal orchestrator uses (levelwise metadata → regions).
        T = typeof(1.0μm)
        A = CurvilinearRegion(
            CurvilinearPolygon(
                Point{T}[p(0μm, 0μm), p(10μm, 0μm), p(10μm, 10μm), p(0μm, 10μm)]
            )
        )
        B = CurvilinearRegion(
            CurvilinearPolygon(
                Point{T}[
                    p(10μm, 0μm),
                    p(20μm, 0μm),
                    p(20μm, 10μm),
                    p(10μm, 10μm),
                    p(10μm, 5μm)
                ]
            )
        )
        groups = Dict(SemanticMeta(:metal) => [A], SemanticMeta(:ground) => [B])
        @test split_t_junctions!(groups) == 1
    end
end

@testitem "split_pinches" setup = [CommonTestSetup] begin
    import DeviceLayout: CurvilinearPolygon, CurvilinearRegion, coordinatetype

    pts(xy) = [Point(x * 1.0μm, y * 1.0μm) for (x, y) in xy]
    contour(xy) = CurvilinearPolygon(pts(xy))
    region(xy) = CurvilinearRegion(contour(xy))
    # Areas in µm², with curves discretized. Material area takes the absolute area of each
    # contour, so a hole wrongly made into a region adds to it instead of cancelling.
    um2(a) = a isa Unitful.Quantity ? ustrip(μm^2, a) : Float64(a)
    loop_area(c) = um2(Polygons.signed_area(to_polygons(c)))
    material_area(regions) =
        sum(regions; init=0.0) do r
            return abs(loop_area(r.exterior)) -
                   sum(h -> abs(loop_area(h)), r.holes; init=0.0)
        end

    @testset "keyhole around an enclosed island becomes a hole" begin
        # From `union2d` of the DemoQPU17 metal negative layer: the gap around a CPW center
        # conductor with open ends. Clipper joins the conductor, a hole in this layer, to
        # the outer contour by a cut along y = 3274 µm traversed twice, so (-911, 3274)
        # repeats.
        r = region([
            (-889, 1670),
            (-889, 3280),
            (-911, 3280),
            (-911, 3274),
            (-895, 3274),
            (-895, 1676),
            (-905, 1676),
            (-905, 3274),
            (-911, 3274),
            (-911, 1670)
        ])
        out = split_pinches([r])
        @test length(out) == 1
        @test material_area(out) ≈ 19440
        @test loop_area(out[1].exterior) ≈ 22 * 1610
        # The hole is the conductor, plus the zero-width cut out to the pinch vertex
        hole = only(out[1].holes)
        @test loop_area(hole) ≈ -(10 * 1598)
        @test Set(points(hole)) == Set(
            pts([(-911, 3274), (-895, 3274), (-895, 1676), (-905, 1676), (-905, 3274)])
        )
    end

    @testset "keyhole into an island inside a hole makes the island a region" begin
        # The complementary contour, as in the metal layer: a clockwise hole joined by a
        # cut to a counterclockwise island of metal inside it.
        ext = contour([(0, 0), (100, 0), (100, 100), (0, 100)])
        hole = contour([
            (20, 20),
            (20, 40),
            (60, 40),
            (60, 60),
            (40, 60),
            (40, 40),
            (20, 40),
            (20, 80),
            (80, 80),
            (80, 20)
        ])
        out = split_pinches([CurvilinearRegion(ext, [hole])])
        @test length(out) == 2
        @test material_area(out) ≈ 100^2 - 60^2 + 20^2
        outer, island = out
        @test loop_area(outer.exterior) ≈ 100^2
        @test loop_area(only(outer.holes)) ≈ -(60^2)
        @test loop_area(island.exterior) ≈ 20^2
        @test isempty(island.holes)
        # The island keeps the zero-width cut out to the pinch vertex at (20, 40)
        @test Set(points(island.exterior)) ==
              Set(pts([(20, 40), (40, 40), (60, 40), (60, 60), (40, 60)]))
    end

    @testset "hole touching the exterior at a point" begin
        # The exterior runs around a triangular hole that touches it at (5, 0)
        r = region([(0, 0), (5, 0), (3, 3), (7, 3), (5, 0), (10, 0), (10, 10), (0, 10)])
        out = split_pinches([r])
        @test length(out) == 1
        @test material_area(out) ≈ 100 - 6
        @test Set(points(only(out[1].holes))) == Set(pts([(5, 0), (3, 3), (7, 3)]))
    end

    @testset "squares touching at corners; a hole goes to the square containing it" begin
        # Two squares touching at (10, 10)
        out = split_pinches([
            region([
                (0, 0),
                (10, 0),
                (10, 10),
                (20, 10),
                (20, 20),
                (10, 20),
                (10, 10),
                (0, 10)
            ])
        ])
        @test length(out) == 2
        @test all(r -> loop_area(r.exterior) ≈ 100 && isempty(r.holes), out)
        # A chain of three squares touching at (10, 10) and (20, 20), with a hole in the
        # middle square
        ext = contour([
            (0, 0),
            (10, 0),
            (10, 10),
            (20, 10),
            (20, 20),
            (30, 20),
            (30, 30),
            (20, 30),
            (20, 20),
            (10, 20),
            (10, 10),
            (0, 10)
        ])
        hole = contour([(13, 13), (13, 17), (17, 17), (17, 13)])
        out = split_pinches([CurvilinearRegion(ext, [hole])])
        @test length(out) == 3
        @test material_area(out) ≈ 300 - 16
        owner = only(filter(r -> !isempty(r.holes), out))
        @test Set(points(owner.exterior)) ==
              Set(pts([(10, 10), (20, 10), (20, 20), (10, 20)]))
    end

    @testset "curves stay native, and a piece closed by a curve is kept" begin
        # A square and a half disk touching at (10, 0). The half disk has only two
        # vertices, and holds a hole in its bulge, away from its straight edge.
        turn = Paths.Turn(180°, 5.0μm; p0=Point(20.0μm, 0.0μm), α0=90°)
        ext = CurvilinearPolygon(
            pts([(0, 0), (10, 0), (20, 0), (10, 0), (10, 10), (0, 10)]),
            [turn],
            [3]
        )
        hole = contour([(14, 1), (14, 3), (16, 3), (16, 1)])
        out = split_pinches([CurvilinearRegion(ext, [hole])])
        @test length(out) == 2
        half_disk = only(filter(r -> !isempty(r.exterior.curves), out))
        @test length(points(half_disk.exterior)) == 2
        @test only(half_disk.exterior.curves) == turn
        @test length(half_disk.holes) == 1
        @test material_area(out) ≈ 100 + π * 25 / 2 - 4 rtol = 1e-3

        # Two squares touching at (10, 10) with rounded corners on both sides of the pinch
        r = 2.0μm
        turn_a = Paths.Turn(90°, r; p0=Point(20.0μm, 18.0μm), α0=90°)
        turn_b = Paths.Turn(90°, r; p0=Point(2.0μm, 10.0μm), α0=180°)
        turn_c = Paths.Turn(90°, r; p0=Point(0.0μm, 2.0μm), α0=270°)
        ext = CurvilinearPolygon(
            pts([
                (0, 2),
                (2, 0),
                (10, 0),
                (10, 10),
                (20, 10),
                (20, 18),
                (18, 20),
                (10, 20),
                (10, 10),
                (2, 10),
                (0, 8)
            ]),
            [turn_c, turn_a, turn_b],
            [1, 6, 10]
        )
        out = split_pinches([CurvilinearRegion(ext)])
        @test length(out) == 2
        @test Set(length.(getfield.(getfield.(out, :exterior), :curves))) == Set([1, 2])
        @test Set(c for r in out for c in r.exterior.curves) ==
              Set([turn_a, turn_b, turn_c])
        @test material_area(out) ≈ 200 - 3 * (4 - π) rtol = 1e-3
    end

    @testset "near pinch: a piece keeps the copy of the vertex its curve ends on" begin
        # A square and a half disk touching at (10, 10), where the square's copy of the
        # vertex is 1 nm from the end of the half disk's arc
        turn = Paths.Turn(180°, 5.0μm; p0=Point(20.0μm, 10.0μm), α0=90°)
        ext = CurvilinearPolygon(
            [
                Point(0.0μm, 0.0μm),
                Point(10.0μm, 0.0μm),
                Point(10.001μm, 10.0μm),
                Point(20.0μm, 10.0μm),
                Paths.p1(turn),
                Point(0.0μm, 10.0μm)
            ],
            [turn],
            [4]
        )
        out = split_pinches([CurvilinearRegion(ext)])
        @test length(out) == 2
        half_disk = only(filter(r -> !isempty(r.exterior.curves), out))
        @test points(half_disk.exterior)[1] == Paths.p1(turn)
        @test material_area(out) ≈ 100 + π * 25 / 2 rtol = 1e-3
    end

    @testset "keyholed hole attached to the wrong region moves to the one containing it" begin
        # As Clipper can output for the DemoQPU17 metal layer: a hole keyholed to the
        # open-ended center conductor inside it is attached to a neighboring conductor `b`
        # rather than to the ground plane `g` that contains it
        g = CurvilinearRegion(
            contour([(0, 0), (100, 0), (100, 100), (0, 100)]),
            [contour([(5, 65), (5, 85), (25, 85), (25, 65)])]
        )
        keyholed = contour([
            (40, 20),
            (40, 30),
            (70, 30),
            (70, 40),
            (50, 40),
            (50, 30),
            (40, 30),
            (40, 50),
            (80, 50),
            (80, 20)
        ])
        b = CurvilinearRegion(contour([(10, 70), (20, 70), (20, 80), (10, 80)]), [keyholed])
        out = split_pinches([g, b])
        @test length(out) == 3
        @test material_area(out) ≈ 100^2 - 20^2 - 40 * 30 + 10^2 + 20 * 10
        @test length(out[1].holes) == 2
        @test loop_area(out[1].holes[2]) ≈ -40 * 30
        @test isempty(out[2].holes)
        @test loop_area(out[3].exterior) ≈ 20 * 10
    end

    @testset "zero-area pieces are dropped" begin
        # The contour runs out to (10, 0) and back along itself to (5, 0)
        out = split_pinches([region([(0, 0), (5, 0), (10, 0), (5, 0), (5, 5), (0, 5)])])
        @test length(out) == 1
        @test Set(points(out[1].exterior)) == Set(pts([(5, 0), (5, 5), (0, 5), (0, 0)]))
    end

    @testset "contour that crosses itself throws" begin
        # The pieces have opposite windings, so the clockwise one is a hole, but it lies
        # outside the counterclockwise one
        r = region([(10, 0), (10, 10), (0, 10), (0, 0), (10, 0), (20, 10), (20, 0)])
        @test_throws ArgumentError split_pinches([r])
    end

    @testset "regions without pinches are returned unchanged" begin
        r = region([(0, 0), (10, 0), (10, 10), (0, 10)])
        @test only(split_pinches([r])) === r
        @test isempty(split_pinches(CurvilinearRegion{typeof(1.0nm)}[]))
        # The result has the promoted coordinate type of the input
        rn = convert(CurvilinearRegion{typeof(1.0nm)}, r)
        mixed = CurvilinearRegion[r, rn]
        @test split_pinches(mixed) isa Vector{CurvilinearRegion{coordinatetype(mixed)}}
    end

    @testset "split_t_junctions! can make a pinch, so split_pinches runs after it" begin
        # `a` has a notch whose tip touches its own bottom edge at (5, 0), with no vertex
        # there, so it has no pinch until noding against `b`, which fills the notch,
        # injects (5, 0) into that edge
        a = region([(0, 0), (10, 0), (10, 10), (0, 10), (0, 6), (5, 0), (0, 4)])
        b = region([(0, 4), (5, 0), (0, 6)])
        @test only(split_pinches([a])) === a
        groups = Dict(:a => [a], :b => [b])
        @test split_t_junctions!(groups) == 1
        split = split_pinches(groups)
        @test Set(keys(split)) == Set([:a, :b])
        @test length(split[:a]) == 2
        @test material_area(split[:a]) ≈ 100 - 5
        @test only(split[:b]) === only(groups[:b])
    end

    @testset "atol is a length, with bare numbers in µm" begin
        # Two squares touching at (10, 10), with the second copy of the vertex 1 nm away
        xy =
            [(0, 0), (10, 0), (10, 10), (20, 10), (20, 20), (10, 20), (10.001, 10), (0, 10)]
        r = region(xy)
        @test length(split_pinches([r])) == 2
        @test length(split_pinches([r]; atol=0.5nm)) == 1
        @test length(split_pinches([r]; atol=0.0005)) == 1
        @test length(split_pinches([r]; atol=0.002)) == 2
        @test length(split_pinches(Dict(:r => [r]); atol=0.5nm)[:r]) == 1
        # The same physical tolerance applies to nm and unitless (µm) coordinates
        rn = convert(CurvilinearRegion{typeof(1.0nm)}, r)
        @test length(split_pinches([rn])) == 2
        @test material_area(split_pinches([rn])) ≈ material_area(split_pinches([r]))
        ru = CurvilinearRegion(CurvilinearPolygon([Point(x, y) for (x, y) in xy] .* 1.0))
        @test length(split_pinches([ru])) == 2
        @test length(split_pinches([ru]; atol=0.5nm)) == 1
    end
end

@testitem "SemanticMeta ordering" setup = [CommonTestSetup] begin
    import DeviceLayout: SemanticMeta

    @testset "isless orders by (layer, index, level)" begin
        # Primary key: layer (Symbols compare lexicographically)
        @test SemanticMeta(:a) < SemanticMeta(:b)
        @test !(SemanticMeta(:b) < SemanticMeta(:a))
        # Secondary key: index, within the same layer
        @test SemanticMeta(:a; index=1) < SemanticMeta(:a; index=2)
        # Tertiary key: level, within the same (layer, index)
        @test SemanticMeta(:a; index=1, level=1) < SemanticMeta(:a; index=1, level=2)
        # layer dominates index and level
        @test SemanticMeta(:a; index=9, level=9) < SemanticMeta(:b; index=1, level=1)
    end

    @testset "consistent with == (no strict-order ties for distinct values)" begin
        x = SemanticMeta(:a; index=1, level=1)
        @test !(x < x)                              # irreflexive
        @test x == SemanticMeta(:a; index=1, level=1)
        y = SemanticMeta(:a; index=1, level=2)
        @test (x < y) ⊻ (y < x)                     # exactly one direction for x != y
    end

    @testset "sortable / deterministic key order" begin
        ks = [
            SemanticMeta(:ground),
            SemanticMeta(:metal; index=2),
            SemanticMeta(:metal; index=1),
            SemanticMeta(:metal; index=1, level=2)
        ]
        s = sort(ks)
        @test s == [
            SemanticMeta(:ground),
            SemanticMeta(:metal; index=1, level=1),
            SemanticMeta(:metal; index=1, level=2),
            SemanticMeta(:metal; index=2)
        ]
        # Sorting is stable regardless of starting permutation
        @test sort(reverse(ks)) == s
    end
end
