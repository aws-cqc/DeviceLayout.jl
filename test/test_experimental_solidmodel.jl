@testitem "Experimental solid-model types and stack" begin
    using DeviceLayout
    using DeviceLayout.SchematicDrivenLayout
    using DeviceLayout.SolidModels.Experimental
    import Unitful: μm

    @test fieldnames(Experimental.SolidModelTarget) == (:levels, :stack, :ops)
    @test Experimental.SolidModelTarget <: SchematicDrivenLayout.Target
    @test !isdefined(Experimental, :VACUUM)
    @test which(SchematicDrivenLayout.facing, Tuple{EntityMeta}).sig.parameters[2] ===
          DeviceLayout.Meta
    integration_source = read(
        joinpath(
            pkgdir(DeviceLayout),
            "src",
            "solidmodels",
            "experimental",
            "schematic_integration.jl"
        ),
        String
    )
    @test !occursin(r"(?<!\.)\bflatten\s*\(", integration_source)

    @test METAL isa Material
    @test DIELECTRIC isa Material
    @test NULL isa Material

    lumped_port = LumpedPort()
    @test fieldnames(LumpedPort) == ()
    @test LumpedPort() == lumped_port
    roles = (Generic(), Terminal(), Ground(), Tag(), WavePort(), lumped_port)
    role_names = ("Generic", "Terminal", "Ground", "Tag", "WavePort", "LumpedPort")
    @test string.(roles) == role_names
    @test [
        physical_group_name(EntityMeta(:metal; name="role", role=role)) for role in roles
    ] == ["metal__role__i1__r$name" for name in role_names]

    instance_role_meta = EntityMeta(:metal; role=Terminal())
    type_role_meta = EntityMeta(:metal; name="island", index=3, role=Terminal)
    @test instance_role_meta.role isa Terminal
    @test type_role_meta.role isa Terminal
    @test_throws TypeError EntityMeta(:metal; role="Terminal")
    @test layer(type_role_meta) == :metal
    @test layerindex(type_role_meta) == 3
    @test level(type_role_meta) == 1
    @test name(type_role_meta) == "island"
    @test physical_group_name(type_role_meta) == "metal__island__i3__rTerminal"
    @test Experimental.map_meta(type_role_meta) == physical_group_name(type_role_meta)

    levels = StackLevels(1 => 0μm, 2 => 500μm)
    pair_layer =
        SourceLayer(DIELECTRIC; level=1 => 2, height=(10μm, -10μm), gds_meta=GDSMeta(8, 2))
    @test first_level(pair_layer) == 1
    @test first_height(pair_layer) == 10μm
    @test resolve_thickness(pair_layer, levels) == 480μm

    stack = SourceStack(:substrate => pair_layer)
    @test haskey(stack, :substrate)
    @test length(stack) == 1

    missing_level_stack =
        SourceStack(:bad => SourceLayer(NULL; level=3, gds_meta=GDSMeta(1, 0)))
    bad_cs = CoordinateSystem("bad", μm)
    place!(bad_cs, Rectangle(1μm, 1μm), EntityMeta(:bad; name="bad_level"))
    @test_throws ArgumentError Experimental._preflight(
        bad_cs,
        missing_level_stack,
        levels,
        Tuple[]
    )
end

@testitem "Experimental artwork visibility and offsets" begin
    using DeviceLayout
    using DeviceLayout.SolidModels.Experimental
    import Unitful: μm

    stack = SourceStack(
        :art_only =>
            SourceLayer(NULL; level=1, gds_meta=GDSMeta(10, 5), solidmodel=false),
        :second => SourceLayer(METAL; level=2, gds_meta=GDSMeta(20, 7)),
        :mesh_only => SourceLayer(METAL; level=1, gds_meta=nothing)
    )
    cs = CoordinateSystem("art", μm)
    place!(cs, Rectangle(1μm, 1μm), EntityMeta(:art_only; index=99))
    place!(cs, Rectangle(Point(2μm, 0μm), Point(3μm, 1μm)), EntityMeta(:second))
    place!(cs, Rectangle(Point(4μm, 0μm), Point(5μm, 1μm)), EntityMeta(:mesh_only))

    cell = Cell("art", μm)
    render!(cell, cs, stack; levels=[1, 2], level_increment=GDSMeta(100, 10))
    @test element_metadata(cell) == [GDSMeta(10, 5), GDSMeta(120, 17)]

    missing = CoordinateSystem("missing", μm)
    place!(missing, Rectangle(1μm, 1μm), EntityMeta(:unknown; name="bad", index=4))
    @test_throws ArgumentError render!(Cell("missing", μm), missing, stack)
    registry = Experimental._build_initial_registry(cs, stack)
    @test !haskey(registry, :art_only)
    @test haskey(registry, :second)
end

@testitem "Experimental compiler and validation" begin
    using DeviceLayout
    using DeviceLayout.SolidModels
    using DeviceLayout.SolidModels.Experimental
    using DeviceLayout.SolidModels.Experimental: PGRecord, LayerState, Registry
    import Unitful: μm

    stack = SourceStack(:metal => SourceLayer(METAL; level=1, thickness=2μm))
    levels = StackLevels(1 => 0μm)
    registry = Registry(
        :metal => LayerState(
            [PGRecord("metal__a__i1__rGeneric", :metal, EntityMeta(:metal; name="a"))],
            2
        )
    )
    pg_ops, final_registry, interfaces, deferred =
        compile_layer_ops([(:metal, SolidModels.extrude_z!, ())], stack, registry; levels)
    @test final_registry[:metal].dim == 3
    @test length(pg_ops) == 2
    @test isempty(interfaces)
    @test isempty(deferred)

    @test_throws ArgumentError compile_layer_ops(
        [(:new_layer, SolidModels.difference_geom!, (:missing, :metal))],
        stack,
        registry;
        levels
    )

    boundary_ops, boundary_registry, _, _ = compile_layer_ops(
        [(:edge, SolidModels.get_boundary, (:metal,))],
        stack,
        registry;
        levels
    )
    @test boundary_registry[:edge].dim == 1
    @test only(boundary_ops)[2] == SolidModels.get_boundary

    translate_ops, translate_registry, _, _ = compile_layer_ops(
        [(:shifted, SolidModels.translate!, (:metal, 1μm, 0μm, 0μm), :copy => true)],
        stack,
        registry;
        levels
    )
    @test haskey(translate_registry, :metal)
    @test translate_registry[:shifted].dim == 2
    @test only(translate_ops)[2] == SolidModels.translate!

    two_translate_ops, two_translate_registry, _, _ = compile_layer_ops(
        [
            (:shifted, SolidModels.translate!, (:metal, 1μm, 0μm, 0μm), :copy => true),
            (:shifted, SolidModels.translate!, (:metal, 2μm, 0μm, 0μm), :copy => true),
            (:shifted, SolidModels.translate!, (:metal, 2μm, 0μm, 0μm), :copy => true)
        ],
        stack,
        registry;
        levels
    )
    shifted_names = getfield.(two_translate_registry[:shifted].pgs, :name)
    @test length(shifted_names) == 2
    @test allunique(shifted_names)
    @test count(operation -> operation[2] == SolidModels.translate!, two_translate_ops) == 2
    @test Experimental.generated_pg_name(
        :generated,
        "object",
        ["tool"];
        operation=:difference
    ) != Experimental.generated_pg_name(
        :generated,
        "object",
        ["tool"];
        operation=:intersect
    )

    malformed_operations = [
        (:bad, SolidModels.translate!, (:metal, 1μm)),
        (:bad, SolidModels.difference_geom!, (:metal, String[])),
        (:bad, SolidModels.get_boundary, ("metal",)),
        (:bad, SolidModels.revolve!, (:metal, 0, 0, 0)),
        (:bad, SolidModels.remove_group!, (:metal,), "not a keyword"),
        (:bad, SolidModels.translate!, (:metal, 1μm, 0μm, 0μm), :bogus => true),
        (:bad, SolidModels.translate!, (:metal, 1μm, 0μm, 0μm), :copy => "yes"),
        (:bad, SolidModels.difference_geom!, (:metal, :metal), :remove_object => "yes"),
        (:bad, SolidModels.remove_group!, (:metal,), :remove_entities => 1),
        (:bad, SolidModels.get_boundary, (:metal,), :combined => "yes"),
        (:bad, SolidModels.get_boundary, (:metal,), :direction => "diagonal"),
        (:bad, SolidModels.get_boundary, (:metal,), :direction => "ALL"),
        (:bad, SolidModels.get_boundary, (:metal,), :position => :min),
        (
            :bad,
            SolidModels.translate!,
            (:metal, 1μm, 0μm, 0μm),
            :copy => true,
            :copy => false
        ),
        (:bad, identity, (:metal,))
    ]
    for operation in malformed_operations
        err = try
            compile_layer_ops([operation], stack, registry; levels)
            nothing
        catch caught
            caught
        end
        @test err isa ArgumentError
        @test occursin("Layer operation 1", sprint(showerror, err))
        @test occursin(":bad", sprint(showerror, err))
    end

    append_registry = deepcopy(registry)
    append_registry[:combined] =
        LayerState([PGRecord("combined__existing", :combined, nothing)], 2)
    append_ops, union_registry, _, _ = compile_layer_ops(
        [(:combined, SolidModels.union_geom!, (:metal,))],
        stack,
        append_registry;
        levels
    )
    @test length(union_registry[:combined].pgs) == 2
    @test any(record -> record.name == "combined__existing", union_registry[:combined].pgs)
    @test !haskey(union_registry, :metal)
    @test count(operation -> operation[2] == SolidModels.union_geom!, append_ops) == 1
    @test count(operation -> operation[2] == SolidModels.difference_geom!, append_ops) == 1

    wrong_dimension_registry = deepcopy(registry)
    wrong_dimension_registry[:shifted] =
        LayerState([PGRecord("shifted__volume", :shifted, nothing)], 3)
    @test_throws ArgumentError compile_layer_ops(
        [(:shifted, SolidModels.translate!, (:metal, 1μm, 0μm, 0μm), :copy => true)],
        stack,
        wrong_dimension_registry;
        levels
    )

    interface_ops, interface_registry, interfaces, deferred = compile_layer_ops(
        [(:interface, SolidModels.intersect_geom!, (:metal, :metal))],
        stack,
        registry;
        levels
    )
    @test isempty(interface_ops)
    @test interface_registry[:interface].dim == 1
    @test length(interfaces) == 1
    @test length(deferred) == 1
    @test length(exnboundaries(:volume)) == 6
end

@testitem "Experimental placement prefix copies and transformed locators" begin
    using DeviceLayout
    using DeviceLayout.SchematicDrivenLayout
    using DeviceLayout.SolidModels.Experimental
    import Unitful: μm

    geometry = CoordinateSystem("shared", μm)
    place!(
        geometry,
        centered(Rectangle(2μm, 2μm)),
        EntityMeta(:metal; name="island", role=Terminal)
    )
    place!(geometry, Rectangle(Point(3μm, 0μm), Point(4μm, 1μm)), EntityMeta(:metal))
    nested = CoordinateSystem("nested", μm)
    place!(nested, Rectangle(1μm, 1μm), EntityMeta(:metal; name="inner"))
    addref!(geometry, nested)
    component = BasicComponent(geometry)
    graph = SchematicGraph("placement_copy")
    add_node!(graph, component; base_id="q1")
    add_node!(graph, component; base_id="q2")
    sch = plan(graph; log_dir=nothing)
    check!(sch)

    original_metadata = deepcopy(element_metadata(component.geometry))
    working = Experimental._working_schematic(sch)
    build!(working)
    Experimental._prefix_placement_names!(working)

    names_by_node = Dict{String, Vector{String}}()
    for (node, ref) in working.ref_dict
        names_by_node[node.id] = [
            entity_meta.name for
            (subcs, _) in DeviceLayout.traversal(DeviceLayout.structure(ref)) for
            entity_meta in element_metadata(subcs) if
            entity_meta isa EntityMeta && !isempty(entity_meta.name)
        ]
    end
    @test "q1.island" in names_by_node["q1"]
    @test "q2.island" in names_by_node["q2"]
    @test "q1.inner" in names_by_node["q1"]
    @test "q2.inner" in names_by_node["q2"]
    @test all(
        name -> !contains(name, "q1.q1") && !contains(name, "q2.q2"),
        vcat(values(names_by_node)...)
    )
    empty_names = [
        entity_meta.name for
        (subcs, _) in DeviceLayout.traversal(working.coordinate_system) for
        entity_meta in element_metadata(subcs) if
        entity_meta isa EntityMeta && isempty(entity_meta.name)
    ]
    @test length(empty_names) == 2
    @test element_metadata(component.geometry) == original_metadata
    @test element_metadata(geometry)[1].name == "island"

    locator_geometry = CoordinateSystem("locator", μm)
    place!(
        locator_geometry,
        centered(Rectangle(2μm, 2μm)),
        EntityMeta(:metal; name="terminal", role=Terminal)
    )
    root = CoordinateSystem("root", μm)
    addref!(root, locator_geometry, Point(10μm, 0μm))
    addref!(root, locator_geometry, Point(-10μm, 5μm))
    stack = SourceStack(:metal => SourceLayer(METAL; level=1))
    locators = Experimental._extract_locator_positions(root, stack, StackLevels(1 => 0μm))
    @test length(locators) == 2
    @test sort([locator.center_x for locator in locators]) == [-10.0, 10.0]
    @test sort([locator.center_y for locator in locators]) == [0.0, 5.0]

    hidden_stack = SourceStack(:metal => SourceLayer(METAL; level=1, solidmodel=false))
    @test isempty(
        Experimental._extract_locator_positions(root, hidden_stack, StackLevels(1 => 0μm))
    )
end

@testitem "Experimental LumpedPort directions" begin
    using DeviceLayout
    using DeviceLayout.SolidModels.Experimental
    import Unitful: μm, °

    const direction_map = Experimental._extract_lumped_port_directions

    local_cs = CoordinateSystem("local_port", μm)
    nested_port = meshsized_entity(
        optional_entity(WithDirection(30°)(Rectangle(2μm, 1μm)), :port; default=true),
        0.2μm
    )
    local_meta = EntityMeta(:port; name="local", role=LumpedPort)
    place!(local_cs, nested_port, local_meta)
    @test direction_map(local_cs)[physical_group_name(local_meta)] ≈
          [cospi(1 / 6), 0.5, 0.0]

    transformed = CoordinateSystem("transformed_ports", μm)
    addref!(transformed, local_cs; rot=90°)
    rotated = direction_map(transformed)[physical_group_name(local_meta)]
    @test rotated ≈ [-0.5, cospi(1 / 6), 0.0]

    reflected = CoordinateSystem("reflected_ports", μm)
    addref!(reflected, local_cs; rot=90°, xrefl=true)
    reflected_direction = direction_map(reflected)[physical_group_name(local_meta)]
    @test reflected_direction ≈ [0.5, cospi(1 / 6), 0.0]

    missing = CoordinateSystem("missing_direction", μm)
    place!(missing, Rectangle(1μm, 1μm), EntityMeta(:port; name="missing", role=LumpedPort))
    err = try
        direction_map(missing)
        nothing
    catch caught
        caught
    end
    @test err isa ArgumentError
    @test occursin("WithDirection", sprint(showerror, err))
    @test occursin("port__missing__i1__rLumpedPort", sprint(showerror, err))

    shared = CoordinateSystem("shared_port", μm)
    shared_meta = EntityMeta(:port; role=LumpedPort)
    place!(shared, WithDirection(0°)(Rectangle(1μm, 1μm)), shared_meta)

    identical = CoordinateSystem("identical_directions", μm)
    addref!(identical, shared, Point(0μm, 0μm))
    addref!(identical, shared, Point(2μm, 0μm))
    @test direction_map(identical)[physical_group_name(shared_meta)] == [1.0, 0.0, 0.0]

    conflicting = CoordinateSystem("conflicting_directions", μm)
    addref!(conflicting, shared)
    addref!(conflicting, shared; rot=90°)
    conflict_err = try
        direction_map(conflicting)
        nothing
    catch caught
        caught
    end
    @test conflict_err isa ArgumentError
    @test occursin("inconsistent final directions", sprint(showerror, conflict_err))
    @test occursin("distinct", sprint(showerror, conflict_err))
    @test occursin("name", sprint(showerror, conflict_err))
    @test occursin("index", sprint(showerror, conflict_err))
end

@testitem "Experimental Tag resolution stays within its declared layer" begin
    using DeviceLayout
    using DeviceLayout.SolidModels
    using DeviceLayout.SolidModels.Experimental
    using DeviceLayout.SolidModels.Experimental: PGRecord, LayerState, Registry

    sm = SolidModel("experimental_tag_layer"; overwrite=true)
    first_tag = SolidModels.gmsh.model.occ.addRectangle(0.0, 0.0, 0.0, 10.0, 10.0)
    second_tag = SolidModels.gmsh.model.occ.addRectangle(0.0, 0.0, 0.0, 10.0, 10.0)
    SolidModels.gmsh.model.occ.synchronize()
    sm["layer_a"] = [(Int32(2), Int32(first_tag))]
    sm["layer_b"] = [(Int32(2), Int32(second_tag))]
    registry = Registry(
        :a => LayerState([PGRecord("layer_a", :a, EntityMeta(:a))], 2),
        :b => LayerState([PGRecord("layer_b", :b, EntityMeta(:b))], 2)
    )
    locator = Experimental.LocatorRecord("tag", 1, Tag(), :a, 5.0, 5.0, 0.0)
    deferred = Experimental.DeferredInterface[]
    interfaces = Dict{String, Tuple{String, String}}()
    Experimental._resolve_tag_locators!(sm, registry, [locator], deferred, interfaces)
    tag_name = physical_group_name(EntityMeta(:a; name="tag", role=Tag()))
    @test SolidModels.hasgroup(sm, tag_name, 2)
    @test SolidModels.entitytags(sm[tag_name, 2]) == [Int32(first_tag)]
end

@testitem "Experimental rendered metadata conforms to schema" begin
    using DeviceLayout
    using DeviceLayout.SchematicDrivenLayout
    using DeviceLayout.SolidModels
    using DeviceLayout.SolidModels.Experimental
    import JSON
    using JSONSchema
    import Unitful: μm, °

    schema_path = joinpath(pkgdir(DeviceLayout), "schemas", "sm_metadata.schema.json")
    schema = JSONSchema.Schema(JSON.parsefile(schema_path); parent_dir=dirname(schema_path))
    fixture = JSON.parsefile(
        joinpath(pkgdir(DeviceLayout), "test", "fixtures", "sm_metadata_v1.json")
    )
    @test isnothing(JSONSchema.validate(schema, fixture))
    invalid_fixture = deepcopy(fixture)
    invalid_fixture["metadata"]["assembly"]["levels"] = Dict("not-an-integer" => 0.0)
    @test !isnothing(JSONSchema.validate(schema, invalid_fixture))

    geometry = CoordinateSystem("shape", μm)
    place!(geometry, Rectangle(10μm, 10μm), EntityMeta(:surface; name="pad"))
    place!(
        geometry,
        WithDirection(90°)(Rectangle(Point(12μm, 0μm), Point(14μm, 2μm))),
        EntityMeta(:port; name="drive", role=LumpedPort)
    )
    graph = SchematicGraph("experimental_render")
    add_node!(graph, BasicComponent(geometry); base_id="q1")
    sch = plan(graph; log_dir=nothing)
    check!(sch)
    target = Experimental.SolidModelTarget(
        StackLevels(1 => 0μm),
        SourceStack(
            :surface => SourceLayer(NULL; level=1, gds_meta=GDSMeta(4, 0)),
            :port => SourceLayer(NULL; level=1, gds_meta=GDSMeta(5, 0))
        )
    )

    missing_geometry = CoordinateSystem("missing_port_style", μm)
    place!(
        missing_geometry,
        Rectangle(2μm, 2μm),
        EntityMeta(:port; name="missing", role=LumpedPort)
    )
    missing_graph = SchematicGraph("missing_port_style")
    add_node!(missing_graph, BasicComponent(missing_geometry); base_id="q1")
    missing_sch = plan(missing_graph; log_dir=nothing) |> check!
    missing_sm = SolidModel("experimental_missing_port_style"; overwrite=true)
    missing_err = try
        render!(missing_sm, missing_sch, target)
        nothing
    catch caught
        caught
    end
    @test missing_err isa ArgumentError
    @test occursin("WithDirection", sprint(showerror, missing_err))
    @test isempty(SolidModels.dimgroupdict(missing_sm, 2))

    output_dir = mktempdir()
    before = readdir(output_dir)
    metadata = cd(output_dir) do
        sm = SolidModel("experimental_schema_test"; overwrite=true)
        return render!(sm, sch, target)
    end
    @test readdir(output_dir) == before
    @test isnothing(JSONSchema.validate(schema, metadata))
    generic_pg = metadata["physical_groups"]["surface__q1.pad__i1__rGeneric"]
    @test generic_pg["entity_meta"]["role"]["type"] == "Generic"
    port_pg = metadata["physical_groups"]["port__q1.drive__i1__rLumpedPort"]
    @test port_pg["entity_meta"]["role"] ==
          Dict("type" => "LumpedPort", "direction" => [0.0, 1.0, 0.0])
    @test element_metadata(geometry)[1].name == "pad"

    second_sm = SolidModel("experimental_schema_test_repeat"; overwrite=true)
    repeated_metadata = render!(second_sm, sch, target)
    @test repeated_metadata == metadata
    @test element_metadata(geometry)[1].name == "pad"

    json_path = joinpath(output_dir, "metadata.json")
    write_metadata(json_path, metadata)
    @test JSON.parsefile(json_path) == metadata
    @test_throws ArgumentError begin
        sm = SolidModel("experimental_no_output_dir"; overwrite=true)
        render!(sm, sch, target; output_dir=output_dir)
    end
end

@testitem "Experimental unitless coordinates and finalization strictness" begin
    using DeviceLayout
    using DeviceLayout.SchematicDrivenLayout
    using DeviceLayout.SolidModels
    using DeviceLayout.SolidModels.Experimental

    unitless_geometry = CoordinateSystem{Float64}("unitless")
    place!(unitless_geometry, Rectangle(10.0, 5.0), EntityMeta(:surface; name="shape"))
    unitless_graph = SchematicGraph("unitless_render")
    add_node!(unitless_graph, BasicComponent(unitless_geometry); base_id="q1")
    unitless_sch = plan(unitless_graph; log_dir=nothing) |> check!
    unitless_target = Experimental.SolidModelTarget(
        StackLevels(1 => 2.0),
        SourceStack(:surface => SourceLayer(NULL; level=1, height=3.0, thickness=0.0))
    )
    unitless_sm = SolidModel("experimental_unitless"; overwrite=true)
    unitless_metadata = render!(unitless_sm, unitless_sch, unitless_target)
    @test unitless_metadata["metadata"]["assembly"]["levels"]["1"] == 2.0
    @test unitless_metadata["layers"]["surface"]["height"] == 3.0
    @test unitless_metadata["layers"]["surface"]["thickness"] == 0.0

    unitless_locator_geometry = CoordinateSystem{Float64}("unitless_locator")
    place!(
        unitless_locator_geometry,
        Rectangle(Point(4.0, 6.0), Point(6.0, 8.0)),
        EntityMeta(:surface; name="locator", role=Terminal())
    )
    unitless_locators = Experimental._extract_locator_positions(
        unitless_locator_geometry,
        unitless_target.stack,
        unitless_target.levels
    )
    @test only(unitless_locators).center_x == 5.0
    @test only(unitless_locators).center_y == 7.0
    @test only(unitless_locators).z == 5.0

    warning_geometry = CoordinateSystem{Float64}("warning_surface")
    place!(warning_geometry, Rectangle(10.0, 10.0), EntityMeta(:metal; name="floating"))
    warning_graph = SchematicGraph("finalization_warning")
    add_node!(warning_graph, BasicComponent(warning_geometry); base_id="q1")
    log_dir = mktempdir()
    warning_sch = plan(warning_graph; log_dir=log_dir) |> check!
    warning_target = Experimental.SolidModelTarget(
        StackLevels(1 => 0.0),
        SourceStack(:metal => SourceLayer(METAL; level=1))
    )
    strict_sm = SolidModel("experimental_strict_warning"; overwrite=true)
    @test_throws ErrorException render!(
        strict_sm,
        warning_sch,
        warning_target;
        strict=:warn
    )
    @test isfile(warning_sch.logger.logname)
    @test contains(read(warning_sch.logger.logname, String), "has no locators")

    # A second render proves the exceptional strict path closed its working logfile.
    nonstrict_sm = SolidModel("experimental_strict_cleanup"; overwrite=true)
    @test render!(nonstrict_sm, warning_sch, warning_target; strict=:no) isa Dict
end
