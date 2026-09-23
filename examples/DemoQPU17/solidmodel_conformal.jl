# QPU17 SolidModel — curve-preserving (conformal) render
#
# Companion to `solidmodel.jl`. It renders the SAME QPU17 design with the SAME
# `SolidModelTarget`, but calls `render_conformal!` instead of `render!`, so native
# curves (CPW turns, rounded corners) are kept as exact OCC arcs instead of being
# discretized to line-segment chords. The only line that differs from
# `solidmodel.jl` is the render call:
#
#     render!(sm, schematic, target)            # stock: OCC booleans, arcs → chords
#     render_conformal!(sm, schematic, target)  # conformal: curve-preserving booleans
#
# The target, its layers, ports, lumped elements, the `simulation` rendering option,
# and every physical-group name are authored exactly as for the stock flow and reused
# verbatim. `render_conformal!` forms the 2D metal from the target's curve-preserving
# `prerender_ops` (`union2d_curved!` / `difference2d_curved!`) instead of the OCC
# `postrender_ops`, nodes shared boundaries with `split_t_junctions!`, and emits via
# `render_conformal_groups!` so shared boundaries resolve to a single OCC curve.
# Fabrication-only fill (autofill ground-plane holes, `not_simulated`) is dropped for
# the simulation model, exactly as the stock render does.
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
# Scope: `render_conformal!(sm, schematic, target)` currently renders the 2D geometry
# (metal + device groups such as ports and lumped elements). The target's 3D
# operations (substrate/vacuum extrusion, bridges) are not yet applied on the
# conformal path; for a 3D simulation domain, extrude and mesh the result with the
# same machinery as `solidmodel.jl`.

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
