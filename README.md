# DeviceLayout.jl

[![](https://img.shields.io/badge/docs-stable-blue.svg)](https://aws-cqc.github.io/DeviceLayout.jl/stable)
[![](https://img.shields.io/badge/docs-dev-blue.svg)](https://aws-cqc.github.io/DeviceLayout.jl/dev)
[![CI](https://github.com/aws-cqc/DeviceLayout.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/aws-cqc/DeviceLayout.jl/actions/workflows/CI.yml)
[![Aqua](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![codecov](https://codecov.io/gh/aws-cqc/DeviceLayout.jl/graph/badge.svg?token=D3EQ7I4LP0)](https://codecov.io/gh/aws-cqc/DeviceLayout.jl)

DeviceLayout.jl is a [Julia](http://julialang.org) package for computer-aided design (CAD) of quantum integrated circuits, developed at the AWS Center for Quantum Computing. The package supports 

- **2D layout generation** for fabrication (GDSII export)
- **3D model generation** for electromagnetic simulation
- **Schematic-driven design** for managing complex devices with many components

## Why DeviceLayout.jl?

We develop DeviceLayout.jl to accelerate design cycles as we scale to larger quantum processors and larger teams. Key features include:

- **Rich geometry types** with first-class support for paths
- **Schematic-driven layout**: Manage complexity by separating component geometry and device connectivity
- **3D modeling and meshing** (via [Open CASCADE Technology](https://dev.opencascade.org/) and [Gmsh](https://gmsh.info/)) using rich geometry and schematic information to improve meshing and configure simulations
- **Developed alongside [*Palace*](https://awslabs.github.io/palace/stable/)**, an open-source tool for electromagnetic finite-element analysis
- **Built-in support** for common elements of superconducting quantum processors like coplanar waveguides, air bridges, and flip-chip assemblies
- **Explicit unit support** without sacrificing performance
- **The Julia ecosystem**: Users write code in Julia, a scientific programming language combining high performance and ease of use
- **Package management**: The [Julia package manager](https://pkgdocs.julialang.org/v1/) offers portability and reproducibility for design projects
- **PDK support**: Teams can manage their own process design kit as a set of Julia packages in a private registry

## Installation

DeviceLayout.jl requires Julia v1.10 or later. You can follow [these instructions](https://julialang.org/install/) to install Julia.

From Julia, install DeviceLayout.jl using the built-in package manager, [Pkg.jl](https://pkgdocs.julialang.org/v1/getting-started/):

```bash
julia> ] # Pressing ] in the Julia REPL activates the Pkg REPL mode
pkg> activate . # Activates an environment in the current directory
pkg> add DeviceLayout # Adds DeviceLayout.jl to the environment
pkg> add FileIO # You'll want FileIO too, to save output files
```

We recommend [using an environment for each project](https://julialang.github.io/Pkg.jl/v1/environments/) rather than installing packages in the default environment. This ensures reproducibility and avoids version conflicts.

### Hello World

```julia
using DeviceLayout, DeviceLayout.PreferredUnits
using FileIO

# Create a cell
cell = Cell("hello", nm)

# Add a rectangle
render!(cell, centered(Rectangle(100μm, 50μm)), GDSMeta(0))

# Save to GDS
save("hello.gds", cell)
```

See [Getting Started](https://aws-cqc.github.io/DeviceLayout.jl/stable/how_to/get_started.md) for a more complete introduction, including workflow setup. There's one especially important tip for users new to Julia: Julia has a just-in-time compiler, so the first execution of code takes longer due to compilation. Subsequent runs in the same session are much faster. To take advantage of this, don't run scripts from the command line each time. Instead, use functions defined in files, and `include` those files in a persistent REPL session.

To explore what you can build with DeviceLayout, see our examples with full walkthroughs in the documentation, including a [17-qubit quantum processor](https://aws-cqc.github.io/DeviceLayout.jl/stable/examples/qpu17/) and [simulation of a transmon and resonator with Palace](https://aws-cqc.github.io/DeviceLayout.jl/stable/examples/singletransmon/).
