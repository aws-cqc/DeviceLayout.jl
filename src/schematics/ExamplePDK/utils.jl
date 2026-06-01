# Functions useful for ExamplePDK but not suitable/ready for base DeviceLayout/SchematicDrivenLayout

"""
    tap!(path::Path, sty::Paths.SimpleCPW=laststyle(path); location=1)

Generate a new path branching off from an initial path.

Location should be `1` for a right-hand tap and `-1` for a left-hand tap.

To illustrate, we start with this input `path`, where the double arrow indicates
the forward direction from the endpoint:

    input path
        ⇑
    ███   ███
    ███   ███
    ███   ███

Then after `tap!`, the input path is modified and an output
path is returned as follows (with `location == 1`):

    input path
        ⇑
    ███   ███ ↕ sty.gap
    ███                            ⤒
    ███      ⇒ output path     sty.trace
    ███                            ⤓
    ███   ███ ↕ sty.gap
    ███   ███
    ███   ███
    ███   ███
"""
function tap!(path::Path, sty::Paths.SimpleCPW=laststyle(path); location=1)
    main_sty = laststyle(path)
    main_sty isa Paths.CPW || error("Last path style should be CPW for a CPW tap")
    main_trace = Paths.trace(main_sty, pathlength(path[end]))
    main_gap = Paths.gap(main_sty, pathlength(path[end]))
    # Add a virtual segment to get (next to) tap start
    norender = Paths.SimpleNoRender(main_trace + main_gap, virtual=true)
    straight!(path, Paths.extent(sty), norender)
    # Create tap path
    tap = Path(
        p1(path) - sign(location) * main_trace / 2 * Point(-sin(α1(path)), cos(α1(path))),
        α0=α1(path) - sign(location) * 90°,
        metadata=path.metadata,
        name=uniquename("tap")
    )
    straight!(tap, main_gap, sty)
    # Extend virtual segment the rest of the way
    straight!(path, Paths.extent(sty), norender)
    # Attach a rectangle to fill in the gap opposite the tap
    cs = CoordinateSystem(uniquename("tap_cut"), nm)
    place!(
        cs,
        centered(Rectangle(2 * Paths.extent(sty), laststyle(path).gap)),
        path.metadata
    )
    attach!(path, sref(cs), zero(main_gap), location=(-location))

    return tap
end

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
    rect_scaffold =
        centered(Rectangle(scaffold_width, h_ground_ground + 2 * scaffold_gap))
    place!(cs, rect_bridge, LayerVocabulary.BRIDGE)
    place!(cs, rect_scaffold, LayerVocabulary.BRIDGE_BASE)
    # Mesh/conformality control -- avoid stray 1D "staple" attachment points
    rect_control = intersect2d(rect_bridge, rect_scaffold)
    place!(cs, only_solidmodel(rect_control), LayerVocabulary.MESH_CONTROL)
    return cs
end

"""
    add_bridges!(schematic, bridge=FEEDLINE_BRIDGE; spacing=500μm, margin=50μm)

Example utility for adding bridges. Not optimized for microwave properties.

Finds all top-level `Path`s and `RouteComponent`s in `schematic`.
For `Path`s, places a bridge in the middle of any path segment with length of at least `margin`.
For `RouteComponent`s, places a bridge at every `spacing`, with no bridges within a margin of
`margin` from the start and end.
"""
function add_bridges!(schematic, bridge; spacing=500μm, margin=50μm)
    ref = sref(bridge)
    for idx in find_components(Path, schematic.graph, depth=1)
        path = component(schematic.graph[idx])
        contains(path.name, "launcher") && continue
        add_bridges!(path, bridge; margin)
    end
    for idx in find_components(RouteComponent, schematic.graph, depth=1)
        routecomp = component(schematic.graph[idx])
        path = SchematicDrivenLayout.path(routecomp)
        attach!(routecomp, ref, margin:spacing:(pathlength(path) - margin))
    end
end

"""
    add_bridges!(path::Path, bridge; margin=50μm)

Example utility for adding bridges. Not optimized for microwave properties.

Places a bridge in the middle of any path segment with length of at least `margin`.
"""
function add_bridges!(path::Path, bridge; margin=50μm)
    isnothing(bridge) && return
    ref = sref(bridge)
    for (i, pathnode) in enumerate(path)
        Paths.undecorated(pathnode.sty) isa Paths.SimpleCPW || continue
        pathlength(pathnode) < margin && continue
        attach!(path, ref, pathlength(pathnode) / 2, i=i)
    end
end

"""
    add_wave_ports!(floorplan::Schematic, nodes::Vector{ComponentNode}, sim_area::Rectangle,
                    wave_port_width::T, wave_port_layer::SemanticMeta)

Add wave port line segments where the path or route component `nodes` intersect `sim_area`. The line
segments will have a length of `wave_port_width` and will be placed in the `wave_port_layer` layer. No
wave port is placed for nodes that do not intersect `sim_area`.
"""
function add_wave_ports!(
    floorplan::Schematic,
    nodes::Vector{ComponentNode},
    sim_area::Rectangle,
    wave_port_width::T,
    wave_port_layer::SemanticMeta
) where {T}
    angle_tol = 1e-1
    for node in nodes
        # Check component type
        node_component = component(node)
        if isa(node_component, Path)
            path = deepcopy(node_component)
        elseif isa(node_component, RouteComponent)
            path = SchematicDrivenLayout.path(deepcopy(node_component))
            path.metadata = node_component.meta
        else
            @warn "Cannot place a wave port for node $(node.id) since it is not a Path or Route."
            continue
        end
        # Find intersection locations and directions
        trans = transformation(floorplan, node)
        intersections = path_intersections(path, trans, sim_area)
        isempty(intersections) &&
            @warn "Cannot place a wave port for node $(node.id) since it does not intersect the simulation area."

        # Create a line segment for each wave port along the domain x or y boundaries
        for (loc, dir, node_idx, t) in intersections
            # Warn if the intersection is in a curved segment
            if path.nodes[node_idx].seg isa Paths.BSpline ||
               !(Paths.curvature(path.nodes[node_idx].seg, t) ≈ Point(0 / nm, 0 / nm))
                @warn "Placing a wave port in curved segment of node $(node.id) can lead to erroneous results."
            end
            # Warn if the path intersection is not perpendicular to the domain boundary
            path_direction = Paths.direction(trans(path).nodes[node_idx].seg, t) % 360°
            if (
                dir == :x &&
                !isapprox_angle(90°, path_direction; atol=angle_tol) &&
                !isapprox_angle(270°, path_direction; atol=angle_tol)
            ) || (
                dir == :y &&
                !isapprox_angle(0°, path_direction; atol=angle_tol) &&
                !isapprox_angle(180°, path_direction; atol=angle_tol)
            )
                @warn "Placing a wave port in segment of node $(node.id) which is not perpendicular to the domain boundary can lead to erroneous results."
            end
            if dir == :x
                line = LineSegment(
                    Point(loc.x - wave_port_width / 2, loc.y),
                    Point(loc.x + wave_port_width / 2, loc.y)
                )
            else
                line = LineSegment(
                    Point(loc.x, loc.y - wave_port_width / 2),
                    Point(loc.x, loc.y + wave_port_width / 2)
                )
            end
            render!(floorplan.coordinate_system, only_simulated(line), wave_port_layer)
        end
    end
end

"""
    path_intersections(path::Path, transformation, bounding_box::Rectangle)

Find the locations where `path` intersects the `bounding_box`.
"""
function path_intersections(path::Path, trans, bounding_box::Rectangle)
    # Create path for the bounding_box edges.
    box_edges = Path(bounding_box.ll)
    box_width, box_height = width(bounding_box), height(bounding_box)
    edges_style = Paths.Trace(1nm)
    straight!(box_edges, box_width, edges_style)
    turn!(box_edges, "l", zero(box_width))
    straight!(box_edges, box_height, edges_style)
    turn!(box_edges, "l", zero(box_width))
    straight!(box_edges, box_width, edges_style)
    turn!(box_edges, "l", zero(box_width))
    straight!(box_edges, box_height, edges_style)

    # Ensure box_edges and path have the same type/units.
    box_edges = convert(typeof(path), box_edges)

    # Get intersections of the path with the bounding box path.
    intersections =
        unique(x -> x[3], sort(Intersect.prepared_intersections([trans(path), box_edges])))

    # Determine intersection direction (x or y) and return intersections
    out = []
    for intersection in intersections
        x, y = intersection[3][1], intersection[3][2]
        if (isapprox(x, bounding_box.ll.x) || isapprox(x, bounding_box.ur.x))
            dir = :y
        elseif (isapprox(y, bounding_box.ll.y) || isapprox(y, bounding_box.ur.y))
            dir = :x
        else
            continue
        end
        push!(out, (Point(x, y), dir, intersection[1][2], intersection[1][3]))
    end
    return out
end

@deprecate filter_params filter_parameters # For backward compatibility
# (No one should be using methods from ExamplePDK but just in case)

"""
    port_directions(sch::Schematic, ly::Symbol) -> Dict{Int, Union{String, Vector{Float64}}}

For every entity on layer `ly` in `sch.coordinate_system` that has been indexed
(i.e., `layerindex(metadata) != 0`) AND carries a [`WithDirection`](@ref) style in
its wrapper chain, return a dictionary mapping `layerindex(metadata) -> direction config value` suitable for Palace's `LumpedPort`/`WavePort` `Direction` field.

Direction config value is a string `"+X"`, `"-X"`, `"+Y"`, or `"-Y"` for axis-aligned orientations
(within `atol=1e-3` degrees of the nearest axis), or a unit vector `[dx, dy, 0.0]::Vector{Float64}`
for arbitrary orientations.

Must be called AFTER indexing has run. Typical usage is after `render!(sm, sch, target)` or `Cell(sch, target)` for a target whose `indexed_layers(target)`
includes `ly`. If no entities on `ly` are indexed or none carry `WithDirection`,
returns an empty `Dict`. This function does NOT call `index_layer!` itself.

# Example

```julia
render!(sm, sch, target)
dirs = port_directions(sch, :lumped_element)
# Dict(1 => "+Y", 2 => "-X")
```

See also: [`WithDirection`](@ref).
"""
function port_directions(sch::Schematic, ly::Symbol)
    dirs = Dict{Int, Union{String, Vector{Float64}}}()
    # Traverse all reachable coordinate systems in the schematic (the schematic's
    # own `coordinate_system` plus every reference descendant). `index_layer!`
    # places indexed entities onto per-node coordsyses, recording the node for
    # each index in `sch.index_dict[ly]` and setting in-component indices to 0.
    # Each `(cs, trans)` pair includes the accumulated reference transform;
    # applying it makes the returned direction reflect the entity's global orientation.
    for (cs, trans) in DeviceLayout.traversal(sch.coordinate_system)
        for (el, m) in zip(elements(cs), element_metadata(cs))
            layer(m) == ly || continue
            idx = layerindex(m)
            idx == 0 && continue
            dir = DeviceLayout.extract_direction(el)
            dir === nothing && continue
            haskey(dirs, idx) &&
                error("Repeated index $idx. Before calling `port_directions`, \
layer $ly should be indexed by rendering with a target whose `indexed_layers` \
include $ly (or indexed directly with `index_layer!`)")
            dirs[idx] = _direction_config(rotated_direction(dir, trans))
        end
    end
    return dirs
end

# Format a direction angle (CCW from +X, in degrees) as a Palace-compatible
# `Direction` config value. Axis-aligned directions return one of "+X", "-X", "+Y",
# "-Y"; off-axis returns a unit-vector [dx, dy, 0.0]. Input is normalized modulo 360°.
function _direction_config(angle; atol=1e-3)
    a_deg = mod(DeviceLayout.ustrip(°, angle), 360.0)
    abs(a_deg - 0.0) < atol && return "+X"
    abs(a_deg - 90.0) < atol && return "+Y"
    abs(a_deg - 180.0) < atol && return "-X"
    abs(a_deg - 270.0) < atol && return "-Y"
    abs(a_deg - 360.0) < atol && return "+X"
    return [cos(angle), sin(angle), 0.0]
end
