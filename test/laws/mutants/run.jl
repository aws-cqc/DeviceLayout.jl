# Mutation run: applies each mutant in turn and lists the GeomLaws checks it fails.
#
#     julia --project=. test/laws/mutants/run.jl [mutant ...]
#
# from the package root, with TestEnv in the default environment. The unmutated suite
# must pass first. `GEOMLAWS_EXAMPLES` and `GEOMLAWS_SEED` apply as usual.
using TestEnv
TestEnv.activate()
include(joinpath(@__DIR__, "runner.jl"))
include(joinpath(@__DIR__, "mutants.jl"))

selected = isempty(ARGS) ? sort(collect(keys(MUTANTS))) : Symbol.(ARGS)
restore!()
baseline = failing_checks(run_laws())
isempty(baseline) || error("the unmutated suite fails: $(join(baseline, ", "))")
println("seed ", GEOMLAWS_SEED, ", ", get(ENV, "GEOMLAWS_EXAMPLES", "50"), " examples")
for k in selected
    restore!()
    MUTANTS[k]()
    caught = failing_checks(run_laws())
    println(rpad(string(k), 28), isempty(caught) ? "NOT CAUGHT" : join(caught, ", "))
end
restore!()
