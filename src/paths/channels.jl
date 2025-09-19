# Channel intersection graph
using Graphs

import DeviceLayout
import DeviceLayout: °, Align, Cell, Coordinate, GDSMeta, Hook, NoUnits, Path, Paths, Point, PointHook, Polygon, Rectangle, circle, render!, text!, uconvert, width, height
import DeviceLayout.Paths: StraightAnd90, Route, Trace
import LinearAlgebra: norm

# ChannelWireSegment = (net, lengthwise space, (start vertex, end vertex))
# vertex is the space index or, if the start/end is a pin, the graph index for that pin
struct ChannelWireSegment
    net_index::Int
    running_space::Int
    start_vertex::Int
    stop_vertex::Int
end

bounding_spaces(ws::ChannelWireSegment) = (ws.start_vertex, ws.stop_vertex)
net_index(ws::ChannelWireSegment) = ws.net_index
running_space(ws::ChannelWireSegment) = ws.running_space

const Channel = Vector{ChannelWireSegment}
const NetWire = Vector{ChannelWireSegment}
const ChannelSpace = Paths.Node
# pathlength 1, pathlength 2, intersection point
const IntersectionInfo{T} = Tuple{T, T, Point{T}}

"""

  - `(path_idx_1, node_idx_1, pathlength_ixn_1)`

      + The index in `paths` of the first `Path` involved in the intersection
      + The index of the intersecting `Node` in that `Path`
      + The length along that node's `Paths.Segment` at which the intersection occurs

  - `(path_idx_2, node_idx_2, pathlength_ixn_2)`

      + As above, for the second `Path` involved in the intersection
  - The intersection point _on the discretized paths_
"""
struct SpaceIntersection{T <: Coordinate}
    location_1::Tuple{Int, Int, T}
    location_2::Tuple{Int, Int, T}
    p::Point{T}
end

"""
    ChannelRouter{T <: Coordinate}
    ChannelRouter(
        nets,
        pins,
        pin_directions,
        pin_adjoining_spaces,
        space_coords,
        space_coord_indices,
        space_widths
    )

A simple autorouter where wires can run on horizontal and vertical channels.

The router will attempt to connect pairs of pins, each with coordinates and a direction.
The indices of connected pins are specified by `nets`.

The router is initialized with a number of vertical and horizontal "spaces", characterized
by a width and the coordinate of their center line. Each space will be divided into some
number of channels as necessary to route all nets.

Routing proceeds in two steps. The first is "space assignment", which proceeds net by net,
finding a path between pins described in terms of the spaces the path uses. The second step
is "channel assigment", which proceeds space by space. Wire segments are assigned to
channels within the space such that wire segments in the same channel do not overlap.

# Arguments

  - `nets::Vector{Tuple{Int,Int}}`: A list specifying which pairs of pins are connected
  - `pins`: The coordinates of those pins
  - `pin_directions`: The angles the pins make with the x-axis
  - `pin_adjoining_spaces`: The perpendicular spaces adjoining the pins
  - `space_coords`: The coordinate of the center line along each space (the "fixed" coordinate)
  - `space_coord_indices`: The index of the fixed coordinate; that is, 1 for vertical spaces
    which have fixed `x` and run along `y`
  - `space_widths`: The widths of the spaces
"""
mutable struct ChannelRouter{T <: Coordinate}
    space_graph::SimpleGraph{Int}     # Spaces/pins are vertices, intersections are edges
    net_pins::Vector{Tuple{Int, Int}} # Pairs of pins (indices in `pins`)
    net_wires::Vector{NetWire}        # Wire segments connecting pins for each net
    pins::Vector{PointHook{T}}        # Position and orientation of pins
    spaces::Vector{ChannelSpace{T}}   # List of spaces
    # space_capacities::Vector{Int}   # Maximum number of channels per space
    # For each edge, information to find the intersection point
    space_intersections::Dict{Tuple{Int, Int}, IntersectionInfo{T}}
    space_segments::Vector{Vector{ChannelWireSegment}}
    space_channels::Vector{Vector{Channel}}
    segment_waypoints::Dict{ChannelWireSegment, PointHook{T}}
end

function ChannelRouter(
    nets,
    pin_hooks::Vector{<:Hook},
    space_paths::Vector{<:Path}
)
    T = promote_type(coordinatetype(pin_hooks), coordinatetype(space_paths))
    net_wires = [NetWire() for i in eachindex(nets)]
    space_segments = [ChannelWireSegment[] for i in eachindex(space_paths)]
    space_channels = [Channel[] for i in eachindex(space_paths)]
    segment_waypoints = Dict{ChannelWireSegment, PointHook{T}}()
    pins = [PointHook{T}(pin.p, pin.in_direction + 180°) for pin in pin_hooks]
    space_graph, ixns = build_space_graph(pins, space_paths, T)
    # Simplify after space graph construction to avoid CompoundSegment operations
    spaces = [simplify(convert(Path{T}, path)) for path in space_paths]
    return ChannelRouter{T}(
        space_graph,
        nets,
        net_wires,
        pins,
        spaces,
        ixns,
        space_segments,
        space_channels,
        segment_waypoints
    )
end

Base.broadcastable(x::ChannelRouter) = Ref(x)
num_spaces(ar::ChannelRouter) = length(ar.spaces)
num_nets(ar::ChannelRouter) = length(ar.net_pins)
num_pins(ar::ChannelRouter) = length(ar.pins)

space_graph(ar::ChannelRouter) = ar.space_graph
net_pins(ar::ChannelRouter, net) = ar.net_pins[net]
net_wire(ar::ChannelRouter, net) = ar.net_wires[net]
pin_coordinates(ar::ChannelRouter, pin) = ar.pins[pin].p
pin_direction(ar::ChannelRouter, pin) = ar.pins[pin].in_direction
space_coordinates(ar::ChannelRouter, space, s) = ar.spaces[space].seg(s)
function space_direction(ar::ChannelRouter, space, s)
    is_pin(ar, space) && return pin_direction(ar, graphidx_to_pin(ar, space))
    return direction(ar.spaces[space].seg, s)
end
space_segments(ar::ChannelRouter, space) = ar.space_segments[space]
space_channels(ar::ChannelRouter, space) = ar.space_channels[space]
num_channels(ar::ChannelRouter, space) = length(ar.space_channels[space])
pin_to_graphidx(ar::ChannelRouter, p::Int) = p + num_spaces(ar)
graphidx_to_pin(ar::ChannelRouter, graphidx::Int) = graphidx - num_spaces(ar)
is_pin(ar::ChannelRouter, graphidx) = graphidx > num_spaces(ar)
adjoining_space(ar::ChannelRouter, pin) =
    neighbors(space_graph(ar), pin_to_graphidx(ar, pin))[1]
space_intersection(ar, s1, s2) = ar.space_intersections[_swap(s1, s2)]
function pathlength_at_intersection(ar::ChannelRouter{T},
    running_space,
    intersecting_space) where {T}
    # Intersecting space is zero where a wire segment hits a pin
    if iszero(running_space) || iszero(intersecting_space)
        return zero(T)
    end
    ixn_info = space_intersection(ar, running_space, intersecting_space)
    running_space < intersecting_space && return ixn_info[1]
    return ixn_info[2]
end

# pin_perp_coord(ar::ChannelRouter, pin) =
#     pin_coordinates(ar, pin)[space_running_coordidx(ar, adjoining_space(ar, pin))]
# pin_par_coord(ar::ChannelRouter, pin) =
#     pin_coordinates(ar, pin)[space_fixed_coordidx(ar, adjoining_space(ar, pin))]
# space_coordinate(ar::ChannelRouter, space) = ar.space_coords[space]
# space_coordinate(ar::ChannelRouter, ws::ChannelWireSegment) =
#     ar.space_coords[running_space(ws)]
segment_waypoint(ar::ChannelRouter, ws::ChannelWireSegment) = ar.segment_waypoints[ws]
_swap(x, y) = (y > x ? (x, y) : (y, x))

pathlength_from_start(space, node, s) = pathlength(space[1:node-1]) + s

# Build graph with pins/spaces as vertices and intersections as edges
function build_space_graph(pins, spaces, T)
    g = SimpleGraph(length(spaces) + length(pins))
    intersection_dict = Dict{Tuple{Int, Int}, IntersectionInfo{T}}()

    # Create segments extending from pins
    bbox = bounds(bounds(spaces), bounds(Polygon(DeviceLayout.getp.(pins))))
    ray_length = max(width(bbox), height(bbox))*sqrt(2)
    pin_rays = Path{T}[]
    for pin in pins
        path = Path{T}(pin.p, pin.in_direction)
        straight!(path, ray_length, Paths.NoRender())
        push!(pin_rays, path)
    end

    # Add edges for intersections between spaces
    intersections = DeviceLayout.Intersect.prepared_intersections(
        [spaces..., pin_rays...])
    pin_ixns = Dict{Int, Tuple{Int, IntersectionInfo{T}}}()
    for ixn in intersections
        location_1, location_2, p = ixn
        v1_idx, node1_idx, s1 = location_1
        v2_idx, node2_idx, s2 = location_2
        if v1_idx >= v2_idx
            # `prepared_intersections` guarantees v2 >= v1
            @assert v1_idx == v2_idx
            # We will also ignore self-intersecting spaces v2 == v1
            @info "Ignoring self-intersection of space $v1_idx"
            continue
        elseif v1_idx > length(spaces) && v2_idx > length(spaces)
            # Both are pins, ignore intersection
            continue
        elseif v2_idx > length(spaces) # v2 is a pin
            s1 = pathlength_from_start(spaces[v1_idx], node1_idx, s1)
            # Record intersection if it's the closest so far
            ixn_info = (s1, s2, p)
            _, old_ixn_info = get(pin_ixns, v2_idx,
                (v1_idx, ixn_info))
            old_distance = old_ixn_info[2]
            if s2 <= old_distance
                pin_ixns[v2_idx] = (v1_idx, ixn_info)
            end
        else # record intersection as edge in space graph, with info in dict
            s1 = pathlength_from_start(spaces[v1_idx], node1_idx, s1)
            s2 = pathlength_from_start(spaces[v2_idx], node2_idx, s2)

            add_edge!(g, v1_idx, v2_idx)
            intersection_dict[(v1_idx, v2_idx)] = # All records have v1 < v2
                (s1, s2, p)
        end
    end
    # Add min distance edge for each pin
    for pin_idx in (length(spaces)+1):(length(spaces) + length(pins))
        orig_idx = pin_idx - length(spaces)
        !haskey(pin_ixns, pin_idx) && error("The ray from pin $(orig_idx) ($(pins[orig_idx])) does not intersect any space")
        space_idx, ixn_info = pin_ixns[pin_idx]
        add_edge!(g, (space_idx, pin_idx))
        intersection_dict[(space_idx, pin_idx)] = ixn_info
    end

    return g, intersection_dict
end

"""
    print_segments(ar::ChannelRouter, net)

Print the information for the wire segments in `net` in a human-readable format.
"""
function print_segments(ar::ChannelRouter, net)
    for (i, ws) in pairs(net_wire(ar, net))
        s1, s2 = bounding_spaces(ws)
        space_names = [
            is_pin(ar, s1) ? "Pin $(graphidx_to_pin(ar, s1))" : "Space $s1",
            is_pin(ar, s2) ? "Pin $(graphidx_to_pin(ar, s2))" : "Space $s2"
        ]
        println(
            """
    Segment $i:
        Runs along Space $(running_space(ws)), Channel $(segment_channel(ar, ws))
        From $(space_names[1]) to $(space_names[2])
        Through waypoint $(segment_waypoint(ar, ws)[1]) at $(segment_waypoint(ar, ws)[2])
    """
        )
    end
end

"""
    segment_channel(ar::ChannelRouter, ws::ChannelWireSegment)

The channel index of `ws`, or `nothing` if no channel has been assigned.
"""
function segment_channel(ar::ChannelRouter, ws::ChannelWireSegment)
    space_idx = running_space(ws)
    channels = space_channels(ar, space_idx)
    channel_idx = findfirst((c) -> ws in c, channels)
    return channel_idx
end

"""
    segment_midpoint(ar::ChannelRouter, ws::ChannelWireSegment)

The midpoint of the segment `ws` between `bounding_spaces(ws)`.

If `ws` has been assigned a channel, uses the segment along that channel.
"""
function segment_midpoint(ar::ChannelRouter{T}, ws::ChannelWireSegment) where {T}
    space_idx = running_space(ws)
    s0, s1 = interval(ar, ws)
    s = (s0+s1)/2
    if is_pin(ar, space_idx)
        dir = pin_direction(ar, graphidx_to_pin(ar, space_idx))
        return pin_coordinates(ar, graphidx_to_pin(ar, space_idx)) +
            s * Point(cos(dir), sin(dir))
    end
    channels = space_channels(ar, space_idx)
    channel_idx = findfirst((c) -> ws in c, channels)
    space_midpoint = space_coordinates(ar, space_idx, s)

    offset_distance = if isnothing(channel_idx)
        zero(T)
    else
        channel_offset(ar, space_idx, channel_idx) # No tapers for now
    end

    space_dir = space_direction(ar, space_idx, s)
    return space_midpoint + offset_distance * Point(-sin(space_dir), cos(space_dir))
end

"""
    segment_direction(ar::ChannelRouter, ws::ChannelWireSegment)

The angle with the x-axis made by segment `ws` directed along its wire toward its end pin.
"""
function segment_direction(ar::ChannelRouter, ws::ChannelWireSegment, s)
    c = segment_channel(ar, ws)
    isnothing(c) && return space_direction(ar, running_space(ws), s)
    off = channel_offset(ar, running_space(ws), c)
    seg = Paths.offset(ar.spaces[running_space(ws)].seg, off)
    return direction(seg, s)
end

function segment_mid_direction(ar::ChannelRouter, ws::ChannelWireSegment)
    s0, s1 = interval(ar, ws)
    return segment_direction(ar, ws, (s0+s1)/2)
end

"""
    channel_offset(ar::ChannelRouter, space_idx, channel_idx, s)

The offset of the centerline of channel `channel_idx` in space `space_idx`,
measured at pathlength `s` in the space.
"""
function channel_offset(ar::ChannelRouter{T}, space_idx, channel_idx, s...) where {T}
    n_channels = length(space_channels(ar, space_idx))
    w = Paths.width(ar.spaces[space_idx].sty, zero(T))
    spacing = w / (n_channels + 1)
    return spacing * (channel_idx - (1 + n_channels) / 2)
end

# function channel_offset(ar::ChannelRouter, space_idx, channel_idx)
#     return s -> channel_offset(ar, space_idx, channel_idx, s)
# end

"""
    interval(ar::ChannelRouter, ws::ChannelWireSegment)

The interval between the center lines of the bounding spaces of `ws`.

The interval is always a tuple with the lower bound as the first element.
"""
function interval(ar::ChannelRouter, ws::ChannelWireSegment)
    start_space, stop_space = bounding_spaces(ws)
    space_idx = running_space(ws)
    
    start_space, stop_space = bounding_spaces(ws)
    s1 = pathlength_at_intersection(ar, space_idx, start_space)
    s2 = pathlength_at_intersection(ar, space_idx, stop_space)

    return _swap(s1, s2)
end

"""
    next(ar::ChannelRouter, ws::ChannelWireSegment)

The wire segment after `ws`, with the wire directed from the source to the destination pin.
"""
function next(ar::ChannelRouter, ws::ChannelWireSegment)
    net_idx = net_index(ws)
    segs = net_wire(ar, net_idx)
    idx = findfirst(isequal(ws), segs)
    if idx == length(segs)
        final_pin_idx = pin_to_graphidx(ar, last(net_pins(ar, net_idx)))
        return ChannelWireSegment(net_idx,
            final_pin_idx,
            running_space(ws),
            0)
    end
    return segs[idx + 1]
end

"""
    prev(ar::ChannelRouter, ws::ChannelWireSegment)

The wire segment before `ws`, with the wire directed from the source to the destination pin.
"""
function prev(ar::ChannelRouter, ws::ChannelWireSegment)
    net_idx = net_index(ws)
    segs = net_wire(ar, net_idx)
    idx = findfirst(isequal(ws), segs)
    if idx == 1
        first_pin_idx = pin_to_graphidx(ar, first(net_pins(ar, net_idx)))
        return ChannelWireSegment(net_idx,
            first_pin_idx,
            0,
            running_space(ws))
    end
    return segs[idx - 1]
end

"""
    shortest_path_between_pins(ar::ChannelRouter, pin_1::Int, pin_2::Int)

A shortest path in the router's space graph from `pin_1` to `pin_2`.

Distance is not physical distance but graph distance (the number of edges in the path).

In the space graph, each space is a vertex, and there is an edge between each intersecting
pair of spaces. Each pin is also a vertex, with an edge only to its adjoining space. A path
is a list of vertex indices `path::Vector{Int}`.
"""
function shortest_path_between_pins(ar::ChannelRouter, p0::Int, p1::Int)
    ys = yen_k_shortest_paths(
        space_graph(ar),
        pin_to_graphidx(ar, p0),
        pin_to_graphidx(ar, p1)
    )
    return ys.paths[1]
end

"""
    assign_spaces!(ar::ChannelRouter)

Performs space assignment for `ar`.
"""
function assign_spaces!(
    ar::ChannelRouter;
    net_indices=eachindex(ar.net_pins),
    fixed_paths::Dict{Int, Vector{Int}}=Dict{Int, Vector{Int}}()
)
    for (idx_net, net) in zip(net_indices, ar.net_pins[net_indices])
        p0, p1 = net
        path = if idx_net in keys(fixed_paths)
            [
                pin_to_graphidx(ar, p0)
                fixed_paths[idx_net]
                pin_to_graphidx(ar, p1)
            ]
        else
            shortest_path_between_pins(ar, p0, p1)
        end
        ixns = [(path[i], path[i + 1]) for i = 1:(length(path) - 1)]
        segs = [(ixns[i], ixns[i + 1]) for i = 1:(length(ixns) - 1)]
        for (space, seg) in zip(path[2:(end - 1)], segs)
            ws = ChannelWireSegment(idx_net, space, first(seg[1]), last(seg[2]))
            push!(net_wire(ar, idx_net), ws)
            push!(space_segments(ar, space), ws)
        end
    end
end

"""
    assign_channels!(ar::ChannelRouter)

Performs channel assigment for `ar`.

This version uses a greedy heuristic for minimizing space height.
"""
function assign_channels!(ar::ChannelRouter{T}) where {T}
    for space = 1:num_spaces(ar)
        channels = space_channels(ar, space)
        ws_ascending = sort(space_segments(ar, space), by=(ws) -> interval(ar, ws))
        for ws in ws_ascending
            low, high = interval(ar, ws)
            options = Int[] # Vector of channel index
            # Channel is an option whenever low > highest upper bound of segments in channel
            for ic in eachindex(channels)
                # Last segment always has highest upper bound by construction
                top = interval(ar, channels[ic][end])
                if low > last(top)
                    push!(options, ic)
                elseif low == last(top) # If bounds coincide, might still share channel
                    # What does this wire connect to at the endpoint?
                    s0, s1 = bounding_spaces(ws)
                    # What does the other wire connect to at the endpoint?
                    s2, s3 = bounding_spaces(channels[ic][end])
                    intersecting_space = (s0 == s2 || s0 == s3) ? s0 : s1
                    if intersecting_space < space # If the intersecting space is scheduled
                        push!(options, ic) # Then that schedule separated them already
                    end
                end
            end

            # Simple scoring rule: go in channel with most similar "tendency"
            # Sum +/- 1 for each adjacent segment where this segment is an upper/lower bound
            # for each segment
            best_score = (1, zero(T))
            best_channel = 0
            for ic in options
                score = score_channel(ar, channels[ic], ws)
                if score > best_score || best_channel == 0
                    best_score = score
                    best_channel = ic
                end
            end

            if isempty(options) # no valid options
                push!(channels, ChannelWireSegment[]) # new channel
                best_channel = length(channels)
            end

            push!(channels[best_channel], ws)
        end
        # If a channel tends to turn CCW, give it a high index
        sort!(channels, by=ch -> tendency(ar, ch))
    end
end

"""
    score_channel(ar::ChannelRouter, channel, ws)

A rough measure of how well `ws` would fit into `channel`.
"""
function score_channel(
    ar::ChannelRouter,
    channel::Vector{ChannelWireSegment},
    ws::ChannelWireSegment
)
    tws = tendency(ar, ws)
    tc = tendency(ar, channel)
    return (tws[1] * tc[1], 0.0)
end

"""
    tendency(ar::ChannelRouter, ws::ChannelWireSegment)

Sum of +/- 1 for the two segments connected to `ws` for which `ws` is an upper/lower bound.
"""
function tendency(ar::ChannelRouter, ws::ChannelWireSegment)
    space_idx = running_space(ws)
    start_space, stop_space = bounding_spaces(ws)
    start_space == 0 || stop_space == 0 && return
    # Distances along bounding and running spaces
    s_along_start = pathlength_at_intersection(ar, start_space, space_idx)
    s1 = pathlength_at_intersection(ar, space_idx, start_space)
    s2 = pathlength_at_intersection(ar, space_idx, stop_space)
    s_along_stop = pathlength_at_intersection(ar, stop_space,  space_idx)
    # Directions of bounding and running spaces
    start_dir = space_direction(ar, start_space, s_along_start)
    dir1 = space_direction(ar, space_idx, s1)
    dir2 = space_direction(ar, space_idx, s2)
    stop_dir = space_direction(ar, stop_space, s_along_stop)
    # Tendencies
    ## +ve = wire makes CCW turns
    ## But actual bends depend on direction of wires vs spaces
    ### Signs of angles made by space intersections
    sgn_bend1 = sign(rem2pi(uconvert(NoUnits, dir1 - start_dir), RoundNearest))
    sgn_bend2 = sign(rem2pi(uconvert(NoUnits, stop_dir - dir2), RoundNearest))
    ### Need to multiply according to direction in space
    ### Is prev upper-bounded by ws? Then it goes along with space
    sgn_start = s_along_start >= last(interval(ar, prev(ar, ws))) ? 1 : -1
    ### Is next upper-bounded by ws? Then it goes against space
    sgn_stop = s_along_stop >= last(interval(ar, next(ar, ws))) ? -1 : 1
    ### Bend signs get another -1 if ws runs opposite to its space direction
    ### But then tendency definition is reversed also
    turn_tendency = (sgn_start * sgn_bend1 + sgn_stop * sgn_bend2)

    # Alternative: Dot product of avg of prev and next midpoints with direction
    prev_midp = segment_midpoint(ar, prev(ar, ws))
    next_midp = segment_midpoint(ar, next(ar, ws))
    space_midp = segment_midpoint(ar, ws)# ar.spaces[space_idx].seg(pathlength(ar.spaces[space_idx])/2)
    vec = (prev_midp + next_midp)/2 - space_midp
    vec2 = (next_midp - prev_midp) / norm(next_midp - prev_midp)
    tiebreaker = sign(s2 - s1)*(vec.x * -vec2.y + vec.y * vec2.x)
    return (turn_tendency, tiebreaker)
end

"""
    tendency(ar::ChannelRouter, channel)

Sum of `tendency` for each segment in the channel.
"""
function tendency(ar::ChannelRouter, channel::Vector{ChannelWireSegment})
    ts = tendency.(ar, channel)
    return (sum(first.(ts)), sum(last.(ts)))
end

"""
    make_routes!(ar::ChannelRouter, rule; net_indices=eachindex(ar.net_pins))

Using space and channel assignments, create `Route`s for the nets in `net_indices`.

A point and direction is calculated for each `wire_segment`. These are assigned to
`ar.segment_waypoints[wire_segment]` (if not already assigned) and then added as a
waypoint/way-direction in the output `Route`.
"""
function make_routes!(
    ar::ChannelRouter{T},
    rule;
    net_indices=eachindex(ar.net_pins)
) where {T}
    routes = Route{T}[]
    for (idx_net, net_segs) in zip(net_indices, ar.net_wires[net_indices])
        waydirs = typeof(1.0°)[]
        waypoints = Point{T}[]
        for seg in net_segs
            if haskey(ar.segment_waypoints, seg)
                wp = segment_waypoint(ar, seg).p
                wd = segment_waypoint(ar, seg).in_direction
                push!(waypoints, wp)
                push!(waydirs, wd)
            else
                wp, wd = segment_midpoint(ar, seg), segment_mid_direction(ar, seg)
                push!(waypoints, wp)
                push!(waydirs, wd)
                ar.segment_waypoints[seg] = PointHook(wp, wd)
            end
        end
        p0, p1 = pin_coordinates.(ar, net_pins(ar, idx_net))
        α0, α1 = pin_direction.(ar, net_pins(ar, idx_net))
        rt = Route(rule, p0, p1, α0, α1 + pi, waypoints=waypoints, waydirs=waydirs)
        push!(routes, rt)
    end
    return routes
end

function _delete_segment!(ar, ws; reset_channels=true, from_net=true)
    # Deletes the wire segment `ws` from `ar`.

    # Delete the wire segment in space_segments
    s = running_space(ws)
    deleteat!(space_segments(ar, s), findfirst(isequal(ws), space_segments(ar, s)))

    # Delete the segment from its channel
    c_idx = segment_channel(ar, ws)
    if !isnothing(c_idx)
        if reset_channels # by default, reset all channel assignments in this space
            empty!(space_channels(ar, s))
        else
            deleteat!(
                space_channels(ar, s)[c_idx],
                findfirst(isequal(ws), space_channels(ar, s)[c_idx])
            )
        end
    end
    # Delete the segment waypoint
    delete!(ar.segment_waypoints, ws)

    # if from_net, delete ws from net_wires
    # We set from_net to false when looping over net segments so it's not changing under us
    return from_net && deleteat!(
        net_wire(ar, net_index(ws)),
        findfirst(isequal(ws), net_wire(ar, net_index(ws)))
    )
end

"""
    reset_nets!(ar; net_indices=eachindex(ar.net_pins), reset_channels=true)

Resets the nets with `net_indices` to their unrouted state.

If `reset_channels` is `true`, then all spaces used by nets being reset will also have their
channel assignments removed.
"""
function reset_nets!(ar; net_indices=eachindex(ar.net_pins), reset_channels=true)
    for segs in net_wire.(ar, net_indices)
        for ws in segs
            # delete segment from the router
            # don't delete it from net yet, we'll do that after this loop
            _delete_segment!(ar, ws, reset_channels=reset_channels, from_net=false)
        end
        empty!(segs)
    end
end

"""
    autoroute!(ar::ChannelRouter, rule; net_indices=eachindex(ar.net_pins),
        fixed_space_paths::Dict{Int,Vector{Int}}=Dict())

Perform space and channel assigment, then make routes.

Routes only the nets in `net_indices`. If the net is already routed, it is reset. A route
for a net can be specified in `fixed_space_paths` by the indices of the spaces the route
takes. For example, `fixed_space_paths=Dict(1 => [2, 4, 1, 5])` will force net 1 to be
routed from its source pin, through spaces 2, 4, 1, 5 in order, then to its destination pin.
"""
function autoroute!(
    ar::ChannelRouter,
    rule;
    net_indices=eachindex(ar.net_pins),
    fixed_space_paths::Dict{Int, Vector{Int}}=Dict{Int, Vector{Int}}()
)
    reset_nets!(ar, net_indices=net_indices)
    assign_spaces!(ar; net_indices=net_indices, fixed_paths=fixed_space_paths)
    assign_channels!(ar)
    return make_routes!(ar, rule; net_indices=net_indices)
end

######## Modification

"""
    set_waypoint!(ar::ChannelRouter, net_idx, seg_idx, new_point)
    set_waypoint!(ar::ChannelRouter, net_idx, seg_idx, new_point, new_direction)

Sets the waypoint for the segment at `seg_idx` in net `net_idx` to `new_point`.

A `new_direction` can also be specified for advanced usage.
"""
function set_waypoint!(
    ar::ChannelRouter,
    net_idx,
    seg_idx,
    new_point,
    dir=segment_waypoints(ar, net_wire(ar, net_idx)[seg_idx])[2]
)
    ws = net_wire(ar, net_idx)[seg_idx]
    return ar.segment_waypoints[ws] = (new_point, dir)
end

######## Visualization

"""
    visualize_router_state(ar::ChannelRouter{T}; wire_width=0.1*oneunit(T))

Return a `Cell` with rectangles and labels illustrating spaces, channels, and routes.

Channels are labeled as `S:C` where `S` is the space index and `C` is the channel index.

Pins are labeled as `P/N` where `P` is the pin index and `N` is the net index.

Segment waypoints are marked with circles and numbered sequentially within each net.
"""
function visualize_router_state(
    ar::ChannelRouter{T};
    wire_width=0.1 * oneunit(T),
    rule=StraightAnd90(min_bend_radius=wire_width, max_bend_radius=wire_width)
) where {T}
    c = Cell{T}("channel_viz")

    rts = make_routes!(ar, rule)
    paths = [Path(rt, Paths.Trace(wire_width)) for rt in rts]

    render!.(c, paths, GDSMeta())
    rect = channel_rectangles(ar)
    render!.(c, rect, GDSMeta(2))
    rect2 = space_rectangles(ar)
    render!.(c, rect2, GDSMeta(3))
    lab = channel_labels(ar)
    [text!(c, l..., GDSMeta(4)) for l in lab]
    [render!(c, circle(wire_width) + p, GDSMeta(5)) for rt in rts for p in rt.waypoints]
    plab = pin_labels(ar)
    [text!(c, l..., GDSMeta(6)) for l in plab]
    wlab = waypoint_labels(ar)
    [
        text!(c, l..., GDSMeta(8), xalign=Align.XCenter(), yalign=Align.YCenter())
        for l in wlab
    ]
    return c
end

function channel_rectangles(ar::ChannelRouter)
    return [
        channel_rectangle(ar, s, c) for s = 1:num_spaces(ar) for c = 1:num_channels(ar, s)
    ]
end

space_rectangles(ar::ChannelRouter) = [space_rectangle(ar, s) for s = 1:num_spaces(ar)]

function channel_labels(ar::ChannelRouter)
    return [
        (
            "$s:$c",
            p0(channel_rectangle(ar, s, c))
        ) for s = 1:num_spaces(ar) for c = 1:num_channels(ar, s)
    ]
end

function pin_labels(ar::ChannelRouter)
    return [
        ("$p/$n", pin_coordinates(ar, p)) for n = 1:num_nets(ar) for p in net_pins(ar, n)
    ]
end

function waypoint_labels(ar::ChannelRouter)
    return [
        ("$i", segment_waypoint(ar, segs[i]).p) for segs in ar.net_wires for
        i = 1:length(segs)
    ]
end

function space_rectangle(ar::ChannelRouter, space_idx)
    return ar.spaces[space_idx]
end

function channel_rectangle(ar::ChannelRouter{T}, space_idx, channel_idx) where {T}
    off = channel_offset(ar, space_idx, channel_idx, zero(T))
    seg = Paths.offset(ar.spaces[space_idx].seg, off)
    n_channels = length(space_channels(ar, space_idx))
    w = Paths.width(ar.spaces[space_idx].sty, zero(T))
    pa = Path([Paths.Node(seg, Paths.Trace(w / (n_channels+1)))])
    return pa
end
