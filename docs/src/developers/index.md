# [Developer Guide](@id dev-index)

This section is for people changing DeviceLayout.jl itself: maintainers, designers who hit a
bug or a missing feature and want to fix it, and the coding assistants either of them might
be working with. If you want to *use* the package, start with
[Getting Started](../how_to/get_started.md) and the [Concepts](@ref concepts-index) instead.

- [Architecture](@ref dev-architecture): how the package is layered, where each concept lives
  in `src/`, the type hierarchy, and the interface a new entity, style, segment, route rule,
  component, or output format has to implement.
- [Development Workflow](@ref dev-workflow): setting up a checkout, running and writing tests,
  formatting, building docs, benchmarks, pull-request expectations, and CI.
- [Release and Maintenance](@ref dev-release): versioning and the breaking-change policy,
  the changelog, the release procedure and the automation behind it, and recurring chores.
- [Dependencies and Integration Points](@ref dev-dependencies): what each external library is
  used for and what to watch when upgrading it.

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

## [Development principles](@id dev-principles)

Development of DeviceLayout.jl is guided by a few principles. They are the tie-breakers when a
design decision isn't obvious, and they're the standard reviewers will hold a change to.

1. **Target the design cycle.** Prioritize the time designers spend getting from one design to
   the next. Provide designers with the right abstractions and precise feedback for fast
   iteration. Raw performance improvements are valuable when they relieve bottlenecks in a
   feedback cycle.

2. **Rigorously pursue correctness.** Outputs that can't be trusted without manual review are
   obstacles to automation and scaling. Specify contracts precisely, test thoroughly, and
   provide tools for designers to verify and validate results where correctness can't be
   mechanically guaranteed. Warn loudly when designers should know results may not be as
   expected, and sparingly otherwise. Fail rather than guess.

3. **Capture and transmit design intent.** Take what designers know about the device and carry
   it from their input to the final output artifacts. Hold on to the mapping between
   schematic and geometry levels for as long as possible, and preserve exact geometry with
   semantic metadata for as long as possible. Don't rely on extracting meaning from raw polygons except
   for validation of what the schematic already knows.

4. **One language for both exploration and scaling:** Going from concept to first simulation is a
   different workflow from integrating that concept into a large-scale device. Both should be
   easy, and both should use the same tools, supporting a fast, faithful path from prototype
   to integration at scale.

5. **Separate physics and geometry.** Layout abstractions own geometry, connectivity, and parameters.
   Physical quantities and models (frequencies, impedances, Hamiltonians) live in PDK or design code
   that maps onto components, not inside them. So: a hook is an attachment point, not necessarily a
   port; a parameter is a geometry control knob, not a device property; one component may be simulated
   in several ways, or not at all.

6. **Design projects are software projects.** Documentation, library architecture, and APIs
   promote high-quality user code and software-engineering best practices.
   Reproducibility is a first-class concern. Anticipate many designers collaborating on different
   parts of the same design or on related designs, and define abstractions and interfaces to
   allow modular contributions.

7. **A process-agnostic core:** The core schematic workflow and layout engine don't encode layer
   numbers, material stacks, or fabrication methods. Those belong to PDKs; the core sees them
   only as rendering directives. Designers don't define a different component for each new
   experimental fabrication process.

The [Architecture](./architecture.md) page describes how these principles relate to certain
decisions about how the package works.

Concrete plans are tracked as
[GitHub issues](https://github.com/aws-cqc/DeviceLayout.jl/issues); `help wanted` marks
items that are well-scoped for a first contribution.

## Where to ask

Open a [GitHub issue](https://github.com/aws-cqc/DeviceLayout.jl/issues) for bugs, feature
requests, and questions about how something works. Security concerns go to AWS Security as
described in CONTRIBUTING.md, not to the public tracker.
