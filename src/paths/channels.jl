# Original: Hashimoto and Stevens https://cs.baylor.edu/~maurer/CSI5346/originalCR.pdf
# VCG, HCG/Zone representation, Doglegs, merging: Yoshimura and Kuh https://my.ece.utah.edu/~kalla/phy_des/yk.pdf
# Crossing-aware: Condrat, Kalla, Blair https://my.ece.utah.edu/~kalla/papers/condrat_crossing-aware_channel_routing_for_photonic_waveguides.pdf

using Graphs
import DeviceLayout
import DeviceLayout: °, Align, Cell, Coordinate, GDSMeta, Hook, NoUnits, Path, Paths, Point, PointHook, Polygon, Rectangle, circle, render!, text!, uconvert, width, height
import DeviceLayout.Paths: StraightAnd90, Route, Trace
import LinearAlgebra: norm

# TrackWireSegment = (net, lengthwise channel, (start vertex, end vertex))
# vertex is the channel index or, if the start/end is a pin, the graph index for that pin
struct TrackWireSegment
    net_index::Int
    running_channel::Int
    start_vertex::Int
    stop_vertex::Int
end

bounding_channels(ws::TrackWireSegment) = (ws.start_vertex, ws.stop_vertex)
net_index(ws::TrackWireSegment) = ws.net_index
running_channel(ws::TrackWireSegment) = ws.running_channel

const Track = Vector{TrackWireSegment}
const NetWire = Vector{TrackWireSegment}
const Channel = Paths.Node
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
struct ChannelIntersection{T <: Coordinate}
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
        pin_adjoining_channels,
        channel_coords,
        channel_coord_indices,
        channel_widths
    )

A simple autorouter where wires can run on horizontal and vertical channels.

The router will attempt to connect pairs of pins, each with coordinates and a direction.
The indices of connected pins are specified by `nets`.

The router is initialized with a number of vertical and horizontal "channels", characterized
by a width and the coordinate of their center line. Each channel will be divided into some
number of tracks as necessary to route all nets.

Routing proceeds in two steps. The first is "channel assignment", which proceeds net by net,
finding a path between pins described in terms of the channels the path uses. The second step
is "track assigment", which proceeds channel by channel. Wire segments are assigned to
tracks within the channel such that wire segments in the same track do not overlap.

# Arguments

  - `nets::Vector{Tuple{Int,Int}}`: A list specifying which pairs of pins are connected
  - `pins`: The coordinates of those pins
  - `pin_directions`: The angles the pins make with the x-axis
  - `pin_adjoining_channels`: The perpendicular channels adjoining the pins
  - `channel_coords`: The coordinate of the center line along each channel (the "fixed" coordinate)
  - `channel_coord_indices`: The index of the fixed coordinate; that is, 1 for vertical channels
    which have fixed `x` and run along `y`
  - `channel_widths`: The widths of the channels
"""
mutable struct ChannelRouter{T <: Coordinate}
    channel_graph::SimpleGraph{Int}     # Channels/pins are vertices, intersections are edges
    net_pins::Vector{Tuple{Int, Int}} # Pairs of pins (indices in `pins`)
    net_wires::Vector{NetWire}        # Wire segments connecting pins for each net
    pins::Vector{PointHook{T}}        # Position and orientation of pins
    channels::Vector{Channel{T}}   # List of channels
    # channel_capacities::Vector{Int}   # Maximum number of tracks per channel
    # For each edge, information to find the intersection point
    channel_intersections::Dict{Tuple{Int, Int}, IntersectionInfo{T}}
    channel_segments::Vector{Vector{TrackWireSegment}}
    channel_tracks::Vector{Vector{Track}}
    segment_waypoints::Dict{TrackWireSegment, PointHook{T}}
end

function ChannelRouter(
    nets,
    pin_hooks::Vector{<:Hook},
    channel_paths::Vector{<:Path}
)
    T = promote_type(coordinatetype(pin_hooks), coordinatetype(channel_paths))
    net_wires = [NetWire() for i in eachindex(nets)]
    channel_segments = [TrackWireSegment[] for i in eachindex(channel_paths)]
    channel_tracks = [Track[] for i in eachindex(channel_paths)]
    segment_waypoints = Dict{TrackWireSegment, PointHook{T}}()
    pins = [PointHook{T}(pin.p, pin.in_direction + 180°) for pin in pin_hooks]
    channel_graph, ixns = build_channel_graph(pins, channel_paths, T)
    # Simplify after channel graph construction to avoid CompoundSegment operations
    channels = [simplify(convert(Path{T}, path)) for path in channel_paths]
    return ChannelRouter{T}(
        channel_graph,
        nets,
        net_wires,
        pins,
        channels,
        ixns,
        channel_segments,
        channel_tracks,
        segment_waypoints
    )
end

Base.broadcastable(x::ChannelRouter) = Ref(x)
num_channels(ar::ChannelRouter) = length(ar.channels)
num_nets(ar::ChannelRouter) = length(ar.net_pins)
num_pins(ar::ChannelRouter) = length(ar.pins)

channel_graph(ar::ChannelRouter) = ar.channel_graph
net_pins(ar::ChannelRouter, net) = ar.net_pins[net]
net_wire(ar::ChannelRouter, net) = ar.net_wires[net]
pin_coordinates(ar::ChannelRouter, pin) = ar.pins[pin].p
pin_direction(ar::ChannelRouter, pin) = ar.pins[pin].in_direction
channel_coordinates(ar::ChannelRouter, channel, s) = ar.channels[channel].seg(s)
function channel_direction(ar::ChannelRouter, channel, s)
    is_pin(ar, channel) && return pin_direction(ar, graphidx_to_pin(ar, channel))
    return direction(ar.channels[channel].seg, s)
end
channel_segments(ar::ChannelRouter, channel) = ar.channel_segments[channel]
channel_tracks(ar::ChannelRouter, channel) = ar.channel_tracks[channel]
num_tracks(ar::ChannelRouter, channel) = length(ar.channel_tracks[channel])
pin_to_graphidx(ar::ChannelRouter, p::Int) = p + num_channels(ar)
graphidx_to_pin(ar::ChannelRouter, graphidx::Int) = graphidx - num_channels(ar)
is_pin(ar::ChannelRouter, graphidx) = graphidx > num_channels(ar)
adjoining_channel(ar::ChannelRouter, pin) =
    neighbors(channel_graph(ar), pin_to_graphidx(ar, pin))[1]
channel_intersection(ar, s1, s2) = ar.channel_intersections[_swap(s1, s2)]
function pathlength_at_intersection(ar::ChannelRouter{T},
    running_channel,
    intersecting_channel) where {T}
    # Intersecting channel is zero where a wire segment hits a pin
    if iszero(running_channel) || iszero(intersecting_channel)
        return zero(T)
    end
    ixn_info = channel_intersection(ar, running_channel, intersecting_channel)
    running_channel < intersecting_channel && return ixn_info[1]
    return ixn_info[2]
end

segment_waypoint(ar::ChannelRouter, ws::TrackWireSegment) = ar.segment_waypoints[ws]
_swap(x, y) = (y > x ? (x, y) : (y, x))

pathlength_from_start(channel, node, s) = pathlength(channel[1:node-1]) + s

# Build graph with pins/channels as vertices and intersections as edges
function build_channel_graph(pins, channels, T)
    g = SimpleGraph(length(channels) + length(pins))
    intersection_dict = Dict{Tuple{Int, Int}, IntersectionInfo{T}}()

    # Create segments extending from pins
    bbox = bounds(bounds(channels), bounds(Polygon(DeviceLayout.getp.(pins))))
    ray_length = max(width(bbox), height(bbox))*sqrt(2)
    pin_rays = Path{T}[]
    for pin in pins
        path = Path{T}(pin.p, pin.in_direction)
        straight!(path, ray_length, Paths.NoRender())
        push!(pin_rays, path)
    end

    # Add edges for intersections between channels
    intersections = DeviceLayout.Intersect.prepared_intersections(
        [channels..., pin_rays...])
    pin_ixns = Dict{Int, Tuple{Int, IntersectionInfo{T}}}()
    for ixn in intersections
        location_1, location_2, p = ixn
        v1_idx, node1_idx, s1 = location_1
        v2_idx, node2_idx, s2 = location_2
        if v1_idx >= v2_idx
            # `prepared_intersections` guarantees v2 >= v1
            @assert v1_idx == v2_idx
            # We will also ignore self-intersecting channels v2 == v1
            @info "Ignoring self-intersection of channel $v1_idx"
            continue
        elseif v1_idx > length(channels) && v2_idx > length(channels)
            # Both are pins, ignore intersection
            continue
        elseif v2_idx > length(channels) # v2 is a pin
            s1 = pathlength_from_start(channels[v1_idx], node1_idx, s1)
            # Record intersection if it's the closest so far
            ixn_info = (s1, s2, p)
            _, old_ixn_info = get(pin_ixns, v2_idx,
                (v1_idx, ixn_info))
            old_distance = old_ixn_info[2]
            if s2 <= old_distance
                pin_ixns[v2_idx] = (v1_idx, ixn_info)
            end
        else # record intersection as edge in channel graph, with info in dict
            haskey(intersection_dict, (v1_idx, v2_idx)) && 
                error("Spaces $v1_idx and $v2_idx have multiple intersections")
            s1 = pathlength_from_start(channels[v1_idx], node1_idx, s1)
            s2 = pathlength_from_start(channels[v2_idx], node2_idx, s2)

            add_edge!(g, v1_idx, v2_idx)
            intersection_dict[(v1_idx, v2_idx)] = # All records have v1 < v2
                (s1, s2, p)
        end
    end
    # Add min distance edge for each pin
    for pin_idx in (length(channels)+1):(length(channels) + length(pins))
        orig_idx = pin_idx - length(channels)
        !haskey(pin_ixns, pin_idx) && error("The ray from pin $(orig_idx) ($(pins[orig_idx])) does not intersect any channel")
        channel_idx, ixn_info = pin_ixns[pin_idx]
        add_edge!(g, (channel_idx, pin_idx))
        intersection_dict[(channel_idx, pin_idx)] = ixn_info
    end

    return g, intersection_dict
end

"""
    print_segments(ar::ChannelRouter, net)

Print the information for the wire segments in `net` in a human-readable format.
"""
function print_segments(ar::ChannelRouter, net)
    for (i, ws) in pairs(net_wire(ar, net))
        s1, s2 = bounding_channels(ws)
        channel_names = [
            is_pin(ar, s1) ? "Pin $(graphidx_to_pin(ar, s1))" : "Channel $s1",
            is_pin(ar, s2) ? "Pin $(graphidx_to_pin(ar, s2))" : "Channel $s2"
        ]
        println(
            """
    Segment $i:
        Runs along Channel $(running_channel(ws)), Track $(segment_track(ar, ws))
        From $(channel_names[1]) to $(channel_names[2])
        Through waypoint $(segment_waypoint(ar, ws)[1]) at $(segment_waypoint(ar, ws)[2])
    """
        )
    end
end

"""
    segment_track(ar::ChannelRouter, ws::TrackWireSegment)

The track index of `ws`, or `nothing` if no track has been assigned.
"""
function segment_track(ar::ChannelRouter, ws::TrackWireSegment)
    channel_idx = running_channel(ws)
    tracks = channel_tracks(ar, channel_idx)
    track_idx = findfirst((c) -> ws in c, tracks)
    return track_idx
end

"""
    segment_midpoint(ar::ChannelRouter, ws::TrackWireSegment)

The midpoint of the segment `ws` between `bounding_channels(ws)`.

If `ws` has been assigned a track, uses the segment along that track.
"""
function segment_midpoint(ar::ChannelRouter{T}, ws::TrackWireSegment) where {T}
    channel_idx = running_channel(ws)
    s0, s1 = interval(ar, ws)
    s = (s0+s1)/2
    if is_pin(ar, channel_idx)
        dir = pin_direction(ar, graphidx_to_pin(ar, channel_idx))
        return pin_coordinates(ar, graphidx_to_pin(ar, channel_idx)) +
            s * Point(cos(dir), sin(dir))
    end
    tracks = channel_tracks(ar, channel_idx)
    track_idx = findfirst((c) -> ws in c, tracks)
    channel_midpoint = channel_coordinates(ar, channel_idx, s)

    offset_distance = if isnothing(track_idx)
        zero(T)
    else
        track_offset(ar, channel_idx, track_idx) # No tapers for now
    end

    channel_dir = channel_direction(ar, channel_idx, s)
    return channel_midpoint + offset_distance * Point(-sin(channel_dir), cos(channel_dir))
end

"""
    segment_direction(ar::ChannelRouter, ws::TrackWireSegment)

The angle with the x-axis made by segment `ws` directed along its wire toward its end pin.
"""
function segment_direction(ar::ChannelRouter, ws::TrackWireSegment, s)
    c = segment_track(ar, ws)
    isnothing(c) && return channel_direction(ar, running_channel(ws), s)
    off = track_offset(ar, running_channel(ws), c)
    seg = Paths.offset(ar.channels[running_channel(ws)].seg, off)
    return direction(seg, s)
end

function segment_mid_direction(ar::ChannelRouter, ws::TrackWireSegment)
    s0, s1 = interval(ar, ws)
    return segment_direction(ar, ws, (s0+s1)/2)
end

"""
    track_offset(ar::ChannelRouter, channel_idx, track_idx, s)

The offset of the centerline of track `track_idx` in channel `channel_idx`,
measured at pathlength `s` in the channel.
"""
function track_offset(ar::ChannelRouter{T}, channel_idx, track_idx, s...) where {T}
    n_tracks = length(channel_tracks(ar, channel_idx))
    w = Paths.width(ar.channels[channel_idx].sty, zero(T))
    spacing = w / (n_tracks + 1)
    return spacing * (track_idx - (1 + n_tracks) / 2)
end

# function track_offset(ar::ChannelRouter, channel_idx, track_idx)
#     return s -> track_offset(ar, channel_idx, track_idx, s)
# end

"""
    interval(ar::ChannelRouter, ws::TrackWireSegment)

The interval between the center lines of the bounding channels of `ws`.

The interval is always a tuple with the lower bound as the first element.
"""
function interval(ar::ChannelRouter, ws::TrackWireSegment)
    start_channel, stop_channel = bounding_channels(ws)
    channel_idx = running_channel(ws)
    
    start_channel, stop_channel = bounding_channels(ws)
    s1 = pathlength_at_intersection(ar, channel_idx, start_channel)
    s2 = pathlength_at_intersection(ar, channel_idx, stop_channel)

    return _swap(s1, s2)
end

"""
    next(ar::ChannelRouter, ws::TrackWireSegment)

The wire segment after `ws`, with the wire directed from the source to the destination pin.
"""
function next(ar::ChannelRouter, ws::TrackWireSegment)
    net_idx = net_index(ws)
    segs = net_wire(ar, net_idx)
    idx = findfirst(isequal(ws), segs)
    if idx == length(segs)
        final_pin_idx = pin_to_graphidx(ar, last(net_pins(ar, net_idx)))
        return TrackWireSegment(net_idx,
            final_pin_idx,
            running_channel(ws),
            0)
    end
    return segs[idx + 1]
end

"""
    prev(ar::ChannelRouter, ws::TrackWireSegment)

The wire segment before `ws`, with the wire directed from the source to the destination pin.
"""
function prev(ar::ChannelRouter, ws::TrackWireSegment)
    net_idx = net_index(ws)
    segs = net_wire(ar, net_idx)
    idx = findfirst(isequal(ws), segs)
    if idx == 1
        first_pin_idx = pin_to_graphidx(ar, first(net_pins(ar, net_idx)))
        return TrackWireSegment(net_idx,
            first_pin_idx,
            0,
            running_channel(ws))
    end
    return segs[idx - 1]
end

"""
    shortest_path_between_pins(ar::ChannelRouter, pin_1::Int, pin_2::Int)

A shortest path in the router's channel graph from `pin_1` to `pin_2`.

Distance is not physical distance but graph distance (the number of edges in the path).

In the channel graph, each channel is a vertex, and there is an edge between each intersecting
pair of channels. Each pin is also a vertex, with an edge only to its adjoining channel. A path
is a list of vertex indices `path::Vector{Int}`.
"""
function shortest_path_between_pins(ar::ChannelRouter, p0::Int, p1::Int)
    ys = yen_k_shortest_paths(
        channel_graph(ar),
        pin_to_graphidx(ar, p0),
        pin_to_graphidx(ar, p1)
    )
    return ys.paths[1]
end

"""
    assign_channels!(ar::ChannelRouter)

Performs channel assignment for `ar`.
"""
function assign_channels!(
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
        for (channel, seg) in zip(path[2:(end - 1)], segs)
            ws = TrackWireSegment(idx_net, channel, first(seg[1]), last(seg[2]))
            push!(net_wire(ar, idx_net), ws)
            push!(channel_segments(ar, channel), ws)
        end
    end
end

"""
    assign_tracks!(ar::ChannelRouter)

Performs track assigment for `ar`.

This version uses a greedy heuristic for minimizing channel height.
"""
function assign_tracks!(ar::ChannelRouter{T}) where {T}
    for channel = 1:num_channels(ar)
        assign_tracks!(ar, channel)
    end
end

function assign_tracks_greedy!(ar, channel)    tracks = channel_tracks(ar, channel)
    ws_ascending = sort(channel_segments(ar, channel), by=(ws) -> interval(ar, ws))
    for ws in ws_ascending
        low, high = interval(ar, ws)
        options = Int[] # Vector of track index
        # Track is an option whenever low > highest upper bound of segments in track
        for ic in eachindex(tracks)
            # Last segment always has highest upper bound by construction
            top = interval(ar, tracks[ic][end])
            if low > last(top)
                push!(options, ic)
            elseif low == last(top) # If bounds coincide, might still share track
                # What does this wire connect to at the endpoint?
                s0, s1 = bounding_channels(ws)
                # What does the other wire connect to at the endpoint?
                s2, s3 = bounding_channels(tracks[ic][end])
                intersecting_channel = (s0 == s2 || s0 == s3) ? s0 : s1
                if intersecting_channel < channel # If the intersecting channel is scheduled
                    push!(options, ic) # Then that schedule separated them already
                end
            end
        end

        # Simple scoring rule: go in track with most similar "tendency"
        # Sum +/- 1 for each adjacent segment where this segment is an upper/lower bound
        # for each segment
        best_score = (1, zero(T))
        best_track = 0
        for ic in options
            score = score_track(ar, tracks[ic], ws)
            if score > best_score || best_track == 0
                best_score = score
                best_track = ic
            end
        end

        if isempty(options) # no valid options
            push!(tracks, TrackWireSegment[]) # new track
            best_track = length(tracks)
        end

        push!(tracks[best_track], ws)
    end
    # If a track tends to turn CCW, give it a high index
    sort!(tracks, by=ch -> tendency(ar, ch))
end



function assign_tracks_merging!(ar, channel)
    # Yoshimura and Kuh Algorithm #1
    zone_ig, vcg = channel_problem_graphs(ar, channel)
    zones = maximal_cliques(zone_ig)
    # Need to sort zones left to right (by their minimal element)
    ws_ascending = sort(channel_segments(ar, channel), by=(ws) -> interval(ar, ws))
    L = Set{Int}()
    seen = Set{Int}()
    merged_into = Dict{Int, Int}()
    for (zone, nextzone) in zip(zones[1:end-1], zones[2:end])
        for ws_idx in zone
            if !(ws_idx in nextzone) # ends in this zone
                push!(L, ws_idx)
            end
        end
        R = Set{Int}()
        for ws_idx in nextzone
            if !(ws_idx in seen) # starts in next zone
                push!(R, ws_idx)
            end
        end
        merged = merge_best!(zone_ig, vcg, L, R)
        into_idx = minimum(merged)
        for ws_idx in merged
            ws_idx > into_idx && merged_into[ws_idx] = into_idx
            pop!(L, ws_idx)
        end
    end
    # Now do actual track assignment based on modified VCG

    # Or do matching version with BipartiteMatching.jl
    # findmaxcardinalitybipartitematching 
    # BitMatrix(adjacency_matrix(temp_bipartite))

    for (zone, nextzone) in zip(zones[1:end-1], zones[2:end])
        # Initialize: Add nets terminating in first zone to left side
        # Add nets starting in second zone to right side
        # Add edges between left and right when they can be merged
        # Find max cardinality matching
        # Check if matching satisfies VCG
        # If not, modify by collecting edges to remove
        #   In a copy, find nodes with no VCG ancestors, remove edges touching them
        #   If any nodes have no edges, remove them and go back
        #   Otherwise, remove a node with fewest edges, remove and collect those edges,
        # Advance to next zone:
        #   merge any matched nodes from right to left
        #   move unmatched nodes from right to left
        #   add new zone to right side
    end
end

function merge_best!(zone_ig, vcg, L, R)
    # Minimize longest path length in VCG (lower bound on necessary # of tracks)
    # Seems annoying, matching version shouldn't be any worse
    merged = Set{Int}()
    while !isempty(R)
        ws1, ws2 = find_best()
        vcg = merge_segments!(zone_ig, vcg, ws1, ws2)
    end
end

function merge_segments!(zone_ig, vcg, ws1, ws2)
    merge_vertices!(zone_ig, [ws1, ws2])
    return merge_vertices(vcg, [ws1, ws2]) # No in-place for directed graph
end

function channel_problem_graphs(ar::ChannelRouter, channel)
    ws_ascending = sort(channel_segments(ar, channel), by=(ws) -> interval(ar, ws))
    # Y&K zone representation as interval graph
    # Edge between each pair of segments that overlap
    zone_ig = SimpleGraph(length(ws_ascending))
    # Condrat et al. VCG with avoidable crossings as constraints
    # Not handled: constraints from vertically aligned pin positions
    vcg = SimpleDiGraph(length(ws_ascending)) # just a fresh graph
    for (idx1, seg1) in pairs(ws_ascending)
        low1, high1 = interval(ar, seg1)
        for (idx2, seg2) in pairs(ws_ascending)[idx1+1:end]
            low2, high2 = interval(ar, seg2)
            # If there is no overlap, break and move on to next seg1
            # Use >= instead of > to allow knock-knees
            low2 >= high1 && break # All subsequent seg2 have low2 >= high1
            # There is overlap, so add an edge to the interval graph
            add_edge!(zone_ig, idx1, idx2)
            # Now check if crossing is unavoidable
            # If seg1 and seg2 enter and exit at the same place, then crossing
            # may be avoidable, but this channel can't say which goes on top yet
            (low1 == high1 && low2 == high2) && break

            # low1 < low2 < [high1 < high2 or high2 <= high1]
            pt1, nt1 = prev_next_tendency(ar, seg1)
            pt2, nt2 = prev_next_tendency(ar, seg2)
            avoidable = is_avoidable(low1, high1, low2, high2, pt1, nt1, pt2, nt2)
            !avoidable && continue
            # Crossing is avoidable, so add a constraint
            # Determine which goes on top based on the lower bound tendency of seg2
            top = (idx1, idx2)[1 + (pt2 == 1)]
            bottom = (idx1, idx2)[2 - (pt2 == 1)]
            add_edge!(vcg, top, bottom)
        end
    end
    return vcg, zone_ig
end

function is_avoidable(low1, high1, low2, high2, pt1, nt1, pt2, nt2)
    if high1 < high2
        # 1 ____
        # 2   ____
        order = [1, 2, 1, 2] # low1 < low2 < high1 < high2
        ordered_tendency = [pt1, pt2, nt1, nt2]
        top = (idx1, idx2)[1]
        bottom = (idx1, idx2)[2]
    else
        # 1 _____
        # 2   __
        order = [1, 2, 2, 1] # low1 < low2 < high2 <= high1
        ordered_tendency = [pt1, pt2, nt2, nt1]
        top = (idx1, idx2)[1]
        bottom = (idx1, idx2)[2]
    end
    up = (ordered_tendency .== 1)
    down = (!).(up)
    ccw_order = [reverse(order[up]); order[down]]
    # Crossing is avoidable if same net has both endpoints adjacent
    # on the clock
    avoidable = (ccw_order[1] == ccw_order[2] ||
        ccw_order[2] == ccw_order[3])
    # Also, if seg1 and seg2 have only one endpoint at the same place,
    # then crossing in this channel is avoidable but depends on
    # other channel; assume other channel will agree
    avoidable = (avoidable || (low1 == high1 || low2 == high2))
end

# +1 if prev segment crosses over high track index in ws's channel
function prev_next_tendency(ar, ws)
    start_channel, stop_channel = bounding_channels(ws)
    # Distances along bounding and running channels
    s_along_start = pathlength_at_intersection(ar, start_channel, channel_idx)
    s1 = pathlength_at_intersection(ar, channel_idx, start_channel)
    s2 = pathlength_at_intersection(ar, channel_idx, stop_channel)
    s_along_stop = pathlength_at_intersection(ar, stop_channel,  channel_idx)
    # Directions of bounding and running channels
    start_dir = channel_direction(ar, start_channel, s_along_start)
    dir1 = channel_direction(ar, channel_idx, s1)
    dir2 = channel_direction(ar, channel_idx, s2)
    stop_dir = channel_direction(ar, stop_channel, s_along_stop)
    # Tendencies
    ## +ve = wire makes CCW turns
    ## But actual bends depend on direction of wires vs channels
    ### Signs of angles made by channel intersections
    sgn_bend1 = sign(rem2pi(uconvert(NoUnits, dir1 - start_dir), RoundNearest))
    sgn_bend2 = sign(rem2pi(uconvert(NoUnits, stop_dir - dir2), RoundNearest))
    ### Need to multiply according to direction in channel
    ### Is prev upper-bounded by ws? Then it goes along with channel
    sgn_start = s_along_start >= last(interval(ar, prev(ar, ws))) ? 1 : -1
    ### Is next upper-bounded by ws? Then it goes against channel
    sgn_stop = s_along_stop >= last(interval(ar, next(ar, ws))) ? -1 : 1
    ### Bend signs get another -1 if ws runs opposite to its channel direction
    ### But then tendency definition is reversed also
    return (sgn_start * sgn_bend1, sgn_stop * sgn_bend2)
end

"""
    score_track(ar::ChannelRouter, track, ws)

A rough measure of how well `ws` would fit into `track`.
"""
function score_track(
    ar::ChannelRouter,
    track::Vector{TrackWireSegment},
    ws::TrackWireSegment
)
    tws = tendency(ar, ws)
    tc = tendency(ar, track)
    return (tws[1] * tc[1], 0.0)
end

"""
    tendency(ar::ChannelRouter, ws::TrackWireSegment)

Sum of +/- 1 for the two segments connected to `ws` for which `ws` is an upper/lower bound.
"""
function tendency(ar::ChannelRouter, ws::TrackWireSegment)
    channel_idx = running_channel(ws)
    start_channel, stop_channel = bounding_channels(ws)
    start_channel == 0 || stop_channel == 0 && return
    # Distances along bounding and running channels
    s_along_start = pathlength_at_intersection(ar, start_channel, channel_idx)
    s1 = pathlength_at_intersection(ar, channel_idx, start_channel)
    s2 = pathlength_at_intersection(ar, channel_idx, stop_channel)
    s_along_stop = pathlength_at_intersection(ar, stop_channel,  channel_idx)
    # Directions of bounding and running channels
    start_dir = channel_direction(ar, start_channel, s_along_start)
    dir1 = channel_direction(ar, channel_idx, s1)
    dir2 = channel_direction(ar, channel_idx, s2)
    stop_dir = channel_direction(ar, stop_channel, s_along_stop)
    # Tendencies
    ## +ve = wire makes CCW turns
    ## But actual bends depend on direction of wires vs channels
    ### Signs of angles made by channel intersections
    sgn_bend1 = sign(rem2pi(uconvert(NoUnits, dir1 - start_dir), RoundNearest))
    sgn_bend2 = sign(rem2pi(uconvert(NoUnits, stop_dir - dir2), RoundNearest))
    ### Need to multiply according to direction in channel
    ### Is prev upper-bounded by ws? Then it goes along with channel
    sgn_start = s_along_start >= last(interval(ar, prev(ar, ws))) ? 1 : -1
    ### Is next upper-bounded by ws? Then it goes against channel
    sgn_stop = s_along_stop >= last(interval(ar, next(ar, ws))) ? -1 : 1
    ### Bend signs get another -1 if ws runs opposite to its channel direction
    ### But then tendency definition is reversed also
    turn_tendency = (sgn_start * sgn_bend1 + sgn_stop * sgn_bend2)

    # Alternative: Dot product of avg of prev and next midpoints with direction
    prev_midp = segment_midpoint(ar, prev(ar, ws))
    next_midp = segment_midpoint(ar, next(ar, ws))
    channel_midp = segment_midpoint(ar, ws)# ar.channels[channel_idx].seg(pathlength(ar.channels[channel_idx])/2)
    vec = (prev_midp + next_midp)/2 - channel_midp
    vec2 = (next_midp - prev_midp) / norm(next_midp - prev_midp)
    tiebreaker = sign(s2 - s1)*(vec.x * -vec2.y + vec.y * vec2.x)
    return (turn_tendency, tiebreaker)
end

"""
    tendency(ar::ChannelRouter, track)

Sum of `tendency` for each segment in the track.
"""
function tendency(ar::ChannelRouter, track::Vector{TrackWireSegment})
    ts = tendency.(ar, track)
    return (sum(first.(ts)), sum(last.(ts)))
end

"""
    make_routes!(ar::ChannelRouter, rule; net_indices=eachindex(ar.net_pins))

Using channel and track assignments, create `Route`s for the nets in `net_indices`.

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

function _delete_segment!(ar, ws; reset_tracks=true, from_net=true)
    # Deletes the wire segment `ws` from `ar`.

    # Delete the wire segment in channel_segments
    s = running_channel(ws)
    deleteat!(channel_segments(ar, s), findfirst(isequal(ws), channel_segments(ar, s)))

    # Delete the segment from its track
    c_idx = segment_track(ar, ws)
    if !isnothing(c_idx)
        if reset_tracks # by default, reset all track assignments in this channel
            empty!(channel_tracks(ar, s))
        else
            deleteat!(
                channel_tracks(ar, s)[c_idx],
                findfirst(isequal(ws), channel_tracks(ar, s)[c_idx])
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
    reset_nets!(ar; net_indices=eachindex(ar.net_pins), reset_tracks=true)

Resets the nets with `net_indices` to their unrouted state.

If `reset_tracks` is `true`, then all channels used by nets being reset will also have their
track assignments removed.
"""
function reset_nets!(ar; net_indices=eachindex(ar.net_pins), reset_tracks=true)
    for segs in net_wire.(ar, net_indices)
        for ws in segs
            # delete segment from the router
            # don't delete it from net yet, we'll do that after this loop
            _delete_segment!(ar, ws, reset_tracks=reset_tracks, from_net=false)
        end
        empty!(segs)
    end
end

"""
    autoroute!(ar::ChannelRouter, rule; net_indices=eachindex(ar.net_pins),
        fixed_channel_paths::Dict{Int,Vector{Int}}=Dict())

Perform channel and track assigment, then make routes.

Routes only the nets in `net_indices`. If the net is already routed, it is reset. A route
for a net can be specified in `fixed_channel_paths` by the indices of the channels the route
takes. For example, `fixed_channel_paths=Dict(1 => [2, 4, 1, 5])` will force net 1 to be
routed from its source pin, through channels 2, 4, 1, 5 in order, then to its destination pin.
"""
function autoroute!(
    ar::ChannelRouter,
    rule;
    net_indices=eachindex(ar.net_pins),
    fixed_channel_paths::Dict{Int, Vector{Int}}=Dict{Int, Vector{Int}}()
)
    reset_nets!(ar, net_indices=net_indices)
    assign_channels!(ar; net_indices=net_indices, fixed_paths=fixed_channel_paths)
    assign_tracks!(ar)
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

Return a `Cell` with rectangles and labels illustrating channels, tracks, and routes.

Tracks are labeled as `S:C` where `S` is the channel index and `C` is the track index.

Pins are labeled as `P/N` where `P` is the pin index and `N` is the net index.

Segment waypoints are marked with circles and numbered sequentially within each net.
"""
function visualize_router_state(
    ar::ChannelRouter{T};
    wire_width=0.1 * oneunit(T),
    rule=StraightAnd90(min_bend_radius=wire_width, max_bend_radius=wire_width)
) where {T}
    c = Cell{T}("track_viz")

    rts = make_routes!(ar, rule)
    paths = [Path(rt, Paths.Trace(wire_width)) for rt in rts]

    render!.(c, paths, GDSMeta())
    rect = track_rectangles(ar)
    render!.(c, rect, GDSMeta(2))
    rect2 = channel_rectangles(ar)
    render!.(c, rect2, GDSMeta(3))
    lab = track_labels(ar)
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

function track_rectangles(ar::ChannelRouter)
    return [
        track_rectangle(ar, s, c) for s = 1:num_channels(ar) for c = 1:num_tracks(ar, s)
    ]
end

channel_rectangles(ar::ChannelRouter) = [channel_rectangle(ar, s) for s = 1:num_channels(ar)]

function track_labels(ar::ChannelRouter)
    return [
        (
            "$s:$c",
            p0(track_rectangle(ar, s, c))
        ) for s = 1:num_channels(ar) for c = 1:num_tracks(ar, s)
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

function channel_rectangle(ar::ChannelRouter, channel_idx)
    return ar.channels[channel_idx]
end

function track_rectangle(ar::ChannelRouter{T}, channel_idx, track_idx) where {T}
    off = track_offset(ar, channel_idx, track_idx, zero(T))
    seg = Paths.offset(ar.channels[channel_idx].seg, off)
    n_tracks = length(channel_tracks(ar, channel_idx))
    w = Paths.width(ar.channels[channel_idx].sty, zero(T))
    pa = Path([Paths.Node(seg, Paths.Trace(w / (n_tracks+1)))])
    return pa
end
