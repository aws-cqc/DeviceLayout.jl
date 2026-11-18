import DeviceLayout.SolidModelsExperimental: Locator, WavePort
# These helpers don't depend on the layer metadata, so they're shared with ExamplePDK.
import ..ExamplePDK: add_bridges!, wave_port_segments

"""
    add_wave_ports!(floorplan::Schematic, nodes::Vector{ComponentNode}, sim_area::Rectangle,
        wave_port_width)

Add a wave port wherever a path or route component in `nodes` crosses the edge of
`sim_area`, as found by `ExamplePDK.wave_port_segments`.

Each wave port is a `LineSegment` of length `wave_port_width` on the `:wave_port` layer,
centered on the crossing, with a [`WavePort`](@ref DeviceLayout.SolidModelsExperimental.WavePort)
locator named `"<node id>_wave_port_\$i"`, where `i` numbers the crossings of that node in
the order they are found.
"""
function add_wave_ports!(
    floorplan::Schematic,
    nodes::Vector{ComponentNode},
    sim_area::Rectangle,
    wave_port_width
)
    for (; node, index, location, segment) in
        wave_port_segments(floorplan, nodes, sim_area, wave_port_width)
        place!(floorplan.coordinate_system, segment, LayerRef(:wave_port))
        place!(
            floorplan.coordinate_system,
            Locator(location),
            WavePort(:wave_port, "$(node.id)_wave_port_$index")
        )
    end
end
