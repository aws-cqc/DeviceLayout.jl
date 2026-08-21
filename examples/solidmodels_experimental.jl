# Minimal example of the experimental solid model pipeline. 
using DeviceLayout
using DeviceLayout.SchematicDrivenLayout
using DeviceLayout.SolidModels
using DeviceLayout.SolidModelsExperimental
using FileIO
import JSON
import Unitful: μm

build_dir = joinpath(@__DIR__, "build", "solidmodels_experimental")
mkpath(build_dir)

geometry = CoordinateSystem("device", μm)
place!(geometry, centered(Rectangle(100μm, 60μm)), EntityMeta(:metal; name="island"))
place!(
    geometry,
    WithDirection(π / 2)(Rectangle(Point(55μm, -10μm), Point(60μm, 10μm))),
    EntityMeta(:port; name="drive", role=LumpedPort)
)

component = BasicComponent(geometry)
graph = SchematicGraph("solidmodels_experimental")
add_node!(graph, component; base_id="q1")
schematic = plan(graph; log_dir=build_dir)
check!(schematic)

stack = SourceStack(
    :metal => SourceLayer(NULL; level=1, gds_meta=GDSMeta(10, 0)),
    :port => SourceLayer(NULL; level=1, gds_meta=GDSMeta(11, 0));
    levels=(1 => 0μm,)
)
target = SolidModelsExperimental.SolidModelTarget(stack)

solid_model = SolidModel("solidmodels_experimental"; overwrite=true)
metadata = render!(solid_model, schematic, target)
open(joinpath(build_dir, "sm_metadata.json"), "w") do io
    return JSON.print(io, metadata, 4)
end
DeviceLayout.save(joinpath(build_dir, "model.xao"), solid_model)
SolidModels.gmsh.model.mesh.generate(2)
save(joinpath(build_dir, "model.msh2"), solid_model)

artwork = Cell("solidmodels_experimental", μm)
render!(artwork, geometry, stack)
save(joinpath(build_dir, "artwork.gds"), artwork)

println("Experimental artifacts written to $build_dir")
