module Experimental

using SHA
import JSON
using Logging
using Unitful
using DeviceLayout
using DeviceLayout: Coordinate, GDSMeta, μm, ustrip
using ..SolidModels
import ..SolidModels: SolidModel

import DeviceLayout: datatype, gdslayer, layer, layerindex, name, render!

include("experimental/types.jl")
include("experimental/stack.jl")
include("experimental/registry.jl")
include("experimental/compiler.jl")
include("experimental/postprocess.jl")
include("experimental/serialization.jl")
include("experimental/artwork.jl")

export Material, METAL, DIELECTRIC, NULL
export Role, Generic, Locator, Terminal, Ground, Tag, Port, WavePort, LumpedPort
export SourceLayer, SourceStack, StackLevels, EntityMeta
export first_level, first_height, resolve_thickness
export physical_group_name, compile_layer_ops, exnboundaries
export serialize_metadata, write_metadata

end # module Experimental
