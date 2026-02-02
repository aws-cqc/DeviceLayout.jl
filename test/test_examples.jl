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
        SchematicDrivenLayout.ExamplePDK.SINGLECHIP_SOLIDMODEL_TARGET;
        strict=:no
    )
    # Ensure fragment and map found all the exterior boundaries: 3*4 sides of chip and vacuum boxes + top + bottom = 14
    @test length(SolidModels.dimtags(sm["exterior_boundary", 2])) == 14
end
