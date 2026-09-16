@testitem "LayerRef, locators, and SourceStack" begin
    using DeviceLayout
    using DeviceLayout.SchematicDrivenLayout
    using DeviceLayout.SolidModelsExperimental:
        DIELECTRIC,
        Ground,
        LayerRef,
        LumpedPort,
        METAL,
        NULL,
        SourceLayer,
        SourceStack,
        Tag,
        Terminal,
        WavePort
    using DeviceLayout.PreferredUnits

    @test METAL isa SolidModelsExperimental.Material
    @test DIELECTRIC isa SolidModelsExperimental.Material
    @test NULL isa SolidModelsExperimental.Material

    layer_ref = LayerRef(:metal)
    @test layer(layer_ref) == :metal

    terminal = Terminal(:metal, "island")
    ground = Ground(:metal)
    tag = Tag(:surface, "junction")
    lumped = LumpedPort(:ports, "drive"; index=2)
    wave = WavePort(:ports, "readout"; index=3)
    @test (layer(terminal), name(terminal)) == (:metal, "island")
    @test layer(ground) == :metal
    @test (layer(tag), name(tag)) == (:surface, "junction")
    @test (layer(lumped), name(lumped), layerindex(lumped)) == (:ports, "drive", 2)
    @test (layer(wave), name(wave), layerindex(wave)) == (:ports, "readout", 3)

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
    @test SolidModelsExperimental.sourcelayer(LayerRef(:substrate), stack) ===
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
    using DeviceLayout.SolidModelsExperimental:
        LayerRef, METAL, NULL, SourceLayer, SourceStack
    import Unitful: μm

    stack = SourceStack(
        :art_only =>
            SourceLayer(NULL; level=1, gds_meta=GDSMeta(10, 5), solidmodel=false),
        :second => SourceLayer(METAL; level=2, gds_meta=GDSMeta(20, 7)),
        :mesh_only => SourceLayer(METAL; level=1, gds_meta=nothing);
        levels=(1 => 0μm, 2 => 500μm)
    )
    cs = CoordinateSystem("art", μm)
    place!(cs, Rectangle(1μm, 1μm), LayerRef(:art_only))
    place!(cs, Rectangle(Point(2μm, 0μm), Point(3μm, 1μm)), LayerRef(:second))
    place!(cs, Rectangle(Point(4μm, 0μm), Point(5μm, 1μm)), LayerRef(:mesh_only))
    place!(cs, Rectangle(Point(6μm, 0μm), Point(7μm, 1μm)), :legacy)

    cell = Cell("art", μm)
    render!(cell, cs, stack; levels=[1, 2], level_increment=GDSMeta(100, 10))
    @test element_metadata(cell) == [GDSMeta(10, 5), GDSMeta(120, 17)]

    missing_cs = CoordinateSystem("missing", μm)
    place!(missing_cs, Rectangle(1μm, 1μm), LayerRef(:unknown))
    @test_throws ArgumentError render!(Cell("missing", μm), missing_cs, stack)
    layer_refs = Set{LayerRef}(meta for meta in element_metadata(cs) if meta isa LayerRef)
    registry = SolidModelsExperimental.initial_registry(layer_refs, stack)
    @test !haskey(registry, :art_only)
    @test haskey(registry, :second)
end

@testitem "Compiler (unit)" begin
    using DeviceLayout
    using DeviceLayout.SolidModels
    using DeviceLayout.SolidModelsExperimental:
        Cut,
        Extrude,
        Fuse,
        GetBoundary,
        GetInterface,
        Heal,
        METAL,
        NULL,
        Remove,
        RestrictTo,
        Revolve,
        SetPeriodic,
        SourceLayer,
        SourceStack,
        Translate,
        PGRecord,
        LayerState,
        LayerRegistry,
        compile_ops,
        exterior_boundaries
    import Unitful: μm

    # Debugging helpers
    function inspect_registry(registry::LayerRegistry; io::IO=stdout)
        for (layer, state) in sort!(collect(registry); by=first)
            println(io, layer, " (dim=", state.dim, ")")
            for record in state.pgs
                print(io, "  ", record.name, " [", record.layer, "]")
                println(io)
            end
        end
        return nothing
    end

    function inspect_ops(ops::AbstractVector; io::IO=stdout)
        for (idx, op) in enumerate(ops)
            print(io, idx, ": ")
            show(io, op[1])
            print(io, " = ", nameof(op[2]))
            show(io, op[3])
            for keyword in op[4:end]
                print(io, "; ")
                show(io, keyword)
            end
            println(io)
        end
        return nothing
    end

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
    metal_pg = "metal__a"
    voids_pg = "voids__b"
    shell_pg = "shell__c"
    hollow_shell_pg = "hollow_shell__d"
    flat_pg = "flat__e"
    registry = LayerRegistry(
        :metal => LayerState([PGRecord(metal_pg, :metal)], 2),
        :voids => LayerState([PGRecord(voids_pg, :voids)], 2),
        :shell => LayerState([PGRecord(shell_pg, :shell)], 2),
        :hollow_shell => LayerState([PGRecord(hollow_shell_pg, :hollow_shell)], 2),
        :flat => LayerState([PGRecord(flat_pg, :flat)], 2)
    )

    @testset "Utils" begin
        @test SolidModelsExperimental.ophash("object", ["tool"]; operation=:cut) !=
              SolidModelsExperimental.ophash("object", ["tool"]; operation=:intersect)

        @test length(exterior_boundaries(:volume)) == 6
    end

    @testset "Extrude" begin
        # Standard extrusion replaces the source surface with a volume.
        ops, reg, dints = compile_ops([Extrude(:metal)], stack, registry)
        src = metal_pg
        out = only(reg[:metal].pgs)
        @test reg[:metal].dim == 3
        @test only(filter(op -> op[2] == SolidModels.extrude_z!, ops))[3] == (src, 2μm, 2)
        @test only(filter(op -> op[2] == SolidModels.remove_group!, ops))[3] == (src, 2)
        @test isempty(SolidModelsExperimental.interface_vertices(dints))

        # A zero-thickness source is left unchanged.
        ops, reg, _ = compile_ops([Extrude(:flat)], stack, registry)
        @test isempty(ops)
        @test reg[:flat].dim == 2
        @test only(reg[:flat].pgs).name == flat_pg

        # Contour-only extrusion keeps only the swept shell's vertical walls.
        ops, reg, _ = compile_ops([Extrude(:shell)], stack, registry)
        src = shell_pg
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
        src = hollow_shell_pg
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
        extruded_metal_pg = only(reg[:metal].pgs).name
        voids_src = voids_pg
        int = only(
            op[1] for op in ops if
            op[2] == SolidModels.extrude_z! && op[3][1] == voids_src && op[3][3] == 2
        )
        @test any(ops) do op
            return op[2] == SolidModels.difference_geom! &&
                   op[3] == (extruded_metal_pg, [int], 3, 3)
        end
        @test any(ops) do op
            return op[2] == SolidModels.remove_group! &&
                   op[3] == (int, 3) &&
                   (:remove_entities => false) in op
        end
        @test reg[:metal].dim == 3
        @test reg[:voids].dim == 2

        generated_reg = deepcopy(registry)
        generated_reg[:generated] = LayerState([PGRecord("generated", :generated)], 2)
        @test_throws ArgumentError compile_ops([Extrude(:generated)], stack, generated_reg)
    end

    @testset "Cut" begin
        @test Cut(:dest, :metal, :tool).tools == (:tool,)
        @test Cut(:dest, :metal, [:tool]).tools == (:tool,)
        @test_throws MethodError Cut(:bad, :metal, :first_tool, :second_tool)
        @test_throws ArgumentError Cut(:bad, :metal, Symbol[])

        @test_throws ArgumentError compile_ops(
            [Cut(:new_layer, :missing, :metal)],
            stack,
            registry
        )

        ops, reg, _ = compile_ops([Cut(:voids, :metal, :voids)], stack, registry)
        op = only(filter(op -> op[2] == SolidModels.difference_geom!, ops))
        @test op[3] == (metal_pg, [voids_pg], 2, 2)
        @test startswith(op[1], "voids") # destination layer
        # destination layer is now generated, so its name contains the op hash
        @test op[1] != voids_pg
        @test (:remove_object => false) in op
        @test (:remove_tool => false) in op
        @test length(reg[:metal].pgs) == 1
        @test length(reg[:voids].pgs) == 1

        ops, reg, _ =
            compile_ops([Cut(:cut, :metal, :voids), Remove(:metal)], stack, registry)
        op = only(filter(op -> op[2] == SolidModels.difference_geom!, ops))
        @test startswith(op[1], "cut")
        @test op[3] == (metal_pg, [voids_pg], 2, 2)
        @test (:remove_object => true) in op
        @test all(op -> op[2] != SolidModels.remove_group!, ops) # removal was absorbed
        @test !haskey(reg, :metal)

        ops, reg, _ =
            compile_ops([Cut(:cut, :metal, :voids), Remove(:voids)], stack, registry)
        op = only(filter(op -> op[2] == SolidModels.difference_geom!, ops))
        @test startswith(op[1], "cut")
        @test op[3] == (metal_pg, [voids_pg], 2, 2)
        @test (:remove_tool => true) in op
        @test all(op -> op[2] != SolidModels.remove_group!, ops) # removal was absorbed
        @test !haskey(reg, :voids)

        ops, reg, _ = compile_ops([Cut(:metal, :metal, :voids)], stack, registry)
        op = only(filter(op -> op[2] == SolidModels.difference_geom!, ops))
        @test op[1] == metal_pg # modifying object in-place retains its name
        @test op[3] == (metal_pg, [voids_pg], 2, 2)
        @test (:remove_object => false) in op
        @test haskey(reg, :metal)
        @test haskey(reg, :voids)

        ops, reg, _ =
            compile_ops([Cut(:metal, :metal, :voids), Remove(:voids)], stack, registry)
        op = only(filter(op -> op[2] == SolidModels.difference_geom!, ops))
        @test op[1] == metal_pg # modifying object in-place retains its name
        @test op[3] == (metal_pg, [voids_pg], 2, 2)
        @test (:remove_object => false) in op
        @test (:remove_tool => true) in op
        @test haskey(reg, :metal)
        @test !haskey(reg, :voids)

        reg = deepcopy(registry)
        second_metal_pg = "metal__second"
        push!(reg[:metal].pgs, PGRecord(second_metal_pg, :metal))
        second_voids_pg = "voids__second"
        push!(reg[:voids].pgs, PGRecord(second_voids_pg, :voids))
        ops, reg, _ = compile_ops([Cut(:cut, :metal, :voids), Remove(:voids)], stack, reg)
        ops = filter(op -> op[2] == SolidModels.difference_geom!, ops)
        @test reg[:cut].dim == 2
        @test length(reg[:cut].pgs) == 2 # one for each metal object
        @test all(op -> startswith(op[3][1], "metal"), ops)
        @test all(op -> length(op[3][2]) == 2, ops) # two void PGs subtracted from each object
        @test getindex.(ops, Ref(5)) == [:remove_tool => false, :remove_tool => true]

        # Partial tool removal cannot be represented by OCC's all-tools removal flag,
        # so the Remove operation is not absorbed into the preceding Cut.
        ops, reg, _ = compile_ops(
            [Cut(:cut, :metal, (:voids, :shell)), Remove(:voids)],
            stack,
            registry
        )
        op = only(filter(op -> op[2] == SolidModels.difference_geom!, ops))
        @test (:remove_tool => false) in op
        @test any(op -> op[2] == SolidModels.remove_group!, ops)
        @test !haskey(reg, :voids)
        @test haskey(reg, :shell)

        # Removing the destination means removing the result, so it is not absorbed.
        ops, reg, _ =
            compile_ops([Cut(:metal, :metal, :voids), Remove(:metal)], stack, registry)
        op = only(filter(op -> op[2] == SolidModels.difference_geom!, ops))
        @test (:remove_object => false) in op
        @test any(op -> op[2] == SolidModels.remove_group!, ops)
        @test !haskey(reg, :metal)

        # A non-adjacent removal remains a separate operation until a more comprehensive
        # compiler can prove that folding it is safe.
        ops, reg, _ = compile_ops(
            [Cut(:cut, :metal, :voids), GetBoundary(:edge, :metal), Remove(:metal)],
            stack,
            registry
        )
        op = only(filter(op -> op[2] == SolidModels.difference_geom!, ops))
        @test (:remove_object => false) in op
        @test any(op -> op[2] == SolidModels.remove_group!, ops)
        @test !haskey(reg, :metal)

        # Independent repeats request the same internal output PG name and are rejected.
        cut = Cut(:cut, :metal, :voids)
        @test_throws ArgumentError compile_ops([cut, cut], stack, registry)
        @test_throws ArgumentError compile_ops([cut, cut, Remove(:metal)], stack, registry)

        # Replace-object repeats operate on the previous result under the same internal PG name.
        ops, reg, _ = compile_ops(
            [Cut(:metal, :metal, :voids), Cut(:metal, :metal, :voids)],
            stack,
            registry
        )
        @test length(ops) == 2
        @test all(op -> op[1] == metal_pg, ops)
        @test all(op -> op[3] == (metal_pg, [voids_pg], 2, 2), ops)
        @test only(reg[:metal].pgs).name == metal_pg

        # Replace-tool repeats use the first difference as the second call's tool.
        ops, reg, _ = compile_ops(
            [Cut(:voids, :metal, :voids), Cut(:voids, :metal, :voids)],
            stack,
            registry
        )
        @test length(ops) == 2
        @test ops[2][3] == (metal_pg, [ops[1][1]], 2, 2)
        @test ops[2][1] != ops[1][1]
        @test only(reg[:voids].pgs).name == ops[2][1]

        # Explicit chains consume a named result from the preceding Cut.
        ops, reg, _ = compile_ops(
            [Cut(:first, :metal, :voids), Cut(:second, :first, :shell)],
            stack,
            registry
        )
        @test length(ops) == 2
        @test ops[2][3] == (ops[1][1], [shell_pg], 2, 2)
        @test haskey(reg, :first)
        @test haskey(reg, :second)
    end

    @testset "GetBoundary" begin
        op = GetBoundary(
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
        @test_throws ArgumentError GetBoundary(:bad, :metal; direction="diagonal")
        @test_throws ArgumentError GetBoundary(:bad, :metal; position="middle")
        @test_throws ArgumentError compile_ops(
            [GetBoundary(:edge, :missing)],
            stack,
            registry
        )

        # Creating a boundary preserves the source and registers a layer one dimension lower.
        ops, reg, _ = compile_ops([op], stack, registry)
        op = only(ops)
        @test op[2] == SolidModels.get_boundary
        @test op[3] == (metal_pg, 2)
        @test (:combined => false) in op
        @test (:oriented => false) in op
        @test (:recursive => true) in op
        @test (:direction => "z") in op
        @test (:position => "max") in op
        @test reg[:edge].dim == 1
        @test only(reg[:edge].pgs).name == op[1]
        @test haskey(reg, :metal)

        # Every source PG produces one boundary operation and registry record.
        reg = deepcopy(registry)
        second_pg = "metal__second"
        push!(reg[:metal].pgs, PGRecord(second_pg, :metal))
        ops, reg, _ = compile_ops([GetBoundary(:edge, :metal)], stack, reg)
        @test length(ops) == 2
        @test Set(op[3] for op in ops) == Set([(metal_pg, 2), (second_pg, 2)])
        @test length(reg[:edge].pgs) == 2
        @test Set(record.name for record in reg[:edge].pgs) == Set(op[1] for op in ops)

        # Independent repeats request the same internal output PG name and are rejected.
        bnd = GetBoundary(:edge, :metal)
        @test_throws ArgumentError compile_ops([bnd, bnd], stack, registry)

        # Appending to an existing unrelated destination is rejected, even for a distinct
        # boundary selection.
        @test_throws ArgumentError compile_ops(
            [
                GetBoundary(:edge, :metal; direction="x"),
                GetBoundary(:edge, :voids; direction="y")
            ],
            stack,
            registry
        )

        reg = deepcopy(registry)
        reg[:edge] = LayerState([PGRecord("existing", :edge)], 1)
        @test_throws ArgumentError compile_ops([GetBoundary(:edge, :metal)], stack, reg)

        # In-place extraction retains its internal PG name while lowering dimension.
        ops, reg, _ = compile_ops([GetBoundary(:metal, :metal)], stack, registry)
        op = only(ops)
        @test op[1] == metal_pg
        @test op[3] == (metal_pg, 2)
        @test reg[:metal].dim == 1

        # Repeated in-place extraction executes at each dimension without going below 0D.
        bnd = GetBoundary(:metal, :metal)
        ops, reg, _ = compile_ops([bnd, bnd, bnd], stack, registry)
        @test length(ops) == 3
        @test getindex.(ops, Ref(3)) == [(metal_pg, 2), (metal_pg, 1), (metal_pg, 0)]
        @test reg[:metal].dim == 0
        @test all(op -> op[1] == metal_pg, ops)

        # Explicit chains consume a named boundary result from the preceding operation.
        ops, reg, _ = compile_ops(
            [GetBoundary(:edges, :metal), GetBoundary(:points, :edges)],
            stack,
            registry
        )
        @test length(ops) == 2
        @test ops[2][3] == (ops[1][1], 1)
        @test reg[:edges].dim == 1
        @test reg[:points].dim == 0

        # An out-of-place 0D boundary remains a valid, potentially unrealized 0D layer.
        reg = deepcopy(registry)
        point_pg = "point__source"
        reg[:point] = LayerState([PGRecord(point_pg, :point)], 0)
        ops, reg, _ = compile_ops([GetBoundary(:empty, :point)], stack, reg)
        @test only(ops)[3] == (point_pg, 0)
        @test reg[:empty].dim == 0

        # Existing unrelated destinations must have the boundary dimension.
        reg = deepcopy(registry)
        reg[:edge] = LayerState([PGRecord("wrong_dimension", :edge)], 2)
        @test_throws ArgumentError compile_ops([GetBoundary(:edge, :metal)], stack, reg)
    end

    @testset "Translate" begin
        @test Translate(:metal, 1μm, 0μm, 0μm).destination == :metal
        @test Translate(:metal, 1μm, 0μm, 0μm).source == :metal
        @test !Translate(:metal, 1μm, 0μm, 0μm).copy
        @test !Translate(:metal, :metal, 1μm, 0μm, 0μm).copy
        @test Translate(:shifted, :metal, 1μm, 0μm, 0μm).copy

        ops, reg, _ =
            compile_ops([Translate(:shifted, :metal, 1μm, 0μm, 0μm)], stack, registry)
        @test haskey(reg, :metal)
        @test reg[:shifted].dim == 2
        @test only(ops)[2] == SolidModels.translate!
        @test (:copy => true) in only(ops)

        @test_throws ArgumentError Translate(:moved, :metal, 1μm, 0μm, 0μm; copy=false)

        # Independent repeats request the same internal output PG name.
        translate = Translate(:shifted, :metal, 1μm, 0μm, 0μm)
        @test_throws ArgumentError compile_ops([translate, translate], stack, registry)

        # Distinct translations may append to one destination; disjointness is the
        # caller's responsibility.
        ops, reg, _ = compile_ops(
            [
                Translate(:shifted, :metal, 1μm, 0μm, 0μm),
                Translate(:shifted, :metal, 2μm, 0μm, 0μm)
            ],
            stack,
            registry
        )
        names = getfield.(reg[:shifted].pgs, :name)
        @test length(names) == 2
        @test allunique(names)
        @test count(op -> op[2] == SolidModels.translate!, ops) == 2

        # In-place noncopying translations accumulate on the previous result.
        ops, reg, _ = compile_ops(
            [Translate(:metal, 1μm, 0μm, 0μm), Translate(:metal, 1μm, 0μm, 0μm)],
            stack,
            registry
        )
        @test length(ops) == 2
        @test all(op -> op[1] == metal_pg, ops)
        @test all(op -> (:copy => false) in op, ops)
        @test only(reg[:metal].pgs).name == metal_pg

        # Repeating an in-place copy would recreate the first internal output PG name.
        in_place_copy = Translate(:metal, :metal, 1μm, 0μm, 0μm; copy=true)
        @test_throws ArgumentError compile_ops(
            [in_place_copy, in_place_copy],
            stack,
            registry
        )

        # Explicit chains consume the translated result from the preceding operation.
        ops, reg, _ = compile_ops(
            [
                Translate(:shifted_x, :metal, 1μm, 0μm, 0μm),
                Translate(:shifted_xy, :shifted_x, 0μm, 2μm, 0μm)
            ],
            stack,
            registry
        )
        @test length(ops) == 2
        @test ops[2][3][1] == ops[1][1]
        @test haskey(reg, :shifted_x)
        @test haskey(reg, :shifted_xy)

        reg = deepcopy(registry)
        reg[:shifted] = LayerState([PGRecord("wrong_dimension", :shifted)], 3)
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

        # Even one source is collapsed into one generated PG with a new internal PG name.
        ops, reg, _ = compile_ops([Fuse(:metal)], stack, registry)
        op = only(ops)
        @test startswith(op[1], "metal__")
        @test op[1] != metal_pg
        @test op[2] == SolidModels.union_geom!
        @test op[3] == ([metal_pg], 2)
        @test (:remove_object => true) in op
        @test only(reg[:metal].pgs).name == op[1]

        # Every PG in a single source participates in the same collapsed result.
        reg = deepcopy(registry)
        second_pg = "metal__second"
        push!(reg[:metal].pgs, PGRecord(second_pg, :metal))
        ops, reg, _ = compile_ops([Fuse(:combined, (:metal,))], stack, reg)
        op = only(ops)
        @test op[3] == (sort([metal_pg, second_pg]), 2)
        @test (:remove_object => false) in op
        @test haskey(reg, :metal)
        @test length(reg[:combined].pgs) == 1
        @test only(reg[:combined].pgs).name == op[1]

        # Multiple sources collapse into the same one-PG representation.
        ops, reg, _ = compile_ops([Fuse(:combined, (:metal, :voids))], stack, registry)
        op = only(ops)
        @test startswith(op[1], "combined__")
        @test op[2] == SolidModels.union_geom!
        @test op[3] == (sort([metal_pg, voids_pg]), 2)
        @test (:remove_object => false) in op
        @test haskey(reg, :metal)
        @test haskey(reg, :voids)
        @test only(reg[:combined].pgs).name == op[1]

        # An unrelated existing destination receives one appended, disjoint fused PG.
        ops, reg, _ = compile_ops([Fuse(:metal, (:voids,))], stack, registry)
        union_op = only(filter(op -> op[2] == SolidModels.union_geom!, ops))
        difference_op = only(filter(op -> op[2] == SolidModels.difference_geom!, ops))
        @test union_op[3] == ([voids_pg], 2)
        @test difference_op[3] == (union_op[1], [metal_pg], 2, 2)
        @test length(reg[:metal].pgs) == 2
        @test reg[:metal].pgs[1].name == metal_pg
        @test reg[:metal].pgs[2].name == union_op[1]
        @test haskey(reg, :voids)

        # Including the destination among the sources collapses and replaces its PGs.
        ops, reg, _ = compile_ops([Fuse(:metal, (:metal, :voids))], stack, registry)
        op = only(ops)
        @test op[3] == (sort([metal_pg, voids_pg]), 2)
        @test length(reg[:metal].pgs) == 1
        @test only(reg[:metal].pgs).name == op[1]
        @test (:remove_object => false) in op
        @test haskey(reg, :voids)

        # Independent repeats request the same internal output PG name and are rejected.
        fuse = Fuse(:combined, (:metal, :voids))
        @test_throws ArgumentError compile_ops([fuse, fuse], stack, registry)

        # Stateful in-place repeats fuse the result produced by the previous call.
        ops, reg, _ = compile_ops([Fuse(:metal), Fuse(:metal)], stack, registry)
        @test length(ops) == 2
        @test ops[2][3] == ([ops[1][1]], 2)
        @test ops[2][1] != ops[1][1]
        @test only(reg[:metal].pgs).name == ops[2][1]

        # Explicit chains consume a named fused result from the preceding operation.
        ops, reg, _ = compile_ops(
            [Fuse(:combined, (:metal, :voids)), Fuse(:all, (:combined, :shell))],
            stack,
            registry
        )
        @test length(ops) == 2
        @test ops[2][3] == (sort([ops[1][1], shell_pg]), 2)
        @test haskey(reg, :combined)
        @test haskey(reg, :all)

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

        reg = deepcopy(registry)
        reg[:combined] = LayerState([PGRecord("combined__existing", :combined)], 3)
        @test_throws ArgumentError compile_ops(
            [Fuse(:combined, (:metal, :voids))],
            stack,
            reg
        )
    end

    @testset "Heal" begin
        @test Heal(:metal).destination == :metal
        @test Heal(:combined, :metal).source == :metal
        @test_throws ArgumentError compile_ops([Heal(:combined, :missing)], stack, registry)

        # In-place healing preserves PG internal PG names.
        ops, reg, _ = compile_ops([Heal(:metal)], stack, registry)
        op = only(ops)
        @test op[1] == metal_pg
        @test op[2] == SolidModels.union_geom!
        @test op[3] == (metal_pg, 2)
        @test (:remove_object => true) in op

        # Stateful repeats heal the result again under the same internal PG.
        ops, reg, _ = compile_ops([Heal(:metal), Heal(:metal)], stack, registry)
        @test length(ops) == 2
        @test all(op -> op[1] == metal_pg, ops)
        @test all(op -> op[3] == (metal_pg, 2), ops)
        @test all(op -> (:remove_object => true) in op, ops)

        reg = deepcopy(registry)
        second_pg = "metal__second"
        push!(reg[:metal].pgs, PGRecord(second_pg, :metal))
        ops, reg, _ = compile_ops([Heal(:metal)], stack, reg)
        @test length(ops) == 2
        @test Set(op[1] for op in ops) == Set((metal_pg, second_pg))

        # Assign mode changes the internal layer prefix and preserves the source records.
        ops, reg, _ = compile_ops([Heal(:combined, :metal)], stack, registry)
        op = only(ops)
        expected_name = replace(metal_pg, "metal__" => "combined__"; count=1)
        @test op[1] == expected_name
        @test op[3] == (metal_pg, 2)
        @test only(reg[:combined].pgs).name == expected_name
        @test (:remove_object => false) in op
        @test haskey(reg, :metal)

        # Independent repeats request the same internal PG and are rejected, even when the
        # second call would otherwise absorb a source removal.
        heal = Heal(:combined, :metal)
        @test_throws ArgumentError compile_ops([heal, heal], stack, registry)
        @test_throws ArgumentError compile_ops(
            [heal, heal, Remove(:metal)],
            stack,
            registry
        )

        # Explicit chains preserve the internal name suffix through successive layer prefixes.
        ops, reg, _ =
            compile_ops([Heal(:clean, :metal), Heal(:cleaner, :clean)], stack, registry)
        clean_name = replace(metal_pg, "metal__" => "clean__"; count=1)
        cleaner_name = replace(clean_name, "clean__" => "cleaner__"; count=1)
        @test length(ops) == 2
        @test ops[1][1] == clean_name
        @test ops[2][1] == cleaner_name
        @test ops[2][3] == (clean_name, 2)
        @test haskey(reg, :metal)
        @test haskey(reg, :clean)

        reg = deepcopy(registry)
        push!(reg[:metal].pgs, PGRecord(second_pg, :metal))
        ops, reg, _ = compile_ops([Heal(:combined, :metal)], stack, reg)
        expected_second = replace(second_pg, "metal__" => "combined__"; count=1)
        @test Set(op[1] for op in ops) == Set((expected_name, expected_second))
        @test Set(record.name for record in reg[:combined].pgs) ==
              Set((expected_name, expected_second))
        @test haskey(reg, :metal)

        # Assigning to an existing destination appends disjoint PGs.
        reg = deepcopy(registry)
        existing_pg = "combined__existing"
        reg[:combined] = LayerState([PGRecord(existing_pg, :combined)], 2)
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
        reg[:combined] = LayerState([PGRecord(expected_name, :combined)], 2)
        @test_throws ArgumentError compile_ops([Heal(:combined, :metal)], stack, reg)

        reg = deepcopy(registry)
        reg[:metal] = LayerState([PGRecord("custom", :metal)], 2)
        @test_throws ArgumentError compile_ops([Heal(:combined, :metal)], stack, reg)

        reg = deepcopy(registry)
        reg[:combined] = LayerState([PGRecord("combined__existing", :combined)], 3)
        @test_throws ArgumentError compile_ops([Heal(:combined, :metal)], stack, reg)
    end

    @testset "Intersect" begin
        intersect = SolidModelsExperimental.Intersect(:intersection, :metal, :voids)
        @test intersect.destination == :intersection
        @test intersect.object == :metal
        @test intersect.tool == :voids
        @test_throws ArgumentError SolidModelsExperimental.Intersect(:self, :metal, :metal)
        @test_throws ArgumentError compile_ops(
            [SolidModelsExperimental.Intersect(:intersection, :missing, :voids)],
            stack,
            registry
        )
        @test_throws ArgumentError compile_ops(
            [SolidModelsExperimental.Intersect(:intersection, :metal, :missing)],
            stack,
            registry
        )

        # One object-tool pair produces one generated OCC intersection.
        ops, reg, _ = compile_ops([intersect], stack, registry)
        op = only(ops)
        @test op[1] ==
              "intersection__" * SolidModelsExperimental.ophash(
            metal_pg,
            [voids_pg];
            operation=:intersect,
            parameters=(2, 2)
        )
        @test op[2] == SolidModels.intersect_geom!
        @test op[3] == (metal_pg, voids_pg, 2, 2)
        @test (:remove_object => false) in op
        @test (:remove_tool => false) in op
        @test reg[:intersection].dim == 2
        @test only(reg[:intersection].pgs).name == op[1]
        @test haskey(reg, :metal)
        @test haskey(reg, :voids)

        # Mixed-dimensional inputs produce a layer at the lower input dimension.
        reg = deepcopy(registry)
        volume_pg = "volume__source"
        reg[:volume] = LayerState([PGRecord(volume_pg, :volume)], 3)
        ops, reg, _ = compile_ops(
            [SolidModelsExperimental.Intersect(:surface, :volume, :metal)],
            stack,
            reg
        )
        @test only(ops)[3] == (volume_pg, metal_pg, 3, 2)
        @test reg[:surface].dim == 2

        # Every object-tool PG pair receives an independent internal output PG name.
        reg = deepcopy(registry)
        second_metal_pg = "metal__second"
        second_voids_pg = "voids__second"
        push!(reg[:metal].pgs, PGRecord(second_metal_pg, :metal))
        push!(reg[:voids].pgs, PGRecord(second_voids_pg, :voids))
        ops, reg, _ = compile_ops([intersect], stack, reg)
        @test length(ops) == 4
        @test length(reg[:intersection].pgs) == 4
        @test Set(op[3][1:2] for op in ops) == Set(
            (object, tool) for object in (metal_pg, second_metal_pg) for
            tool in (voids_pg, second_voids_pg)
        )

        # Generated destination collisions are rejected.
        @test_throws ArgumentError compile_ops([intersect, intersect], stack, registry)

        # Appending clips new results against existing destination PGs.
        reg = deepcopy(registry)
        existing_pg = "existing"
        reg[:intersection] = LayerState([PGRecord(existing_pg, :intersection)], 2)
        ops, reg, _ = compile_ops([intersect], stack, reg)
        intersection_op = only(filter(op -> op[2] == SolidModels.intersect_geom!, ops))
        difference_op = only(filter(op -> op[2] == SolidModels.difference_geom!, ops))
        @test difference_op[3] == (intersection_op[1], [existing_pg], 2, 2)
        @test (:remove_object => true) in difference_op
        @test (:remove_tool => false) in difference_op
        @test reg[:intersection].pgs[1].name == existing_pg
        @test reg[:intersection].pgs[2].name == intersection_op[1]

        reg = deepcopy(registry)
        reg[:intersection] = LayerState([PGRecord("wrong_dimension", :intersection)], 3)
        @test_throws ArgumentError compile_ops([intersect], stack, reg)

        # Aliased destinations replace the corresponding source layer.
        ops, reg, _ = compile_ops(
            [SolidModelsExperimental.Intersect(:metal, :metal, :voids)],
            stack,
            registry
        )
        @test length(ops) == 1
        @test (:remove_object => true) in only(ops)
        @test (:remove_tool => false) in only(ops)
        @test reg[:metal].dim == 2
        @test only(reg[:metal].pgs).name == only(ops)[1]
        @test haskey(reg, :voids)

        ops, reg, _ = compile_ops(
            [SolidModelsExperimental.Intersect(:voids, :metal, :voids)],
            stack,
            registry
        )
        @test length(ops) == 1
        @test (:remove_object => false) in only(ops)
        @test (:remove_tool => true) in only(ops)
        @test only(reg[:voids].pgs).name == only(ops)[1]
        @test haskey(reg, :metal)

        # Object and tool lifetime is controlled by adjacent Remove operations.
        ops, reg, _ =
            compile_ops([intersect, Remove(:metal), Remove(:voids)], stack, registry)
        op = only(ops)
        @test (:remove_object => true) in op
        @test (:remove_tool => true) in op
        @test !haskey(reg, :metal)
        @test !haskey(reg, :voids)

        ops, reg, _ = compile_ops([intersect, Remove(:metal)], stack, registry)
        op = only(ops)
        @test (:remove_object => true) in op
        @test (:remove_tool => false) in op
        @test !haskey(reg, :metal)
        @test haskey(reg, :voids)

        ops, reg, _ = compile_ops([intersect, Remove(:voids)], stack, registry)
        op = only(ops)
        @test (:remove_object => false) in op
        @test (:remove_tool => true) in op
        @test haskey(reg, :metal)
        @test !haskey(reg, :voids)

        # Removal flags are scheduled only on each PG's final cross-product use.
        reg = deepcopy(registry)
        push!(reg[:metal].pgs, PGRecord(second_metal_pg, :metal))
        push!(reg[:voids].pgs, PGRecord(second_voids_pg, :voids))
        ops, reg, _ = compile_ops([intersect, Remove(:metal), Remove(:voids)], stack, reg)
        @test getindex.(ops, Ref(4)) == [
            :remove_object => false,
            :remove_object => true,
            :remove_object => false,
            :remove_object => true
        ]
        @test getindex.(ops, Ref(5)) == [
            :remove_tool => false,
            :remove_tool => false,
            :remove_tool => true,
            :remove_tool => true
        ]
        @test !haskey(reg, :metal)
        @test !haskey(reg, :voids)

        # A removal naming an aliased destination applies to the result and is not absorbed.
        ops, reg, _ = compile_ops(
            [SolidModelsExperimental.Intersect(:metal, :metal, :voids), Remove(:metal)],
            stack,
            registry
        )
        intersection_op = only(filter(op -> op[2] == SolidModels.intersect_geom!, ops))
        @test (:remove_object => true) in intersection_op
        @test any(op -> op[2] == SolidModels.remove_group!, ops)
        @test !haskey(reg, :metal)

        # A following removal does not make a duplicate internal output PG name valid.
        @test_throws ArgumentError compile_ops(
            [intersect, intersect, Remove(:metal)],
            stack,
            registry
        )

        # Empty source layers cannot produce a cross product.
        reg = deepcopy(registry)
        empty!(reg[:metal].pgs)
        @test_throws ArgumentError compile_ops([intersect], stack, reg)
        reg = deepcopy(registry)
        empty!(reg[:voids].pgs)
        @test_throws ArgumentError compile_ops([intersect], stack, reg)

        # OCC may realize fewer than A*B nonempty destination PGs.
        sm = SolidModel("intersect_cross_product"; overwrite=true)
        SolidModels.gmsh.option.setNumber("General.Verbosity", 2)
        rectangles = (
            "object_1" => (0.0, 0.0, 2.0, 2.0),
            "object_2" => (10.0, 0.0, 2.0, 2.0),
            "tool_1" => (1.0, 0.0, 2.0, 2.0),
            "tool_2" => (20.0, 0.0, 2.0, 2.0)
        )
        reg = LayerRegistry()
        for (name, (x, y, dx, dy)) in rectangles
            tag = SolidModels.gmsh.model.occ.addRectangle(x, y, 0.0, dx, dy)
            SolidModels.gmsh.model.occ.synchronize()
            sm[name] = [(Int32(2), Int32(tag))]
        end
        reg[:objects] =
            LayerState([PGRecord("object_1", :objects), PGRecord("object_2", :objects)], 2)
        reg[:tools] =
            LayerState([PGRecord("tool_1", :tools), PGRecord("tool_2", :tools)], 2)
        ops, reg, _ = compile_ops(
            [SolidModelsExperimental.Intersect(:results, :objects, :tools)],
            stack,
            reg
        )
        @test length(reg[:results].pgs) == 4 # speculative compiler records
        reg[:empty_results] = LayerState([PGRecord("unrealized", :empty_results)], 2)
        SolidModels._postrender!(sm, ops)
        SolidModelsExperimental._prune_unrealized_pgs!(sm, reg)
        @test length(reg[:results].pgs) == 1
        @test haskey(reg, :empty_results)
        @test isempty(reg[:empty_results].pgs)
    end

    @testset "GetInterface" begin
        @test_throws ArgumentError GetInterface(:metal, :metal, :voids)
        @test_throws ArgumentError GetInterface(:voids, :metal, :voids)
        @test_throws ArgumentError compile_ops(
            [GetInterface(:interface, :missing, :metal)],
            stack,
            registry
        )
        @test_throws ArgumentError compile_ops(
            [GetInterface(:interface, :metal, :missing)],
            stack,
            registry
        )

        # Same-dimensional inputs produce a deferred boundary one dimension lower.
        ops, reg, dints =
            compile_ops([GetInterface(:interface, :metal, :metal)], stack, registry)
        @test isempty(ops)
        @test reg[:interface].dim == 1
        @test only(reg[:interface].pgs).name ==
              "interface__" * SolidModelsExperimental.ophash(
            metal_pg,
            [metal_pg];
            operation=:get_interface,
            parameters=(2, 2)
        )
        op = only(SolidModelsExperimental.interface_vertices(dints))
        obj, tool = SolidModelsExperimental.operation_pgs(dints, op)
        @test obj == tool
        @test SolidModelsExperimental.MetaGraphs.get_prop(dints, obj, :name) == metal_pg
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
        volume_pg = "volume__source"
        reg[:volume] = LayerState([PGRecord(volume_pg, :volume)], 3)
        ops, reg, dints = compile_ops([GetInterface(:surface, :metal, :volume)], stack, reg)
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
        ops, reg, dints = compile_ops([GetInterface(:surface, :volume, :metal)], stack, reg)
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
        second_metal_pg = "metal__second"
        push!(reg[:metal].pgs, PGRecord(second_metal_pg, :metal))
        volume_pg = "volume__first"
        second_volume_pg = "volume__second"
        reg[:volume] = LayerState(
            [PGRecord(volume_pg, :volume), PGRecord(second_volume_pg, :volume)],
            3
        )
        ops, reg, dints = compile_ops([GetInterface(:surface, :metal, :volume)], stack, reg)
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

        # Repeated independent interfaces request the same internal PG and are rejected.
        interface = GetInterface(:interface, :metal, :voids)
        @test_throws ArgumentError compile_ops([interface, interface], stack, registry)

        # Distinct interfaces append to an existing compatible destination.
        ops, reg, dints = compile_ops(
            [
                GetInterface(:interface, :metal, :voids),
                GetInterface(:interface, :metal, :shell)
            ],
            stack,
            registry
        )
        @test isempty(ops)
        @test reg[:interface].dim == 1
        @test length(reg[:interface].pgs) == 2
        @test length(SolidModelsExperimental.interface_vertices(dints)) == 2

        reg = deepcopy(registry)
        existing = PGRecord("existing", :interface)
        reg[:interface] = LayerState([existing], 1)
        ops, reg, dints =
            compile_ops([GetInterface(:interface, :metal, :voids)], stack, reg)
        @test isempty(ops)
        @test reg[:interface].pgs[1] == existing
        @test length(reg[:interface].pgs) == 2
        @test length(SolidModelsExperimental.interface_vertices(dints)) == 1

        # Explicit chains consume an earlier deferred destination without aliasing inputs.
        ops, reg, dints = compile_ops(
            [
                GetInterface(:metal_voids, :metal, :voids),
                GetInterface(:chained, :metal_voids, :shell)
            ],
            stack,
            registry
        )
        @test isempty(ops)
        @test reg[:metal_voids].dim == 1
        @test reg[:chained].dim == 1
        dops = SolidModelsExperimental.interface_vertices(dints)
        @test length(dops) == 2
        chained = only(
            op for op in dops if
            SolidModelsExperimental.MetaGraphs.get_prop(dints, op, :dest_layer) == :chained
        )
        @test SolidModelsExperimental.MetaGraphs.get_prop(dints, chained, :parent_layers) ==
              (:metal_voids, :shell)

        # Deferred inputs must retain the same registered PG name and dimension.
        @test_throws ArgumentError compile_ops([interface, Remove(:metal)], stack, registry)
        @test_throws ArgumentError compile_ops(
            [interface, GetBoundary(:metal, :metal)],
            stack,
            registry
        )

        # Out-of-place operations may use a deferred input while preserving it.
        ops, reg, dints =
            compile_ops([interface, GetBoundary(:edge, :metal)], stack, registry)
        @test length(ops) == 1
        @test haskey(reg, :metal)
        @test haskey(reg, :edge)
        @test length(SolidModelsExperimental.interface_vertices(dints)) == 1

        # Existing unrelated destinations must have the interface dimension.
        reg = deepcopy(registry)
        reg[:interface] = LayerState([PGRecord("existing", :interface)], 2)
        @test_throws ArgumentError compile_ops(
            [GetInterface(:interface, :metal, :voids)],
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
        in_place = Revolve(:metal, (0, 0, 0), (0, 0, 1), π)
        @test in_place.destination == :metal
        @test in_place.source == :metal
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
        @test op[3] == (metal_pg, 2, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, Float64(π))
        @test reg[:revolved].dim == 3
        @test only(reg[:revolved].pgs).name == op[1]
        @test haskey(reg, :metal)

        # In-place revolution advances the layer dimension while retaining its internal PG name.
        rev = Revolve(:metal, :metal, (1, 2, 3), (0, 1, 0), π / 2)
        ops, reg, _ = compile_ops([rev], stack, registry)
        op = only(ops)
        @test op[2] == SolidModels.revolve!
        @test op[1] == metal_pg
        @test op[3] == (metal_pg, 2, 1.0, 2.0, 3.0, 0.0, 1.0, 0.0, π / 2)
        @test reg[:metal].dim == 3

        # Every source PG is revolved and registered independently.
        reg = deepcopy(registry)
        second_pg = "metal__second"
        push!(reg[:metal].pgs, PGRecord(second_pg, :metal))
        ops, reg, _ =
            compile_ops([Revolve(:revolved, :metal, (0, 0, 0), (1, 0, 0), π)], stack, reg)
        @test length(ops) == 2
        @test length(reg[:revolved].pgs) == 2
        @test Set(op[3][1] for op in ops) == Set((metal_pg, second_pg))

        # Independent repeats request the same internal output PG name and are rejected.
        rev = Revolve(:revolved, :metal, (0, 0, 0), (0, 0, 1), π)
        @test_throws ArgumentError compile_ops([rev, rev], stack, registry)

        # Lower-dimensional sources advance by exactly one dimension.
        reg = deepcopy(registry)
        line_pg = "line__source"
        reg[:line] = LayerState([PGRecord(line_pg, :line)], 1)
        ops, reg, _ =
            compile_ops([Revolve(:surface, :line, (0, 0, 0), (0, 0, 1), π)], stack, reg)
        @test only(ops)[3][2] == 1
        @test reg[:surface].dim == 2

        # In-place repeats advance through successive dimensions.
        reg = deepcopy(registry)
        reg[:line] = LayerState([PGRecord(line_pg, :line)], 1)
        revolve_line = Revolve(:line, (0, 0, 0), (0, 0, 1), π)
        ops, reg, _ = compile_ops([revolve_line, revolve_line], stack, reg)
        @test length(ops) == 2
        @test ops[1][3][2] == 1
        @test ops[2][3][2] == 2
        @test reg[:line].dim == 3
        @test all(op -> op[1] == line_pg, ops)

        # Explicit chains consume the named result from the preceding revolution.
        reg = deepcopy(registry)
        reg[:line] = LayerState([PGRecord(line_pg, :line)], 1)
        ops, reg, _ = compile_ops(
            [
                Revolve(:surface, :line, (0, 0, 0), (0, 0, 1), π),
                Revolve(:volume, :surface, (0, 0, 0), (1, 0, 0), π / 2)
            ],
            stack,
            reg
        )
        @test length(ops) == 2
        @test ops[2][3][1] == ops[1][1]
        @test ops[2][3][2] == 2
        @test reg[:surface].dim == 2
        @test reg[:volume].dim == 3

        # Distinct revolutions may append when their generated identities differ.
        ops, reg, _ = compile_ops(
            [
                Revolve(:revolved, :metal, (0, 0, 0), (0, 0, 1), π),
                Revolve(:revolved, :voids, (0, 0, 0), (1, 0, 0), π)
            ],
            stack,
            registry
        )
        @test length(ops) == 2
        @test length(reg[:revolved].pgs) == 2
        @test allunique(record.name for record in reg[:revolved].pgs)

        # OCC cannot sweep a volume into a fourth dimension.
        reg = deepcopy(registry)
        reg[:volume] = LayerState([PGRecord("volume", :volume)], 3)
        @test_throws ArgumentError compile_ops(
            [Revolve(:invalid, :volume, (0, 0, 0), (0, 0, 1), π)],
            stack,
            reg
        )

        # Existing destinations must have the swept dimension.
        reg = deepcopy(registry)
        reg[:revolved] = LayerState([PGRecord("existing", :revolved)], 2)
        @test_throws ArgumentError compile_ops(
            [Revolve(:revolved, :metal, (0, 0, 0), (0, 0, 1), π)],
            stack,
            reg
        )
    end

    @testset "SetPeriodic" begin
        periodic = SetPeriodic(:metal, :voids)
        @test periodic.first == :metal
        @test periodic.second == :voids
        @test_throws ArgumentError SetPeriodic(:metal, :metal)
        @test_throws ArgumentError compile_ops(
            [SetPeriodic(:missing, :voids)],
            stack,
            registry
        )
        @test_throws ArgumentError compile_ops(
            [SetPeriodic(:metal, :missing)],
            stack,
            registry
        )

        # A pair of single-PG 2D layers maps directly to the native operation.
        ops, reg, dints = compile_ops([periodic], stack, registry)
        op = only(ops)
        @test op[1] == "Periodic_$(metal_pg)"
        @test op[2] == SolidModels.set_periodic!
        @test op[3] == (metal_pg, voids_pg, 2, 2)
        @test reg[:metal].dim == 2
        @test reg[:voids].dim == 2
        @test isempty(SolidModelsExperimental.interface_vertices(dints))

        # Repeated periodic operations execute without changing registry state.
        ops, reg, _ = compile_ops([periodic, periodic], stack, registry)
        @test length(ops) == 2
        @test all(op -> op[2] == SolidModels.set_periodic!, ops)
        @test all(op -> op[3] == (metal_pg, voids_pg, 2, 2), ops)

        # Native periodic pairing supports only surface groups.
        reg = deepcopy(registry)
        reg[:metal].dim = 1
        @test_throws ArgumentError compile_ops([periodic], stack, reg)

        reg = deepcopy(registry)
        reg[:voids].dim = 3
        @test_throws ArgumentError compile_ops([periodic], stack, reg)

        # Positional pairing of multiple PG records is intentionally unsupported.
        reg = deepcopy(registry)
        second_metal_pg = "metal__second"
        push!(reg[:metal].pgs, PGRecord(second_metal_pg, :metal))
        @test_throws ArgumentError compile_ops([periodic], stack, reg)

        reg = deepcopy(registry)
        second_voids_pg = "voids__second"
        push!(reg[:voids].pgs, PGRecord(second_voids_pg, :voids))
        @test_throws ArgumentError compile_ops([periodic], stack, reg)
    end

    @testset "RestrictTo" begin
        @test_throws ArgumentError compile_ops([RestrictTo(:missing)], stack, registry)

        # Restriction requires a 3D bounding-volume layer.
        @test_throws ArgumentError compile_ops([RestrictTo(:metal)], stack, registry)

        volume_pg = "volume__source"
        volume_record = PGRecord(volume_pg, :volume)
        reg = deepcopy(registry)
        reg[:volume] = LayerState([volume_record], 3)
        ops, out_reg, dints = compile_ops([RestrictTo(:volume)], stack, reg)
        op = only(ops)
        @test op[1] == "restrict"
        @test op[2] == SolidModels.restrict_to_volume!
        @test op[3] == (volume_pg,)
        @test out_reg[:volume].dim == 3
        @test only(out_reg[:volume].pgs) == volume_record
        @test Set(keys(out_reg)) == Set(keys(reg))
        @test isempty(SolidModelsExperimental.interface_vertices(dints))

        # Repeated restrictions execute independently without changing registry state.
        ops, out_reg, _ =
            compile_ops([RestrictTo(:volume), RestrictTo(:volume)], stack, reg)
        @test length(ops) == 2
        @test all(op -> op[2] == SolidModels.restrict_to_volume!, ops)
        @test all(op -> op[3] == (volume_pg,), ops)
        @test only(out_reg[:volume].pgs) == volume_record

        # A multi-PG layer cannot map to the native single-PG restriction operation.
        reg = deepcopy(reg)
        second_pg = "volume__second"
        push!(reg[:volume].pgs, PGRecord(second_pg, :volume))
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
        @test op[3] == (metal_pg, 2)
        @test (:remove_entities => true) in op
        @test !haskey(reg, :metal)
        @test isempty(SolidModelsExperimental.interface_vertices(dints))
        @test haskey(reg, :voids)

        # Physical-group-only removal still deletes the layer registry entry.
        ops, reg, _ = compile_ops([Remove(:metal; remove_entities=false)], stack, registry)
        op = only(ops)
        @test op[3] == (metal_pg, 2)
        @test (:remove_entities => false) in op
        @test !haskey(reg, :metal)

        # Every PG in the layer is removed with the requested entity behavior.
        reg = deepcopy(registry)
        second_pg = "metal__second"
        push!(reg[:metal].pgs, PGRecord(second_pg, :metal))
        ops, reg, _ = compile_ops([Remove(:metal; remove_entities=false)], stack, reg)
        @test length(ops) == 2
        @test Set(op[3] for op in ops) == Set([(metal_pg, 2), (second_pg, 2)])
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
            [Remove(:metal), GetBoundary(:edge, :metal)],
            stack,
            registry
        )
    end
end

@testitem "Compiler (integration)" begin
    using DeviceLayout
    using DeviceLayout.SchematicDrivenLayout
    using DeviceLayout.SolidModels
    using DeviceLayout.SolidModelsExperimental:
        Cut,
        Fuse,
        GetBoundary,
        GetInterface,
        Heal,
        LayerRef,
        LayerRegistry,
        LayerState,
        NULL,
        PGRecord,
        Remove,
        RestrictTo,
        Revolve,
        SetPeriodic,
        SolidModelTarget,
        SourceLayer,
        SourceStack,
        Translate
    import DeviceLayout: μm

    function render_case(name, geometry, stack, ops)
        graph = SchematicGraph(name)
        add_node!(graph, BasicComponent(geometry); base_id="fixture")
        schematic = plan(graph; log_dir=nothing) |> check!
        sm = SolidModel(name; overwrite=true)
        SolidModels.gmsh.option.setNumber("General.Verbosity", 2)
        metadata = render!(sm, schematic, SolidModelTarget(stack, ops))
        return (; sm, metadata)
    end

    function layer_pgs(result, layer)
        state = result.metadata["layers"][String(layer)]
        dim = state["dim"]
        return [result.sm[pg_name, dim] for pg_name in state["pgs"]]
    end

    function layer_dimtags(result, layer)
        return unique(vcat(SolidModels.dimtags.(layer_pgs(result, layer))...))
    end

    function layer_measure(result, layer)
        return sum(layer_dimtags(result, layer)) do (dim, tag)
            return SolidModels.gmsh.model.occ.getMass(dim, tag)
        end
    end

    function layer_bbox(result, layer)
        boxes = [
            SolidModels.gmsh.model.getBoundingBox(dim, tag) for
            (dim, tag) in layer_dimtags(result, layer)
        ]
        return (
            minimum(box[1] for box in boxes),
            minimum(box[2] for box in boxes),
            minimum(box[3] for box in boxes),
            maximum(box[4] for box in boxes),
            maximum(box[5] for box in boxes),
            maximum(box[6] for box in boxes)
        )
    end

    function flat_stack(layers...; thickness=0μm)
        return SourceStack(
            (
                layer => SourceLayer(NULL; level=1, height=0μm, thickness=thickness) for
                layer in layers
            )...;
            levels=(1 => 0μm,)
        )
    end

    _rectangle(xmin, ymin, xmax, ymax) =
        Rectangle(Point(xmin * μm, ymin * μm), Point(xmax * μm, ymax * μm))

    @testset "Planar Boolean geometry and source lifetime" begin
        cases = [
            (
                "cut",
                [Cut(:result, :a, :b)],
                2.0,
                [0.0, 0.0, 0.0, 1.0, 2.0, 0.0],
                Set(["a", "b", "result"])
            ),
            (
                "fuse",
                [Fuse(:result, [:a, :b])],
                6.0,
                [0.0, 0.0, 0.0, 3.0, 2.0, 0.0],
                Set(["a", "b", "result"])
            ),
            (
                "cut_remove",
                [Cut(:result, :a, :b), Remove(:a)],
                2.0,
                [0.0, 0.0, 0.0, 1.0, 2.0, 0.0],
                Set(["b", "result"])
            )
        ]
        for (name, ops, expected_area, expected_bbox, expected_layers) in cases
            geometry = CoordinateSystem(name, μm)
            place!(geometry, _rectangle(0.0, 0.0, 2.0, 2.0), LayerRef(:a))
            place!(geometry, _rectangle(1.0, 0.0, 3.0, 2.0), LayerRef(:b))
            place!(geometry, _rectangle(10.0, 0.0, 11.0, 1.0), :legacy)
            result =
                render_case("compiler_geometry_$name", geometry, flat_stack(:a, :b), ops)
            @test layer_measure(result, :result) ≈ expected_area atol = 1e-8
            @test collect(layer_bbox(result, :result)) ≈ expected_bbox atol = 1e-6
            @test Set(keys(result.metadata["layers"])) == expected_layers
            if haskey(result.metadata["layers"], "a")
                @test layer_measure(result, :a) ≈ 4.0 atol = 1e-8
            end
            @test layer_measure(result, :b) ≈ 4.0 atol = 1e-8
        end
    end

    @testset "Sparse pairwise intersections prune empty results" begin
        # Note: using unitless coordinates for this test to also exercise rendering
        # of unitless coordinate systems / schematics
        geometry = CoordinateSystem{Float64}("sparse_intersections")
        for (layer, name, x0) in (
            (:objects, "first", 0.0),
            (:objects, "second", 3.0),
            (:tools, "first", 0.5),
            (:tools, "second", 3.5)
        )
            place!(
                geometry,
                Rectangle(Point(x0, 0.0), Point(x0 + 1.0, 1.0)),
                LayerRef(layer)
            )
        end
        result = render_case(
            "compiler_geometry_sparse_intersections",
            geometry,
            SourceStack(
                :objects => SourceLayer(NULL; level=1, height=0.0, thickness=0.0),
                :tools => SourceLayer(NULL; level=1, height=0.0, thickness=0.0);
                levels=(1 => 0.0,)
            ),
            [SolidModelsExperimental.Intersect(:intersections, :objects, :tools)]
        )
        @test length(layer_pgs(result, :intersections)) == 1
        @test layer_measure(result, :intersections) ≈ 1.0 atol = 1e-8
        @test collect(layer_bbox(result, :intersections)) ≈ [0.5, 0.0, 0.0, 4.0, 1.0, 0.0] atol =
            1e-6
    end

    @testset "Extrusion and deferred interfaces" begin
        geometry = CoordinateSystem("adjacent_volumes", μm)
        place!(geometry, _rectangle(0.0, 0.0, 1.0, 1.0), LayerRef(:left))
        place!(geometry, _rectangle(1.0, 0.0, 2.0, 1.0), LayerRef(:right))
        result = render_case(
            "compiler_geometry_interface",
            geometry,
            flat_stack(:left, :right; thickness=1μm),
            [
                GetInterface(:interface, :left, :right),
                GetInterface(:interface_copy, :left, :right),
                GetInterface(:self_interface, :left, :left)
            ]
        )
        @test result.metadata["layers"]["left"]["dim"] == 3
        @test result.metadata["layers"]["right"]["dim"] == 3
        @test result.metadata["layers"]["interface"]["dim"] == 2
        @test layer_measure(result, :left) ≈ 1.0 atol = 1e-8
        @test layer_measure(result, :right) ≈ 1.0 atol = 1e-8
        @test layer_measure(result, :interface) ≈ 1.0 atol = 1e-8
        @test layer_measure(result, :interface_copy) ≈ 1.0 atol = 1e-8
        @test layer_measure(result, :self_interface) ≈ 6.0 atol = 1e-8
        @test collect(layer_bbox(result, :left)) ≈ [0.0, 0.0, 0.0, 1.0, 1.0, 1.0] atol =
            1e-6
        @test collect(layer_bbox(result, :right)) ≈ [1.0, 0.0, 0.0, 2.0, 1.0, 1.0] atol =
            1e-6
        @test collect(layer_bbox(result, :interface)) ≈ [1.0, 0.0, 0.0, 1.0, 1.0, 1.0] atol =
            1e-6
        @test collect(layer_bbox(result, :interface_copy)) ≈ [1.0, 0.0, 0.0, 1.0, 1.0, 1.0] atol =
            1e-6
        @test collect(layer_bbox(result, :self_interface)) ≈ [0.0, 0.0, 0.0, 1.0, 1.0, 1.0] atol =
            1e-6

        mixed_geometry = CoordinateSystem("mixed_interface", μm)
        place!(mixed_geometry, _rectangle(0.0, 0.0, 1.0, 1.0), LayerRef(:volume))
        place!(mixed_geometry, _rectangle(0.0, 0.0, 1.0, 1.0), LayerRef(:surface))
        mixed_stack = SourceStack(
            :volume => SourceLayer(NULL; level=1, thickness=1μm),
            :surface => SourceLayer(NULL; level=1, thickness=0μm);
            levels=(1 => 0μm,)
        )
        mixed = render_case(
            "compiler_geometry_mixed_interface",
            mixed_geometry,
            mixed_stack,
            [
                GetInterface(:lower_first, :surface, :volume),
                GetInterface(:higher_first, :volume, :surface)
            ]
        )
        for layer in (:lower_first, :higher_first)
            @test mixed.metadata["layers"][String(layer)]["dim"] == 2
            @test layer_measure(mixed, layer) ≈ 1.0 atol = 1e-8
            @test collect(layer_bbox(mixed, layer)) ≈ [0.0, 0.0, 0.0, 1.0, 1.0, 0.0] atol =
                1e-6
        end
    end

    @testset "Translation, boundary extraction, and revolution" begin
        geometry = CoordinateSystem("translated_boundary", μm)
        place!(geometry, _rectangle(0.0, 0.0, 2.0, 1.0), LayerRef(:shape))
        translated = render_case(
            "compiler_geometry_translated_boundary",
            geometry,
            flat_stack(:shape),
            [Translate(:shifted, :shape, 3μm, 0μm, 0μm), GetBoundary(:edge, :shifted)]
        )
        @test layer_measure(translated, :shape) ≈ 2.0 atol = 1e-8
        @test layer_measure(translated, :shifted) ≈ 2.0 atol = 1e-8
        @test layer_measure(translated, :edge) ≈ 6.0 atol = 1e-8
        @test collect(layer_bbox(translated, :shifted)) ≈ [3.0, 0.0, 0.0, 5.0, 1.0, 0.0] atol =
            1e-6

        revolved_geometry = CoordinateSystem("revolved", μm)
        place!(revolved_geometry, _rectangle(1.0, 0.0, 2.0, 1.0), LayerRef(:shape))
        revolved = render_case(
            "compiler_geometry_revolved",
            revolved_geometry,
            flat_stack(:shape),
            [Revolve(:solid, :shape, (0, 0, 0), (0, 1, 0), π)]
        )
        @test revolved.metadata["layers"]["solid"]["dim"] == 3
        @test layer_measure(revolved, :solid) ≈ 3π / 2 atol = 1e-8
        @test collect(layer_bbox(revolved, :solid)) ≈ [-2.0, 0.0, -2.0, 2.0, 1.0, 0.0] atol =
            1e-6
    end

    @testset "Global restriction" begin
        geometry = CoordinateSystem("restricted", μm)
        place!(geometry, _rectangle(0.0, 0.0, 3.0, 1.0), LayerRef(:target))
        place!(geometry, _rectangle(1.0, 0.0, 2.0, 1.0), LayerRef(:bounds))
        result = render_case(
            "compiler_geometry_restricted",
            geometry,
            flat_stack(:target, :bounds; thickness=1μm),
            [RestrictTo(:bounds)]
        )
        @test layer_measure(result, :target) ≈ 1.0 atol = 1e-8
        @test collect(layer_bbox(result, :target)) ≈ [1.0, 0.0, 0.0, 2.0, 1.0, 1.0] atol =
            1e-6
    end

    @testset "Periodic surfaces survive finalization" begin
        geometry = CoordinateSystem("periodic", μm)
        place!(geometry, _rectangle(0.0, 0.0, 1.0, 1.0), LayerRef(:child))
        place!(geometry, _rectangle(0.0, 0.0, 1.0, 1.0), LayerRef(:parent))
        stack = SourceStack(
            :child => SourceLayer(NULL; level=1, thickness=0μm),
            :parent => SourceLayer(NULL; level=2, thickness=0μm);
            levels=(1 => 0μm, 2 => 2μm)
        )
        result = render_case(
            "compiler_geometry_periodic",
            geometry,
            stack,
            [SetPeriodic(:child, :parent)]
        )
        @test collect(layer_bbox(result, :child)) ≈ [0.0, 0.0, 0.0, 1.0, 1.0, 0.0] atol =
            1e-6
        @test collect(layer_bbox(result, :parent)) ≈ [0.0, 0.0, 2.0, 1.0, 1.0, 2.0] atol =
            1e-6
        child_tags = Int32[tag for (_, tag) in layer_dimtags(result, :child)]
        parent_tags = Int32[tag for (_, tag) in layer_dimtags(result, :parent)]
        SolidModels.gmsh.model.mesh.generate(2)
        @test SolidModels.gmsh.model.mesh.getPeriodic(2, child_tags) == parent_tags
    end

    @testset "Registry/model consistency" begin
        sm = SolidModel("registry_validation"; overwrite=true)
        SolidModels.gmsh.option.setNumber("General.Verbosity", 2)
        tag = SolidModels.gmsh.model.occ.addRectangle(0.0, 0.0, 0.0, 1.0, 1.0)
        SolidModels.gmsh.model.occ.synchronize()
        sm["surface"] = [(Int32(2), Int32(tag))]

        registry = LayerRegistry()
        @test_throws ErrorException SolidModelsExperimental._check_pgs_registered(
            sm,
            registry
        )

        registry[:surface] = LayerState([PGRecord("surface", :surface)], 2)
        @test isnothing(SolidModelsExperimental._check_pgs_registered(sm, registry))
    end
end

@testitem "Placement prefix copies" begin
    using DeviceLayout
    using DeviceLayout.SchematicDrivenLayout
    using DeviceLayout.SolidModelsExperimental:
        LayerRef, Locator, LocatorMeta, Tag, Terminal
    import Unitful: μm

    geometry = CoordinateSystem("shared", μm)
    place!(geometry, Locator(0μm, 0μm), Terminal(:metal, "island"))
    place!(geometry, Rectangle(Point(3μm, 0μm), Point(4μm, 1μm)), LayerRef(:metal))
    nested = CoordinateSystem("nested", μm)
    place!(nested, Locator(0μm, 0μm), Tag(:metal, "inner"))
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
            meta in element_metadata(subcs) if
            meta isa LocatorMeta && hasproperty(meta, :name)
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
    @test element_metadata(component.geometry) == original_metadata
    @test name(element_metadata(geometry)[1]) == "island"
end

@testitem "LumpedPort resolution" begin
    using DeviceLayout
    using DeviceLayout.SchematicDrivenLayout
    using DeviceLayout.SolidModels
    using DeviceLayout.SolidModelsExperimental:
        LayerRef, Locator, LumpedPort, NULL, SolidModelTarget, SourceLayer, SourceStack
    import Unitful: μm, °

    stack = SourceStack(
        :port => SourceLayer(NULL; level=1, gds_meta=GDSMeta(5, 0));
        levels=(1 => 0μm,)
    )
    function direction_map(cs)
        locators = SolidModelsExperimental.resolve_locators(flatten(cs), stack)
        return Dict(rl.meta => rl.direction for rl in locators)
    end

    local_cs = CoordinateSystem("local_port", μm)
    nested_port = meshsized_entity(
        optional_entity(WithDirection(30°)(Rectangle(2μm, 1μm)), :port; default=true),
        0.2μm
    )
    local_meta = LumpedPort(:port, "local")
    place!(local_cs, nested_port, LayerRef(:port))
    place!(local_cs, Locator(0μm, 0μm), local_meta)
    @test direction_map(local_cs)[local_meta] ≈ [cospi(1 / 6), 0.5, 0.0]

    transformed = CoordinateSystem("transformed_ports", μm)
    addref!(transformed, local_cs; rot=90°)
    rotated = direction_map(transformed)[local_meta]
    @test rotated ≈ [-0.5, cospi(1 / 6), 0.0]

    reflected = CoordinateSystem("reflected_ports", μm)
    addref!(reflected, local_cs; rot=90°, xrefl=true)
    reflected_direction = direction_map(reflected)[local_meta]
    @test reflected_direction ≈ [0.5, cospi(1 / 6), 0.0]

    target = SolidModelTarget(stack)
    function _port_schematic(name, geometry)
        graph = SchematicGraph(name)
        add_node!(graph, BasicComponent(geometry); base_id="q1")
        return plan(graph; log_dir=nothing) |> check!
    end

    missing_geometry = CoordinateSystem("missing_port_style", μm)
    place!(missing_geometry, Rectangle(2μm, 2μm), LayerRef(:port))
    place!(missing_geometry, Locator(1μm, 1μm), LumpedPort(:port, "missing"))
    missing_sm = SolidModel("missing_port_style"; overwrite=true)
    SolidModels.gmsh.option.setNumber("General.Verbosity", 2)
    @test_throws ArgumentError render!(
        missing_sm,
        _port_schematic("missing_port_style", missing_geometry),
        target
    )
    @test isempty(SolidModels.dimgroupdict(missing_sm, 2))

    duplicate_geometry = CoordinateSystem("duplicate_port_name", μm)
    duplicate_meta = LumpedPort(:port, "duplicate")
    place!(duplicate_geometry, WithDirection(0°)(Rectangle(1μm, 1μm)), LayerRef(:port))
    place!(duplicate_geometry, Locator(0.5μm, 0.5μm), duplicate_meta)
    place!(
        duplicate_geometry,
        WithDirection(0°)(Rectangle(Point(2μm, 0μm), Point(3μm, 1μm))),
        LayerRef(:port)
    )
    place!(duplicate_geometry, Locator(2.5μm, 0.5μm), duplicate_meta)
    duplicate_sm = SolidModel("duplicate_port_name"; overwrite=true)
    @test_throws ArgumentError render!(
        duplicate_sm,
        _port_schematic("duplicate_port_name", duplicate_geometry),
        target
    )
    @test isempty(SolidModels.dimgroupdict(duplicate_sm, 2))
end

@testitem "Tag resolution" begin
    using DeviceLayout
    using DeviceLayout.SolidModels
    using DeviceLayout.SolidModelsExperimental: Tag, PGRecord, LayerState, LayerRegistry

    sm = SolidModel("tag_layer"; overwrite=true)
    SolidModels.gmsh.option.setNumber("General.Verbosity", 2)
    first_tag = SolidModels.gmsh.model.occ.addRectangle(0.0, 0.0, 0.0, 10.0, 10.0)
    second_tag = SolidModels.gmsh.model.occ.addRectangle(0.0, 0.0, 0.0, 10.0, 10.0)
    SolidModels.gmsh.model.occ.synchronize()
    sm["layer_a"] = [(Int32(2), Int32(first_tag))]
    sm["layer_b"] = [(Int32(2), Int32(second_tag))]
    registry = LayerRegistry(
        :a => LayerState([PGRecord("layer_a", :a)], 2),
        :b => LayerState([PGRecord("layer_b", :b)], 2)
    )
    rl = SolidModelsExperimental.ResolvedLocator((5.0, 5.0, 0.0), Tag(:a, "tag"))
    bbox_cache = Dict{Int32, NTuple{6, Float64}}()
    sel = SolidModelsExperimental._select_surface!(sm, registry, rl, bbox_cache)
    @test sel.locators == [rl]
    @test sel.entity_tags == [Int32(first_tag)]
    # The selection PG is an ordinary PG registered under the locator's layer.
    @test keys(registry) == Set([:a, :b])
    selection_pg = only(filter(r -> r.name != "layer_a", registry[:a].pgs)).name
    @test SolidModels.entitytags(sm[selection_pg, 2]) == [Int32(first_tag)]
    @test length(registry[:b].pgs) == 1

    # Unrealized layers and points outside every entity of the layer are errors.
    unrealized = SolidModelsExperimental.ResolvedLocator((5.0, 5.0, 0.0), Tag(:c, "tag"))
    @test_throws ArgumentError SolidModelsExperimental._select_surface!(
        sm,
        registry,
        unrealized,
        bbox_cache
    )
    outside = SolidModelsExperimental.ResolvedLocator((50.0, 50.0, 0.0), Tag(:a, "out"))
    @test_throws ArgumentError SolidModelsExperimental._select_surface!(
        sm,
        registry,
        outside,
        bbox_cache
    )
end

@testitem "Locator resolution against flat geometry" begin
    using DeviceLayout
    using DeviceLayout.SolidModelsExperimental:
        Ground, LayerRef, Locator, LumpedPort, NULL, SourceLayer, SourceStack, Tag, Terminal
    import Unitful: μm, °

    stack = SourceStack(
        :metal => SourceLayer(NULL; level=1),
        :port => SourceLayer(NULL; level=2),
        :hidden => SourceLayer(NULL; level=1, solidmodel=false);
        levels=(1 => 0μm, 2 => 3μm)
    )
    cs = CoordinateSystem("resolution", μm)
    place!(cs, Locator(1μm, 2μm), Tag(:metal, "tag"))
    place!(cs, Locator(0μm, 0μm), Ground(:metal))
    place!(cs, WithDirection(90°)(Rectangle(2μm, 2μm)), LayerRef(:port))
    place!(cs, Locator(1μm, 1μm), LumpedPort(:port, "p"))
    place!(cs, Locator(0μm, 0μm), Terminal(:hidden, "dropped"))

    locators = SolidModelsExperimental.resolve_locators(flatten(cs), stack)
    by_meta = Dict(rl.meta => rl for rl in locators)
    # Positions are in model units at the layer z; only ports carry a direction; locators
    # on layers excluded from the solid model are dropped.
    @test by_meta[Tag(:metal, "tag")].r == (1.0, 2.0, 0.0)
    @test isnothing(by_meta[Tag(:metal, "tag")].direction)
    @test isnothing(by_meta[Ground(:metal)].direction)
    @test by_meta[LumpedPort(:port, "p")].r == (1.0, 1.0, 3.0)
    @test by_meta[LumpedPort(:port, "p")].direction ≈ [0.0, 1.0, 0.0]
    @test !haskey(by_meta, Terminal(:hidden, "dropped"))
    @test length(locators) == 3

    # Duplicate tag or port locators are rejected before any geometry is rendered.
    place!(cs, Locator(1μm, 0μm), Tag(:metal, "tag"))
    @test_throws ArgumentError SolidModelsExperimental.resolve_locators(flatten(cs), stack)

    # Locator metadata must annotate a Locator point entity.
    bad = CoordinateSystem("bad_entity", μm)
    place!(bad, Rectangle(1μm, 1μm), Tag(:metal, "rect"))
    @test_throws ArgumentError SolidModelsExperimental.resolve_locators(flatten(bad), stack)
end

@testitem "Deduplication partitions entities by PG membership" begin
    using DeviceLayout
    using DeviceLayout.SolidModels
    using DeviceLayout.SolidModelsExperimental: PGRecord, LayerState, LayerRegistry

    sm = SolidModel("dedup_membership"; overwrite=true)
    SolidModels.gmsh.option.setNumber("General.Verbosity", 2)
    e1 = Int32(SolidModels.gmsh.model.occ.addRectangle(0.0, 0.0, 0.0, 1.0, 1.0))
    e2 = Int32(SolidModels.gmsh.model.occ.addRectangle(1.0, 0.0, 0.0, 1.0, 1.0))
    e3 = Int32(SolidModels.gmsh.model.occ.addRectangle(2.0, 0.0, 0.0, 1.0, 1.0))
    SolidModels.gmsh.model.occ.synchronize()
    # Layer PG spanning all three entities, a same-layer PG overlapping the first two, a
    # cross-registered PG (two layers) on the middle entity, and a selection on the last.
    sm["e123"] = [(Int32(2), e1), (Int32(2), e2), (Int32(2), e3)]
    sm["e12"] = [(Int32(2), e1), (Int32(2), e2)]
    sm["e2"] = [(Int32(2), e2)]
    sm["e3"] = [(Int32(2), e3)]
    registry = LayerRegistry(
        :a => LayerState(
            [
                PGRecord("e123", :a),
                PGRecord("e12", :a),
                PGRecord("e2", :a),
                PGRecord("e3", :a)
            ],
            2
        ),
        :b => LayerState([PGRecord("e2", :b)], 2)
    )
    SolidModelsExperimental._deduplicate_pgs!(sm, registry, 2)

    pgs = SolidModels.dimgroupdict(sm, 2)
    # Every entity belongs to exactly one PG.
    owners = Dict{Int32, Vector{String}}()
    for (name, pg) in pgs, t in SolidModels.entitytags(pg)
        push!(get!(Vector{String}, owners, t), name)
    end
    @test Set(keys(owners)) == Set([e1, e2, e3])
    @test all(==(1), length.(values(owners)))
    # All original PGs were fully consumed by e2 groups.
    @test !any(haskey(pgs, n) for n in ("e123", "e12", "e2", "e3"))
    @test length(pgs) == 3
    # Sub-PGs are registered under the union of their members' layers.
    @test Set(r.name for r in registry[:a].pgs) == Set(keys(pgs))
    @test only(registry[:b].pgs).name == only(owners[e2])
    # Every registered record exists in the model.
    @test all(haskey(pgs, r.name) for s in values(registry) for r in s.pgs)
end

@testitem "Strictness modes" begin
    using DeviceLayout
    using DeviceLayout.SchematicDrivenLayout
    using DeviceLayout.SolidModels
    using DeviceLayout.SolidModelsExperimental:
        LayerRef, METAL, SolidModelTarget, SourceLayer, SourceStack

    geometry = CoordinateSystem{Float64}("warning_surface")
    place!(geometry, Rectangle(10.0, 10.0), LayerRef(:metal))
    graph = SchematicGraph("finalization_warning")
    add_node!(graph, BasicComponent(geometry); base_id="q1")
    schematic = plan(graph; log_dir=mktempdir()) |> check!
    target = SolidModelTarget(
        SourceStack(
            :metal => SourceLayer(METAL; level=1, height=0.0, thickness=0.0);
            levels=(1 => 0.0,)
        )
    )
    SolidModels.gmsh.option.setNumber("General.Verbosity", 2)
    # A metal connected component without a Terminal or Ground locator emits a warning,
    # which strict=:warn promotes to an error.
    @test_throws ErrorException render!(
        SolidModel("strict_warning"; overwrite=true),
        schematic,
        target;
        strict=:warn
    )
    @test render!(
        SolidModel("nonstrict_warning"; overwrite=true),
        schematic,
        target;
        strict=:no
    ) isa Dict
end

@testitem "SolidModel end-to-end" begin
    using DeviceLayout
    using DeviceLayout.SchematicDrivenLayout
    using DeviceLayout.SolidModels
    using DeviceLayout.SolidModelsExperimental:
        Cut,
        DIELECTRIC,
        GetBoundary,
        GetInterface,
        Ground,
        Heal,
        LayerRef,
        Locator,
        LocatorMeta,
        LumpedPort,
        METAL,
        NULL,
        Remove,
        RestrictTo,
        SolidModelTarget,
        SourceLayer,
        SourceStack,
        Tag,
        Terminal,
        exterior_boundaries
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
        place!(cs, meshsized_entity(gaps, gaps_mesh_lengthscale), LayerRef(:METAL_NEG))

        # Terminal locator on the island
        place!(
            cs,
            Locator(zero(island_width), zero(island_width)),
            Terminal(:METAL_POS, "island")
        )

        # Tag locator on the island (ensures island is given a dedicated physical group
        # even if terminal locator above were removed)
        place!(
            cs,
            Locator(zero(island_width), zero(island_width)),
            Tag(:METAL_POS, "island")
        )

        # Lumped port spanning the gap at the top of the island
        port_y = island_height / 2 + island_ground_gap / 2
        port_rect = centered(
            Rectangle(port_width, island_ground_gap),
            on_pt=Point(zero(island_width), port_y)
        )
        place!(cs, WithDirection(π / 2)(port_rect), LayerRef(:PORTS))
        place!(cs, Locator(center(bounds(port_rect))), LumpedPort(:PORTS, "jj"))

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
                LayerRef(:METAL_NEG)
            )

            place!(
                cs,
                Locator(Point((arm_x_start + arm_x_end) / 2, zero(island_width))),
                Terminal(:METAL_POS, hook_name)
            )
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
            Cut(:METAL_POS, :CHIP_OUTLINE, :METAL_NEG),
            Remove(:CHIP_OUTLINE),
            Cut(:CUTOUT, :METAL_NEG, :PORTS),
            Remove(:METAL_NEG),
            Heal(:METAL_POS),
            Cut(:VACUUM, :BOUNDING_VOLUME, :SUBSTRATE_BOTTOM),
            RestrictTo(:BOUNDING_VOLUME),
            # Extract the six BOUNDING_VOLUME boundaries as EXTBND_XMIN,
            # EXTBND_XMAX, and so on.
            exterior_boundaries(:BOUNDING_VOLUME)...,
            # Remove the bounding volume layer but keep its underlying entities (including
            # the exterior-boundary entities extracted above)
            Remove(:BOUNDING_VOLUME; remove_entities=false)
        ]

        target = SolidModelTarget(stack, ops)

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
        place!(coordinate_system, chip, LayerRef(:CHIP_OUTLINE))
        place!(coordinate_system, chip, LayerRef(:SUBSTRATE_BOTTOM))
        place!(coordinate_system, chip, LayerRef(:BOUNDING_VOLUME))

        gnd_pt = chip_center + Point(400μm, 400μm)
        place!(coordinate_system, Locator(gnd_pt), Ground(:METAL_POS))

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

            # Each transmon contributes one terminal CC with a locator ending in ".island"
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

        @testset "Port locator metadata" begin
            ports = solid_model_metadata["ports"]
            @test length(ports) == 2
            for (port_name, port_data) in ports
                @test endswith(port_name, ".jj")
                @test port_data["type"] == "LumpedPort"
                @test port_data["layer"] == "PORTS"
                @test !isempty(port_data["pgs"])
                node_id = first(split(port_name, "."))
                @test port_data["direction"] ≈ planned_port_directions[node_id]
            end
            port_pg_sets = [Set(port["pgs"]) for port in values(ports)]
            @test isempty(intersect(port_pg_sets...))
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
            for (_, port_info) in solid_model_metadata["ports"]
                for pg_name in port_info["pgs"]
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

        @testset "Deduplication: non-overlapping PGs" begin
            # INVARIANT: no entity appears in more than one PG of its dimension (Palace
            # rejects faces with multiple boundary elements).
            for dim = 1:3
                tag_to_pg = Dict{Int32, String}()
                duplicates = Pair{Int32, Tuple{String, String}}[]
                for (pg_name, dim_pg) in SolidModels.dimgroupdict(solid_model, dim)
                    for t in SolidModels.entitytags(dim_pg)
                        if haskey(tag_to_pg, t)
                            push!(duplicates, t => (tag_to_pg[t], pg_name))
                        else
                            tag_to_pg[t] = pg_name
                        end
                    end
                end
                if !isempty(duplicates)
                    @warn "Duplicate entity assignments" dim count = length(duplicates) examples =
                        first(duplicates, 5)
                end
                @test isempty(duplicates)
            end
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

        println("\nE2E test artifacts in: $output_dir")
    end
end
