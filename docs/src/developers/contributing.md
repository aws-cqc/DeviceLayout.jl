# [Contributing](@id dev-contributing)

How to set up a development checkout, run and write tests, format code, build the docs, decide
whether a change is breaking, and get a change reviewed and merged. Contribution etiquette
(issues first for large changes, fork-and-PR, licensing) is in
[CONTRIBUTING.md](https://github.com/aws-cqc/DeviceLayout.jl/blob/main/CONTRIBUTING.md).

## Setup

```sh
git clone https://github.com/aws-cqc/DeviceLayout.jl
cd DeviceLayout.jl
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

`--project=.` activates the package's own environment. You can also `] dev /path/to/DeviceLayout.jl`
from another environment (for example a PDK or design project) to test your change against
real downstream code.

Optional pieces:

- **TestEnv** in your default environment (`] add TestEnv` outside the project) to run
  individual test items without going through `Pkg.test()`.
- **VS Code Julia extension** if you want the Testing sidebar (see below).
- **Python + ezdxf** for the DXF backend and its test: `pip install -r requirements.txt`.
  The test calls `python3` from `PATH`; without ezdxf, the DXF testset in the "Backends" test
  item fails. Everything else works without Python.

Reviewers who just want to try a branch can `] add DeviceLayout#branch-name` for a branch on
the main repository, or `] add https://github.com/<user>/DeviceLayout.jl#branch-name` for a
branch on a fork.

## [Testing](@id dev-testing)

The suite uses [TestItemRunner](https://github.com/julia-vscode/TestItemRunner.jl):
each `@testitem` in `test/*.jl` is an independent unit that runs in its own module.
`test/runtests.jl` defines shared `@testsnippet`s and calls `@run_package_tests` with a
filter that matches test-item names against `ARGS`.

### Running tests

1. **Full suite, CI-equivalent.** With the package as active project:
   ```julia
   using Pkg; Pkg.test()
   ```
   To run only test items whose names contain any of some strings:
   ```julia
   Pkg.test(test_args=["Routes", "Polygon clipping"])
   ```
2. **CLI.** From the package root directory, the full suite (via `Pkg.test()`) or, with
   arguments, the items whose names contain any of them (via TestEnv, as in 4):
   ```bash
   julia --project=. scripts/test.jl
   julia --project=. scripts/test.jl "Routes" "Polygon clipping"
   ```
3. **VS Code.** Open the repo folder and use the Testing sidebar (beaker icon). Individual test
   items can be run, debugged, or run with coverage.
4. **Targeted, in a REPL.** With TestEnv available and the package as active project:
   ```julia
   using TestEnv; TestEnv.activate()
   using TestItemRunner
   import DeviceLayout
   TestItemRunner.run_tests(pkgdir(DeviceLayout); filter=ti -> ti.name == "Backends")
   ```
   The filter receives `(; filename::String, name::String, tags::Vector{Symbol})`; `filename`
   is an absolute path. **Always pass an explicit path to `run_tests`.** Without it,
   TestItemRunner scans upward from the current directory and can pick up test items from
   sibling checkouts or `~/.julia`. Use `TestEnv.activate()` rather than running tests in the
   checkout's project directly: some tests write preferences, and TestEnv keeps them out of
   the repo's `Project.toml`/`LocalPreferences.toml`; tests also have some additional
   dependencies that are not present in the package's own project environment.

On Julia versions before 1.13, `Pkg.test()` runs with `--check-bounds=yes`, so it can't reuse
the precompile cache from development and recompiles DeviceLayout and its dependencies. Prefer
the TestEnv routes for iteration on those versions.

CI runs the full suite on every released Julia minor from 1.10 upward. Pre-release Julia is
allowed to fail but failures should be investigated.

### Anatomy of the suite

| File | Covers |
|---|---|
| `runtests.jl` | `CommonTestSetup` snippet (imports; unit constants like `μm2nm` for mixed-preference tests; `is_sliver`, `with_test_logger`, `quiet_test_output`, `check_g1_continuity`, `check_line_arc_fillets`), `QuietGmshSetup` snippet, runner. |
| `tests.jl` | The original monolithic file: points, polygons, transformations, cells, paths, backends. New tests usually go in a topical file instead. |
| `test_<topic>.jl` | One file per subsystem: `test_clipping.jl`, `test_render.jl`, `test_routes.jl`, `test_schematicdriven.jl`, `test_solidmodel.jl`, `test_parameter_set.jl`, ... |
| `test_examples.jl` | The "ExamplePDK" item runs `examples/DemoQPU17` end to end and checks the artwork against a geometry fingerprint. The "Single Transmon" item rebuilds the `examples/SingleTransmon` schematic from ExamplePDK components and checks the rendered `SolidModel`'s physical groups; the example script itself needs Palace and other packages and is not run in CI. |
| `test_aqua.jl` | [Aqua](https://github.com/JuliaTesting/Aqua.jl): compat entries for all deps, no type piracy (except one deliberate `ForwardDiff` method), no stale deps, no undefined exports, no method ambiguities. |
| `*.gds`, `test_ezdxf.py` | Fixtures: malformed GDS files for reader robustness, and a Python helper for the DXF round-trip. |

### Writing tests

- Put new tests in the topical `test_<topic>.jl` file, or create one. Use `@testitem` with the shared setup snippet:
  `setup = [CommonTestSetup]` (plus `QuietGmshSetup` for anything that touches Gmsh).
- Name test items descriptively and reference the issue when the test is a regression test:
  `@testitem "Zero-length turns are ignored (#269)"`. Names are what the CLI filter matches on.
- **Assert on logs.** Warnings are part of the contract. Use `with_test_logger`,
  `with_expected_info`, or `quiet_test_output` from the snippet to require that expected
  warnings appear and no others do, or `@test_logs` directly. Unexpected warnings in a
  test are failures, not noise.
- **Unitful and unitless.** If the code under test is generic in the coordinate type, test at
  least one `Length` type and `Float64`. The snippet's `μm2nm`, `μm2μm`, etc. let you test
  mixed-preference arithmetic without changing the compile-time preference. Only the default
  unit preference (`PreferNanometers`) is tested in CI. The test suite's `μm`, `nm`, etc. are imported
  from Unitful (no preference), not `PreferNanometers`. Tests that pass in a user environment
  can fail in the test environment, or vice versa, depending on unit preference and how unit symbols
  were imported in the user environment.
- **Geometry comparisons** should use `isapprox` with an explicit `atol`, or compare
  invariants (area, perimeter, vertex count, `is_sliver`) rather than raw vertex lists, unless
  the vertex list is the contract.
- **Fingerprints.** `Cells.geometry_fingerprint` gives a SHA-256 of a cell's flattened,
  canonically ordered geometry. Use it for "nothing changed" regression tests on large
  outputs. When a rendering change is intentional, update the expected hash and say so in the
  PR. The QPU17 fingerprint test is gated to Julia ≥ 1.12 because Julia 1.10 and 1.11 give
  different hashes.
- Files written during tests go under `tdir` (a `mktempdir()` from the snippet).

## Formatting

CI rejects unformatted code. Format with

```sh
julia scripts/format.jl format
```

which installs JuliaFormatter v1 into a temporary environment (so you get exactly the version
CI uses) and formats `src/`, `test/`, and `scripts/` according to `.JuliaFormatter.toml`.
`julia scripts/format.jl check` reports without modifying. Docstrings are also formatted
(`format_docstrings = true`), so a formatting-only diff inside a docstring is normal.

## Documentation

Docs are built with [Documenter](https://documenter.juliadocs.org/) from `docs/src/`,
with the page tree in `docs/make.jl`. Docstrings are pulled in via `@docs` blocks on the
Reference and Examples pages; a docstring that isn't listed anywhere is silently omitted because
`checkdocs=:none`.

**Previews.** Every pull request gets a preview at
`https://aws-cqc.github.io/DeviceLayout.jl/previews/PR<number>/`, deleted when the PR closes.
This is usually the fastest way to review docs changes.

**Local build.**

```sh
julia --project=docs -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'
julia --project=docs docs/make.jl
```

Expect several minutes: the `@example` blocks run real code, including the QPU17 example.
If the build dies with `MissingRemoteError` for a `CoordinateTransformations` docstring, run
`Pkg.develop("CoordinateTransformations")` in the docs environment: the Reference pages include
its docstrings, and Documenter needs a git checkout to generate source links. (This adds a
local path to `docs/Project.toml` under `[sources]`; don't commit that.) Because
`prettyurls=true`, the output in `docs/build/` needs a web server rather than `file://`; for
example `using LiveServer; serve(dir="docs/build")`.

**Check for warnings.** `warnonly=true` means broken `@ref` links, missing
docstrings, and failed doctests produce warnings, not errors. Scan the log for `Warning`
before merging docs changes.

**Conventions.** New user-facing concepts go under `docs/src/concepts/`, task-oriented material under
`tutorials/` or `how_to/`, and API listings under `reference/`. For more on the distinctions
between these kinds of documentation and how to write each effectively, see
[Diátaxis](https://diataxis.fr/). This "Developer Guide" section is for material that only
matters if you're changing the package itself.

## Benchmarks

`benchmark/` is a [PkgBenchmark](https://github.com/JuliaCI/PkgBenchmark.jl) suite
(`benchmarks.jl` defines `SUITE`; topical files add groups for autofill, bounds, clipping,
curves, intersections, polygons, and schematics). It has its own environment:

```sh
julia --project=benchmark -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'
julia --project=benchmark -e 'include("benchmark/run_benchmarks.jl")'
```

`run_benchmarks.jl` writes `benchmark.md` and prints a summary. The `Benchmark` GitHub
workflow runs the same thing on demand (`workflow_dispatch`) and uploads `benchmark.md` as an
artifact. To compare two commits, use `PkgBenchmark.judge` directly.

Benchmarks are not run on every PR. If a change is performance-motivated, include before/after
numbers in the PR description.

When adding benchmarks, you may need to delete `benchmark/tune.json` so it can be regenerated.

## [Versioning and breaking changes](@id dev-versioning)

DeviceLayout.jl follows [Semantic Versioning](https://semver.org/). The package has been at
v1 since its public release. Since a major bump is a large event, breaking changes are
collected for 2.0 in the
[2.0 tracking issue](https://github.com/aws-cqc/DeviceLayout.jl/issues/300) and the
[`DeviceLayout 2.0.0` milestone](https://github.com/aws-cqc/DeviceLayout.jl/milestone/1),
and fixes that would technically be breaking are made opt-in in v1 where possible.

### [What counts as breaking?](@id dev-breaking)

We aim to be clear and consistent about what counts as a breaking change.

- Backward-incompatible changes to the public API are breaking. The public API is what is
  exported or documented, including the interfaces users implement for their own subtypes:
  adding a required method to an abstract type, or changing what an interface method such as
  `_geometry!` or `_route_leg!` receives or must return, is breaking.
- Changing the return type of a public function (e.g. scalar → vector) is breaking even when
  the geometry is unchanged.
- Changes to `ExamplePDK` are never breaking.
- Changes to curve discretization within the default or a specified tolerance are not
  breaking. Such changes can lead to out-of-tolerance changes further downstream (for
  example, in autofill, if a grid point crosses from just inside to just outside a contour),
  so they should still be called out prominently in the changelog.
- Changing default mesh sizing is not breaking.
- Changing silently incorrect behavior to match documented behavior is not breaking.
- Changing underspecified behavior to something more "correct" is breaking. For example,
  [#8](https://github.com/aws-cqc/DeviceLayout.jl/issues/8) describes undesirable `halo`
  outputs, but there's no well-specified contract under which some are clearly "wrong". Other
  boundaries between bugfixes and breaking changes may be fuzzy; lean towards opt-in fixes in
  v1 (e.g., a keyword that selects the new behavior) and call out the fixed behavior as
  breaking in the 2.0 changelog.
- Changes to graphical output (color schemes, text display) are not breaking.
- Changes to auto-generated names are not breaking. For example, `flatten(c)` defaults to
  `name=uniquename("flatten_"*name(c))`, but this default or the `uniquename` mechanism itself
  may change. If the user depends on an exact name downstream, they should set it explicitly,
  both for this reason and because these names are already not stable for the same code run
  multiple times in a Julia session (unless `reset_uniquename!()` is called before each run).

For component packages in user PDKs rather than DeviceLayout itself, see
[Component and package creation and versioning](@ref style-package) in the Style Guide.

### Opt-in first

Whenever a change can be made available in a 1.x release behind a keyword or preference that
defaults to current behavior, it should be. Then 2.0 mostly flips defaults, and users who opted
in early see no change at all. The opt-in PR targets `main`; the corresponding 2.0 PR only
flips the default.

Changes with no opt-in path (type and field changes, removals, restructuring) go in their own
PR against the long-running `v2.0.0-dev` branch, so each stays reviewable and revertible.

### [Deprecations](@id dev-deprecations)

Deprecated functionality keeps working for the rest of 1.x and is removed in 2.0.

- Use `Base.depwarn()` where a method is simply going away or being renamed.
- Use a default-visible `@warn` with `maxlog` where there is a new, more correct usage to opt
  into.
- Every message names the replacement spelling, not just the removal.
- The test suite runs quiet: tests don't trigger deprecation warnings except in one dedicated
  test item asserting that each deprecation still warns.
- Add a "Deprecated" changelog entry, and add the removal to the 2.0 tracking issue.

The last 1.x release is an upgrade-assist release: it removes nothing, makes every 2.0
behavior reachable by opting in, and makes all deprecation warnings loud and repeated.

### Changelog

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/). Every user-visible
change lands with an entry under `## Unreleased` in one of `### Added`, `### Changed`,
`### Deprecated`, `### Removed`, `### Fixed`. Entries are written for users: name the public
symbols, say what changed and why it matters, and link the issue or PR when there is one.
Tolerance-level geometry changes are called out explicitly. On the `v2.0.0-dev` branch,
breaking changes go under `### Breaking` in a `## 2.0.0 (unreleased)` section.

## Pull requests and review

Before opening a PR:

- The change is scoped: every changed line traces to the stated purpose. Don't reformat or
  refactor code you aren't otherwise touching.
- Tests pass locally (`Pkg.test()`), including new tests for new behavior and a regression
  test for any bug fix.
- `julia scripts/format.jl check` passes.
- `CHANGELOG.md` has an entry under "Unreleased" in the appropriate subsection, as described
  above. Decide whether the change is breaking using
  [What counts as breaking?](@ref dev-breaking); if it is, make it opt-in on `main` or target
  `v2.0.0-dev`.
- Docstrings are updated for any changed public API, new public API functions are added
  to the appropriate API reference page, and concept pages are updated if the
  change alters behavior they describe.
- Code adapted from another project has a compatible license and an entry in
  `THIRDPARTY.md`, and the PR says so.

Required checks on `main` are: formatting, documentation build, and tests on each released
Julia minor version in the CI matrix. Tests only start once the formatting check passes. CI
runs only on Linux x64, so test platform-specific behavior (file paths, binary dependencies,
Gmsh callbacks) locally. A PR can merge once the checks pass and a maintainer has approved.
Squash-merge is the norm; the PR title becomes the commit message, so make it descriptive.

DeviceLayout-specific things reviewers should look for beyond standard criteria:
correctness on unitful *and* unitless coordinates; whether the change silently alters
rendered geometry; new warnings or log noise, including in tests and docs builds;
and whether the changelog entry and breaking-change assessment are right.
