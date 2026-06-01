# QPU17 SolidModel
include("DemoQPU17.jl")
schematic, artwork = DemoQPU17.qpu17_demo(savegds=true)

using DeviceLayout,
    .SchematicDrivenLayout, .PreferredUnits, .SchematicDrivenLayout.ExamplePDK
using .ExamplePDK.LayerVocabulary
using FileIO

place!(schematic.coordinate_system, bounds(schematic.coordinate_system), SIMULATED_AREA)
target = ExamplePDK.SINGLECHIP_SOLIDMODEL_TARGET
if length(target.rendering_options.retained_physical_groups) < 10
    ports = [("port_$i", 2) for i = 1:42]
    lumped_elements = [("lumped_element_$i", 2) for i = 1:34]
    append!(target.rendering_options.retained_physical_groups, ports, lumped_elements)
end

sm = SolidModel("demo"; overwrite=true)
SolidModels.gmsh.option.set_number("General.Verbosity", 2)
@time render!(sm, schematic, target) # ~30 min => 1 hr with mesh control on bridges

DeviceLayout.save("qpu17.xao", sm)
# Verify port connectivity (~2 min)
# < 1s without staple detection
# But still >2 min with mesh control on bridges (only staples are from intersection XSTY), why?
# The bridges shouldn't need any isInside checks in that case because the bounding box checks fail
# So maybe those are expensive? Need to investigate, may still be room for improvement
# Otherwise might just leave QPU17 without the mesh control polygons
@time conn = SolidModels.check_port_connectivity(sm, ["port_$i" for i=1:42], ["metal"]; dim=2)
for i = 1:42
    port = "port_$i"
    component_node =  schematic.index_dict[:port][i]
    role = split(component_node.component.name, "_")[2]
    if role == "XY" || role == "RO"
        @assert conn[port] == :open "$role port $i is $(conn[port]); should be :open"
    elseif role == "Z"
        @assert conn[port] == :short "$role port $i is $(conn[port]); should be :short"
    else
        error("Invalid port role")
    end
end
println("All flux ports are `:short`, and all charge and readout ports are `:open`")

# mesh_order = 1
# SolidModels.mesh_order(mesh_order)
# SolidModels.gmsh.option.set_number("General.Verbosity", 3)
# @time SolidModels.gmsh.model.mesh.generate(1)
# @time SolidModels.gmsh.model.mesh.generate(2)
# @time SolidModels.gmsh.model.mesh.generate(3)
# meshfile = joinpath(@__DIR__, "qpu17_order$mesh_order.msh2")
# save(meshfile, sm)

# # Config
# attributes = SolidModels.attributes(sm)
# config = Dict(
#     "Problem" => Dict("Type" => "Eigenmode", "Verbose" => 2, "Output" => "postpro"),
#     "Model" => Dict(
#         "Mesh" => meshfile,
#         "L0" => 1e-6, # um is Palace default; record it anyway
#         "Refinement" => Dict(
#             "MaxIts" => 0 # Increase to enable AMR
#         )
#     ),
#     "Domains" => Dict(
#         "Materials" => [
#             Dict(
#                 # Vacuum
#                 "Attributes" => [attributes["vacuum"]],
#                 "Permeability" => 1.0,
#                 "Permittivity" => 1.0
#             ),
#             Dict(
#                 # Sapphire
#                 "Attributes" => [attributes["substrate"]],
#                 "Permeability" => [0.99999975, 0.99999975, 0.99999979],
#                 "Permittivity" => [9.3, 9.3, 11.5],
#                 "LossTan" => [3.0e-5, 3.0e-5, 8.6e-5],
#                 "MaterialAxes" => [[0.8, 0.6, 0.0], [-0.6, 0.8, 0.0], [0.0, 0.0, 1.0]]
#             )
#         ]
#     ),
#     "Boundaries" => Dict(
#         "PEC" => Dict(
#             "Attributes" => [attributes["metal"], attributes["exterior_boundary"]]
#         ),
#         "LumpedPort" => []
#     ),
#     "Solver" => Dict(
#         "Order" => 2,
#         "Eigenmode" => Dict("N" => 2, "Tol" => 1.0e-6, "Target" => 2, "Save" => 2),
#         "Linear" => Dict("Type" => "Default", "Tol" => 1.0e-7, "MaxIts" => 500)
#     )
# )

# for i = 1:42
#     node = schematic.index_dict[:port][i]
#     dirs = Dict(0.0° => "+X", 90.0° => "+Y", 180.0° => "-X", 270.0° => "-Y")
#     dir = dirs[rem(rotation(transformation(schematic, node)), 360°, RoundDown)]
#     push!(
#         config["Boundaries"]["LumpedPort"],
#         Dict(
#             "Index" => i,
#             "Attributes" => [attributes["port_$i"]],
#             "R" => 50,
#             "Direction" => dir
#         )
#     )
# end

# for i = 1:34
#     node = schematic.index_dict[:lumped_element][i]
#     dirs = Dict(0.0° => "+Y", 180.0° => "-Y")
#     dir = dirs[rem(rotation(transformation(schematic, node)), 360°, RoundDown)]
#     push!(
#         config["Boundaries"]["LumpedPort"],
#         Dict(
#             "Index" => 42 + i,
#             "Attributes" => [attributes["lumped_element_$i"]],
#             "L" => 28.0e-9 + i * 0.05e-9,
#             "C" => 2.75e-15,
#             "Direction" => dir
#         )
#     )
# end

# using JSON
# open(joinpath(@__DIR__, "config.json"), "w") do f
#     return JSON.print(f, config)
# end
