# Changelog

The format of this changelog is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## Upcoming

  - `SolidModels.check_overlap` now skips empty groups
  - Built-in components `Spacer`, `ArrowAnnotation`, and `WeatherVane` now default to coordinate type `typeof(1.0UPREFERRED)` if no coordinate type is specified in the constructor
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
