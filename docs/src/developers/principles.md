# [Design Principles](@id dev-principles)

Development of DeviceLayout.jl is guided by a few principles. They are the tie-breakers when a
design decision isn't obvious, and they're the standard reviewers will hold a change to.

1. **Target the design cycle:** Prioritize the time designers spend getting from one design to
   the next. Provide designers with the right abstractions and precise feedback for fast
   iteration. Raw performance improvements are valuable when they relieve bottlenecks in a
   feedback cycle.

2. **Rigorously pursue correctness:** Outputs that can't be trusted without manual review are
   obstacles to automation and scaling. Specify contracts precisely, test thoroughly, and
   provide tools for designers to verify and validate results where correctness can't be
   mechanically guaranteed. Warn loudly when designers should know results may not be as
   expected, and sparingly otherwise. Fail rather than guess.

3. **Capture and transmit design intent:** Take what designers know about the device and carry
   it from their input to the final output artifacts. Hold on to the mapping between
   schematic and geometry levels for as long as possible, and preserve exact geometry with
   semantic metadata for as long as possible. Don't rely on extracting meaning from raw polygons except
   for validation of what the schematic already knows.

4. **One language for both exploration and scaling:** Going from concept to first simulation is a
   different workflow from integrating that concept into a large-scale device. Both should be
   easy, and both should use the same tools, supporting a fast, faithful path from prototype
   to integration at scale.

5. **Separate physics and geometry:** Layout abstractions own geometry, connectivity, and parameters.
   Physical quantities and models (frequencies, impedances, Hamiltonians) live in PDK or design code
   that maps onto components, not inside them. So: a hook is an attachment point, not necessarily a
   port; a parameter is a geometry control knob, not a device property; one component may be simulated
   in several ways, or not at all.

6. **Design projects are software projects:** Documentation, library architecture, and APIs
   promote high-quality user code and software-engineering best practices.
   Reproducibility is a first-class concern. Anticipate many designers collaborating on different
   parts of the same design or on related designs, and define abstractions and interfaces to
   allow modular contributions.

7. **A process-agnostic core:** The core schematic workflow and layout engine don't encode layer
   numbers, material stacks, or fabrication methods. Those belong to PDKs; the core sees them
   only as rendering directives. Designers don't define a different component for each new
   experimental fabrication process.

## How the principles shape the architecture

Many questions about why the package is the way it is are answered by principles 3, 5, and 7:
"Capture and transmit design intent", "Separate physics and geometry", and "A process-agnostic core."

A typical user of DeviceLayout.jl is working with a team in a fast-moving field, iterating on
schematics, components, fabrication processes, and models of device physics. Mixing those four things together forces projects to form separate branches for variations on any one of them, where improvements in one branch might not make it to another. Isolating them under different data flows allows fabricated and simulated geometry to drift apart. Keeping the four in separate but connected abstraction layers allows each to be independently modified and swapped out when needed, with all output artifacts descending from a single source of truth.
This also makes standard tools for version control and dependency management effective for ensuring reproducibility and combining multiple work streams—related to the "Design projects are software projects" principle.

The package is structured accordingly:

  - The `SchematicGraph` describes components and their connectivity without knowing anything about geometry. It expresses design intent as symbolic placement and routing constraints that will be followed even if the underlying component parameters or types change.
  - Component geometry, defined in `_geometry!` methods of individual components, encodes design intent as parameterized exact geometry with symbolic metadata. This gives us `CoordinateSystem`s storing arbitrary `GeometryEntity` types with arbitrary metadata (usually `SemanticMeta`). Components do not know anything about fabrication processes or physics, besides a vocabulary of layer-name symbols.
  - Rendering backends receive all that information about the schematic and exact geometry, plus a `Target` containing process-level information—the mapping from layer names to GDS layers in a `ProcessTechnology` inside a `LayoutTarget`, or how to turn the 2D geometry into a 3D model in a `SolidModelTarget`. The same schematic can be used to generate both, keeping models and artwork in sync.
  - Configuration of physics for simulation happens downstream of all of the above, with all relevant information preserved. The same rendered `SolidModel` can be used with different boundary conditions and simulation types. Results can be traced back to schematic-level information, for example for port or eigenmode identification. This physics step is mainly left to the user.

These abstractions are not watertight, often intentionally, because research devices need flexibility—but, ideally, escape hatches between layers have a limited, well-defined scope. For example, a component can be connected to a `SchematicGraph` by an "additional hook" with position and direction manually specified during graph assembly, rather than computed during floorplanning. Geometry thus leaks into the graph to allow fast ad-hoc component placement.

The name `Target` (for the object holding layer mappings and other rendering directives) was chosen to evoke compilation, where you compile (`render!`) source code (a `Schematic`) targeting an instruction set architecture (fabrication process or simulation type).
As long as fabrication process technologies use the same layer vocabulary—the layer-name symbols used in `SemanticMeta`—they can be used with the same schematics.

The compilation analogy does not quite extend to an intermediate representation (IR), where all geometry would be "lowered" to a canonical form before being passed to a particular rendering backend. The closest thing
right now is that most rendering passes through `CurvilinearPolygon` or `CurvilinearRegion` in order
to handle complex rounding (including filleting of corners where arcs meet lines or other arcs)
even when the final goal is plain polygons. A canonical geometry form based on
`Vector{CurvilinearRegion}` [has been proposed](https://github.com/aws-cqc/DeviceLayout.jl/issues/293)
for an eventual v2.

The [Architecture](@ref dev-architecture) page describes how this architecture is laid out in the source.
