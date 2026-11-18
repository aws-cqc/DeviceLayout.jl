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

    # A 1-D primitive (LineSegment) has no boundary to sample: it hits the
    # generic fallback and contributes no control points.
    SolidModels.clear_mesh_control_points!()
    SolidModels._collect_mesh_control_points!(
        [DeviceLayout.LineSegment(Point(0μm, 0μm), Point(10μm, 0μm))],
        1.0,
        0.5,
        0.0
    )
    @test isempty(SolidModels.mesh_control_points())

    # Regression: when a positive-`h` group's primitives emit NO samples (e.g. a
    # sub-3-vertex polygon), the `(h, α)` bucket is never created. Recording
    # (`mesh_seen`/`mesh_points` non-nothing) must not index a missing key — it
    # previously threw `KeyError((h, α))`. This is the recording path
    # `_render_orchestrator!` uses, so it must be a safe no-op here.
    SolidModels.clear_mesh_control_points!()
    seen = Set{NTuple{5, Float64}}()
    collected = Set{NTuple{5, Float64}}()
    SolidModels._collect_mesh_control_points!(
        [Polygon([Point(0μm, 0μm), Point(1μm, 0μm)])],  # 2 vertices → no samples
        75.0,
        -1.0,
        0.0;
        curvature_sizing=false,
        mesh_seen=seen,
        mesh_points=collected
    )
    @test isempty(collected)
    @test isempty(seen)

    circle_cs = CoordinateSystem("circle_size_fields", nm)
    render!(circle_cs, Circle(Point(3μm, 4μm), 2μm), SemanticMeta(:circle))
    render!(circle_cs, Circle(Point(3μm, 4μm), 2μm), SemanticMeta(:circle_copy))
    preserve_primitives(el; kwargs...) = el

    cp = SolidModels.populate_size_fields!(
        circle_cs;
        primitives_of=preserve_primitives,
        zmap=_ -> 7μm
    )
    @test collect(only(cp[(2.0, -1.0)])) == [3.0, 4.0, 7.0]

    plain_cs = CoordinateSystem("custom_primitives", nm)
    render!(plain_cs, Rectangle(10μm, 10μm), SemanticMeta(:plain))
    custom_calls = Ref(0)
    function circle_from_plain(el; kwargs...)
        custom_calls[] += 1
        return Circle(Point(3μm, 4μm), 2μm)
    end
    custom_cp = SolidModels.populate_size_fields!(plain_cs; primitives_of=circle_from_plain)
    @test custom_calls[] == 1
    @test collect(only(custom_cp[(2.0, -1.0)])) == [3.0, 4.0, 0.0]

    primitive_calls = Ref(0)
    function count_primitives(el; kwargs...)
        primitive_calls[] += 1
        return el
    end
    SolidModels.populate_size_fields!(
        circle_cs;
        primitives_of=count_primitives,
        curvature_sizing=false
    )
    @test primitive_calls[] == 0
    @test isempty(SolidModels.mesh_control_points())
end

@testitem "Mesh size under styles that don't set one" setup = [CommonTestSetup] begin
    import DeviceLayout: Plain
    import DeviceLayout.SolidModels: meshsize, meshgrading
    import DeviceLayout.SchematicDrivenLayout: only_simulated

    pa = Path(μm)
    straight!(pa, 100μm, Paths.CPW(10μm, 6μm))
    node = pa[1]
    @test meshsize(node) == 12
    @test meshsize(only_simulated(node); simulation=true) == 12
    @test meshsize(Plain()(node)) == 12
    @test meshsize(WithDirection(0°)(node)) == 12
    @test meshsize(only_simulated(pa); simulation=true) == 12
    pu = Path(Point(0.0, 0.0))
    straight!(pu, 100.0, Paths.CPW(10.0, 6.0))
    @test meshsize(Plain()(pu[1])) == 12
    @test meshsize(only_simulated(pu[1]); simulation=true) == 12

    # The outermost style that sets a size wins, including one selected by an OptionalStyle,
    # and the grading comes with it
    r = Rectangle(2μm, 3μm)
    inner = MeshSized(2μm, 0.5)(r)
    @test (meshsize(Plain()(inner)), meshgrading(Plain()(inner))) == (2, 0.5)
    outer = MeshSized(1μm, 0.8)(Plain()(inner))
    @test (meshsize(outer), meshgrading(outer)) == (1, 0.8)
    opt = OptionalStyle(MeshSized(1μm, 0.8), :refine)(inner)
    @test (meshsize(opt; refine=true), meshgrading(opt; refine=true)) == (1, 0.8)
    @test (meshsize(opt; refine=false), meshgrading(opt; refine=false)) == (2, 0.5)
    # An explicit MeshSized(0) still turns sizing off
    @test meshsize(MeshSized(0μm)(node)) == 0

    # Simulated-only CPWs get their trace and gap refinement in the size field
    cs = CoordinateSystem("simulated_cpw", nm)
    place!(cs, only_simulated(pa), SemanticMeta(:path))
    cp = SolidModels.populate_size_fields!(cs; simulation=true)
    @test (12.0, -1.0) in keys(cp)
    SolidModels.clear_mesh_control_points!()
    @test isempty(SolidModels.populate_size_fields!(cs; simulation=false))
    SolidModels.clear_mesh_control_points!()
end
