using Documenter, DeviceLayout, FileIO, CoordinateTransformations, .SchematicDrivenLayout
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
    format=Documenter.HTML(
        prettyurls=true,
        assets=["assets/favicon.ico"],
        size_threshold=300_000,
        collapselevel=1
    ),
    sitename="DeviceLayout.jl",
    authors="""
  AWS Center for Quantum Computing
  """,
    pages=[
        "Home" => "index.md",
        "Getting Started" => "how_to/get_started.md",
        "Tutorials" => [
            "Overview" => "tutorials/index.md",
            "First Layout" => "tutorials/first_layout.md",
            "Working with Paths" => "tutorials/working_with_paths.md",
            "Building a Component" => "tutorials/building_a_component.md",
            "Schematic Basics" => "tutorials/schematic_basics.md",
            "Composite Components" => "tutorials/composite_components.md",
            "Creating a PDK" => "tutorials/creating_a_pdk.md"
        ],
        "Concepts" => [
            "Overview" => "concepts/index.md",
            "Units" => "concepts/units.md",
            "Points" => "concepts/points.md",
            "Geometry" => "concepts/geometry.md",
            "Transformations" => "concepts/transformations.md",
            "Polygons" => "concepts/polygons.md",
            "Coordinate Systems" => "concepts/coordinate_systems.md",
            "Texts" => "concepts/texts.md",
            "Paths" => "concepts/paths.md",
            "Routes" => "concepts/routes.md",
            "Rendering and Export" => "concepts/render.md",
            "Solid Models (3D Geometry)" => "concepts/solidmodels.md",
            "Schematic-Driven Design" => "concepts/schematic_driven_design.md",
            "Components" => "concepts/components.md",
            "Autofill" => "concepts/autofill.md",
            "PDKs" => "concepts/pdks.md",
            "Style Guide" => "concepts/styleguide.md"
        ],
        "Examples" => [
            "ExamplePDK" => "examples/examplepdk.md",
            "Quantum Processor" => "examples/qpu17.md",
            "Single-Transmon Simulation" => "examples/singletransmon.md"
        ],
        "Reference" => [
            "Overview" => "reference/index.md",
            "Geometry API Reference" => "reference/api.md",
            "Path API Reference" => "reference/path_api.md",
            "Schematic API Reference" => "reference/schematic_api.md",
            "Shape Reference" => "reference/shapes.md"
        ],
        "FAQ/Troubleshooting" => "how_to/faq.md"
    ]
)

deploydocs(
    repo="https://github.com/aws-cqc/DeviceLayout.jl",
    devbranch="main",
    push_preview=true,
    forcepush=true
)
