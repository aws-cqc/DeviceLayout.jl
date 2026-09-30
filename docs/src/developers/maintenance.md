# [Maintainer Runbook](@id dev-maintenance)

Procedures for people with write access: releasing, the CI and automation behind it, and
recurring chores. The versioning policy these procedures apply is in
[Contributing](@ref dev-versioning).

## Release process

1. Confirm `main` is green and that downstream test pipelines that track `main` (for example,
   internal PDKs) are passing.
2. Choose the new version `X.Y.Z` from the changes since the last release, using
   [What counts as breaking?](@ref dev-breaking).
3. Open a PR from a branch `vX.Y.Z` with a single commit titled `DeviceLayout vX.Y.Z` that
   changes only:
   - `Project.toml`: `version`.
   - `CHANGELOG.md`: rename `## Unreleased` to `## X.Y.Z (YYYY-MM-DD)`, add a fresh empty
     `## Unreleased` above it, and fill in anything missing.
   - `CITATION.cff` (the source of truth for the author list): add anyone who made a
     significant contribution since the last release, if not already listed.
4. Merge once checks pass.
5. On the GitHub page for the resulting commit on `main` (click the commit message on the repo
   front page), comment `@JuliaRegistrator register`
   ([example](https://github.com/aws-cqc/DeviceLayout.jl/commit/5733341e20762f2af43622cadfefad8f3794694f)).
   Everything after this is automatic:
   - JuliaRegistrator opens a PR against the [General registry](https://github.com/JuliaRegistries/General),
     which auto-merges after checks (~30 minutes). If it doesn't, the PR comments
     explain why.
   - Once registered, TagBot creates the `vX.Y.Z` tag and GitHub release. The release notes
     are TagBot's generated list of PRs and issues closed since the last release; the
     human-written summary stays in `CHANGELOG.md`.
   - The tag push triggers the `Documentation` workflow, which deploys the versioned docs and
     updates `stable`.
6. If there are new authors, create a new version of the Zenodo record, which mints a DOI per
   version:
   - Download the tagged source as a `.zip` (green "Code" button on the release).
   - At [the Zenodo record](https://zenodo.org/records/20430150), choose "New version" (you
     need to be granted access to the record by an existing owner).
   - Upload the `.zip`, set the publication date to today and the version to `X.Y.Z`
     (no `v` prefix), add new contributors as authors, preview, and publish.
7. Announce in the appropriate channels. On the Julia Discourse forum, reply to the
   [existing 1.x release thread](https://discourse.julialang.org/t/ann-devicelayout-jl-cad-for-quantum-integrated-circuits-and-more/126502/3)
   rather than starting a new one.

### The 2.0 branch and release

Breaking changes accumulate on the long-running `v2.0.0-dev` branch (see
[Opt-in first](@ref dev-versioning) and the
[2.0 tracking issue](https://github.com/aws-cqc/DeviceLayout.jl/issues/300)).

- Integrate `main` into `v2.0.0-dev` by **merge**, on a regular cadence, rather than rebasing.
  Rebase only while the branch still has a single author.
- **Check `CHANGELOG.md` after every integration merge.** Three-way merges follow context
  lines, not position, so entries can silently land under the wrong version heading with no
  conflict.
- Release sequence: 1.x minors add APIs, opt-in flags, and quiet deprecations; the last 1.x
  release is the upgrade-assist release described under [Deprecations](@ref dev-deprecations)
  and ships an "Upgrading to 2.0" docs page; 2.0.0 flips defaults, removes deprecated API, and
  lands the changes with no opt-in path. Decide up front how long fixes will be backported to
  1.x, and say so in the 2.0.0 release notes.

## Continuous integration

Workflows live in `.github/workflows/`.

| Workflow | Trigger | What it does |
|---|---|---|
| `CI.yml` | push to `main`, tags, PRs, manual | `julia-format` job runs `scripts/format.jl check`; then a `test` matrix over Julia versions runs `Pkg.test()` with coverage uploaded to Codecov. Installs Python + `requirements.txt` for the DXF test. `pre` entries in the matrix are `continue-on-error`. |
| `Documentation.yml` | push to `main`, tags, PRs | Builds docs with Julia 1.10 and deploys via `deploydocs` (`push_preview=true` for PR previews). Uploads `docs/build/` as an artifact for 7 days. |
| `Docs-Cleanup.yml` | PR closed | Removes `previews/PR<n>` from the `gh-pages` branch and squashes its history. |
| `TagBot.yml` | comment by `JuliaTagBot`, manual | Creates the GitHub release after a version is registered in General. |
| `CompatHelper.yaml` | daily, manual | Checks for new dependency versions outside `[compat]` (see [Dependency compatibility](@ref dev-compathelper)). |
| `Benchmark.yml` | manual | Runs the benchmark suite and uploads `benchmark.md`. |

All jobs run on `ubuntu-latest` x64 only; macOS, Windows, and ARM are not covered.

Secrets: `DOCUMENTER_KEY` (SSH deploy key with write access, used by TagBot and CompatHelper)
and `CODECOV_TOKEN`. `GITHUB_TOKEN` is provided automatically.

### How the automation is wired

For anyone setting up a similar repository, or debugging why a step didn't fire:

- **JuliaRegistrator** is a GitHub App installed on the repository. It reacts to
  `@JuliaRegistrator register` comments from users with write access.
- **TagBot** (`.github/workflows/TagBot.yml`) runs on `issue_comment` events, guarded by
  `github.actor == 'JuliaTagBot'`, so it fires when the registry bot comments on the
  registration PR. It needs `contents: write` and uses `secrets.DOCUMENTER_KEY` (an SSH deploy
  key with write access) to push the tag. Pushing with an SSH key rather than `GITHUB_TOKEN`
  matters: tags pushed with `GITHUB_TOKEN` do not trigger other workflows, so the docs
  wouldn't build. TagBot can also be run manually (`workflow_dispatch`) with a `lookback`
  in days if a release was missed.
- **Documenter** (`.github/workflows/Documentation.yml`) uses `GITHUB_TOKEN` for deployment
  (`deploydocs` supports this on GitHub Actions) and needs `contents: write`,
  `statuses: write`, and `pull-requests: read`. The public key half of `DOCUMENTER_KEY` is
  registered as a deploy key on the repository.
- **CompatHelper** (`.github/workflows/CompatHelper.yaml`) reuses `DOCUMENTER_KEY` as
  `COMPATHELPER_PRIV` for the same reason: PRs opened with an SSH key trigger CI.
- **Branch protection** on `main` requires the format check, the docs build, and the test job
  for each released Julia version.

## Maintenance chores

### Julia version matrix

The `test` matrix in `.github/workflows/CI.yml` lists every supported Julia minor version
explicitly, plus `'pre'` whenever a new minor is in pre-release.

- When a new minor Julia is released, replace `'pre'` with that version. Then add that job to
  the branch protection rule as a required check; the job may need to run once on `main`
  before GitHub offers it in the rule's list.
- When the next minor enters pre-release (usually some weeks after a release), add `'pre'`
  back. It runs with `continue-on-error`, so it can't block merges, but failures should be
  looked at: they are early warning of upstream changes.
- `julia = "1.10"` in `[compat]` is the lower bound. Raising it isn't breaking under SemVer
  (the resolver won't offer the new version to older Julia), but it needs at least a minor
  release rather than a patch, and a changelog note.

### [Dependency compatibility](@id dev-compathelper)

`CompatHelper` runs daily and detects dependencies with new releases outside our `[compat]`
bounds. It was added after an incident where a substantial B-spline slowdown moving from
Julia 1.10 to 1.11 turned out to have already been fixed upstream in a version our compat
bounds excluded.

Because of organization settings, the action cannot open PRs itself. Instead, the workflow
**fails** whenever it finds something to bump, and leaves a branch behind. When you see it
fail:

1. Open a PR from the branch CompatHelper created.
2. If tests pass, merge it. If they don't, decide whether to fix our code or pin the
   dependency.

Upgrades that need more than a green test run:

- **`gmsh_jll`** can change fragmentation behavior and mesh output. The "Single Transmon" test
  item and `test_solidmodel.jl` are the main guards; they check physical groups, not meshes.
- **`PkgTemplates`** has had breaking minor releases. `test_pdktools.jl` covers
  `generate_pdk` and friends.
- **`Unitful`** occasionally changes promotion rules for mixed-unit arithmetic, which shows up
  in the mixed-preference tests.

`Aqua.test_deps_compat` in the test suite ensures every non-stdlib dependency has a compat
entry, so adding a dependency without one fails CI.

### Documentation previews

`Docs-Cleanup.yml` deletes `previews/PR<n>` from `gh-pages` when a PR closes and rewrites the
branch history to keep it from growing. If `gh-pages` gets large anyway (e.g. previews from
PRs that were deleted rather than closed), it is safe to remove stale `previews/` directories
by hand; nothing else references them.
