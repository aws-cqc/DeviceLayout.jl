# Changelog

The format of this changelog is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## Upcoming

  - Added `xor2d` for polygon XOR
  - Improved support of wave port boundary conditions in SolidModel

      + SolidModelTargets now take `wave_port_layers`, a list of layer symbols used to define wave port boundary conditions.
      + Added support for `LineSegment` in SolidModel.
      + Added option to use wave ports instead of lumped ports in the single transmon example.

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
