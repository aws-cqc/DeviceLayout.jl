import DeviceLayout.SolidModelsExperimental: Locator, WavePort
# These helpers don't depend on the layer metadata, so they're shared with ExamplePDK.
import ..ExamplePDK: add_bridges!, path_intersections

"""
    bridge_geometry(style::Paths.SimpleCPW)

Return a `CoordinateSystem` with a simple scaffolded bridge that spans `style`.
"""
function bridge_geometry(style::Paths.SimpleCPW)
    cs = CoordinateSystem(uniquename("bridge"))
    h_ground_ground = 2 * Paths.extent(style)
    bridge_width = 10μm
    scaffold_width = 16μm
    scaffold_gap = 5μm
    foot_length = 5μm
    rect_bridge = centered(
        Rectangle(bridge_width, h_ground_ground + 2 * (scaffold_gap + foot_length))
    )
    rect_scaffold = centered(Rectangle(scaffold_width, h_ground_ground + 2 * scaffold_gap))
    place!(cs, rect_bridge, LayerRef(:bridge))
    place!(cs, rect_scaffold, LayerRef(:bridge_base))
    return cs
end

"""
    add_wave_ports!(floorplan::Schematic, nodes::Vector{ComponentNode}, sim_area::Rectangle,
        wave_port_width)

Add a wave port wherever a path or route component in `nodes` crosses the edge of
`sim_area`.

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
    for node in nodes
        node_component = component(node)
        if node_component isa Path
            path = deepcopy(node_component)
        elseif node_component isa RouteComponent
            path = SchematicDrivenLayout.path(deepcopy(node_component))
        else
            @warn "Cannot place a wave port for node $(node.id) since it is not a Path or Route."
            continue
        end
        intersections = path_intersections(path, transformation(floorplan, node), sim_area)
        isempty(intersections) &&
            @warn "Cannot place a wave port for node $(node.id) since it does not intersect the simulation area."
        # A path can cross the simulation area more than once, so number its crossings.
        for (i, (loc, dir, _, _)) in enumerate(intersections)
            offset =
                dir == :x ? Point(wave_port_width / 2, zero(wave_port_width)) :
                Point(zero(wave_port_width), wave_port_width / 2)
            place!(
                floorplan.coordinate_system,
                LineSegment(loc - offset, loc + offset),
                LayerRef(:wave_port)
            )
            place!(
                floorplan.coordinate_system,
                Locator(loc),
                WavePort(:wave_port, "$(node.id)_wave_port_$i")
            )
        end
    end
end
