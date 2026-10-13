# [Conventions](@id dev-conventions)

Rules for writing code in DeviceLayout.jl. They apply to new and changed code. Existing code
doesn't follow all of them, and isn't changed just to conform. Conventions for tests and docs are in
[Writing tests](@ref dev-writing-tests) and [Documentation](@ref dev-docs).

## Substantive conventions

Some conventions are particularly consequential:

**Units and coordinate types.** Almost all geometry is parameterized by a coordinate type
`T <: Coordinate = Union{Real, Length}`. Code must work for unitless `Float64` (interpreted as
microns), for `Unitful` lengths, and (in some places) for `Int`. Functions that take more than
one coordinate should work when they have different units. Use `zero(T)`, `oneunit(T)`,
`DeviceLayout.onenanometer(T)`, `DeviceLayout.onemicron(T)`, and `ustrip(unit, x)` rather than
assuming a unit.

**Tolerances.** Curve discretization defaults to `atol = onenanometer(T)`; Clipper works on
coordinates rounded to an `Int64` femtometer grid by `clipperize`. When comparing geometry,
prefer `isapprox` with an explicit `atol` over `==`.

**Generated names.** `uniquename` appends a counter from a process-global, thread-safe
dictionary; it is deterministic only in a fresh session or after calling `reset_uniquename!()`.
If you need to generate a unique name (schematic node `id`, coordinate system `name`), use
`uniquename` to avoid collisions, and allow the user to explicitly provide a name.
Auto-generated names are not part of the public API (see
[What counts as breaking?](@ref dev-breaking)).

**Fallbacks.** New functions should have enough methods to handle any concrete subtype they
might see. If you write a fallback that dispatches on an abstract type, it must be guaranteed to
be correct for new future subtypes, not just existing ones not covered by
specializations—otherwise, a new subtype that doesn't have a specialization will lead to silent
incorrect results rather than a `MethodError`.

**Logging.** Use `@warn`/`@info` from `Logging`, never `println`, for anything a user should see. Many tests
assert on logs (see [Writing tests](@ref dev-writing-tests)), so a stray warning can be a test
failure. Warn when a designer should know a result may not be what they expect, and sparingly
otherwise. Throw an error rather than guess at what the user intended
(see [Design Principles](@ref dev-principles)).

**Global state.** Avoid adding global state. Where it is unavoidable, add it to the list in
[Global state](@ref dev-global-state).

## Style

DeviceLayout.jl generally follows the [Julia manual's style guide](https://docs.julialang.org/en/v1/manual/style-guide/)
and [Blue style](https://github.com/JuliaDiff/BlueStyle), but consistency with existing code
is more important. Layout is whatever JuliaFormatter
produces with `.JuliaFormatter.toml`, which CI enforces (see [Formatting](@ref dev-formatting)),
so formatting is never a review topic. Remaining style decisions can be settled by [SciMLStyle](https://github.com/SciML/SciMLStyle) when it has an applicable rule.

Some conventions are not obvious from context (especially in older ports of the code) or simply come up frequently:

**Mutation.** Functions and methods that mutate any of their arguments have names ending in
`!`. Mutated arguments come before non-mutated arguments, following SciML's
[function argument precedence](https://github.com/SciML/SciMLStyle?tab=readme-ov-file#function-argument-precedence).

**Leading underscores.** A name beginning with `_` is not called by users. It is either a
private helper or an interface method that users implement but don't call, like `_geometry!`,
`_graph!`, `_build_subcomponents`, and `_route_leg!` (see
[Extension points](@ref dev-extension-points)). New private helpers within a source file should
begin with `_`. New methods used across source files should not use a leading underscore, even
if they are not public (exported, documented, or part of an interface that users implement).

**Variables.** Names reflect the actual type of the value they hold, not a related
concept. For example, a `ComponentNode` is `node`, never `comp` (the component it wraps is
`node.component`); a `Schematic` is `sch` or `floorplan`; a `SchematicGraph` is `g` (avoid `graph`, which is a function exported by `.SchematicDrivenLayout`); a `Cell` is
`c`, not `cs` (which denotes a `CoordinateSystem`). In a small scope where the type is
obvious from context or a type annotation (a comprehension, a short loop body, a short function
with annotated arguments), use very brief names. In a large scope, or where nothing lets a
reader infer the type, use longer descriptive names.

**Extending functions from other modules.** Define methods with a qualified name
(`SchematicDrivenLayout.hooks(c::MyComp) = ...`). If the function is `import`ed, then Julia
will accept the bare name as referring to the imported function, but prefer the qualified name
for clarity.

**Comments.** Comments explain why the code is the way it is, so future readers know what's safe or necessary to change. Comments are evergreen and do not make historical references ("refactored", "new", "improved", "fixed").

Example code follows the [component style guide](../concepts/styleguide.md).
