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

    @testset "stray edge embedded in face interior connects two faces" begin
        # Two coplanar surfaces that share no topological boundary in gmsh's adjacency
        # graph, but are bridged geometrically by 1D edges lying in the interior of
        # one and on the boundary of the other. Mirrors the staple-airbridge foot
        # edges landing on a ground plane: OCC's global fragment leaves these curves
        # geometrically embedded but topologically detached, so getAdjacencies returns
        # only the ground plane's outer rectangle. Geometry matches the minimal
        # reproduction observed empirically — the second loose-rectangle is irrelevant
        # but kept to match the exact tag layout the reproduction relies on.
        fresh_model("stray_edge")
        gmsh.model.occ.addRectangle(-10, -10, 0, 20, 20)
        gmsh.model.occ.addRectangle(0, 0, 1, 1, 1)
        gmsh.model.occ.addRectangle(0, 0, 0, 1, 1)
        gmsh.model.occ.addPoint(0, 0, 0)
        gmsh.model.occ.addPoint(0, 1, 0)
        gmsh.model.occ.addPoint(1, 1, 0)
        gmsh.model.occ.addPoint(1, 0, 0)
        l1 = gmsh.model.occ.addLine(9, 10)
        l2 = gmsh.model.occ.addLine(11, 12)
        ext = gmsh.model.occ.extrude([(1, 9), (1, 10)], 0.0, 0.0, 1.0)
        frag, _ = gmsh.model.occ.fragment([(1, l1), (1, l2)], [(2, 1), (2, 2), (2, 3), (2, 4), (2, 5)])
        gmsh.model.occ.synchronize()
        leg_faces = Int32[dt[2] for dt in frag if dt[1] == 2]
        tags = leg_faces

        # Topology only: ground plane (tag 1) is disconnected from each leg face.
        result_topo = connected_components(2, tags; staple_tol=0.0) # tol=0.0 turns off augmentation
        @test length(result_topo) == 2

        # Geometric augmentation: the foot edges lie in the ground plane's interior
        # and are boundary edges of the leg faces → all united into 1 component.
        result_geom = connected_components(2, tags; staple_tol=1e-6)
        @test length(result_geom) == 1
    end

    @testset "staple bridge connects" setup = [CommonTestSetup] begin
        cs = DeviceLayout.SchematicDrivenLayout.ExamplePDK.bridge_geometry(Paths.CPW(10μm, 6μm))
        place!(cs, centered(Rectangle(1mm, 1mm)), :gnd)
        sm = SolidModel("test"; overwrite=true)
        render!(sm, cs; postrender_ops=[
            SolidModels.staple_bridge_postrendering(;
                base="bridge_base",
                bridge="bridge",
                bridge_height=10μm # Exaggerated, for visualization
            )...,], solidmodel=true)
        @test length(connected_components(sm, ["bridge_metal", "gnd"])) == 1
        # Works even without stapling
        @test length(connected_components(sm, ["bridge_metal", "gnd"], staple_tol=0)) == 1
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
