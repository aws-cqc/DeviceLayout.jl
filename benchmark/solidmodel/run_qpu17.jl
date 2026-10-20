# Large-scale SolidModel rendering and meshing benchmark on the DemoQPU17 example.
#
# Single-shot: one process, one render, one mesh per requested scale. The render alone takes
# tens of minutes, so this is not part of the BenchmarkTools `SUITE`; run it directly:
#
#   julia --project=benchmark benchmark/solidmodel/run_qpu17.jl [--out=results.json]
#       [--scales=1.0,0.5] [--order=1] [--skip-mesh]
#
# Results are written as JSON (default `benchmark/solidmodel/results/qpu17-<sha>-<timestamp>.json`)
# and compared across runs with `compare.jl`.

using DeviceLayout, DeviceLayout.SolidModels, DeviceLayout.PreferredUnits
using DeviceLayout.SchematicDrivenLayout, DeviceLayout.SchematicDrivenLayout.ExamplePDK
using .ExamplePDK.LayerVocabulary
using JSON

include(joinpath(@__DIR__, "common.jl"))
include(joinpath(pkgdir(DeviceLayout), "examples", "DemoQPU17", "solidmodel.jl"))

function qpu17_benchmark_setup()
    schematic, artwork, target = qpu17_solidmodel_setup(savegds=false, dir=mktempdir())
    return schematic, target, artwork
end

run_solidmodel_benchmark("qpu17", qpu17_benchmark_setup, parse_benchmark_args(ARGS))
