# Changelog

The format of this changelog is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## Unreleased

  - Added `ParameterSet`, a nested dictionary wrapper with dot-access for reading and
    writing design parameters, plus `resolve` and `leaf_params` helpers
  - Added a `ParameterSetYAMLExt` weak-dep extension loaded via `using YAML` that
    enables `ParameterSet(path::String)` / `ParameterSet(io::IO)` construction and
    `save_parameter_set` with Unitful round-tripping
  - Added `SchematicGraph(name, ps)` to carry a `ParameterSet` on the graph, plumbed
    through `_build_subcomponents` via `parameter_set(graph)` and
    `create_component(T, ps, address)`
  - Added `SchematicDrivenLayout.footprint_halo` for implementing fast custom halos with less boilerplate
  - Fixed incorrect loading of GDS array references with nonzero origin
  - Added `set_parameters(c, ps, address; kwargs...)` and the scoped form
    `set_parameters(c, sub::ParameterSet)` for the templates-aliasing pattern:
    overlay `ParameterSet` leaves on top of a template instance, with optional
    composite-level kwargs winning over the overlay. Unknown leaves under the
    address surface as `ArgumentError` at composite-build time
  - `create_component(T; kwargs...)` now rejects `MissingNamespace` and
    `ParameterSet` kwarg values with actionable errors at the call site,
    rather than letting them flow into the constructor
  - Added optional `rtol` keyword argument for `render!`/`to_polygons` to allow larger features to be rendered with relaxed tolerance; if provided, curves are discretized with tolerance `max(atol, rtol * local_curvature_radius)`
  - Fixed issue where rendering keyword arguments could be dropped for compound segments with non-compound styles
  - Fixed overly-strict `Ellipse` and `Circle` constructors to allow different center and radius coordinate types

## 1.13.0 (2026-04-28)

  - Added layerwise Booleans `union2d_layerwise`, `difference2d_layerwise`, `intersect2d_layerwise`, and `xor2d_layerwise`
  - Added `clip_tiled` for tiled clipping of large polygon sets
  - Added `Polygons.area`
  - Normalized rotation angles to [0, 360) when writing GDS files
  - `Path` now uses the preferred coordinate type (`typeof(1.0UPREFERRED)`) when the coordinate type is not explicitly specified; use `Path{T}(...)` or (e.g.) `Path(nm, ...)` for explicit control
  - `offset` now returns polygons with interior cuts instead of separate outer and hole contours when holes are present
  - Deprecated `cliptree(op, s, c; kwargs...)` in favor of `clip(op, s, c; kwargs...).tree`
  - Fixed bug where `default_parameters` would throw an error if `@compdef` parameter defaults referenced earlier parameters
  - Fixed overly-strict argument types for polygon clipping methods
  - Fixed `selection_tolerance` not being forwarded when applying a transformation to a `Rounded` style
  - Fixed `perimeter(::ClippedPolygon)` to sum over all outermost contours rather than just the first
  - Fixed errors when rendering or clipping an empty `ClippedPolygon`
  - Fixed degenerate cases in line-arc corner rounding that could produce `NaN` values or arcs too small for SolidModel rendering

## 1.12.0 (2026-04-13)

  - Added `auto_union` SolidModel rendering option; if `true`, self-unions every 2D group before any other postrendering (default `false`)
  - Added `skip_unused_layers` SolidModel rendering option; if `true`, entities in layers not referenced by postrendering operations or `retained_physical_groups` are not rendered (default `false`)
  - Added `SolidModels.connected_components`, which takes a group or collection of groups and returns the connected components of entities in those groups as vectors of `(dim, tag)` tuples
  - Added tolerance-based `to_polygons` rendering for CurvilinearPolygon and CurvilinearRegion (no longer using a fixed 181 points per curve)
  - Improved efficiency of autofill point-in-polygon algorithm
  - Fixed `uniquename` not being called on default route names in some schematic routing methods
  - Fixed ClippedPolygon rendering bug that allowed keyhole cuts to pass through other holes

## 1.11.2 (2026-03-31)

  - Fixed unit promotion in rounding that could hit a Unitful bug (Unitful.jl#845)
  - Fixed `kwargs...` forwarding for CurvilinearRegion `to_polygons`

## 1.11.1 (2026-03-30)

  - Fixed dispatch error for rounding of styled entities introduced by 1.11.0
  - Fixed relative radius handling in line-arc rounding
  - Fixed `circular_arc([θ1, θ2], ...)` method so `θ1 = θ2` gives a vector with a single point rather than `nothing`

## 1.11.0 (2026-03-23)

This release adds line-arc corner rounding and improves SolidModel robustness:

  - Added support for rounding line-arc corners in `CurvilinearPolygon` and the SolidModel rendering pipeline, extending the `Rounded` style which previously only handled straight-straight corners
  - Changed SolidModel fragment recipe to fragment adjacent dimensions pairwise, fixing `PLC Error` failures when meshing geometries with extrusions at multiple height levels
  - Added `hash` and `==` for `Straight` and `Turn` path segments; also fixed `BSpline` hash and equality to give consistent results for equivalent segments with different `Unitful` unit choices
  - Improved `plan` performance by caching `hooks` results per component, avoiding redundant recomputation

Several bugs have also been fixed:

  - Fixed `render!` overwriting user-provided path metadata with default `GDSMeta()` when rendering a `Path` to `Cell`
  - Fixed `show` for empty `Cell`
  - Fixed `extent` calculation for `SimpleStrands` with more than one strand
  - Fixed error computing halo of a taper with inner delta
  - Fixed operator precedence in 45-degree routing double turn check
  - Fixed `CompoundRouteRule` default `leg_lengths` type (`Vector{Int}` instead of `Vector{Float64}`)
  - Fixed `route!` with `CompoundRouteRule` using wrong length for default style vector
  - Fixed `direction` for zero-angle `Turn` to avoid division by zero

## 1.10.0 (2026-03-04)

This release includes several new features and fixes involving Path styles:

  - Added `Paths.PeriodicStyle`, which cycles between substyles in a repeating sequence
  - Added `margin` keyword to `terminate!` to allow terminating a specified distance before the end of the path
  - Added `Paths.round_trace_transitions!` for splicing rounded tapers between `Trace` styles
  - Added `overlay_index` keyword to `terminate!` to allow applying terminations to overlay styles
  - Fixed incorrect behaviors when extending certain `Paths`: overlay styles continue as overlays, while terminations continue as `NoRenderContinuous`
  - Fixed incompatibility issues for combinations of compound, decorated, overlay, and termination styles
  - Fixed bug where zero-length path segments could cause SolidModel rendering to fail
  - Fixed bug where a generic taper inside a `simplify`-ed path would lead to an error thrown in rendering
  - Fixed bug where references in a decorated style applied as an overlay would be ignored by `halo`

There are also several minor features and fixes:

  - Added `SchematicDrivenLayout.filter_parameters` for sharing parameters between composite components and subcomponents
  - Added `rename_duplicates` option to `GDSWriterOptions`
  - Added experimental Text entity support to graphics backend
  - Fixed bug where `map_metadata!` would map multiply-referenced structures multiple times
  - Fixed bug where `@composite_variant` would not forward `map_hooks` to base variant when defined with component instance rather than type

The documentation has also been reorganized and improved:

  - Moved API reference material to separate pages
  - Added several tutorials
  - Added a style guide for component definition
  - Improved or expanded several sections, including explanation of rendering and solid models

## 1.9.0 (2026-02-09)

  - Added `SingleChannelRouting`, which allows multiple paths to be routed in parallel in the same `Channel` (defined by a path with a trace style), entering and exiting the channel in different places
  - Added memoization for B-spline optimization (`auto_speed`), so a given curve only needs `auto_speed` to do any computation once per Julia session
  - Changed default CPW mesh size to use `2 * min(trace, gap)` (higher element quality when trace and gap are very different)
  - Changed default global mesh grading from `0.9` to `0.75` (more robust meshing for complex geometries, relatively small cost)
  - Changed threshold for GDSII layer/datatype number spec warning to 32767; added `GDSWriterOptions` to configure this
  - Fixed `SolidModel` rendering issue where some exterior boundaries might not be tagged
  - Fixed breaking error with `apply_size_to_surfaces=true` supplied via `MeshingParameters`; it is still deprecated as of 1.8.0 and has no effect, but no longer throws an error

## 1.8.0 (2026-01-05)

  - Mesh size fields are no longer controlled via `PhysicalGroup` internally, this change
    allows for changing the size field associated to a `SolidModel` after `render!` via the
    global parameters accessed in `MeshSized`. This reduces the number of entities in any
    global boolean operations, improving performance, along with separating the concerns of
    rendering and meshing thereby improving user experience.

  - Deprecated `SolidModels.MeshingParameters` in favour of new `mesh_scale`, `mesh_order`,
    `mesh_grading_default` accessed from `SolidModels`. Removed `apply_size_to_surfaces`.
  - Improvements to `SolidModels.render!` to improve stability and performance.

      + Changed `SolidModels.restrict_to_volume!` to perform a check if the simulation domain
        already bounds all two and three dimensional objects, if so skips operation.
      + Changed `SolidModels.render!` to incorporate a two stage `_fragment_and_map!` operation,
        reconciling vertices and segments before reconciling all entities. This improves the
        robustness of the OpenCascade integration which can error in synchronization if too much
        reconciliation is required all at once by `fragment`.
      + These two operations in conjunction with the removal of `MeshSized` entities results in
        a ~3x performance improvement in rendering the QPU17 example to `SolidModel`, and ~4.5x
        reduction in time from schematic to mesh.
  - Fixed Julia 1.11+ performance regression for B-spline optimization.

## 1.7.0 (2025-11-26)

  - Added `xor2d` for polygon XOR

  - Improved support for wave port boundaries in a `SolidModel`

      + `SolidModelTargets` now take `wave_port_layers`, a list of layer symbols used to define wave port boundary conditions
      + Added support for `LineSegment` in SolidModel
      + Added `add_wave_ports!` to automatically place wave port boundaries where specified paths/routes intersect the simulation area
      + Added option to use wave ports instead of lumped ports in the single transmon example
  - Fixed bug where `Rounded` might incorrectly not apply to a `ClippedPolygon` with a
    negative.
  - Introduced `selection_tolerance` for `Rounded` which allows a rounding style to not
    select a point unless it is within a tolerance of the target. This defaults to infinite,
    but in a future major release will be reduced to a value consistent with floating point arithmetic.
  - Improved rendering performance for curves and circles

For developers, the test suite now uses the TestItem framework, and new benchmarks have been added to the benchmark suite.

## 1.6.0 (2025-10-16)

  - Improved metadata handling for `LayoutTarget` and `SolidModelTarget`

      + SolidModelTargets will now ignore `NORENDER_META` (the `:norender` layer)
      + SolidModelTargets now take `ignored_layers`, a list of layer symbols which are not rendered
      + LayoutTargets now allow overriding the mapping of `GDSMeta` by setting `target.map_meta_dict[my_gdsmeta] = my_override`, allowing changes to different `GDSMeta` or `nothing` rather than always mapping a `GDSMeta` to itself

  - Changed `remove_group!` SolidModel postrendering operation to use `remove_entities=true` by default, fixing the unexpected and undesired default behavior that only removed the record of the group and not its entities
  - Changed routing errors to be logged instead of throwing exceptions, so that a "best-effort" route is always drawn
  - Changed graphical backend to display everything in the entire reference hierarchy by default, rather than only displaying the contents of the top-level coordinate system
  - Added default metadata map, so that a CoordinateSystem or Component with SemanticMeta can be rendered directly to a Cell for quick GDS inspection
  - Added graphical `show` method for CoordinateSystem (like what `Cell` already had), so `julia> my_cs` or `julia> geometry(my_component)` will display the geometry if graphical output is available (for example, in the Julia for VS Code REPL)
  - Added dark theme for graphical output (lighter colors that look better on dark background) and `DeviceLayout.Graphics.set_theme!(theme)` for `"light"` (default) and `"dark"` themes
  - Changed ellipse rendering to use `atol` for absolute tolerance by default (supplying `Δθ` keyword will still use that as angular step)
  - Deprecated `circle` in favor of `Circle` (exact circle entity) and `circle_polygon` (discretized by angular step)
  - Deprecated `rounded` keyword in SolidModel rendering; supplying `Δθ` keyword alone will discretize ellipses

## 1.5.0 (2025-10-10)

  - Added `auto_speed`, `endpoints_curvature`, and `auto_curvature` keyword options to `bspline!` and `BSplineRouting`

      + `auto_speed` sets the speed at endpoints to avoid sharp bends (minimizing the integrated square of the curvature derivative with respect to arclength)
      + `endpoints_curvature` sets boundary conditions on the curvature (by inserting extra waypoints)
      + `auto_curvature` B-spline sets curvature at endpoints to match previous segment (or to zero if there is no previous segment)
      + Both `endpoints_speed` and `endpoints_curvature` can be specified as two-element iterables to set the start and end boundary conditions separately

  - Added `spec_warnings` keyword option for `save` to allow disabling warnings about cell names violating the GDSII specification (modern tools will accept a broader range of names than strictly allowed by the specification)
  - Added `unfold` method for point arrays to help construct polygons with mirror symmetry
  - Added FAQ entry about MeshSized/OptionalEntity styling on Paths
  - Fixed incorrect conversion and reflection of split BSplines
  - Fixed issue causing duplicate `Cell` names with paths and composite components, where rendering would use the component's name rather than a unique name

## 1.4.2 (2025-07-16)

  - Removed invalid keyword constructor without type parameters for `@compdef`-ed components with type parameters, so it can be overridden without warnings
  - Fixed `1` character in PolyTextSansMono
  - Fixed autofill exclusion in DemoQPU17
  - Removed stale Memoize.jl dependency
  - Minor documentation improvements

## 1.4.1 (2025-07-08)

  - `SolidModels.check_overlap` now skips empty groups
  - Built-in components `Spacer`, `ArrowAnnotation`, and `WeatherVane` now default to coordinate type `typeof(1.0UPREFERRED)` if no coordinate type is specified in the constructor
  - Improvements to ExamplePDK/DemoQPU17 component mesh sizing
  - Minor documentation improvements

## 1.4.0 (2025-07-01)

  - Added `SolidModels.check_overlap(::SolidModel)` for checking overlap of physical groups in a `SolidModel`
  - `Path`s containing offset B-splines and other arbitrary curves are rendered to `SolidModel` more quickly and using fewer entities for B-spline approximation
  - Rendering keyword `atol` now controls tolerance of B-spline approximation of offset B-splines and other arbitrary curves when rendering to a `SolidModel` (default tolerance remains `1.0nm`)

## 1.3.0 (2025-06-06)

  - Added `set_periodic!` to `SolidModels` to enable periodic meshes
  - `CompositeComponent` geometry now preserves subcomponents instead of replacing them with `CoordinateSystem`s, unless `build!` is called explicitly on the composite component's schematic or the parent schematic
  - Minor documentation improvements

### Fixed

  - `DecoratedStyle` and `CompoundStyle` are no longer missing any of the methods `width`, `trace`, or `gap` (forwarded to the underlying style)
  - `GeometryEntity` interface methods (`lowerleft/upperright/bounds`, `footprint`, `halo`) for `StyledEntity` now fall back to underlying entity as documented;
    specialized behavior for `NoRender` and `OptionalStyle` is preserved but now documented
  - `halo(c::ClippedPolygon)` is now consistent with the halo of an `AbstractPolygon` vector containing `c`, using the clipped polygon itself rather than its `bounds`
  - `footprint(::ClippedPolygon)` now uses outer contour if there's only one (and `bounds` otherwise, as before)

## 1.2.0 (2025-04-28)

  - Composite components can define `_build_subcomponents` to return a `NamedTuple` with keys that differ from component names
  - `Turn` segments with `SimpleTrace` or `SimpleCPW` styles now use `atol` to determine the discretization; this is faster and in some cases more accurate than the fallback method using `adapted_grid`

### Fixed

  - Rounding no longer fails when available length is less than `min_side_len` only due to numerical precision issues
  - Circular arcs in rounded polygons will no longer occasionally produce very short edges near the endpoints, and are instead now drawn with equally spaced points including the endpoints
  - Added missing `hash` and `convert` methods for `ScaledIsometry`

## 1.1.1 (2025-04-16)

  - Improved performance of nested `CompositeComponent`s by storing hooks after first computation
  - Improved performance of `ComponentNode` global transformation calculations by traversing the coordinate system hierarchy bottom-up
  - Updated compat for MetaGraphs.jl to require 0.8, fixing precompilation on Julia v1.12 beta

## 1.1.0 (2025-04-07)

  - Added `generate_pdk`, `generate_component_package`, and `generate_component_definition` to `SchematicDrivenLayout` to help users create packages and files from templates
  - Lowered default for meshing parameter `α_default` from `1.0` to `0.9` to improve robustness
  - Docs: Added closed-loop optimization example with single transmon
  - Docs: Updated to clarify that `build!` is not necessary

### Fixed

  - `launch!` without rounding now has the correct gap behind the pad
  - `terminate!` with `initial=true` appends the termination before the `Path` start as documented (previously incorrectly kept `p0(path)` constant, shifting the rest of the `Path` forward)
  - `terminate!` with rounding on a curve is still drawn as straight but keeps the full underlying segment (previously consumed some turn angle to replace with straight segment including rounding length)

## 1.0.0 (2025-02-27)

Initial release.
