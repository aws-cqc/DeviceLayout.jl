# Minimal example of the experimental solid model pipeline. 
using DeviceLayout
using DeviceLayout.SchematicDrivenLayout
using DeviceLayout.SolidModels
using DeviceLayout.SolidModels.Experimental
using FileIO
import Unitful: μm

build_dir = joinpath(@__DIR__, "build", "experimental_solidmodel")
mkpath(build_dir)

geometry = CoordinateSystem("device", μm)
place!(geometry, centered(Rectangle(100μm, 60μm)), EntityMeta(:metal; name="island"))
place!(
    geometry,
    WithDirection(π / 2)(Rectangle(Point(55μm, -10μm), Point(60μm, 10μm))),
    EntityMeta(:port; name="drive", role=LumpedPort)
)

component = BasicComponent(geometry)
graph = SchematicGraph("experimental_solidmodel")
add_node!(graph, component; base_id="q1")
schematic = plan(graph; log_dir=build_dir)
check!(schematic)

levels = StackLevels(1 => 0μm)
stack = SourceStack(
    :metal => SourceLayer(NULL; level=1, gds_meta=GDSMeta(10, 0)),
    :port => SourceLayer(NULL; level=1, gds_meta=GDSMeta(11, 0))
)
target = DeviceLayout.SolidModels.Experimental.SolidModelTarget(levels, stack)

model = SolidModel("experimental_solidmodel"; overwrite=true)
metadata = render!(model, schematic, target)
write_metadata(joinpath(build_dir, "sm_metadata.json"), metadata)
DeviceLayout.save(joinpath(build_dir, "model.xao"), model)
SolidModels.gmsh.model.mesh.generate(2)
save(joinpath(build_dir, "model.msh2"), model)

artwork = Cell("experimental_solidmodel", μm)
render!(artwork, geometry, stack)
save(joinpath(build_dir, "artwork.gds"), artwork)

println("Experimental artifacts written to $build_dir")
