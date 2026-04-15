@testitem "ParameterSet" setup = [CommonTestSetup] begin
    using DeviceLayout: ParameterSet, resolve, leaf_params
    using DeviceLayout.SchematicDrivenLayout: SchematicGraph

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

        # Error on missing key
        @test_throws ErrorException ps.nonexistent
        @test_throws ErrorException ps.components.qubit.missing_param
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
    end

    @testset "propertynames" begin
        ps = ParameterSet()
        ps.extra = 42
        pnames = propertynames(ps)
        @test :global in pnames
        @test :components in pnames
        @test :extra in pnames
    end

    @testset "show" begin
        ps = ParameterSet()
        io = IOBuffer()
        show(io, ps)
        s = String(take!(io))
        @test contains(s, "ParameterSet")
        @test contains(s, "global")
        @test contains(s, "components")
    end
end

@testitem "SchematicGraph with ParameterSet" setup = [CommonTestSetup] begin
    using DeviceLayout: ParameterSet
    using DeviceLayout.SchematicDrivenLayout: SchematicGraph

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
end
