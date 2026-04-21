@testitem "ParameterSet" setup = [CommonTestSetup] begin
    using DeviceLayout.SchematicDrivenLayout:
        ParameterSet, ParameterKeyError, resolve, leaf_params, SchematicGraph

    @testset "Construction" begin
        # Empty ParameterSet has required namespaces
        ps = ParameterSet()
        @test haskey(ps.data, "global")
        @test haskey(ps.data, "components")
        @test ps.data["global"] isa Dict
        @test ps.data["components"] isa Dict
        @test ps.path == ""

        # From Dict — required namespaces are added if missing
        ps = ParameterSet(Dict{String, Any}("custom" => 42))
        @test haskey(ps.data, "global")
        @test haskey(ps.data, "components")
        @test ps.data["custom"] == 42

        # From Dict — existing namespaces are preserved
        ps = ParameterSet()
        ps.global.version = 1
        ps.components.qubit = ("cap_width" => 300)
        @test ps.global.version == 1
        @test ps.components.qubit.cap_width == 300
    end

    @testset "Dot access" begin
        ps = ParameterSet()
        ps.global.version = 1
        ps.components.qubit = ("cap_width" => 300)
        ps.components.qubit.cap_gap = 20

        # Namespace access returns scoped ParameterSet
        qubit_ps = ps.components.qubit
        @test qubit_ps isa ParameterSet

        # Leaf access returns value
        @test ps.components.qubit.cap_width == 300
        @test ps.components.qubit.cap_gap == 20
        @test ps.global.version == 1

        # Reading a missing key shows error (no exception from show)
        @test contains(string(ps.nonexistent), "ParameterKeyError")
        @test contains(string(ps.components.qubit.missing_param), "ParameterKeyError")

        # Using a missing key as a value throws
        @test_throws ParameterKeyError iterate(ps.nonexistent)
    end

    @testset "resolve" begin
        ps = ParameterSet()
        ps.components.qubit = ("cap_width" => 300)

        # Resolve to subtree
        qubit_ps = resolve(ps, "components.qubit")
        @test qubit_ps isa ParameterSet

        # Resolve to leaf
        @test resolve(ps, "components.qubit.cap_width") == 300

        # Resolve to namespace
        comp_ps = resolve(ps, "components")
        @test comp_ps isa ParameterSet
    end

    @testset "leaf_params" begin
        ps = ParameterSet()
        ps.components.cap_width = 300
        ps.components.cap_gap = 20
        ps.components.junction = ("width" => 200)

        # Extracts only non-Dict entries
        lp = leaf_params(ps.components)
        @test :cap_width in keys(lp)
        @test :cap_gap in keys(lp)
        @test !(:junction in keys(lp))
        @test lp.cap_width == 300
        @test lp.cap_gap == 20

        # Empty dict returns empty NamedTuple
        lp_empty = leaf_params(ps.global)
        @test lp_empty == (;)
    end

    @testset "Access tracking" begin
        ps = ParameterSet()
        ps.components.qubit = ("cap_width" => 300)
        ps.components.qubit.cap_gap = 20

        # Tracked set is initially empty
        @test isempty(ps.accessed)

        # Accessing a leaf tracks it
        _ = ps.components.qubit.cap_width
        @test "cap_width" in ps.accessed

        # Tracking is shared across scoped views
        sub = ps.components.qubit
        _ = sub.cap_gap
        @test "cap_gap" in ps.accessed
    end

    @testset "Dot-access mutation" begin
        ps = ParameterSet()

        # Set a leaf value
        ps.global.version = 1
        @test ps.global.version == 1

        # Set a new namespace
        ps.components.qubit = ("cap_width" => 300)
        @test ps.components.qubit.cap_width == 300

        # Overwrite a leaf value
        ps.components.qubit.cap_width = 500
        @test ps.components.qubit.cap_width == 500

        # Chained auto-vivification for deep paths
        ps2 = ParameterSet()
        ps2.components.transmon.island.cap_length = 520
        @test ps2.components.transmon.island.cap_length == 520
    end

    @testset "propertynames" begin
        ps = ParameterSet()
        ps.extra = 42
        pnames = propertynames(ps)
        @test :global in pnames
        @test :components in pnames
        @test :extra in pnames
    end

    @testset "Scoped views skip namespace injection" begin
        # Scoped ParameterSets (from `ps.components.qubit` etc.) must NOT have
        # "global"/"components" keys injected into the interior subtree. Only
        # the top-level ParameterSet carries the required-namespace invariant.
        ps = ParameterSet()
        ps.components.qubit.cap_width = 300

        sub = ps.components.qubit
        @test sub isa ParameterSet
        # Scoped view exposes only the qubit subtree's own keys
        @test Set(propertynames(sub)) == Set([:cap_width])
        @test !haskey(sub.data, "global")
        @test !haskey(sub.data, "components")

        # And the top-level data wasn't polluted by the scoped lookup
        @test !haskey(ps.data["components"]["qubit"], "global")
        @test !haskey(ps.data["components"]["qubit"], "components")
    end

    @testset "show" begin
        ps = ParameterSet()
        ps.components.qubit.cap_width = 300

        # Compact show (single line)
        io = IOBuffer()
        show(io, ps)
        s = String(take!(io))
        @test contains(s, "ParameterSet")
        @test contains(s, "global")
        @test contains(s, "components")

        # text/plain — indented tree (top namespaces indented)
        io = IOBuffer()
        show(io, MIME("text/plain"), ps)
        s = String(take!(io))
        @test contains(s, "ParameterSet")
        @test contains(s, "  components")
        @test contains(s, "    qubit")
        @test contains(s, "      cap_width = 300")

        # text/markdown — nested list
        io = IOBuffer()
        show(io, MIME("text/markdown"), ps)
        s = String(take!(io))
        @test contains(s, "**ParameterSet**")
        @test contains(s, "- **components**")
        @test contains(s, "    - cap_width = `300`")

        # text/html — nested <ul>
        io = IOBuffer()
        show(io, MIME("text/html"), ps)
        s = String(take!(io))
        @test contains(s, "<b>ParameterSet</b>")
        @test contains(s, "<b>qubit</b>")
        @test contains(s, "cap_width = <code>300</code>")
    end
end

@testitem "SchematicGraph with ParameterSet" setup = [CommonTestSetup] begin
    using DeviceLayout.SchematicDrivenLayout:
        ParameterSet, SchematicGraph, parameter_set, create_component

    @testset "Default constructor" begin
        g = SchematicGraph("test")
        @test g.name == "test"
        @test g.parameter_set === nothing
    end

    @testset "Constructor with ParameterSet" begin
        ps = ParameterSet()
        ps.global.version = 1
        ps.components.qubit = ("cap_width" => 300)

        g = SchematicGraph("test", ps)
        @test g.parameter_set === ps
        @test g.parameter_set.components.qubit.cap_width == 300
        @test g.name == "test"
    end

    @testset "getproperty accesses parameter_set" begin
        ps = ParameterSet()
        g = SchematicGraph("test", ps)
        @test g.parameter_set === ps
        @test g.parameter_set isa ParameterSet
    end

    @testset "Copy constructor" begin
        # Copy with ParameterSet preserves name and parameter_set
        ps = ParameterSet()
        ps.components.qubit = ("cap_width" => 300)
        g = SchematicGraph("original", ps)
        g_copy = SchematicGraph(g)
        @test g_copy.name == "original"
        @test g_copy.parameter_set === ps
        @test g_copy.parameter_set.components.qubit.cap_width == 300

        # Copy without ParameterSet
        g_no_ps = SchematicGraph("bare")
        g_no_ps_copy = SchematicGraph(g_no_ps)
        @test g_no_ps_copy.name == "bare"
        @test g_no_ps_copy.parameter_set === nothing

        # Copy creates a fresh graph (independent nodes/edges)
        @test g_copy !== g
    end

    @testset "parameter_set function" begin
        # Returns nothing for graph without ParameterSet
        g = SchematicGraph("test")
        @test parameter_set(g) === nothing

        # Returns the ParameterSet for graph with one
        ps = ParameterSet()
        ps.components.qubit = ("cap_width" => 300)
        g = SchematicGraph("test", ps)
        @test parameter_set(g) === ps
        @test parameter_set(g).components.qubit.cap_width == 300
    end

    @testset "create_component with ParameterSet" begin
        using DeviceLayout.SchematicDrivenLayout: parameters
        using DeviceLayout.SchematicDrivenLayout.ExamplePDK.Transmons:
            ExampleRectangleIsland

        ps = ParameterSet()
        ps.components.island = ("cap_width" => 30)
        ps.components.island.cap_length = 400

        # Create component from parameter set subtree
        island = create_component(ExampleRectangleIsland, ps, "components.island")
        @test island isa ExampleRectangleIsland
        p = parameters(island)
        @test p.cap_width == 30
        @test p.cap_length == 400

        # Accessed parameters are tracked
        @test "components.island.cap_width" in ps.accessed
        @test "components.island.cap_length" in ps.accessed
    end

    @testset "create_component with scoped ParameterSet" begin
        using DeviceLayout.SchematicDrivenLayout: parameters
        using DeviceLayout.SchematicDrivenLayout.ExamplePDK.Transmons:
            ExampleRectangleIsland

        ps = ParameterSet()
        ps.components.island.cap_width = 30
        ps.components.island.cap_length = 400

        # Scoped dot-chain access returns a ParameterSet that can be passed directly
        sub = ps.components.island
        @test sub isa ParameterSet

        island = create_component(ExampleRectangleIsland, sub)
        @test island isa ExampleRectangleIsland
        p = parameters(island)
        @test p.cap_width == 30
        @test p.cap_length == 400
        # Defaults preserved for unset leaves
        @test p.cap_gap == parameters(ExampleRectangleIsland()).cap_gap

        # Accessed tracking: leaf-only keys (scoped ParameterSet has no prefix)
        @test "cap_width" in ps.accessed
        @test "cap_length" in ps.accessed

        # Inline chained form works identically
        ps2 = ParameterSet()
        ps2.components.island.cap_width = 50
        island2 = create_component(ExampleRectangleIsland, ps2.components.island)
        @test parameters(island2).cap_width == 50

    end

    @testset "set_parameters with value => :name pairs" begin
        using DeviceLayout.SchematicDrivenLayout: parameters, set_parameters
        using DeviceLayout.SchematicDrivenLayout.ExamplePDK.Transmons:
            ExampleRectangleIsland
        using Unitful: μm

        ps = ParameterSet()
        ps.components.transmon.junction_gap = 15μm

        island = ExampleRectangleIsland()
        # Reversed pair: value => :param_name
        island2 = set_parameters(island, ps.components.transmon.junction_gap => :junction_gap)
        @test parameters(island2).junction_gap == 15μm

        # Forwarding a value under a different parameter name
        island3 = set_parameters(island, ps.components.transmon.junction_gap => :cap_gap)
        @test parameters(island3).cap_gap == 15μm
        # Untouched parameters keep their previous values
        @test parameters(island3).cap_width == parameters(island).cap_width

        # Multiple pairs
        island4 = set_parameters(
            island,
            40μm => :cap_width,
            600μm => :cap_length
        )
        @test parameters(island4).cap_width == 40μm
        @test parameters(island4).cap_length == 600μm

        # Pairs combine with trailing kwargs (distinct keys)
        island5 = set_parameters(island, 40μm => :cap_width; cap_length=600μm)
        @test parameters(island5).cap_width == 40μm
        @test parameters(island5).cap_length == 600μm

        # Zero pairs is a no-op copy
        island6 = set_parameters(island)
        @test parameters(island6).cap_width == parameters(island).cap_width
    end
end

@testitem "ParameterSet YAML IO" setup = [CommonTestSetup] begin
    using DeviceLayout.SchematicDrivenLayout:
        ParameterSet, resolve, leaf_params, save_parameter_set
    using YAML
    using Unitful: μm, ustrip, unit

    @testset "save_parameter_set to IO" begin
        ps = ParameterSet()
        ps.global.version = 1
        ps.components.cap.finger_length = 150μm
        ps.components.cap.finger_count = 6

        io = IOBuffer()
        save_parameter_set(io, ps)
        yaml_str = String(take!(io))

        # Unitful quantities serialized as quoted unit strings
        @test contains(yaml_str, "finger_length: \"150μm\"") ||
              contains(yaml_str, "finger_length: \"150.0μm\"")
        # Plain numbers stay as numbers
        @test contains(yaml_str, "finger_count: 6")
        @test contains(yaml_str, "version: 1")
    end

    @testset "ParameterSet from IO" begin
        yaml_str = """
        global:
          version: 2
        components:
          qubit:
            cap_width: 300μm
            cap_gap: 20μm
            finger_count: 4
        """
        io = IOBuffer(yaml_str)
        ps = ParameterSet(io)

        @test ps.global.version == 2
        @test ps.components.qubit.cap_width == 300μm
        @test ps.components.qubit.cap_gap == 20μm
        @test ps.components.qubit.finger_count == 4
    end

    @testset "IO round-trip with Unitful" begin
        ps = ParameterSet()
        ps.global.process_node = "fab_v3"
        ps.components.jj.w_jj = 1μm
        ps.components.jj.h_jj = 0.5μm
        ps.components.jj.count = 2

        # Write
        io = IOBuffer()
        save_parameter_set(io, ps)
        yaml_bytes = take!(io)

        # Read back
        ps2 = ParameterSet(IOBuffer(yaml_bytes))

        @test ps2.global.process_node == "fab_v3"
        @test ps2.components.jj.w_jj == 1μm
        @test ps2.components.jj.h_jj == 0.5μm
        @test ps2.components.jj.count == 2
    end

    @testset "ParameterSet from IO with path" begin
        yaml_str = """
        global:
          version: 1
        components:
          res:
            length: 500μm
        """
        io = IOBuffer(yaml_str)
        ps = ParameterSet(io, "my_design.yaml")

        @test ps.path == "my_design.yaml"
        @test ps.components.res.length == 500μm
    end

    @testset "File round-trip" begin
        ps = ParameterSet()
        ps.global.version = 1
        ps.components.cap.width = 150μm
        ps.components.cap.gap = 3μm
        ps.components.cap.count = 6

        path = joinpath(tdir, "test_ps.yaml")
        save_parameter_set(path, ps)

        ps2 = ParameterSet(path)
        @test ps2.path == path
        @test ps2.global.version == 1
        @test ps2.components.cap.width == 150μm
        @test ps2.components.cap.gap == 3μm
        @test ps2.components.cap.count == 6
    end

    @testset "Nested namespaces round-trip" begin
        ps = ParameterSet()
        ps.components.transmon.island.cap_length = 520μm
        ps.components.transmon.island.cap_width = 24μm
        ps.components.transmon.junction.w_jj = 1μm

        io = IOBuffer()
        save_parameter_set(io, ps)
        ps2 = ParameterSet(IOBuffer(take!(io)))

        @test ps2.components.transmon.island.cap_length == 520μm
        @test ps2.components.transmon.island.cap_width == 24μm
        @test ps2.components.transmon.junction.w_jj == 1μm
    end
end
