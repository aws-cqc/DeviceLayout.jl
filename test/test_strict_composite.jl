@testitem "Strict composite components" setup = [CommonTestSetup] begin
    using .SchematicDrivenLayout
    import .SchematicDrivenLayout:
        AbstractComponent,
        AbstractStrictCompositeComponent,
        _build_subcomponent,
        compose_hookname,
        decompose_hookname,
        nodes,
        component,
        components,
        subcomponents

    reset_uniquename!()

    METAL = SemanticMeta(:metal)

    # Simple leaf component used to fill slots throughout.
    @compdef struct StrictLeaf <: Component
        name = "leaf"
        width = 10μm
        gap = 2μm
    end
    SchematicDrivenLayout.hooks(c::StrictLeaf) = (;
        a=PointHook(zero(c.width), zero(c.width), 0°),
        b=PointHook(c.width, zero(c.width), 180°)
    )
    SchematicDrivenLayout._geometry!(cs::CoordinateSystem, c::StrictLeaf) =
        render!(cs, centered(Rectangle(c.width, c.width)), METAL)

    # Reference strict composite: two distinct slots, shared + prefixed forwarding,
    # a per-slot override, and one mapped hook.
    @compdef struct StrictPair <: StrictCompositeComponent
        name = "pair"
        width = 12μm      # shared with StrictLeaf
        right_gap = 5μm   # prefixed: forwarded to the :right slot as `gap`
        extra = 1μm       # matches nothing; must be silently ignored
    end
    SchematicDrivenLayout.composite_spec(::Type{StrictPair}) = (
        slots=(; left=StrictLeaf, right=StrictLeaf),
        nodes=(:left => :left, :right => :right)
    )
    SchematicDrivenLayout._build_subcomponent(cc::StrictPair, ::Val{:left}) = (; gap=3μm)
    function SchematicDrivenLayout._graph!(
        g::SchematicGraph,
        cc::StrictPair,
        subcomps::NamedTuple
    )
        return fuse!(g, g.left => :b, g.right => :a)
    end
    SchematicDrivenLayout.map_hooks(::Type{StrictPair}) = Dict((:left => :a) => :input)

    @testset "Spec introspection accessors" begin
        @test slot_names(StrictPair) == (:left, :right)
        @test slot_types(StrictPair) == (StrictLeaf, StrictLeaf)
        @test node_ids(StrictPair) == (:left, :right)
        @test node_slots(StrictPair) == (:left, :right)
        @test slot_of_node(StrictPair, :right) == :right
        @test_throws ArgumentError slot_of_node(StrictPair, :nope)
        @test validate_composite_spec(StrictPair) === composite_spec(StrictPair)
    end

    @testset "Derived build and parameter forwarding" begin
        cc = StrictPair(; width=20μm, right_gap=7μm)
        g = graph(cc)
        @test length(nodes(g)) == 2
        @test nodes(g)[1].id == "left"
        @test nodes(g)[2].id == "right"
        # Node lookup by declared id
        @test cc.left === nodes(g)[1]
        left = component(cc.left)
        right = component(cc.right)
        # Instances are named after their slot
        @test name(left) == "left"
        @test name(right) == "right"
        # Shared parameter forwarded to both slots
        @test left.width == 20μm
        @test right.width == 20μm
        # Prefixed parameter beats the slot default; other slots unaffected
        @test right.gap == 7μm
        # _build_subcomponent override wins for :left
        @test left.gap == 3μm
        # `extra` matched nothing and was dropped without warning
        @test !(:extra in propertynames(parameters(left)))
    end

    @testset "Prefixed forwarding beats shared forwarding" begin
        # A composite with both `gap` (shared) and `right_gap` (prefixed): the
        # prefixed value must win for the :right slot, while :left sees `gap`.
        @compdef struct StrictShadow <: StrictCompositeComponent
            name = "shadow"
            gap = 4μm
            right_gap = 6μm
        end
        SchematicDrivenLayout.composite_spec(::Type{StrictShadow}) = (
            slots=(; left=StrictLeaf, right=StrictLeaf),
            nodes=(:left => :left, :right => :right)
        )
        SchematicDrivenLayout._graph!(g::SchematicGraph, ::StrictShadow, ::NamedTuple) =
            nothing
        cc = StrictShadow()
        @test component(cc.left).gap == 4μm
        @test component(cc.right).gap == 6μm
    end

    @testset "Hook naming and lookup" begin
        cc = StrictPair()
        h = hooks(cc)
        @test :input in keys(h)         # mapped
        @test :left_b in keys(h)        # node-id fallback
        @test :right_a in keys(h)
        @test :right_b in keys(h)
        # Name-based and index-based lookup agree
        @test hooks(cc, :left, :a).p == h.input.p
        @test hooks(cc, 1, :a).p == h.input.p
        @test hooks(cc, :right, :b).p == h.right_b.p
        @test_throws ArgumentError hooks(cc, :nope, :a)
        # decompose_hookname round-trips both mapped and fallback names
        @test decompose_hookname(cc, :input) == (1 => :a)
        @test decompose_hookname(cc, :right_b) == (2 => :b)
    end

    @testset "Multi-use slots" begin
        @compdef struct StrictTwins <: StrictCompositeComponent
            name = "twins"
            width = 8μm
        end
        SchematicDrivenLayout.composite_spec(::Type{StrictTwins}) =
            (slots=(; twin=StrictLeaf), nodes=(:t1 => :twin, :t2 => :twin))
        function SchematicDrivenLayout._graph!(
            g::SchematicGraph,
            cc::StrictTwins,
            subcomps::NamedTuple
        )
            return fuse!(g, g.t1 => :b, g.t2 => :a)
        end
        cc = StrictTwins()
        g = graph(cc)
        @test length(nodes(g)) == 2
        # Both nodes hold the *same* component instance
        @test component(cc.t1) === component(cc.t2)
        @test keys(subcomponents(cc)) == (:twin,)
        # Hooks are disambiguated per node id
        h = hooks(cc)
        @test :t1_a in keys(h) && :t2_a in keys(h)
        @test h.t1_a.p != h.t2_a.p # placed at different graph positions
    end

    @testset "Appended machinery nodes keep v1 fallback naming" begin
        @compdef struct StrictAppend <: StrictCompositeComponent
            name = "app"
            width = 10μm
        end
        SchematicDrivenLayout.composite_spec(::Type{StrictAppend}) =
            (slots=(; core=StrictLeaf), nodes=(:core => :core,))
        function SchematicDrivenLayout._graph!(
            g::SchematicGraph,
            cc::StrictAppend,
            subcomps::NamedTuple
        )
            # Fusing a bare component appends a machinery node beyond the
            # declared prefix — allowed.
            return fuse!(g, g.core => :b, StrictLeaf(; name="extra") => :a)
        end
        cc = StrictAppend()
        g = graph(cc)
        @test length(nodes(g)) == 2
        @test nodes(g)[1].id == "core"
        # Machinery node hooks use positional fallback names
        @test compose_hookname(cc, 2, :b) == :_2_b
        @test :_2_b in keys(hooks(cc))
        @test :core_a in keys(hooks(cc))
    end

    @testset "Malformed declarations" begin
        # Missing composite_spec
        @compdef struct StrictNoSpec <: StrictCompositeComponent
            name = "nospec"
        end
        @test_throws ArgumentError composite_spec(StrictNoSpec)
        @test_throws ArgumentError graph(StrictNoSpec())

        # Wrong spec keys
        @compdef struct StrictBadKeys <: StrictCompositeComponent
            name = "badkeys"
        end
        SchematicDrivenLayout.composite_spec(::Type{StrictBadKeys}) =
            (slot=(; s=StrictLeaf), nodes=(:a => :s,))
        @test_throws ArgumentError validate_composite_spec(StrictBadKeys)

        # Non-component slot type
        @compdef struct StrictBadSlotType <: StrictCompositeComponent
            name = "badslot"
        end
        SchematicDrivenLayout.composite_spec(::Type{StrictBadSlotType}) =
            (slots=(; s=Int), nodes=(:a => :s,))
        @test_throws ArgumentError validate_composite_spec(StrictBadSlotType)

        # Slot value is an instance, not a type
        @compdef struct StrictInstanceSlot <: StrictCompositeComponent
            name = "instslot"
        end
        SchematicDrivenLayout.composite_spec(::Type{StrictInstanceSlot}) =
            (slots=(; s=StrictLeaf(; name="s")), nodes=(:a => :s,))
        @test_throws ArgumentError validate_composite_spec(StrictInstanceSlot)

        # nodes not a Tuple
        @compdef struct StrictVecNodes <: StrictCompositeComponent
            name = "vecnodes"
        end
        SchematicDrivenLayout.composite_spec(::Type{StrictVecNodes}) =
            (slots=(; s=StrictLeaf), nodes=[:a => :s])
        @test_throws ArgumentError validate_composite_spec(StrictVecNodes)

        # node entry not a Pair{Symbol, Symbol}
        @compdef struct StrictBadNodeEntry <: StrictCompositeComponent
            name = "badnode"
        end
        SchematicDrivenLayout.composite_spec(::Type{StrictBadNodeEntry}) =
            (slots=(; s=StrictLeaf), nodes=(:a => 1,))
        @test_throws ArgumentError validate_composite_spec(StrictBadNodeEntry)

        # Duplicate node ids
        @compdef struct StrictDupIds <: StrictCompositeComponent
            name = "dup"
        end
        SchematicDrivenLayout.composite_spec(::Type{StrictDupIds}) =
            (slots=(; s=StrictLeaf), nodes=(:a => :s, :a => :s))
        @test_throws ArgumentError validate_composite_spec(StrictDupIds)

        # Undeclared slot referenced by a node
        @compdef struct StrictUndeclSlot <: StrictCompositeComponent
            name = "undecl"
        end
        SchematicDrivenLayout.composite_spec(::Type{StrictUndeclSlot}) =
            (slots=(; s=StrictLeaf), nodes=(:a => :nope,))
        @test_throws ArgumentError validate_composite_spec(StrictUndeclSlot)

        # Unused slot
        @compdef struct StrictUnusedSlot <: StrictCompositeComponent
            name = "unused"
        end
        SchematicDrivenLayout.composite_spec(::Type{StrictUnusedSlot}) =
            (slots=(; s=StrictLeaf, orphan=StrictLeaf), nodes=(:a => :s,))
        @test_throws ArgumentError validate_composite_spec(StrictUnusedSlot)
    end

    @testset "Malformed hook maps" begin
        # v1 integer-indexed keys are rejected on strict types
        @compdef struct StrictIntHooks <: StrictCompositeComponent
            name = "inthooks"
        end
        SchematicDrivenLayout.composite_spec(::Type{StrictIntHooks}) =
            (slots=(; s=StrictLeaf), nodes=(:a => :s,))
        SchematicDrivenLayout.map_hooks(::Type{StrictIntHooks}) = Dict((1 => :a) => :input)
        @test_throws ArgumentError validate_composite_spec(StrictIntHooks)

        # Undeclared node id in the hook map
        @compdef struct StrictHookNode <: StrictCompositeComponent
            name = "hooknode"
        end
        SchematicDrivenLayout.composite_spec(::Type{StrictHookNode}) =
            (slots=(; s=StrictLeaf), nodes=(:a => :s,))
        SchematicDrivenLayout.map_hooks(::Type{StrictHookNode}) =
            Dict((:nope => :a) => :input)
        @test_throws ArgumentError validate_composite_spec(StrictHookNode)

        # Two subcomponent hooks mapped to the same composite name
        @compdef struct StrictDupHookName <: StrictCompositeComponent
            name = "duphook"
        end
        SchematicDrivenLayout.composite_spec(::Type{StrictDupHookName}) =
            (slots=(; s=StrictLeaf), nodes=(:a => :s,))
        SchematicDrivenLayout.map_hooks(::Type{StrictDupHookName}) =
            Dict((:a => :a) => :x, (:a => :b) => :x)
        @test_throws ArgumentError validate_composite_spec(StrictDupHookName)
    end

    @testset "_graph! must preserve the declared node prefix" begin
        # Removing a declared node is detected (node count shrinks)
        @compdef struct StrictRemNode <: StrictCompositeComponent
            name = "rem"
        end
        SchematicDrivenLayout.composite_spec(::Type{StrictRemNode}) =
            (slots=(; s=StrictLeaf), nodes=(:a => :s, :b => :s))
        function SchematicDrivenLayout._graph!(
            g::SchematicGraph,
            cc::StrictRemNode,
            subcomps::NamedTuple
        )
            rem_node!(g, g.b)
            return nothing
        end
        @test_throws ArgumentError graph(StrictRemNode())

        # Reordering is detected (rem_node! swaps with the last node)
        @compdef struct StrictReorder <: StrictCompositeComponent
            name = "reorder"
        end
        SchematicDrivenLayout.composite_spec(::Type{StrictReorder}) =
            (slots=(; s=StrictLeaf), nodes=(:a => :s, :b => :s))
        function SchematicDrivenLayout._graph!(
            g::SchematicGraph,
            cc::StrictReorder,
            subcomps::NamedTuple
        )
            fuse!(g, g.a => :b, StrictLeaf(; name="extra") => :a)
            rem_node!(g, g.a) # swap-with-last puts "extra" at index 1
            return nothing
        end
        @test_throws ArgumentError graph(StrictReorder())
    end

    @testset "ParameterSet integration" begin
        ps = ParameterSet(
            Dict{String, Any}(
                "global" => Dict{String, Any}(),
                "components" => Dict{String, Any}(
                    "pair" => Dict{String, Any}(
                        "width" => 30μm,
                        "right" => Dict{String, Any}("gap" => 9μm),
                        "left" => Dict{String, Any}("gap" => 99μm)
                    )
                )
            )
        )
        cc = create_component(StrictPair, ps, "components.pair")
        # Composite-level leaf applied
        @test cc.width == 30μm
        g = graph(cc)
        right = component(cc.right)
        left = component(cc.left)
        # Shared forwarding uses the PS-provided composite value
        @test right.width == 30μm
        # PS slot overlay beats the forwarded prefix default
        @test right.gap == 9μm
        # _build_subcomponent override beats the PS overlay
        @test left.gap == 3μm
        # Slot leaf access is tracked
        @test "components.pair.right.gap" in ps.accessed
        @test "components.pair.left.gap" in ps.accessed

        # Unknown slot leaf surfaces as an error at graph build
        ps_typo = ParameterSet(
            Dict{String, Any}(
                "components" => Dict{String, Any}(
                    "pair" => Dict{String, Any}(
                        "right" => Dict{String, Any}("gapp" => 9μm)
                    )
                )
            )
        )
        cc_typo = create_component(StrictPair, ps_typo, "components.pair")
        @test_throws ArgumentError graph(cc_typo)

        # A leaf *at* a slot address is rejected rather than silently ignored.
        # (Inject the graph directly: reaching this state through the public
        # address form requires the leaf name to collide with a composite
        # parameter.)
        ps_leaf = ParameterSet(
            Dict{String, Any}(
                "components" =>
                    Dict{String, Any}("pair" => Dict{String, Any}("left" => 5μm))
            )
        )
        cc_leaf = create_component(
            StrictPair,
            "pair";
            _graph=SchematicGraph(uniquename("pair"), ps_leaf)
        )
        @test_throws ArgumentError graph(cc_leaf)

        # A PS that doesn't mention a slot leaves it at defaults
        ps_sparse = ParameterSet(
            Dict{String, Any}(
                "components" =>
                    Dict{String, Any}("pair" => Dict{String, Any}("width" => 25μm))
            )
        )
        cc_sparse = create_component(StrictPair, ps_sparse, "components.pair")
        graph(cc_sparse)
        @test component(cc_sparse.right).gap == 5μm # prefixed composite default
    end

    @testset "Composite variants inherit the spec" begin
        @composite_variant StrictPairVariant StrictPair new_defaults = (; width=42μm)
        @test composite_spec(StrictPairVariant) === composite_spec(StrictPair)
        @test node_ids(StrictPairVariant) == (:left, :right)
        cc = StrictPairVariant()
        g = graph(cc)
        @test nodes(g)[1].id == "left"
        @test component(cc.left).width == 42μm
        @test component(cc.left).gap == 3μm # base _build_subcomponent override
        @test :input in keys(hooks(cc))     # base map_hooks
    end

    @testset "Parametric strict components" begin
        @compdef struct StrictParam{S} <: StrictCompositeComponent
            name = "param"
            width = 10μm
        end
        SchematicDrivenLayout.composite_spec(::Type{StrictParam{S}}) where {S} =
            (slots=(; core=S), nodes=(:core => :core,))
        SchematicDrivenLayout._graph!(g::SchematicGraph, ::StrictParam, ::NamedTuple) =
            nothing
        cc = StrictParam{StrictLeaf}()
        @test slot_types(typeof(cc)) == (StrictLeaf,)
        g = graph(cc)
        @test component(cc.core) isa StrictLeaf
        @test component(cc.core).width == 10μm # shared forwarding
    end

    @testset "add_node! explicit ids" begin
        g = SchematicGraph("addnode")
        n1 = add_node!(g, StrictLeaf(; name="x"); id=:custom)
        @test n1.id == "custom"
        @test g.custom === n1
        # Reuse is rejected
        @test_throws ErrorException add_node!(g, StrictLeaf(; name="y"); id=:custom)
        # Auto-generated ids don't collide with registered explicit ids
        n2 = add_node!(g, StrictLeaf(; name="custom"))
        @test n2.id != "custom"
        # Ids that uniquename would normalize are rejected up front
        @test_throws ErrorException add_node!(g, StrictLeaf(; name="z"); id=:z_0)
    end

    @testset "ExampleStrictRectangleTransmon matches the v1 component" begin
        using .SchematicDrivenLayout.ExamplePDK.Transmons:
            ExampleStrictRectangleTransmon, ExampleRectangleTransmon
        # ExamplePDK defaults use nm-preferred units; use matching units here since
        # Unitful cannot promote across different unit preferences.
        tr = ExampleStrictRectangleTransmon(; junction_gap=14μm2nm, cap_length=500μm2nm)
        tr_v1 = ExampleRectangleTransmon(; junction_gap=14μm2nm, cap_length=500μm2nm)
        @test slot_names(typeof(tr)) == (:island, :junction)
        # Junction override matches the v1 build rule
        @test component(tr.junction).ground_island_length == 14μm2nm
        # Island shares the composite parameters
        @test component(tr.island).cap_length == 500μm2nm
        # Mapped hooks agree with the v1 component
        for h in (:readout, :xy, :z)
            @test hooks(tr, h).p ≈ hooks(tr_v1, h).p
        end
        # Geometry is equivalent
        @test bounds(geometry(tr)) == bounds(geometry(tr_v1))
    end
end
