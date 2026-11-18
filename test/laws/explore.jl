# Exploratory GeomLaws run: the generative :geomlaws test items at a large example
# budget and a fresh seed, with Supposition's shrinker disabled. The shrinker has no
# time budget and has run for more than 20 h on one counterexample, while the unshrunk
# counterexample is already reproducible from the seed. The scheduled GeomLaws workflow
# runs this once per law file; locally, from the package root:
#
#     GEOMLAWS_EXAMPLES=2000 julia --project=. test/laws/explore.jl test_offset
#
# The optional argument selects law files whose name contains it; one process per file
# keeps memory bounded at large budgets. `GEOMLAWS_SEED` defaults to a random seed,
# printed first. To reproduce a failure, rerun with that seed and budget (and the
# argument), or run the failing item through TestItemRunner as in the README to shrink
# it. Requires TestEnv in the default environment.
using TestEnv
TestEnv.activate()
using TestItemRunner, Supposition
import DeviceLayout

Supposition.shrink!(::Supposition.TestState) = nothing

if get(ENV, "GEOMLAWS_SEED", "random") == "random"
    ENV["GEOMLAWS_SEED"] = string(rand(UInt32))
end
ENV["GEOMLAWS_EXAMPLES"] = get(ENV, "GEOMLAWS_EXAMPLES", "2000")
file = isempty(ARGS) ? "test_" : only(ARGS)
println(
    "GeomLaws exploration: GEOMLAWS_SEED=",
    ENV["GEOMLAWS_SEED"],
    " GEOMLAWS_EXAMPLES=",
    ENV["GEOMLAWS_EXAMPLES"],
    " files matching \"",
    file,
    "\""
)
TestItemRunner.run_tests(
    pkgdir(DeviceLayout);
    filter=ti -> :geomlaws in ti.tags && occursin(file, basename(ti.filename)),
    verbose=true
)
