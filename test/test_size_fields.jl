@testitem "Size fields from coordinate systems" setup = [CommonTestSetup] begin
    cs = CoordinateSystem("size_fields", nm)

    render!(
        cs,
        styled(centered(Rectangle(10μm, 10μm)), MeshSized(1μm, 0.8)),
        SemanticMeta(:fine)
    )

    pa = Path(Point(20μm, 0μm); metadata=SemanticMeta(:path))
    straight!(pa, 100μm, Paths.SimpleCPW(10μm, 6μm))
    render!(cs, pa, SemanticMeta(:path))

    cp = SolidModels.populate_size_fields!(cs; zmap=_ -> 3μm)

    @test (1.0, 0.8) in keys(cp)
    @test (12.0, -1.0) in keys(cp)
    @test length(cp[(1.0, 0.8)]) == 40
    @test !isempty(cp[(12.0, -1.0)])
    @test !isempty(SolidModels.mesh_control_trees())
    @test all(p -> p[3] == 3.0, Iterators.flatten(values(cp)))

    SolidModels.clear_mesh_control_points!()
    cp = SolidModels.populate_size_fields!(cs)
    @test all(p -> p[3] == 0.0, Iterators.flatten(values(cp)))
end
