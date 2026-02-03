@testitem "ExamplePDK" setup = [CommonTestSetup] begin
    include("../examples/DemoQPU17/DemoQPU17.jl")
    @time "Total" schematic, artwork = DemoQPU17.qpu17_demo(dir=tdir)
end

@testitem "Single Transmon" setup = [CommonTestSetup] begin
    # Single transmon example file requires CSV, JSON, JSONSchema, DataFrames
    # Just test the components
    using .SchematicDrivenLayout
    q = SchematicDrivenLayout.ExamplePDK.Transmons.ExampleRectangleTransmon()
    rr = SchematicDrivenLayout.ExamplePDK.ReadoutResonators.ExampleClawedMeanderReadout()
    @test geometry(q) isa CoordinateSystem{typeof(1.0DeviceLayout.nm)}
    @test geometry(rr) isa CoordinateSystem{typeof(1.0DeviceLayout.nm)}
    @test issubset([:readout, :xy, :z], keys(hooks(q)))
    @test abs(hooks(rr).qubit.p.y - hooks(rr).feedline.p.y) ≈ rr.total_height

    import .SchematicDrivenLayout.ExamplePDK: LayerVocabulary
    g = SchematicGraph("single-transmon")
    qubit_node = add_node!(g, q)
    rres_node = fuse!(g, qubit_node, rr)
    # Readout path
    p_readout = Path(
        Point(0μm, 0μm);
        α0=π / 2,
        name="p_ro",
        metadata=LayerVocabulary.METAL_NEGATIVE
    )
    straight!(p_readout, 2mm, Paths.CPW(10μm, 6μm))
    straight!(p_readout, 2mm, Paths.CPW(10μm, 6μm))
    # Ports
    csport = CoordinateSystem(uniquename("port"), nm)
    render!(csport, only_simulated(centered(Rectangle(10μm, 10μm))), LayerVocabulary.PORT)
    # Attach with port center `cpw_width` from the end (instead of `cpw_width/2`) to avoid corner effects
    attach!(p_readout, sref(csport), 10μm, i=1) # @ start
    attach!(p_readout, sref(csport), 2mm - 10μm, i=2) # @ end
    p_readout_node = add_node!(g, p_readout)
    attach!(g, p_readout_node, rres_node => :feedline, 0mm, location=1)
    floorplan = plan(g)
    # Define bounds for bounding simulation box
    chip = offset(bounds(floorplan), 2mm)[1]
    sim_area = chip
    render!(floorplan.coordinate_system, sim_area, LayerVocabulary.SIMULATED_AREA)
    # postrendering operations in solidmodel target define metal = (WRITEABLE_AREA - METAL_NEGATIVE) + METAL_POSITIVE
    render!(floorplan.coordinate_system, sim_area, LayerVocabulary.WRITEABLE_AREA)
    # Define rectangle that gets extruded to generate substrate volume
    render!(floorplan.coordinate_system, chip, LayerVocabulary.CHIP_AREA)
    check!(floorplan)
    sm = SolidModel("test", overwrite=true)
    render!(
        sm,
        floorplan,
        SchematicDrivenLayout.ExamplePDK.ExamplePDK.singlechip_solidmodel_target(
            "port_1",
            "port_2",
            "lumped_element"
        );
        strict=:no
    )
    # Ensure fragment and map found all the exterior boundaries: 3*4 sides of chip and vacuum boxes + top + bottom = 14
    @test length(SolidModels.dimtags(sm["exterior_boundary", 2])) == 14
    @test length(SolidModels.dimtags(sm["metal", 2])) == 7 # Island + ground + 2x leads + 2x mesh control partitions of ground + CPW trace between ports
    @test length(SolidModels.dimtags(sm["vacuum", 3])) == 2
    @test length(SolidModels.dimtags(sm["substrate", 3])) == 1
    @test length(SolidModels.dimtags(sm["port_1", 2])) == 1
    @test length(SolidModels.dimtags(sm["port_2", 2])) == 1
    @test length(SolidModels.dimtags(sm["lumped_element", 2])) == 1
end
