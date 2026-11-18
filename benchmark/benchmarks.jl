using Test, BenchmarkTools
using DeviceLayout, Pkg, FileIO, Unitful, DeviceLayout.PreferredUnits
using DeviceLayout.SchematicDrivenLayout
import Random: default_rng, rand, seed!
import Logging: NullLogger, with_logger

const um = μm
const SUITE = BenchmarkGroup()

include("autofill.jl")
include("bounds.jl")
include("clipping.jl")
include("curves.jl")
include("intersect.jl")
include("polygons.jl")
include("schematic.jl")
