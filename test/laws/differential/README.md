# Differential harness

Scripts that run the same polygon operations in two DeviceLayout builds and classify
every difference between their outputs. They exist to evaluate a change of clipping
kernel, such as replacing Clipper1 with Clipper2 (#199). Some differences are expected,
such as vertex order or rounding. Any other difference means that one of the kernels is
wrong, and wherever the right answer is defined the harness says which. The scripts are
not part of the test suite.

Outputs are compared with the region comparisons of the law suite (see
[How outputs are compared](../README.md#how-outputs-are-compared)). Where two outputs
really differ, the harness decides which build is right by evaluating the operation
exactly at a point where they disagree, from the operands alone, without either kernel.

## Running

The two builds can't share a Julia process, since each links one clipping library
through DeviceLayout's `Clipper` dependency. A run is therefore three steps that share a
run directory, `RUN`:

```sh
# 1. Generate cases. Needs the test environment, for Supposition.
julia --project=. -e 'using TestEnv; TestEnv.activate();
    include("test/laws/differential/generate.jl")' -- RUN --cases 3000 \
    --corpus corpus/demo_qpu17.gds --corpus-cases 1400

# 2. Evaluate the cases in each build. Only evaluate.jl and exchange.jl are loaded.
julia --project=/path/to/reference  test/laws/differential/evaluate.jl RUN clipper1
julia --project=/path/to/candidate  test/laws/differential/evaluate.jl RUN clipper2

# 3. Classify. This uses neither kernel, so any checkout's test environment will do.
julia --project=. -t 4 --heap-size-hint=4G -e 'using TestEnv; TestEnv.activate();
    include("test/laws/differential/compare.jl")' -- RUN clipper1 clipper2
```

The labels (`clipper1` and `clipper2` here) name each build's output directory;
`compare.jl` takes the reference build's label first.

`generate.jl` takes `--seed` (default 20260908), `--cases` per generator family (200),
`--corpus` (a GDS file from `harvest.jl`, below), `--corpus-cases` (500), and
`--max-vertices` (300; larger corpus polygons are skipped and counted, because the exact
comparison is quadratic in edge count).

Evaluation writes each result as soon as it has it and skips cases already done, so an
interrupted or hung run can be restarted where it stopped. Keep the heap-size hint when
classifying: the rational arithmetic allocates heavily, and without the hint a
40 000-case corpus run grows to tens of GB before the garbage collector catches up. A
120 000-case generated run classifies in about 8 minutes on 8 threads; corpus runs with
300-vertex polygons take about 30 minutes single-threaded.

## Output

| File                                                           | Contents                                                                                                                                     |
|:-------------------------------------------------------------- |:-------------------------------------------------------------------------------------------------------------------------------------------- |
| `inputs/cases.txt`, `inputs/manifest.toml`                     | The operands as exact text (`repr` of each `Int` or `Float64`), and the seed and options                                                     |
| `outputs/<label>/results.txt`, `outputs/<label>/manifest.toml` | Each build's output contours, and the checkout, commit, kernel library, and Julia version that produced them                                 |
| `report.md`                                                    | Counts per class for each generator family and operation, the largest differences, and up to 40 cases from each of classes c, b, u, e, and i |
| `classified.tsv`                                               | One line per case                                                                                                                            |
| `findings.jl`                                                  | A Julia reproducer for every case in classes b and c                                                                                         |

## Classes

| Class | Meaning                                                                                                                          |
|:----- |:-------------------------------------------------------------------------------------------------------------------------------- |
| a0    | Identical vertex lists                                                                                                           |
| a1    | The same contours, up to vertex order, starting vertex, or collinear vertices                                                    |
| a2    | The same region, divided into contours differently (for example two touching outer contours versus an outer contour with a hole) |
| d     | Different regions, but every difference is within the case's tolerance of the output boundaries: rounding                        |
| b     | Different regions beyond the tolerance, and the exact answer agrees with the candidate: the reference is wrong                   |
| c     | Different regions beyond the tolerance, and the exact answer agrees with the reference: the candidate is wrong                   |
| u     | Different regions beyond the tolerance, but the exact answer is undefined at the point of disagreement (see below)               |
| i     | The tolerance check ran out of its work budget                                                                                   |
| v     | The outputs are too large to compare exactly                                                                                     |
| e     | At least one build threw an error                                                                                                |

The exact answer at a point q comes from the operation's definition, applied to the
operands: winding numbers under each fill rule for the boolean operations, and for
offsets by δ, dist(q, A) ≤ δ for growth or q ∈ A with dist(q, ∂A) ≥ |δ| for erosion. That
distance rule is exact for round joins. Miter and square joins differ from it near the
corners where the offset outline turns outward (convex corners when growing, reflex
corners when eroding), so within the miter limit 2|δ| of those corners the harness
treats the answer as undefined, as it does at points on an operand's boundary.

When the outputs differ beyond the tolerance, the comparison yields a point where they
disagree, and the exact answer there decides between b and c, or gives u. In
addition, every disagreement region whose centroid is farther than the tolerance from
both output boundaries is judged at its centroid, and the report counts how often the
exact answer sided with each build. A case is class c if the reference is right at the
witness or at any of those regions, even where the candidate is right at others. For
every case that differs, the report also gives the exact area of the symmetric
difference and its *depth*: the largest distance from a disagreement region's centroid
to the nearest output boundary, in grid units (1 for integer operands, 1 fm for
floats). Depth is a lower bound on how far apart the outputs are, and unlike area it
distinguishes a long sliver from a deep notch.

## Cases

`generate.jl` draws operands from the law suite's generators (integer, rectilinear, and
float pairs, fm-perturbed pairs, triples, polygon sets, and trees with a hole) and emits
the operations the laws cover: `union2d`, `intersect2d`, `difference2d`, and `xor2d`;
`union2d` of a set; `clip` with single and mixed fill rules; `offset` with miter and
square joins on every family and round joins on integer families; `clip_tiled`; and the
keyhole cuts of `to_polygons`. Round joins are left out on floats because two kernels'
arcs differ by up to their 1 nm arc tolerance, about 10⁶ grid units. Each case records
the tolerance at which the laws hold for its family, so `compare.jl` needs no knowledge
of the generators.

With `--corpus`, each real-design polygon is unioned alone, and paired with partners of
known relationship to it: copies shifted to overlap it, to share an edge of its bounding
box, and to touch a corner of its bounding box; a copy with an extra collinear vertex;
a sliver along an edge; and a copy with one vertex moved. Slivers and moved vertices
are 1 fm to 1 nm. Each polygon is also offset by 10 % of its smaller extent, both ways.

## Corpus

```sh
julia --project=. test/laws/differential/harvest.jl OUT.gds SOURCE...
```

Each `SOURCE` is a GDS file, or `demo-qpu17` to render the ExamplePDK DemoQPU17
example. Every source is flattened, its polygons are deduplicated by shape (so fill
patterns and repeated components count once), and the result is written as one flat
cell with a 1 nm database unit. `OUT.toml` records each source's SHA-256 and each
polygon's source, layer, datatype, and vertex count. Rendering uses the clipping kernel,
so harvest once and use the same file for every run. Write corpora harvested from
private designs outside the repository.
