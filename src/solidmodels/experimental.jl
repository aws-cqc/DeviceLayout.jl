module Experimental

using SHA
import Graphs
import JSON
using Logging
import MetaGraphs
using Unitful
using DeviceLayout
using DeviceLayout: Coordinate, GDSMeta, μm, ustrip
using ..SolidModels
import ..SolidModels: SolidModel

import DeviceLayout: datatype, gdslayer, layer, layerindex, name, render!

include("experimental/entitymeta.jl")
include("experimental/stack.jl")
include("experimental/compiler.jl")
include("experimental/locators.jl")
include("experimental/postprocess.jl")
include("experimental/serialization.jl")

export Material, METAL, DIELECTRIC, NULL
export Role, Generic, Locator, Terminal, Ground, Tag, Port, WavePort, LumpedPort
export SourceLayer, SourceStack, EntityMeta
export sourcelayer, layer_z, thickness
export physical_group_name, compile_layer_ops, exterior_boundaries
export serialize_metadata, write_metadata

end # module Experimental
