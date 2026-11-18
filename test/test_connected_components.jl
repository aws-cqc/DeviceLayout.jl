@testitem "Connected components" setup = [CommonTestSetup] begin
    import DeviceLayout.SolidModels
    import DeviceLayout.SolidModels: connected_components

    gmsh = SolidModels.gmsh

    # Helper: initialize a fresh Gmsh model for each testset
    function fresh_model(name="test")
        sm = SolidModel(name; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        return sm
    end

    @testset "empty input" begin
        fresh_model("empty")
        result = connected_components(3, Int32[])
        @test result == Vector{Tuple{Int32, Int32}}[]
    end

    @testset "single entity" begin
        fresh_model("single")
        gmsh.model.occ.addBox(0, 0, 0, 1, 1, 1)
        gmsh.model.occ.synchronize()
        tags = Int32[1]
        result = connected_components(3, tags)
        @test length(result) == 1
        @test result[1] == [(Int32(3), Int32(1))]
    end

    @testset "two disconnected volumes" begin
        fresh_model("disconnected")
        gmsh.model.occ.addBox(0, 0, 0, 1, 1, 1)     # tag 1
        gmsh.model.occ.addBox(10, 10, 10, 1, 1, 1)   # tag 2, far apart
        gmsh.model.occ.synchronize()
        vols = [dt[2] for dt in gmsh.model.getEntities(3)]
        result = connected_components(3, vols)
        @test length(result) == 2
        # Each component should have exactly one volume
        sizes = sort([length(c) for c in result])
        @test sizes == [1, 1]
    end

    # Ground plane 20x20 and a bridge deck at z = 1 on two open vertical legs whose foot
    # curves land in the ground plane's interior.
    function stray_edge_model(name)
        fresh_model(name)
        ground = gmsh.model.occ.addRectangle(-10, -10, 0, 20, 20)
        deck = gmsh.model.occ.addRectangle(0, 0, 1, 1, 1)
        p1 = gmsh.model.occ.addPoint(0, 0, 0)
        p2 = gmsh.model.occ.addPoint(0, 1, 0)
        p3 = gmsh.model.occ.addPoint(1, 1, 0)
        p4 = gmsh.model.occ.addPoint(1, 0, 0)
        l1 = gmsh.model.occ.addLine(p1, p2)
        l2 = gmsh.model.occ.addLine(p3, p4)
        ext = gmsh.model.occ.extrude([(1, l1), (1, l2)], 0.0, 0.0, 1.0)
        legs = [dt for dt in ext if dt[1] == 2]
        frag, _ =
            gmsh.model.occ.fragment([(1, l1), (1, l2)], [(2, ground), (2, deck), legs...])
        gmsh.model.occ.synchronize()
        return Int32[dt[2] for dt in frag if dt[1] == 2]
    end

    face_width(tag) = (bb = gmsh.model.getBoundingBox(2, tag); bb[4] - bb[1])

    @testset "stray edge embedded in face interior connects two faces" begin
        # The foot edges are embedded in the ground plane rather than bounding it, so only
        # the embedded-curve step connects the ground plane to the legs.
        tags = stray_edge_model("stray_edge")
        ground_tag = only(t for t in tags if face_width(t) > 10)
        @test length(gmsh.model.mesh.getEmbedded(2, ground_tag)) == 2
        @test length(connected_components(2, tags)) == 1
    end

    @testset "embedded contact connects without the face joining the legs" begin
        # Leave out the top rectangle that joins the legs through shared boundary edges.
        tags = stray_edge_model("stray_edge_no_top")
        faces = [t for t in tags if gmsh.model.getBoundingBox(2, t)[3] < 0.5]
        @test length(faces) == 3
        @test length(connected_components(2, faces)) == 1
    end

    @testset "closed contour on a face splits it without embedding" begin
        fresh_model("closed_contour")
        gmsh.model.occ.addRectangle(-10, -10, 0, 20, 20)
        circle = gmsh.model.occ.addCircle(0, 0, 0, 1)
        wall = gmsh.model.occ.extrude([(1, circle)], 0.0, 0.0, 1.0)
        frag, _ = gmsh.model.occ.fragment([(1, circle)], [(2, 1), wall[2]])
        gmsh.model.occ.synchronize()
        tags = Int32[dt[2] for dt in frag if dt[1] == 2]
        ground_pieces = [t for t in tags if gmsh.model.getBoundingBox(2, t)[6] < 0.5]
        @test length(ground_pieces) == 2
        @test all(isempty(gmsh.model.mesh.getEmbedded(2, t)) for t in ground_pieces)
        @test length(connected_components(2, tags)) == 1
    end

    @testset "staple bridge connects" begin
        cs = DeviceLayout.SchematicDrivenLayout.ExamplePDK.bridge_geometry(
            Paths.CPW(10e3nm, 6e3nm)
        )
        place!(cs, centered(Rectangle(1e6nm, 1e6nm)), :gnd)
        sm = SolidModel("test"; overwrite=true)
        render!(
            sm,
            cs;
            postrender_ops=[
                SolidModels.staple_bridge_postrendering(;
                    base="bridge_base",
                    bridge="bridge",
                    bridge_height=10μm # Exaggerated, for visualization
                )...
            ],
            solidmodel=true
        )
        @test length(connected_components(sm, ["bridge_metal", "gnd"])) == 1
    end

    @testset "shared-boundary volumes via fragment" begin
        fresh_model("shared")
        # Two overlapping boxes — fragment will create shared boundary surfaces
        gmsh.model.occ.addBox(0, 0, 0, 2, 1, 1)
        gmsh.model.occ.addBox(1, 0, 0, 2, 1, 1)
        gmsh.model.occ.fragment([(3, 1)], [(3, 2)])
        gmsh.model.occ.synchronize()
        vols = [dt[2] for dt in gmsh.model.getEntities(3)]
        @test length(vols) == 3  # fragment produces 3 volumes
        result = connected_components(3, vols)
        # All volumes share boundaries, so should be one connected component
        @test length(result) == 1
        @test sort(last.(result[1])) == sort(vols)
    end

    @testset "chain connectivity A-B-C" begin
        fresh_model("chain")
        # Three boxes in a chain: A overlaps B, B overlaps C, but A does not overlap C
        gmsh.model.occ.addBox(0, 0, 0, 2, 1, 1)    # A
        gmsh.model.occ.addBox(1, 0, 0, 3, 1, 1)    # B overlaps A
        gmsh.model.occ.addBox(3, 0, 0, 2, 1, 1)    # C overlaps B but not A
        # Fragment all three to create shared boundaries
        gmsh.model.occ.fragment([(3, 1), (3, 2), (3, 3)], [])
        gmsh.model.occ.synchronize()
        vols = [dt[2] for dt in gmsh.model.getEntities(3)]
        @test length(vols) == 5  # fragment produces multiple volumes
        result = connected_components(3, vols)
        # All volumes are transitively connected: A-B-C chain
        @test length(result) == 1
        @test sort(last.(result[1])) == sort(vols)
    end

    @testset "mixed: one connected group and one isolated" begin
        fresh_model("mixed")
        # Two overlapping boxes (will be connected after fragment)
        gmsh.model.occ.addBox(0, 0, 0, 2, 1, 1)
        gmsh.model.occ.addBox(1, 0, 0, 2, 1, 1)
        # One isolated box far away
        gmsh.model.occ.addBox(100, 100, 100, 1, 1, 1)
        # Fragment the overlapping pair (include isolated box too)
        gmsh.model.occ.fragment([(3, 1), (3, 2), (3, 3)], [])
        gmsh.model.occ.synchronize()
        vols = [dt[2] for dt in gmsh.model.getEntities(3)]
        result = connected_components(3, vols)
        # Should have exactly 2 components: the connected pair and the isolated box
        @test length(result) == 2
        sizes = sort([length(c) for c in result])
        @test sizes[1] == 1  # isolated box
        @test sizes[2] == 3  # connected volumes from the overlap
    end

    @testset "2D surface connectivity" begin
        fresh_model("surfaces")
        # Two overlapping rectangles in 2D (surfaces)
        gmsh.model.occ.addRectangle(0, 0, 0, 2, 1)
        gmsh.model.occ.addRectangle(1, 0, 0, 2, 1)
        # One isolated rectangle
        gmsh.model.occ.addRectangle(100, 100, 0, 1, 1)
        gmsh.model.occ.fragment([(2, 1), (2, 2), (2, 3)], [])
        gmsh.model.occ.synchronize()
        surfs = [dt[2] for dt in gmsh.model.getEntities(2)]
        result = connected_components(2, surfs)
        # Should have 2 components: the connected pair and the isolated rectangle
        @test length(result) == 2
        sizes = sort([length(c) for c in result])
        @test sizes[1] == 1  # isolated rectangle
        @test sizes[2] == 3  # connected surfaces from the overlap

        fresh_model("surfaces2")
        # Three chained adjacent rectangles
        gmsh.model.occ.addRectangle(10, 10, 0, 1, 1)
        gmsh.model.occ.addRectangle(11, 10, 0, 1, 1)
        gmsh.model.occ.addRectangle(12, 10, 0, 1, 1)
        # Two nested rectangles
        gmsh.model.occ.addRectangle(50, 50, 0, 4, 4)
        gmsh.model.occ.addRectangle(51, 51, 0, 1, 1)
        gmsh.model.occ.synchronize()
        dt, dtmap = gmsh.model.occ.fragment(gmsh.model.getEntities(2), [])
        gmsh.model.occ.synchronize()
        surfs = [dt[2] for dt in gmsh.model.getEntities(2)]
        result = connected_components(2, surfs)
        # Should have 2 components
        @test length(result) == 2
        sizes = sort([length(c) for c in result])
        @test sizes[1] == 2
        @test sizes[2] == 3
        # If you skip the connecting rectangle you get 3 groups
        disconnected = unique(vcat(dtmap[1], dtmap[3], dtmap[4], dtmap[5]))
        result2 = connected_components(2, last.(disconnected))
        @test length(result2) == 3
        sizes = sort([length(c) for c in result2])
        @test sizes == [1, 1, 2]
    end
end
