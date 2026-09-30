# [Development Workflow](@id dev-workflow)

How to set up a development checkout, run and write tests, format code, build the docs, and
get a change reviewed and merged. Contribution etiquette (issues first for large changes,
fork-and-PR, licensing) is in
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

- **TestEnv** in your default environment (`] add TestEnv` outside the project) if you want
  to run individual test items without going through `Pkg.test()`.
- **VS Code Julia extension** if you want the Testing sidebar (see below).
- **Python + ezdxf** for the DXF backend and its test: `pip install -r requirements.txt`.
  The test calls `python3` from `PATH`. Everything else works without Python.

Reviewers who just want to try a branch can `] add DeviceLayout#branch-name` without cloning.

## [Testing](@id dev-testing)

The suite uses [TestItemRunner](https://github.com/julia-vscode/TestItemRunner.jl):
each `@testitem` in `test/*.jl` is an independent unit that runs in its own module.
`test/runtests.jl` defines shared `@testsnippet`s and calls `@run_package_tests` with a
filter that matches test-item names against `ARGS`.

### Running tests

Four equivalent ways, from least to most granular:

1. **Full suite, CI-equivalent.** With the package as active project:
   ```julia
   using Pkg; Pkg.test()
   ```
   To run only test items whose names contain any of some strings:
   ```julia
   Pkg.test(test_args=["Routes", "Polygon clipping"])
   ```
2. **CLI.** From the package root directory, full suite or items with names containing the arguments:
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

CI runs the full suite on every released Julia minor from 1.10 upward. Pre-release Julia is
allowed to fail but failures should be investigated.

### Anatomy of the suite

| File | Covers |
|---|---|
| `runtests.jl` | `CommonTestSetup` snippet (imports; unit constants like `μm2nm` for mixed-preference tests; `is_sliver`, `with_test_logger`, `quiet_test_output`, `check_g1_continuity`, `check_line_arc_fillets`), `QuietGmshSetup` snippet, runner. |
| `tests.jl` | The original monolithic file: points, polygons, transformations, cells, paths, backends. New tests usually go in a topical file instead. |
| `test_<topic>.jl` | One file per subsystem: `test_clipping.jl`, `test_render.jl`, `test_routes.jl`, `test_schematicdriven.jl`, `test_solidmodel.jl`, `test_parameter_set.jl`, ... |
| `test_examples.jl` | Runs `examples/DemoQPU17` and `examples/SingleTransmon` end to end and checks the QPU17 artwork against a geometry fingerprint. |
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
  PR. The QPU17 fingerprint test is gated to Julia ≥ 1.12 because the hash differs across
  Julia minor versions.
- Files written during tests go under `tdir` (a `mktempdir()` from the snippet).

## Formatting

CI rejects unformatted code. Format with

```sh
julia scripts/format.jl format
```

which installs JuliaFormatter v1 into a temporary environment (so you get exactly the version
CI uses) and formats `src/`, `test/`, and `scripts/` according to `.JuliaFormatter.toml`.
`julia scripts/format.jl check` reports without modifying. Markdown in docstrings is also
formatted (`format_markdown=true`), so a formatting-only diff inside a docstring is normal.

## Documentation

Docs are built with [Documenter](https://documenter.juliadocs.org/) from `docs/src/`,
with the page tree in `docs/make.jl`. Docstrings are pulled in via `@docs` blocks on the
Reference pages; a docstring that isn't listed anywhere is silently omitted because
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

**Conventions.**

New user-facing concepts go under `docs/src/concepts/`, task-oriented material under
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

## Pull requests and review

Before opening a PR:

- The change is scoped: every changed line traces to the stated purpose. Don't reformat or
  refactor code you aren't otherwise touching.
- Tests pass locally (`Pkg.test()`), including new tests for new behavior and a regression
  test for any bug fix.
- `julia scripts/format.jl check` passes.
- `CHANGELOG.md` has an entry under "Unreleased" in the appropriate subsection (Added /
  Changed / Deprecated / Removed / Fixed), written for users, naming the public symbols
  involved. Decide whether the change is breaking using
  [What counts as breaking?](@ref dev-breaking); if it is, say so in the entry.
- Docstrings are updated for any changed public API, new public API functions are added
  to the appropriate API reference page, and concept pages are updated if the
  change alters behavior they describe.

Required checks on `main` are: formatting, documentation build, and tests on each released
Julia minor version in the CI matrix. A PR can merge once those pass and a maintainer has
approved. Squash-merge is the norm; the PR title becomes the commit message, so make it
descriptive.

DeviceLayout-specific things reviewers should look for beyond standard criteria:
correctness on unitful *and* unitless coordinates; whether the change silently alters
rendered geometry; new warnings or log noise, including in tests and docs builds;
and whether the changelog entry and breaking-change assessment are right.

## Continuous integration

Workflows live in `.github/workflows/`.

| Workflow | Trigger | What it does |
|---|---|---|
| `CI.yml` | push to `main`, tags, PRs, manual | `julia-format` job runs `scripts/format.jl check`; then a `test` matrix over Julia versions runs `Pkg.test()` with coverage uploaded to Codecov. Installs Python + `requirements.txt` for the DXF test. `pre` entries in the matrix are `continue-on-error`. |
| `Documentation.yml` | push to `main`, tags, PRs | Builds docs with Julia 1.10 and deploys via `deploydocs` (`push_preview=true` for PR previews). Uploads `docs/build/` as an artifact for 7 days. |
| `Docs-Cleanup.yml` | PR closed | Removes `previews/PR<n>` from the `gh-pages` branch and squashes its history. |
| `TagBot.yml` | comment by `JuliaTagBot`, manual | Creates the GitHub release after a version is registered in General. Uses `DOCUMENTER_KEY` so the tag push triggers the docs build. |
| `CompatHelper.yaml` | daily, manual | Checks for new dependency versions outside `[compat]`. See [Release and Maintenance](@ref dev-release) for how to handle its output. |
| `Benchmark.yml` | manual | Runs the benchmark suite and uploads `benchmark.md`. |

Secrets: `DOCUMENTER_KEY` (SSH deploy key with write access, shared by Documenter, TagBot,
and CompatHelper) and `CODECOV_TOKEN`. `GITHUB_TOKEN` is provided automatically.

### Debugging CI failures

- **Format job fails:** run `julia scripts/format.jl format` locally and commit. If the
  formatter changed code you didn't touch, someone merged unformatted code; format it in a
  separate commit so review stays readable.
- **Tests fail on one Julia version only:** usually floating-point differences (check
  fingerprint tests and `isapprox` tolerances) or a dependency resolving differently. Run
  locally with that version via `juliaup`.
- **Docs build fails:** the error is almost always in an `@example` block; find the first
  `ERROR` in the log. Warnings don't fail the build.
- **DXF test fails:** Python or `ezdxf` is missing or a different `python3` is first on `PATH`.
- **Cache weirdness:** `julia-actions/cache` can serve a stale compiled cache after a
  dependency bump; rerun the job before digging deeper.
