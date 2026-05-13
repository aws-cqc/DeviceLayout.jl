@testitem "Port connectivity" setup = [CommonTestSetup] begin
    import DeviceLayout.SolidModels: connected_components, check_port_connectivity

    gmsh = SolidModels.gmsh

    # Helper: initialize a fresh Gmsh model for each testset
    function fresh_model(name="porttest")
        sm = SolidModel(name; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        return sm
    end

    # Helper: name a physical group at a given dimension from raw dimtags
    function name_group!(sm, gname, dim, tags)
        sm[gname] = [(Int32(dim), Int32(t)) for t in tags]
        return sm
    end

    @testset "open port bridges two disconnected metals" begin
        sm = fresh_model("open_port")
        # Two disjoint metal cubes at x=0..1 and x=3..4, plus a port bridging them at x=1..3.
        # Fragment to make them share boundary faces where they touch.
        gmsh.model.occ.addBox(0, 0, 0, 1, 1, 1)  # metal A (will be tag 1)
        gmsh.model.occ.addBox(3, 0, 0, 1, 1, 1)  # metal B (will be tag 2)
        gmsh.model.occ.addBox(1, 0, 0, 2, 1, 1)  # port spans x=1..3 (will be tag 3)
        gmsh.model.occ.fragment([(3, 1), (3, 2), (3, 3)], [])
        gmsh.model.occ.synchronize()
        # After fragment, the three boxes retain tags 1,2,3 because they do not overlap;
        # they just share faces. Register physical groups.
        name_group!(sm, "metal_A", 3, [1])
        name_group!(sm, "metal_B", 3, [2])
        name_group!(sm, "port_1", 3, [3])

        result = DeviceLayout.check_port_connectivity(
            sm,
            ["port_1"],
            ["metal_A", "metal_B"];
            dim=3
        )
        @test result == Dict("port_1" => :open)
    end

    @testset "short port touches only one metal" begin
        sm = fresh_model("short_port")
        # 2D U-shaped metal_A with a port nested in the opening: the port shares
        # two edges (top and bottom) with metal_A's connected component → :short.
        gmsh.model.occ.addRectangle(0, 0, 0, 3, 1)  # 1: metal A bottom strip
        gmsh.model.occ.addRectangle(2, 1, 0, 1, 1)  # 2: metal A right connector (joins top↔bottom)
        gmsh.model.occ.addRectangle(0, 2, 0, 3, 1)  # 3: metal A top strip
        gmsh.model.occ.addRectangle(0, 1, 0, 1, 1)  # 4: port (touches A on top and bottom)
        gmsh.model.occ.fragment([(2, 1), (2, 2), (2, 3), (2, 4)], [])
        gmsh.model.occ.synchronize()
        name_group!(sm, "metal_A", 2, [1, 2, 3])
        name_group!(sm, "port_1", 2, [4])

        result = DeviceLayout.check_port_connectivity(sm, ["port_1"], ["metal_A"]; dim=2)
        @test result == Dict("port_1" => :short)
    end

    @testset "floating port touches no metal" begin
        sm = fresh_model("floating_port")
        gmsh.model.occ.addBox(0, 0, 0, 1, 1, 1)   # metal A
        gmsh.model.occ.addBox(5, 5, 5, 1, 1, 1)   # port, far away from metal
        gmsh.model.occ.synchronize()
        name_group!(sm, "metal_A", 3, [1])
        name_group!(sm, "port_1", 3, [2])

        result = DeviceLayout.check_port_connectivity(sm, ["port_1"], ["metal_A"]; dim=3)
        @test result == Dict("port_1" => :floating)
    end

    @testset "cross-layer via: port bridging via stack reads as :short" begin
        # Flip-chip-style fixture: metal L1 at z=0, via column in the middle, metal L2 at z=3.
        # The port spans the full z-height alongside the stack, so it touches L1 and L2 on
        # two distinct boundary faces. Asked about L1+via+L2 (one component via the via),
        # this is :short. Asked about only L1, only one boundary touches metal → :floating.
        sm = fresh_model("via_stack")
        gmsh.model.occ.addBox(0, 0, 0, 2, 2, 1)     # metal L1 at z=[0,1]
        gmsh.model.occ.addBox(0.5, 0.5, 1, 1, 1, 1) # via at z=[1,2]
        gmsh.model.occ.addBox(0, 0, 2, 2, 2, 1)     # metal L2 at z=[2,3]
        gmsh.model.occ.addBox(2, 0, 0, 1, 2, 3)     # port at x=[2,3], z=[0,3] (shares +x faces with L1 and L2)
        gmsh.model.occ.fragment([(3, 1), (3, 2), (3, 3), (3, 4)], [])
        gmsh.model.occ.synchronize()
        name_group!(sm, "metal_L1", 3, [1])
        name_group!(sm, "via", 3, [2])
        name_group!(sm, "metal_L2", 3, [3])
        name_group!(sm, "port_1", 3, [4])

        # Unioning L1+via+L2 as metal: port touches both L1 and L2, which are joined
        # into one component through the via, so this is :short.
        result = DeviceLayout.check_port_connectivity(
            sm,
            ["port_1"],
            ["metal_L1", "via", "metal_L2"];
            dim=3
        )
        @test result == Dict("port_1" => :short)

        # Asking only about metal_L1: only one boundary face touches metal → :floating.
        result2 = DeviceLayout.check_port_connectivity(sm, ["port_1"], ["metal_L1"]; dim=3)
        @test result2 == Dict("port_1" => :floating)
    end

    @testset "batch: mixed open / short / floating in one call" begin
        sm = fresh_model("batch")
        # metal A is a U-shape (three boxes sharing faces, one connected component)
        # surrounding port_short on -x, +x, and -y. metal B is a separate box at x=[3,4].
        # port_open at x=[1,3] bridges metal A's right arm and metal B → :open.
        # port_short sits inside metal A's U and touches metal A on multiple faces but
        # all reach the same component → :short.
        # port_floating at x=[10,11] is isolated.
        gmsh.model.occ.addBox(-2, 0, 0, 1, 1, 1)   # 1: metal A left arm  (x=[-2,-1])
        gmsh.model.occ.addBox(0, 0, 0, 1, 1, 1)    # 2: metal A right arm (x=[0,1])
        gmsh.model.occ.addBox(-2, -1, 0, 3, 1, 1)  # 3: metal A connector (x=[-2,1], y=[-1,0]) joins the arms
        gmsh.model.occ.addBox(3, 0, 0, 1, 1, 1)    # 4: metal B
        gmsh.model.occ.addBox(1, 0, 0, 2, 1, 1)    # 5: port_open (connects A and B)
        gmsh.model.occ.addBox(-1, 0, 0, 1, 1, 1)   # 6: port_short (sits inside metal A's U)
        gmsh.model.occ.addBox(10, 0, 0, 1, 1, 1)   # 7: port_floating
        gmsh.model.occ.fragment(
            [(3, 1), (3, 2), (3, 3), (3, 4), (3, 5), (3, 6), (3, 7)],
            []
        )
        gmsh.model.occ.synchronize()
        name_group!(sm, "metal_A", 3, [1, 2, 3])
        name_group!(sm, "metal_B", 3, [4])
        name_group!(sm, "port_open", 3, [5])
        name_group!(sm, "port_short", 3, [6])
        name_group!(sm, "port_floating", 3, [7])

        result = DeviceLayout.check_port_connectivity(
            sm,
            ["port_open", "port_short", "port_floating"],
            ["metal_A", "metal_B"];
            dim=3
        )
        @test result["port_open"] === :open
        @test result["port_short"] === :short
        @test result["port_floating"] === :floating
        @test length(result) == 3
    end

    @testset "symbol vs string keys" begin
        sm = fresh_model("symkeys")
        # U-shape metal sandwiches the port, so the port has two metal-touching
        # boundaries on the same component → :short.
        gmsh.model.occ.addBox(0, 0, 0, 1, 1, 1)    # 1: metal left  arm
        gmsh.model.occ.addBox(2, 0, 0, 1, 1, 1)    # 2: metal right arm
        gmsh.model.occ.addBox(0, -1, 0, 3, 1, 1)   # 3: metal connector
        gmsh.model.occ.addBox(1, 0, 0, 1, 1, 1)    # 4: port between the arms
        gmsh.model.occ.fragment([(3, 1), (3, 2), (3, 3), (3, 4)], [])
        gmsh.model.occ.synchronize()
        name_group!(sm, "metal", 3, [1, 2, 3])
        name_group!(sm, "p1", 3, [4])

        # Pass Symbols for port_names and metal_groups
        result = DeviceLayout.check_port_connectivity(sm, [:p1], [:metal]; dim=3)
        # Keys always returned as String
        @test haskey(result, "p1")
        @test result["p1"] === :short
    end

    @testset "missing port name → :missing" begin
        sm = fresh_model("missing_port")
        gmsh.model.occ.addBox(0, 0, 0, 1, 1, 1)
        gmsh.model.occ.synchronize()
        name_group!(sm, "metal", 3, [1])
        # "port_absent" was never registered

        result = DeviceLayout.check_port_connectivity(sm, ["port_absent"], ["metal"]; dim=3)
        @test result == Dict("port_absent" => :missing)
    end
end
