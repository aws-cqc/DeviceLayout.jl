# [Release and Maintenance](@id dev-release)

## Versioning

DeviceLayout.jl follows [Semantic Versioning](https://semver.org/). The package has been at
v1 since its public release; the rules below decide whether a change requires a minor
or a major version bump. Since a major bump is a large event, fixes that would technically
be breaking are usually made opt-in in v1 and queued for v2 (see below).

### [What counts as breaking?](@id dev-breaking)

We aim to be clear and consistent about what counts as a breaking change.

- Changes to the public API are breaking. The public API is what is exported or documented.
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
  breaking in the v2 changelog.
- Changes to graphical output (color schemes, text display) are not breaking.
- Changes to auto-generated names are not breaking. For example, `flatten(c)` defaults to
  `name=uniquename("flatten_"*name(c))`, but this default or the `uniquename` mechanism itself
  may change. If the user depends on an exact name downstream, they should set it explicitly,
  both for this reason and because these names are already not stable for the same code run
  multiple times in a Julia session (unless `reset_uniquename!()` is called before each run).

For component packages (PDKs) rather than DeviceLayout itself, see
[Component and package creation and versioning](@ref style-package) in the Style Guide.

### Changelog

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/). Every user-visible
change lands with an entry under `## Unreleased` in one of `### Added`, `### Changed`,
`### Deprecated`, `### Removed`, `### Fixed`. Entries are written for users: name the public
symbols, say what changed and why it matters, and link the issue or PR when there is one.
Breaking changes (in a v2 changelog) and tolerance-level geometry changes (any version) are
called out explicitly.

## Release process

1. Confirm `main` is green and that downstream test pipelines that track `main` (for example,
   internal PDKs) are passing.
2. Choose the new version `X.Y.Z` from the changes since the last release, using the rules
   above.
3. Open a PR from a branch `vX.Y.Z` with a single commit titled `DeviceLayout vX.Y.Z` that
   changes only:
   - `Project.toml`: `version`.
   - `CHANGELOG.md`: rename `## Unreleased` to `## X.Y.Z (YYYY-MM-DD)`, add a fresh empty
     `## Unreleased` above it, and fill in anything missing.
   - `CITATION.cff`: add anyone who made a significant contribution since the last release,
     if not already listed.
4. Merge once checks pass.
5. On the GitHub page for the resulting commit on `main` (click the commit message on the repo
   front page), comment `@JuliaRegistrator register`
   ([example](https://github.com/aws-cqc/DeviceLayout.jl/commit/5733341e20762f2af43622cadfefad8f3794694f)).
   Everything after this is automatic:
   - JuliaRegistrator opens a PR against the [General registry](https://github.com/JuliaRegistries/General),
     which auto-merges after checks (~30 minutes). If it doesn't, the PR comments
     explain why.
   - Once registered, TagBot creates the `vX.Y.Z` tag and GitHub release, with release notes
     taken from the changelog.
   - The tag push triggers the `Documentation` workflow, which deploys the versioned docs and
     updates `stable`.
6. If there are new authors, create a new version of the Zenodo record:
   - Download the tagged source as a `.zip` (green "Code" button on the release).
   - At [the Zenodo record](https://zenodo.org/records/20430150), choose "New version" (you
     need to be granted access to the record by an existing owner).
   - Upload the `.zip`, set the publication date to today and the version to `X.Y.Z`
     (no `v` prefix), add new contributors as authors, preview, and publish.
7. Announce in the appropriate channels. On the Julia Discourse forum, reply to the
   [existing 1.x release thread](https://discourse.julialang.org/t/ann-devicelayout-jl-cad-for-quantum-integrated-circuits-and-more/126502/3)
   rather than starting a new one.

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
- `julia = "1.10"` in `[compat]` is the lower bound. Raising it is a breaking change for
  users on older Julia; do it at a minor release at the earliest and note it in the
  changelog.

### Dependency compatibility

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

To stop CompatHelper from repeatedly proposing a bump for a dependency that must stay pinned,
use an equality specifier in `[compat]` (e.g. `Foo = "=1.2.3"`) and pass
`bump_compat_containing_equality_specifier=false` to `CompatHelper.main()` in the workflow.

`Aqua.test_deps_compat` in the test suite ensures every non-stdlib dependency has a compat
entry, so adding a dependency without one fails CI.

### Authors and citation

`CITATION.cff` is the source of truth for the author list, and Zenodo mints a DOI per version.
When a new author makes a major contribution, add them to `CITATION.cff` in the next release
PR and create a new Zenodo version as part of that release.

### Documentation previews

`Docs-Cleanup.yml` deletes `previews/PR<n>` from `gh-pages` when a PR closes and rewrites the
branch history to keep it from growing. If `gh-pages` gets large anyway (e.g. previews from
PRs that were deleted rather than closed), it is safe to remove stale `previews/` directories
by hand; nothing else references them.
