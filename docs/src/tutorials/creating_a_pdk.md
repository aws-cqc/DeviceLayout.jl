# Tutorial: Creating a PDK

A Process Design Kit (PDK) packages reusable components, layer definitions, and rendering configurations for a specific fabrication process. This tutorial shows how to create a PDK using DeviceLayout's scaffolding tools.

## What You'll Learn

- Generating a PDK package with `generate_pdk`
- Defining a layer vocabulary
- Configuring a process technology and rendering targets
- Generating a component package with `generate_component_package`
- Implementing a component within the PDK
- Using the PDK to build and render a schematic

## Prerequisites

- Completed [Schematic Basics](schematic_basics.md) tutorial
- Understanding of components and schematics

## What is a PDK?

A PDK provides:

1. **Layer vocabulary**: Named layers with semantic meaning (`:metal_negative`, `:junction`, etc.)
2. **Process technology**: How layers map to physical fabrication parameters
3. **Rendering targets**: Configurations for different outputs (artwork GDS, 3D simulation model)
4. **Components**: Reusable building blocks designed for the process

## Step 1: Generate the PDK Package

DeviceLayout provides [`generate_pdk`](@ref) to scaffold a new PDK with the correct structure and conventions:

```julia
using DeviceLayout.SchematicDrivenLayout

generate_pdk("MyPDK") # You may also need `user="<username>"` for Git
```

This creates a Julia package with the following structure:

```
MyPDK/
├── Project.toml            # Package metadata (DeviceLayout dependency added automatically)
├── src/
│   └── MyPDK.jl            # Main module with template code
├── docs/                   # Documenter.jl setup
├── test/
│   └── runtests.jl
└── components/             # Directory for component packages (created empty)
```

Open `MyPDK/src/MyPDK.jl` — you'll see the generated template:

```julia
module MyPDK

using DeviceLayout, .SchematicDrivenLayout, .PreferredUnits

const COMPONENTS_DIR = joinpath(dirname(@__DIR__), "components")

##### Layers
const LAYER_RECORD = (;
    # layer_name = GDSMeta(gdslayer, datatype),
    # ...
)

module LayerVocabulary
# Automatically generates `const LAYER_NAME = SemanticMeta(:layer_name)` for each key in LAYER_RECORD
import ..MyPDK: LAYER_RECORD, SemanticMeta
# ... (metaprogramming loop)
end

##### Process technologies
const MY_PROCESS_TECHNOLOGY = ProcessTechnology(
    LAYER_RECORD,
    (; # Technology parameters
    )
)

##### Rendering targets
const MY_ARTWORK_TARGET = ArtworkTarget(MY_PROCESS_TECHNOLOGY)

const MY_SOLIDMODEL_TARGET = SolidModelTarget(
    MY_PROCESS_TECHNOLOGY;
    simulation=true,
    # bounding_layers = [...],
    # substrate_layers = [...],
    # postrender_ops = [...],
)

end # module
```

The template handles the boilerplate — module structure, imports, and the `LayerVocabulary` metaprogramming that auto-generates constants from your layer record. Your job is to fill in the content: layers, technology parameters, and target options.

## Step 2: Define Your Layers

Edit the `LAYER_RECORD` in `MyPDK/src/MyPDK.jl`. Each entry maps a semantic layer name to a GDS layer/datatype pair:

```julia
const LAYER_RECORD = (;
    metal_negative   = GDSMeta(0, 0),
    metal_positive   = GDSMeta(1, 0),
    junction         = GDSMeta(2, 0),
    junction_bandage = GDSMeta(3, 0),
    bridge_base      = GDSMeta(10, 0),
    bridge           = GDSMeta(11, 0),
    chip_area        = GDSMeta(100, 0),
    writeable_area   = GDSMeta(101, 0),
    simulated_area   = GDSMeta(102, 0),
)
```

The `LayerVocabulary` module (already generated) will automatically create constants like `METAL_NEGATIVE = SemanticMeta(:metal_negative)` for each entry. Components use these constants to place geometry on the right layer without hard-coding GDS numbers.

## Step 3: Configure the Process Technology

The [`ProcessTechnology`](@ref) holds your layer record plus physical parameters that describe how layers relate to fabrication. The key parameters are `height` (z-position of each layer's bottom face) and `thickness` (extrusion height for 3D modeling):

```julia
const MY_PROCESS_TECHNOLOGY = ProcessTechnology(
    LAYER_RECORD,
    (;
        height = (;
            simulated_area = -1000μm,
        ),
        thickness = (;
            chip_area      = 525μm,    # Substrate thickness
            simulated_area = 2000μm,   # Simulation box height
        ),
    )
)
```

These parameters are accessed by rendering targets during 3D model generation via [`layer_height`](@ref) and [`layer_thickness`](@ref). Layers not listed default to zero height and thickness.

## Step 4: Set Up Rendering Targets

Targets configure how a schematic renders to different outputs. The template provides two:

### Artwork Target

[`ArtworkTarget`](@ref) renders to GDS polygons for mask fabrication. For a single-chip PDK, set `levels=[1]` (the default `[1, 2]` is for flipchip stacks):

```julia
const MY_ARTWORK_TARGET = ArtworkTarget(MY_PROCESS_TECHNOLOGY; levels=[1])
```

### Solid Model Target

[`SolidModelTarget`](@ref) renders to a 3D model for electromagnetic simulation. Uncomment and fill in the options:

```julia
const MY_SOLIDMODEL_TARGET = SolidModelTarget(
    MY_PROCESS_TECHNOLOGY;
    simulation       = true,
    bounding_layers  = [:simulated_area],
    substrate_layers = [:chip_area],
    postrender_ops   = [
        (   # Subtract negative from writeable area to get metal
            "metal",
            SolidModels.difference_geom!,
            ("writeable_area", "metal_negative", 2, 2),
            :remove_object => true
        ),
        (   # Add any positive metal back
            "metal",
            SolidModels.union_geom!,
            ("metal", "metal_positive", 2, 2),
            :remove_tool => true
        ),
    ]
)
```

The `simulation=true` option controls which geometry is included: entities decorated with [`only_simulated`](@ref) or [`not_simulated`](@ref) styles are filtered based on this flag. The `postrender_ops` define boolean operations that combine layers into final 3D volumes.

## Step 5: Generate a Component Package

With the PDK structure in place, activate the package and generate a component:

```julia
using Pkg
Pkg.activate("MyPDK")
using DeviceLayout.SchematicDrivenLayout
using MyPDK

generate_component_package("MyCapacitors", MyPDK, "MyCapacitor")
```

This creates a new package inside `MyPDK/components/`:

```
MyPDK/components/MyCapacitors/
├── Project.toml
├── src/
│   └── MyCapacitors.jl     # Module with component template
├── docs/
│   └── src/index.md        # Documentation template with example skeleton
└── test/
    └── runtests.jl
```

The generated `MyCapacitors.jl` contains a stub `@compdef struct` with placeholder methods for `_geometry!` and `hooks` — the same interface you learned in the [Building a Component](building_a_component.md) tutorial.

## Step 6: Implement the Component

Open `MyPDK/components/MyCapacitors/src/MyCapacitors.jl` and fill in the component definition with your capacitor from the [Building a Component](building_a_component.md) tutorial:

```julia
module MyCapacitors

using DeviceLayout, .SchematicDrivenLayout, .PreferredUnits
using MyPDK, MyPDK.LayerVocabulary

export MyCapacitor

"""
    MyCapacitor <: Component

A simple interdigitated capacitor with two terminals (positive pattern).

# Parameters
- `name`: Component name
- `finger_length`: Length of each finger
- `finger_width`: Width of each finger
- `finger_gap`: Gap between fingers
- `finger_count`: Number of finger pairs
- `rounding`: Rounding radius for metal corners

# Hooks
- `p0`: Left terminal
- `p1`: Right terminal
"""
@compdef struct MyCapacitor <: Component
    name = "capacitor"
    finger_length = 100μm
    finger_width = 5μm
    finger_gap = 3μm
    finger_count::Int = 4
    rounding = 1μm
end

function SchematicDrivenLayout._geometry!(cs::CoordinateSystem, cap::MyCapacitor)
    (; finger_length, finger_width, finger_gap, finger_count, rounding) = cap
    
    # Calculate dimensions
    pitch = finger_width + finger_gap
    total_height = finger_count * pitch
    
    # Create the two bus bars
    left_bus = Rectangle(finger_width, total_height)
    right_bus = Translation(finger_length + finger_gap + finger_width, 0nm)(
        Rectangle(finger_width, total_height)
    )

    finger_rect = Align.rightof(Rectangle(finger_length, finger_width), left_bus)
    left_fingers = [
        Align.flushbottom(
            finger_rect, left_bus, offset = (i - 1) * pitch
        ) for i in 1:2:finger_count
        ]
    finger_rect = Align.leftof(Rectangle(finger_length, finger_width), right_bus)
    right_fingers = [
        Align.flushbottom(
            finger_rect, left_bus, offset = (i - 1) * pitch
        ) for i in 2:2:finger_count
        ]

    # Take union before rounding
    all_metal = union2d([left_fingers; right_fingers], [left_bus, right_bus])
    # Apply rounding
    rounded_metal = Rounded(all_metal, rounding) # Creates a StyledEntity
    # Place in the geometry
    place!(cs, rounded_metal, METAL_POSITIVE)
    
    return cs
end

function SchematicDrivenLayout.hooks(cap::MyCapacitor)
    (; finger_length, finger_width, finger_gap, finger_count) = cap

    # Calculate dimensions
    pitch = finger_width + finger_gap
    total_height = finger_count * pitch
    center_y = total_height / 2
    total_width = finger_length + finger_gap + 2*finger_width
    
    # Left hook: pointing right (+x direction, 0°)
    p0 = PointHook(Point(0nm, center_y), 0°)
    
    # Right hook: pointing right (-x direction, 180°)
    p1 = PointHook(Point(total_width, center_y), 180°)
    
    # Return NamedTuple with names p0 and p1 
    return (; p0, p1) # (equivalent to (; p0 = p0, p1 = p1))
end

end # module
```

There is **one important change** from the previous tutorial: instead of placing `rounded_metal` in the `SemanticMeta(:metal)` layer, the component uses `METAL_POSITIVE` from `MyPDK.LayerVocabulary` — the constants auto-generated from your `LAYER_RECORD`. This is the connection between your layer definitions and your component geometry.

## Step 7: Use Your PDK

With the PDK and component defined, create a new project in a sibling directory `MyPDK/../MyDesign`, add the PDK and component packages as dependencies, and use them in a design:

```julia
# In a script or REPL in a sibling directory
using Pkg
Pkg.activate(".")
Pkg.add("DeviceLayout")
Pkg.add("FileIO")
Pkg.develop(path="../MyPDK")
Pkg.develop(path="../MyPDK/components/MyCapacitors")
```

```julia
using DeviceLayout, DeviceLayout.PreferredUnits
using DeviceLayout.SchematicDrivenLayout
using MyPDK, MyCapacitors
using FileIO

# Build a schematic
g = SchematicGraph("my_device")
cap = add_node!(g, MyCapacitor(finger_length=150μm))

# Plan, check, and render
sch = plan(g; log_dir=nothing)
check!(sch)

cell = Cell("output")
render!(cell, sch, MyPDK.MY_ARTWORK_TARGET)
save("output.gds", cell)
```

The `plan` → `check!` → `render!` sequence is the standard workflow: `plan` resolves the schematic graph into placed geometry, `check!` validates constraints (required before rendering), and `render!` converts semantic geometry into GDS polygons using the target's layer mapping (in this case, `metal_positive = GDSMeta(1, 0)`).

## Best Practices

### Version Your PDK and Components

Use [semantic versioning](https://semver.org/) in `Project.toml`. DeviceLayout is added as a dependency automatically by `generate_pdk`, with a compatibility bound on the current major version.

### Separate Component Packages

`generate_component_package` creates each component family as its own package inside `components/`. This lets teams version and release component libraries independently from the core PDK. For example:

```
MyPDK/components/
├── MyCapacitors/
├── MyTransmons/
└── MyResonators/
```

### Document Components

The generated `docs/` directory in each component package includes a documentation skeleton with an example block that renders the component. Fill in docstrings for parameters and hooks so that `@autodocs` picks them up.

### Custom Templates

PDKs can override the default component templates. Place custom `.jlt` files in `MyPDK/templates/` and they'll be used instead of the built-in ones when calling `generate_component_package` against your PDK.

## Summary

In this tutorial, you learned:

- **`generate_pdk`**: Scaffolds a PDK package with correct structure and conventions
- **Layer vocabulary**: Defined in `LAYER_RECORD`, auto-generates `SemanticMeta` constants
- **Process technology**: Physical parameters (`height`, `thickness`) for layer-to-fabrication mapping
- **Rendering targets**: `ArtworkTarget` for GDS, `SolidModelTarget` for 3D simulation
- **`generate_component_package`**: Scaffolds component packages within the PDK
- **Component implementation**: `_geometry!` and `hooks` using PDK layer constants

## Next Steps

Continue to [Simulation Workflow](simulation_workflow.md) to learn how to generate 3D models and meshes for electromagnetic simulation from your PDK targets.

## See Also

- [PDK Architecture](@ref pdk-architecture) for deeper understanding of the PDK system
- [ExamplePDK source](https://github.com/aws-cqc/DeviceLayout.jl/tree/main/ExamplePDK) for a complete reference implementation
- [Composite Components](composite_components.md) to build components from subcomponents
