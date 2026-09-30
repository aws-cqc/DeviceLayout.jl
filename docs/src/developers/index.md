# [Developer Guide](@id dev-index)

This section is for people changing DeviceLayout.jl itself: maintainers, designers who hit a
bug or a missing feature and want to fix it, and the coding assistants either of them might
be working with. If you want to *use* the package, start with
[Getting Started](../how_to/get_started.md) and the [Concepts](@ref concepts-index) instead.

- [Design Principles](@ref dev-principles): the principles that decide design questions and
  review, and how they shape the package's layered architecture.
- [Architecture](@ref dev-architecture): how the package is laid out in `src/`, how a
  schematic becomes a GDS file or a 3D model, the type hierarchy, and the interface a new
  entity, style, segment, route rule, component, or output format has to implement.
- [Contributing](@ref dev-contributing): setting up a checkout, running and writing tests,
  formatting, building docs, benchmarks, versioning and deprecation policy, and pull-request
  expectations.
- [Maintainer Runbook](@ref dev-maintenance): the release procedure, CI and the automation
  behind it, and recurring chores such as dependency and Julia version updates.

This project has adopted the [Amazon Open Source Code of Conduct](https://aws.github.io/code-of-conduct).

## First contribution, in brief

1. Open or find an issue describing the problem. For anything larger than a bug fix, agree on
   the approach there first.
2. Clone, `julia --project=. -e 'using Pkg; Pkg.instantiate()'`, and reproduce the issue with a
   test (see [Testing](@ref dev-testing)).
3. Make the change. Use the [Architecture](@ref dev-architecture) page to find the right
   file and the interface you need to satisfy.
4. Run `julia scripts/format.jl format`, then `Pkg.test()`.
5. Add a `CHANGELOG.md` entry under "Unreleased" and decide whether the change is
   [breaking](@ref dev-breaking).
6. Open a pull request. CI runs formatting, docs, and tests on every supported Julia version;
   a docs preview link appears once the docs job finishes.

Concrete plans are tracked as
[GitHub issues](https://github.com/aws-cqc/DeviceLayout.jl/issues); `help wanted` marks
items that are well-scoped for a first contribution.

## Where to ask

Open a [GitHub issue](https://github.com/aws-cqc/DeviceLayout.jl/issues) for bugs, feature
requests, and questions about how something works. Security concerns go to AWS Security as
described in CONTRIBUTING.md, not to the public tracker.
