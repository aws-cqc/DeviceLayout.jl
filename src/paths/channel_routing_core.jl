# Pure algorithmic core for channel routing.
# No DeviceLayout geometry types — communicates through AbstractChannelProblem interface.
#
# References:
# Original: Hashimoto and Stevens https://cs.baylor.edu/~maurer/CSI5346/originalCR.pdf
# VCG, HCG/Zone representation, doglegs, merging: Yoshimura and Kuh https://my.ece.utah.edu/~kalla/phy_des/yk.pdf
# Crossing-aware: Condrat, Kalla, Blair https://my.ece.utah.edu/~kalla/papers/condrat_crossing-aware_channel_routing_for_photonic_waveguides.pdf

import Graphs:
    SimpleGraph,
    SimpleDiGraph,
    nv,
    ne,
    add_edge!,
    add_vertex!,
    rem_edge!,
    has_edge,
    edges,
    inneighbors,
    neighbors,
    outneighbors,
    maximal_cliques,
    dijkstra_shortest_paths,
    enumerate_paths,
    topological_sort_by_dfs
import SparseArrays: sparse
import BipartiteMatching

# ──── Pure types ─────────────────────────────────────────────────────────────

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

struct AuxiliaryGraph{T, M <: AbstractMatrix{T}}
    graph::SimpleGraph{Int}
    distmx::M
    aux_to_edge::Vector{Tuple{Int, Int}}       # aux vertex → original (u, v) edge
    edge_to_aux::Dict{Tuple{Int, Int}, Int}     # original (u, v) edge → aux vertex
end

# ──── Abstract interface ─────────────────────────────────────────────────────

"""
    AbstractChannelProblem{T}

Abstract supertype for channel routing problems.

Subtypes must implement the following interface functions so that the core
channel-routing algorithms can operate without knowledge of the underlying
geometry representation:

  - `channel_graph(prob)::SimpleGraph{Int}`
  - `num_channels(prob)::Int`
  - `num_nets(prob)::Int`
  - `num_pins(prob)::Int`
  - `net_pins(prob, net)::Tuple{Int,Int}`
  - `net_wire(prob, net)::NetWire`
  - `channel_segments(prob, ch)::Vector{TrackWireSegment}`
  - `channel_tracks(prob, ch)::Vector{Track}`
  - `num_tracks(prob, ch)::Int`
  - `pathlength_at_intersection(prob, ch1, ch2)::T`
  - `direction_at_intersection(prob, ch1, ch2)::Float64` (radians)
  - `channel_width(prob, ch, s)::T`
  - `is_pin(prob, idx)::Bool`
  - `segment_offset(prob, ws, s...; use_wire_direction)::T`
"""
abstract type AbstractChannelProblem{T} end

function channel_graph end
function num_channels end
function num_nets end
function num_pins end
function net_pins end
function net_wire end
function channel_segments end
function channel_tracks end
function num_tracks end
function pathlength_at_intersection end
function direction_at_intersection end
function channel_width end
function is_pin end
function segment_offset end

# ──── Pure utility functions ─────────────────────────────────────────────────

_swap(x, y) = (y > x ? (x, y) : (y, x))

function _shared_vertex(edge_a::Tuple{Int, Int}, edge_b::Tuple{Int, Int})
    a1, a2 = edge_a
    b1, b2 = edge_b
    a1 in (b1, b2) && return a1
    a2 in (b1, b2) && return a2
    return error("Edges $edge_a and $edge_b share no vertex")
end

pin_to_graphidx(ar::AbstractChannelProblem, p::Int) = p + num_channels(ar)
graphidx_to_pin(ar::AbstractChannelProblem, graphidx::Int) = graphidx - num_channels(ar)
is_pin(ar::AbstractChannelProblem, graphidx) = graphidx > num_channels(ar)
adjoining_channel(ar::AbstractChannelProblem, pin) =
    neighbors(channel_graph(ar), pin_to_graphidx(ar, pin))[1]

# Offset coordinate or function for the section of track with given width
function track_section_offset(n_tracks, section_width::Number, track_idx; reversed=false)
    # (spacing) * number of tracks away from middle track
    sgn = reversed ? -1 : 1
    spacing = section_width / (n_tracks + 1)
    return sgn * spacing * ((1 + n_tracks) / 2 - track_idx)
end

function track_section_offset(n_tracks, section_width::Function, track_idx; reversed=false)
    # (spacing) * number of tracks away from middle track
    return t ->
        (reversed ? -1 : 1) *
        (section_width(t) / (n_tracks + 1)) *
        ((1 + n_tracks) / 2 - track_idx)
end

# ──── Track/segment queries ──────────────────────────────────────────────────

"""
    segment_track(ar::AbstractChannelProblem, ws::TrackWireSegment)

The track index of `ws`, or `nothing` if no track has been assigned.
"""
function segment_track(ar::AbstractChannelProblem, ws::TrackWireSegment)
    channel_idx = running_channel(ws)
    tracks = channel_tracks(ar, channel_idx)
    track_idx = findfirst((c) -> ws in c, tracks)
    return track_idx
end

"""
    next(ar::AbstractChannelProblem, ws::TrackWireSegment)

The wire segment after `ws`, with the wire directed from the source to the destination pin.
"""
function next(ar::AbstractChannelProblem, ws::TrackWireSegment)
    net_idx = net_index(ws)
    segs = net_wire(ar, net_idx)
    idx = findfirst(isequal(ws), segs)
    if idx == length(segs)
        final_pin_idx = pin_to_graphidx(ar, last(net_pins(ar, net_idx)))
        return TrackWireSegment(net_idx, final_pin_idx, running_channel(ws), 0)
    end
    return segs[idx + 1]
end

"""
    prev(ar::AbstractChannelProblem, ws::TrackWireSegment)

The wire segment before `ws`, with the wire directed from the source to the destination pin.
"""
function prev(ar::AbstractChannelProblem, ws::TrackWireSegment)
    net_idx = net_index(ws)
    segs = net_wire(ar, net_idx)
    idx = findfirst(isequal(ws), segs)
    if idx == 1
        first_pin_idx = pin_to_graphidx(ar, first(net_pins(ar, net_idx)))
        return TrackWireSegment(net_idx, first_pin_idx, 0, running_channel(ws))
    end
    return segs[idx - 1]
end

function against_channel(ar, wireseg)
    s1, s2 = unsorted_interval(ar, wireseg)
    return s1 > s2
end

# ──── Interval computation ───────────────────────────────────────────────────

"""
    interval(ar::AbstractChannelProblem, ws::TrackWireSegment)

A tuple `(start, stop)` of approximate channel pathlengths at which `ws` starts and stops.

If tracks have been assigned to the previous or next segments, then the track offset is
taken into account. Otherwise, the start and stop are at the centre line of the intersecting channel.

The interval is always a tuple with the lower bound as the first element.
"""
function interval(ar::AbstractChannelProblem, ws::TrackWireSegment; use_track=true)
    return _swap(unsorted_interval(ar, ws; use_track)...)
end

function unsorted_interval(ar::AbstractChannelProblem, ws::TrackWireSegment; use_track=true)
    start_channel, stop_channel = bounding_channels(ws)
    channel_idx = running_channel(ws)

    start_channel, stop_channel = bounding_channels(ws)
    s1 = pathlength_at_intersection(ar, channel_idx, start_channel)
    s2 = pathlength_at_intersection(ar, channel_idx, stop_channel)
    (!use_track || is_pin(ar, channel_idx)) && return _swap(s1, s2)
    # Could just do that for all cases
    # But if we want to break ties we use offsets from previous/next segments
    # Offset sign needs to take into account relative directions of segments in channels
    s_start = pathlength_at_intersection(ar, start_channel, channel_idx)
    s_stop = pathlength_at_intersection(ar, stop_channel, channel_idx)
    pt, nt = prev_next_tendency(ar, ws)
    start_dir = direction_at_intersection(ar, start_channel, channel_idx)
    dir1 = direction_at_intersection(ar, channel_idx, start_channel)
    dir2 = direction_at_intersection(ar, channel_idx, stop_channel)
    stop_dir = direction_at_intersection(ar, stop_channel, channel_idx)
    # Offset also depends neighbor track offsets
    α_ixn_start = (dir1 - start_dir)
    α_ixn_stop = (stop_dir - dir2)
    prev_offset_proj =
        segment_offset(ar, prev(ar, ws), s_start; use_wire_direction=false) /
        sin(α_ixn_start)
    next_offset_proj =
        segment_offset(ar, next(ar, ws), s_stop; use_wire_direction=false) / sin(α_ixn_stop)
    # Offset *also* depends on this wire segment's offset at a non-90° intersection
    start_offset_proj =
        -segment_offset(ar, ws, s_start; use_wire_direction=false) / tan(α_ixn_start)
    stop_offset_proj =
        -segment_offset(ar, ws, s_stop; use_wire_direction=false) / tan(α_ixn_stop)
    # This is approximate on bending or tapered tracks
    return s1 + (prev_offset_proj + start_offset_proj),
    s2 - (next_offset_proj + stop_offset_proj)
end

# ──── Tendency computation ───────────────────────────────────────────────────

# +1 if segment crosses over low track index in ws's channel
function prev_next_tendency(ar, ws; use_wire_direction=true)
    channel_idx = running_channel(ws)
    start_channel, stop_channel = bounding_channels(ws)
    # Distances along bounding channels
    s_along_start = pathlength_at_intersection(ar, start_channel, channel_idx)
    s_along_stop = pathlength_at_intersection(ar, stop_channel, channel_idx)
    # Directions of bounding and running channels (Float64 radians from interface)
    start_dir = direction_at_intersection(ar, start_channel, channel_idx)
    dir1 = direction_at_intersection(ar, channel_idx, start_channel)
    dir2 = direction_at_intersection(ar, channel_idx, stop_channel)
    stop_dir = direction_at_intersection(ar, stop_channel, channel_idx)
    # Tendencies
    ## +ve = wire makes CCW turns
    ## But actual bends depend on direction of wires vs channels
    ### Signs of angles made by channel intersections
    sgn_bend1 = sign(rem2pi(dir1 - start_dir, RoundNearest))
    sgn_bend2 = sign(rem2pi(stop_dir - dir2, RoundNearest))
    !use_wire_direction && return (sgn_bend1, sgn_bend2)
    ### Need to multiply according to direction in channel
    ### Is prev upper-bounded by ws? Then it goes along with channel
    sgn_start = s_along_start >= last(interval(ar, prev(ar, ws), use_track=false)) ? 1 : -1
    ### Is next upper-bounded by ws? Then it goes against channel
    sgn_stop = s_along_stop >= last(interval(ar, next(ar, ws), use_track=false)) ? -1 : 1
    ### Bend signs get another -1 if ws runs opposite to its channel direction
    ### But then tendency definition is reversed also
    return (sgn_start * sgn_bend1, sgn_stop * sgn_bend2)
end

# ──── Overlap and avoidability ───────────────────────────────────────────────

function segments_overlap(ar, seg1, seg2)
    low1, high1 = interval(ar, seg1)
    low2, high2 = interval(ar, seg2)
    if low1 <= low2 # segments are in ascending order
        low2 < high1 && return true
        low2 == high1 || return false
        # Boundary case: check if knock-knee is actually possible
        return _same_tendency_at_boundary(ar, seg1, seg2)
    else # descending order, just reverse the roles
        low1 < high2 && return true
        low1 == high2 || return false
        return _same_tendency_at_boundary(ar, seg2, seg1)
    end
end

function _same_tendency_at_boundary(ar, seg1, seg2)
    p1, n1 = bounding_channels(seg1)
    p2, n2 = bounding_channels(seg2)
    shared_boundary = [2 - 1 * (p1 == p2 || p1 == n2), 2 - 1 * (p2 == p1 || p2 == n1)]
    t1 = prev_next_tendency(ar, seg1)
    t2 = prev_next_tendency(ar, seg2)
    return t1[shared_boundary[1]] == t2[shared_boundary[2]]
end

function is_avoidable(
    low1,
    high1,
    low2,
    high2,
    low1_tend,
    high1_tend,
    low2_tend,
    high2_tend
)
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
    avoidable = (ccw_order[1] == ccw_order[2] || ccw_order[2] == ccw_order[3])
    # Also, if seg1 and seg2 have an endpoint at the same place and don't make an X,
    # then crossing in this channel may be avoidable but depends on
    # other channel; assume other channel will agree
    depends =
        ((low1 == low2) || high1 == high2) &&
        ((low1_tend == low2_tend) || (high1_tend == high2_tend))
    avoidable = (avoidable || depends)
    return avoidable
end

# ──── Graph algorithms ───────────────────────────────────────────────────────

"""
    build_auxiliary_graph(ar::AbstractChannelProblem)

Build an auxiliary graph where each vertex represents an intersection point (edge in the
channel graph) and edges connect consecutive intersections along the same channel, weighted
by the physical distance between them.
"""
function build_auxiliary_graph(ar::AbstractChannelProblem{T}) where {T}
    g = channel_graph(ar)
    n_aux = ne(g)

    # Map channel-graph edges to auxiliary vertices
    aux_to_edge = Vector{Tuple{Int, Int}}(undef, n_aux)
    edge_to_aux = Dict{Tuple{Int, Int}, Int}()
    for (i, e) in enumerate(edges(g))
        key = _swap(e.src, e.dst)
        aux_to_edge[i] = key
        edge_to_aux[key] = i
    end

    # Build auxiliary graph: chain consecutive intersections per channel
    aux_g = SimpleGraph(n_aux)
    I = Int[]
    J = Int[]
    V = T[]
    for ch = 1:num_channels(ar)
        nbs = neighbors(g, ch)
        length(nbs) < 2 && continue

        # Collect (pathlength_along_ch, aux_vertex) for each intersection on this channel
        ch_ixns = Tuple{T, Int}[
            (pathlength_at_intersection(ar, ch, nb), edge_to_aux[_swap(ch, nb)]) for
            nb in nbs
        ]
        sort!(ch_ixns, by=first)

        # Connect consecutive intersection points
        for k = 1:(length(ch_ixns) - 1)
            s1, aux1 = ch_ixns[k]
            s2, aux2 = ch_ixns[k + 1]
            add_edge!(aux_g, aux1, aux2)
            w = abs(s2 - s1)
            push!(I, aux1)
            push!(J, aux2)
            push!(V, w)
            push!(I, aux2)
            push!(J, aux1)
            push!(V, w)
        end
    end

    distmx = sparse(I, J, V, n_aux, n_aux)
    return AuxiliaryGraph(aux_g, distmx, aux_to_edge, edge_to_aux)
end

"""
    shortest_path_between_pins(ar::AbstractChannelProblem, pin_1::Int, pin_2::Int, aux::AuxiliaryGraph)

A shortest path minimizing physical distance (sum of arclengths along channels between
intersection points), using a precomputed [`AuxiliaryGraph`](@ref).

In both cases, the returned path is a list of vertex indices
`[pin_gidx, ch1, ..., chN, pin_gidx]`.
"""
function shortest_path_between_pins(
    ar::AbstractChannelProblem,
    p0::Int,
    p1::Int,
    aux::AuxiliaryGraph
)
    pin0_gidx = pin_to_graphidx(ar, p0)
    pin1_gidx = pin_to_graphidx(ar, p1)
    src_aux = aux.edge_to_aux[_swap(pin0_gidx, adjoining_channel(ar, p0))]
    dst_aux = aux.edge_to_aux[_swap(pin1_gidx, adjoining_channel(ar, p1))]

    ds = dijkstra_shortest_paths(aux.graph, src_aux, aux.distmx)
    aux_path = enumerate_paths(ds, dst_aux)
    isempty(aux_path) && error("No path between pins $p0 and $p1")

    # Convert aux vertices back to channel-graph vertex sequence.
    # Skip consecutive duplicates: the aux path may traverse multiple intersections on
    # the same channel, which just means a longer segment on that channel.
    path = Int[pin0_gidx]
    for i = 1:(length(aux_path) - 1)
        ch = _shared_vertex(aux.aux_to_edge[aux_path[i]], aux.aux_to_edge[aux_path[i + 1]])
        if ch != last(path)
            push!(path, ch)
        end
    end
    push!(path, pin1_gidx)
    return path
end

# ──── Channel assignment ─────────────────────────────────────────────────────

"""
    assign_channels!(ar::AbstractChannelProblem)

Performs channel assignment for `ar`.

Finds a shortest path between pins minimizing physical distance along channels
(sum of arclengths between intersection points), using an auxiliary intersection-point
graph with Dijkstra's algorithm.
Does not currently take congestion, crossings, or channel capacity into account.
"""
function assign_channels!(
    ar::AbstractChannelProblem;
    net_indices=eachindex(ar.net_pins),
    fixed_paths::Dict{Int, Vector{Int}}=Dict{Int, Vector{Int}}()
)
    aux = build_auxiliary_graph(ar)
    for (idx_net, net) in zip(net_indices, ar.net_pins[net_indices])
        p0, p1 = net
        path = if idx_net in keys(fixed_paths)
            [
                pin_to_graphidx(ar, p0)
                fixed_paths[idx_net]
                pin_to_graphidx(ar, p1)
            ]
        else
            shortest_path_between_pins(ar, p0, p1, aux)
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

# ──── Track assignment ───────────────────────────────────────────────────────

"""
    assign_tracks!(ar::AbstractChannelProblem)

Performs track assignment for all channels in `ar`.

Track assignment operates on **all** channels, not a subset. Re-running after modifying
a single net will reassign tracks globally in every channel that contains wire segments.
"""
function assign_tracks!(ar::AbstractChannelProblem)
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
            for v in collect(active) # v was in nextzone last round
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
        merging_graph = SimpleGraph(length(wiresegs_ascending))
        # Add edges between left and right when they can be merged
        high_to_low = topological_sort_by_dfs(vcg)
        dists_from_r = Dict(r => dag_shortest_paths(vcg, high_to_low, r) for r in R)
        for l in L
            # Only use rightmost in any merged group
            haskey(merged_into, l) && continue
            dists_from_l = dag_shortest_paths(vcg, high_to_low, l)
            for r in R
                mergeable = dists_from_l[r] >= nv(vcg) && dists_from_r[r][l] >= nv(vcg)
                !mergeable && continue
                if !segments_overlap(ar, wiresegs_ascending[l], wiresegs_ascending[r])
                    add_edge!(merging_graph, l, r)
                end
            end
        end
        # Find max cardinality valid matching, removing edges as necessary
        matching = best_matching!(merging_graph, vcg, L, R)
    end
    # Assign merged groups to tracks according to VCG
    tracks = channel_tracks(ar, channel)
    # At the end of this process, segments are merged into layers in the VCG
    # The longest directed path gives a representative of each merged group where track height is max
    # But VCG may be a partial order so use topological sort
    high_to_low = topological_sort_by_dfs(vcg) # If vcg was acyclic to begin with, it is still acyclic
    for v = 1:nv(vcg)
        if !haskey(merged_groups, v)
            merged_groups[v] = [v]
        end
    end
    assigned = Int[]
    for v in high_to_low # high in vcg => low track index
        # Create a track with `v` and all others merged with it
        v in assigned && continue
        push!(tracks, wiresegs_ascending[merged_groups[v]])
        append!(assigned, merged_groups[v])
    end
end

function best_matching!(merging_graph, vcg, L, R)
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
            for v = 1:nv(edge_selection_graph)
                v in ignored && continue
                if isempty(inneighbors(working_vcg, v)) ||
                   all([w in ignored for w in inneighbors(working_vcg, v)])
                    # v has no surviving ancestors, remove edges to other such vertices
                    for w in no_ancestors
                        rem_edge!(edge_selection_graph, v, w)
                    end
                    push!(no_ancestors, v)
                end
            end
            # Find nodes with minimum number of edges
            for v = 1:nv(edge_selection_graph)
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
    # Any matching is feasible now that we've removed marked edges.
    # Rows are R so the returned row→col dict is keyed by R, matching how the
    # caller looks up `matching[v]` when v crosses from R into L next iteration.
    R_vec = collect(R)
    L_vec = collect(L)
    sort!(R_vec) # For determinism
    sort!(L_vec)
    bip = falses(length(R_vec), length(L_vec))
    for (i, r) in pairs(R_vec), (j, l) in pairs(L_vec)
        bip[i, j] = has_edge(merging_graph, r, l)
    end
    row_to_col, _ = BipartiteMatching.findmaxcardinalitybipartitematching(BitMatrix(bip))
    return Dict{Int, Int}(R_vec[i] => L_vec[j] for (i, j) in row_to_col)
end

function dag_shortest_paths(dag, v_sorted, s)
    d = fill(nv(dag), nv(dag))
    d[s] = 0
    for i = findfirst(v -> v == s, v_sorted):nv(dag)
        u = v_sorted[i]
        for v in outneighbors(dag, u)
            if d[v] > d[u] + 1
                d[v] = d[u] + 1
            end
        end
    end
    return d
end

function channel_problem_graphs(ar::AbstractChannelProblem, channel)
    wiresegs_ascending = sort(channel_segments(ar, channel), by=(ws) -> interval(ar, ws))
    # Y&K zone representation as interval graph
    # Edge between each pair of segments that overlap
    zone_ig = SimpleGraph(length(wiresegs_ascending))
    # Condrat et al. VCG with avoidable crossings as constraints
    # Not handled: constraints from vertically aligned pin positions
    vcg = SimpleDiGraph(length(wiresegs_ascending)) # just a fresh graph
    for (idx1, seg1) in pairs(wiresegs_ascending)
        low1, high1 = interval(ar, seg1)
        for (idx2, seg2) in collect(pairs(wiresegs_ascending))[(idx1 + 1):end]
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
            avoidable = is_avoidable(
                low1,
                high1,
                low2,
                high2,
                low1_tend,
                high1_tend,
                low2_tend,
                high2_tend
            )
            !avoidable && continue

            # Crossing is avoidable, so add a constraint
            # Determine which goes on top based on the lower bound tendency of seg2
            # Is prev or next the lower bound?
            # top is rightmost segment iff its lower bound tends towards higher (lower index) tracks
            top = (idx1, idx2)[1 + (low2_tend == 1)]
            bottom = (idx1, idx2)[2 - (low2_tend == 1)]
            add_edge!(vcg, top, bottom) # VCG has edge from higher to lower tracks
        end
    end
    return vcg, zone_ig
end

# ──── Segment deletion / reset ───────────────────────────────────────────────

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

If `reset_tracks` is `true` (the default), then **all** track assignments in every channel
that contained a deleted segment are cleared — not just the tracks for the deleted nets.
This affects other nets sharing those channels. This is intentional: track assignment must be
globally consistent within a channel.
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
    reroute_nets!(ar::AbstractChannelProblem, net_indices; fixed_paths=Dict{Int,Vector{Int}}())

Reset and re-route specific nets, then reassign tracks globally.

Returns the set of all net indices affected by the track reassignment (i.e., nets that
shared a channel with any re-routed net). This set always includes `net_indices` and may
include additional nets whose track assignments changed as a side effect.

See also [`reset_nets!`](@ref), [`assign_channels!`](@ref), [`assign_tracks!`](@ref).
"""
function reroute_nets!(
    ar::AbstractChannelProblem,
    net_indices;
    fixed_paths::Dict{Int, Vector{Int}}=Dict{Int, Vector{Int}}()
)
    # Identify all nets sharing channels with the target nets (for caller awareness)
    affected_nets = Set{Int}(net_indices)
    for idx in net_indices
        for ws in net_wire(ar, idx)
            for other_ws in channel_segments(ar, running_channel(ws))
                push!(affected_nets, net_index(other_ws))
            end
        end
    end

    reset_nets!(ar; net_indices=net_indices, reset_tracks=true)
    assign_channels!(ar; net_indices=net_indices, fixed_paths)
    assign_tracks!(ar)
    return affected_nets
end

# ──── Diagnostics ────────────────────────────────────────────────────────────

"""
    routing_summary([io::IO,] ar::AbstractChannelProblem)

Print a per-net summary of routing results: pin pair, channel path, and track assignments.

Segments with unassigned tracks are flagged.
"""
function routing_summary(io::IO, ar::AbstractChannelProblem)
    for idx = 1:num_nets(ar)
        wire = net_wire(ar, idx)
        pins = net_pins(ar, idx)
        channels_used = [running_channel(ws) for ws in wire]
        tracks = [segment_track(ar, ws) for ws in wire]
        has_unassigned = any(isnothing, tracks)
        println(
            io,
            "Net $idx: pins $(pins[1])→$(pins[2]), $(length(wire)) segments, " *
            "channels $channels_used, tracks $tracks" *
            (has_unassigned ? " [UNASSIGNED TRACKS]" : "")
        )
    end
end
routing_summary(ar::AbstractChannelProblem) = routing_summary(stdout, ar)
