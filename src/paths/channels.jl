"""
    RouteChannel{T} <: AbstractComponent{T}
    RouteChannel(pa::Path)
"""
struct RouteChannel{T} <: AbstractComponent{T}
    path::Path{T}
    node::Node{T} # path as single node
    capacity::Int # Currently unused
end

function RouteChannel(pa::Path{T}, capacity=0) where {T}
    length(nodes(pa)) != 1 && return RouteChannel{T}(pa, simplify(pa), capacity)
    return RouteChannel{T}(pa, only(nodes(pa)), capacity)
end

# Return a node corresponding to the section of the channel that the segment actually runs through
function segment_channel_section(ch::RouteChannel{T}, wireseg_start, wireseg_stop, prev_width, next_width; margin=zero(T)) where {T}
    d = wireseg_stop - wireseg_start
    # Adjust for margins and track vs channel direction to get the channel node section used by actual segment
    if abs(d) <= 2*margin + prev_width + next_width
        # handle case where margin consumes entire segment
        # Just have a zero length Straight at the midpoint
        track_mid = (wireseg_start + wireseg_stop)/2
        midpoint = ch.node.seg(track_mid)
        middir = direction(ch.node.seg, track_mid)
        channel_section = Node(Straight(zero(T), midpoint, middir), SimpleTrace(width(ch.node.sty, track_mid)))
    elseif d > zero(d) # segment is along channel direction
        channel_section = split(ch.node,
            [wireseg_start + margin + prev_width/2,
             wireseg_stop - margin - next_width/2])[2]
    elseif d < zero(d) # segment is counter to channel direction
        channel_section = reverse(split(ch.node,
            [wireseg_stop + margin + next_width/2,
             wireseg_start - margin - prev_width/2])[2])
    end
    return channel_section
end

function track_path_segment(n_tracks, channel_section, track_idx; reversed=false)
    return offset(channel_section.seg,
        track_section_offset(n_tracks, width(channel_section.sty), track_idx; reversed))
end

function track_section_offset(n_tracks, section_width::Coordinate, track_idx; reversed=false)
    # (spacing) * number of tracks away from middle track
    sgn = reversed ? -1 : 1
    spacing = section_width / (n_tracks + 1)
    return sgn * spacing * (track_idx - (1 + n_tracks) / 2)
end

function track_section_offset(n_tracks, section_width::Function, track_idx; reversed=false)
    # (spacing) * number of tracks away from middle track
    return t -> (reversed ? -1 : 1) * (section_width(t) / (n_tracks + 1)) * (track_idx - (1 + n_tracks) / 2)
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
        range(1-tmax, stop=1-tmin, length=length(p))
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
reverse(s::TaperCPW{T}, l) where {T} = TaperCPW{T}(s.trace_end, s.gap_end, s.trace_start, s.gap_start, s.length)
reverse(s::SimpleCPW, l) = s
reverse(s::GeneralCPW, l) = GeneralCPW(t -> trace(s, l - t), t -> gap(s, l - t))
# For compound segments, reverse the individual sections and reverse their order
# Keep the same tag so if a compound segment/style pair matched before they will still match
reverse(s::CompoundSegment) = CompoundSegment(reverse(reverse.(s.segments)), s.tag)
function reverse(s::CompoundStyle{T}, l) where {T}
    lengths = reverse(diff(s.tgrid))
    CompoundStyle{T}(reverse(reverse.(s.styles, lengths)), cumsum(reverse(lengths)), s.tag)
end

abstract type AbstractMultiRouting <: RouteRule end

abstract type AbstractChannelRouting <: AbstractMultiRouting end

function _route!(p::Path{T}, p1::Point, α1, rule::AbstractChannelRouting, 
                    sty, waypoints, waydirs) where {T}
    # Track segments for each channel
    track_path_segs = track_path_segments(rule, p, p1)
    waypoints = Point{T}[] # Segments too short for margins will just become waypoints for transitions
    # Add segments and transitions
    for (track_path_seg, next_entry_rule) in zip(track_path_segs, entry_rules(rule))
        if iszero(pathlength(track_path_seg)) # Was too short for margins
            push!(waypoints, p0(track_path_seg))
        else
            route!(p, p0(track_path_seg), α0(track_path_seg), next_entry_rule, sty; waypoints)
            push!(p, Node(track_path_seg, sty), reconcile=false) # already reconciled by construction
            empty!(waypoints)
        end
    end
    # Exit
    route!(p, p1, α1, exit_rule(rule), sty; waypoints)
    return
end

struct SingleChannelRouting{T} <: AbstractChannelRouting
    channel::RouteChannel{T}
    transition_rules::Tuple{<:RouteRule,<:RouteRule}
    transition_margins::Tuple{T,T}
    segment_tracks::Dict{Path{T}, Int}
end
function SingleChannelRouting(ch::RouteChannel{T}, rule::RouteRule, margin::T) where {T}
    return SingleChannelRouting{T}(ch, (rule, rule), (margin, margin), Dict{Path{T}, Int}())
end
entry_rules(scr::SingleChannelRouting) = [first(scr.transition_rules)]
exit_rule(scr::SingleChannelRouting) = last(scr.transition_rules)
entry_margin(scr::SingleChannelRouting) = first(scr.transition_margins)
exit_margin(scr::SingleChannelRouting) = last(scr.transition_margins)
num_tracks(scr::SingleChannelRouting) = maximum(values(scr.segment_tracks))
track_idx(scr, pa) = scr.segment_tracks[pa]
function set_track!(scr, pa, track_idx)
    scr.segment_tracks[pa] = track_idx
end

function track_path_segments(rule::SingleChannelRouting, pa::Path, endpt)
    wireseg_start = pathlength_nearest(rule.channel.node.seg, p1(pa))
    wireseg_stop = pathlength_nearest(rule.channel.node.seg, endpt)
    return [track_path_segment(num_tracks(rule),
        segment_channel_section(rule.channel, wireseg_start, wireseg_stop, 2*entry_margin(rule), 2*exit_margin(rule)),
            track_idx(rule, pa),
            reversed=wireseg_start > wireseg_stop)]
end

function _update_with_graph!(rule::SingleChannelRouting, route_node, graph; track=num_tracks(rule)+1, kwargs...)
    set_track!(rule, route_node.component._path, track)
end