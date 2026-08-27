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

    @testset "shared core: split_t_junctions! and mutual_node! agree on a fixture" begin
        # Both are thin wrappers over the same RTree noding core. On a shared
        # fixture, the asymmetric split_t_junctions!(A, B) must inject into A
        # exactly what the symmetric mutual_node! injects into A from B.
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
        SolidModels.mutual_node!(groups)
        onA =
            q ->
                isapprox(getx(q), 10.0μm; atol=1e-6μm) &&
                    isapprox(gety(q), 5.0μm; atol=1e-6μm)
        @test n_asym == 1
        @test any(onA, points(tA[1].exterior))                 # via split_t_junctions!
        @test any(onA, points(groups[:a][1].exterior))         # via mutual_node!
    end
end
