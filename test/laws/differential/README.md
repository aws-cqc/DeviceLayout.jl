# Differential harness

Compares two clipping kernels on identical inputs and classifies every disagreement
by region, using the exact predicates from `../lawslib.jl` as the referee. This is
the Clipper1 → Clipper2 gate artifact (plan §5.5/§6); it is not part of the test
suite.

The two kernels cannot share a process (the Clipper2 shim replaces the `Clipper`
dependency), so the run is three steps over a run directory:

```sh
# 1. generate cases (needs the test environment for Supposition)
julia --project=. -e 'using TestEnv; TestEnv.activate();
    include("test/laws/differential/generate.jl")' -- RUN --cases 3000 \
    --corpus corpus/demo_qpu17.gds --corpus-cases 1400

# 2. evaluate in each worktree; only evaluate.jl and exchange.jl are loaded there
julia --project=/path/to/main  test/laws/differential/evaluate.jl RUN clipper1
julia --project=/path/to/shim  test/laws/differential/evaluate.jl RUN clipper2

# 3. classify (kernel-independent; any worktree's test environment)
julia --project=. -t 4 --heap-size-hint=4G -e 'using TestEnv; TestEnv.activate();
    include("test/laws/differential/compare.jl")' -- RUN clipper1 clipper2
```

The comparison's rational arithmetic allocates heavily: keep the heap-size hint, or the
process grows to tens of GB on a 40 000-case corpus run before the collector catches up.
A 120 000-case generated run classifies in ~8 minutes on 8 threads; corpus runs with
300-vertex polygons take about 30 minutes single-threaded.

`RUN/inputs/cases.txt` holds the operands as exact text (`repr` of `Int`/`Float64`),
`RUN/outputs/<label>/results.txt` each kernel's contours, and `compare.jl` writes
`RUN/report.md`, `RUN/classified.tsv`, and `RUN/findings.jl` (Julia reproducers for
every case where a kernel is provably wrong). Evaluation appends and flushes per case
and skips cases already present, so a kernel hang loses nothing.

## Cases

`generate.jl` draws from the law generators (`int_pair`, `int_rectilinear_pair`,
`float_star_pair`, `float_perturbed_pair`, triples, polygon sets, holed trees) and
emits the operations the laws cover: `union2d`/`intersect2d`/`difference2d`/`xor2d`,
`union2d` of a set, `clip` with single and mixed fill rules, `offset` (miter/square
on all families, round on integer families only — see `../test_offset.jl`),
`clip_tiled`, and `to_polygons` keyhole cutting of a kernel tree. Each case records
the tolerance at which the laws hold on that family, so `compare.jl` needs no
knowledge of the generator.

With `--corpus`, real-design polygons from a harvested GDS (`harvest.jl`) are paired
with a constructed partner (overlap, shared bounding-box edge, vertex touch, collinear
split, fm/nm sliver, fm-perturbed vertex) and offset by 10 % of their smaller extent.
Polygons above `--max-vertices` are skipped and counted: the exact arrangement is
quadratic in edge count.

## Classes

| class | meaning |
|---|---|
| a0 | identical vertex lists |
| a1 | same canonical contours: vertex order, start vertex, or collinear vertices differ |
| a2 | same region, different decomposition (e.g. two touching outers vs outer + hole) |
| d | regions differ within the case tolerance of the output boundaries (rounding) |
| b | regions differ beyond tolerance; the exact oracle sides with the candidate |
| c | regions differ beyond tolerance; the exact oracle sides with the reference — a candidate regression |
| u | regions differ beyond tolerance; the oracle is undecided at the witness (within the miter limit of a join vertex, or on an operand boundary) |
| i | the tolerance certificate exhausted its work budget |
| v | output too large for the exact arrangement |
| e | a kernel raised an error |

The oracle evaluates the operation's semantics at a rational witness point inside a
disagreement cell from the operands alone: fill-rule winding numbers for booleans,
`dist(q, A) ≤ δ` (or `q ∈ A ∧ dist(q, ∂A) ≥ |δ|`) for offsets. Miter and square
joins differ from that distance oracle only within the miter limit `2|δ|` of the
vertices where the outline turns convexly (convex vertices for δ > 0, reflex for
δ < 0); witnesses there are undecided. For every differing case the report also gives
the exact symmetric-difference area and the *depth*: the largest distance from a
disagreement cell's centroid to the nearest output boundary, a lower bound on how far
the two regions are apart in lattice units (1 unit for integer operands, 1 fm for
floats) that, unlike the area, distinguishes a long sliver from a deep notch.

## Corpus

`harvest.jl OUT.gds SOURCE...` loads each GDS (or renders `demo-qpu17`), flattens it,
deduplicates polygons by shape, and writes one flat cell at 1 nm database units with
an `OUT.toml` provenance manifest (source SHA-256, layer/datatype and vertex count per
polygon, producing worktree). Rendering uses the kernel, so harvest once and share
the file between runs. Corpora from internal designs stay outside the repository.
