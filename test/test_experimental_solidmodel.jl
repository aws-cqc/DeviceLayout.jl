@testitem "EntityMeta and SourceStack" begin
    using DeviceLayout
    using DeviceLayout.SchematicDrivenLayout
    using DeviceLayout.SolidModels.Experimental
    # import Unitful: μm
    using DeviceLayout.PreferredUnits

    # Offered material types remain present
    @test METAL isa Material
    @test DIELECTRIC isa Material
    @test NULL isa Material

    # Some consumers may take PG as contract
    for role in [Generic(), Terminal(), Ground(), Tag(), WavePort(), LumpedPort()]
        @test physical_group_name(EntityMeta(:metal; name="name", role=role)) ==
              "metal__name__i1__r$role"
    end

    instance_role_meta = EntityMeta(:metal; role=Terminal())
    type_role_meta = EntityMeta(:metal; name="island", index=3, role=Terminal)
    @test instance_role_meta.role isa Terminal
    @test type_role_meta.role isa Terminal
    @test_throws TypeError EntityMeta(:metal; role="Terminal")
    @test layer(type_role_meta) == :metal
    @test layerindex(type_role_meta) == 3
    @test level(type_role_meta) == 1 # DeviceLayout.Meta interface
    @test name(type_role_meta) == "island"
    @test physical_group_name(type_role_meta) == "metal__island__i3__rTerminal"
    @test Experimental.map_meta(type_role_meta) == physical_group_name(type_role_meta)

    simple_layer = SourceLayer(NULL; thickness=10.0nm)
    offset_layer = SourceLayer(NULL; thickness=15μm, height=5μm)
    stack = SourceStack(:a => simple_layer, :b => offset_layer; levels=(1 => 0.0nm))
    @test simple_layer.level == 1
    @test thickness(simple_layer, stack) == 10.0nm
    @test thickness(offset_layer, stack) == 15μm # offset shouldn't change thickness

    pair_layer = SourceLayer(NULL; level=1 => 2)
    offset_pair_layer =
        SourceLayer(DIELECTRIC; level=1 => 2, height=(10μm, -10μm), gds_meta=GDSMeta(8, 2))
    @test first(offset_pair_layer.level) == 1
    @test last(offset_pair_layer.level) == 2
    @test first(offset_pair_layer.height) == 10μm
    @test last(offset_pair_layer.height) == -10μm
    stack = SourceStack(:substrate => offset_pair_layer; levels=(1 => 0μm, 2 => 500μm))
    @test thickness(pair_layer, stack) == 500μm
    @test thickness(stack.layers[:substrate], stack) == 480μm
    @test layer_z(:substrate, stack) == 10μm
    @test layer_z(stack.layers[:substrate], stack) == 10μm
    @test sourcelayer(:substrate, stack) === stack.layers[:substrate]
    @test sourcelayer(EntityMeta(:substrate), stack) === stack.layers[:substrate]
    @test stack.levels[1] == 0μm
    @test stack.levels[2] == 500μm
    @test typeof(stack.layers[:substrate]).parameters[1] == typeof(stack.levels[1])
    # Inconsistent length types (mixed unitful and unitless)
    @test_throws ArgumentError SourceStack(
        :substrate => offset_pair_layer;
        levels=(1 => 0.0,)
    )
    # Mixed length types (all unitful)
    layer = SourceLayer(NULL; level=1 => 2, height=(10μm, -5.4μm))
    stack = SourceStack(:substrate => layer; levels=(1 => 0μm, 2 => 500000.3nm))

    mixed_types_stack = SourceStack(
        :integer => SourceLayer(NULL),
        :floating => SourceLayer(NULL; height=0.0μm, thickness=0.0μm);
        levels=(1 => 0.0μm,)
    )
    @test typeof(mixed_types_stack).parameters[1] === SourceLayer
    @test typeof(mixed_types_stack).parameters[2] == typeof(mixed_types_stack.levels[1])
    @test layer_z(:integer, mixed_types_stack) == 0.0μm

    # Referenced level does not exist
    @test_throws ArgumentError SourceStack(
        :bad => SourceLayer(NULL; level=3, gds_meta=GDSMeta(1, 0));
        levels=(1 => 0μm, 2 => 500μm)
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
        :mesh_only => SourceLayer(METAL; level=1, gds_meta=nothing);
        levels=(1 => 0μm, 2 => 500μm)
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
    registry = Experimental._build_initial_registry(Experimental._entity_metas(cs), stack)
    @test !haskey(registry, :art_only)
    @test haskey(registry, :second)
end

@testitem "Experimental compiler and validation" begin
    using DeviceLayout
    using DeviceLayout.SolidModels
    using DeviceLayout.SolidModels.Experimental
    using DeviceLayout.SolidModels.Experimental: PGRecord, LayerState, Registry
    import Unitful: μm

    stack = SourceStack(
        :metal => SourceLayer(METAL; level=1, thickness=2μm);
        levels=(1 => 0μm,)
    )
    registry = Registry(
        :metal => LayerState(
            [PGRecord("metal__a__i1__rGeneric", :metal, EntityMeta(:metal; name="a"))],
            2
        )
    )
    pg_ops, final_registry, interfaces, deferred =
        compile_layer_ops([(:metal, SolidModels.extrude_z!, ())], stack, registry)
    @test final_registry[:metal].dim == 3
    @test length(pg_ops) == 2
    @test isempty(interfaces)
    @test isempty(deferred)

    @test_throws ArgumentError compile_layer_ops(
        [(:new_layer, SolidModels.difference_geom!, (:missing, :metal))],
        stack,
        registry
    )

    boundary_ops, boundary_registry, _, _ =
        compile_layer_ops([(:edge, SolidModels.get_boundary, (:metal,))], stack, registry)
    @test boundary_registry[:edge].dim == 1
    @test only(boundary_ops)[2] == SolidModels.get_boundary

    translate_ops, translate_registry, _, _ = compile_layer_ops(
        [(:shifted, SolidModels.translate!, (:metal, 1μm, 0μm, 0μm), :copy => true)],
        stack,
        registry
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
        registry
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
            compile_layer_ops([operation], stack, registry)
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
        append_registry
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
        wrong_dimension_registry
    )

    interface_ops, interface_registry, interfaces, deferred = compile_layer_ops(
        [(:interface, SolidModels.intersect_geom!, (:metal, :metal))],
        stack,
        registry
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
    stack = SourceStack(:metal => SourceLayer(METAL; level=1); levels=(1 => 0μm,))
    locators = Experimental._extract_locator_positions(root, stack)
    @test length(locators) == 2
    @test sort([locator.center_x for locator in locators]) == [-10.0, 10.0]
    @test sort([locator.center_y for locator in locators]) == [0.0, 5.0]

    hidden_stack = SourceStack(
        :metal => SourceLayer(METAL; level=1, solidmodel=false);
        levels=(1 => 0μm,)
    )
    @test isempty(Experimental._extract_locator_positions(root, hidden_stack))
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
        SourceStack(
            :surface => SourceLayer(NULL; level=1, gds_meta=GDSMeta(4, 0)),
            :port => SourceLayer(NULL; level=1, gds_meta=GDSMeta(5, 0));
            levels=(1 => 0μm,)
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
        SourceStack(
            :surface => SourceLayer(NULL; level=1, height=3.0, thickness=0.0);
            levels=(1 => 2.0,)
        )
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
        unitless_target.stack
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
        SourceStack(
            :metal => SourceLayer(METAL; level=1, height=0.0, thickness=0.0);
            levels=(1 => 0.0,)
        )
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

@testitem "Experimental SolidModel end-to-end" begin
    using DeviceLayout
    using DeviceLayout.SchematicDrivenLayout
    using DeviceLayout.SolidModels
    using DeviceLayout.SolidModels.Experimental
    using FileIO: save
    import JSON
    using JSONSchema
    import DeviceLayout: nm, μm
    import Unitful: °, ustrip

    output_dir = abspath(joinpath(@__DIR__, "build"))

    @compdef struct MockTransmon <: Component
        name::String = "transmon"
        island_width = 100μm
        island_height = 200μm
        island_ground_gap = 20μm
        port_width = 5μm
        coupler_length = 80μm
        coupler_width = 10μm
        coupler_spacing = 30μm
    end

    function DeviceLayout.hooks(tr::MockTransmon)
        (; island_width, island_ground_gap, coupler_spacing, coupler_length) =
            parameters(tr)
        cutout_half_width = island_width / 2 + island_ground_gap
        # Coupler hooks at the far edge of each arm. When two transmons are fused
        # hook-to-hook, the arm edges meet and the two pads become one metallic island.
        coupler_x = cutout_half_width + coupler_spacing + coupler_length
        return (
            left=PointHook(Point(-coupler_x, zero(cutout_half_width)), π),
            right=PointHook(Point(coupler_x, zero(cutout_half_width)), 0.0)
        )
    end

    function SchematicDrivenLayout._geometry!(cs::CoordinateSystem, tr::MockTransmon)
        (;
            island_width,
            island_height,
            island_ground_gap,
            port_width,
            coupler_length,
            coupler_width,
            coupler_spacing
        ) = parameters(tr)

        # Negative: gap surrounding the island
        island = centered(Rectangle(island_width, island_height))
        gap_region = centered(
            Rectangle(
                island_width + 2island_ground_gap,
                island_height + 2island_ground_gap
            )
        )
        gaps = DeviceLayout.difference2d(gap_region, island)
        gaps_mesh_lengthscale = min(
            island_width,
            island_height,
            island_ground_gap,
            port_width,
            coupler_spacing,
            coupler_width
        )
        place!(cs, meshsized_entity(gaps, gaps_mesh_lengthscale), EntityMeta(:METAL_NEG))

        # Terminal locator on the island
        locator = centered(Rectangle(10μm, 10μm))
        place!(cs, locator, EntityMeta(:METAL_POS; name="island", role=Terminal))

        # Tag locator on the island (ensures island is given a dedicated physical group
        # even if terminal locator above were removed)
        place!(
            cs,
            centered(Rectangle(5μm, 5μm)),
            EntityMeta(:METAL_POS; name="island", role=Tag)
        )

        # Lumped port spanning the gap at the top of the island
        port_y = island_height / 2 + island_ground_gap / 2
        port_rect = centered(
            Rectangle(port_width, island_ground_gap),
            on_pt=Point(zero(island_width), port_y)
        )
        place!(
            cs,
            WithDirection(π / 2)(port_rect),
            EntityMeta(:PORTS; name="jj", role=LumpedPort)
        )

        # Capacitive coupler islands (east and west)
        cutout_half_width = island_width / 2 + island_ground_gap
        for (sign, hook_name) in ((1, "coupler_east"), (-1, "coupler_west"))
            arm_x_start = sign * (cutout_half_width + coupler_spacing)
            arm_x_end = sign * (cutout_half_width + coupler_spacing + coupler_length)
            arm = Rectangle(
                Point(min(arm_x_start, arm_x_end), -(coupler_width / 2)),
                Point(max(arm_x_start, arm_x_end), coupler_width / 2)
            )

            # Isolate the full coupler island from the ground plane.
            gap_x_start = sign * (cutout_half_width + coupler_spacing - island_ground_gap)
            gap_x_end = arm_x_end
            arm_gap_region = Rectangle(
                Point(
                    min(gap_x_start, gap_x_end),
                    -(coupler_width / 2 + island_ground_gap)
                ),
                Point(max(gap_x_start, gap_x_end), coupler_width / 2 + island_ground_gap)
            )
            arm_gap = DeviceLayout.difference2d(arm_gap_region, arm)
            place!(
                cs,
                meshsized_entity(arm_gap, min(coupler_width, coupler_spacing)),
                EntityMeta(:METAL_NEG)
            )

            arm_locator = centered(
                Rectangle(5μm, 5μm),
                on_pt=Point((arm_x_start + arm_x_end) / 2, zero(island_width))
            )
            place!(cs, arm_locator, EntityMeta(:METAL_POS; name=hook_name, role=Terminal))
        end

        return nothing
    end

    @testset "Experimental SolidModel end-to-end" begin
        stack = SourceStack(
            :SUBSTRATE_BOTTOM => SourceLayer(DIELECTRIC; level=0 => 1),
            :METAL_NEG => SourceLayer(NULL; level=1, gds_meta=GDSMeta(10, 0)),
            :METAL_POS => SourceLayer(METAL; level=1, gds_meta=GDSMeta(11, 0)),
            :CHIP_OUTLINE => SourceLayer(NULL; level=1, gds_meta=GDSMeta(20, 0)),
            :PORTS => SourceLayer(NULL; level=1, gds_meta=GDSMeta(30, 0)),
            :BOUNDING_VOLUME => SourceLayer(
                NULL;
                level=0 => 1,
                height=(-500μm, 500μm),
                gds_meta=nothing
            );
            levels=(0 => -500.0μm, 1 => 0.0μm)
        )

        ops = Tuple[
            (
                :METAL_POS,
                SolidModels.difference_geom!,
                (:CHIP_OUTLINE, :METAL_NEG),
                :remove_object => true,
                :remove_tool => false
            ),
            (
                :CUTOUT,
                SolidModels.difference_geom!,
                (:METAL_NEG, :PORTS),
                :remove_object => true
            ),
            (:METAL_POS, SolidModels.union_geom!, (:METAL_POS,)),
            (:VACUUM, SolidModels.difference_geom!, (:BOUNDING_VOLUME, :SUBSTRATE_BOTTOM)),
            (:restrict, SolidModels.restrict_to_volume!, (:BOUNDING_VOLUME,)),
            # Extract the six BOUNDING_VOLUME boundaries as EXTBND_XMIN,
            # EXTBND_XMAX, and so on.
            exnboundaries(:BOUNDING_VOLUME)...,
            (
                :remove,
                SolidModels.remove_group!,
                (:BOUNDING_VOLUME,),
                # Keep the exterior-boundary entities extracted above.
                :remove_entities => false
            )
        ]

        target = Experimental.SolidModelTarget(stack, ops)

        # Build schematic with two MockTransmons fused via coupler hooks.
        # The coupler arms meet at the fuse point, creating a galvanic connection
        # between the two coupler_east and coupler_west locators
        graph = SchematicGraph("e2e_test")
        q1 = add_node!(graph, MockTransmon(; name="q1"))
        fuse!(graph, q1 => :right, MockTransmon(; name="q2") => :left)
        schematic = plan(graph; log_dir=nothing) |> check!
        coordinate_system = schematic.coordinate_system
        planned_port_directions = Dict{String, Vector{Float64}}()
        for (node, ref) in schematic.ref_dict
            direction = rotated_direction(
                WithDirection(π / 2).direction,
                DeviceLayout.transformation(ref)
            )
            turns = Float64(ustrip(°, direction)) / 180
            planned_port_directions[node.id] = Float64[cospi(turns), sinpi(turns), 0.0]
        end

        # Global placements (chip-level geometry, centered on component bounding box)
        chip_size = 1000μm
        chip_center = center(bounds(coordinate_system))
        chip = centered(Rectangle(chip_size, chip_size), on_pt=chip_center)
        place!(coordinate_system, chip, EntityMeta(:CHIP_OUTLINE))
        place!(coordinate_system, chip, EntityMeta(:SUBSTRATE_BOTTOM))
        place!(coordinate_system, chip, EntityMeta(:BOUNDING_VOLUME))

        gnd_pt = chip_center + Point(400μm, 400μm)
        gnd_locator = centered(Rectangle(5μm, 5μm), on_pt=gnd_pt)
        place!(coordinate_system, gnd_locator, EntityMeta(:METAL_POS; role=Ground))

        # Render SolidModel
        solid_model = SolidModel("e2e_test"; overwrite=true)
        SolidModels.gmsh.option.setNumber("General.Verbosity", 2) # errors and warnings only
        solid_model_metadata = render!(solid_model, schematic, target)
        write_metadata(joinpath(output_dir, "sm_metadata.json"), solid_model_metadata)
        schema_path = joinpath(pkgdir(DeviceLayout), "schemas", "sm_metadata.schema.json")
        schema =
            JSONSchema.Schema(JSON.parsefile(schema_path); parent_dir=dirname(schema_path))
        @test isnothing(JSONSchema.validate(schema, solid_model_metadata))

        SolidModels.save(joinpath(output_dir, "e2e_test.xao"), solid_model)

        # Mesh and save
        SolidModels.mesh_scale(1.0)
        SolidModels.gmsh.model.mesh.generate(3)
        SolidModels.save(joinpath(output_dir, "e2e_test.msh2"), solid_model)

        # Render GDS using SourceStack for layer mapping
        cell = Cell("e2e_test", nm)
        render!(cell, coordinate_system, stack; levels=[1])
        flatten!(cell)
        @test !isempty(elements(cell))
        artwork_metadata = Set(element_metadata(cell))
        @test GDSMeta(10, 0) in artwork_metadata
        @test !(GDSMeta(310, 0) in artwork_metadata)
        save(joinpath(output_dir, "e2e_test.gds"), cell)

        @testset "Output files exist" begin
            for filename in
                ("sm_metadata.json", "e2e_test.xao", "e2e_test.gds", "e2e_test.msh2")
                path = joinpath(output_dir, filename)
                @test isfile(path)
                @test filesize(path) > 0
            end
        end

        @testset "SolidModel has expected 3D physical groups" begin
            groups_3d = SolidModels.dimgroupdict(solid_model, 3)
            # Substrate extruded
            @test any(contains("SUBSTRATE_BOTTOM"), keys(groups_3d))
            # Vacuum created
            @test any(contains("VACUUM"), keys(groups_3d))
            # Bounding volume removed
            @test !any(contains("BOUNDING_VOLUME"), keys(groups_3d))
        end

        @testset "SolidModel has expected 2D physical groups" begin
            groups_2d = SolidModels.dimgroupdict(solid_model, 2)
            group_names = collect(keys(groups_2d))
            # All six exterior boundaries exist and have non-empty entity lists
            for suffix in ("XMIN", "XMAX", "YMIN", "YMAX", "ZMIN", "ZMAX")
                matching = filter(contains("EXTBND_$suffix"), group_names)
                @test !isempty(matching)
                pg = groups_2d[first(matching)]
                @test !isempty(SolidModels.entitytags(pg))
            end
            # Port preserved
            @test any(contains("jj"), group_names)
            # METAL_POS recoverable via layers map
            @test haskey(solid_model_metadata["layers"], "METAL_POS")
        end

        @testset "Terminal identification" begin
            terminals = solid_model_metadata["terminals"]
            ground = solid_model_metadata["ground"]

            # One ground plane
            @test length(ground) == 1
            for (_, cc_info) in ground
                @test !isempty(cc_info["pgs"])
            end

            # Terminals: 2 islands + 1 fused coupler pair
            @test length(terminals) == 3
            for (_, cc_info) in terminals
                @test !isempty(cc_info["pgs"])
            end

            # A PG cannot represent more than one terminal or ground CC.
            cc_pg_sets = [
                Set(cc_info["pgs"]) for
                cc_info in Iterators.flatten((values(terminals), values(ground)))
            ]
            for first_idx in eachindex(cc_pg_sets)
                for second_idx = (first_idx + 1):length(cc_pg_sets)
                    @test isempty(intersect(cc_pg_sets[first_idx], cc_pg_sets[second_idx]))
                end
            end

            # Each transmon contributes one tagged CC with a locator ending in ".island"
            island_ccs = filter(collect(terminals)) do (_, cc_info)
                return any(endswith(".island"), cc_info["locators"])
            end
            @test length(island_ccs) == 2

            # Node fusion: q1.coupler_east meets q2.coupler_west at the fuse point
            fused_pair = filter(collect(terminals)) do (_, cc_info)
                locs = cc_info["locators"]
                return any(==("q1.coupler_east"), locs) && any(==("q2.coupler_west"), locs)
            end
            @test length(fused_pair) == 1
        end

        @testset "Port metadata preserved" begin
            pgs = solid_model_metadata["physical_groups"]
            port_pgs = filter(pgs) do (_, data)
                entity_meta = data["entity_meta"]
                return !isnothing(entity_meta) &&
                       entity_meta["role"]["type"] == "LumpedPort"
            end
            # Each transmon gets its own port PG (names prefixed by component node ID)
            @test length(port_pgs) == 2
            for (_, port_data) in port_pgs
                port_name = port_data["entity_meta"]["name"]
                @test endswith(port_name, ".jj")
                node_id = first(split(port_name, "."))
                @test port_data["entity_meta"]["role"]["direction"] ≈
                      planned_port_directions[node_id]
            end
        end

        @testset "Metadata ↔ SolidModel PG consistency" begin
            # Collect all PGs from the SolidModel (across all dimensions)
            solid_model_pgs = Dict{String, Int}()
            for dim = 1:3
                for (pg_name, _) in SolidModels.dimgroupdict(solid_model, dim)
                    solid_model_pgs[pg_name] = dim
                end
            end

            # Collect all PGs tracked in metadata, including terminal/ground sub-PGs.
            meta_pgs = Dict{String, Int}()
            for (pg_name, pg_data) in solid_model_metadata["physical_groups"]
                meta_pgs[pg_name] = pg_data["dim"]
            end
            for (_, cc_info) in solid_model_metadata["terminals"]
                for pg_name in cc_info["pgs"]
                    meta_pgs[pg_name] = 2
                end
            end
            for (_, cc_info) in solid_model_metadata["ground"]
                for pg_name in cc_info["pgs"]
                    meta_pgs[pg_name] = 2
                end
            end

            # Every PG in metadata must exist in the SolidModel
            for (pg_name, dim) in meta_pgs
                @test haskey(solid_model_pgs, pg_name)
                if haskey(solid_model_pgs, pg_name)
                    @test solid_model_pgs[pg_name] == dim
                end
            end

            # Every PG in the SolidModel must exist in metadata
            for (pg_name, dim) in solid_model_pgs
                @test haskey(meta_pgs, pg_name)
                if haskey(meta_pgs, pg_name)
                    @test meta_pgs[pg_name] == dim
                end
            end
        end

        @testset "Terminal/Ground locator geometry never enters the model" begin
            for dim = 0:3
                dimension_groups = SolidModels.dimgroupdict(solid_model, dim)
                for (pg_name, _) in dimension_groups
                    @test !contains(pg_name, "rTerminal")
                    @test !contains(pg_name, "rGround")
                end
            end
        end

        @testset "Tag locator serialized in tagged section" begin
            tagged = solid_model_metadata["tagged"]

            # Each MockTransmon places a Tag locator on its island → 2 tagged entries
            @test length(tagged) == 2
            @test haskey(tagged, "q1.island")
            @test haskey(tagged, "q2.island")

            for (_, tag_info) in tagged
                @test tag_info["layer"] == "METAL_POS"
                @test !isempty(tag_info["pgs"])
                # All referenced PGs should exist in the model
                for pg_name in tag_info["pgs"]
                    @test SolidModels.hasgroup(solid_model, pg_name, 2)
                end
            end
        end

        @testset "Deduplication: non-overlapping 2D PGs" begin
            # INVARIANT: no entity tag appears in more than one 2D PG
            tag_to_pg = Dict{Int32, String}()
            duplicates = Pair{Int32, Tuple{String, String}}[]
            for (pg_name, dim_pg) in SolidModels.dimgroupdict(solid_model, 2)
                for t in SolidModels.entitytags(dim_pg)
                    if haskey(tag_to_pg, t)
                        push!(duplicates, t => (tag_to_pg[t], pg_name))
                    else
                        tag_to_pg[t] = pg_name
                    end
                end
            end
            if !isempty(duplicates)
                @warn "Duplicate entity assignments" count = length(duplicates) examples =
                    first(duplicates, 5)
            end
            @test isempty(duplicates)
        end

        @testset "Deduplication: per-layer conservation via layers map" begin
            # The layers map in metadata should allow recovering each layer's full
            # original entity set (before dedup split/subtracted anything)
            layers_meta = solid_model_metadata["layers"]

            # Every layer's PG list should be non-empty and all PGs should exist in model
            for (_, layer_data) in layers_meta
                pg_names = layer_data["pgs"]
                dim = layer_data["dim"]
                @test !isempty(pg_names)
                for pg_name in pg_names
                    @test SolidModels.hasgroup(solid_model, pg_name, dim)
                end
            end
        end

        # Visualization-only mesh (run last; mutates `solid_model`'s 2D PGs)

        Experimental.remap_to_visualization_pgs!(solid_model, solid_model_metadata)
        visualization_path = joinpath(output_dir, "e2e_test.viz.msh2")
        SolidModels.save(visualization_path, solid_model)
        @test isfile(visualization_path)
        @test filesize(visualization_path) > 0

        println("\nE2E test artifacts in: $output_dir")
    end
end
