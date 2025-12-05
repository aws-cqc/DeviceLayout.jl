# To run this script
#
# open julia REPL in this directory.
# ] activate .
# ] instantiate # this will result in a lot of precompiling
# include("solidmodel.jl") # will compile then run, quite like you'll get complains to add things
# qpu17_solidmodel(schematic, target) # Will create the model, and mesh

using DeviceLayout,
    .SchematicDrivenLayout, .PreferredUnits, .SchematicDrivenLayout.ExamplePDK
using .ExamplePDK.LayerVocabulary

include("DemoQPU17.jl")

schematic, artwork = DemoQPU17.qpu17_demo(savegds=true)

place!(schematic.coordinate_system, bounds(schematic.coordinate_system), SIMULATED_AREA)

target = ExamplePDK.SINGLECHIP_SOLIDMODEL_TARGET
if length(target.rendering_options.retained_physical_groups) < 10
    ports = [("port_$i", 2) for i = 1:42]
    lumped_elements = [("lumped_element_$i", 2) for i = 1:34]
    append!(target.rendering_options.retained_physical_groups, ports, lumped_elements)
end

function qpu17_solidmodel(schematic, target)

    sm = SolidModel("demo"; overwrite=true)
    SolidModels.gmsh.option.set_number("General.Verbosity", 2)
    meshing_parameters = SolidModels.MeshingParameters(mesh_order=2)
    @time "Rendering to SolidModel" render!(sm, schematic, target; meshing_parameters, strict=:no)

    SolidModels.gmsh.option.set_number("Mesh.ElementOrder", 2)

    # There are defaults for these, but these are the two "high level" mesh modification
    # levels right now.

    # Must be less than 1, make smaller to refine next to model
    # SolidModels.mesh_scale(1.0)
    # Must be in [0,1], 0 is uniform, 1 is fastest growth geometrically possible.
    # SolidModels.mesh_grading_default(0.75)
    # SolidModels.gmsh.option.set_number("General.Verbosity", 5)
    @time "Generating 1D Mesh" SolidModels.gmsh.model.mesh.generate(1)
    @time "Generating 2D Mesh" SolidModels.gmsh.model.mesh.generate(2)
    @time "Generating 3D Mesh" SolidModels.gmsh.model.mesh.generate(3)

    # Can use SolidModels.gmsh to access any commands you might want from the gmsh julia API.
    return sm
end
