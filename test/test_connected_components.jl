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
        @test result[1] == (Int32(3), Int32(1))
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
        @show result2
        @test length(result2) == 3
        sizes = sort([length(c) for c in result2])
        @test sizes == [1, 1, 2]
    end
end
