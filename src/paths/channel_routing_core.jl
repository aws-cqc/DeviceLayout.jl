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
    topological_sort_by_dfs,
    is_cyclic
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
  - `channel_width(prob, ch, s...)::T`
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

    s1 = pathlength_at_intersection(ar, channel_idx, start_channel)
    s2 = pathlength_at_intersection(ar, channel_idx, stop_channel)
    (!use_track || is_pin(ar, channel_idx)) && return _swap(s1, s2)
    # Could just do that for all cases
    # But if we want to break ties we use offsets from previous/next segments
    # Offset sign needs to take into account relative directions of segments in channels
    s_start = pathlength_at_intersection(ar, start_channel, channel_idx)
    s_stop = pathlength_at_intersection(ar, stop_channel, channel_idx)
    start_dir = direction_at_intersection(ar, start_channel, channel_idx)
    dir1 = direction_at_intersection(ar, channel_idx, start_channel)
    dir2 = direction_at_intersection(ar, channel_idx, stop_channel)
    stop_dir = direction_at_intersection(ar, stop_channel, channel_idx)
    # Offset also depends neighbor track offsets
    α_ixn_start = (dir1 - start_dir)
    α_ixn_stop = (stop_dir - dir2)
    sin_start = _transverse_sine(α_ixn_start, channel_idx, start_channel)
    sin_stop = _transverse_sine(α_ixn_stop, channel_idx, stop_channel)
    prev_offset_proj =
        segment_offset(ar, prev(ar, ws), s_start; use_wire_direction=false) / sin_start
    next_offset_proj =
        segment_offset(ar, next(ar, ws), s_stop; use_wire_direction=false) / sin_stop
    # Offset *also* depends on this wire segment's offset at a non-90° intersection
    start_offset_proj =
        -segment_offset(ar, ws, s_start; use_wire_direction=false) *
        _transverse_cotangent(α_ixn_start)
    stop_offset_proj =
        -segment_offset(ar, ws, s_stop; use_wire_direction=false) *
        _transverse_cotangent(α_ixn_stop)
    # This is approximate on bending or tapered tracks
    return s1 + (prev_offset_proj + start_offset_proj),
    s2 - (next_offset_proj + stop_offset_proj)
end

function _transverse_sine(α, channel, bounding_vertex)
    sinα = sin(α)
    abs(sinα) <= sqrt(eps(Float64)) && throw(
        ArgumentError(
            "Channel $channel and bounding vertex $bounding_vertex intersect at a near-parallel angle; track-offset projection is undefined."
        )
    )
    return sinα
end

# Exactly zero at a perpendicular intersection, where `1 / tan(π / 2)` is not. Refinement
# passes compute intervals with the segment's own track assigned, and the residue would
# otherwise make aligned ends differ by rounding error from pass to pass.
function _transverse_cotangent(α)
    sinα, cosα = sincos(α)
    abs(cosα) <= sqrt(eps(Float64)) && return 0.0
    return cosα / sinα
end

# ──── Tendency computation ───────────────────────────────────────────────────

# +1 if segment crosses over low track index in ws's channel
function prev_next_tendency(ar, ws; use_wire_direction=true)
    channel_idx = running_channel(ws)
    start_channel, stop_channel = bounding_channels(ws)
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
    ### Neighbor directions come from track-aware intervals. A neighbor ending within the
    ### width of ws's channel can run the opposite way from what ws's centerline implies.
    ### Is prev upper-bounded by ws? Then it goes along with channel
    ### (Pin intervals are sorted, which is correct for prev: pin rays run toward ws)
    prev_start, prev_stop = unsorted_interval(ar, prev(ar, ws))
    sgn_start = prev_stop >= prev_start ? 1 : -1
    ### Is next upper-bounded by ws? Then it goes against channel
    ### (Pin intervals are sorted, so handle explicitly: next always runs against the ray)
    nws = next(ar, ws)
    next_start, next_stop = unsorted_interval(ar, nws)
    sgn_stop = (is_pin(ar, running_channel(nws)) || next_start >= next_stop) ? -1 : 1
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
    net_indices=1:num_nets(ar),
    fixed_paths::Dict{Int, Vector{Int}}=Dict{Int, Vector{Int}}()
)
    _validate_fixed_paths(fixed_paths)
    aux = build_auxiliary_graph(ar)
    for idx_net in net_indices
        p0, p1 = net_pins(ar, idx_net)
        path = if haskey(fixed_paths, idx_net)
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

function _validate_fixed_paths(fixed_paths)
    for (net_idx, path) in fixed_paths
        allunique(path) || throw(
            ArgumentError(
                "Fixed channel path for net $net_idx revisits a channel: $path. Each channel may appear at most once."
            )
        )
    end
    return nothing
end

# ──── Track assignment ───────────────────────────────────────────────────────

"""
    assign_tracks!(ar::AbstractChannelProblem; max_refinement_passes=2, min_leg_spacing=zero(T))

Performs track assignment for all channels in `ar`.

Track assignment operates on **all** channels, not a subset. Re-running after modifying
a single net will reassign tracks globally in every channel that contains wire segments.

After an initial pass over channels in index order, up to `max_refinement_passes`
additional passes reassign each channel whose constraints have changed, since a segment's
constraints depend on the tracks of the channels at its ends. From the second refinement
pass on, a channel keeps its tracks if they still satisfy its changed constraints. Passes
stop once every channel's tracks satisfy its constraints.

If that doesn't happen within `max_refinement_passes`, track assignment keeps the
assignment, from the initial pass or any refinement pass, with the fewest wires overlapping
on a shared track, and then the fewest channels whose tracks violate their constraints. If
that assignment has violations, it warns about the channels with them, which can have
wires overlapping on a shared track or crossings that a different order would avoid. The
warning also says whether the passes were cycling between assignments, in which case more
passes won't help.

Two wires leaving a channel to opposite sides at the same point are put in the order that
keeps their legs from overlapping, unless that order would make the vertical constraint
graph cyclic (`autoroute!` then warns about the pair). The same order is imposed on wires
leaving closer together than `min_leg_spacing`, so their legs don't run side by side
across the channel closer than that. This can increase the number of tracks, since such
pairs could otherwise share a track.

!!! warning "Experimental API"

    The channel autorouter is experimental. Its API and its solutions for a given problem
    may change in minor versions.
"""
function assign_tracks!(
    ar::AbstractChannelProblem{T};
    max_refinement_passes=2,
    min_leg_spacing=zero(T)
) where {T}
    validate_max_refinement_passes(max_refinement_passes)
    for channel = 1:num_channels(ar)
        empty!(channel_tracks(ar, channel))
    end
    # Order of channels will change results
    # Generally you want early channels to be those with more pins adjoining them
    # Or fewer non-pinned segments
    # Because those channels will inform constraints on later channels
    # For now the user can worry about that
    used_inputs = map(1:num_channels(ar)) do channel
        inputs = _track_inputs(ar, channel; min_leg_spacing)
        assign_tracks_matching!(ar, channel, inputs)
        return inputs
    end
    # The initial pass measures each segment to the centerline of any bounding channel not
    # yet assigned. A segment whose endpoint is near that centerline can turn out to run
    # the other way once the bounding channel has tracks, invalidating the order chosen
    # here (see the "Channel Autorouter" tests for an example). Refinement passes reassign
    # channels with all neighboring tracks known. Reassignment must not discard a
    # consistent order on the basis of unconstrained neighbor tracks; see
    # `_outer_of_disjoint_neighbors`.
    #
    # Channels whose constraints depend on each other's tracks can keep trading
    # assignments, so from the second refinement pass on, a channel keeps tracks that still
    # satisfy its constraints. The first refinement pass reassigns regardless: the initial
    # pass's tracks often still satisfy the constraints but use more tracks than needed
    # once the neighbors' tracks are known.
    states = [_track_state(ar)]
    cycled = false
    for pass = 1:max_refinement_passes
        reassigned = false
        for channel = 1:num_channels(ar)
            # Old tracks stay in place while inputs and new tracks are computed so that
            # offsets of this channel's segments remain available to neighbor intervals
            inputs = _track_inputs(ar, channel; min_leg_spacing)
            inputs == used_inputs[channel] && continue
            used_inputs[channel] = inputs
            pass > 1 && _tracks_satisfy(ar, channel, inputs) && continue
            tracks = channel_tracks(ar, channel)
            n_old = length(tracks)
            assign_tracks_matching!(ar, channel, inputs)
            deleteat!(tracks, 1:n_old)
            reassigned = true
        end
        reassigned || return
        state = _track_state(ar)
        # Passes after the first depend only on the tracks they start from. So if a pass
        # ends with the tracks that an earlier pass after the first started from, the
        # passes cycle. Ending with the tracks this pass started from instead means the
        # next pass would change nothing.
        cycled = state in states[2:(end - 1)]
        push!(states, state)
        cycled && break
    end
    isempty(_violating_channels(ar, min_leg_spacing)) ||
        _keep_least_violating!(ar, states, cycled; min_leg_spacing)
    return
end

# After refinement passes that didn't settle, restores the assignment in `states` with the
# fewest violations and warns about any channels whose tracks violate their constraints
function _keep_least_violating!(ar, states, cycled; min_leg_spacing)
    scores = map(states) do state
        _restore_track_state!(ar, state)
        return (
            _shared_track_overlaps(ar),
            length(_violating_channels(ar, min_leg_spacing))
        )
    end
    _restore_track_state!(ar, states[argmin(scores)])
    violating = _violating_channels(ar, min_leg_spacing)
    # The initial pass's assignment, which the first refinement pass replaces regardless,
    # can satisfy all constraints
    isempty(violating) && return
    remedy = if cycled
        "The passes cycle between assignments, so more passes won't help."
    else
        "Increasing `max_refinement_passes` may help."
    end
    @warn """
        Track assignment did not converge in $(length(states) - 1) refinement passes. \
        Tracks in channels $violating violate their constraints, which can leave wires \
        overlapping on a shared track or crossing where a different order would avoid \
        it. Of the assignments tried, the one with the fewest violations is kept. \
        $remedy\
        """
    return
end

# Throws unless `n` is a valid `max_refinement_passes`. `AutoChannelRouting` checks too,
# so that a bad value fails before any routing work.
function validate_max_refinement_passes(n)
    n >= 0 || throw(ArgumentError("`max_refinement_passes` must be nonnegative, got $n."))
    return n
end

# The tracks of all channels, to compare and restore assignments
_track_state(ar) = [copy.(channel_tracks(ar, channel)) for channel = 1:num_channels(ar)]

function _restore_track_state!(ar, state)
    for channel = 1:num_channels(ar)
        tracks = channel_tracks(ar, channel)
        empty!(tracks)
        append!(tracks, state[channel])
    end
end

# Whether the current tracks of `channel` satisfy the constraints in `inputs` (see
# `_track_inputs`): no overlapping segments on one track, and every vertical constraint
# respected by the track order
function _tracks_satisfy(ar, channel, inputs)
    seg_idx = Dict(ws => idx for (idx, ws) in pairs(inputs.segs))
    track_of = zeros(Int, length(inputs.segs))
    for (track_idx, track) in pairs(channel_tracks(ar, channel)), ws in track
        haskey(seg_idx, ws) || return false
        track_of[seg_idx[ws]] = track_idx
    end
    any(iszero, track_of) && return false
    # Lower track index is higher in the channel, and the VCG has edges from higher to lower
    all(e -> track_of[e.src] < track_of[e.dst], edges(inputs.vcg)) || return false
    all(e -> track_of[e.src] != track_of[e.dst], edges(inputs.zone_ig)) || return false
    return all(((a, b),) -> track_of[a] != track_of[b], inputs.touching_overlaps)
end

# Channels whose current tracks violate their constraints
function _violating_channels(ar, min_leg_spacing)
    return filter(1:num_channels(ar)) do channel
        return !_tracks_satisfy(ar, channel, _track_inputs(ar, channel; min_leg_spacing))
    end
end

# Number of pairs of segments that overlap on a shared track, in any channel
function _shared_track_overlaps(ar)
    n = 0
    for channel = 1:num_channels(ar), track in channel_tracks(ar, channel)
        for (idx, ws) in pairs(track), other in track[(idx + 1):end]
            n += segments_overlap(ar, ws, other)
        end
    end
    return n
end

# Everything `assign_tracks_matching!` reads from `channel`'s current state. Equal inputs
# give equal tracks, so a channel whose inputs are unchanged needs no reassignment.
# Intervals enter only through the graphs and through the pairs that touch exactly but
# can't share a track (see `segments_overlap`). Comparing those rather than raw intervals
# keeps rounding error in track offsets from counting as a change.
function _track_inputs(ar, channel; min_leg_spacing)
    segs, ends = sorted_segments_and_ends(ar, channel)
    vcg, zone_ig = channel_problem_graphs(ar, ends; min_leg_spacing)
    touching_overlaps = Set{Tuple{Int, Int}}()
    for (idx1, end1) in pairs(ends)
        for idx2 = (idx1 + 1):length(ends)
            low2 = ends[idx2].low
            low2 > end1.high && break
            low2 == end1.high &&
                segments_overlap(ar, segs[idx1], segs[idx2]) &&
                push!(touching_overlaps, (idx1, idx2))
        end
    end
    return (; segs, vcg, zone_ig, touching_overlaps)
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

function assign_tracks_matching!(ar, channel, inputs)
    # Yoshimura and Kuh Algorithm #2
    vcg = copy(inputs.vcg) # Merging edits it, and `inputs` is kept for comparison
    zones = maximal_cliques(inputs.zone_ig)
    isempty(zones) && return
    # Need to sort zones left to right. Segments are indexed in order of their low ends,
    # so a zone's common overlap starts at its maximal element. Its minimal element can be
    # a long segment shared by many zones, which leaves them unordered.
    sort!(zones, by=maximum)
    wiresegs_ascending = inputs.segs
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
        high_to_low = _topological_order(vcg, channel, wiresegs_ascending)
        dists_from_r = Dict(r => dag_shortest_paths(vcg, high_to_low, r) for r in R)
        for l in L
            # Only use rightmost in any merged group
            haskey(merged_into, l) && continue
            dists_from_l = dag_shortest_paths(vcg, high_to_low, l)
            for r in R
                mergeable = dists_from_l[r] >= nv(vcg) && dists_from_r[r][l] >= nv(vcg)
                !mergeable && continue
                # `segments_overlap`, read from `inputs` so equal inputs give equal tracks
                overlap =
                    has_edge(inputs.zone_ig, l, r) ||
                    _swap(l, r) in inputs.touching_overlaps
                overlap || add_edge!(merging_graph, l, r)
            end
        end
        # Find max cardinality valid matching, removing edges as necessary
        matching = best_matching!(merging_graph, vcg, L, R)
    end
    # Assign merged groups to tracks according to VCG
    tracks = channel_tracks(ar, channel)
    for v = 1:nv(vcg)
        if !haskey(merged_groups, v)
            merged_groups[v] = [v]
        end
    end
    for group in
        _merged_group_topological_order(vcg, merged_groups, channel, wiresegs_ascending)
        push!(tracks, wiresegs_ascending[group])
    end
end

function _merged_group_topological_order(vcg, merged_groups, channel, wiresegs)
    groups = Vector{Vector{Int}}()
    group_for_vertex = zeros(Int, nv(vcg))
    for v = 1:nv(vcg)
        !iszero(group_for_vertex[v]) && continue
        group = merged_groups[v]
        push!(groups, group)
        group_idx = length(groups)
        for member in group
            group_for_vertex[member] = group_idx
        end
    end

    # Tracks correspond to merged groups, not individual VCG vertices. Sorting vertices
    # and taking the first member of each group can violate a constraint between later
    # members, so sort the quotient graph whose vertices are the merged groups.
    group_vcg = SimpleDiGraph(length(groups))
    for edge in edges(vcg)
        source_group = group_for_vertex[edge.src]
        destination_group = group_for_vertex[edge.dst]
        source_group == destination_group && throw(
            ArgumentError(
                "Merged track group in channel $channel contains a vertical constraint."
            )
        )
        add_edge!(group_vcg, source_group, destination_group)
    end
    group_wiresegs = [wiresegs[first(group)] for group in groups]
    is_cyclic(group_vcg) && _topological_order(group_vcg, channel, group_wiresegs)

    # Preserve interval order when the VCG leaves groups incomparable instead of
    # inheriting DFS traversal order as an arbitrary track-order tie-break.
    indegrees = length.(inneighbors.(Ref(group_vcg), 1:nv(group_vcg)))
    available = findall(iszero, indegrees)
    high_to_low = Int[]
    while !isempty(available)
        group_idx = popfirst!(available)
        push!(high_to_low, group_idx)
        for child in outneighbors(group_vcg, group_idx)
            indegrees[child] -= 1
            if iszero(indegrees[child])
                push!(available, child)
                sort!(available)
            end
        end
    end
    return groups[high_to_low]
end

function _topological_order(vcg, channel, wiresegs)
    if is_cyclic(vcg)
        nets = sort!(unique(net_index.(wiresegs)))
        throw(
            ArgumentError(
                "Vertical constraint graph for channel $channel contains a cycle. Nets routed in this channel: $nets."
            )
        )
    end
    return topological_sort_by_dfs(vcg)
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

function channel_problem_graphs(
    ar::AbstractChannelProblem{T},
    ends;
    min_leg_spacing=zero(T)
) where {T}
    # Y&K zone representation as interval graph
    # Edge between each pair of segments that overlap
    zone_ig = SimpleGraph(length(ends))
    # Condrat et al. VCG with avoidable crossings as constraints, plus constraints between
    # non-overlapping segments with aligned ends (see `facing_end_pairs`)
    vcg = SimpleDiGraph(length(ends)) # just a fresh graph
    for (idx1, end1) in pairs(ends)
        for idx2 = (idx1 + 1):length(ends)
            end2 = ends[idx2]
            # If there is no overlap, break and move on to next seg1
            # Use >= instead of > to potentially allow knock-knees
            end2.low >= end1.high && break # All subsequent seg2 have low2 >= high1
            # There is overlap, so add an edge to the interval graph
            add_edge!(zone_ig, idx1, idx2)
            # Now check if crossing is unavoidable
            (i1, l1, h1, lt1, ht1), (i2, l2, h2, lt2, ht2) =
                _avoidability_args(idx1, end1, idx2, end2)
            avoidable = is_avoidable(l1, h1, l2, h2, lt1, ht1, lt2, ht2)
            !avoidable && continue

            # Crossing is avoidable, so add a constraint
            # Determine which goes on top based on the lower bound tendency of seg2
            # Is prev or next the lower bound?
            # top is rightmost segment iff its lower bound tends towards higher (lower index) tracks
            top = (i1, i2)[1 + (lt2 == 1)]
            bottom = (i1, i2)[2 - (lt2 == 1)]
            add_edge!(vcg, top, bottom) # VCG has edge from higher to lower tracks
        end
    end
    facing = facing_end_pairs(ar, ends, min_leg_spacing; use_pitch=false)
    _add_facing_constraints!(vcg, facing)
    return vcg, zone_ig
end

# Segments `idx1` and `idx2`, with ends `end1` and `end2`, as arguments for `is_avoidable`:
# `(index, low, high, low tendency, high tendency)` for each, the one with the lower low
# first.
#
# `is_avoidable` treats each neighbor as extending indefinitely along its channel, so it
# orders the segments by their neighbors' tracks. Neighbors on disjoint runs from the
# same side have unconstrained tracks, and the order is instead set by the runs (see
# `_outer_of_disjoint_neighbors`). That order is presented to `is_avoidable` as adjacent
# endpoints, the outer one inward.
function _avoidability_args(idx1, end1, idx2, end2)
    l1, h1, l2, h2 = end1.low, end1.high, end2.low, end2.high
    if end1.low_tend == end2.low_tend
        outer = _outer_of_disjoint_neighbors(end1.low_neighbor, end2.low_neighbor)
        if outer != 0 # Adjacent lows, the outer one larger
            l_inner = min(l1, l2)
            l1, l2 =
                outer == 1 ? (nextfloat(l_inner), l_inner) : (l_inner, nextfloat(l_inner))
        end
    end
    if end1.high_tend == end2.high_tend
        outer = _outer_of_disjoint_neighbors(end1.high_neighbor, end2.high_neighbor)
        if outer != 0 # Adjacent highs, the outer one smaller
            h_inner = max(h1, h2)
            h1, h2 =
                outer == 1 ? (prevfloat(h_inner), h_inner) : (h_inner, prevfloat(h_inner))
        end
    end
    args1 = (idx1, l1, h1, end1.low_tend, end1.high_tend)
    args2 = (idx2, l2, h2, end2.low_tend, end2.high_tend)
    return l1 <= l2 ? (args1, args2) : (args2, args1)
end

# Constrains each facing pair (see `facing_end_pairs`) to its order in `vcg` unless that
# would make `vcg` cyclic. Closest ends first, and exactly aligned ones before all others,
# since they would overlap rather than just be close.
function _add_facing_constraints!(vcg, facing)
    for pair in sort(facing, by=pair -> pair.gap)
        has_edge(vcg, pair.top, pair.bottom) && continue
        add_edge!(vcg, pair.top, pair.bottom)
        is_cyclic(vcg) && rem_edge!(vcg, pair.top, pair.bottom)
    end
    return vcg
end

# Which of two segments (1 or 2) is fixed as the outer one at their low or high end by
# their neighbors there, `nb1` and `nb2` (see `_neighbor_end`), or 0 if the neighbors
# don't fix an order.
#
# The order is fixed when both neighbors run along the same bounding channel B, from the
# same side, on assigned tracks, and occupy disjoint runs of B. Below, segments s₁ and s₂
# run up channel C, and their neighbors come from pins below B:
#
#        current order               flipped order
#
#       s₁      s₂                   s₂      s₁
#       |       |                    |       |
#       +---+   |                    |   +---+
#   B       |   +-----+          B   +---×---------+
#           |         |                  |         |
#           p₁        p₂                 p₁        p₂
#
# - With disjoint runs, B has no constraint between the neighbors, so their relative
#   tracks are arbitrary (here s₂'s neighbor happens to be on the lower track).
# - `is_avoidable` sees s₂ entering C below s₁ from the same side. Since it assumes s₂'s
#   neighbor extends indefinitely to the right, it concludes s₂ must be inside s₁ and
#   flips them.
# - In the flipped order, s₂'s neighbor covers the point where s₁'s neighbor leaves B, so
#   B can no longer avoid a crossing with either track order.
#
# The current order is kept instead. With disjoint runs from the same side, the segment
# whose neighbor reaches farther along B is the one turning into C farther out, so that
# segment is reported as outer.
#
# This is conservative if s₁'s neighbor leaves B toward C's side, where flipping could
# also be crossing-free. That requires a pin or channel inside C's footprint.
#
# The condition needs both neighbors on assigned tracks, so it only applies in refinement
# passes. Before that, same-side neighbors both end at C's centerline, and their runs
# overlap.
function _outer_of_disjoint_neighbors(nb1, nb2)
    nb1.channel != nb2.channel && return 0
    (nb1.assigned && nb2.assigned) || return 0
    lo1, hi1 = nb1.interval
    lo2, hi2 = nb2.interval
    (hi1 <= lo2 || hi2 <= lo1) || return 0
    nb1.reach > nb2.reach && return 1
    nb2.reach > nb1.reach && return 2
    return 0
end

# The neighbor segment at `ws`'s low (`at_low`) or high end, as
# `_outer_of_disjoint_neighbors` needs it: the channel it runs along, whether it is on an
# assigned track (never for a pin), its interval, and its reach, the signed distance from
# `ws`'s channel to the neighbor's far end, positive in the direction the neighbor extends
# away from `ws`. `against` is whether `ws` runs against its channel.
function _neighbor_end(ar, ws, at_low, against)
    is_prev = xor(at_low, against)
    nb = is_prev ? prev(ar, ws) : next(ar, ws)
    channel = running_channel(nb)
    assigned = !is_pin(ar, channel) && !isnothing(segment_track(ar, nb))
    s_ws = pathlength_at_intersection(ar, channel, running_channel(ws))
    start, stop = unsorted_interval(ar, nb)
    far, near = is_prev ? (start, stop) : (stop, start)
    reach = (far - s_ws) * sign(far - near)
    return (; channel, assigned, interval=_swap(start, stop), reach)
end

# What constraints between `ws` and other segments in its channel depend on: its interval,
# the tendency at each end, the neighbor at each end (see `_neighbor_end`), the track
# pitch of the bounding vertex at each end (see `_end_pitch`), and the tolerance for its
# high end to count as aligned with another segment's low end. Computing these once per
# segment rather than once per pair of segments keeps graph construction fast.
function _segment_ends(ar::AbstractChannelProblem, ws)
    s_start, s_stop = unsorted_interval(ar, ws)
    low, high = _swap(s_start, s_stop)
    against = s_start > s_stop
    pt, nt = prev_next_tendency(ar, ws)
    low_tend, high_tend = against ? (nt, pt) : (pt, nt)
    # Rounding error in pathlengths and track offsets scales with these
    high_atol =
        sqrt(eps(Float64)) * (abs(high) + channel_width(ar, running_channel(ws), high))
    return (;
        low,
        high,
        low_tend,
        high_tend,
        low_neighbor=_neighbor_end(ar, ws, true, against),
        high_neighbor=_neighbor_end(ar, ws, false, against),
        low_pitch=_end_pitch(ar, ws, _end_vertex(ws, true, against)),
        high_pitch=_end_pitch(ar, ws, _end_vertex(ws, false, against)),
        high_atol
    )
end

# Segments of `channel` in ascending order of their intervals, as the channel's graphs and
# `facing_end_pairs` index them, and their ends (see `_segment_ends`)
function sorted_segments_and_ends(ar, channel)
    segs = channel_segments(ar, channel)
    ends = [_segment_ends(ar, ws) for ws in segs]
    order = sortperm(ends, by=e -> (e.low, e.high))
    return segs[order], ends[order]
end

# Pairs of non-overlapping segments whose facing ends leave the channel to opposite sides
# at the same point or closer than `min_spacing`, or, with `use_pitch`, closer than the
# track pitch of the bounding channels there. Returned as `(; top, bottom, gap, pitch)`
# with `top` and `bottom` indices into `ends` (see `sorted_segments_and_ends`) in the order
# the pair must take unless it shares a track:
#
#        a above b                 a below b
#
#        a                         a
#        |                         |
#     ---+                         |  +---
#           +---                ---+  |
#           |                         |
#           b                         b
#
# Wire a turns toward the low-index side and wire b arrives from the high-index side. With
# a on the higher track, their legs leaving the channel are on opposite sides of the
# tracks. In the other order, they run side by side between the tracks, `gap` apart. That
# is a collinear overlap if `gap` is zero (the classic vertical constraint between nets at
# the same column), and closer than other wires there if `gap` is less than `pitch`. Wires
# near each end already run at the pitch of the bounding channel there, so `pitch` is the
# smaller of the two, ignoring a pin or channel without tracks, which has none.
#
# Ends within rounding error of each other count as the same point, with `gap` zero. Pin
# coordinates that come from transformations, for example, rarely align exactly.
function facing_end_pairs(
    ar::AbstractChannelProblem{T},
    ends,
    min_spacing;
    use_pitch=true
) where {T}
    pairs_found = @NamedTuple{top::Int, bottom::Int, gap::T, pitch::T}[]
    isempty(ends) && return pairs_found
    max_pitch = use_pitch ? maximum(e -> max(e.low_pitch, e.high_pitch), ends) : zero(T)
    max_clearance = max(min_spacing, max_pitch)
    for (idx1, end1) in pairs(ends)
        for (idx2, end2) in pairs(ends)
            # Segments are sorted by low end, so later ones are farther from end1.high
            end2.low > end1.high + max_clearance + end1.high_atol && break
            gap = end2.low - end1.high
            # A zero-length segment's own ends coincide
            (idx1 == idx2 || gap < -end1.high_atol || end1.high_tend == end2.low_tend) &&
                continue
            abs(gap) <= end1.high_atol && (gap = zero(gap))
            pitch = use_pitch ? _smaller_nonzero(end1.high_pitch, end2.low_pitch) : zero(T)
            (iszero(gap) || closer_than(gap, min_spacing) || closer_than(gap, pitch)) ||
                continue
            top, bottom = end1.high_tend == 1 ? (idx1, idx2) : (idx2, idx1)
            push!(pairs_found, (; top, bottom, gap, pitch))
        end
    end
    return pairs_found
end

_smaller_nonzero(a, b) = iszero(a) ? b : iszero(b) ? a : min(a, b)

# Whether `gap` is less than `clearance` by more than rounding error
closer_than(gap, clearance) = gap < clearance && !(gap ≈ clearance)

# Bounding vertex at the low (`at_low`) or high end of `ws`, which runs against its channel
# if `against`
_end_vertex(ws, at_low, against) = xor(at_low, against) ? ws.start_vertex : ws.stop_vertex

# Track pitch of bounding vertex `v` where `ws` meets it; zero for a pin or a channel
# without tracks yet
function _end_pitch(ar::AbstractChannelProblem{T}, ws, v) where {T}
    (is_pin(ar, v) || iszero(num_tracks(ar, v))) && return zero(T)
    s = pathlength_at_intersection(ar, v, running_channel(ws))
    return channel_width(ar, v, s) / (num_tracks(ar, v) + 1)
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
    reset_nets!(ar; net_indices=1:num_nets(ar), reset_tracks=true)

Resets the nets with `net_indices` to their unrouted state.

If `reset_tracks` is `true` (the default), then **all** track assignments in every channel
that contained a deleted segment are cleared — not just the tracks for the deleted nets.
This affects other nets sharing those channels. This is intentional: track assignment must be
globally consistent within a channel.
"""
function reset_nets!(ar; net_indices=1:num_nets(ar), reset_tracks=true)
    for idx in net_indices
        segs = net_wire(ar, idx)
        for ws in segs
            # delete segment from the router
            # don't delete it from net yet, we'll do that after this loop
            _delete_segment!(ar, ws, reset_tracks=reset_tracks, from_net=false)
        end
        empty!(segs)
    end
end

"""
    reroute_nets!(ar::AbstractChannelProblem, net_indices; fixed_paths=Dict{Int,Vector{Int}}(), kwargs...)

Reset and re-route specific nets, then reassign tracks globally.
Other keyword arguments (`max_refinement_passes`, `min_leg_spacing`) are passed to
[`assign_tracks!`](@ref).

Returns the set of all net indices affected by the track reassignment (i.e., nets that
shared a channel with any re-routed net). This set always includes `net_indices` and may
include additional nets whose track assignments changed as a side effect.

See also [`reset_nets!`](@ref), [`assign_channels!`](@ref), [`assign_tracks!`](@ref).
"""
function reroute_nets!(
    ar::AbstractChannelProblem,
    net_indices;
    fixed_paths::Dict{Int, Vector{Int}}=Dict{Int, Vector{Int}}(),
    kwargs...
)
    _validate_fixed_paths(fixed_paths)

    # Identify all nets sharing old or new channels with the target nets
    affected_nets = Set{Int}(net_indices)
    _collect_affected_nets!(affected_nets, ar, net_indices)

    reset_nets!(ar; net_indices=net_indices, reset_tracks=true)
    assign_channels!(ar; net_indices=net_indices, fixed_paths)
    _collect_affected_nets!(affected_nets, ar, net_indices)
    assign_tracks!(ar; kwargs...)
    return affected_nets
end

function _collect_affected_nets!(affected_nets, ar, net_indices)
    for idx in net_indices
        for ws in net_wire(ar, idx)
            for other_ws in channel_segments(ar, running_channel(ws))
                push!(affected_nets, net_index(other_ws))
            end
        end
    end
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
