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

        # Cell targets require GDSMeta.
        @test_throws ArgumentError round_layer!(
            c,
            GDSMeta(2),
            1μm;
            target_layer=SemanticMeta(:metal)
        )
        @test_throws ArgumentError round_layer!(
            c,
            GDSMeta(2),
            1μm;
            target_layer=GDSMeta(4),
            remap_originals=SemanticMeta(:metal)
        )
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

    @testset "Exact coordinate types" begin
        c = Cell{Int}("int")
        push!(c.elements, Polygon(p(0, 0), p(1000, 0), p(1000, 1000), p(0, 1000)))
        push!(c.element_metadata, GDSMeta(1))

        # Out-of-place widens only after taking the exact-coordinate Clipper path.
        regions = round_layer(c, GDSMeta(1), 100)
        @test length(regions) == 1
        @test coordinatetype(only(regions)) === Float64

        # A coarse discretization whose points lie on the integer grid is representable.
        round_layer!(c, GDSMeta(1), 100; target_layer=GDSMeta(2), atol=100)
        @test count(==(GDSMeta(2)), element_metadata(c)) == 1

        # A finer discretization is not representable, and failure is transactional.
        c_fail = Cell{Int}("int_fail")
        push!(c_fail.elements, Polygon(p(0, 0), p(1000, 0), p(1000, 1000), p(0, 1000)))
        push!(c_fail.element_metadata, GDSMeta(1))
        @test_throws InexactError round_layer!(
            c_fail,
            GDSMeta(1),
            100;
            target_layer=GDSMeta(2),
            remap_originals=GDSMeta(3)
        )
        @test elements(c_fail) == [Polygon(p(0, 0), p(1000, 0), p(1000, 1000), p(0, 1000))]
        @test element_metadata(c_fail) == [GDSMeta(1)]

        # Large integer coordinates must not take the prescaled floating-point Clipper path.
        c_large = Cell{Int}("int_large")
        b = 10^12
        push!(
            c_large.elements,
            Polygon(p(b, b), p(b + 1000, b), p(b + 1000, b + 1000), p(b, b + 1000))
        )
        push!(c_large.element_metadata, GDSMeta(1))
        @test length(round_layer(c_large, GDSMeta(1), 100)) == 1

        # Exact symbolic fillets remain valid in an integer CoordinateSystem.
        cs = CoordinateSystem{Int}("int_cs")
        place!(
            cs,
            Polygon(p(0, 0), p(1000, 0), p(1000, 1000), p(0, 1000)),
            SemanticMeta(:metal)
        )
        cs_regions = round_layer(cs, SemanticMeta(:metal), 100)
        @test coordinatetype(only(cs_regions)) === Int
        @test length(only(cs_regions).exterior.curves) == 4
        @test all(c -> c isa Paths.Turn{Int}, only(cs_regions).exterior.curves)

        # Empty exact-coordinate targets are valid no-ops.
        empty_cell = Cell{Int}("int_empty")
        @test round_layer!(empty_cell, GDSMeta(1), 100; target_layer=GDSMeta(2)) ===
              empty_cell
    end
end
