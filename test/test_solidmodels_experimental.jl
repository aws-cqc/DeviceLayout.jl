@testitem "EntityMeta and SourceStack" begin
    using DeviceLayout
    using DeviceLayout.SchematicDrivenLayout
    using DeviceLayout.SolidModelsExperimental
    using DeviceLayout.PreferredUnits

    # Offered material types remain present
    @test METAL isa SolidModelsExperimental.Material
    @test DIELECTRIC isa SolidModelsExperimental.Material
    @test NULL isa SolidModelsExperimental.Material

    # Some consumers may take PG as contract
    for role in [Generic(), Terminal(), Ground(), Tag(), WavePort(), LumpedPort()]
        @test SolidModelsExperimental.pgname(EntityMeta(:metal; name="name", role=role)) ==
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
    @test SolidModelsExperimental.pgname(type_role_meta) == "metal__island__i3__rTerminal"
    @test SolidModelsExperimental.map_meta(type_role_meta) ==
          SolidModelsExperimental.pgname(type_role_meta)

    simple_layer = SourceLayer(NULL; thickness=10.0nm)
    offset_layer = SourceLayer(NULL; thickness=15μm, height=5μm)
    stack = SourceStack(:a => simple_layer, :b => offset_layer; levels=(1 => 0.0nm))
    @test simple_layer.level == 1
    @test SolidModelsExperimental.thickness(simple_layer, stack) == 10.0nm
    @test SolidModelsExperimental.thickness(offset_layer, stack) == 15μm # offset shouldn't change thickness

    pair_layer = SourceLayer(NULL; level=1 => 2)
    offset_pair_layer =
        SourceLayer(DIELECTRIC; level=1 => 2, height=(10μm, -10μm), gds_meta=GDSMeta(8, 2))
    @test first(offset_pair_layer.level) == 1
    @test last(offset_pair_layer.level) == 2
    @test first(offset_pair_layer.height) == 10μm
    @test last(offset_pair_layer.height) == -10μm
    stack = SourceStack(:substrate => offset_pair_layer; levels=(1 => 0μm, 2 => 500μm))
    @test SolidModelsExperimental.thickness(pair_layer, stack) == 500μm
    @test SolidModelsExperimental.thickness(stack.layers[:substrate], stack) == 480μm
    @test SolidModelsExperimental.layer_z(:substrate, stack) == 10μm
    @test SolidModelsExperimental.layer_z(stack.layers[:substrate], stack) == 10μm
    @test SolidModelsExperimental.sourcelayer(:substrate, stack) ===
          stack.layers[:substrate]
    @test SolidModelsExperimental.sourcelayer(EntityMeta(:substrate), stack) ===
          stack.layers[:substrate]
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
    @test SolidModelsExperimental.layer_z(:integer, mixed_types_stack) == 0.0μm

    # Referenced level does not exist
    @test_throws ArgumentError SourceStack(
        :bad => SourceLayer(NULL; level=3, gds_meta=GDSMeta(1, 0));
        levels=(1 => 0μm, 2 => 500μm)
    )
end

@testitem "Artwork visibility and offsets" begin
    using DeviceLayout
    using DeviceLayout.SolidModelsExperimental
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
    registry = SolidModelsExperimental.initial_registry(
        SolidModelsExperimental._entity_metas(cs),
        stack
    )
    @test !haskey(registry, :art_only)
    @test haskey(registry, :second)
end

@testitem "Compiler" begin
    using DeviceLayout
    using DeviceLayout.SolidModels
    using DeviceLayout.SolidModelsExperimental
    using DeviceLayout.SolidModelsExperimental: PGRecord, LayerState, LayerRegistry
    using DeviceLayout.SolidModelsExperimental: compile_ops, pgname
    import Unitful: μm

    stack = SourceStack(
        :metal => SourceLayer(METAL; level=1, thickness=2μm),
        :voids => SourceLayer(NULL; level=1, thickness=2μm, keep_interior=false),
        :shell => SourceLayer(METAL; level=1, thickness=2μm, contour_only=true),
        :hollow_shell => SourceLayer(
            METAL;
            level=1,
            thickness=2μm,
            contour_only=true,
            keep_interior=false
        ),
        :flat => SourceLayer(METAL; level=1, thickness=0μm);
        levels=(1 => 0μm,)
    )
    metal_meta = EntityMeta(:metal; name="a")
    voids_meta = EntityMeta(:voids; name="b")
    shell_meta = EntityMeta(:shell; name="c")
    hollow_shell_meta = EntityMeta(:hollow_shell; name="d")
    flat_meta = EntityMeta(:flat; name="e")
    registry = LayerRegistry(
        :metal => LayerState([PGRecord(pgname(metal_meta), :metal, metal_meta)], 2),
        :voids => LayerState([PGRecord(pgname(voids_meta), :voids, voids_meta)], 2),
        :shell => LayerState([PGRecord(pgname(shell_meta), :shell, shell_meta)], 2),
        :hollow_shell => LayerState(
            [PGRecord(pgname(hollow_shell_meta), :hollow_shell, hollow_shell_meta)],
            2
        ),
        :flat => LayerState([PGRecord(pgname(flat_meta), :flat, flat_meta)], 2)
    )

    @testset "Utils" begin
        @test SolidModelsExperimental.ophash("object", ["tool"]; operation=:difference) !=
              SolidModelsExperimental.ophash("object", ["tool"]; operation=:intersect)

        @test length(exterior_boundaries(:volume)) == 6
    end

    @testset "Extrude" begin
        # Standard extrusion replaces the source surface with a volume.
        ops, reg, dints = compile_ops([Extrude(:metal)], stack, registry)
        src = pgname(metal_meta)
        out = only(reg[:metal].pgs)
        @test reg[:metal].dim == 3
        @test out.meta == metal_meta
        @test only(filter(op -> op[2] == SolidModels.extrude_z!, ops))[3] == (src, 2μm, 2)
        @test only(filter(op -> op[2] == SolidModels.remove_group!, ops))[3] == (src, 2)
        @test isempty(SolidModelsExperimental.interface_vertices(dints))

        # A zero-thickness source is left unchanged.
        ops, reg, _ = compile_ops([Extrude(:flat)], stack, registry)
        @test isempty(ops)
        @test reg[:flat].dim == 2
        @test only(reg[:flat].pgs).name == pgname(flat_meta)

        # Contour-only extrusion keeps only the swept shell's vertical walls.
        ops, reg, _ = compile_ops([Extrude(:shell)], stack, registry)
        src = pgname(shell_meta)
        bnd = only(filter(op -> op[2] == SolidModels.get_boundary, ops))
        ext = only(filter(op -> op[2] == SolidModels.extrude_z!, ops))
        @test bnd[3] == (src, 2)
        @test ext[3] == (bnd[1], 2μm, 1)
        @test reg[:shell].dim == 2
        @test only(reg[:shell].pgs).name == ext[1]
        @test !haskey(reg, :EXTBND_MISC) # no interior solids were flush (keep_interior=true)
        # so no external boundaries were added to EXTBND_MISC tracking layer

        # A hollow contour also creates a temporary interior and registers its boundary.
        ops, reg, _ = compile_ops([Extrude(:hollow_shell)], stack, registry)
        src = pgname(hollow_shell_meta)
        int = only(
            filter(op -> op[2] == SolidModels.extrude_z! && op[3] == (src, 2μm, 2), ops)
        )
        intbnd = only(
            filter(op -> op[2] == SolidModels.get_boundary && op[3] == (int[1], 3), ops)
        )
        @test reg[:hollow_shell].dim == 2
        @test only(reg[:EXTBND_MISC].pgs).name == intbnd[1]
        @test any(op -> op[2] == SolidModels.remove_group! && op[3] == (int[1], 3), ops)

        # Interior solids are subtracted from every existing volume before cleanup.
        ops, reg, _ = compile_ops([Extrude(:metal), Extrude(:voids)], stack, registry)
        metal_pg = only(reg[:metal].pgs).name
        voids_src = pgname(voids_meta)
        int = only(
            op[1] for op in ops if
            op[2] == SolidModels.extrude_z! && op[3][1] == voids_src && op[3][3] == 2
        )
        @test any(ops) do op
            return op[2] == SolidModels.difference_geom! && op[3] == (metal_pg, [int], 3, 3)
        end
        @test any(ops) do op
            return op[2] == SolidModels.remove_group! &&
                   op[3] == (int, 3) &&
                   (:remove_entities => false) in op
        end
        @test reg[:metal].dim == 3
        @test reg[:voids].dim == 2

        generated_reg = deepcopy(registry)
        generated_reg[:generated] =
            LayerState([PGRecord("generated", :generated, nothing)], 2)
        @test_throws ArgumentError compile_ops([Extrude(:generated)], stack, generated_reg)
    end

    @testset "Difference" begin
        @test Difference(:dest, :metal, :tool).tools == (:tool,)
        @test Difference(:dest, :metal, [:tool]).tools == (:tool,)
        @test_throws MethodError Difference(:bad, :metal, :first_tool, :second_tool)
        @test_throws ArgumentError Difference(:bad, :metal, Symbol[])

        @test_throws ArgumentError compile_ops(
            [Difference(:new_layer, :missing, :metal)],
            stack,
            registry
        )

        ops, reg, _ = compile_ops([Difference(:voids, :metal, :voids)], stack, registry)
        op = only(filter(op -> op[2] == SolidModels.difference_geom!, ops))
        @test op[3] == (pgname(metal_meta), [pgname(voids_meta)], 2, 2)
        @test startswith(op[1], "voids") # destination layer
        # destination layer is now generated, so its name contains the op hash
        @test op[3] != pgname(voids_meta)
        @test (:remove_object => false) in op
        @test (:remove_tool => false) in op
        @test length(reg[:metal].pgs) == 1
        @test length(reg[:voids].pgs) == 1

        ops, reg, _ =
            compile_ops([Difference(:cut, :metal, :voids), Remove(:metal)], stack, registry)
        op = only(filter(op -> op[2] == SolidModels.difference_geom!, ops))
        @test startswith(op[1], "cut")
        @test op[3] == (pgname(metal_meta), [pgname(voids_meta)], 2, 2)
        @test (:remove_object => true) in op
        @test all(op -> op[2] != SolidModels.remove_group!, ops) # removal was absorbed
        @test !haskey(reg, :metal)

        ops, reg, _ =
            compile_ops([Difference(:cut, :metal, :voids), Remove(:voids)], stack, registry)
        op = only(filter(op -> op[2] == SolidModels.difference_geom!, ops))
        @test startswith(op[1], "cut")
        @test op[3] == (pgname(metal_meta), [pgname(voids_meta)], 2, 2)
        @test (:remove_tool => true) in op
        @test all(op -> op[2] != SolidModels.remove_group!, ops) # removal was absorbed
        @test !haskey(reg, :voids)

        ops, reg, _ = compile_ops([Difference(:metal, :metal, :voids)], stack, registry)
        op = only(filter(op -> op[2] == SolidModels.difference_geom!, ops))
        @test op[1] == pgname(metal_meta) # modifying object in-place retains its name
        @test op[3] == (pgname(metal_meta), [pgname(voids_meta)], 2, 2)
        @test (:remove_object => false) in op
        @test haskey(reg, :metal)
        @test haskey(reg, :voids)

        ops, reg, _ = compile_ops(
            [Difference(:metal, :metal, :voids), Remove(:voids)],
            stack,
            registry
        )
        op = only(filter(op -> op[2] == SolidModels.difference_geom!, ops))
        @test op[1] == pgname(metal_meta) # modifying object in-place retains its name
        @test op[3] == (pgname(metal_meta), [pgname(voids_meta)], 2, 2)
        @test (:remove_object => false) in op
        @test (:remove_tool => true) in op
        @test haskey(reg, :metal)
        @test !haskey(reg, :voids)

        reg = deepcopy(registry)
        second_metal_meta = EntityMeta(:metal; name="second")
        push!(
            reg[:metal].pgs,
            PGRecord(pgname(second_metal_meta), :metal, second_metal_meta)
        )
        second_voids_meta = EntityMeta(:voids; name="second")
        push!(
            reg[:voids].pgs,
            PGRecord(pgname(second_voids_meta), :voids, second_voids_meta)
        )
        ops, reg, _ =
            compile_ops([Difference(:cut, :metal, :voids), Remove(:voids)], stack, reg)
        ops = filter(op -> op[2] == SolidModels.difference_geom!, ops)
        @test reg[:cut].dim == 2
        @test length(reg[:cut].pgs) == 2 # one for each metal object
        @test all(op -> startswith(op[3][1], "metal"), ops)
        @test all(op -> length(op[3][2]) == 2, ops) # two void PGs subtracted from each object
        @test getindex.(ops, Ref(5)) == [:remove_tool => false, :remove_tool => true]

        # Partial tool removal cannot be represented by OCC's all-tools removal flag,
        # so Remove op is not abosrbed into preceding Difference
        ops, reg, _ = compile_ops(
            [Difference(:cut, :metal, (:voids, :shell)), Remove(:voids)],
            stack,
            registry
        )
        op = only(filter(op -> op[2] == SolidModels.difference_geom!, ops))
        @test (:remove_tool => false) in op
        @test any(op -> op[2] == SolidModels.remove_group!, ops)
        @test !haskey(reg, :voids)
        @test haskey(reg, :shell)

        # Removing the destination means removing the result, so it is not absorbed.
        ops, reg, _ = compile_ops(
            [Difference(:metal, :metal, :voids), Remove(:metal)],
            stack,
            registry
        )
        op = only(filter(op -> op[2] == SolidModels.difference_geom!, ops))
        @test (:remove_object => false) in op
        @test any(op -> op[2] == SolidModels.remove_group!, ops)
        @test !haskey(reg, :metal)

        # A non-adjacent removal remains a separate operation (for now, until we
        # implement a more compherensive compiler)
        ops, reg, _ = compile_ops(
            [Difference(:cut, :metal, :voids), Boundary(:edge, :metal), Remove(:metal)],
            stack,
            registry
        )
        op = only(filter(op -> op[2] == SolidModels.difference_geom!, ops))
        @test (:remove_object => false) in op
        @test any(op -> op[2] == SolidModels.remove_group!, ops)
        @test !haskey(reg, :metal)
    end

    @testset "Boundary" begin
        op = Boundary(
            :edge,
            :metal;
            combined=false,
            oriented=false,
            recursive=true,
            direction="Z",
            position="MAX"
        )
        @test !op.combined
        @test !op.oriented
        @test op.recursive
        @test op.direction == "z"
        @test op.position == "max"
        @test_throws ArgumentError Boundary(:bad, :metal; direction="diagonal")
        @test_throws ArgumentError Boundary(:bad, :metal; position="middle")
        @test_throws ArgumentError compile_ops([Boundary(:edge, :missing)], stack, registry)

        # Creating a boundary preserves the source and registers a layer one dimension lower.
        ops, reg, _ = compile_ops([op], stack, registry)
        op = only(ops)
        @test op[2] == SolidModels.get_boundary
        @test op[3] == (pgname(metal_meta), 2)
        @test (:combined => false) in op
        @test (:oriented => false) in op
        @test (:recursive => true) in op
        @test (:direction => "z") in op
        @test (:position => "max") in op
        @test reg[:edge].dim == 1
        @test only(reg[:edge].pgs).name == op[1]
        @test only(reg[:edge].pgs).meta === nothing
        @test haskey(reg, :metal)

        # Every source PG produces one boundary operation and registry record.
        reg = deepcopy(registry)
        second_meta = EntityMeta(:metal; name="second")
        push!(reg[:metal].pgs, PGRecord(pgname(second_meta), :metal, second_meta))
        ops, reg, _ = compile_ops([Boundary(:edge, :metal)], stack, reg)
        @test length(ops) == 2
        @test Set(op[3] for op in ops) ==
              Set([(pgname(metal_meta), 2), (pgname(second_meta), 2)])
        @test length(reg[:edge].pgs) == 2
        @test Set(record.name for record in reg[:edge].pgs) == Set(op[1] for op in ops)

        # Repeated identical boundaries execute with deterministic local suffixes.
        bnd = Boundary(:edge, :metal)
        ops, reg, _ = compile_ops([bnd, bnd], stack, registry)
        @test length(ops) == 2
        @test ops[2][1] == ops[1][1] * "__2"
        @test length(reg[:edge].pgs) == 2
        @test reg[:edge].pgs[1].name == ops[1][1]
        @test reg[:edge].pgs[2].name == ops[2][1]

        # Distinct boundaries append to an existing compatible destination.
        ops, reg, _ = compile_ops(
            [
                Boundary(:edge, :metal; direction="x"),
                Boundary(:edge, :voids; direction="y")
            ],
            stack,
            registry
        )
        @test length(ops) == 2
        @test reg[:edge].dim == 1
        @test length(reg[:edge].pgs) == 2
        @test Set(op[3][1] for op in ops) == Set((pgname(metal_meta), pgname(voids_meta)))

        reg = deepcopy(registry)
        existing = PGRecord("existing", :edge, nothing)
        reg[:edge] = LayerState([existing], 1)
        ops, reg, _ = compile_ops([Boundary(:edge, :metal)], stack, reg)
        @test only(ops)[2] == SolidModels.get_boundary
        @test reg[:edge].pgs[1] == existing
        @test length(reg[:edge].pgs) == 2

        # In-place extraction retains PG identity and metadata while lowering dimension.
        ops, reg, _ = compile_ops([Boundary(:metal, :metal)], stack, registry)
        op = only(ops)
        @test op[1] == pgname(metal_meta)
        @test op[3] == (pgname(metal_meta), 2)
        @test reg[:metal].dim == 1
        @test only(reg[:metal].pgs).meta == metal_meta

        # Repeated in-place extraction executes at each dimension without going below 0D.
        bnd = Boundary(:metal, :metal)
        ops, reg, _ = compile_ops([bnd, bnd, bnd], stack, registry)
        @test length(ops) == 3
        @test getindex.(ops, Ref(3)) ==
              [(pgname(metal_meta), 2), (pgname(metal_meta), 1), (pgname(metal_meta), 0)]
        @test reg[:metal].dim == 0
        @test all(op -> op[1] == pgname(metal_meta), ops)

        # An out-of-place 0D boundary remains a valid, potentially unrealized 0D layer.
        reg = deepcopy(registry)
        point_meta = EntityMeta(:point)
        reg[:point] = LayerState([PGRecord(pgname(point_meta), :point, point_meta)], 0)
        ops, reg, _ = compile_ops([Boundary(:empty, :point)], stack, reg)
        @test only(ops)[3] == (pgname(point_meta), 0)
        @test reg[:empty].dim == 0

        # Existing unrelated destinations must have the boundary dimension.
        reg = deepcopy(registry)
        reg[:edge] = LayerState([PGRecord("wrong_dimension", :edge, nothing)], 2)
        @test_throws ArgumentError compile_ops([Boundary(:edge, :metal)], stack, reg)
    end

    @testset "Translate" begin
        ops, reg, _ =
            compile_ops([Translate(:shifted, :metal, 1μm, 0μm, 0μm)], stack, registry)
        @test haskey(reg, :metal)
        @test reg[:shifted].dim == 2
        @test only(ops)[2] == SolidModels.translate!
        @test (:copy => true) in only(ops)

        ops, reg, _ = compile_ops(
            [Translate(:moved, :metal, 1μm, 0μm, 0μm; copy=false)],
            stack,
            registry
        )
        @test haskey(reg, :metal)
        @test reg[:moved].dim == 2
        @test (:copy => false) in only(ops)

        ops, reg, _ = compile_ops(
            [
                Translate(:shifted, :metal, 1μm, 0μm, 0μm),
                Translate(:shifted, :metal, 2μm, 0μm, 0μm),
                Translate(:shifted, :metal, 2μm, 0μm, 0μm)
            ],
            stack,
            registry
        )
        names = getfield.(reg[:shifted].pgs, :name)
        @test length(names) == 3
        @test allunique(names)
        @test count(op -> op[2] == SolidModels.translate!, ops) == 3

        reg = deepcopy(registry)
        reg[:shifted] = LayerState([PGRecord("wrong_dimension", :shifted, nothing)], 3)
        @test_throws ArgumentError compile_ops(
            [Translate(:shifted, :metal, 1μm, 0μm, 0μm)],
            stack,
            reg
        )
    end

    @testset "Fuse" begin
        @test Fuse(:dest, [:metal]).sources == (:metal,)
        @test Fuse(:metal).sources == (:metal,)
        @test Fuse(:metal).destination == :metal
        @test_throws MethodError Fuse(:bad, :metal)
        @test_throws ArgumentError Fuse(:bad, Symbol[])
        @test_throws ArgumentError Fuse(:bad, (:metal, :metal))
        @test_throws ArgumentError compile_ops(
            [Fuse(:combined, (:missing,))],
            stack,
            registry
        )

        # Even one source is collapsed into one generated PG with a new identity.
        ops, reg, _ = compile_ops([Fuse(:metal)], stack, registry)
        op = only(ops)
        @test startswith(op[1], "metal__")
        @test op[1] != pgname(metal_meta)
        @test op[2] == SolidModels.union_geom!
        @test op[3] == ([pgname(metal_meta)], 2)
        @test (:remove_object => true) in op
        @test only(reg[:metal].pgs).name == op[1]
        @test isnothing(only(reg[:metal].pgs).meta)

        # Every PG in a single source participates in the same collapsed result.
        reg = deepcopy(registry)
        second_meta = EntityMeta(:metal; name="second")
        push!(reg[:metal].pgs, PGRecord(pgname(second_meta), :metal, second_meta))
        ops, reg, _ = compile_ops([Fuse(:combined, (:metal,))], stack, reg)
        op = only(ops)
        @test op[3] == (sort([pgname(metal_meta), pgname(second_meta)]), 2)
        @test (:remove_object => false) in op
        @test haskey(reg, :metal)
        @test length(reg[:combined].pgs) == 1
        @test only(reg[:combined].pgs).name == op[1]
        @test isnothing(only(reg[:combined].pgs).meta)

        # Multiple sources collapse into the same one-PG representation.
        ops, reg, _ = compile_ops([Fuse(:combined, (:metal, :voids))], stack, registry)
        op = only(ops)
        @test startswith(op[1], "combined__")
        @test op[2] == SolidModels.union_geom!
        @test op[3] == (sort([pgname(metal_meta), pgname(voids_meta)]), 2)
        @test (:remove_object => false) in op
        @test haskey(reg, :metal)
        @test haskey(reg, :voids)
        @test only(reg[:combined].pgs).name == op[1]

        # An existing destination must be an explicit source and is collapsed with them.
        @test_throws ArgumentError compile_ops([Fuse(:metal, (:voids,))], stack, registry)
        ops, reg, _ = compile_ops([Fuse(:metal, (:metal, :voids))], stack, registry)
        op = only(ops)
        @test op[3] == (sort([pgname(metal_meta), pgname(voids_meta)]), 2)
        @test length(reg[:metal].pgs) == 1
        @test only(reg[:metal].pgs).name == op[1]
        @test (:remove_object => false) in op
        @test haskey(reg, :voids)

        # Explicit removal controls source lifetime and is folded only when all
        # non-destination sources are removed.
        ops, reg, _ = compile_ops(
            [Fuse(:combined, (:metal, :voids)), Remove(:metal)],
            stack,
            registry
        )
        union_op = only(filter(op -> op[2] == SolidModels.union_geom!, ops))
        @test (:remove_object => false) in union_op
        @test any(op -> op[2] == SolidModels.remove_group!, ops)
        @test !haskey(reg, :metal)
        @test haskey(reg, :voids)

        ops, reg, _ = compile_ops(
            [Fuse(:combined, (:metal, :voids)), Remove(:metal), Remove(:voids)],
            stack,
            registry
        )
        union_op = only(ops)
        @test union_op[2] == SolidModels.union_geom!
        @test (:remove_object => true) in union_op
        @test !haskey(reg, :metal)
        @test !haskey(reg, :voids)

        # Sources must be dimensionally homogeneous and contain at least one PG.
        reg = deepcopy(registry)
        reg[:voids].dim = 3
        @test_throws ArgumentError compile_ops(
            [Fuse(:combined, (:metal, :voids))],
            stack,
            reg
        )
        reg = deepcopy(registry)
        empty!(reg[:metal].pgs)
        @test_throws ArgumentError compile_ops([Fuse(:metal)], stack, reg)
    end

    @testset "Heal" begin
        @test Heal(:metal).destination == :metal
        @test Heal(:combined, :metal).source == :metal
        @test_throws ArgumentError compile_ops([Heal(:combined, :missing)], stack, registry)

        # In-place healing preserves PG names, identities, and metadata.
        ops, reg, _ = compile_ops([Heal(:metal)], stack, registry)
        op = only(ops)
        @test op[1] == pgname(metal_meta)
        @test op[2] == SolidModels.union_geom!
        @test op[3] == (pgname(metal_meta), 2)
        @test (:remove_object => true) in op
        @test only(reg[:metal].pgs).meta == metal_meta

        reg = deepcopy(registry)
        second_meta = EntityMeta(:metal; name="second")
        push!(reg[:metal].pgs, PGRecord(pgname(second_meta), :metal, second_meta))
        ops, reg, _ = compile_ops([Heal(:metal)], stack, reg)
        @test length(ops) == 2
        @test Set(op[1] for op in ops) == Set((pgname(metal_meta), pgname(second_meta)))
        @test Set(record.meta for record in reg[:metal].pgs) ==
              Set((metal_meta, second_meta))

        # Assign mode changes only the layer prefix and preserves the source records.
        ops, reg, _ = compile_ops([Heal(:combined, :metal)], stack, registry)
        op = only(ops)
        expected_name = replace(pgname(metal_meta), "metal__" => "combined__"; count=1)
        @test op[1] == expected_name
        @test op[3] == (pgname(metal_meta), 2)
        @test only(reg[:combined].pgs).name == expected_name
        @test only(reg[:combined].pgs).meta == metal_meta
        @test (:remove_object => false) in op
        @test haskey(reg, :metal)

        reg = deepcopy(registry)
        push!(reg[:metal].pgs, PGRecord(pgname(second_meta), :metal, second_meta))
        ops, reg, _ = compile_ops([Heal(:combined, :metal)], stack, reg)
        expected_second = replace(pgname(second_meta), "metal__" => "combined__"; count=1)
        @test Set(op[1] for op in ops) == Set((expected_name, expected_second))
        @test Set(record.name for record in reg[:combined].pgs) ==
              Set((expected_name, expected_second))
        @test Set(record.meta for record in reg[:combined].pgs) ==
              Set((metal_meta, second_meta))
        @test haskey(reg, :metal)

        # Assigning to an existing destination appends disjoint, identity-preserving PGs.
        reg = deepcopy(registry)
        existing_pg = "combined__existing"
        reg[:combined] = LayerState([PGRecord(existing_pg, :combined, nothing)], 2)
        ops, reg, _ = compile_ops([Heal(:combined, :metal)], stack, reg)
        union_op = only(filter(op -> op[2] == SolidModels.union_geom!, ops))
        difference_op = only(filter(op -> op[2] == SolidModels.difference_geom!, ops))
        @test union_op[1] == expected_name
        @test difference_op[3] == (expected_name, [existing_pg], 2, 2)
        @test (:remove_object => true) in difference_op
        @test (:remove_tool => false) in difference_op
        @test Set(record.name for record in reg[:combined].pgs) ==
              Set((existing_pg, expected_name))
        @test (:remove_object => false) in union_op
        @test haskey(reg, :metal)

        # An adjacent explicit removal is folded into the native heal operation.
        ops, reg, _ =
            compile_ops([Heal(:combined, :metal), Remove(:metal)], stack, registry)
        op = only(ops)
        @test op[2] == SolidModels.union_geom!
        @test (:remove_object => true) in op
        @test !haskey(reg, :metal)

        # Identity collisions and noncanonical source names fail rather than being renamed.
        reg = deepcopy(registry)
        reg[:combined] = LayerState([PGRecord(expected_name, :combined, nothing)], 2)
        @test_throws ArgumentError compile_ops([Heal(:combined, :metal)], stack, reg)

        reg = deepcopy(registry)
        reg[:metal] = LayerState([PGRecord("custom", :metal, metal_meta)], 2)
        @test_throws ArgumentError compile_ops([Heal(:combined, :metal)], stack, reg)

        reg = deepcopy(registry)
        reg[:combined] = LayerState([PGRecord("combined__existing", :combined, nothing)], 3)
        @test_throws ArgumentError compile_ops([Heal(:combined, :metal)], stack, reg)
    end

    @testset "Interface" begin
        @test_throws ArgumentError compile_ops(
            [Interface(:interface, :missing, :metal)],
            stack,
            registry
        )
        @test_throws ArgumentError compile_ops(
            [Interface(:interface, :metal, :missing)],
            stack,
            registry
        )

        # Same-dimensional inputs produce a deferred boundary one dimension lower.
        ops, reg, dints =
            compile_ops([Interface(:interface, :metal, :metal)], stack, registry)
        @test isempty(ops)
        @test reg[:interface].dim == 1
        @test only(reg[:interface].pgs).meta === nothing
        @test only(reg[:interface].pgs).name ==
              "interface__" * SolidModelsExperimental.ophash(
            pgname(metal_meta),
            [pgname(metal_meta)];
            operation=:interface,
            parameters=(2, 2)
        )
        op = only(SolidModelsExperimental.interface_vertices(dints))
        obj, tool = SolidModelsExperimental.operation_pgs(dints, op)
        @test obj == tool
        @test SolidModelsExperimental.MetaGraphs.get_prop(dints, obj, :name) ==
              pgname(metal_meta)
        @test SolidModelsExperimental.MetaGraphs.get_prop(dints, obj, :dim) == 2
        @test SolidModelsExperimental.MetaGraphs.get_prop(dints, op, :dest_pg) ==
              only(reg[:interface].pgs).name
        @test SolidModelsExperimental.MetaGraphs.get_prop(dints, op, :dest_layer) ==
              :interface
        @test SolidModelsExperimental.MetaGraphs.get_prop(dints, op, :parent_layers) ==
              (:metal, :metal)
        @test haskey(reg, :metal)

        # Mixed-dimensional inputs produce an interface at the lower dimension.
        reg = deepcopy(registry)
        volume_meta = EntityMeta(:volume)
        reg[:volume] = LayerState([PGRecord(pgname(volume_meta), :volume, volume_meta)], 3)
        ops, reg, dints = compile_ops([Interface(:surface, :metal, :volume)], stack, reg)
        @test isempty(ops)
        @test reg[:surface].dim == 2
        op = only(SolidModelsExperimental.interface_vertices(dints))
        obj, tool = SolidModelsExperimental.operation_pgs(dints, op)
        @test SolidModelsExperimental.MetaGraphs.get_prop(dints, obj, :dim) == 2
        @test SolidModelsExperimental.MetaGraphs.get_prop(dints, tool, :dim) == 3
        @test SolidModelsExperimental.MetaGraphs.get_prop(dints, op, :parent_layers) ==
              (:metal, :volume)

        # Behavior is symmetric
        delete!(reg, :surface)
        ops, reg, dints = compile_ops([Interface(:surface, :volume, :metal)], stack, reg)
        @test isempty(ops)
        @test reg[:surface].dim == 2
        op = only(SolidModelsExperimental.interface_vertices(dints))
        obj, tool = SolidModelsExperimental.operation_pgs(dints, op)
        @test SolidModelsExperimental.MetaGraphs.get_prop(dints, obj, :dim) == 3
        @test SolidModelsExperimental.MetaGraphs.get_prop(dints, tool, :dim) == 2
        @test SolidModelsExperimental.MetaGraphs.get_prop(dints, op, :parent_layers) ==
              (:volume, :metal)

        # Every object-tool PG pair produces one deferred interface and registry record.
        reg = deepcopy(registry)
        second_metal_meta = EntityMeta(:metal; name="second")
        push!(
            reg[:metal].pgs,
            PGRecord(pgname(second_metal_meta), :metal, second_metal_meta)
        )
        volume_meta = EntityMeta(:volume; name="first")
        second_volume_meta = EntityMeta(:volume; name="second")
        reg[:volume] = LayerState(
            [
                PGRecord(pgname(volume_meta), :volume, volume_meta),
                PGRecord(pgname(second_volume_meta), :volume, second_volume_meta)
            ],
            3
        )
        ops, reg, dints = compile_ops([Interface(:surface, :metal, :volume)], stack, reg)
        dops = SolidModelsExperimental.interface_vertices(dints)
        @test isempty(ops)
        @test length(dops) == 4
        @test length(reg[:surface].pgs) == 4
        @test Set(
            SolidModelsExperimental.MetaGraphs.get_prop(dints, op, :dest_pg) for op in dops
        ) == Set(record.name for record in reg[:surface].pgs)
        @test all(dops) do op
            return SolidModelsExperimental.MetaGraphs.get_prop(dints, op, :parent_layers) ==
                   (:metal, :volume)
        end

        # Repeated identical interfaces are deduplicated.
        ops, reg, dints = compile_ops(
            [Interface(:interface, :metal, :voids), Interface(:interface, :metal, :voids)],
            stack,
            registry
        )
        @test isempty(ops)
        @test length(SolidModelsExperimental.interface_vertices(dints)) == 1
        @test length(reg[:interface].pgs) == 1

        # Distinct interfaces append to an existing compatible destination.
        ops, reg, dints = compile_ops(
            [Interface(:interface, :metal, :voids), Interface(:interface, :metal, :shell)],
            stack,
            registry
        )
        @test isempty(ops)
        @test reg[:interface].dim == 1
        @test length(reg[:interface].pgs) == 2
        @test length(SolidModelsExperimental.interface_vertices(dints)) == 2

        reg = deepcopy(registry)
        existing = PGRecord("existing", :interface, nothing)
        reg[:interface] = LayerState([existing], 1)
        ops, reg, dints = compile_ops([Interface(:interface, :metal, :voids)], stack, reg)
        @test isempty(ops)
        @test reg[:interface].pgs[1] == existing
        @test length(reg[:interface].pgs) == 2
        @test length(SolidModelsExperimental.interface_vertices(dints)) == 1

        # An aliased destination replaces the corresponding source layer.
        ops, reg, dints = compile_ops([Interface(:metal, :metal, :voids)], stack, registry)
        @test isempty(ops)
        @test reg[:metal].dim == 1
        @test only(reg[:metal].pgs).layer == :metal
        @test haskey(reg, :voids)
        op = only(SolidModelsExperimental.interface_vertices(dints))
        @test SolidModelsExperimental.MetaGraphs.get_prop(dints, op, :parent_layers) ==
              (:metal, :voids)

        ops, reg, _ = compile_ops([Interface(:voids, :metal, :voids)], stack, registry)
        @test isempty(ops)
        @test reg[:voids].dim == 1
        @test only(reg[:voids].pgs).layer == :voids
        @test haskey(reg, :metal)

        # Existing unrelated destinations must have the interface dimension.
        reg = deepcopy(registry)
        reg[:interface] = LayerState([PGRecord("existing", :interface, nothing)], 2)
        @test_throws ArgumentError compile_ops(
            [Interface(:interface, :metal, :voids)],
            stack,
            reg
        )

        # Deferred PG vertices are reused, and duplicate destination identities fail
        # without leaving orphan vertices.
        dints = SolidModelsExperimental._deferred_interface_graph()
        SolidModelsExperimental.defer_interface!(
            dints,
            "ab",
            "a",
            "b",
            2,
            3,
            :interface,
            :a,
            :b
        )
        SolidModelsExperimental.defer_interface!(
            dints,
            "ac",
            "a",
            "c",
            2,
            3,
            :interface,
            :a,
            :c
        )
        @test SolidModelsExperimental.Graphs.nv(dints) == 5 # 3 PGs + 2 operations
        @test length(SolidModelsExperimental.interface_vertices(dints)) == 2
        @test_throws ArgumentError SolidModelsExperimental.defer_interface!(
            dints,
            "ab",
            "a",
            "b",
            2,
            3,
            :interface,
            :a,
            :b
        )
        @test_throws ArgumentError SolidModelsExperimental.defer_interface!(
            dints,
            "ab",
            "new_a",
            "new_b",
            2,
            3,
            :interface,
            :new_a,
            :new_b
        )
        @test SolidModelsExperimental.Graphs.nv(dints) == 5
    end

    @testset "Revolve" begin
        rev = Revolve(:revolved, :metal, (0, 0, 0), (0, 0, 1), π)
        @test rev.origin === (0.0, 0.0, 0.0)
        @test rev.axis === (0.0, 0.0, 1.0)
        @test rev.angle === Float64(π)
        @test_throws ArgumentError compile_ops(
            [Revolve(:revolved, :missing, (0, 0, 0), (0, 0, 1), π)],
            stack,
            registry
        )

        # The registry tracks the swept dimension; render cleanup removes lower-dimensional PGs.
        ops, reg, _ = compile_ops([rev], stack, registry)
        op = only(ops)
        @test startswith(op[1], "revolved")
        @test op[2] == SolidModels.revolve!
        @test op[3] == (pgname(metal_meta), 2, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, Float64(π))
        @test reg[:revolved].dim == 3
        @test only(reg[:revolved].pgs).name == op[1]
        @test haskey(reg, :metal)

        # In-place revolution advances the layer dimension while retaining its PG identity.
        rev = Revolve(:metal, :metal, (1, 2, 3), (0, 1, 0), π / 2)
        ops, reg, _ = compile_ops([rev], stack, registry)
        op = only(ops)
        @test op[2] == SolidModels.revolve!
        @test op[1] == pgname(metal_meta)
        @test op[3] == (pgname(metal_meta), 2, 1.0, 2.0, 3.0, 0.0, 1.0, 0.0, π / 2)
        @test reg[:metal].dim == 3
        @test only(reg[:metal].pgs).meta == metal_meta

        # Every source PG is revolved and registered independently.
        reg = deepcopy(registry)
        second_meta = EntityMeta(:metal; name="second")
        push!(reg[:metal].pgs, PGRecord(pgname(second_meta), :metal, second_meta))
        ops, reg, _ =
            compile_ops([Revolve(:revolved, :metal, (0, 0, 0), (1, 0, 0), π)], stack, reg)
        @test length(ops) == 2
        @test length(reg[:revolved].pgs) == 2
        @test Set(op[3][1] for op in ops) == Set((pgname(metal_meta), pgname(second_meta)))

        # Repeated identical revolutions execute and receive deterministic local suffixes.
        rev = Revolve(:revolved, :metal, (0, 0, 0), (0, 0, 1), π)
        ops, reg, _ = compile_ops([rev, rev], stack, registry)
        @test length(ops) == 2
        @test length(reg[:revolved].pgs) == 2
        @test ops[2][1] == ops[1][1] * "__2"
        @test reg[:revolved].pgs[1].name == ops[1][1]
        @test reg[:revolved].pgs[2].name == ops[2][1]

        # Lower-dimensional sources advance by exactly one dimension.
        reg = deepcopy(registry)
        line_meta = EntityMeta(:line)
        reg[:line] = LayerState([PGRecord(pgname(line_meta), :line, line_meta)], 1)
        ops, reg, _ =
            compile_ops([Revolve(:surface, :line, (0, 0, 0), (0, 0, 1), π)], stack, reg)
        @test only(ops)[3][2] == 1
        @test reg[:surface].dim == 2

        # OCC cannot sweep a volume into a fourth dimension.
        reg = deepcopy(registry)
        reg[:volume] = LayerState([PGRecord("volume", :volume, nothing)], 3)
        @test_throws ArgumentError compile_ops(
            [Revolve(:invalid, :volume, (0, 0, 0), (0, 0, 1), π)],
            stack,
            reg
        )

        # Existing destinations must have the swept dimension.
        reg = deepcopy(registry)
        reg[:revolved] = LayerState([PGRecord("existing", :revolved, nothing)], 2)
        @test_throws ArgumentError compile_ops(
            [Revolve(:revolved, :metal, (0, 0, 0), (0, 0, 1), π)],
            stack,
            reg
        )
    end

    @testset "Periodic" begin
        periodic = Periodic(:metal, :voids)
        @test periodic.first == :metal
        @test periodic.second == :voids
        @test_throws ArgumentError compile_ops(
            [Periodic(:missing, :voids)],
            stack,
            registry
        )
        @test_throws ArgumentError compile_ops(
            [Periodic(:metal, :missing)],
            stack,
            registry
        )

        # A pair of single-PG 2D layers maps directly to the native operation.
        ops, reg, dints = compile_ops([periodic], stack, registry)
        op = only(ops)
        @test op[1] == "Periodic_$(pgname(metal_meta))"
        @test op[2] == SolidModels.set_periodic!
        @test op[3] == (pgname(metal_meta), pgname(voids_meta), 2, 2)
        @test reg[:metal].dim == 2
        @test only(reg[:metal].pgs).meta == metal_meta
        @test reg[:voids].dim == 2
        @test only(reg[:voids].pgs).meta == voids_meta
        @test isempty(SolidModelsExperimental.interface_vertices(dints))

        # Repeated periodic operations execute without changing registry state.
        ops, reg, _ = compile_ops([periodic, periodic], stack, registry)
        @test length(ops) == 2
        @test all(op -> op[2] == SolidModels.set_periodic!, ops)
        @test all(op -> op[3] == (pgname(metal_meta), pgname(voids_meta), 2, 2), ops)
        @test only(reg[:metal].pgs).meta == metal_meta
        @test only(reg[:voids].pgs).meta == voids_meta

        # Native periodic pairing supports only surface groups.
        reg = deepcopy(registry)
        reg[:metal].dim = 1
        @test_throws ArgumentError compile_ops([periodic], stack, reg)

        reg = deepcopy(registry)
        reg[:voids].dim = 3
        @test_throws ArgumentError compile_ops([periodic], stack, reg)

        # Positional pairing of multiple PG records is intentionally unsupported.
        reg = deepcopy(registry)
        second_metal_meta = EntityMeta(:metal; name="second")
        push!(
            reg[:metal].pgs,
            PGRecord(pgname(second_metal_meta), :metal, second_metal_meta)
        )
        @test_throws ArgumentError compile_ops([periodic], stack, reg)

        reg = deepcopy(registry)
        second_voids_meta = EntityMeta(:voids; name="second")
        push!(
            reg[:voids].pgs,
            PGRecord(pgname(second_voids_meta), :voids, second_voids_meta)
        )
        @test_throws ArgumentError compile_ops([periodic], stack, reg)
    end

    @testset "RestrictTo" begin
        @test_throws ArgumentError compile_ops([RestrictTo(:missing)], stack, registry)

        # Restriction requires a 3D bounding-volume layer.
        @test_throws ArgumentError compile_ops([RestrictTo(:metal)], stack, registry)

        volume_meta = EntityMeta(:volume)
        volume_pg = PGRecord(pgname(volume_meta), :volume, volume_meta)
        reg = deepcopy(registry)
        reg[:volume] = LayerState([volume_pg], 3)
        ops, out_reg, dints = compile_ops([RestrictTo(:volume)], stack, reg)
        op = only(ops)
        @test op[1] == "restrict"
        @test op[2] == SolidModels.restrict_to_volume!
        @test op[3] == (pgname(volume_meta),)
        @test out_reg[:volume].dim == 3
        @test only(out_reg[:volume].pgs) == volume_pg
        @test Set(keys(out_reg)) == Set(keys(reg))
        @test isempty(SolidModelsExperimental.interface_vertices(dints))

        # Repeated restrictions execute independently without changing registry state.
        ops, out_reg, _ =
            compile_ops([RestrictTo(:volume), RestrictTo(:volume)], stack, reg)
        @test length(ops) == 2
        @test all(op -> op[2] == SolidModels.restrict_to_volume!, ops)
        @test all(op -> op[3] == (pgname(volume_meta),), ops)
        @test only(out_reg[:volume].pgs) == volume_pg

        # A multi-PG layer cannot map to the native single-PG restriction operation.
        reg = deepcopy(reg)
        second_meta = EntityMeta(:volume; name="second")
        push!(reg[:volume].pgs, PGRecord(pgname(second_meta), :volume, second_meta))
        @test_throws ArgumentError compile_ops([RestrictTo(:volume)], stack, reg)
    end

    @testset "Remove" begin
        @test Remove(:metal).remove_entities
        @test !Remove(:metal; remove_entities=false).remove_entities

        # Removing a layer emits one native operation per PG and deletes its registry entry.
        ops, reg, dints = compile_ops([Remove(:metal)], stack, registry)
        op = only(ops)
        @test op[1] == "_rm"
        @test op[2] == SolidModels.remove_group!
        @test op[3] == (pgname(metal_meta), 2)
        @test (:remove_entities => true) in op
        @test !haskey(reg, :metal)
        @test isempty(SolidModelsExperimental.interface_vertices(dints))
        @test haskey(reg, :voids)

        # Physical-group-only removal still deletes the layer registry entry.
        ops, reg, _ = compile_ops([Remove(:metal; remove_entities=false)], stack, registry)
        op = only(ops)
        @test op[3] == (pgname(metal_meta), 2)
        @test (:remove_entities => false) in op
        @test !haskey(reg, :metal)

        # Every PG in the layer is removed with the requested entity behavior.
        reg = deepcopy(registry)
        second_meta = EntityMeta(:metal; name="second")
        push!(reg[:metal].pgs, PGRecord(pgname(second_meta), :metal, second_meta))
        ops, reg, _ = compile_ops([Remove(:metal; remove_entities=false)], stack, reg)
        @test length(ops) == 2
        @test Set(op[3] for op in ops) ==
              Set([(pgname(metal_meta), 2), (pgname(second_meta), 2)])
        @test all(op -> (:remove_entities => false) in op, ops)
        @test !haskey(reg, :metal)

        # Missing and repeated removals are no-ops, matching remove_group! behavior.
        ops, reg, _ = compile_ops([Remove(:missing)], stack, registry)
        @test isempty(ops)
        @test Set(keys(reg)) == Set(keys(registry))

        ops, reg, _ = compile_ops([Remove(:metal), Remove(:metal)], stack, registry)
        @test length(ops) == 1
        @test !haskey(reg, :metal)

        # Later operations cannot use a layer removed earlier in the sequence.
        @test_throws ArgumentError compile_ops(
            [Remove(:metal), Boundary(:edge, :metal)],
            stack,
            registry
        )
    end
end

@testitem "Model physical groups are registered" begin
    using DeviceLayout
    using DeviceLayout.SolidModels
    using DeviceLayout.SolidModelsExperimental
    using DeviceLayout.SolidModelsExperimental: PGRecord, LayerState, LayerRegistry

    sm = SolidModel("registry_validation"; overwrite=true)
    SolidModels.gmsh.option.setNumber("General.Verbosity", 2)
    tag = SolidModels.gmsh.model.occ.addRectangle(0.0, 0.0, 0.0, 1.0, 1.0)
    SolidModels.gmsh.model.occ.synchronize()
    sm["surface"] = [(Int32(2), Int32(tag))]

    registry = LayerRegistry()
    @test_throws ErrorException SolidModelsExperimental._check_pgs_registered(sm, registry)

    registry[:surface] =
        LayerState([PGRecord("surface", :surface, EntityMeta(:surface))], 2)
    @test isnothing(SolidModelsExperimental._check_pgs_registered(sm, registry))
end

@testitem "Placement prefix copies" begin
    using DeviceLayout
    using DeviceLayout.SchematicDrivenLayout
    using DeviceLayout.SolidModelsExperimental
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
    sch_copy = deepcopy(sch)
    SolidModelsExperimental._prefix_placement_names!(sch_copy)

    names_by_node = Dict{String, Vector{String}}()
    for (node, ref) in sch_copy.ref_dict
        names_by_node[node.id] = [
            meta.name for
            (subcs, _) in DeviceLayout.traversal(DeviceLayout.structure(ref)) for
            meta in element_metadata(subcs) if meta isa EntityMeta && !isempty(meta.name)
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
        meta.name for (subcs, _) in DeviceLayout.traversal(sch_copy.coordinate_system)
        for meta in element_metadata(subcs) if meta isa EntityMeta && isempty(meta.name)
    ]
    @test length(empty_names) == 2
    @test element_metadata(component.geometry) == original_metadata
    @test element_metadata(geometry)[1].name == "island"
end

@testitem "LumpedPort directions" begin
    using DeviceLayout
    using DeviceLayout.SolidModelsExperimental
    import Unitful: μm, °, ustrip

    function direction_map(cs)
        directions = Dict{String, Vector{Float64}}()
        flat = flatten(cs)
        for (entity, meta) in zip(elements(flat), element_metadata(flat))
            (meta isa EntityMeta && meta.role isa LumpedPort) || continue
            angle = DeviceLayout.extract_direction(entity)
            turns = Float64(ustrip(°, angle)) / 180
            directions[SolidModelsExperimental.pgname(meta)] =
                Float64[cospi(turns), sinpi(turns), 0.0]
        end
        return directions
    end

    local_cs = CoordinateSystem("local_port", μm)
    nested_port = meshsized_entity(
        optional_entity(WithDirection(30°)(Rectangle(2μm, 1μm)), :port; default=true),
        0.2μm
    )
    local_meta = EntityMeta(:port; name="local", role=LumpedPort)
    place!(local_cs, nested_port, local_meta)
    @test direction_map(local_cs)[SolidModelsExperimental.pgname(local_meta)] ≈
          [cospi(1 / 6), 0.5, 0.0]

    transformed = CoordinateSystem("transformed_ports", μm)
    addref!(transformed, local_cs; rot=90°)
    rotated = direction_map(transformed)[SolidModelsExperimental.pgname(local_meta)]
    @test rotated ≈ [-0.5, cospi(1 / 6), 0.0]

    reflected = CoordinateSystem("reflected_ports", μm)
    addref!(reflected, local_cs; rot=90°, xrefl=true)
    reflected_direction =
        direction_map(reflected)[SolidModelsExperimental.pgname(local_meta)]
    @test reflected_direction ≈ [0.5, cospi(1 / 6), 0.0]
end

@testitem "Tag resolution stays within its declared layer" begin
    using DeviceLayout
    using DeviceLayout.SolidModels
    using DeviceLayout.SolidModelsExperimental
    using DeviceLayout.SolidModelsExperimental: PGRecord, LayerState, LayerRegistry

    sm = SolidModel("tag_layer"; overwrite=true)
    SolidModels.gmsh.option.setNumber("General.Verbosity", 2)
    first_tag = SolidModels.gmsh.model.occ.addRectangle(0.0, 0.0, 0.0, 10.0, 10.0)
    second_tag = SolidModels.gmsh.model.occ.addRectangle(0.0, 0.0, 0.0, 10.0, 10.0)
    SolidModels.gmsh.model.occ.synchronize()
    sm["layer_a"] = [(Int32(2), Int32(first_tag))]
    sm["layer_b"] = [(Int32(2), Int32(second_tag))]
    registry = LayerRegistry(
        :a => LayerState([PGRecord("layer_a", :a, EntityMeta(:a))], 2),
        :b => LayerState([PGRecord("layer_b", :b, EntityMeta(:b))], 2),
        :interface => LayerState([PGRecord("interface_ab", :interface, nothing)], 1)
    )
    locator = SolidModelsExperimental.LocatorRecord(
        EntityMeta(:a; name="tag", role=Tag()),
        (5.0, 5.0, 0.0)
    )
    deferred = SolidModelsExperimental._deferred_interface_graph()
    SolidModelsExperimental.defer_interface!(
        deferred,
        "interface_ab",
        "layer_a",
        "layer_b",
        2,
        2,
        :interface,
        :a,
        :b
    )
    tag_records = SolidModelsExperimental.add_tagged_pgs!(sm, registry, [locator], deferred)
    tag_name = SolidModelsExperimental.pgname(EntityMeta(:a; name="tag", role=Tag()))
    @test tag_records == [(tag_name, "tag", :a)]
    @test SolidModels.hasgroup(sm, tag_name, 2)
    @test SolidModels.entitytags(sm[tag_name, 2]) == [Int32(first_tag)]
    @test length(SolidModelsExperimental.interface_vertices(deferred)) == 2
    @test any(SolidModelsExperimental.interface_vertices(deferred)) do operation
        object, tool = SolidModelsExperimental.operation_pgs(deferred, operation)
        object_name = SolidModelsExperimental.MetaGraphs.get_prop(deferred, object, :name)
        tool_name = SolidModelsExperimental.MetaGraphs.get_prop(deferred, tool, :name)
        return (object_name, tool_name) == (tag_name, "layer_b")
    end
end

@testitem "Deferred interface graph execution" begin
    using DeviceLayout
    using DeviceLayout.SolidModels
    using DeviceLayout.SolidModelsExperimental

    sm = SolidModel("deferred_graph"; overwrite=true)
    SolidModels.gmsh.option.setNumber("General.Verbosity", 2)
    obj_tag = SolidModels.gmsh.model.occ.addBox(0.0, 0.0, 0.0, 1.0, 1.0, 1.0)
    tool_tag = SolidModels.gmsh.model.occ.addBox(1.0, 0.0, 0.0, 1.0, 1.0, 1.0)
    SolidModels.gmsh.model.occ.synchronize()
    sm["object"] = [(Int32(3), Int32(obj_tag))]
    sm["tool"] = [(Int32(3), Int32(tool_tag))]
    SolidModels._fragment_three_pass!(sm)

    same_dim = SolidModelsExperimental._deferred_interface_graph()
    SolidModelsExperimental.defer_interface!(
        same_dim,
        "interface_1",
        "object",
        "tool",
        3,
        3,
        :interface,
        :object,
        :tool
    )
    SolidModelsExperimental.defer_interface!(
        same_dim,
        "interface_2",
        "object",
        "tool",
        3,
        3,
        :interface,
        :object,
        :tool
    )
    SolidModelsExperimental.defer_interface!(
        same_dim,
        "self_interface",
        "object",
        "object",
        3,
        3,
        :interface,
        :object,
        :object
    )
    SolidModelsExperimental.execute_deferred_interfaces!(sm, same_dim)

    interface_tags = SolidModels.entitytags(sm["interface_1", 2])
    @test !isempty(interface_tags)
    @test SolidModels.entitytags(sm["interface_2", 2]) == interface_tags
    @test !isempty(SolidModels.entitytags(sm["self_interface", 2]))

    sm["lower"] = [(Int32(2), tag) for tag in interface_tags]
    mixed_dim = SolidModelsExperimental._deferred_interface_graph()
    SolidModelsExperimental.defer_interface!(
        mixed_dim,
        "lower_first",
        "lower",
        "tool",
        2,
        3,
        :interface,
        :lower,
        :tool
    )
    SolidModelsExperimental.defer_interface!(
        mixed_dim,
        "higher_first",
        "tool",
        "lower",
        3,
        2,
        :interface,
        :tool,
        :lower
    )
    SolidModelsExperimental.execute_deferred_interfaces!(sm, mixed_dim)
    @test SolidModels.entitytags(sm["lower_first", 2]) == interface_tags
    @test SolidModels.entitytags(sm["higher_first", 2]) == interface_tags
end

@testitem "Rendered metadata conforms to schema" begin
    using DeviceLayout
    using DeviceLayout.SchematicDrivenLayout
    using DeviceLayout.SolidModels
    using DeviceLayout.SolidModelsExperimental
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
    graph = SchematicGraph("render")
    add_node!(graph, BasicComponent(geometry); base_id="q1")
    sch = plan(graph; log_dir=nothing)
    check!(sch)
    target = SolidModelsExperimental.SolidModelTarget(
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
    missing_sm = SolidModel("missing_port_style"; overwrite=true)
    SolidModels.gmsh.option.setNumber("General.Verbosity", 2)
    @test_throws ArgumentError render!(missing_sm, missing_sch, target)
    @test isempty(SolidModels.dimgroupdict(missing_sm, 2))

    duplicate_geometry = CoordinateSystem("duplicate_port_identity", μm)
    duplicate_meta = EntityMeta(:port; name="duplicate", role=LumpedPort)
    place!(duplicate_geometry, WithDirection(0°)(Rectangle(1μm, 1μm)), duplicate_meta)
    place!(
        duplicate_geometry,
        WithDirection(0°)(Rectangle(Point(2μm, 0μm), Point(3μm, 1μm))),
        duplicate_meta
    )
    duplicate_graph = SchematicGraph("duplicate_port_identity")
    add_node!(duplicate_graph, BasicComponent(duplicate_geometry); base_id="q1")
    duplicate_sch = plan(duplicate_graph; log_dir=nothing) |> check!
    duplicate_sm = SolidModel("duplicate_port_identity"; overwrite=true)
    @test_throws ArgumentError render!(duplicate_sm, duplicate_sch, target)
    @test isempty(SolidModels.dimgroupdict(duplicate_sm, 2))

    output_dir = mktempdir()
    before = readdir(output_dir)
    metadata = cd(output_dir) do
        sm = SolidModel("schema_test"; overwrite=true)
        return render!(sm, sch, target)
    end
    @test readdir(output_dir) == before
    @test isnothing(JSONSchema.validate(schema, metadata))
    generic_pg = metadata["physical_groups"][SolidModelsExperimental.pgname(
        EntityMeta(:surface; name="q1.pad")
    )]
    @test generic_pg["entity_meta"]["role"]["type"] == "Generic"
    port_pg = metadata["physical_groups"][SolidModelsExperimental.pgname(
        EntityMeta(:port; name="q1.drive", role=LumpedPort)
    )]
    @test port_pg["entity_meta"]["role"] ==
          Dict("type" => "LumpedPort", "direction" => [0.0, 1.0, 0.0])
    @test element_metadata(geometry)[1].name == "pad"

    second_sm = SolidModel("schema_test_repeat"; overwrite=true)
    repeated_metadata = render!(second_sm, sch, target)
    @test repeated_metadata == metadata
    @test element_metadata(geometry)[1].name == "pad"

    json_path = joinpath(output_dir, "metadata.json")
    open(json_path, "w") do io
        return JSON.print(io, metadata, 4)
    end
    @test JSON.parsefile(json_path) == metadata
    @test_throws ArgumentError begin
        sm = SolidModel("no_output_dir"; overwrite=true)
        render!(sm, sch, target; output_dir=output_dir)
    end
end

@testitem "Unitless coordinates and finalization strictness" begin
    using DeviceLayout
    using DeviceLayout.SchematicDrivenLayout
    using DeviceLayout.SolidModels
    using DeviceLayout.SolidModelsExperimental

    unitless_geometry = CoordinateSystem{Float64}("unitless")
    place!(unitless_geometry, Rectangle(10.0, 5.0), EntityMeta(:surface; name="shape"))
    unitless_graph = SchematicGraph("unitless_render")
    add_node!(unitless_graph, BasicComponent(unitless_geometry); base_id="q1")
    unitless_sch = plan(unitless_graph; log_dir=nothing) |> check!
    unitless_target = SolidModelsExperimental.SolidModelTarget(
        SourceStack(
            :surface => SourceLayer(NULL; level=1, height=3.0, thickness=0.0);
            levels=(1 => 2.0,)
        )
    )
    unitless_sm = SolidModel("unitless"; overwrite=true)
    SolidModels.gmsh.option.setNumber("General.Verbosity", 2)
    unitless_metadata = render!(unitless_sm, unitless_sch, unitless_target)
    @test unitless_metadata["metadata"]["assembly"]["levels"]["1"] == 2.0
    @test unitless_metadata["layers"]["surface"]["height"] == 3.0
    @test unitless_metadata["layers"]["surface"]["thickness"] == 0.0

    warning_geometry = CoordinateSystem{Float64}("warning_surface")
    place!(warning_geometry, Rectangle(10.0, 10.0), EntityMeta(:metal; name="floating"))
    warning_graph = SchematicGraph("finalization_warning")
    add_node!(warning_graph, BasicComponent(warning_geometry); base_id="q1")
    log_dir = mktempdir()
    warning_sch = plan(warning_graph; log_dir=log_dir) |> check!
    warning_target = SolidModelsExperimental.SolidModelTarget(
        SourceStack(
            :metal => SourceLayer(METAL; level=1, height=0.0, thickness=0.0);
            levels=(1 => 0.0,)
        )
    )
    strict_sm = SolidModel("strict_warning"; overwrite=true)
    @test_throws ErrorException render!(
        strict_sm,
        warning_sch,
        warning_target;
        strict=:warn
    )
    @test isfile(warning_sch.logger.logname)

    # A second render proves the exceptional strict path closed its working logfile.
    nonstrict_sm = SolidModel("strict_cleanup"; overwrite=true)
    @test render!(nonstrict_sm, warning_sch, warning_target; strict=:no) isa Dict
end

@testitem "SolidModel end-to-end" begin
    using DeviceLayout
    using DeviceLayout.SchematicDrivenLayout
    using DeviceLayout.SolidModels
    using DeviceLayout.SolidModelsExperimental
    using DeviceLayout.SolidModelsExperimental: pgname
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

    @testset "SolidModel end-to-end" begin
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

        ops = [
            Difference(:METAL_POS, :CHIP_OUTLINE, :METAL_NEG),
            Remove(:CHIP_OUTLINE),
            Difference(:CUTOUT, :METAL_NEG, :PORTS),
            Remove(:METAL_NEG),
            Heal(:METAL_POS),
            Difference(:VACUUM, :BOUNDING_VOLUME, :SUBSTRATE_BOTTOM),
            RestrictTo(:BOUNDING_VOLUME),
            # Extract the six BOUNDING_VOLUME boundaries as EXTBND_XMIN,
            # EXTBND_XMAX, and so on.
            exterior_boundaries(:BOUNDING_VOLUME)...,
            # Keep the exterior-boundary entities extracted above.
            Remove(:BOUNDING_VOLUME; remove_entities=false)
        ]

        target = SolidModelsExperimental.SolidModelTarget(stack, ops)

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
        open(joinpath(output_dir, "sm_metadata.json"), "w") do io
            return JSON.print(io, solid_model_metadata, 4)
        end
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
            layers = solid_model_metadata["layers"]
            for layer_name in ("SUBSTRATE_BOTTOM", "VACUUM")
                @test layers[layer_name]["dim"] == 3
                @test all(layers[layer_name]["pgs"]) do pg_name
                    return SolidModels.hasgroup(solid_model, pg_name, 3)
                end
            end
            @test !haskey(layers, "BOUNDING_VOLUME")
        end

        @testset "SolidModel has expected 2D physical groups" begin
            layers = solid_model_metadata["layers"]
            # All six exterior boundaries exist and have non-empty entity lists
            for suffix in ("XMIN", "XMAX", "YMIN", "YMAX", "ZMIN", "ZMAX")
                layer = layers["EXTBND_$suffix"]
                @test layer["dim"] == 2
                @test !isempty(layer["pgs"])
                for pg_name in layer["pgs"]
                    @test !isempty(SolidModels.entitytags(solid_model[pg_name, 2]))
                end
            end
            # METAL_POS recoverable via layers map
            @test haskey(layers, "METAL_POS")
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
                meta = data["entity_meta"]
                return !isnothing(meta) && meta["role"]["type"] == "LumpedPort"
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
            locator_names = [
                "$node.$name" for node in ("q1", "q2") for
                name in ("island", "coupler_east", "coupler_west")
            ]
            locator_pgs = Set(
                pgname(EntityMeta(:METAL_POS; name, role=Terminal)) for
                name in locator_names
            )
            push!(locator_pgs, pgname(EntityMeta(:METAL_POS; role=Ground)))
            model_pgs = Set(
                pg_name for dim = 0:3 for
                pg_name in keys(SolidModels.dimgroupdict(solid_model, dim))
            )
            @test isempty(intersect(locator_pgs, model_pgs))
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

        SolidModelsExperimental.remap_to_visualization_pgs!(
            solid_model,
            solid_model_metadata
        )
        visualization_path = joinpath(output_dir, "e2e_test.viz.msh2")
        SolidModels.save(visualization_path, solid_model)
        @test isfile(visualization_path)
        @test filesize(visualization_path) > 0

        println("\nE2E test artifacts in: $output_dir")
    end
end
