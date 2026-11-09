# Single-transmon SolidModel rendering and meshing benchmark (~1 min) on the geometry of
# `examples/SingleTransmon`. Same options and output format as `run_qpu17.jl`.

using DeviceLayout, DeviceLayout.SolidModels, DeviceLayout.PreferredUnits
using JSON

include(joinpath(@__DIR__, "common.jl"))
include(joinpath(pkgdir(DeviceLayout), "examples", "SingleTransmon", "schematic.jl"))

function single_transmon_benchmark_setup()
    floorplan, target = single_transmon_schematic(; log_dir=mktempdir())
    return floorplan, target, nothing
end

run_solidmodel_benchmark(
    "single_transmon",
    single_transmon_benchmark_setup,
    parse_benchmark_args(ARGS)
)
