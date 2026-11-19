# Run the BenchmarkTools suite in `benchmarks.jl` against whichever DeviceLayout the
# `benchmark` environment points to.
#
#   julia --project=benchmark benchmark/run_benchmarks.jl [--out=benchmark.json]
#
# Writes the PkgBenchmark results to `--out` (the input format of `compare.jl`) and a
# markdown report alongside it with extension `.md`, and prints the report.
#
# The suite always comes from this directory, not from the package checkout under test, so
# `Pkg.develop`ing another checkout into the environment runs the same benchmarks against
# it. PkgBenchmark still reads `benchmark/tune.json` from that checkout (it has no option
# to override it), which matters only if the two checkouts' tuning files differ.
using PkgBenchmark
using UnicodePlots, Statistics

out = "benchmark.json"
for a in ARGS
    if startswith(a, "--out=")
        global out = a[7:end]
    else
        error("usage: run_benchmarks.jl [--out=benchmark.json]")
    end
end
mkpath(dirname(abspath(out)))

include(joinpath(dirname(@__FILE__), "data", "generate_data.jl"))
bench = benchmarkpkg(
    "DeviceLayout";
    script=joinpath(dirname(@__FILE__), "benchmarks.jl"),
    resultfile=out
)
export_markdown(splitext(out)[1] * ".md", bench)
export_markdown(stdout, bench)

diff2dgroup = bench.benchmarkgroup["clipping"]["difference2d"]

for series in ("square",)
    N = Vector{Float64}(undef, 0)
    t = Vector{Float64}(undef, 0)
    for k in keys(diff2dgroup)
        n, v = split(k, '_')
        if v == series
            push!(N, parse(Float64, n))
            push!(t, median(diff2dgroup[k].times) / 1e9)
        end
    end
    idx = sortperm(N)
    display(lineplot(N[idx], t[idx]))
end
