@testsnippet ParamExtractionSetup begin
    using Test
    using DeviceLayout, Unitful
    import Unitful: nm, μm, mm
    using DeviceLayout.SchematicDrivenLayout

    import DeviceLayout.SchematicDrivenLayout:
        AbstractComponent,
        AbstractCompositeComponent,
        nodes,
        component,
        extract_parameters,
        parameters_to_yaml

    reset_uniquename!()

    @compdef struct ExtTestLeaf <: AbstractComponent{typeof(1.0nm)}
        name::String = "example_leaf_component"
        width = 100nm
        gap = 10nm
    end
    SchematicDrivenLayout.hooks(::ExtTestLeaf) = (
        origin=PointHook(Point(0nm, 0nm), 0),
    )

    @compdef struct ExtTestComposite <: CompositeComponent
        name::String = "example_composite_component"
        leaf_width = 100nm
        leaf_gap = 10nm
        spacing = 500nm
    end
    SchematicDrivenLayout.hooks(::ExtTestComposite) = (
        origin=PointHook(Point(0nm, 0nm), 0),
    )

    function SchematicDrivenLayout._build_subcomponents(c::ExtTestComposite)
        @component leaf_a = ExtTestLeaf begin
            width = c.leaf_width
            gap = c.leaf_gap
        end
        @component leaf_b = ExtTestLeaf begin
            width = c.leaf_width
        end
        return (leaf_a, leaf_b)
    end

    function SchematicDrivenLayout._graph!(
        g::SchematicGraph,
        ::ExtTestComposite,
        subcomps::NamedTuple
    )
        add_node!(g, subcomps.leaf_a)
        add_node!(g, subcomps.leaf_b)
        return nothing
    end

    SchematicDrivenLayout.map_hooks(::ExtTestComposite) =
        Dict((1 => :origin) => :origin)

    const tdir = mktempdir()
    const save_yaml = get(ENV, "SAVE_YAML", "") == "1"
    const yaml_outdir = joinpath(@__DIR__, "yaml_output")

    function maybe_save_yaml(g::SchematicGraph, name::String)
        save_yaml || return
        mkpath(yaml_outdir)
        outpath = joinpath(yaml_outdir, name * ".yaml")
        parameters_to_yaml(g, outpath)
        @info "Saved YAML to $outpath"
    end
end

@testitem "extract_parameters basics" setup = [ParamExtractionSetup] begin
    g = SchematicGraph("test_extraction")
    leaf = ExtTestLeaf(width=200nm)
    node = add_node!(g, leaf)

    data = extract_parameters(g)

    # Defaults section has the type
    @test haskey(data["defaults"], "ExtTestLeaf")
    defs = data["defaults"]["ExtTestLeaf"]
    @test defs["width"] == string(100nm)
    @test defs["gap"] == string(10nm)

    # Instance only has overrides
    entry = data["components"][node.id]
    @test entry["type"] == "ExtTestLeaf"
    @test entry["parameters"]["width"] == string(200nm)
    @test !haskey(entry["parameters"], "gap")

    maybe_save_yaml(g, "basics")
end

@testitem "extract_parameters composite hierarchy" setup = [ParamExtractionSetup] begin
    g = SchematicGraph("test_composite")
    comp = ExtTestComposite(leaf_width=300nm)
    node = add_node!(g, comp)

    data = extract_parameters(g)

    # Both types should appear in defaults
    @test haskey(data["defaults"], "ExtTestComposite")
    @test haskey(data["defaults"], "ExtTestLeaf")

    # Top-level instance has override
    entry = data["components"][node.id]
    @test entry["type"] == "ExtTestComposite"
    @test entry["parameters"]["leaf_width"] == string(300nm)

    # Subcomponents present
    @test haskey(entry, "subcomponents")
    @test length(entry["subcomponents"]) == 2

    maybe_save_yaml(g, "composite_hierarchy")
end

@testitem "parameters_to_yaml output" setup = [ParamExtractionSetup] begin
    g = SchematicGraph("test_yaml")
    add_node!(g, ExtTestLeaf(width=200nm))
    add_node!(g, ExtTestComposite(leaf_width=300nm, spacing=1000nm))

    buf = IOBuffer()
    parameters_to_yaml(g; io=buf)
    yaml_str = String(take!(buf))

    # Check structure
    @test occursin("components:", yaml_str)
    @test occursin("default_parameters:", yaml_str)

    # Check anchors and merge keys
    @test occursin("&ExtTestLeaf_defaults", yaml_str)
    @test occursin("*ExtTestLeaf_defaults", yaml_str)
    @test occursin("<<: *ExtTestLeaf_defaults", yaml_str)

    # Check type field present
    @test occursin("type: ExtTestLeaf", yaml_str)
    @test occursin("type: ExtTestComposite", yaml_str)

    # Check overrides show up
    @test occursin(string(200nm), yaml_str)
    @test occursin(string(300nm), yaml_str)

    maybe_save_yaml(g, "yaml_output")
end

@testitem "parameters_to_yaml file output" setup = [ParamExtractionSetup] begin
    g = SchematicGraph("test_yaml_file")
    add_node!(g, ExtTestLeaf(width=500nm))

    filepath = joinpath(tdir, "test_params.yaml")
    parameters_to_yaml(g, filepath)

    @test isfile(filepath)
    content = read(filepath, String)
    @test occursin("components:", content)
    @test occursin("default_parameters:", content)

    maybe_save_yaml(g, "file_output")
end
