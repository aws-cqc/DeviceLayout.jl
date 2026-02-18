# [Tutorials](@id tutorials-index)

These tutorials are designed to help you learn DeviceLayout.jl progressively, building from basic concepts to advanced workflows.

## Tutorial Overview

Each tutorial builds on the previous one. We recommend following them in order if you're new to DeviceLayout.jl.

| Tutorial | Description | Time |
|----------|-------------|------|
| [First Layout: Vernier Scale](first_layout.md) | Basic shapes, cells, and rendering | ~15 min |
| [Working with Paths: CPW Resonator](working_with_paths.md) | Path segments, styles, and decorations | ~20 min |
| [Building a Component: Interdigital Capacitor](building_a_component.md) | Reusable, parameterized geometry | ~30 min |
| [Schematic Basics](schematic_basics.md) | Introduction to schematic-driven layout | ~25 min |
| [Creating a PDK](creating_a_pdk.md) | Build a simple process design kit | ~30 min |
| [Simulation Workflow](simulation_workflow.md) | From layout to electromagnetic simulation | ~45 min |

## Prerequisites

These tutorials assume you have:

- [Installed DeviceLayout.jl](../getting_started/installation.md)
- [Set up your development environment](../getting_started/workflow_setup.md)
- Basic familiarity with Julia syntax

## Learning Paths

Depending on your goals, you might take different paths through the tutorials:

### Quick Prototyping
If you need to create simple layouts quickly:
1. [First Layout](first_layout.md)
2. [Working with Paths](working_with_paths.md)
3. Jump to [How-To Guides](@ref how-to-index)

### Device Design
If you're designing quantum devices:
1. Complete all tutorials in order
2. Study the [QPU17 Example](../examples/qpu17.md)
3. Read [Schematic-Driven Design Concepts](@ref schematic-driven-design)

### PDK Development
If you're building components for your team:
1. [First Layout](first_layout.md)
2. [Building a Component](building_a_component.md)
3. [Creating a PDK](creating_a_pdk.md)
4. Read [PDK Architecture](@ref pdk-architecture)

### Simulation
If you're preparing layouts for simulation:
1. Complete basic tutorials (1-4)
2. [Simulation Workflow](simulation_workflow.md)
3. Study the [SingleTransmon Example](../examples/singletransmon.md)

## Getting Help

If you get stuck:

- Check the [FAQ](../faq.md) for common questions
- Browse [How-To Guides](@ref how-to-index) for specific tasks
- Look up functions in the [Reference](@ref reference-index)

```@contents
Pages = [
    "first_layout.md",
    "working_with_paths.md",
    "building_a_component.md",
    "schematic_basics.md",
    "creating_a_pdk.md",
    "simulation_workflow.md"
]
Depth = 2
```
