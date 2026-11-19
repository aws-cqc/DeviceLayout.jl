# Compare two result files written by `run_benchmarks.jl`: the same suite run against a
# base and a head checkout, ideally back-to-back on the same machine (timings from
# different machines or GitHub runners are not comparable).
#
#   julia --project=benchmark benchmark/compare.jl base.json head.json
#
# Prints PkgBenchmark's markdown judgement of head against base, listing every benchmark
# the two runs share. Time ratios use the minimum over samples, the estimator least
# affected by other load on the machine. A ratio is marked as a possible regression or
# improvement when it differs from 1 by more than the benchmark's `time_tolerance` (5% by
# default) or `memory_tolerance` (1%). The exit status does not depend on the result:
# with a few dozen benchmarks at these tolerances, some run-to-run noise gets flagged even
# when base and head are the same commit.
using PkgBenchmark

length(ARGS) == 2 || error("usage: compare.jl base.json head.json")
base, head = readresults.(ARGS)
export_markdown(stdout, judge(head, base); export_invariants=true)
