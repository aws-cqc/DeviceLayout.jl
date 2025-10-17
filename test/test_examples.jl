@testitem "ExamplePDK" setup = [CommonTestSetup] begin
    include("../examples/DemoQPU17/DemoQPU17.jl")
    @time "Total" schematic, artwork = DemoQPU17.qpu17_demo(dir=tdir)
    # Single transmon example file requires CSV, JSON, JSONSchema, DataFrames
    # Just test the components
    using .SchematicDrivenLayout
    q = SchematicDrivenLayout.ExamplePDK.Transmons.ExampleRectangleTransmon()
    rr = SchematicDrivenLayout.ExamplePDK.ReadoutResonators.ExampleClawedMeanderReadout()
    @test geometry(q) isa CoordinateSystem{typeof(1.0DeviceLayout.nm)}
    @test geometry(rr) isa CoordinateSystem{typeof(1.0DeviceLayout.nm)}
    @test issubset([:readout, :xy, :z], keys(hooks(q)))
    @test abs(hooks(rr).qubit.p.y - hooks(rr).feedline.p.y) ≈ rr.total_height
end
