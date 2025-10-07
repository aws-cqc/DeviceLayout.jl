"""
    RouteChannel{T} <: AbstractComponent{T}
    RouteChannel(pa::Path)

A channel that routes can be guided through along parallel tracks.

Used in `route!` with [`Paths.SingleChannelRouting`](@ref).

The `Path` used to construct a `RouteChannel` should use `Trace` styles only.

A `RouteChannel` is an `AbstractComponent` with the same hooks as its `Path` and
an empty geometry.
"""
struct RouteChannel{T} <: AbstractComponent{T}
    path::Path{T}
    node::Node{T} # path as single node
end
name(ch::RouteChannel) = name(ch.path)
DeviceLayout.hooks(ch::RouteChannel) = DeviceLayout.hooks(ch.path)

function RouteChannel(pa::Path{T}) where {T}
    length(nodes(pa)) != 1 && return RouteChannel{T}(pa, simplify(pa))
    return RouteChannel{T}(pa, only(nodes(pa)))
end

# Return a node corresponding to the section of the channel that the segment actually runs through
function segment_channel_section(
    ch::RouteChannel{T},
    wireseg_start,
    wireseg_stop,
    prev_width,
    next_width;
    margin=zero(T)
) where {T}
    d = wireseg_stop - wireseg_start
    # Adjust for margins and track vs channel direction to get the channel node section used by actual segment
    if abs(d) <= 2 * margin + prev_width / 2 + next_width / 2
        # handle case where margin consumes entire segment
        # Just have a zero length Straight at the midpoint
        track_mid = (wireseg_start + wireseg_stop) / 2
        midpoint = ch.node.seg(track_mid)
        middir = direction(ch.node.seg, track_mid)
        channel_section = Node(
            Straight(zero(T); p0=midpoint, α0=middir),
            SimpleTrace(width(ch.node.sty, track_mid))
        )
    elseif d > zero(d) # segment is along channel direction
        channel_section = split(
            ch.node,
            [
                wireseg_start + margin + prev_width / 2,
                wireseg_stop - margin - next_width / 2
            ]
        )[2]
    elseif d < zero(d) # segment is counter to channel direction
        channel_section = reverse(
            split(
                ch.node,
                [
                    wireseg_stop + margin + next_width / 2,
                    wireseg_start - margin - prev_width / 2
                ]
            )[2]
        )
    end
    return channel_section
end

# Actual routed path segment along a track offset from the channel path
function track_path_segment(n_tracks, channel_section, track_idx; reversed=false)
    return offset(
        channel_section.seg,
        track_section_offset(n_tracks, width(channel_section.sty), track_idx; reversed)
    )
end

# Offset coordinate or function for the section of track with given width
function track_section_offset(
    n_tracks,
    section_width::Coordinate,
    track_idx;
    reversed=false
)
    # (spacing) * number of tracks away from middle track
    sgn = reversed ? -1 : 1
    spacing = section_width / (n_tracks + 1)
    return sgn * spacing * (track_idx - (1 + n_tracks) / 2)
end

function track_section_offset(n_tracks, section_width::Function, track_idx; reversed=false)
    # (spacing) * number of tracks away from middle track
    return t ->
        (reversed ? -1 : 1) *
        (section_width(t) / (n_tracks + 1)) *
        (track_idx - (1 + n_tracks) / 2)
end

reverse(n::Node) = Paths.Node(reverse(n.seg), reverse(n.sty, pathlength(n.seg)))
######## Methods required to use segments and styles as RouteChannels
function reverse(b::BSpline{T}) where {T}
    p = reverse(b.p)
    t0 = RotationPi()(b.t1)
    t1 = RotationPi()(b.t0)
    # Use true t range for interpolations defined by points that have been scaled out of [0,1]
    tmin = b.r.ranges[1][1]
    tmax = b.r.ranges[1][end]
    (tmin == 0 && tmax == 1) && return BSpline(p, t0, t1)
    p0 = b.p1
    p1 = b.p0
    r = Interpolations.scale(
        interpolate(p, Interpolations.BSpline(Cubic(NeumannBC(t0, t1)))),
        range(1 - tmax, stop=1 - tmin, length=length(p))
    )
    α0 = rotated_direction(b.α1, RotationPi())
    α1 = rotated_direction(b.α0, RotationPi())
    return BSpline(p, t0, t1, r, p0, p1, α0, α1)
end
reverse(s::Turn) = Turn(-s.α, s.r, p1(s), α1(s) + 180°)
reverse(s::Straight) = Straight(s.l, p1(s), s.α0 + 180°)
# Reversing a GeneralTrace requires knowing its length, so we'll require that as an argument even if unused
reverse(s::TaperTrace{T}, l) where {T} = TaperTrace{T}(s.width_end, s.width_start, s.length)
reverse(s::SimpleTrace, l) = s
reverse(s::GeneralTrace, l) = GeneralTrace(t -> width(s, l - t))
# Define methods for CPW even though they're not allowed for channels
reverse(s::TaperCPW{T}, l) where {T} =
    TaperCPW{T}(s.trace_end, s.gap_end, s.trace_start, s.gap_start, s.length)
reverse(s::SimpleCPW, l) = s
reverse(s::GeneralCPW, l) = GeneralCPW(t -> trace(s, l - t), t -> gap(s, l - t))
# For compound segments, reverse the individual sections and reverse their order
# Keep the same tag so if a compound segment/style pair matched before they will still match
reverse(s::CompoundSegment) = CompoundSegment(reverse(reverse.(s.segments)), s.tag)
function reverse(s::CompoundStyle{T}, l) where {T}
    lengths = reverse(diff(s.tgrid))
    return CompoundStyle{T}(
        reverse(reverse.(s.styles, lengths)),
        cumsum(reverse(lengths)),
        s.tag
    )
end

abstract type AbstractMultiRouting <: RouteRule end

abstract type AbstractChannelRouting <: AbstractMultiRouting end

function _route!(
    p::Path{T},
    p1::Point,
    α1,
    rule::AbstractChannelRouting,
    sty,
    waypoints,
    waydirs
) where {T}
    # Track segments for each channel
    track_path_segs = track_path_segments(rule, p, p1)
    waypoints = Point{T}[] # Segments too short for margins will just become waypoints for transitions
    # Add segments and transitions
    for (track_path_seg, next_entry_rule) in zip(track_path_segs, entry_rules(rule))
        if iszero(pathlength(track_path_seg)) # Was too short for margins
            push!(waypoints, p0(track_path_seg))
        else
            route!(
                p,
                p0(track_path_seg),
                α0(track_path_seg),
                next_entry_rule,
                sty;
                waypoints
            )
            push!(p, Node(track_path_seg, sty), reconcile=false) # p0, α0 reconciled by construction
            p[end - 1].next = p[end]
            p[end].prev = p[end - 1]
            # Note `auto_curvature` BSpline uses curvature from end of previous segment
            # and is not reconciled with the new node
            # But we can do this ourselves
            _reconcile_curvature!(p[end - 1], next_entry_rule)
            empty!(waypoints)
        end
    end
    # Exit
    route!(p, p1, α1, exit_rule(rule), sty; waypoints)
    _reconcile_curvature!(p[end], exit_rule(rule))
    return
end

function _reconcile_curvature!(n::Node{T}, rule::RouteRule) where {T} end
function _reconcile_curvature!(n::Node{T}, rule::BSplineRouting) where {T}
    !rule.auto_curvature && return
    κ0 = if n.prev === n
        0.0 / oneunit(T)
    else
        signed_curvature(segment(n.prev), pathlength(segment(n.prev)))
    end
    κ1 = if n.next === n
        0.0 / oneunit(T)
    else
        signed_curvature(segment(n.next), zero(coordinatetype(n)))
    end
    _set_endpoints_curvature!(segment(n), κ0, κ1)
    if rule.auto_speed
        _optimize_bspline!(segment(n); endpoints_curvature=(κ0, κ1))
    else
        _update_interpolation!(segment(n))
    end
end

"""
    struct SingleChannelRouting{T <: Coordinate} <: AbstractChannelRouting
    SingleChannelRouting(ch::RouteChannel, transition_rule::RouteRule, margin::T)
    SingleChannelRouting(ch::RouteChannel, transition_rules, margins)

A `RouteRule` for guiding routed paths along tracks in a [`Paths.RouteChannel`](@ref).

## Tracks

"Tracks" are offsets of the channel's path, with equal spacing between each other
and the extents of the channel's trace width. Tracks are ordered from right to left
when looking along the channel. For example, track 1 is the bottom track
(most negative offset) for a channel directed along the positive x axis, while
the highest track index is the top track.

The user manually assigns tracks to paths that will be routed with
`rule::SingleChannelRouting` using `set_track!(rule, path)` for each path,
prior to calling `route!(path, ...)`.

If used for schematic routing, the track is supplied as a keyword argument,
defaulting to a new track added at the top of the channel:
`route!(g::SchematicGraph, rule, ...; track=num_tracks(rule)+1)`.

## Routing

A path routed from `p0` to `p1` using this rule will enter the channel
at the channel's closest point to `p0` and exit at the closest point to `p1` if
`margin` is zero. For nonzero `margin`, the entry and exit points are each shifted
towards the other along the channel by `margin`, allowing more space for the
transitions into and out of the channel.

The middle "tracked" section is offset from the channel's center line according to
the path's track, the maximum track assigned to any path by the rule,
and the channel width.

The path is routed from `p0` to the tracked section and from the tracked section
to `p1` using `transition_rule`.

Transition rules and margins can also be supplied as tuples to the constructor
to allow different parameters for entry and exit transitions.
"""
mutable struct SingleChannelRouting{T <: Coordinate} <: AbstractChannelRouting
    channel::RouteChannel{T}
    transition_rules::Tuple{<:RouteRule, <:RouteRule}
    transition_margins::Tuple{T, T}
    segment_tracks::Dict{Path, Int}
    global_channel::RouteChannel{T}
    function SingleChannelRouting(
        ch::RouteChannel{T},
        rules,
        margins,
        tracks=Dict{Path, Int}()
    ) where {T}
        return new{T}(ch, rules, margins, tracks)
    end
end
function SingleChannelRouting(
    ch::RouteChannel{T},
    rule::RouteRule,
    margin,
    tracks...
) where {T}
    return SingleChannelRouting(ch, (rule, rule), (margin, margin), tracks...)
end
function channel(rule::SingleChannelRouting)
    isdefined(rule, :global_channel) && return rule.global_channel
    return rule.channel
end
entry_rules(scr::SingleChannelRouting) = [first(scr.transition_rules)]
exit_rule(scr::SingleChannelRouting) = last(scr.transition_rules)
entry_margin(scr::SingleChannelRouting) = first(scr.transition_margins)
exit_margin(scr::SingleChannelRouting) = last(scr.transition_margins)
function num_tracks(scr::SingleChannelRouting)
    isempty(scr.segment_tracks) && return 0
    return maximum(values(scr.segment_tracks))
end
function track_idx(scr, pa)
    return scr.segment_tracks[pa]
end
function set_track!(scr, pa, track_idx)
    return scr.segment_tracks[pa] = track_idx
end

function track_path_segments(rule::SingleChannelRouting, pa::Path, endpt)
    wireseg_start = pathlength_nearest(channel(rule).node.seg, p1(pa))
    wireseg_stop = pathlength_nearest(channel(rule).node.seg, endpt)
    return [
        track_path_segment(
            num_tracks(rule),
            segment_channel_section(
                channel(rule),
                wireseg_start,
                wireseg_stop,
                2 * entry_margin(rule),
                2 * exit_margin(rule)
            ),
            track_idx(rule, pa),
            reversed=wireseg_start > wireseg_stop
        )
    ]
end
