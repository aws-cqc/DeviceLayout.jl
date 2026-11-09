@testitem "ExamplePDK" setup = [CommonTestSetup] begin
    include("../examples/DemoQPU17/DemoQPU17.jl")
    logger = TestLogger()
    schematic, artwork = quiet_test_output() do
        with_logger(logger) do
            return DemoQPU17.qpu17_demo(dir=tdir)
        end
    end
    @test all(logger.logs) do log
        return log.level < Logging.Warn
    end
    # Check for changes to geometry
    # Mainly for flagging unintentional changes, so doesn't need to run on every version
    fingerprint = Cells.geometry_fingerprint(artwork)
    expected = "a80f5676a8dbad9f535c669356cffb92cc5f20630262887947ef905af0d9e896"
    @test fingerprint == expected
    fingerprint != expected && println("""
        Expected QPU17 artwork fingerprint: $expected
        Found: $fingerprint
        If rendering changes were intentional, update the expected fingerprint.
    """)
    # Check target constructor
    fc_target = SchematicDrivenLayout.ExamplePDK.flipchip_solidmodel_target([
        "port_1",
        "port_2",
        "lumped_element"
    ])

    @test ("port_1", 2) in fc_target.retained_physical_groups
    @test ("port_2", 2) in fc_target.rendering_options.retained_physical_groups # Backwards compatibility
end

@testitem "Single Transmon (experimental)" setup = [CommonTestSetup, QuietGmshSetup] begin
    import JSON
    using JSONSchema
    include("../examples/SingleTransmon/SingleTransmonExperimental.jl")
    schema = Schema(
        JSON.parsefile(joinpath(@__DIR__, "..", "schemas", "sm_metadata.schema.json"))
    )
    no_warnings = log -> log.level < Logging.Warn

    floorplan, sm, metadata_path = with_test_logger(no_warnings) do
        return SingleTransmonExperimental.single_transmon(;
            save_mesh=true,
            mesh_order=1,
            dir=tdir
        )
    end
    metadata = JSON.parsefile(metadata_path)
    @test isvalid(schema, metadata)

    layer_entities(name) =
        sum(metadata["layers"][name]["pgs"]) do pg_name
            return length(
                SolidModels.entitytags(sm[pg_name, metadata["layers"][name]["dim"]])
            )
        end
    # 3*4 sides of chip and vacuum boxes + top + bottom
    @test layer_entities("exterior_boundary") == 14
    @test layer_entities("vacuum") == 2
    @test layer_entities("substrate") == 1
    @test layer_entities("lumped_element") == 1
    @test layer_entities("port") == 2
    # Ground, island, and transmission line
    @test sort([only(t["locators"]) for t in values(metadata["terminals"])]) == ["p_ro.feedline", "qubit.island"]
    @test length(metadata["ground"]) == 1
    @test Set(keys(metadata["ports"])) ==
          Set(["p_ro.port_1", "p_ro.port_2", "qubit.junction"])

    config = SingleTransmonExperimental.configfile(metadata_path)
    boundaries = config["Boundaries"]
    port_attributes = [only(p["Attributes"]) for p in boundaries["LumpedPort"]]
    @test allunique(port_attributes)
    @test [p["Direction"] for p in boundaries["LumpedPort"]] == [[1.0, 0.0, 0.0], [-1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]

    @testset "Palace mesh boundary attributes" begin
        # Save the generated mesh again as text, to parse it.
        gmsh = SolidModels.gmsh
        mesh_path = joinpath(tdir, "single_transmon_experimental.msh2")
        original_binary = gmsh.option.get_number("Mesh.Binary")
        try
            gmsh.option.set_number("Mesh.Binary", 0)
            save(mesh_path, sm)
        finally
            gmsh.option.set_number("Mesh.Binary", original_binary)
        end

        # MSH2 writes a boundary element for each physical group containing a surface.
        # Palace requires a single boundary record per non-periodic face.
        mesh_lines = readlines(mesh_path)
        elements_start = findfirst(==("\$Elements"), mesh_lines)
        element_count = parse(Int, mesh_lines[elements_start + 1])
        boundary_faces = NTuple{3, Int}[]
        boundary_attributes = Set{Int}()
        volume_elements = 0
        for line in mesh_lines[(elements_start + 2):(elements_start + 1 + element_count)]
            fields = parse.(Int, split(line))
            if fields[2] == 2 # Linear triangles
                num_tags = fields[3]
                push!(boundary_faces, Tuple(sort(fields[(num_tags + 4):(num_tags + 6)])))
                push!(boundary_attributes, fields[4])
            elseif fields[2] == 4 # Linear tetrahedra
                volume_elements += 1
            end
        end
        @test volume_elements > 0
        @test allunique(boundary_faces)
        @test boundary_attributes == Set([
            boundaries["PEC"]["Attributes"]...,
            boundaries["Absorbing"]["Attributes"]...,
            port_attributes...
        ])
    end

    @testset "Wave ports" begin
        _, wave_sm, wave_metadata_path = with_test_logger(no_warnings) do
            return SingleTransmonExperimental.single_transmon(; wave_ports=true, dir=tdir)
        end
        wave_metadata = JSON.parsefile(wave_metadata_path)
        @test isvalid(schema, wave_metadata)
        @test Set(keys(wave_metadata["ports"])) ==
              Set(["qubit.junction", "p_ro_wave_port_1", "p_ro_wave_port_2"])
        # Each patch is split where the substrate surface meets it
        for name in ("p_ro_wave_port_1", "p_ro_wave_port_2")
            @test sum(wave_metadata["ports"][name]["pgs"]) do pg_name
                return length(SolidModels.entitytags(wave_sm[pg_name, 2]))
            end == 2
        end
        wave_config = SingleTransmonExperimental.configfile(wave_metadata_path)
        wave_attributes = [
            only(p["Attributes"]) for p in [
                wave_config["Boundaries"]["WavePort"]
                wave_config["Boundaries"]["LumpedPort"]
            ]
        ]
        @test allunique(wave_attributes)
    end
end

@testitem "Single Transmon example schematic" setup = [CommonTestSetup, QuietGmshSetup] begin
    # Unlike the rest of the example, `schematic.jl` depends only on DeviceLayout, so it can be
    # tested here; the SolidModel benchmarks also include it
    using .SchematicDrivenLayout
    include("../examples/SingleTransmon/schematic.jl")

    # Components used by the schematic
    q = ExampleRectangleTransmon()
    rr = ExampleClawedMeanderReadout()
    @test geometry(q) isa CoordinateSystem{typeof(1.0DeviceLayout.nm)}
    @test geometry(rr) isa CoordinateSystem{typeof(1.0DeviceLayout.nm)}
    @test issubset([:readout, :xy, :z], keys(hooks(q)))
    @test abs(hooks(rr).qubit.p.y - hooks(rr).feedline.p.y) ≈ rr.total_y_length

    no_warnings = log -> log.level < Logging.Warn
    floorplan, target = with_test_logger(no_warnings) do
        return single_transmon_schematic(; log_dir=nothing)
    end
    sm = SolidModel("single_transmon_schematic", overwrite=true)
    with_test_logger(no_warnings) do
        return render!(sm, floorplan, target)
    end
    # 3*4 sides of chip and vacuum boxes + top + bottom = 14
    @test length(SolidModels.dimtags(sm["exterior_boundary", 2])) == 14
    @test length(SolidModels.dimtags(sm["metal", 2])) == 19
    @test length(SolidModels.dimtags(sm["vacuum", 3])) == 2
    @test length(SolidModels.dimtags(sm["substrate", 3])) == 1
    @test length(SolidModels.dimtags(sm["port_1", 2])) == 1
    @test length(SolidModels.dimtags(sm["port_2", 2])) == 1
    @test length(SolidModels.dimtags(sm["lumped_element", 2])) == 1
    metal_conn_comps = SolidModels.connected_components(sm, "metal")
    active_conn_comps = SolidModels.connected_components(
        sm,
        ["metal", "lumped_element", "port_1", "port_2"]
    )
    @test length(metal_conn_comps) == 3  # Transmission line, island, ground
    @test length(active_conn_comps) == 1 # Ports and lumped elements connect metal components

    @testset "Palace mesh boundary attributes" begin
        gmsh = SolidModels.gmsh
        mesh_path = joinpath(tdir, "single_transmon_schematic.msh2")
        option_names = ("Mesh.Binary", "Mesh.ElementOrder")
        original_options = gmsh.option.get_number.(option_names)
        try
            gmsh.option.set_number("Mesh.Binary", 0)
            gmsh.option.set_number("Mesh.ElementOrder", 2)
            gmsh.model.mesh.generate(3)
            save(mesh_path, sm)
        finally
            for (option, value) in zip(option_names, original_options)
                gmsh.option.set_number(option, value)
            end
        end

        # MSH2 writes a boundary element for each physical group containing a surface.
        # Palace requires a single boundary record per non-periodic face.
        mesh_lines = readlines(mesh_path)
        elements_start = findfirst(==("\$Elements"), mesh_lines)
        element_count = parse(Int, mesh_lines[elements_start + 1])
        boundary_faces = NTuple{3, Int}[]
        boundary_attributes = Set{Int}()
        volume_elements = 0
        for line in mesh_lines[(elements_start + 2):(elements_start + 1 + element_count)]
            fields = parse.(Int, split(line))
            if fields[2] in (2, 9) # Linear and quadratic triangles
                num_tags = fields[3]
                push!(boundary_faces, Tuple(sort(fields[(num_tags + 4):(num_tags + 6)])))
                push!(boundary_attributes, fields[4])
            elseif fields[2] in (4, 11) # Linear and quadratic tetrahedra
                volume_elements += 1
            end
        end
        attributes = SolidModels.attributes(sm)
        expected_boundaries =
            ("exterior_boundary", "metal", "lumped_element", "port_1", "port_2")
        @test volume_elements > 0
        @test !isempty(boundary_faces)
        @test allunique(boundary_faces)
        @test boundary_attributes == Set(attributes[name] for name in expected_boundaries)
    end

    # Assign to new groups
    metal_comp_tags = []
    for i in eachindex(metal_conn_comps)
        sm["metal_island_$i"] = metal_conn_comps[i]
        push!(metal_comp_tags, SolidModels.entitytags(sm["metal_island_$i", 2]))
    end
    sort!(metal_comp_tags, by=length)
    @test length(metal_comp_tags[1]) == 1 # Transmission line
    @test length(metal_comp_tags[2]) == 2 # Transmon island
    @test length(metal_comp_tags[3]) == 16 # Ground
end
