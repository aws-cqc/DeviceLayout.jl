# Geometry laws

Run the `:geomlaws` testitems using `TestEnv.activate()` and
`TestItemRunner.run_tests(pkgdir(DeviceLayout); filter=ti -> :geomlaws in ti.tags)`.
`GEOMLAWS_EXAMPLES` sets the valid-example budget (default 50), and
`GEOMLAWS_SEED` sets the seed (default 20260908; `random` for exploration).
`@lawcheck` fails a successful Supposition search that exhausted its attempt limit
without reaching that budget. Its nested testset reports valid examples and attempts.
Known-broken generative laws remain explicitly skipped (`GEOMLAWS_RUN_BROKEN=1` runs
them); their deterministic reproducers live in `test_ledger.jl`.

## Exploration

At the PR budget the laws are deterministic regression tests over a fixed set of
inputs. The search happens in the weekly GeomLaws workflow
(`.github/workflows/GeomLaws.yml`), which runs `explore.jl` once per law file with a
fresh seed, 2000 examples, and shrinking disabled: Supposition's shrinker has no time
budget. A failure prints the seed and the unshrunk counterexample. To reproduce it,
run `GEOMLAWS_SEED=<seed> GEOMLAWS_EXAMPLES=2000 julia --project=. test/laws/explore.jl
<file>`, or run that item through `TestItemRunner.run_tests` with the same environment to
shrink it. Graduate the counterexample into `test_ledger.jl` before changing the law.

## Comparison contract

Vertices map to the same lattice used by clipping: integer coordinates are not
prescaled, whereas floating coordinates use the femtometer grid. The regions between
those vertices are **continuous**, not sets of lattice points. Contour collections
use even-odd membership, including hole contours and zero-width keyhole bridges.
These comparisons are not for arbitrary overlapping positive-fill input collections.

- `≐` compares contours after removing consecutive duplicates, removing intermediate
  collinear vertices, normalizing orientation/start vertex, and sorting contours.
- `region_same` also recognizes equivalent decompositions into contours. An exact
  rational vertical sweep includes every endpoint and crossing of the boundaries.
  Between event coordinates, ordered edges bound cells of constant membership.
  Collinear overlaps are split and parity-neutral seams/bridges cancelled before
  certification, so only actual region boundaries contribute tolerance capsules.
  Any nonempty disagreement cell disproves equality; integer probes are not needed.
- `region_within(X, Y, tol)` certifies that every disagreement lies in the **closed**
  `tol`-neighborhood of either boundary. Each disagreement cell is triangulated.
  A triangle is covered if all its vertices lie in one segment's radius-`tol`
  capsule, which is convex. Otherwise the checker subdivides, finds an exact
  rational off-band witness, or exhausts its work/depth budget.
- `region_subset_within` checks only cells belonging to X but not Y.

Certificates use `Rational{BigInt}`, never the clipping kernel. A tolerance comparison
can return `(false, :inconclusive)` when it cannot finish the certificate; this is a
**non-pass**, not a generator rejection. Failure diagnostics are recorded as
Supposition events. `max_work` bounds arrangement and subdivision work. Total-area
differences and finite membership samples are not accepting region-equality oracles.
The contract ignores isolated boundary decorations, not filled slivers.

B7, B12, O3, and O7 are explicitly **sampled** membership laws against a reference
computed from the operands alone. They complement, rather than replace, the certified
region comparisons; exact certificates between two discretized curves, as O7 would
need, cost about a second per example. O8 checks the entire length of each output
chord: an exact segment-distance minimum enforces the lower distance bound, while a
capsule certificate enforces the upper bound. On integers it uses the stated
two-lattice-unit conformance tolerance, not a claim about Clipper's unrounded 0.25 arc
tolerance; on floats it pins the default `atol` of 1 nm, allowing the 2.25× that
Clipper1's rounding of each corner's chord count can reach.
O8 is explicitly restricted to **positive offsets of convex polygons**, with `δ > 2`.
Outside a convex source, source-distance residual equals distance to its expanded
boundary. This is false where nonconvex fronts merge, so the checker rejects that
unsupported domain rather than falsely certifying it. O3 retains general stars and
erosion, but is sampled; general nonconvex O8 certification remains open. O8 does not
by itself prove that no component was omitted.

## Generator and output validity

Hole containment checks whole edges, including excursions through a concave parent's
boundary; checking only vertices is insufficient after rounding. B11 draws valid trees
directly rather than waiting for unrelated stars to happen to produce a hole: an
outer/hole pair, and trees of two to six holes in a grid of cells, some with islands.
It tests both those trees and integer/float kernel trees derived from them.
B8 checks winding as well as hole flags, simplicity, and optional nesting.

B11 checks that keyhole output is weakly simple, counterclockwise, and free of
zero-length edges, including at cut endpoints (ledger L6, fixed by #350). Trees with a
hole outside its parent are rejected as B11 inputs; `to_polygons` throws on them
(ledger L5).

Generators draw vertex counts on their own (the shorter of two independently sized
vectors is usually 3 at small budgets, and triangles are convex), and angles, radii,
and shifts on integer grids (bounded `Data.Floats` draws bit patterns, putting about a
quarter of draws within 1e-3 of the lower bound). Shapes that reach a law's hard cases are drawn on purpose:
dumbbells and cavities whose offsets change topology (O3), multi-hole trees (B11),
pairs moved up to 1 cm from the origin (B7, B8, T1), and kernel output fed back as an
operand (B12), which reaches near-coincident edges.

## Mutants

`mutants/` applies modeled defects to the kernel wrappers, `interiorcuts`, and path
halos by method redefinition and lists the checks each one fails
(`julia --project=. test/laws/mutants/run.jl [mutant ...]`). Use it to judge a new law
or generator by what it catches; see its README.

## Differential runs

`differential/` holds the scripts that compare two clipping kernels on the same
generated and corpus inputs and classify every disagreement; see its README. The
definitions shared with the laws live in `lawslib.jl`, which `setup.jl` wraps in the
`LawsSetup` snippet.

## Limits

The exact fallback costs more than canonical comparison or sampling. Measure the PR
budget on the CI matrix before changing its default; never trade an inconclusive
certificate for a passing sample vote. The work budget does not interrupt a native
Clipper call. Differential/corpus runs and native-call process timeouts are separate
from these testitems.
