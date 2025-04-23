# Changelog

The format of this changelog is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## Upcoming

  - Composite components can define `_build_subcomponents` to return a `NamedTuple` with keys that differ from component names

### Fixed

  - Rounding no longer fails when radius is less than `min_side_len` only due to numerical precision issues
  - Circular arcs in rounded polygons will no longer occasionally produce very short edges near the endpoints, and are instead now drawn with equally spaced points including the endpoints
  - `Turn` segments with `SimpleTrace` or `SimpleCPW` styles now use `atol` to determine the discretization; this is faster and in some cases more accurate than the fallback method using `adapted_grid`

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
