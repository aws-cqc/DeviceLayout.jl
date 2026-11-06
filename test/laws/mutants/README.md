# Mutants

Modeled defects for judging the GeomLaws suite by what it catches. Each mutant replaces
part of DeviceLayout with a defective version by redefining methods in the running
session. `run.jl` then runs every `:geomlaws` test item in that session and lists the
checks that fail. The results at the default budget are in the
[main README](../README.md#which-defects-the-suite-catches).

## Running

From the package root, with Julia 1.13 or later (`runner.jl` uses `Test.@with_testset`)
and TestEnv in your default environment:

```sh
julia --project=. test/laws/mutants/run.jl                  # every mutant
julia --project=. test/laws/mutants/run.jl halo_short       # selected mutants
```

The unmutated suite runs first and must pass. Then each mutant prints the checks that
fail with it applied, or `NOT CAUGHT`. `GEOMLAWS_EXAMPLES` and `GEOMLAWS_SEED` apply as
usual. Every mutant reruns the whole suite, so a full run takes about 15 minutes.

## How mutants are applied

  - Boolean and offset mutants wrap DeviceLayout's internal `_clip` and `_offset`, the
    functions that call Clipper, so they can change any result: drop holes, reverse
    contours, substitute another operation.
  - `interiorcuts` and halo mutants evaluate an edited copy of the function's source. Each
    edit must apply: if the source changes so that an edit no longer matches, the mutant
    throws instead of silently testing the original code.
  - `runner.jl` evaluates each test item's body in a fresh module, as TestItemRunner does,
    so the redefinitions take effect without recompiling DeviceLayout. Shrinking is off,
    since only detection matters.

## Adding a mutant

Add an entry to `MUTANTS` in `mutants.jl`: a function that installs the defect, through
`MUTATE_CLIP`, `MUTATE_OFFSET`, or `evalsrc` with `edited`. If it redefines anything
those don't cover, undo that in `restore!`. A new law or generator should come with a
mutant it catches; after a full run, update the table in the main README.
