# Single-transmon SolidModel rendering and meshing benchmark (~1 min). Same options and output
# format as `run_qpu17.jl`; see `single_transmon.jl` for the workload.

using DeviceLayout, DeviceLayout.SolidModels, DeviceLayout.PreferredUnits
using JSON

include(joinpath(@__DIR__, "common.jl"))
include(joinpath(@__DIR__, "single_transmon.jl"))

function single_transmon_benchmark_setup()
    floorplan, target = single_transmon_setup()
    return floorplan, target, nothing
end

run_solidmodel_benchmark(
    "single_transmon",
    single_transmon_benchmark_setup,
    parse_benchmark_args(ARGS)
)
