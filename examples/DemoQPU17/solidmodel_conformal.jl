# QPU17 SolidModel — conformal render
#
# Companion to `solidmodel.jl`. It renders the same QPU17 design with the same
# `SolidModelTarget`, but with `render_conformal!` instead of `render!`:
#
#     render!(sm, schematic, target)            # a fragment pass makes shared boundaries conformal
#     render_conformal!(sm, schematic, target)  # an edge cache does, without a fragment pass
#
# `render_conformal!` forms the 2D groups with the target's curve-preserving
# `prerender_ops` (`union2d_curved!` / `difference2d_curved!`) instead of its
# `postrender_ops`, nodes shared boundaries with `split_t_junctions!`, splits self-touching
# contours with `split_pinches`, and emits the groups with `render_conformal_groups!`.
# Fabrication-only fill (`not_simulated`) is dropped for the simulation model, as in
# `render!`.
#
# To run this script:
#
#   Open a Julia REPL in this directory, then:
#     ] activate .
#     ] instantiate
#     include("solidmodel_conformal.jl")
#
#   Then drive it interactively:
#     sm = qpu17_solidmodel_conformal(schematic, target)
#     DeviceLayout.save(joinpath(@__DIR__, "qpu17_conformal.xao"), sm)
#
# Scope: `render_conformal!(sm, schematic, target)` renders 2D geometry: the metal, ports
# and lumped elements. The target's 3D operations (substrate and vacuum extrusion, bridges)
# are not run.

using DeviceLayout,
    .SchematicDrivenLayout,
    .PreferredUnits,
    .SchematicDrivenLayout.ExamplePDK
using .ExamplePDK.LayerVocabulary
using FileIO

include("DemoQPU17.jl")

schematic, artwork = DemoQPU17.qpu17_demo(savegds=true)

place!(schematic.coordinate_system, bounds(schematic.coordinate_system), SIMULATED_AREA)

target = ExamplePDK.SINGLECHIP_SOLIDMODEL_TARGET
if length(target.rendering_options.retained_physical_groups) < 10
    ports = [("port_$i", 2) for i = 1:42]
    lumped_elements = [("lumped_element_$i", 2) for i = 1:34]
    append!(target.rendering_options.retained_physical_groups, ports, lumped_elements)
end

function qpu17_solidmodel_conformal(schematic, target)
    sm = SolidModel("demo_conformal"; overwrite=true)
    SolidModels.gmsh.option.set_number("General.Verbosity", 2)
    @time "Conformal render" render_conformal!(sm, schematic, target)
    return sm
end

# When run non-interactively, produce the geometry and save it.
if abspath(PROGRAM_FILE) == @__FILE__
    sm = qpu17_solidmodel_conformal(schematic, target)
    out = joinpath(@__DIR__, "qpu17_conformal.xao")
    DeviceLayout.save(out, sm)
    @info "Wrote $out"
end
