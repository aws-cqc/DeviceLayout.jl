# [Architecture](@id dev-architecture)

This page is a map of the source tree for people who need to change it. It explains how the
package is organized, where each concept lives, and what interface a new type must satisfy to
participate in the rest of the system. The [Concepts](@ref concepts-index) section explains
*what* the abstractions are; this page is about where they are, how they fit together, and
why they were chosen in the first place.

## Architecture decisions and development principles

Many questions about why the package is the way it is are answered by the [development principles](@ref dev-principles), especially numbers 3, 5, and 7—"Capture and transmit design intent", "Separate physics and geometry", and "A process-agnostic core."

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

## Modules

`DeviceLayout` is a single package with one top-level module and a tree of submodules. Most
submodules are namespacing devices rather than hard boundaries: the top-level module
`import`s their names and re-exports the public ones, so users mostly write `using DeviceLayout`
and never see the submodule.

| Module | File | Role |
|---|---|---|
| `DeviceLayout` | `src/DeviceLayout.jl` | Abstract types, type aliases, FileIO registration, include order, exports |
| `Points`, `Transformations` | `src/points.jl`, `src/transform.jl` | `Point`, `ScaledIsometry` and friends |
| `Rectangles`, `Polygons` | `src/rectangles.jl`, `src/polygons.jl` (+ `src/clipping.jl`) | Polygon entities, `Rounded`, `ClippedPolygon`, Clipper-based Booleans and offsets |
| `Curvilinear` | `src/curvilinear.jl` (+ `src/curve_recovery.jl`) | `CurvilinearPolygon`/`CurvilinearRegion` (exact curved edges), `pathtopolys`, curve recovery after clipping |
| `Align`, `Texts`, `SimpleShapes`, `Intersect`, `Autofill` | one file each | Utilities built on the entity/structure interfaces |
| `CoordinateSystems`, `Cells` | `src/coordinate_systems.jl`, `src/cells.jl` | The two container types (see below) |
| `Paths` | `src/paths/` | `Path`, segments, styles, routes, hooks integration |
| `GDS`, `Graphics`, `DXF` | `src/backends/` | 2D file output (and GDS input) |
| `SolidModels` | `src/solidmodels/` | 3D geometry via Gmsh/Open CASCADE, meshing, `ConformalRender` |
| `PolyText` | `src/polytext/` | Text rendered as polygons (fonts stored as GDS in `deps/`) |
| `SchematicDrivenLayout` | `src/schematics/` | Components, schematics, targets, `ParameterSet`, PDK tooling |
| `SchematicDrivenLayout.ExamplePDK` | `src/schematics/ExamplePDK/` | Example components and process; used by tests, docs, and the precompile workload |
| `PreferNanometers`, `PreferMicrons`, `PreferNoUnits` | `src/units.jl` | Unit-preference modules selected at compile time |

`SchematicDrivenLayout` is the one submodule users are expected to load explicitly
(`using DeviceLayout, DeviceLayout.SchematicDrivenLayout`). It has its own export list and
is where the "schematic-driven" half of the package lives. `ExamplePDK` is nested inside it
and is explicitly *not* covered by semantic versioning (see
[What counts as breaking?](@ref dev-breaking)).

Package extensions in `ext/` load only when the corresponding weak dependency is present:

- `SchematicGraphMakieExt.jl` (`GraphMakie`): `graphplot` for `SchematicGraph`.
- `ParameterSetYAMLExt.jl` (`YAML`): `load_parameter_set`/`save_parameter_set`.

## Source map

Files with more than one concern, or whose names don't make their contents obvious.

### `src/` (top level)

| File | Contents |
|---|---|
| `DeviceLayout.jl` | Abstract type definitions (`AbstractGeometry`, `GeometryEntity`, `GeometryStructure`, `AbstractComponent`, `GeometryReference`, `AbstractCoordinateSystem`, `AbstractPolygon`, `Meta`), type aliases (`Coordinate`, `PointTypes`, ...), `__init__` (Clipper handles, FileIO format registration), the include order, and all top-level exports. Also contains the floating-point splitter/epsilon setup for the robust predicates. |
| `units.jl` | Unit-preference modules and the compile-time `unit_preference` switch (`@load_preference`); `UPREFERRED`; `ForwardDiff` methods for `Unitful` quantities. |
| `predicates.jl` | Shewchuk-style adaptive-precision `orientation` predicate. Do not "simplify" the arithmetic; it is written that way to control rounding. |
| `entities.jl`, `styles.jl` | The `GeometryEntity` and `GeometryEntityStyle` interfaces (see [Extension points](@ref dev-extension-points)); `StyledEntity`; `bounds`/`footprint`/`halo` defaults. |
| `structures.jl` | `GeometryStructure` interface (`elements`, `refs`, `flatten`, `map_metadata!`, `traversal`), `uniquename`/`reset_uniquename!` and the thread-safe global name counter. |
| `references.jl` | `StructureReference`, `ArrayReference`, `sref`/`aref`. |
| `metadata.jl` | `SemanticMeta`, `GDSMeta`, `layer_inclusion` filters, `default_meta_map`. |
| `polygons.jl` | `Polygon`, `Ellipse`/`Circle`, `LineSegment`/`Ray`/`Line`, `ClippedPolygon`, `Rounded`, `StyleDict`, `offset`, `gridpoints_in_polygon`. Includes `clipping.jl` at the bottom. |
| `clipping.jl` | Everything that touches Clipper: `clip`, `clipperize`/`declipperize` (float/unitful ↔ `Int64`), `union2d`/`difference2d`/`intersect2d`/`xor2d`, `*_layerwise`, tiled clipping with an R-tree. |
| `curvilinear.jl` | `CurvilinearPolygon`/`CurvilinearRegion`, line–line and line–arc corner rounding, `pathtopolys` (the shared implementation behind path rendering), curved Booleans (`union2d_curved` etc.). Includes `curve_recovery.jl`, which re-identifies arcs/B-splines in Clipper output by provenance. |
| `postrender.jl` | Layer-wide passes applied to *composed* geometry rather than single entities: `round_layer!`, `split_t_junctions!`. |
| `coordsys_interface.jl` | Methods shared by all `AbstractCoordinateSystem`s (`show`, broadcasting, etc.). |
| `hooks.jl` | `Hook`, `PointHook`, `HandedPointHook`, `compass`, and `transformation(h1, h2)`, the formula `plan` uses to align components. |
| `intersect.jl` | Finding crossings between paths (interval-tree sweep) and resolving them with an `IntersectStyle` such as `AirBridge`. Not polygon Booleans; those are in `clipping.jl`. |
| `autofill.jl` | Grid fill with exclusion halos. |
| `precompile.jl` | `PrecompileTools` workload. Uses `ExamplePDK`, so ExamplePDK changes may require updating it. Re-registers FileIO formats and Clipper handles because `__init__` hasn't run at precompile time. |

### `src/paths/`

| Path | Contents |
|---|---|
| `paths.jl` | Abstract `Segment`/`Style` hierarchies and their required methods, `Node`, `Path`, `StyledHook`, linked-list operations, `straight!`/`turn!`/`corner!`/`meander!`/`launch!`/`attach!`, `simplify`. |
| `segments/` | `Straight`, `Turn`, `Corner`, `CompoundSegment`, `BSpline` (with `bspline_approximation.jl` and `bspline_optimization.jl` for fitting), `OffsetSegment`. |
| `contstyles/` | Continuous styles: `trace.jl`, `cpw.jl`, `tapers.jl`, `strands.jl`, `compound.jl`, `periodic.jl`, `decorated.jl` (`DecoratedStyle`, `OverlayStyle`), `termination.jl`. `interface.jl` documents the style interface. |
| `discretestyles/` | Styles for zero-length segments (`SimpleTraceCorner`). |
| `norender.jl` | `NoRender` and its continuous/discrete forms. |
| `routes.jl` | `Route`, `RouteRule` interface, `StraightAnd90`, `StraightAnd45`, `BSplineRouting`, `CompoundRouteRule`, `route!`. |
| `channels.jl` | `RouteChannel` and `SingleChannelRouting`. |

### `src/render/`

| Path | Contents |
|---|---|
| `render.jl` | `render!(::Cell, ::GeometryStructure)`: traverses the reference hierarchy, maps metadata, memoizes structures so shared substructures become shared cells. |
| `discretization.jl` | `discretize_curve`/`discretization_grid`: curvature-adaptive sampling with absolute (`atol`) and relative (`rtol`) tolerance. |
| `polygons.jl` | `render!(::Cell, ::Polygon, ::GDSMeta)`, including splitting polygons above the GDS vertex limit. |
| `paths.jl` | `to_polygons(::Segment, ::Style)` generic fallback (via `Paths.Node` → `pathtopolys`). |
| `trace.jl`, `cpw.jl`, `tapers.jl`, `strands.jl`, `compound.jl`, `periodic.jl`, `termination.jl`, `corners.jl` | Specialized `to_polygons` methods for specific `(segment, style)` combinations. |

### `src/solidmodels/`

| Path | Contents |
|---|---|
| `solidmodels.jl` | `SolidModel`, geometry kernels (`OpenCascade`, `GmshNative`), physical groups, mesh-size fields and the size callback, `save`. |
| `render.jl` | `to_primitives` (entity → kernel geometry; exact curves under OCC), `render!(::SolidModel, ::CoordinateSystem, ...)`, extrusion, `_fragment_and_map!`. |
| `postrender.jl` | Post-render operations (`extrude_z!`, `revolve!`, `translate!`, `union_geom!`, `intersect_geom!`, `difference_geom!`, ...). `_postrender!` runs a list of `(destination, op, args, kwargs...)` tuples and assigns each result to physical group `destination`. |
| `conformal/conformal.jl` | `ConformalRender`: an alternative render strategy that emits shared OCC edges for adjacent faces so that fragmentation is unnecessary. |

Note that `SolidModelTarget` and `render!(::SolidModel, ::Schematic, ::Target)` live in
`src/schematics/solidmodels.jl`, not here; this directory is the target-agnostic 3D layer.

### `src/schematics/`

| Path | Contents |
|---|---|
| `SchematicDrivenLayout.jl` | Module definition, imports from `DeviceLayout`, exports, `Component` alias, include order. |
| `technologies.jl` | `ProcessTechnology` (layer record + process parameters), level/flipchip conventions (`facing`, `backing`, `level_z`). |
| `targets.jl` | `Target`, `LayoutTarget`/`ArtworkTarget`, `SimulationTarget`, the semantic-layer → `GDSMeta` mapping, `OptionalStyle` handling (`only_simulated`, `not_solidmodel`, ...). |
| `schematics.jl` | `SchematicGraph` (a `MetaGraph` with hook-labelled edges), `ComponentNode`, `add_node!`/`fuse!`/`attach!`, `plan` (place by hook alignment, then resolve routes), `check!`, `build!`, `render!(cs, sch, target)`, `flatten`. |
| `components/components.jl` | `AbstractComponent` accessors, `geometry` caching, `create_component`/`set_parameters`, `GDSComponent`, `BasicComponent`. |
| `components/compdef.jl` | The `@compdef` macro. |
| `components/composite_components.jl` | `AbstractCompositeComponent`, `CompositeComponent`, `filter_parameters`, hook mapping, lazy subgraph construction. |
| `components/builtin_components.jl` | `Spacer`, `WeatherVane`, `ArrowAnnotation`. |
| `components/variants.jl` | `@variant`, `@composite_variant`, `base_variant`. |
| `routes.jl` | `RouteComponent`: a component whose geometry is a `Path` resolved during `plan`. |
| `parameter_set.jl`, `parameter_set_extraction.jl` | `ParameterSet` (namespaced, dot-accessible parameter store) and extraction of parameters from an existing graph. |
| `solidmodels.jl` | `SolidModelTarget` and schematic → `SolidModel` rendering (automatic extrusion, levelwise/indexed layers, port layers). |
| `pdktools.jl` | `generate_pdk`, `generate_component_package`, `generate_component_definition`, driven by the templates in `templates/`. |
| `ExamplePDK/` | `LayerVocabulary`, example `ProcessTechnology`, and component packages (`ChipTemplates`, `ClawCapacitors`, `ReadoutResonators`, `SimpleJunctions`, `Transmons`). |

## Type hierarchy

```
AbstractGeometry{T<:Coordinate}
├── GeometryEntity
│   ├── AbstractPolygon: Rectangle, Polygon, ClippedPolygon
│   ├── Ellipse (Circle is a constructor), LineSegment/Ray/Line (D1)
│   ├── CurvilinearPolygon, CurvilinearRegion
│   ├── StyledEntity{T,U,S}          # entity + GeometryEntityStyle
│   ├── Texts.Text
│   └── Paths.Node                   # (segment, style) pair; how Paths render
├── GeometryStructure
│   ├── AbstractComponent
│   │   ├── Path                     # a Path is a component with hooks at its ends
│   │   ├── RouteChannel
│   │   ├── Component = AbstractComponent{typeof(1.0UPREFERRED)} → (user components)
│   │   ├── AbstractCompositeComponent → CompositeComponent → (user components)
│   │   └── RouteComponent, GDSComponent, BasicComponent, Spacer, WeatherVane, ...
│   └── AbstractCoordinateSystem
│       ├── CoordinateSystem
│       └── AbstractCell → Cell
├── GeometryReference{T,S}: StructureReference, ArrayReference
└── Hook: PointHook, HandedPointHook, Paths.StyledHook

Meta: SemanticMeta, GDSMeta
GeometryEntityStyle: Plain, NoRender, MeshSized, OptionalStyle, ToTolerance, WithDirection,
                     Rounded (RelativeRounded is a constructor), StyleDict
Paths.Segment{T}: ContinuousSegment (Straight, Turn, BSpline, CompoundSegment, OffsetSegment),
                  DiscreteSegment (Corner)
Paths.Style: ContinuousStyle{CanStretch} (Trace, CPW, Taper*, Strands, Compound/Periodic,
             Decorated/Overlay, terminations, NoRenderContinuous), DiscreteStyle
Paths.RouteRule: StraightAnd90, StraightAnd45, BSplineRouting, CompoundRouteRule,
                 AbstractMultiRouting → AbstractChannelRouting → SingleChannelRouting
SchematicDrivenLayout.Target: LayoutTarget (ArtworkTarget/SimulationTarget are constructors),
                              SolidModelTarget
```

Designers will define subtypes of `Component` and `CompositeComponent`.

There are two potential surprises in the hierarchy:

- **A `Path` is an `AbstractComponent <: GeometryStructure`.** It's a `GeometryStructure` because it can store references added using `attach!` or `overlay!`. It's an `AbstractComponent` to allow using a `Path` in a schematic without a wrapper component type. It has hooks (`p0_hook`, `p1_hook`), can be placed in a schematic, and caches its own rendered `CoordinateSystem` in `_geometry`. That's why `AbstractComponent` is defined in `DeviceLayout` rather than in `SchematicDrivenLayout`. Because it's not a `GeometryEntity`, it can't use a `GeometryEntityStyle` and doesn't have all entity-only interface methods. However, `simplify(path)` is a single `GeometryEntity` equivalent to the path minus any references—see the next point.
- **A `Paths.Node` is a `GeometryEntity`.** Although path references are stored by nodes with an `AbstractDecoratedStyle`, a "bare" node outside a `Path` must still obey the rule that an entity can only be associated with a single piece of metadata. This is why rendering a decorated node directly must drop any attachments with a warning. Internal package code paths always use `elements(::Path), refs(::Path)` to get undecorated nodes and references separately, so these warnings can only be triggered by user code that sends a decorated node somewhere unexpected.

## [Extension points](@id dev-extension-points)

Many contributions add a new subtype of an abstract type or a new function to an abstract type's interface.

New functions should have enough methods to handle any concrete subtype they might see. If you write
a fallback that dispatches on the abstract type, it must be guaranteed to be correct for new future
subtypes, not just existing ones not covered by specializations—otherwise, a new subtype that doesn't
implement a correct specialization will lead to silent incorrect results rather than a `MethodError`.

For new subtypes, the required methods are documented in the docstring of each abstract type;
this is a checklist of where to look.

| To add a... | Subtype | Implement | Also consider |
|---|---|---|---|
| Geometry entity | `GeometryEntity{T}` | `to_polygons(::E)`, `transform(::E, f)` | `footprint`, `halo`, `lowerleft`/`upperright` for speed; `SolidModels.to_primitives(::SolidModel, ::E)` if the kernel can represent it exactly; a `ConformalRender` method if it should share edges |
| Entity style | `GeometryEntityStyle` | `to_polygons(::E, ::S; kwargs...)` for each supported entity (or `::Polygon` as a fallback) | Watch `Aqua.test_ambiguities`: the generic `(::Type{<:GeometryEntityStyle})(::GeometryEntity, args...)` constructor makes a style whose first field is an entity ambiguous |
| Path segment | `Paths.ContinuousSegment{T}` | `pathlength`, `p0`, `α0`, `α1`, `setp0!`, `setα0!`, callable `seg(t)` for `t ∈ [0, pathlength]` (arc length, not normalized) | `curvature` uses `ForwardDiff` on `seg(t)`, so keep it differentiable; `reverse`; `hash`/`==`; `to_polygons(::Seg, ::Style)` specializations if the generic `pathtopolys` route is too slow or inexact |
| Path style | `Paths.ContinuousStyle{false}` (or `{true}` for stretchable) | `extent`, `width`, `translate`, `reverse`, `pin` (see `paths/contstyles/interface.jl`) | `to_polygons(::Segment, ::S)` in `render/`; `to_primitives` in `solidmodels/render.jl` for exact 3D geometry; `reconcilestyle!` if the style has phase/state that must carry across nodes |
| Route rule | `Paths.RouteRule` | `_route!` or `_route_leg!`; optionally `reconcile!` | Docstring of `RouteRule` in `paths/routes.jl` |
| Component | `Component` via `@compdef` | `_geometry!(cs, ::C)`, `hooks(::C)` | [Components](@ref concept-components), [Building a Component](../tutorials/building_a_component.md), the [Style Guide](../concepts/styleguide.md) |
| Composite component | `CompositeComponent` via `@compdef` | `_build_subcomponents`, `_graph!`, `map_hooks` | [Composite Components](@ref concept-composite-components) |
| Output format | — | `save(::File{format"X"}, ::Cell)` (or `::SolidModel`) in `src/backends/` | Register the format in `__init__` **and** in `precompile.jl` if the workload touches it |
| Post-render operation (3D) | — | A function `op!(sm::SolidModel, args...; kwargs...)` returning the new group's entities, in `solidmodels/postrender.jl`; users reference it in `postrender_ops` tuples | Document it in `concepts/solidmodels.md`; check whether `_compose_meshsize!` needs a method for it |

Methods extending functions from another module must be defined with a qualified name
(`SchematicDrivenLayout.hooks(c::MyComp) = ...`). If the function is `import`ed, then Julia will
accept the bare name as referring to the imported function, but prefer the qualified
name for clarity.

### Conventions

**Units and coordinate types.** Almost everything is parameterized by a coordinate type
`T <: Coordinate = Union{Real, Length}`. Code must work for unitless `Float64` (interpreted as microns), for
`Unitful` lengths, and (in a few places) for `Int`. Use `zero(T)`, `oneunit(T)`,
`DeviceLayout.onenanometer(T)`, and `ustrip(unit, x)` rather than assuming a unit.

**Tolerances.** Curve discretization defaults to `atol = onenanometer(T)`; Clipper works on
coordinates rounded to an `Int64` femtometer grid by `clipperize`. When comparing
geometry, prefer `isapprox` with an explicit `atol` over `==`.

**Naming.** `uniquename` appends a counter from a process-global, thread-safe dictionary; it is deterministic only in a fresh session or after calling `reset_uniquename!()`.
If you need to generate a unique name (schematic node `id`, coordinate system `name`), use `uniquename` to avoid collisions, and allow the user to explicitly provide a name. Auto-generated names are not part of the public API (see [What counts as breaking?](@ref dev-breaking)).

**Logging.** Use `@warn`/`@info` from `Logging`, never `println`, for anything a user should
see. Tests assert on logs (see [Testing](@ref dev-testing)), so a stray warning is a test
failure. Warn when a designer should know a result may not be what they expect, and
sparingly otherwise.

## Global state

Prefer to avoid global state, but be aware that it is used in a few places:

- `__init__` creates the global Clipper handles (`_clip`, `_coffset`) and registers FileIO
  formats. `precompile.jl` duplicates both because `__init__` has not run during precompilation.
- `SolidModels` wraps a single global Gmsh session. Tests that touch it use the
  `QuietGmshSetup` snippet to initialize it and silence output.
- `Memoization` caches (B-spline optimization) and the default `uniquename` counter are process-global.
