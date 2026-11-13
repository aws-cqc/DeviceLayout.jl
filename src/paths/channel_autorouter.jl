# DeviceLayout-specific ChannelRouter implementation.
# Pure algorithmic core is in channel_routing_core.jl.

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
struct ChannelRouter{T <: Coordinate} <: AbstractChannelProblem{T}
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
    net_routes::Vector{Route{T}}
end

"""
    ChannelRouter(
        nets::Vector{Tuple{Int, Int}},
        pin_hooks::Vector{<:Hook},
        channels::Vector{<:RouteChannel}
    )

Construct a `ChannelRouter` from `nets`, `pin_hooks`, and `channels`.

`nets` is a list of `(i, j)` pairs of indices into `pin_hooks`; each pair specifies
a wire to be routed from pin `i` to pin `j`. The pin `Hook`s supply the entry/exit
positions and directions; each pin's outward ray (opposite its `in_direction`) must
strike one of `channels` for graph construction to succeed.

Channel intersections are computed eagerly during construction. Pass the result to
[`autoroute!`](@ref) to actually assign channels and tracks.
"""
function ChannelRouter(nets, pin_hooks::Vector{<:Hook}, channels::Vector{<:RouteChannel})
    T = promote_type(coordinatetype(pin_hooks), coordinatetype(channels))
    net_wires = [NetWire() for i in eachindex(nets)]
    channel_segments = [TrackWireSegment[] for i in eachindex(channels)]
    channel_tracks = [Track[] for i in eachindex(channels)]
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
        Route{T}[]
    )
end

"""
    ChannelRouter(channels::Vector{RouteChannel{T}}) where {T}

Construct an empty `ChannelRouter` containing `channels` but no pins or nets.

Nets and pins are added later — typically by constructing an [`AutoChannelRouting`](@ref)
rule around this router and calling `route!` on a schematic graph, which discovers pins
from the schematic's hooks at `plan` time.
"""
function ChannelRouter(channels::Vector{RouteChannel{T}}) where {T}
    channel_segments = [TrackWireSegment[] for i in eachindex(channels)]
    channel_tracks = [Track[] for i in eachindex(channels)]
    return ChannelRouter{T}(
        SimpleGraph(),
        Tuple{Int, Int}[],
        NetWire[],
        PointHook{T}[],
        channels,
        Dict{Tuple{Int, Int}, IntersectionInfo{T}}(),
        channel_segments,
        channel_tracks,
        Route{T}[]
    )
end

# ──── AbstractChannelProblem interface implementation ────────────────────────

Base.broadcastable(x::ChannelRouter) = Ref(x)
num_channels(ar::ChannelRouter) = length(ar.channels)
num_nets(ar::ChannelRouter) = length(ar.net_pins)
num_pins(ar::ChannelRouter) = length(ar.pins)

channel_graph(ar::ChannelRouter) = ar.channel_graph
net_pins(ar::ChannelRouter, net) = ar.net_pins[net]
net_wire(ar::ChannelRouter, net) = ar.net_wires[net]
pin_coordinates(ar::ChannelRouter, pin) = ar.pins[pin].p
pin_direction(ar::ChannelRouter, pin) = ar.pins[pin].in_direction
function channel_width(ar::ChannelRouter{T}, channel, s...) where {T}
    is_pin(ar, channel) && return zero(T)
    return Paths.width(ar.channels[channel].node.sty, s...)
end
channel_segments(ar::ChannelRouter, channel) = ar.channel_segments[channel]
channel_tracks(ar::ChannelRouter, channel) = ar.channel_tracks[channel]
num_tracks(ar::ChannelRouter, channel) = length(ar.channel_tracks[channel])

channel_intersection(ar, s1, s2) = ar.channel_intersections[_swap(s1, s2)]

function pathlength_at_intersection(
    ar::ChannelRouter{T},
    running_channel,
    intersecting_channel
) where {T}
    # Intersecting channel is zero where a wire segment hits a pin
    if iszero(running_channel) || iszero(intersecting_channel)
        return zero(T)
    end
    ixn_info = channel_intersection(ar, running_channel, intersecting_channel)
    running_channel < intersecting_channel && return ixn_info[1]
    return ixn_info[2]
end

function direction_at_intersection(ar::ChannelRouter, running_channel, intersecting_channel)
    # Intersecting channel is zero where a wire segment hits a pin
    if iszero(running_channel) || iszero(intersecting_channel)
        return 0.0
    end
    ixn_info = channel_intersection(ar, running_channel, intersecting_channel)
    angle_unitful = running_channel < intersecting_channel ? ixn_info[3] : ixn_info[4]
    return rem2pi(uconvert(NoUnits, angle_unitful), RoundNearest)
end

function segment_offset(
    ar::ChannelRouter{T},
    ws::TrackWireSegment,
    s...;
    use_wire_direction=true
) where {T}
    channel_idx = running_channel(ws)
    is_pin(ar, channel_idx) && return zero(T)
    track_idx = segment_track(ar, ws)
    isnothing(track_idx) && return zero(T)
    reversed = use_wire_direction && against_channel(ar, ws)
    return track_section_offset(
        length(ar.channel_tracks[channel_idx]),
        channel_width(ar, channel_idx, s...),
        track_idx;
        reversed
    )
end

# ──── DL-dependent geometry functions ────────────────────────────────────────

pathlength_from_start(channel, node, s) = pathlength(channel[1:(node - 1)]) + s

# Build graph with pins/channels as vertices and intersections as edges
function build_channel_graph(pins, channels, T)
    g = SimpleGraph(length(channels) + length(pins))
    intersection_dict = Dict{Tuple{Int, Int}, IntersectionInfo{T}}()

    # Create segments extending from pins
    bbox = bounds(bounds(channels), bounds(Polygon(DeviceLayout.getp.(pins))))
    ray_length = max(DeviceLayout.width(bbox), DeviceLayout.height(bbox)) * sqrt(2)
    pin_rays = Path{T}[]
    for pin in pins
        path = Path{T}(pin.p, pin.in_direction)
        straight!(path, ray_length, Paths.NoRender())
        push!(pin_rays, path)
    end

    # Add edges for intersections between channels
    intersections =
        DeviceLayout.Intersect.prepared_intersections([channels..., pin_rays...])
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
            _, old_ixn_info = get(pin_ixns, v2_idx, (v1_idx, ixn_info))
            old_distance = old_ixn_info[2]
            if s2 <= old_distance
                pin_ixns[v2_idx] = (v1_idx, ixn_info)
            end
        else # record intersection as edge in channel graph, with info in dict
            haskey(intersection_dict, (v1_idx, v2_idx)) &&
                error("Channels $v1_idx and $v2_idx have multiple intersections")
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
    for pin_idx = (length(channels) + 1):(length(channels) + length(pins))
        orig_idx = pin_idx - length(channels)
        !haskey(pin_ixns, pin_idx) && error(
            "The ray from pin $(orig_idx) ($(pins[orig_idx])) does not intersect any channel"
        )
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
        println("""
        Segment $i:
            Runs along Channel $(running_channel(ws)), Track $(segment_track(ar, ws))
            From $(channel_names[1]) to $(channel_names[2])
        """)
    end
end

"""
    autoroute!(ar::ChannelRouter, transition_rule, margin; net_indices, fixed_channel_paths, max_refinement_passes=2, min_leg_spacing=zero(T), verbose)

Perform channel and track assignment, then make routes.

Routes only the nets in `net_indices`. If the net is already routed, it is reset. A route
for a net can be specified in `fixed_channel_paths` by the indices of the channels the route
takes. Each channel may appear at most once in a fixed path. For example,
`fixed_channel_paths=Dict(1 => [2, 4, 1, 5])` will force net 1 to be routed from its source
pin, through channels 2, 4, 1, 5 in order, then to its destination pin.

`max_refinement_passes` and `min_leg_spacing` set the options of the
[`AutoChannelRouting`](@ref) rule used for routing.

If `verbose=true`, prints a summary of routing results including net count and track usage.

Warns about any wire segment that is a sideways jog too short for `transition_rule` to
route, such as from a pin nearly in line with a track of a crossing channel, and about any
pair of wires whose legs run side by side closer than the track pitch. The jog check is
exact for `StraightAnd90`. For `StraightAnd45` it catches jogs too short for a single 45°
turn on each side, but longer jogs (up to `2 * margin`) can also fail to route.
"""
function autoroute!(
    ar::ChannelRouter,
    transition_rule,
    margin;
    net_indices=1:num_nets(ar),
    fixed_channel_paths::Dict{Int, Vector{Int}}=Dict{Int, Vector{Int}}(),
    verbose=false,
    kwargs...
)
    rule = AutoChannelRouting(ar, transition_rule, margin; kwargs...)
    _assign_and_check!(rule, net_indices, fixed_channel_paths)
    routes = make_routes!(ar, rule)

    if verbose
        n_routed = count(!isempty, ar.net_wires[collect(net_indices)])
        n_total = length(net_indices)
        max_tracks = maximum(num_tracks(ar, ch) for ch = 1:num_channels(ar))
        @info "Autorouting complete" nets_routed = n_routed nets_total = n_total max_tracks_per_channel =
            max_tracks
        for idx in net_indices
            for (seg_i, ws) in enumerate(net_wire(ar, idx))
                if isnothing(segment_track(ar, ws))
                    @warn "Net $idx segment $seg_i: no track assigned" channel =
                        running_channel(ws)
                end
            end
        end
    end

    return routes
end

# Channel and track assignment with `rule`'s options, followed by warnings about results
# that would otherwise show up only as route errors or as wires too close in the layout
function _assign_and_check!(rule, net_indices, fixed_paths)
    ar = rule.router
    reroute_nets!(
        ar,
        net_indices;
        fixed_paths,
        rule.max_refinement_passes,
        rule.min_leg_spacing
    )
    _warn_short_jogs(ar, rule.transition_rule, rule.transition_margin)
    return _warn_close_legs(ar, rule.min_leg_spacing)
end

######## Route construction

# Warn about each wire segment that `transition_rule` cannot route.
#
# A segment no longer than `2 * margin` has no straight section along its channel. Its
# neighbors' transitions meet at its midpoint, so the wire jogs sideways by the segment's
# length. `StraightAnd90` and `StraightAnd45` can route a jog only if it is zero or at least
# a minimum set by their bend radius. A shorter jog typically comes from a pin nearly in
# line with a track of a channel crossing the pin's channel. The route errors it causes
# name only coordinates, so this names the net and where the jog is.
function _warn_short_jogs(ar::ChannelRouter{T}, transition_rule, margin) where {T}
    min_jog = _min_jog(transition_rule)
    isnothing(min_jog) && return
    for net = 1:num_nets(ar), ws in net_wire(ar, net)
        isnothing(segment_track(ar, ws)) && continue
        s_start, s_stop = unsorted_interval(ar, ws)
        jog = abs(s_stop - s_start)
        # A jog the rule treats as straight still has to arrive within `route!`'s default
        # tolerance; the rule accepts a jog approximately equal to its minimum
        (
            jog > 2 * margin ||
            jog <= 1e-9 * DeviceLayout.onemicron(T) ||
            jog >= min_jog ||
            jog ≈ min_jog
        ) && continue
        from, to = _vertex_name.(ar, bounding_channels(ws))
        @warn """
            Net $net jogs $jog along channel $(running_channel(ws)) between $from and \
            $to, but $(nameof(typeof(transition_rule))) needs a jog of zero or at least \
            $min_jog. Move the pin or channel so the jog is zero or at least that long.\
            """
    end
end

# Shortest nonzero sideways jog at a collapsed segment, where each transition makes half
# the jog with a single turn; `nothing` for rules without such a limit
_min_jog(rule::StraightAnd90) = 2 * rule.min_bend_radius
_min_jog(rule::StraightAnd45) = 2 * rule.min_bend_radius * (1 - cos(π / 4))
_min_jog(::RouteRule) = nothing

_vertex_name(ar, v) = is_pin(ar, v) ? "pin $(graphidx_to_pin(ar, v))" : "channel $v"

# Warn about each pair of wires whose legs leaving a channel overlap or run side by side
# closer than `min_leg_spacing` or the track pitch there (see `_facing_end_pairs`). Pairs
# closer than the pitch alone are expected, and the warning suggests `min_leg_spacing` to
# separate them. Track assignment orders the others, so they remain only where that order
# conflicts with other track constraints.
function _warn_close_legs(ar::ChannelRouter, min_leg_spacing)
    for channel = 1:num_channels(ar)
        wiresegs_ascending =
            sort(channel_segments(ar, channel), by=(ws) -> interval(ar, ws))
        facing = _facing_end_pairs(ar, wiresegs_ascending, min_leg_spacing)
        for (; top, bottom, gap, pitch) in facing
            top_ws, bottom_ws = wiresegs_ascending[top], wiresegs_ascending[bottom]
            top_track, bottom_track =
                segment_track(ar, top_ws), segment_track(ar, bottom_ws)
            # Sharing a track keeps legs apart unless the ends coincide
            (top_track > bottom_track || (iszero(gap) && top_track == bottom_track)) ||
                continue
            nets = "Nets $(net_index(top_ws)) and $(net_index(bottom_ws))"
            enforced = iszero(gap) || _closer(gap, min_leg_spacing)
            problem = if iszero(gap)
                "$nets leave channel $channel at the same point to opposite sides, in an \
                order that overlaps their wires."
            else
                limit =
                    enforced ? "`min_leg_spacing` $min_leg_spacing" :
                    "the track pitch $pitch"
                "$nets leave channel $channel $gap apart to opposite sides, in an order \
                that runs their wires side by side closer than $limit."
            end
            remedy = if enforced
                "The other order conflicts with other track constraints; move a pin or \
                channel to separate them."
            else
                "Set `min_leg_spacing` greater than $gap to reorder them, or move a pin or \
                channel to separate them."
            end
            @warn "$problem $remedy"
        end
    end
end

"""
    make_routes!(ar::ChannelRouter, rule)

Using channel and track assignments, create a `Route` for every net.
"""
function make_routes!(ar::ChannelRouter{T}, rule) where {T}
    empty!(ar.net_routes)
    for idx_net in eachindex(ar.net_pins)
        p0, p1 = pin_coordinates.(ar, net_pins(ar, idx_net))
        α0, α1 = pin_direction.(ar, net_pins(ar, idx_net))
        rt = Route(rule, p0, p1, α0, α1 + pi)
        push!(ar.net_routes, rt)
    end
    return ar.net_routes
end

"""
    validate_routes(ar::ChannelRouter{T}, sty; atol=onenanometer(T)) where {T}

Construct `Path` objects from the router's `Route`s and check whether each one
reaches its destination point and angle.

Returns a `BitVector` of length `num_nets(ar)` where `true` means the route
produced valid geometry.  When a route fails, the corresponding `@error` from
`route!()` is still emitted to the logging system.
"""
function validate_routes(
    ar::ChannelRouter{T},
    sty;
    atol=DeviceLayout.onenanometer(T)
) where {T}
    success = trues(num_nets(ar))
    for (idx, rt) in enumerate(ar.net_routes)
        pa = Path(rt.p0, α0=rt.α0)
        ok = route!(
            pa,
            rt.p1,
            rt.α1,
            rt.rule,
            sty;
            waypoints=rt.waypoints,
            waydirs=rt.waydirs,
            atol=atol
        )
        success[idx] = something(ok, false) # route! currently returns nothing on failure
    end
    return success
end

######## Visualization

"""
    visualize_router_state(ar::ChannelRouter{T}; wire_width=0.1*oneunit(T))

Return a `Cell` with rectangles and labels illustrating channels, tracks, and routes.

Tracks are labeled as `S:C` where `S` is the channel index and `C` is the track index.

Pins are labeled as `P/N` where `P` is the pin index and `N` is the net index.

Segment waypoints are marked with circles and numbered sequentially within each net.
"""
function visualize_router_state(ar::ChannelRouter{T}; wire_width=0.1 * oneunit(T)) where {T}
    c = DeviceLayout.Cell{T}("track_viz")

    paths = Path.(ar.net_routes, Ref(Paths.Trace(wire_width)))
    DeviceLayout.render!.(c, paths, GDSMeta(7))
    channels = channel_paths(ar)
    DeviceLayout.render!.(c, channels, GDSMeta(3))
    tracks = track_paths(ar)
    DeviceLayout.render!.(c, tracks, GDSMeta(1))
    trlab = track_labels(ar, tracks)
    DeviceLayout.text!.(c, trlab, GDSMeta(0))
    for pa in paths
        for node in pa[1:(end - 1)]
            DeviceLayout.render!(
                c,
                DeviceLayout.Circle(1.5wire_width) + p1(node.seg),
                GDSMeta(5)
            )
        end
    end
    plab = pin_labels(ar)
    for l in plab
        DeviceLayout.text!(c, l..., GDSMeta(6))
    end
    return c
end

function track_paths(ar::ChannelRouter)
    return [track_path(ar, s, c) for s = 1:num_channels(ar) for c = 1:num_tracks(ar, s)]
end

channel_paths(ar::ChannelRouter) = [channel_path(ar, s) for s = 1:num_channels(ar)]

function track_labels(ar::ChannelRouter{T}, tracks) where {T}
    return [
        DeviceLayout.Texts.Text(
            track.name,
            p0(track),
            width=width(track[1].sty, zero(T)),
            rot=α0(track),
            xalign=DeviceLayout.Align.LeftEdge(),
            yalign=DeviceLayout.Align.YCenter()
        ) for track in tracks
    ]
end

function pin_labels(ar::ChannelRouter)
    return [
        ("$p/$n", pin_coordinates(ar, p)) for n = 1:num_nets(ar) for p in net_pins(ar, n)
    ]
end

function channel_path(ar::ChannelRouter, channel_idx)
    return ar.channels[channel_idx].path
end

function track_path(ar::ChannelRouter{T}, channel_idx, track_idx) where {T}
    n_tracks = length(channel_tracks(ar, channel_idx))
    seg = track_path_segment(n_tracks, ar.channels[channel_idx].node, track_idx)
    w = channel_width(ar, channel_idx, zero(T)) # Just illustrative, assume constant width
    pa = Path(
        [Paths.Node(seg, Paths.Trace(0.9 * w / (n_tracks + 1)))];
        name="$channel_idx.$track_idx"
    )
    return pa
end

######## Actually doing the path construction
"""
    struct AutoChannelRouting{T <: Coordinate} <: AbstractChannelRouting
    AutoChannelRouting(router::ChannelRouter, transition_rule::RouteRule, margin;
        max_refinement_passes=2, min_leg_spacing=zero(T))
    AutoChannelRouting(channels::Vector{<:RouteChannel}, transition_rule::RouteRule, margin;
        max_refinement_passes=2, min_leg_spacing=zero(T))

A `RouteRule` that delegates routing decisions to a shared [`ChannelRouter`](@ref).

At the schematic level, every `route!` call that should share channel and track
assignments must use the **same** `AutoChannelRouting` instance, so that the
underlying `router` sees all nets before channel and track assignment run during
`plan`. The `channels`/`transition_rule`/`margin` form constructs a fresh empty
`ChannelRouter` internally and is convenient when nets are populated from the schematic.

`transition_rule` routes the short legs between a pin and its first channel, and
between adjacent channels. It is typically [`Paths.StraightAnd90`](@ref),
[`Paths.StraightAnd45`](@ref), or [`Paths.BSplineRouting`](@ref). `margin`
reserves arclength at each end of a channel segment for the transition bends.

Track assignment options:

  - `max_refinement_passes`: maximum number of passes that reassign tracks in each
    channel once all neighboring channels have tracks. Passes stop as soon as no channel
    needs reassignment, so a larger maximum costs time only where refinement is needed.
    A warning suggests increasing it if tracks are still outdated after the last pass.
  - `min_leg_spacing`: minimum spacing between wires that leave a channel to opposite
    sides near the same point. Closer pairs are ordered so their legs separate instead of
    running side by side across the channel. The default of zero orders only pairs at the
    same point, whose legs would overlap. A positive value can increase the number of
    tracks, since such pairs could otherwise share a track.

See [`Paths.assign_tracks!`](@ref).
"""
struct AutoChannelRouting{T <: Coordinate} <: AbstractChannelRouting
    router::ChannelRouter{T}
    transition_rule::RouteRule
    transition_margin::T
    max_refinement_passes::Int
    min_leg_spacing::T
end

function AutoChannelRouting(
    router::ChannelRouter{T},
    transition_rule,
    margin;
    max_refinement_passes=2,
    min_leg_spacing=zero(T)
) where {T}
    return AutoChannelRouting{T}(
        router,
        transition_rule,
        convert(T, margin),
        max_refinement_passes,
        convert(T, min_leg_spacing)
    )
end
function AutoChannelRouting(
    channels::Vector{RouteChannel{T}},
    transition_rule,
    margin;
    kwargs...
) where {T}
    return AutoChannelRouting(ChannelRouter(channels), transition_rule, margin; kwargs...)
end
entry_rules(r::AutoChannelRouting) = Iterators.repeated(r.transition_rule)
exit_rule(r::AutoChannelRouting) = r.transition_rule

function track_path_segments(rule::AutoChannelRouting, pa::Path, _)
    matching_idx = findall(
        pin -> pin.p ≈ p0(pa) && isapprox_angle(in_direction(pin), α0(pa)),
        rule.router.pins[first.(rule.router.net_pins)]
    )
    isempty(matching_idx) && error(
        "Could not find start pin corresponding to path $(pa.name) starting at $(p0(pa))."
    )
    length(matching_idx) > 1 && error(
        "Multiple nets $(matching_idx) including $(pa.name) start at $(p0(pa)). AutoChannelRouting requires distinct starting pins."
    )
    net_idx = only(matching_idx)
    return [
        track_path_segment(rule.router, channel, net_idx; margin=rule.transition_margin) for
        channel in channels_taken(rule.router, net_idx)
    ]
end

function track_path_segment(
    ar::ChannelRouter{T},
    channel_idx::Int,
    net_idx::Int;
    margin=zero(T)
) where {T}
    ch = ar.channels[channel_idx]
    # Get the track wire segment from the router
    # Assume there is exactly one wire segment belonging to this path in the channel
    wireseg_idx = findfirst(ws -> running_channel(ws) == channel_idx, net_wire(ar, net_idx))
    wireseg = net_wire(ar, net_idx)[wireseg_idx]
    track_idx = segment_track(ar, wireseg)
    # Get the starting and ending pathlengths
    # Accounting for track offsets
    wireseg_start, wireseg_stop = unsorted_interval(ar, wireseg)
    prev_width = zero(T) # Autorouter just uses margin
    next_width = zero(T) # Interval already takes into account actual neighbor track offsets so we don't need this precaution
    channel_section = segment_channel_section(
        ch,
        wireseg_start,
        wireseg_stop,
        prev_width,
        next_width;
        margin
    )
    # Return channel section segment offset by width according to track
    return track_path_segment(
        length(channel_tracks(ar, channel_idx)),
        channel_section,
        track_idx;
        reversed=against_channel(ar, wireseg)
    )
end

function channels_taken(ar::ChannelRouter, net_idx::Int)
    return [running_channel(wireseg) for wireseg in net_wire(ar, net_idx)]
end
