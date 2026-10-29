# [Versioning Policy](@id dev-versioning)

DeviceLayout.jl follows [Semantic Versioning](https://semver.org/). The package has been at
v1 since its public release. Since a major bump is a large event, breaking changes are
collected for 2.0 in the
[2.0 tracking issue](https://github.com/aws-cqc/DeviceLayout.jl/issues/300) and the
[`DeviceLayout v2.0.0` milestone](https://github.com/aws-cqc/DeviceLayout.jl/milestone/1),
and fixes that would technically be breaking are made opt-in in v1 where possible.

## [What counts as breaking?](@id dev-breaking)

We aim to be clear and consistent about what counts as a breaking change:

- Backward-incompatible changes to the public API are breaking. The public API is what is
  exported or in [API documentation](@ref reference-index), including the interfaces users
  implement for their own subtypes. Interfaces documented as "experimental" are not included.
- Adding a required method to an abstract type, or changing what an interface method like
  `_geometry!` or `_route_leg!` receives or must return, is breaking.
- Changing the return type of a public function (e.g. scalar → vector) is breaking.
- Changing underspecified behavior to something more "correct" is breaking. For example,
  [#8](https://github.com/aws-cqc/DeviceLayout.jl/issues/8) describes undesirable `halo`
  outputs, but there's no well-specified contract under which some are clearly "wrong". Other
  boundaries between bugfixes and breaking changes may be fuzzy; lean towards opt-in fixes in
  v1 (e.g., a keyword that selects the new behavior) and call out the fixed behavior as
  breaking in the 2.0 changelog.

Not breaking:

- Changes to any "experimental" API are not breaking.
- Changing silently incorrect behavior to match documented behavior is not breaking.
- Changes to `ExamplePDK` are never breaking.
- Changes to curve discretization within the default or a specified tolerance are not
  breaking. Such changes can lead to out-of-tolerance changes further downstream (for
  example, in autofill, if a grid point crosses from just inside to just outside a contour),
  so they should still be called out prominently in the changelog.
- Changing default mesh sizing is not breaking.
- Changes to graphical output (color schemes, text display) are not breaking.
- Changes to auto-generated names are not breaking. For example, `flatten(c)` defaults to
  `name=uniquename("flatten_"*name(c))`, but this default or the `uniquename` mechanism itself
  may change. If the user depends on an exact name downstream, they should set it explicitly,
  both for this reason and because these names are already not stable for the same code run
  multiple times in a Julia session (unless `reset_uniquename!()` is called before each run).

For component packages in user PDKs rather than DeviceLayout itself, see
[Component and package creation and versioning](@ref style-package) in the Style Guide.

## [Opt-in first](@id dev-opt-in)

Whenever a change can be made available in a 1.x release behind a keyword or preference that
defaults to current behavior, it should be. Then 2.0 mostly flips defaults, and users who opted
in early see no change at all. The opt-in PR targets `main`; the corresponding 2.0 PR only
flips the default.

Changes with no opt-in path (type and field changes, removals, restructuring) go in their own
PR against the long-running `v2.0.0-dev` branch, so each stays reviewable and revertible.

## [Deprecations](@id dev-deprecations)

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

## [Changelog](@id dev-changelog)

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/). Every user-visible
change lands with an entry under `## Unreleased` in one of `### Added`, `### Changed`,
`### Deprecated`, `### Removed`, `### Fixed`. Entries are written for users: name the public
symbols, say what changed and why it matters, and link the issue or PR when there is one.
Tolerance-level geometry changes are called out explicitly. On the `v2.0.0-dev` branch,
changes for 2.0 go in a `## 2.0.0 (upcoming)` section above `## Unreleased`: flipped defaults
and other breaking behavior changes under `### Breaking`, removed API under `### Removed`
(naming the version it was deprecated in and its replacement), and anything else under the
usual headings.