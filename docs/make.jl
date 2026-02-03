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
    warnonly=false,
    checkdocs=:none,
    format=Documenter.HTML(prettyurls=true, assets=["assets/favicon.ico"]),
    sitename="DeviceLayout.jl",
    authors="""
  AWS Center for Quantum Computing
  """,
    pages=[
        "Home" => "index.md",
        "Geometry-Level Layout" => [
            "Overview" => "geometrylevel.md",
            "Units" => "units.md",
            "Points" => "points.md",
            "Geometry" => "geometry.md",
            "Transformations" => "transformations.md",
            "Entity Styles" => "entitystyles.md",
            "Polygons" => "polygons.md",
            "Coordinate Systems" => "coordinate_systems.md",
            "Texts" => "texts.md",
            "Paths" => "paths.md",
            "Routes" => "routes.md",
            "Shape library" => "shapes.md",
            "Autofill" => "autofill.md",
            "Rendering" => "render.md",
            "Solid Models (3D Geometry)" => "solidmodels.md",
            "File Formats" => "fileio.md",
            "Troubleshooting/FAQ" => "faq.md"
        ],
        "Schematic-Driven Layout" => [
            "Overview" => "schematicdriven/index.md",
            "Components" => "schematicdriven/components.md",
            "Hooks" => "schematicdriven/hooks.md",
            "Schematics" => "schematicdriven/schematics.md",
            "Technologies" => "schematicdriven/technologies.md",
            "Targets" => "schematicdriven/targets.md",
            "Solid Models" => "schematicdriven/solidmodels.md",
            "PDKs" => "schematicdriven/pdks.md",
            "Style Guide" => "schematicdriven/styleguide.md",
            "Troubleshooting/FAQ" => "schematicdriven/faq.md"
        ],
        "Examples" => [
            "ExamplePDK" => "examples/examplepdk.md",
            "Quantum Processor" => "examples/qpu17.md",
            "Single-Transmon Simulation" => "examples/singletransmon.md"
        ]
    ]
)

deploydocs(
    repo="https://github.com/aws-cqc/DeviceLayout.jl",
    devbranch="main",
    push_preview=true,
    forcepush=true
)
