# SolidModel rendering and meshing benchmarks

Single-shot, end-to-end timings of `render!(::SolidModel, ...)` and Gmsh meshing on two
example workloads. Unlike the BenchmarkTools suite in `../benchmarks.jl`, each workload runs
once per process — the QPU17 render alone takes tens of minutes — and records per-phase
timings, geometry and mesh statistics, and geometry fingerprints as JSON.

| script | workload | typical time |
|---|---|---|
| `run_single_transmon.jl` | `examples/SingleTransmon/schematic.jl` (`single_transmon_schematic`) | ~1 min |
| `run_qpu17.jl` | `examples/DemoQPU17/solidmodel.jl` (`qpu17_solidmodel_setup`) | 30–60 min |

The workloads are the examples' own schematic-construction functions, included from the
`DeviceLayout` checkout under test (`pkgdir(DeviceLayout)`), so a base ref must be recent
enough to define them: at or after the commit that added this directory.

## Running

From the repository root:

```sh
julia --project=benchmark -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'
julia --project=benchmark benchmark/solidmodel/run_single_transmon.jl
julia --project=benchmark benchmark/solidmodel/run_qpu17.jl --order=1 --scales=1.0
```

Options (all scripts):

- `--out=PATH` — output JSON (default `results/<workload>-<sha>-<timestamp>.json`, gitignored)
- `--scales=1.0,0.5` — `SolidModels.mesh_scale` values to mesh at, in order
- `--order=1` — element order for meshing
- `--skip-mesh` — render only

Gmsh's own progress output goes to stderr; filter it with `2>&1 | grep -v '^Info    :'`.

## Comparing runs

```sh
julia --project=benchmark benchmark/solidmodel/compare.jl base.json head.json [--threshold=0.10]
```

prints a markdown report and exits nonzero if geometry differs or any timing regresses by more
than `threshold`:

- **Geometry identity** — artwork fingerprint (`Cells.geometry_fingerprint`), SolidModel
  fingerprint (SHA-256 over sorted, rounded per-entity and per-physical-group mass and
  centroid, independent of OCC entity tags), entity counts per dimension, per-group entity
  counts and masses, mesh node/element counts, minimum `minSICN` and `gamma` quality, and the
  number of elements with `γ < 0.1` and `0.1 ≤ γ < 0.2`.
- **Timings** — setup (`plan` + artwork render), SolidModel render total and per phase
  (physical groups, auto-union, postrender operations, three-pass fragment), 1D/2D/3D mesh
  generation per scale.

Two runs at the same commit on the same machine are a **determinism check**: every row in
the geometry-identity section should read `same`. Any `differs` row is a nondeterminism to
catalog (source, magnitude, whether it changes the mesh).

Timings across different machines (or different GitHub runners) are not comparable; the
`Benchmark SolidModel` workflow therefore runs base and head back-to-back in one job. The
first run in a process includes JIT compilation, which is a visible fraction of the
single-transmon numbers and negligible for QPU17.

## What the render phases mean

Phase timings come from the step reporter that `render!(...; verbose=true)` also uses for its
log messages (`StepCollector` in `common.jl`); each step is recorded in the results JSON under
`phases.render.steps` as `(phase, name, seconds)`:

- `groups` — adding each physical group's entities to the OCC kernel (2D geometry →
  OCC faces, with point deduplication)
- `auto_union` — per-group unions when `auto_union=true`
- `postrender` — the target's `postrender_ops` (booleans, extrusions, boundary extraction)
- `fragment` — `_fragment_three_pass!` over dimension pairs `[0,1]`, `[1,2]`, `[2,3]`
