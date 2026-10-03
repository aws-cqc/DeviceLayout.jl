# [Architecture](@id dev-architecture)

This page is a map of the source tree for people who need to change it: how the package is
organized, how a schematic becomes output, and what interface a new type must satisfy to
participate in the rest of the system. The [Concepts](@ref concepts-index) section explains
*what* the abstractions are, and [Design Principles](@ref dev-principles) explains why they
were chosen.

## Modules

`DeviceLayout` is a single package with one top-level module and a tree of submodules. Most
submodules are namespacing devices rather than hard boundaries: the top-level module
`import`s their names and re-exports the public ones, so users mostly write `using DeviceLayout`
and only name a submodule for unexported names like `Paths.CPW`.

| Module | File | Role |
|---|---|---|
| `DeviceLayout` | `src/DeviceLayout.jl` | Abstract types, type aliases, FileIO registration, include order, exports |
| `Points`, `Transformations` | `src/points.jl`, `src/transform.jl` | `Point`, `ScaledIsometry` and friends |
| `Rectangles`, `Polygons` | `src/rectangles.jl`, `src/polygons.jl` (+ `src/clipping.jl`) | Polygon entities, `Rounded`, `ClippedPolygon`, Clipper-based Booleans and offsets |
| `Curvilinear` | `src/curvilinear.jl` (+ `src/curve_recovery.jl`) | `CurvilinearPolygon`/`CurvilinearRegion` (exact curved edges), `pathtopolys`, curve recovery after clipping |
| `Align`, `Texts`, `SimpleShapes`, `Intersect`, `Autofill` | one file each | Utilities built on the entity/structure interfaces |
| `CoordinateSystems`, `Cells` | `src/coordinate_systems.jl`, `src/cells.jl` | The two container types |
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

## [How a schematic becomes output](@id dev-render-pipeline)

Both backends start from a checked `Schematic`, whose internal `coordinate_system` holds
references to the components placed by `plan`. Component geometry is produced lazily: the
renderer asks for `elements(comp)`, which calls `geometry(comp)`, which runs `_geometry!` once
and caches the result. `build!` only forces that step early.

Rendering options (`target.rendering_options` plus any keywords the caller passes) travel as
keyword arguments through every layer down to `to_polygons`/`to_primitives`, where
`OptionalStyle` reads its flag from them. Nothing validates them on the way, so a misspelled
option is silently ignored ([#7](https://github.com/aws-cqc/DeviceLayout.jl/issues/7)).

Errors raised while rendering an individual structure are caught and logged with
`_group=:render` rather than thrown, so one broken component doesn't abort a whole layout.
`render!` on a `Schematic` sends those logs to the schematic's log file and then applies its
`strict` keyword: by default it throws at the end if anything was logged at error level.

**Artwork:** `render!(cs, sch, ::LayoutTarget)` in `schematics/schematics.jl`.

1. `_maps(target)` (`schematics/targets.jl`) turns the target into a `map_meta` function
   (`SemanticMeta` → `GDSMeta`, or `nothing` to skip the entity) plus rendering options.
2. When the destination is a `Cell`, `_render!` in `render/render.jl` walks the reference
   tree, creating one `Cell` per distinct structure (memoized) and reproducing the references
   as `CellReference`s/`CellArray`s, so the hierarchy survives.
3. Each entity's metadata is mapped and the entity is converted with `to_polygons`. Polygons
   above the GDS vertex limit are split (`render/polygons.jl`).
4. `Paths.Node`s go through `pathtopolys` (`curvilinear.jl`). `islinear(seg, sty)` sends
   straight-edged segment/style pairs to the fast `to_polygons` methods in `render/*.jl`;
   everything else becomes `CurvilinearPolygon`s, which are then discretized to tolerance.

**3D model:** `render!(sm, sch, ::SolidModelTarget)` in `schematics/solidmodels.jl`.

1. The target supplies indexed layers, `zmap` (`layer_z`), `map_meta`, retained groups,
   rendering options, and the postrender operation list: extrusions derived from the target,
   then `target.postrenderer`, then intersections with the simulation volume.
2. `render!(sm, cs; ...)` in `solidmodels/render.jl` flattens the coordinate system (no
   hierarchy survives in 3D). For each distinct metadata it maps the metadata to a
   physical-group name, converts the entities with `to_primitives`, and adds them to the
   kernel. Path nodes use the same `islinear` gate and `pathtopolys` as artwork, but curved
   results stay `CurvilinearRegion`s and become exact curves in Open CASCADE.
3. Mesh-size control points are sampled from the same primitives into `MESHSIZE_PARAMS`.
4. Each group is optionally unioned, `_postrender!` runs the operation list, and
   `_fragment_and_map!` fragments the model (in three dimension-pair passes) and remaps
   physical groups onto the fragments.
5. The mesh-size callback `gmsh_meshsize` is installed, and if a retained-group list was
   given, other physical groups are removed (their entities stay). Meshing happens when the
   user asks.

`render_conformal!` shares steps 2–5 but deduplicates edges as they are created, so the
model is conformal by construction and fragmentation is skipped unless
`fragment_backstop=true`.

## Where things are

Only files whose names don't make their contents obvious, or whose contents live somewhere
you might not look.

| File | Contents |
|---|---|
| `DeviceLayout.jl` | Besides abstract types and exports: `__init__` and the floating-point splitter/epsilon constants for the robust predicates. |
| `predicates.jl` | Shewchuk-style adaptive-precision `orientation` predicate. Do not "simplify" the arithmetic; it is written that way to control rounding. |
| `structures.jl` | The `GeometryStructure` interface, and also `uniquename`/`reset_uniquename!` with the global name counter. |
| `polygons.jl` | Besides `Polygon`: `Ellipse`/`Circle`, `LineSegment`/`Ray`/`Line`, `ClippedPolygon`, `Rounded`, `StyleDict`, `gridpoints_in_polygon`. Includes `clipping.jl` at the bottom. |
| `clipping.jl` | Everything that touches Clipper, including `offset`, `*_layerwise`, and tiled clipping. |
| `curvilinear.jl` | `CurvilinearPolygon`/`CurvilinearRegion`, corner rounding, curved Booleans, and `pathtopolys`: the geometry of every non-linear segment/style pair, used by both artwork and 3D rendering. Includes `curve_recovery.jl`. |
| `postrender.jl` | Layer-wide 2D passes on composed geometry: `round_layer!`, `split_t_junctions!`. Unrelated to `solidmodels/postrender.jl`. |
| `intersect.jl` | Path crossings and `IntersectStyle`s such as `AirBridge`. Not polygon Booleans; those are in `clipping.jl`. |
| `autofill.jl` | Grid fill, and also `halo` for coordinate systems and cells. |
| `precompile.jl` | `PrecompileTools` workload. Uses `ExamplePDK`, so ExamplePDK changes may require updating it. Registers the GDS format and Clipper handles itself because `__init__` hasn't run at precompile time. |
| `paths/contstyles/interface.jl` | The continuous-style interface (`extent`, `width`, `translate`, `pin`, `reverse`). |
| `paths/norender.jl` | `Paths.NoRender` and its forms, a path `Style`. Distinct from the entity style `DeviceLayout.NoRender` in `styles.jl`. |
| `render/*.jl` | `render.jl` has the `Cell` traversal; the rest are fast `to_polygons` methods for straight-edged segment/style pairs only. |
| `solidmodels/render.jl` | `to_primitives`, `render!(::SolidModel, ...)`, `_fragment_and_map!`, mesh-size control points and callback. `MESHSIZE_PARAMS` itself is in `solidmodels.jl`. |
| `schematics/solidmodels.jl` | `SolidModelTarget` and `render!(::SolidModel, ::Schematic, ::Target)`, not in `solidmodels/`. |
| `schematics/targets.jl` | `Target` types, and also `facing`/`backing`, `only_simulated`/`not_solidmodel`, and `render!(cs, x, ::LayoutTarget)` for non-schematic structures. |
| `schematics/components/builtin_components.jl` | `GDSComponent`, `BasicComponent`, `Spacer`, `WeatherVane`, `ArrowAnnotation`. |
| `schematics/utils.jl` | `annotated_geometry`. |
| `schematics/pdktools.jl` | `generate_pdk` and friends, driven by the templates in the repository-root `templates/`. |

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

There are two potential surprises in the hierarchy (see also "Why is `Path` a
`GeometryStructure` rather than a `GeometryEntity`?" in the [FAQ](../how_to/faq.md)):

- **A `Path` is an `AbstractComponent <: GeometryStructure`.** It's a `GeometryStructure` because it can store references added using `attach!` or `overlay!`. It's an `AbstractComponent` to allow using a `Path` in a schematic without a wrapper component type. It has hooks (`p0_hook`, `p1_hook`), can be placed in a schematic, and caches its own rendered `CoordinateSystem` in `_geometry`. That's why `AbstractComponent` is defined in `DeviceLayout` rather than in `SchematicDrivenLayout`. Because it's not a `GeometryEntity`, it can't use a `GeometryEntityStyle` and doesn't have all entity-only interface methods. However, `simplify(path)` is a single `GeometryEntity` equivalent to the path minus any references—see the next point.
- **A `Paths.Node` is a `GeometryEntity`.** Although path references are stored by nodes with an `AbstractDecoratedStyle`, a "bare" node outside a `Path` must still obey the rule that an entity can only be associated with a single piece of metadata. This is why rendering a decorated node directly must drop any attachments with a warning. Internal package code paths always use `elements(::Path), refs(::Path)` to get undecorated nodes and references separately, so these warnings can only be triggered by user code that sends a decorated node somewhere unexpected.

## [Extension points](@id dev-extension-points)

Many contributions add a new subtype of an abstract type or a new function to an abstract type's interface.

New functions should have enough methods to handle any concrete subtype they might see. If you write
a fallback that dispatches on the abstract type, it must be guaranteed to be correct for new future
subtypes, not just existing ones not covered by specializations—otherwise, a new subtype that doesn't
have a specialization will lead to silent incorrect results rather than a `MethodError`.

For new subtypes, the required methods are documented in the docstring of each abstract type;
this is a checklist of where to look.

| To add a... | Subtype | Implement | Also consider |
|---|---|---|---|
| Geometry entity | `GeometryEntity{T}` | `to_polygons(::E)`, `transform(::E, f)` | `footprint`, `halo`, `lowerleft`/`upperright` for speed; `SolidModels.to_primitives(::SolidModel, ::E)` if the kernel can represent it exactly (the fallback is `to_polygons`); `to_curvilinear` methods if styled versions should keep exact curves (the fallback discretizes and warns); a `ConformalRender._add_conformal!` method if it should share edges |
| Entity style | `GeometryEntityStyle` | `to_polygons(::E, ::S; kwargs...)` for each supported entity (or `::Polygon` as a fallback) | `transform(::S, f)` if the style holds geometric state such as a direction (the default returns the style unchanged); `lowerleft`/`upperright`/`footprint`/`halo` for `StyledEntity{T, E, S}` if the style changes the entity's extent (the defaults use the bare entity); watch `Aqua.test_ambiguities`: the generic `(::Type{<:GeometryEntityStyle})(::GeometryEntity, args...)` constructor makes a style whose first field is an entity ambiguous |
| Path segment | `Paths.ContinuousSegment{T}` | `pathlength`, `p0`, `α0`, `α1`, `setp0!`, `setα0!`, callable `seg(t)` for `t ∈ [0, pathlength]` (arc length, not normalized); `pathtopolys(::Seg, ::Style)` for the styles it should render with, since the generic method throws | The generic style methods in `curvilinear.jl` accept only `BaseContinuousSegment = Union{Straight, Turn, BSpline}` and build edges with `Paths.offset`, so either make the segment work there or convert it first (as `OffsetSegment` does with `resolve_offset`); `curvature` uses `ForwardDiff` on `seg(t)`, so keep it differentiable; `reverse`; `hash`/`==` |
| Path style | `Paths.ContinuousStyle{false}` (or `{true}` for stretchable, with the length as the last field) | `extent`, `width`, `translate`, `reverse`, `pin` (see `paths/contstyles/interface.jl`); `pathtopolys(::BaseContinuousSegment, ::S)` in `curvilinear.jl` | If it only produces straight edges on `Straight`, add it to `LinearStyle` with a fast `to_polygons(::Straight, ::S)` in `render/`; `to_primitives(::SolidModel, ::Segment, ::S)` only if 3D output must differ from `pathtopolys` (as for terminations) |
| Route rule | `Paths.RouteRule` | `_route!` or `_route_leg!`; optionally `reconcile!` | Docstring of `RouteRule` in `paths/routes.jl` |
| Component | `Component` via `@compdef` | `_geometry!(cs, ::C)`, `hooks(::C)` | [Components](@ref concept-components), [Building a Component](../tutorials/building_a_component.md), the [Style Guide](../concepts/styleguide.md) |
| Composite component | `CompositeComponent` via `@compdef` | `_build_subcomponents`, `_graph!`, `map_hooks` | [Composite Components](@ref concept-composite-components) |
| Output format | — | `save(::File{format"X"}, ::Cell)` (or `::SolidModel`) in `src/backends/` | Register the format in `__init__`, and also in `precompile.jl` if the workload saves or loads it by file name |
| Post-render operation (3D) | — | A function `op!(sm::SolidModel, args...; kwargs...)` returning the new group's entities, in `solidmodels/postrender.jl`; users reference it in `postrender_ops` tuples | Document it in `concepts/solidmodels.md`; check whether `_compose_meshsize!` needs a method for it |

Methods extending functions from another module must be defined with a qualified name
(`SchematicDrivenLayout.hooks(c::MyComp) = ...`). If the function is `import`ed, then Julia will
accept the bare name as referring to the imported function, but prefer the qualified
name for clarity.

These interfaces are public API: adding a required method to an abstract type, or changing
what an interface method receives or must return, breaks downstream subtypes (see
[What counts as breaking?](@ref dev-breaking)).

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
see. Many tests assert on logs (see [Testing](@ref dev-testing)), so a stray warning can be a
test failure. Warn when a designer should know a result may not be what they expect, and
sparingly otherwise.

## Global state

Prefer to avoid global state, but be aware that it is used in a few places:

- `__init__` creates the global Clipper handles (`_clip`, `_coffset`) and registers FileIO
  formats. `precompile.jl` duplicates both because `__init__` has not run during precompilation.
  Clipper is not thread-safe through these handles.
- `SolidModels` wraps a single global Gmsh session. Tests that touch it use the
  `QuietGmshSetup` snippet to initialize it and silence output.
- `MESHSIZE_PARAMS` (`solidmodels/solidmodels.jl`) holds the global mesh scale and default
  grading as well as the mesh-size control points and their KD-trees. `render!` clears
  the control points, but the scalar settings persist across models until changed.
- The `uniquename` counter, the `Memoization` cache for B-spline tangent optimization, and the
  PolyText font caches are process-global.
- Some warnings are shown once per session (for example, `recover_curves` warns once per entity
  type about lost curves). Test items share a process, so a test asserting such a warning
  depends on nothing earlier having triggered it.

## Integration points

**Clipper.** All 2D polygon Booleans and offsets go through the C++ Clipper library.
Clipper works on `Int64` coordinates: `clipperize` scales unitless coordinates by `10^9`
(femtometers, since `1.0` means one micron) or converts lengths to femtometers, and rounds;
`declipperize` converts back. Clipper discards curve information, so inputs are discretized
first and `Curvilinear.recover_curves` re-identifies arcs and B-splines in the output by
provenance, which lets the `*_curved` Booleans keep exact curves for 3D rendering. Results with
holes come back as a contour tree; `to_polygons(::ClippedPolygon)` serializes them with keyhole
cuts for GDS.

**Gmsh and Open CASCADE.** `SolidModels` drives the single Gmsh session through `Gmsh.jl`
(`gmsh.model.occ` for `OpenCascade`, `gmsh.model.geo` for `GmshNative`); Open CASCADE comes
bundled in `gmsh_jll`. Gmsh holds named models with one current model, one option set, and one
mesh-size callback. `SolidModel(name)` adds a model and makes it current, erroring if the name
exists unless `overwrite=true`. Entity tags are integers assigned by the kernel, and physical
groups are how DeviceLayout keeps track of what entities mean across Booleans and
fragmentation. The mesh-size callback is the top-level function `gmsh_meshsize` reading
`MESHSIZE_PARAMS`, not a closure, because closures can't be passed as C callbacks on Apple
silicon.

**FileIO.** `save`/`load` dispatch on file extension. `__init__` registers `format"GDS"` (with
magic bytes, load and save), `format"DXF"`, `format"STEP"`, `format"BREP"`, and
`format"MSH2"`, and adds DeviceLayout as a saver for the already-registered `MSH`, `SVG`,
`PDF`, `EPS`, and `PNG`. `SolidModels.save` passes any other extension to `gmsh.write()`.

**Python.** The DXF backend writes a small Python script that calls
[ezdxf](https://ezdxf.readthedocs.io/) and runs it with a user-supplied interpreter
(`save("file.dxf", cell, "python3")`). There is no PyCall/PythonCall dependency.

**Unitful and ForwardDiff.** `units.jl` defines `ForwardDiff.derivative` for `Unitful.Length`
arguments, which is how segment tangents and curvature work with units; `Aqua.test_piracies`
is told to treat it as our own. Segment code must therefore accept `ForwardDiff.Dual` numbers.

**Palace.** [Palace](https://awslabs.github.io/palace/stable/) is the finite-element solver
`SolidModel` output is designed for. DeviceLayout does not depend on it; the interface is the
`.msh` file plus physical-group attribute numbers that a Palace config refers to, as in
`examples/SingleTransmon`.

**PDKs.** PDKs are separate Julia packages, typically in a private registry, that depend on
DeviceLayout. `ExamplePDK` is the reference pattern (see [PDKs](@ref pdk-architecture)).
Downstream PDK test suites are the best available integration test for a DeviceLayout change.
