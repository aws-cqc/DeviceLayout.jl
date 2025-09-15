# Original: Hashimoto and Stevens https://cs.baylor.edu/~maurer/CSI5346/originalCR.pdf
# VCG, HCG/Zone representation, doglegs, merging: Yoshimura and Kuh https://my.ece.utah.edu/~kalla/phy_des/yk.pdf
# Crossing-aware: Condrat, Kalla, Blair https://my.ece.utah.edu/~kalla/papers/condrat_crossing-aware_channel_routing_for_photonic_waveguides.pdf

import Graphs:
    SimpleGraph,
    SimpleDiGraph,
    nv,
    add_edge!,
    rem_edge!,
    adjacency_matrix,
    edges,
    inneighbors,
    neighbors,
    outneighbors,
    dag_longest_path,
    maximal_cliques,
    yen_k_shortest_paths
import LinearAlgebra: norm
import BipartiteMatching

# TrackWireSegment = (net, lengthwise channel, start vertex, end vertex)
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
# pathlength 1, pathlength 2, dir1, dir2, intersection point
const IntersectionInfo{T} = Tuple{T, T, typeof(1.0°), typeof(1.0°), Point{T}}

"""
    ChannelRouter{T <: Coordinate}

A simple autorouter where wires can run on horizontal and vertical channels.

The router will attempt to connect pairs of pins, each with coordinates and a direction.
The indices of connected pins are specified by `nets`.

The router is initialized with a number of vertical and horizontal "channels", characterized
by a width and the coordinate of their center line. Each channel will be divided into some
number of tracks as necessary to route all nets.

Routing proceeds in two steps. The first is "channel assignment", which proceeds net by net,
choosing which channels the net's wire passes through on its way from one pin to the other. The second step
is "track assigment", which proceeds channel by channel. Wire segments are assigned to
tracks within the channel such that wire segments in the same track do not overlap.
"""
struct ChannelRouter{T <: Coordinate}
    channel_graph::SimpleGraph{Int}   # Channels/pins are vertices, intersections are edges
    net_pins::Vector{Tuple{Int, Int}} # Pairs of pins (indices in `pins`)
    net_wires::Vector{NetWire}        # Wire segments connecting pins for each net
    pins::Vector{PointHook{T}}        # Position and orientation of pins
    channels::Vector{RouteChannel{T}}   # List of channels
    # channel_capacities::Vector{Int}   # Maximum number of tracks per channel, not used
    # For each edge, information to find the intersection point
    channel_intersections::Dict{Tuple{Int, Int}, IntersectionInfo{T}}
    # Vector of vectors of all segments in each channel
    channel_segments::Vector{Vector{TrackWireSegment}}
    # Vector of vectors of all tracks in each channel [where each track is a vector of wire segments]
    channel_tracks::Vector{Vector{Track}}
    # Waypoints for each segment (used for visualizing router state)
    segment_waypoints::Dict{TrackWireSegment, PointHook{T}}
    net_paths::Vector{Path{T}}        # [Internals] Persistent path objects to populate after routing
end

""""
    ChannelRouter(
        nets::Vector{Tuple{Int, Int}},
        pin_hooks::Vector{<:Hook},
        channels::Vector{<:RouteChannel}
    )
"""
function ChannelRouter(
    nets,
    pin_hooks::Vector{<:Hook},
    channels::Vector{<:RouteChannel}
)
    T = promote_type(coordinatetype(pin_hooks), coordinatetype(channels))
    net_wires = [NetWire() for i in eachindex(nets)]
    channel_segments = [TrackWireSegment[] for i in eachindex(channels)]
    channel_tracks = [Track[] for i in eachindex(channels)]
    segment_waypoints = Dict{TrackWireSegment, PointHook{T}}()
    pins = [PointHook{T}(pin.p, pin.in_direction + 180°) for pin in pin_hooks]
    # Build channel graphs with full paths to avoid compound operations
    channel_paths = [ch.path for ch in channels]
    channel_graph, ixns = build_channel_graph(pins, channel_paths, T)
    return ChannelRouter{T}(
        channel_graph,
        nets,
        net_wires,
        pins,
        channels,
        ixns,
        channel_segments,
        channel_tracks,
        segment_waypoints,
        [Path{T}() for net in nets]
    )
end

function ChannelRouter(channels::Vector{RouteChannel{T}}) where {T}
    channel_segments = [TrackWireSegment[] for i in eachindex(channels)]
    channel_tracks = [Track[] for i in eachindex(channels)]
    segment_waypoints = Dict{TrackWireSegment, PointHook{T}}()
    return ChannelRouter{T}(
        SimpleGraph(),
        Tuple{Int,Int}[],
        NetWire[],
        PointHook{T}[],
        channels,
        Dict{Tuple{Int, Int}, IntersectionInfo{T}}(),
        channel_segments,
        channel_tracks,
        segment_waypoints,
        Path{T}[]
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
channel_coordinates(ar::ChannelRouter, channel, s) = ar.channels[channel].node.seg(s)
function channel_direction(ar::ChannelRouter, channel, s)
    is_pin(ar, channel) && return pin_direction(ar, graphidx_to_pin(ar, channel))
    return direction(ar.channels[channel].node.seg, s)
end
function channel_width(ar::ChannelRouter{T}, channel, s) where {T}
    # Intersecting channel is zero where a wire segment hits a pin
    is_pin(ar, channel) && return zero(T)
    return width(ar.channels[channel].node.sty, s)
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

function direction_at_intersection(ar::ChannelRouter,
    running_channel,
    intersecting_channel)
    # Intersecting channel is zero where a wire segment hits a pin
    if iszero(running_channel) || iszero(intersecting_channel)
        return 0.0°
    end
    ixn_info = channel_intersection(ar, running_channel, intersecting_channel)
    running_channel < intersecting_channel && return ixn_info[3]
    return ixn_info[4]
end

function width_at_intersection(ar::ChannelRouter{T},
    running_channel,
    intersecting_channel) where {T}

    ixn_info = channel_intersection(ar, running_channel, intersecting_channel)
    running_channel < intersecting_channel && return channel_width(ar, running_channel, ixn_info[1])
    return channel_width(ar, running_channel, ixn_info[2])
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
    ray_length = max(DeviceLayout.width(bbox), DeviceLayout.height(bbox))*sqrt(2)
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
            dir1 = direction(channels[v1_idx][node1_idx].seg, s1)
            dir2 = pins[v2_idx - length(channels)].in_direction
            s1 = pathlength_from_start(channels[v1_idx], node1_idx, s1)
            # Record intersection if it's the closest so far
            ixn_info = (s1, s2, dir1, dir2, p)
            _, old_ixn_info = get(pin_ixns, v2_idx,
                (v1_idx, ixn_info))
            old_distance = old_ixn_info[2]
            if s2 <= old_distance
                pin_ixns[v2_idx] = (v1_idx, ixn_info)
            end
        else # record intersection as edge in channel graph, with info in dict
            haskey(intersection_dict, (v1_idx, v2_idx)) && 
                error("Spaces $v1_idx and $v2_idx have multiple intersections")
            dir1 = direction(channels[v1_idx][node1_idx].seg, s1)
            dir2 = direction(channels[v2_idx][node2_idx].seg, s2)
            s1 = pathlength_from_start(channels[v1_idx], node1_idx, s1)
            s2 = pathlength_from_start(channels[v2_idx], node2_idx, s2)

            add_edge!(g, v1_idx, v2_idx)
            intersection_dict[(v1_idx, v2_idx)] = # All records have v1 < v2
                (s1, s2, dir1, dir2, p)
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
    channel_midpoint = channel_coordinates(ar, channel_idx, s)

    offset_distance = segment_offset(ar, ws)

    channel_dir = channel_direction(ar, channel_idx, s)
    return channel_midpoint + offset_distance * Point(-sin(channel_dir), cos(channel_dir))
end

"""
    segment_direction(ar::ChannelRouter, ws::TrackWireSegment)

The angle with the x-axis made by segment `ws` directed along its wire toward its end pin.
"""
function segment_direction(ar::ChannelRouter, ws::TrackWireSegment, s)
    off = segment_offset(ar, ws, s)
    seg = Paths.offset(ar.channels[running_channel(ws)].seg, off)
    return direction(seg, s)
end

function segment_mid_direction(ar::ChannelRouter, ws::TrackWireSegment)
    s0, s1 = interval(ar, ws)
    return segment_direction(ar, ws, (s0+s1)/2)
end

function segment_offset(ar::ChannelRouter{T}, ws::TrackWireSegment, s...) where {T}
    is_pin(ar, running_channel(ws)) && return zero(T)
    c = segment_track(ar, ws)
    isnothing(c) && return zero(T)
    return track_offset(ar, running_channel(ws), c, s...)
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

"""
    interval(ar::ChannelRouter, ws::TrackWireSegment)

A tuple `(start, stop)` of approximate channel pathlengths at which `ws` starts and stops.

If tracks have been assigned to the previous or next segments, then the track offset is
taken into account. Otherwise, the start and stop are at the centre line of the intersecting channel.

The interval is always a tuple with the lower bound as the first element.
"""
function interval(ar::ChannelRouter, ws::TrackWireSegment; use_track=true)
    start_channel, stop_channel = bounding_channels(ws)
    channel_idx = running_channel(ws)
    
    start_channel, stop_channel = bounding_channels(ws)
    s1 = pathlength_at_intersection(ar, channel_idx, start_channel)
    s2 = pathlength_at_intersection(ar, channel_idx, stop_channel)
    (!use_track || is_pin(ar, channel_idx)) && return _swap(s1, s2)
    # Could just do that for all cases
    # But if we want to break ties we would use offsets from previous/next segments, like:
    # return _swap(s1 + segment_offset(ar, prev(ws)), s2 - segment_offset(ar, next(ws)))
    # But sign needs to take into account relative orientations of channels
    pt, nt = prev_next_tendency(ar, ws; use_segment_direction=false)
    s_start = pathlength_at_intersection(ar, start_channel, channel_idx)
    s_stop = pathlength_at_intersection(ar, stop_channel, channel_idx)
    return _swap(s1 + pt*segment_offset(ar, prev(ar, ws), s_start),
                 s2 - nt*segment_offset(ar, next(ar, ws), s_stop))
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

Currently just finds a "shortest path" between pins, where 
distance is not physical distance but graph distance (the number of edges in the path).
In other words, each net takes a path that changes channels a minimal number of times.
Does not currently take congestion, crossings, or channel capacity into account.
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
"""
function assign_tracks!(ar::ChannelRouter{T}) where {T}
    # Order of channels will change results
    # Generally you want early channels to be those with more pins adjoining them
    # Or fewer non-pinned segments
    # Because those channels will inform constraints on later channels
    # For now the user can worry about that
    for channel = 1:num_channels(ar)
        assign_tracks_matching!(ar, channel)
    end
end

function merge_in_vcg!(vcg, v1, v2)
    # Children of one become children of the other
    for child in outneighbors(vcg, v1) # Directed neighbor v1 -> child
        add_edge!(vcg, v2, child)
    end
    for child in outneighbors(vcg, v2) # Directed neighbor v2 -> child
        add_edge!(vcg, v1, child)
    end
    # Parents of one become parents of the other
    for parent in inneighbors(vcg, v1) # parent -> v1
        add_edge!(vcg, parent, v2)
    end
    for parent in inneighbors(vcg, v2)
        add_edge!(vcg, parent, v1)
    end
end

function assign_tracks_matching!(ar, channel)
    # Yoshimura and Kuh Algorithm #2
    # We will not check whether there are cycles in the vertical constraint graph, just assume
    vcg, zone_ig = channel_problem_graphs(ar, channel)
    zones = maximal_cliques(zone_ig)
    isempty(zones) && return
    # Need to sort zones left to right (by their minimal element)
    sort!(zones, by=minimum)
    # Same with wire segments, to follow same indexing as graphs
    wiresegs_ascending = sort(channel_segments(ar, channel), by=(ws) -> interval(ar, ws))
    L = Set{Int}()
    active = Set(zones[1])
    merged_groups = Dict{Int, Vector{Int}}()
    merged_into = Dict{Int, Int}() # merged_into[x] = y means y was merged into x with y > x
    merging_graph = SimpleGraph(length(wiresegs_ascending))
    matching = Dict{Int, Int}()
    R = Set{Int}()

    for (zone, nextzone) in zip(zones, [zones[2:end]..., Int[]]) # Extra empty zone at end
        # Merge nets terminating in current zone to left side
        if length(zones) > 1
            for v in active # v was in nextzone last round
                if !(v in nextzone) # v terminates in current zone
                    pop!(active, v) # no longer active
                    push!(L, v)     # add to left side
                    if haskey(matching, v)
                        # Matched in previous round, so update VCG
                        merge_in_vcg!(vcg, matching[v], v)
                        # Record merge
                        merged_into[matching[v]] = v
                        group = get!(merged_groups, matching[v], Int[matching[v]])
                        push!(group, v)
                        merged_groups[v] = group
                        # Replace match with v as representative of merged group in L
                        pop!(L, matching[v]) # match must have been in L
                    end
                    v in R && pop!(R, v)
                end
            end
        end
        # Add nets starting in next zone to right side
        for v in nextzone
            if !(v in active)
                push!(R, v)
                push!(active, v)
            end
        end
        # Remove all edges in merging graph, start fresh this iteration
        for edge in edges(merging_graph)
            rem_edge!(merging_graph, edge)
        end
        # Add edges between left and right when they can be merged
        for l in L
            # Only use rightmost in any merged group
            haskey(merged_into, l) && continue
            for r in R
                if !segments_overlap(ar, wiresegs_ascending[l], wiresegs_ascending[r])
                    mergeable = isempty(yen_k_shortest_paths(vcg, l, r).paths) && isempty(yen_k_shortest_paths(vcg, r, l).paths)
                    mergeable && add_edge!(merging_graph, l, r)
                end
            end
        end
        # Find max cardinality valid matching, removing edges as necessary
        matching = best_matching!(merging_graph, vcg)[1] # Just the dict, not the indicator
    end
    # Assign merged groups to tracks according to VCG
    tracks = channel_tracks(ar, channel)
    # At the end of this process, segments are merged into layers in the VCG
    # So the longest directed path gives a representative of each merged group
    high_to_low = dag_longest_path(vcg) # If vcg was acyclic to begin with, it is still acyclic
    num_tracks = length(high_to_low)
    for v in 1:nv(vcg)
        if !haskey(merged_groups, v)
            merged_groups[v] = [v]
        end
    end
    for v in reverse(high_to_low)
        # Create a track with `v` and all others merged with it
        push!(tracks, wiresegs_ascending[merged_groups[v]])
    end
end

function segments_overlap(ar, seg1, seg2)
    low1, high1 = interval(ar, seg1)
    low2, high2 = interval(ar, seg2)
    if low1 <= low2 # segments are in ascending order
        return low2 < high1 # no overlap for '==' means knock-knees are OK
    else # descending order
        return low1 < high2
    end
end

function best_matching!(merging_graph, vcg)
    # Collect set of edges to remove
    to_remove = Set{Tuple{Int, Int}}()
    # Create a temporary copy to help find problematic edges
    edge_selection_graph = copy(merging_graph)
    working_vcg = copy(vcg)
    # Collect "deleted" vertices in edge_selection_graph 
    # Vertices aren't labelled, just indexed, so we don't actually delete them
    ignored = Set{Int}() 
    # While working graphs have vertices, keep collecting edges to remove from merging graph
    while length(ignored) < nv(edge_selection_graph)
        # 1. Find nodes with no VCG ancestors, remove edges between them
        # 2. If there are nodes with no edges in edge_selection_graph, remove them from working graphs and go back to 1
        # 3. Now the node with the fewest edges has at least one edge
        # That edge corresponds to a merging that would cause a problem in the VCG
        # so then we mark it for removal from the merging graph
        # and remove it from our working graphs
        min_neighbors = nv(edge_selection_graph)
        v_min_neighbors = 0
        orphans = true
        while orphans
            min_neighbors = nv(edge_selection_graph)
            v_min_neighbors = 0
            orphans = false
            # Remove edges between vertices with no ancestors
            # Then they will not be selected for removal from `merging_graph`
            no_ancestors = Int[]
            for v in 1:nv(edge_selection_graph)
                v in ignored && continue
                if isempty(inneighbors(working_vcg, v)) || all([w in ignored for w in inneighbors(working_vcg, v)])
                    # v has no surviving ancestors, remove edges to other such vertices
                    for w in no_ancestors
                        rem_edge!(edge_selection_graph, v, w)
                    end
                    push!(no_ancestors, v)
                end
            end
            # Find nodes with minimum number of edges
            for v in 1:nv(edge_selection_graph)
                v in ignored && continue
                nbs = neighbors(edge_selection_graph, v)
                if length(nbs) < min_neighbors
                    min_neighbors = length(nbs)
                    v_min_neighbors = v
                end
                # If any nodes have no edges, remove them and go back
                if isempty(nbs)
                    min_neighbors = 0
                    orphans = true
                    push!(ignored, v)
                    # No need to remove edges from edge_selection_graph because it doesn't have any
                    # "Removing" v from working VCG means merging edges betwen its parents and children
                    for parent in inneighbors(working_vcg, v)
                        for child in outneighbors(working_vcg, v)
                            add_edge!(working_vcg, parent, child)
                        end
                    end
                end
            end
        end
        #  Remove a node with fewest edges, remove and collect those edges
        if !iszero(v_min_neighbors) && min_neighbors > 0
            for nb in copy(neighbors(edge_selection_graph, v_min_neighbors)) # copy bc neighbors is changing in the loop
                rem_edge!(edge_selection_graph, v_min_neighbors, nb)
                push!(to_remove, (v_min_neighbors, nb))
            end
            push!(ignored, v_min_neighbors)
            # "Removing" v from working VCG means merging edges betwen its parents and children
            for parent in inneighbors(working_vcg, v_min_neighbors)
                for child in outneighbors(working_vcg, v_min_neighbors)
                    add_edge!(working_vcg, parent, child)
                end
            end
        end
    end
    # Remove marked edges
    for edge in to_remove
        rem_edge!(merging_graph, edge...)
    end
    # Any matching is feasible now that we've removed marked edges
    return BipartiteMatching.findmaxcardinalitybipartitematching(
            BitMatrix(adjacency_matrix(merging_graph))
        )
end

function merge_segments!(zone_ig, vcg, ws1, ws2)
    merge_vertices!(zone_ig, [ws1, ws2])
    return merge_vertices(vcg, [ws1, ws2]) # No in-place for directed graph
end

function against_channel(ar, wireseg)
    channel_idx = running_channel(wireseg)
    start_channel, stop_channel = bounding_channels(wireseg)
    s1 = pathlength_at_intersection(ar, channel_idx, start_channel)
    s2 = pathlength_at_intersection(ar, channel_idx, stop_channel)
    return s1 > s2
end

function channel_problem_graphs(ar::ChannelRouter, channel)
    wiresegs_ascending = sort(channel_segments(ar, channel), by=(ws) -> interval(ar, ws))
    # Y&K zone representation as interval graph
    # Edge between each pair of segments that overlap
    zone_ig = SimpleGraph(length(wiresegs_ascending))
    # Condrat et al. VCG with avoidable crossings as constraints
    # Not handled: constraints from vertically aligned pin positions
    vcg = SimpleDiGraph(length(wiresegs_ascending)) # just a fresh graph
    for (idx1, seg1) in pairs(wiresegs_ascending)
        low1, high1 = interval(ar, seg1)
        for (idx2, seg2) in collect(pairs(wiresegs_ascending))[idx1+1:end]
            low2, high2 = interval(ar, seg2)

            # If there is no overlap, break and move on to next seg1
            # Use >= instead of > to potentially allow knock-knees
            low2 >= high1 && break # All subsequent seg2 have low2 >= high1
            # There is overlap, so add an edge to the interval graph
            add_edge!(zone_ig, idx1, idx2)
            # Now check if crossing is unavoidable
            pt1, nt1 = prev_next_tendency(ar, seg1)
            pt2, nt2 = prev_next_tendency(ar, seg2)
            # If seg1 and seg2 enter and exit at the same place with same tendency, then crossing
            # may be avoidable, but this channel can't say which goes on top yet
            (low1 == high1 && low2 == high2 && pt1 == pt2 && nt1 == nt2) && break
            low1_tend, high1_tend = against_channel(ar, seg1) ? (nt1, pt1) : (pt1, nt1)
            low2_tend, high2_tend = against_channel(ar, seg2) ? (nt2, pt2) : (pt2, nt2)
            avoidable = is_avoidable(low1, high1, low2, high2,
                low1_tend, high1_tend, low2_tend, high2_tend)
            !avoidable && continue

            # Crossing is avoidable, so add a constraint
            # Determine which goes on top based on the lower bound tendency of seg2
            # Is prev or next the lower bound?
            # top is rightmost segment iff its lower bound tends towards higher tracks
            top = (idx1, idx2)[1 + (low2_tend == 1)]
            bottom = (idx1, idx2)[2 - (low2_tend == 1)]
            add_edge!(vcg, top, bottom) # VCG has edge from higher to lower tracks
        end
    end
    return vcg, zone_ig
end

function is_avoidable(low1, high1, low2, high2, low1_tend, high1_tend, low2_tend, high2_tend)
    if high1 < high2
        # 1 ____
        # 2   ____
        order = [1, 2, 1, 2] # low1 <= low2 < high1 < high2
        ordered_tendency = [low1_tend, low2_tend, high1_tend, high2_tend]
    else
        # 1 _____
        # 2   __
        order = [1, 2, 2, 1] # low1 <= low2 < high2 <= high1
        ordered_tendency = [low1_tend, low2_tend, high2_tend, high1_tend]
    end
    up = (ordered_tendency .== 1)
    down = (!).(up)
    ccw_order = [reverse(order[up]); order[down]]
    # Crossing is avoidable if same net has both endpoints adjacent
    # on the clock
    avoidable = (ccw_order[1] == ccw_order[2] ||
        ccw_order[2] == ccw_order[3])
    # Also, if seg1 and seg2 have an endpoint at the same place,
    # then crossing in this channel may be avoidable but depends on
    # other channel; assume other channel will agree
    avoidable = (avoidable || (low1 == low2 || high1 == high2))
end

# +1 if segment crosses over high track index in ws's channel
function prev_next_tendency(ar, ws; use_segment_direction=true)
    channel_idx = running_channel(ws)
    start_channel, stop_channel = bounding_channels(ws)
    # Distances along bounding and running channels
    s_along_start = pathlength_at_intersection(ar, start_channel, channel_idx)
    s1 = pathlength_at_intersection(ar, channel_idx, start_channel)
    s2 = pathlength_at_intersection(ar, channel_idx, stop_channel)
    s_along_stop = pathlength_at_intersection(ar, stop_channel,  channel_idx)
    # Directions of bounding and running channels
    start_dir = direction_at_intersection(ar, start_channel, channel_idx)
    dir1 = direction_at_intersection(ar, channel_idx, start_channel)
    dir2 = direction_at_intersection(ar, channel_idx, stop_channel)
    stop_dir = direction_at_intersection(ar, stop_channel, channel_idx)
    # Tendencies
    ## +ve = wire makes CCW turns
    ## But actual bends depend on direction of wires vs channels
    ### Signs of angles made by channel intersections
    sgn_bend1 = sign(rem2pi(uconvert(NoUnits, dir1 - start_dir), RoundNearest))
    sgn_bend2 = sign(rem2pi(uconvert(NoUnits, stop_dir - dir2), RoundNearest))
    !use_segment_direction && return (sgn_bend1, sgn_bend2)
    ### Need to multiply according to direction in channel
    ### Is prev upper-bounded by ws? Then it goes along with channel
    sgn_start = s_along_start >= last(interval(ar, prev(ar, ws), use_track=false)) ? 1 : -1
    ### Is next upper-bounded by ws? Then it goes against channel
    sgn_stop = s_along_stop >= last(interval(ar, next(ar, ws), use_track=false)) ? -1 : 1
    ### Bend signs get another -1 if ws runs opposite to its channel direction
    ### But then tendency definition is reversed also
    return (sgn_start * sgn_bend1, sgn_stop * sgn_bend2)
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
    c = DeviceLayout.Cell{T}("track_viz")

    rts = make_routes!(ar, rule)
    paths = [Path(rt, Paths.Trace(wire_width)) for rt in rts]

    DeviceLayout.render!.(c, paths, GDSMeta())
    rect = track_rectangles(ar)
    DeviceLayout.render!.(c, rect, GDSMeta(2))
    rect2 = channel_rectangles(ar)
    DeviceLayout.render!.(c, rect2, GDSMeta(3))
    lab = track_labels(ar)
    [DeviceLayout.text!(c, l..., GDSMeta(4)) for l in lab]
    [DeviceLayout.render!(c, DeviceLayout.circle(wire_width) + p, GDSMeta(5)) for rt in rts for p in rt.waypoints]
    plab = pin_labels(ar)
    [DeviceLayout.text!(c, l..., GDSMeta(6)) for l in plab]
    wlab = waypoint_labels(ar)
    [
        DeviceLayout.text!(c, l..., GDSMeta(8), xalign=DeviceLayout.Align.XCenter(), yalign=DeviceLayout.Align.YCenter())
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

######## Actually doing the path construction
struct AutoChannelRouting{T <: Coordinate} <: AbstractMultiRouting
    channels::Vector{RouteChannel{T}}
    transition_rule::RouteRule
    transition_margin::T
    router::ChannelRouter{T}
end
entry_rules(r::AutoChannelRouting) = Iterators.repeated(r.transition_rule)
exit_rule(r::AutoChannelRouting) = r.transition_rule

function track_path_segments(rule::AutoChannelRouting, pa::Path, _)
    return [track_path_segment(rule.router, channel, pa; margin=rule.transition_margin)
        for channel in rule.channels[channels_taken(rule.router, pa)]]
end

function track_path_segment(r::ChannelRouter{T}, ch::RouteChannel, pa::Path; margin=zero(T)) where {T}
    # Get the track wire segment from the router
    # Assume there is exactly one wire segment belonging to this path in the channel
    # Channel node might have been converted to store in router, so just check start point/direction
    channel_idx = findfirst(chn -> p0(chn.seg) ≈ p0(ch.path) && α0(chn.seg) == α0(ch.path), r.channels)
    wireseg_idx = findfirst(ws -> running_channel(ws) == channel_idx, channel_segments(r, channel_idx))
    wireseg = channel_segments(r, channel_idx)[wireseg_idx]
    track_idx = segment_track(r, wireseg)
    # Get the starting and ending pathlengths
    start_channel, stop_channel = bounding_channels(wireseg)
    wireseg_start = pathlength_at_intersection(ar, channel_idx, start_channel)
    wireseg_stop = pathlength_at_intersection(ar, channel_idx, stop_channel)
    prev_width = width_at_intersection(ar, start_channel, channel_idx)
    next_width = width_at_intersection(ar, stop_channel, channel_idx)
    channel_section = segment_channel_section(channel, wireseg_start, wireseg_stop, prev_width, next_width; margin)
    # Return channel section segment offset by width according to track
    return track_path_segment(length(channel_tracks(ar, channel_idx)), channel_section, track_idx)
end

function channels_taken(r::ChannelRouter, pa::Path)
    net_idx = only(indexin(pa, r.net_paths))
    channels_taken = [running_channel(wireseg) for wireseg in net_wire(r, net_idx)]
end

function _update_with_graph!(rule::AutoChannelRouting, route_node, graph; kwargs...)
    push!(rule.router.net_paths, route_node.component._path)
end

function _update_with_plan!(rule::AutoChannelRouting{T}, route_node, sch) where {T}
    pin_idx = length(rule.router.pins) + 1
    push!(pins, hooks(route_node.component).p0)
    push!(pins, hooks(route_node.component).p1)
    push!(rule.router.net_pins, (pin_idx, pin_idx + 1))
    # If all paths have been added, go ahead and run autorouting
    if length(rule.router.net_pins) == length(rule.router.net_paths)
        build_channel_graph(rule.router.pins, rule.router.channels, T)
        assign_channels!(rule.router)
        assign_tracks!(ar)
    end
end