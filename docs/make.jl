using Documenter, DeviceLayout, FileIO, CoordinateTransformations
DocMeta.setdocmeta!(
    DeviceLayout,
    :DocTestSetup,
    quote
        using Unitful, DeviceLayout
    end;
    recursive=true
)
DocMeta.setdocmeta!(
    DeviceLayout.SchematicDrivenLayout,
    :DocTestSetup,
    quote
        using Unitful, DeviceLayout, .SchematicDrivenLayout
    end;
    recursive=true
)
DocMeta.setdocmeta!(
    CoordinateTransformations,
    :DocTestSetup,
    :(using CoordinateTransformations),
    recursive=true
)

makedocs(
    repo=Documenter.Remotes.GitHub("aws-cqc", "DeviceLayout.jl"),
    modules=[DeviceLayout, CoordinateTransformations, DeviceLayout.SchematicDrivenLayout],
    warnonly=true,
    checkdocs=:none,
    format=Documenter.HTML(prettyurls=true, assets=["assets/favicon.ico"]),
    sitename="DeviceLayout.jl",
    authors="""
  AWS Center for Quantum Computing
  """,
    pages=[
        "Home" => "index.md",
        "Getting Started" => "tutorials/getting_started.md",
        "Tutorials" => [
            "Overview" => "tutorials/index.md",
            "First Layout" => "tutorials/first_layout.md",
            "Working with Paths" => "tutorials/working_with_paths.md",
            "Building a Component" => "tutorials/building_a_component.md",
            "Schematic Basics" => "tutorials/schematic_basics.md",
            "Composite Components" => "tutorials/composite_components.md",
            "Creating a PDK" => "tutorials/creating_a_pdk.md",
            "Simulation Workflow" => "tutorials/simulation_workflow.md"
        ],
        "How-To Guides" => [
            "Overview" => "how_to/index.md",
            "Geometry" => [
                "Create Custom Shapes" => "how_to/geometry/create_custom_shapes.md",
                "Transform and Align" => "how_to/geometry/transform_and_align.md",
                "Boolean Operations" => "how_to/geometry/boolean_operations.md",
                "Work with Units" => "how_to/geometry/work_with_units.md"
            ],
            "Paths" => [
                "Create a CPW" => "how_to/paths/create_cpw.md",
                "Add Tapers" => "how_to/paths/add_tapers.md",
                "Attach to Paths" => "how_to/paths/attach_to_paths.md",
                "Handle Intersections" => "how_to/paths/handle_intersections.md",
                "Create Meanders" => "how_to/paths/create_meanders.md"
            ],
            "Components" => [
                "Define Hooks" => "how_to/components/define_hooks.md",
                "Create Composite" => "how_to/components/create_composite.md",
                "Modify Existing" => "how_to/components/modify_existing.md",
                "Add Mesh Sizing" => "how_to/components/add_mesh_sizing.md"
            ],
            "Schematics" => [
                "Connect Components" => "how_to/schematics/connect_components.md",
                "Routing Strategies" => "how_to/schematics/routing_strategies.md",
                "Add Crossovers" => "how_to/schematics/add_crossovers.md",
                "Autofill Patterns" => "how_to/schematics/autofill_patterns.md"
            ],
            "Output" => [
                "Export to GDS" => "how_to/output/export_gds.md",
                "Generate Solid Models" => "how_to/output/generate_solid_model.md",
                "Create Meshes" => "how_to/output/create_mesh.md",
                "Visualize Layouts" => "how_to/output/visualize_layouts.md"
            ],
            "Debugging" => "how_to/debugging.md"
        ],
        "Concepts" => [
            "Overview" => "concepts/index.md",
            "Entities and Metadata" => "concepts/entities.md",
            "Schematic-Driven Design" => "concepts/schematic_driven_design.md",
            "Components and Hooks" => "concepts/components.md",
            "PDK Architecture" => "concepts/pdk_architecture.md"
        ],
        "Reference" => [
            "Overview" => "reference/index.md",
            "API Reference" => "reference/api.md",
            "Units" => "concepts/units.md",
            "Points" => "concepts/points.md",
            "Geometry" => "concepts/geometry.md",
            "Transformations" => "concepts/transformations.md",
            "Polygons" => "concepts/polygons.md",
            "Coordinate Systems" => "concepts/coordinate_systems.md",
            "Texts" => "concepts/texts.md",
            "Paths" => "concepts/paths.md",
            "Routes" => "concepts/routes.md",
            "Shape Library" => "shapes.md",
            "Autofill" => "concepts/autofill.md",
            "Rendering" => "concepts/render.md",
            "Solid Models" => "solidmodels.md",
            "File Formats" => "fileio.md"
        ],
        "Schematic-Driven Reference" => [
            "Overview" => "schematicdriven/index.md",
            "Components" => "schematicdriven/components.md",
            "Hooks" => "schematicdriven/hooks.md",
            "Schematics" => "schematicdriven/schematics.md",
            "Technologies" => "schematicdriven/technologies.md",
            "Targets" => "schematicdriven/targets.md",
            "Solid Models" => "schematicdriven/solidmodels.md",
            "PDKs" => "schematicdriven/pdks.md",
            "Troubleshooting/FAQ" => "schematicdriven/faq.md"
        ],
        "Examples" => [
            "ExamplePDK" => "examples/examplepdk.md",
            "Quantum Processor" => "examples/qpu17.md",
            "Single-Transmon Simulation" => "examples/singletransmon.md"
        ],
        "Developer Guide" => "developer/index.md",
        "FAQ" => "faq.md"
    ]
)

deploydocs(
    repo="https://github.com/aws-cqc/DeviceLayout.jl",
    devbranch="main",
    push_preview=true,
    forcepush=true
)
