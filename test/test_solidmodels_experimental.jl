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
    offset_layer = SourceLayer(NULL; thickness=15μm, offset=5μm)
    stack = SourceStack(:a => simple_layer, :b => offset_layer; levels=(1 => 0.0nm))
    @test simple_layer.level == 1
    @test SolidModelsExperimental.thickness(simple_layer, stack) == 10.0nm
    @test SolidModelsExperimental.thickness(offset_layer, stack) == 15μm # offset shouldn't change thickness

    pair_layer = SourceLayer(NULL; level=1 => 2)
    offset_pair_layer =
        SourceLayer(DIELECTRIC; level=1 => 2, offset=(10μm, -10μm), gds_meta=GDSMeta(8, 2))
    @test first(offset_pair_layer.level) == 1
    @test last(offset_pair_layer.level) == 2
    @test first(offset_pair_layer.offset) == 10μm
    @test last(offset_pair_layer.offset) == -10μm
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
    span_layer = SourceLayer(NULL; level=1 => 2, offset=(10μm, -5.4μm))
    stack = SourceStack(:substrate => span_layer; levels=(1 => 0μm, 2 => 500000.3nm))

    mixed_types_stack = SourceStack(
        :integer => SourceLayer(NULL),
        :floating => SourceLayer(NULL; offset=0.0μm, thickness=0.0μm);
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

    art_cell = Cell("art", μm)
    render!(art_cell, cs, stack; levels=[1, 2], level_increment=GDSMeta(100, 10))
    @test element_metadata(art_cell) == [GDSMeta(10, 5), GDSMeta(120, 17)]

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
        DeferredInterface,
        Extrude,
        Fuse,
        GetBoundary,
        GetInterface,
        Hollow,
        Intersect,
        METAL,
        NULL,
        Remove,
        RestrictTo,
        Revolve,
        SetPeriodic,
        SourceLayer,
        SourceStack,
        Translate,
        LayerState,
        LayerRegistry,
        compile_ops,
        exterior_boundaries
    import Unitful: μm

    # Debugging helpers
    function inspect_registry(registry::LayerRegistry; io::IO=stdout)
        for (layer_name, state) in sort!(collect(registry); by=first)
            println(io, layer_name, " (dim=", state.dim, ", dz=", state.dz, ")")
            for pg_name in state.pgs
                println(io, "  ", pg_name)
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
        :voids => SourceLayer(NULL; level=1, thickness=2μm),
        :shell => SourceLayer(METAL; level=1, thickness=2μm),
        :span => SourceLayer(NULL; level=1 => 2, offset=(0μm, 1μm)),
        :flat => SourceLayer(METAL; level=1, thickness=0μm);
        levels=(1 => 0μm, 2 => 3μm)
    )
    # Before rendering, every layer holds one PG named after it.
    registry = LayerRegistry(
        layer => LayerState([string(layer)], 2) for
        layer in (:metal, :voids, :shell, :span, :flat)
    )
    with(registry, extra...) = merge(deepcopy(registry), LayerRegistry(extra...))
    lowered(ops, f) = only(filter(op -> op[2] == f, ops))

    @testset "Utils" begin
        @test length(exterior_boundaries(:volume)) == 6
    end

    @testset "Extrude" begin
        @test_throws ArgumentError Extrude(:metal, :metal, 2μm, 2, nothing)
        @test_throws ArgumentError Extrude(:metal; offset=1μm)

        # In place, a declared thickness replaces the source surface with a volume and
        # consumes the surface.
        ops, reg, dints = compile_ops([Extrude(:metal)], stack, registry)
        @test reg[:metal].dim == 3
        @test reg[:metal].dz == 2.0
        @test only(reg[:metal].pgs) == "metal"
        @test lowered(ops, SolidModels.extrude_z!)[3] == ("metal", 2μm, 2)
        @test lowered(ops, SolidModels.remove_group!)[3] == ("metal", 2)
        @test isempty(dints)

        # A level span declares the thickness between its two ends.
        ops, reg, _ = compile_ops([Extrude(:span)], stack, registry)
        @test lowered(ops, SolidModels.extrude_z!)[3] == ("span", 4μm, 2)
        @test reg[:span].dz == 4.0

        # Explicit distances and target levels must agree with the declaration.
        @test compile_ops([Extrude(:metal, 2μm)], stack, registry)[2][:metal].dim == 3
        @test compile_ops(
            [Extrude(:span; to_level=2, offset=1μm)],
            stack,
            registry
        )[2][:span].dim == 3
        @test_throws ArgumentError compile_ops([Extrude(:metal, 1μm)], stack, registry)
        @test_throws ArgumentError compile_ops(
            [Extrude(:metal; to_level=2)],
            stack,
            registry
        )
        @test_throws ArgumentError compile_ops([Extrude(:flat)], stack, registry)
        @test_throws ArgumentError compile_ops(
            [Extrude(:metal; to_level=7)],
            stack,
            registry
        )

        # A distinct destination receives a copy and leaves the source in place.
        ops, reg, _ = compile_ops([Extrude(:solid, :metal)], stack, registry)
        @test reg[:metal].dim == 2
        @test reg[:solid].dim == 3
        @test reg[:solid].dz == 2.0
        @test only(reg[:solid].pgs) == "solid"
        @test only(ops) == ("solid", SolidModels.extrude_z!, ("metal", 2μm, 2))

        # Walls: extrude the 1D outline of a surface.
        ops, reg, _ =
            compile_ops([GetBoundary(:shell, :shell), Extrude(:shell)], stack, registry)
        @test lowered(ops, SolidModels.extrude_z!)[3] == ("shell", 2μm, 1)
        @test reg[:shell].dim == 2

        # Generated layers need an explicit distance or target level.
        generated = with(registry, :generated => LayerState(["generated"], 2))
        @test_throws ArgumentError compile_ops([Extrude(:generated)], stack, generated)
        ops, reg, _ = compile_ops([Extrude(:generated, 3μm)], stack, generated)
        @test reg[:generated].dim == 3
        @test reg[:generated].dz == 3.0
        ops, reg, _ = compile_ops([Extrude(:generated; to_level=2)], stack, generated)
        to_z = lowered(ops, SolidModelsExperimental._extrude_to_z!)
        @test to_z[3][1:3] == ("generated", 3.0, 2)
        @test to_z[3][4] === reg[:generated] # the distance is recorded here at execution
        @test isnothing(reg[:generated].dz)

        # 3D layers cannot be extruded.
        extruded = compile_ops([Extrude(:metal)], stack, registry)[2]
        @test_throws ArgumentError compile_ops([Extrude(:metal)], stack, extruded)

        # Every declared thickness still in the registry must have been built.
        _, reg, _ = compile_ops([Extrude(:metal)], stack, registry)
        @test_throws ArgumentError SolidModelsExperimental.check_declared_thicknesses(
            reg,
            stack
        )
        for layer in (:voids, :shell, :span)
            delete!(reg, layer)
        end
        @test isnothing(SolidModelsExperimental.check_declared_thicknesses(reg, stack))
    end

    @testset "Hollow" begin
        @test_throws ArgumentError compile_ops([Hollow(:metal)], stack, registry)
        ops, reg, _ = compile_ops([Extrude(:metal), Hollow(:metal)], stack, registry)
        # The shell takes the layer's name at dimension 2 while the solid awaits removal.
        @test reg[:metal].dim == 2
        @test reg[:metal].dz == 2.0
        @test only(reg[:metal].pgs) == "metal"
        bnd = lowered(ops, SolidModels.get_boundary)
        @test bnd[1] == "metal" && bnd[3] == ("metal", 3)
        @test only(reg[SolidModelsExperimental._HOLLOWED].pgs) == "metal"
        @test reg[SolidModelsExperimental._HOLLOWED].dim == 3
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

        # A new destination preserves both inputs.
        ops, reg, _ = compile_ops([Cut(:cut, :metal, :voids)], stack, registry)
        op = only(ops)
        @test op[1:3] == ("cut", SolidModels.difference_geom!, ("metal", ["voids"], 2, 2))
        @test (:remove_object => false) in op
        @test (:remove_tool => false) in op
        @test reg[:cut].dim == 2
        @test only(reg[:cut].pgs) == "cut"
        @test haskey(reg, :metal) && haskey(reg, :voids)

        # In place, the result replaces the object or the tool it is named after.
        ops, reg, _ = compile_ops([Cut(:metal, :metal, :voids)], stack, registry)
        @test only(ops)[1] == "metal"
        @test haskey(reg, :metal) && haskey(reg, :voids)
        ops, reg, _ = compile_ops([Cut(:voids, :metal, :voids)], stack, registry)
        @test only(ops)[1] == "voids"
        @test only(ops)[3] == ("metal", ["voids"], 2, 2)

        # Adjacent removals of the object or of all tools are absorbed into the OCC call.
        ops, reg, _ =
            compile_ops([Cut(:cut, :metal, :voids), Remove(:metal)], stack, registry)
        @test (:remove_object => true) in only(ops)
        @test !haskey(reg, :metal)
        ops, reg, _ =
            compile_ops([Cut(:cut, :metal, :voids), Remove(:voids)], stack, registry)
        @test (:remove_tool => true) in only(ops)
        @test !haskey(reg, :voids)
        ops, reg, _ =
            compile_ops([Cut(:metal, :metal, :voids), Remove(:voids)], stack, registry)
        @test (:remove_object => false) in only(ops)
        @test (:remove_tool => true) in only(ops)
        @test haskey(reg, :metal) && !haskey(reg, :voids)

        # Partial tool removal cannot be represented by OCC's all-tools removal flag.
        ops, reg, _ = compile_ops(
            [Cut(:cut, :metal, (:voids, :shell)), Remove(:voids)],
            stack,
            registry
        )
        @test (:remove_tool => false) in lowered(ops, SolidModels.difference_geom!)
        @test any(op -> op[2] == SolidModels.remove_group!, ops)
        @test !haskey(reg, :voids) && haskey(reg, :shell)

        # Removing the destination means removing the result, so it is not absorbed.
        ops, reg, _ =
            compile_ops([Cut(:metal, :metal, :voids), Remove(:metal)], stack, registry)
        @test (:remove_object => false) in lowered(ops, SolidModels.difference_geom!)
        @test any(op -> op[2] == SolidModels.remove_group!, ops)
        @test !haskey(reg, :metal)

        # A non-adjacent removal remains a separate operation.
        ops, reg, _ = compile_ops(
            [Cut(:cut, :metal, :voids), GetBoundary(:edge, :metal), Remove(:metal)],
            stack,
            registry
        )
        @test (:remove_object => false) in lowered(ops, SolidModels.difference_geom!)
        @test any(op -> op[2] == SolidModels.remove_group!, ops)
        @test !haskey(reg, :metal)

        # A destination must be new or one of the inputs.
        cut = Cut(:cut, :metal, :voids)
        @test_throws ArgumentError compile_ops([cut, cut], stack, registry)
        @test_throws ArgumentError compile_ops(
            [Cut(:shell, :metal, :voids)],
            stack,
            registry
        )

        # In-place repeats operate on the previous result.
        ops, reg, _ = compile_ops(
            [Cut(:metal, :metal, :voids), Cut(:metal, :metal, :voids)],
            stack,
            registry
        )
        @test length(ops) == 2
        @test all(op -> op[1] == "metal", ops)
        @test only(reg[:metal].pgs) == "metal"

        # Explicit chains consume the named result of the preceding Cut.
        ops, reg, _ = compile_ops(
            [Cut(:first, :metal, :voids), Cut(:second, :first, :shell)],
            stack,
            registry
        )
        @test ops[2][3] == ("first", ["shell"], 2, 2)
        @test haskey(reg, :first) && haskey(reg, :second)
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
        @test op[1:3] == ("edge", SolidModels.get_boundary, ("metal", 2))
        @test (:combined => false) in op
        @test (:oriented => false) in op
        @test (:recursive => true) in op
        @test (:direction => "z") in op
        @test (:position => "max") in op
        @test reg[:edge].dim == 1
        @test only(reg[:edge].pgs) == "edge"
        @test haskey(reg, :metal)

        # A destination must be new or the source.
        bnd = GetBoundary(:edge, :metal)
        @test_throws ArgumentError compile_ops([bnd, bnd], stack, registry)
        @test_throws ArgumentError compile_ops(
            [
                GetBoundary(:edge, :metal; direction="x"),
                GetBoundary(:edge, :voids; direction="y")
            ],
            stack,
            registry
        )

        # In-place extraction lowers the dimension under the same name, never below 0D.
        bnd = GetBoundary(:metal, :metal)
        ops, reg, _ = compile_ops([bnd, bnd, bnd], stack, registry)
        @test getindex.(ops, Ref(3)) == [("metal", 2), ("metal", 1), ("metal", 0)]
        @test all(op -> op[1] == "metal", ops)
        @test reg[:metal].dim == 0

        # Explicit chains consume the named boundary of the preceding operation.
        ops, reg, _ = compile_ops(
            [GetBoundary(:edges, :metal), GetBoundary(:points, :edges)],
            stack,
            registry
        )
        @test ops[2][3] == ("edges", 1)
        @test reg[:edges].dim == 1
        @test reg[:points].dim == 0
    end

    @testset "Translate" begin
        @test Translate(:metal, 1μm, 0μm, 0μm).destination == :metal
        @test Translate(:metal, 1μm, 0μm, 0μm).source == :metal

        # A distinct destination receives a copy; in place, the layer moves.
        ops, reg, _ =
            compile_ops([Translate(:shifted, :metal, 1μm, 0μm, 0μm)], stack, registry)
        @test only(ops)[1:3] ==
              ("shifted", SolidModels.translate!, ("metal", 1μm, 0μm, 0μm))
        @test (:copy => true) in only(ops)
        @test haskey(reg, :metal)
        @test reg[:shifted].dim == 2
        ops, reg, _ = compile_ops(
            [Translate(:metal, 1μm, 0μm, 0μm), Translate(:metal, 1μm, 0μm, 0μm)],
            stack,
            registry
        )
        @test all(op -> op[1] == "metal" && (:copy => false) in op, ops)
        @test only(reg[:metal].pgs) == "metal"

        # A destination must be new or the source.
        translate = Translate(:shifted, :metal, 1μm, 0μm, 0μm)
        @test_throws ArgumentError compile_ops([translate, translate], stack, registry)
        @test_throws ArgumentError compile_ops(
            [Translate(:voids, :metal, 1μm, 0μm, 0μm)],
            stack,
            registry
        )

        # Explicit chains consume the translated result of the preceding operation.
        ops, reg, _ = compile_ops(
            [
                Translate(:shifted_x, :metal, 1μm, 0μm, 0μm),
                Translate(:shifted_xy, :shifted_x, 0μm, 2μm, 0μm)
            ],
            stack,
            registry
        )
        @test ops[2][3][1] == "shifted_x"
        @test haskey(reg, :shifted_x) && haskey(reg, :shifted_xy)
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

        # In place, a single source is healed into itself.
        ops, reg, _ = compile_ops([Fuse(:metal)], stack, registry)
        @test only(ops)[1:3] == ("metal", SolidModels.union_geom!, (["metal"], 2))
        @test (:remove_object => true) in only(ops)
        @test only(reg[:metal].pgs) == "metal"

        # Multiple sources are preserved and fused into a new destination.
        ops, reg, _ = compile_ops([Fuse(:combined, (:metal, :voids))], stack, registry)
        @test only(ops)[1:3] ==
              ("combined", SolidModels.union_geom!, (["metal", "voids"], 2))
        @test (:remove_object => false) in only(ops)
        @test haskey(reg, :metal) && haskey(reg, :voids)
        @test only(reg[:combined].pgs) == "combined"

        # One source into a new destination heals it there and preserves it unless removed.
        ops, reg, _ =
            compile_ops([Fuse(:clean, (:metal,)), Remove(:metal)], stack, registry)
        @test only(ops)[1:3] == ("clean", SolidModels.union_geom!, (["metal"], 2))
        @test (:remove_object => true) in only(ops)
        @test !haskey(reg, :metal)

        # Including the destination among the sources replaces its geometry.
        ops, reg, _ = compile_ops([Fuse(:metal, (:metal, :voids))], stack, registry)
        @test only(ops)[1] == "metal"
        @test only(reg[:metal].pgs) == "metal"
        @test haskey(reg, :voids)

        # A destination must be new or one of the sources.
        fuse = Fuse(:combined, (:metal, :voids))
        @test_throws ArgumentError compile_ops([fuse, fuse], stack, registry)
        @test_throws ArgumentError compile_ops(
            [Fuse(:shell, (:metal, :voids))],
            stack,
            registry
        )

        # Explicit chains consume the named result of the preceding Fuse.
        ops, reg, _ = compile_ops(
            [Fuse(:combined, (:metal, :voids)), Fuse(:all, (:combined, :shell))],
            stack,
            registry
        )
        @test ops[2][3] == (["combined", "shell"], 2)
        @test haskey(reg, :combined) && haskey(reg, :all)

        # Removal is folded in only when every non-destination source is removed.
        ops, reg, _ = compile_ops(
            [Fuse(:combined, (:metal, :voids)), Remove(:metal)],
            stack,
            registry
        )
        @test (:remove_object => false) in lowered(ops, SolidModels.union_geom!)
        @test any(op -> op[2] == SolidModels.remove_group!, ops)
        @test !haskey(reg, :metal) && haskey(reg, :voids)
        ops, reg, _ = compile_ops(
            [Fuse(:combined, (:metal, :voids)), Remove(:metal), Remove(:voids)],
            stack,
            registry
        )
        @test (:remove_object => true) in only(ops)
        @test !haskey(reg, :metal) && !haskey(reg, :voids)

        # Sources must be dimensionally homogeneous.
        reg = deepcopy(registry)
        reg[:voids].dim = 3
        @test_throws ArgumentError compile_ops(
            [Fuse(:combined, (:metal, :voids))],
            stack,
            reg
        )
    end

    @testset "Intersect" begin
        intersect = Intersect(:intersection, :metal, :voids)
        @test intersect.destination == :intersection
        @test intersect.object == :metal
        @test intersect.tool == :voids
        @test_throws ArgumentError Intersect(:self, :metal, :metal)
        @test_throws ArgumentError compile_ops(
            [Intersect(:intersection, :missing, :voids)],
            stack,
            registry
        )

        # A new destination preserves both inputs.
        ops, reg, _ = compile_ops([intersect], stack, registry)
        op = only(ops)
        @test op[1:3] ==
              ("intersection", SolidModels.intersect_geom!, ("metal", "voids", 2, 2))
        @test (:remove_object => false) in op
        @test (:remove_tool => false) in op
        @test reg[:intersection].dim == 2
        @test only(reg[:intersection].pgs) == "intersection"
        @test haskey(reg, :metal) && haskey(reg, :voids)

        # Mixed-dimensional inputs produce a layer at the lower input dimension.
        reg = with(registry, :volume => LayerState(["volume"], 3))
        ops, reg, _ = compile_ops([Intersect(:surface, :volume, :metal)], stack, reg)
        @test only(ops)[3] == ("volume", "metal", 3, 2)
        @test reg[:surface].dim == 2
        reg = with(registry, :volume => LayerState(["volume"], 3))
        ops, reg, _ = compile_ops([Intersect(:volume, :volume, :metal)], stack, reg)
        @test reg[:volume].dim == 2

        # A destination must be new or one of the inputs.
        @test_throws ArgumentError compile_ops([intersect, intersect], stack, registry)
        @test_throws ArgumentError compile_ops(
            [Intersect(:shell, :metal, :voids)],
            stack,
            registry
        )

        # In place, the result replaces the input it is named after, which OCC consumes.
        ops, reg, _ = compile_ops([Intersect(:metal, :metal, :voids)], stack, registry)
        @test (:remove_object => true) in only(ops)
        @test (:remove_tool => false) in only(ops)
        @test only(reg[:metal].pgs) == "metal"
        @test haskey(reg, :voids)
        ops, reg, _ = compile_ops([Intersect(:voids, :metal, :voids)], stack, registry)
        @test (:remove_object => false) in only(ops)
        @test (:remove_tool => true) in only(ops)
        @test haskey(reg, :metal)

        # Input lifetime is controlled by adjacent Remove operations.
        ops, reg, _ =
            compile_ops([intersect, Remove(:metal), Remove(:voids)], stack, registry)
        @test (:remove_object => true) in only(ops)
        @test (:remove_tool => true) in only(ops)
        @test !haskey(reg, :metal) && !haskey(reg, :voids)
        ops, reg, _ = compile_ops([intersect, Remove(:voids)], stack, registry)
        @test (:remove_object => false) in only(ops)
        @test (:remove_tool => true) in only(ops)
        @test haskey(reg, :metal) && !haskey(reg, :voids)

        # A removal naming an aliased destination applies to the result and is not absorbed.
        ops, reg, _ = compile_ops(
            [Intersect(:metal, :metal, :voids), Remove(:metal)],
            stack,
            registry
        )
        @test any(op -> op[2] == SolidModels.remove_group!, ops)
        @test !haskey(reg, :metal)

        # An empty OCC result leaves an unrealized layer that `sync_registry!` empties.
        sm = SolidModel("intersect_empty"; overwrite=true)
        SolidModels.gmsh.option.setNumber("General.Verbosity", 2)
        for (name, x) in (("object", 0.0), ("tool", 10.0))
            tag = SolidModels.gmsh.model.occ.addRectangle(x, 0.0, 0.0, 2.0, 2.0)
            SolidModels.gmsh.model.occ.synchronize()
            sm[name] = [(Int32(2), Int32(tag))]
        end
        reg = LayerRegistry(
            :object => LayerState(["object"], 2),
            :tool => LayerState(["tool"], 2)
        )
        ops, reg, _ = compile_ops([Intersect(:result, :object, :tool)], stack, reg)
        SolidModels._postrender!(sm, ops)
        SolidModelsExperimental.sync_registry!(sm, reg)
        @test haskey(reg, :result)
        @test isempty(reg[:result].pgs)
    end

    @testset "GetInterface" begin
        @test_throws ArgumentError GetInterface(:metal, :metal, :voids)
        @test_throws ArgumentError GetInterface(:voids, :metal, :voids)
        @test_throws ArgumentError compile_ops(
            [GetInterface(:interface, :missing, :metal)],
            stack,
            registry
        )

        # Same-dimensional inputs produce a deferred boundary one dimension lower.
        ops, reg, dints =
            compile_ops([GetInterface(:interface, :metal, :voids)], stack, registry)
        @test isempty(ops)
        @test reg[:interface].dim == 1
        @test only(reg[:interface].pgs) == "interface"
        @test only(dints) == DeferredInterface(:interface, :metal, :voids, 2, 2)
        @test haskey(reg, :metal) && haskey(reg, :voids)

        # Mixed-dimensional inputs produce an interface at the lower dimension, symmetrically.
        reg = with(registry, :volume => LayerState(["volume"], 3))
        for (object, tool) in ((:metal, :volume), (:volume, :metal))
            ops, out, dints =
                compile_ops([GetInterface(:surface, object, tool)], stack, reg)
            @test isempty(ops)
            @test out[:surface].dim == 2
            @test only(dints) ==
                  DeferredInterface(:surface, object, tool, reg[object].dim, reg[tool].dim)
        end

        # A destination must be new.
        interface = GetInterface(:interface, :metal, :voids)
        @test_throws ArgumentError compile_ops([interface, interface], stack, registry)
        @test_throws ArgumentError compile_ops(
            [interface, GetInterface(:interface, :metal, :shell)],
            stack,
            registry
        )

        # Explicit chains consume an earlier deferred destination.
        ops, reg, dints = compile_ops(
            [
                GetInterface(:metal_voids, :metal, :voids),
                GetInterface(:chained, :metal_voids, :shell)
            ],
            stack,
            registry
        )
        @test reg[:metal_voids].dim == 1
        @test reg[:chained].dim == 1
        @test last(dints) == DeferredInterface(:chained, :metal_voids, :shell, 1, 2)

        # Deferred inputs must retain their registered PG name and dimension.
        @test_throws ArgumentError compile_ops([interface, Remove(:metal)], stack, registry)
        @test_throws ArgumentError compile_ops(
            [interface, GetBoundary(:metal, :metal)],
            stack,
            registry
        )
        ops, reg, dints =
            compile_ops([interface, GetBoundary(:edge, :metal)], stack, registry)
        @test length(ops) == 1
        @test haskey(reg, :metal) && haskey(reg, :edge)
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

        # A new destination is registered one dimension higher and preserves the source.
        ops, reg, _ = compile_ops([rev], stack, registry)
        @test only(ops) == (
            "revolved",
            SolidModels.revolve!,
            ("metal", 2, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, Float64(π))
        )
        @test reg[:revolved].dim == 3
        @test only(reg[:revolved].pgs) == "revolved"
        @test haskey(reg, :metal)

        # In place, repeats advance through successive dimensions under the same name.
        reg = with(registry, :line => LayerState(["line"], 1))
        revolve_line = Revolve(:line, (0, 0, 0), (0, 0, 1), π)
        ops, reg, _ = compile_ops([revolve_line, revolve_line], stack, reg)
        @test getindex.(ops, Ref(3)) .|> (args -> args[2]) == [1, 2]
        @test all(op -> op[1] == "line", ops)
        @test reg[:line].dim == 3

        # A destination must be new or the source.
        @test_throws ArgumentError compile_ops([rev, rev], stack, registry)
        @test_throws ArgumentError compile_ops(
            [Revolve(:voids, :metal, (0, 0, 0), (0, 0, 1), π)],
            stack,
            registry
        )

        # Explicit chains consume the named result of the preceding revolution.
        reg = with(registry, :line => LayerState(["line"], 1))
        ops, reg, _ = compile_ops(
            [
                Revolve(:surface, :line, (0, 0, 0), (0, 0, 1), π),
                Revolve(:volume, :surface, (0, 0, 0), (1, 0, 0), π / 2)
            ],
            stack,
            reg
        )
        @test ops[2][3][1:2] == ("surface", 2)
        @test reg[:surface].dim == 2
        @test reg[:volume].dim == 3

        # OCC cannot sweep a volume into a fourth dimension.
        reg = with(registry, :volume => LayerState(["volume"], 3))
        @test_throws ArgumentError compile_ops(
            [Revolve(:invalid, :volume, (0, 0, 0), (0, 0, 1), π)],
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

        # A pair of 2D layers maps directly to the native operation without registry changes.
        ops, reg, dints = compile_ops([periodic, periodic], stack, registry)
        @test all(
            op ->
                op ==
                ("Periodic_metal", SolidModels.set_periodic!, ("metal", "voids", 2, 2)),
            ops
        )
        @test reg[:metal].dim == 2
        @test reg[:voids].dim == 2
        @test isempty(dints)

        # Native periodic pairing supports only surface groups.
        reg = deepcopy(registry)
        reg[:metal].dim = 1
        @test_throws ArgumentError compile_ops([periodic], stack, reg)
        reg = deepcopy(registry)
        reg[:voids].dim = 3
        @test_throws ArgumentError compile_ops([periodic], stack, reg)
    end

    @testset "RestrictTo" begin
        @test_throws ArgumentError compile_ops([RestrictTo(:missing)], stack, registry)
        @test_throws ArgumentError compile_ops([RestrictTo(:metal)], stack, registry)

        # Restriction maps to the native operation without registry changes.
        reg = with(registry, :volume => LayerState(["volume"], 3))
        ops, out, dints =
            compile_ops([RestrictTo(:volume), RestrictTo(:volume)], stack, reg)
        @test all(
            op -> op == ("restrict", SolidModels.restrict_to_volume!, ("volume",)),
            ops
        )
        @test keys(out) == keys(reg)
        @test out[:volume].dim == 3
        @test isempty(dints)
    end

    @testset "Remove" begin
        @test Remove(:metal).remove_entities
        @test !Remove(:metal; remove_entities=false).remove_entities

        # Removing a layer emits one native operation and deletes its registry entry.
        ops, reg, dints = compile_ops([Remove(:metal)], stack, registry)
        @test only(ops)[1:3] == ("_rm", SolidModels.remove_group!, ("metal", 2))
        @test (:remove_entities => true) in only(ops)
        @test !haskey(reg, :metal) && haskey(reg, :voids)
        @test isempty(dints)
        ops, reg, _ = compile_ops([Remove(:metal; remove_entities=false)], stack, registry)
        @test (:remove_entities => false) in only(ops)
        @test !haskey(reg, :metal)

        # Missing and repeated removals are no-ops, matching remove_group! behavior.
        ops, reg, _ = compile_ops([Remove(:missing)], stack, registry)
        @test isempty(ops)
        @test Set(keys(reg)) == Set(keys(registry))
        ops, reg, _ = compile_ops([Remove(:metal), Remove(:metal)], stack, registry)
        @test length(ops) == 1

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
        Extrude,
        Fuse,
        GetBoundary,
        GetInterface,
        Hollow,
        LayerRef,
        LayerRegistry,
        LayerState,
        NULL,
        Remove,
        RestrictTo,
        Revolve,
        SetPeriodic,
        SolidModelTarget,
        SourceLayer,
        SourceStack,
        Translate
    import DeviceLayout: μm

    function render_case(name, cs, stack, ops)
        sg = SchematicGraph(name)
        add_node!(sg, BasicComponent(cs); base_id="fixture")
        schematic = plan(sg; log_dir=nothing) |> check!
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
                layer => SourceLayer(NULL; level=1, offset=0μm, thickness=thickness) for
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
            cs = CoordinateSystem(name, μm)
            place!(cs, _rectangle(0.0, 0.0, 2.0, 2.0), LayerRef(:a))
            place!(cs, _rectangle(1.0, 0.0, 3.0, 2.0), LayerRef(:b))
            place!(cs, _rectangle(10.0, 0.0, 11.0, 1.0), :legacy)
            result = render_case("compiler_geometry_$name", cs, flat_stack(:a, :b), ops)
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
        cs = CoordinateSystem{Float64}("sparse_intersections")
        for (layer, name, x0) in (
            (:objects, "first", 0.0),
            (:objects, "second", 3.0),
            (:tools, "first", 0.5),
            (:tools, "second", 3.5)
        )
            place!(cs, Rectangle(Point(x0, 0.0), Point(x0 + 1.0, 1.0)), LayerRef(layer))
        end
        result = render_case(
            "compiler_geometry_sparse_intersections",
            cs,
            SourceStack(
                :objects => SourceLayer(NULL; level=1, offset=0.0, thickness=0.0),
                :tools => SourceLayer(NULL; level=1, offset=0.0, thickness=0.0);
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
        cs = CoordinateSystem("adjacent_volumes", μm)
        place!(cs, _rectangle(0.0, 0.0, 1.0, 1.0), LayerRef(:left))
        place!(cs, _rectangle(1.0, 0.0, 2.0, 1.0), LayerRef(:right))
        result = render_case(
            "compiler_geometry_interface",
            cs,
            flat_stack(:left, :right; thickness=1μm),
            [
                Extrude(:left),
                Extrude(:right),
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
                Extrude(:volume),
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
        cs = CoordinateSystem("translated_boundary", μm)
        place!(cs, _rectangle(0.0, 0.0, 2.0, 1.0), LayerRef(:shape))
        translated = render_case(
            "compiler_geometry_translated_boundary",
            cs,
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

    @testset "Explicit extrusion and hollowing" begin
        cs = CoordinateSystem("hollow", μm)
        place!(cs, _rectangle(0.0, 0.0, 4.0, 4.0), LayerRef(:box))
        place!(cs, _rectangle(1.0, 1.0, 2.0, 2.0), LayerRef(:bump))
        place!(cs, _rectangle(1.0, 2.5, 2.0, 3.5), LayerRef(:foot))
        place!(cs, _rectangle(3.0, 1.0, 3.5, 1.5), LayerRef(:outline))
        stack = SourceStack(
            :box => SourceLayer(NULL; level=1, thickness=2μm),
            :bump => SourceLayer(NULL; level=1, offset=0.5μm, thickness=1μm),
            :foot => SourceLayer(NULL; level=1, thickness=1μm),
            :outline => SourceLayer(NULL; level=1, thickness=1μm);
            levels=(1 => 0μm, 2 => 2μm)
        )
        result = render_case(
            "compiler_geometry_hollow",
            cs,
            stack,
            [
                Extrude(:box),
                Extrude(:bump),
                Hollow(:bump),
                Extrude(:foot),
                Hollow(:foot),
                # A generated layer reaches a target level from its own z at execution.
                Translate(:copy, :outline, 0μm, 2μm, 0μm),
                Extrude(:copy; to_level=2),
                # Walls: extrude the outline rather than the surface.
                GetBoundary(:outline, :outline),
                Extrude(:outline),
                # Interfaces are realized after hollowing, so the box boundary excludes faces
                # toward removed interiors.
                GetInterface(:box_foot, :box, :foot)
            ]
        )
        layers = result.metadata["layers"]
        @test layer_measure(result, :box_foot) ≈ 5.0 atol = 1e-8
        # Hollowed interiors are gone from the model; the shells remain as the layers.
        @test layer_measure(result, :box) ≈ 4.0 * 4.0 * 2.0 - 2.0 atol = 1e-8
        @test layers["bump"]["dim"] == 2
        @test layers["bump"]["thickness"] == 1.0
        @test layer_measure(result, :bump) ≈ 6.0 atol = 1e-8
        # A solid on the box floor loses its floor face, which bounded nothing else.
        @test layer_measure(result, :foot) ≈ 5.0 atol = 1e-8
        for layer in (:bump, :foot), (_, tag) in layer_dimtags(result, layer)
            @test !isempty(first(SolidModels.gmsh.model.getAdjacencies(2, tag)))
        end
        @test !haskey(layers, String(SolidModelsExperimental._HOLLOWED))
        # to_level on a generated layer, and walls from a 1D outline.
        @test layers["copy"]["dim"] == 3
        @test layers["copy"]["thickness"] ≈ 2.0 atol = 1e-9
        @test layer_measure(result, :copy) ≈ 0.5 atol = 1e-8
        @test collect(layer_bbox(result, :copy)) ≈ [3.0, 3.0, 0.0, 3.5, 3.5, 2.0] atol =
            1e-6
        @test layers["outline"]["dim"] == 2
        @test layer_measure(result, :outline) ≈ 2.0 atol = 1e-8
    end

    @testset "Global restriction" begin
        cs = CoordinateSystem("restricted", μm)
        place!(cs, _rectangle(0.0, 0.0, 3.0, 1.0), LayerRef(:target))
        place!(cs, _rectangle(1.0, 0.0, 2.0, 1.0), LayerRef(:bounds))
        result = render_case(
            "compiler_geometry_restricted",
            cs,
            flat_stack(:target, :bounds; thickness=1μm),
            [Extrude(:target), Extrude(:bounds), RestrictTo(:bounds)]
        )
        @test layer_measure(result, :target) ≈ 1.0 atol = 1e-8
        @test collect(layer_bbox(result, :target)) ≈ [1.0, 0.0, 0.0, 2.0, 1.0, 1.0] atol =
            1e-6
    end

    @testset "Periodic surfaces survive finalization" begin
        cs = CoordinateSystem("periodic", μm)
        place!(cs, _rectangle(0.0, 0.0, 1.0, 1.0), LayerRef(:child))
        place!(cs, _rectangle(0.0, 0.0, 1.0, 1.0), LayerRef(:parent))
        stack = SourceStack(
            :child => SourceLayer(NULL; level=1, thickness=0μm),
            :parent => SourceLayer(NULL; level=2, thickness=0μm);
            levels=(1 => 0μm, 2 => 2μm)
        )
        result = render_case(
            "compiler_geometry_periodic",
            cs,
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

        # A model PG absent from the registry is an error; an unrealized record is pruned.
        registry = LayerRegistry()
        @test_throws ErrorException SolidModelsExperimental.sync_registry!(sm, registry)

        registry[:surface] = LayerState(["surface", "missing"], 2)
        SolidModelsExperimental.sync_registry!(sm, registry)
        @test only(registry[:surface].pgs) == "surface"
    end
end

@testitem "Placement prefix copies" begin
    using DeviceLayout
    using DeviceLayout.SchematicDrivenLayout
    using DeviceLayout.SolidModelsExperimental:
        LayerRef, Locator, LocatorMeta, Tag, Terminal
    import Unitful: μm

    cs = CoordinateSystem("shared", μm)
    place!(cs, Locator(0μm, 0μm), Terminal(:metal, "island"))
    place!(cs, Rectangle(Point(3μm, 0μm), Point(4μm, 1μm)), LayerRef(:metal))
    nested = CoordinateSystem("nested", μm)
    place!(nested, Locator(0μm, 0μm), Tag(:metal, "inner"))
    addref!(cs, nested)
    comp = BasicComponent(cs)
    sg = SchematicGraph("placement_copy")
    add_node!(sg, comp; base_id="q1")
    add_node!(sg, comp; base_id="q2")
    sch = plan(sg; log_dir=nothing)
    check!(sch)

    original_metadata = deepcopy(element_metadata(comp.geometry))
    sch_copy = deepcopy(sch)
    SolidModelsExperimental._qualify_locator_names!(sch_copy)

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
    @test element_metadata(comp.geometry) == original_metadata
    @test name(element_metadata(cs)[1]) == "island"
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
    function _port_schematic(name, cs)
        sg = SchematicGraph(name)
        add_node!(sg, BasicComponent(cs); base_id="q1")
        return plan(sg; log_dir=nothing) |> check!
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
    using DeviceLayout.SolidModelsExperimental: Tag, LayerState, LayerRegistry

    sm = SolidModel("tag_layer"; overwrite=true)
    SolidModels.gmsh.option.setNumber("General.Verbosity", 2)
    first_tag = SolidModels.gmsh.model.occ.addRectangle(0.0, 0.0, 0.0, 10.0, 10.0)
    second_tag = SolidModels.gmsh.model.occ.addRectangle(0.0, 0.0, 0.0, 10.0, 10.0)
    SolidModels.gmsh.model.occ.synchronize()
    sm["layer_a"] = [(Int32(2), Int32(first_tag))]
    sm["layer_b"] = [(Int32(2), Int32(second_tag))]
    registry =
        LayerRegistry(:a => LayerState(["layer_a"], 2), :b => LayerState(["layer_b"], 2))
    rl = SolidModelsExperimental.ResolvedLocator((5.0, 5.0, 0.0), Tag(:a, "tag"))
    bbox_cache = Dict{Int32, NTuple{6, Float64}}()
    sel = SolidModelsExperimental._select_surface!(sm, registry, rl, bbox_cache)
    @test sel.locators == [rl]
    @test sel.entity_tags == [Int32(first_tag)]
    # The selection PG is an ordinary PG registered under the locator's layer.
    @test keys(registry) == Set([:a, :b])
    selection_pg = only(filter(!=("layer_a"), registry[:a].pgs))
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
    using DeviceLayout.SolidModelsExperimental: LayerState, LayerRegistry

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
        :a => LayerState(["e123", "e12", "e2", "e3"], 2),
        :b => LayerState(["e2"], 2)
    )
    SolidModelsExperimental.deduplicate_pgs!(sm, registry, 2)

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
    @test Set(registry[:a].pgs) == Set(keys(pgs))
    @test only(registry[:b].pgs) == only(owners[e2])
    # Every registered PG exists in the model.
    @test all(haskey(pgs, name) for s in values(registry) for name in s.pgs)
end

@testitem "Strictness modes" begin
    using DeviceLayout
    using DeviceLayout.SchematicDrivenLayout
    using DeviceLayout.SolidModels
    using DeviceLayout.SolidModelsExperimental:
        LayerRef, METAL, SolidModelTarget, SourceLayer, SourceStack

    cs = CoordinateSystem{Float64}("warning_surface")
    place!(cs, Rectangle(10.0, 10.0), LayerRef(:metal))
    sg = SchematicGraph("finalization_warning")
    add_node!(sg, BasicComponent(cs); base_id="q1")
    schematic = plan(sg; log_dir=mktempdir()) |> check!
    target = SolidModelTarget(
        SourceStack(
            :metal => SourceLayer(METAL; level=1, offset=0.0, thickness=0.0);
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
        Extrude,
        Fuse,
        GetBoundary,
        GetInterface,
        Ground,
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
                offset=(-500μm, 500μm),
                gds_meta=nothing
            );
            levels=(0 => -500.0μm, 1 => 0.0μm)
        )

        ops = [
            Extrude(:SUBSTRATE_BOTTOM),
            Extrude(:BOUNDING_VOLUME),
            Cut(:METAL_POS, :CHIP_OUTLINE, :METAL_NEG),
            Remove(:CHIP_OUTLINE),
            Cut(:CUTOUT, :METAL_NEG, :PORTS),
            Remove(:METAL_NEG),
            Fuse(:METAL_POS),
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
        sg = SchematicGraph("e2e_test")
        q1 = add_node!(sg, MockTransmon(; name="q1"))
        fuse!(sg, q1 => :right, MockTransmon(; name="q2") => :left)
        schematic = plan(sg; log_dir=nothing) |> check!
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
        art_cell = Cell("e2e_test", nm)
        render!(art_cell, coordinate_system, stack; levels=[1])
        flatten!(art_cell)
        @test !isempty(elements(art_cell))
        artwork_metadata = Set(element_metadata(art_cell))
        @test GDSMeta(10, 0) in artwork_metadata
        @test !(GDSMeta(310, 0) in artwork_metadata)
        save(joinpath(output_dir, "e2e_test.gds"), art_cell)

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
