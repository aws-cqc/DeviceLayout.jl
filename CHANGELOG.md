# Changelog

The format of this changelog is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

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
