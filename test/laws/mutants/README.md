# Mutants

Modeled defects for judging the GeomLaws suite by what it catches. `mutants.jl` defines
each mutant as a function that applies it by method redefinition: boolean and offset
mutants wrap the internal `_clip`/`_offset` through hooks; `interiorcuts` and halo
mutants re-evaluate edited copies of the source and fail if the edit no longer applies.
`runner.jl` runs the :geomlaws test items in process, so the redefinitions are seen
without re-precompiling, with shrinking disabled.

```sh
julia --project=. test/laws/mutants/run.jl                  # every mutant
julia --project=. test/laws/mutants/run.jl halo_short       # selected mutants
```

Run from the package root with TestEnv in the default environment. The unmutated suite
must pass first; each mutant then prints the checks it fails. Before adding a law or
generator, add the mutant it should catch and check that it does.

At the PR budget (50 examples, default seed) on Clipper1:

| mutant | models | caught by |
|---|---|---|
| `fill_hole_near_parent` | a hole with a vertex within a unit of its parent is filled (gate report §3.6) | B5, B6, B7, B9, B12, ledger |
| `fill_small_holes` | holes under 5 % of their parent are filled | B5, B6, B7, B12, O3, ledger |
| `drop_small_components` | components under 5 % of the largest vanish (L1, at scale) | B2, B5, B6, B7, B9, B10, B12 |
| `xor_touch_is_union` | xor of operands sharing a vertex returns the union | B4, B5, B7, B9, B12, ledger |
| `evenodd_subjects` | subjects filled even-odd instead of positive | B2, B3, B9, B10 |
| `hole_orientation` | holes returned counterclockwise | B2, B3, B5, B6, B8, B9, B11, ledger |
| `duplicate_vertex` | a repeated vertex in each outer contour | B3, B8, B11, B12, ledger |
| `erosion_largest_only` | erosion keeps only its largest component | O3 |
| `offset_fills_holes` | growth fills the cavity it encloses | O3 |
| `float_arc_100x` | float round joins 100× coarser than `atol` | O3, O6, O8 |
| `miter_limit_4` | miter limit 4δ instead of 2δ | none: no law claims a miter limit, and `offset` documents none |
| `cuts_forget_spliced_holes` | a later hole's ray ignores holes already cut in | B11, ledger |
| `cuts_drop_islands` | islands inside holes are dropped | B11 |
| `halo_short` | trace and CPW halos widened by 0.95δ | O7, ledger |

B1 and T1 catch none of these, since every mutant treats both operands alike and
commutes with rigid transforms.
