# Geometry laws

Run the `:geomlaws` testitems using `TestEnv.activate()` and
`TestItemRunner.run_tests(pkgdir(DeviceLayout); filter=ti -> :geomlaws in ti.tags)`.
`GEOMLAWS_EXAMPLES` sets the valid-example budget (default 100), and
`GEOMLAWS_SEED` sets the seed (default 20260908; `random` for exploration).
`@lawcheck` fails a successful Supposition search that exhausted its attempt limit
without reaching that budget. Its nested testset reports valid examples and attempts.
Known-broken generative laws remain explicitly skipped; their deterministic
reproducers live in `test_ledger.jl`.

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

B7 and O3 remain explicitly **sampled** membership laws. They complement, rather than
replace, the certified region comparisons. O8 checks the entire length of each output
chord: an exact segment-distance minimum enforces the lower distance bound, while a
capsule certificate enforces the upper bound. It uses the stated two-lattice-unit
conformance tolerance, not a claim about Clipper's unrounded 0.25 arc tolerance.
O8 is explicitly restricted to **positive offsets of convex polygons**, with `δ > 2`.
Outside a convex source, source-distance residual equals distance to its expanded
boundary. This is false where nonconvex fronts merge, so the checker rejects that
unsupported domain rather than falsely certifying it. O3 retains general stars and
erosion, but is sampled; general nonconvex O8 certification remains open. O8 does not
by itself prove that no component was omitted.

## Generator and output validity

Hole containment checks whole edges, including excursions through a concave parent's
boundary; checking only vertices is insufficient after rounding. B11 draws a valid
outer/hole pair directly rather than waiting for unrelated stars to happen to produce
a hole. It tests both that tree and integer/float kernel trees derived from it.
B8 checks winding as well as hole flags, simplicity, and optional nesting.

B11 checks keyhole output validity with the narrow L6 exception: repeated consecutive
vertices are permitted only where the exact nearest downward-ray attachment coincides
with a parent vertex or rounds onto the lowest hole vertex (a zero-length cut).
The exception is granted only for a single-outer/single-hole tree. With siblings the
attachment search changes after earlier cuts; with multiple components, coordinates
alone cannot identify the owner of an exception. Exemptions fail closed in both cases.
All other zero edges, wrong winding, and proper crossings fail. Fixed-tree ledger
reproducers demand that even those duplicate cut endpoints disappear, independently
of whether a clipping-kernel change stops generating the affected tree.

## Limits

The exact fallback costs more than canonical comparison or sampling. Measure the PR
budget on the CI matrix before changing its default; never trade an inconclusive
certificate for a passing sample vote. The work budget does not interrupt a native
Clipper call: round-join float offsets remain excluded because they can produce huge
outputs or hang inside the kernel. Differential/corpus runs, native-call process
timeouts, and nightly scheduling are separate from these testitems.
