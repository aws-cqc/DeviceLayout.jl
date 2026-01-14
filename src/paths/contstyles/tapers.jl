"""
    struct TaperTrace{T<:Coordinate} <: Trace{true}
        width_start::T
        width_end::T
        length::T
    end

A single trace with a linearly tapered width as a function of path length.
"""
struct TaperTrace{T <: Coordinate} <: Trace{true}
    width_start::T
    width_end::T
    length::T
    TaperTrace{T}(ws::T, we::T, l=zero(T)) where {T <: Coordinate} = new{T}(ws, we, l)
end
copy(x::TaperTrace{T}) where {T} = TaperTrace{T}(x.width_start, x.width_end, x.length)
extent(s::TaperTrace, t) = 0.5 * width(s, t)
width(s::TaperTrace, t) =
    (1 - uconvert(NoUnits, t / s.length)) * s.width_start + t / s.length * s.width_end

function pin(s::TaperTrace{T}; start=nothing, stop=nothing) where {T}
    iszero(s.length) && error("cannot `pin`; length of $s not yet determined.")
    x0 = isnothing(start) ? zero(s.length) : start
    x1 = isnothing(stop) ? s.length : stop
    if (x1 <= x0) || !(zero(x0) <= x0 < s.length) || !(zero(x1) < x1 <= s.length)
        if x1 ≈ s.length
            x1 = s.length
        else
            throw(
                ArgumentError(
                    "Invalid start and/or stop locations: need 0 < $x0 < $x1 <= $(s.length)"
                )
            )
        end
    end
    return TaperTrace{T}(convert(T, width(s, x0)), convert(T, width(s, x1)), x1 - x0)
end
function TaperTrace(width_start::Coordinate, width_end::Coordinate)
    dimension(width_start) != dimension(width_end) && throw(DimensionError(trace, gap))
    w_s, w_e = promote(float(width_start), float(width_end))
    return TaperTrace{typeof(w_s)}(w_s, w_e)
end

"""
    struct TaperCPW{T<:Coordinate} <: CPW{true}
        trace_start::T
        gap_start::T
        trace_end::T
        gap_end::T
        length::T
    end

A CPW with a linearly tapered trace and gap as a function of path length.
"""
struct TaperCPW{T <: Coordinate} <: CPW{true}
    trace_start::T
    gap_start::T
    trace_end::T
    gap_end::T
    length::T
end

function TaperCPW{T}(ts::T, gs::T, te::T, ge::T) where {T <: Coordinate}
    return TaperCPW{T}(ts, gs, te, ge, zero(T))
end

TaperCPW(s0::SimpleCPW, s1::SimpleCPW) = TaperCPW(s0.trace, s0.gap, s1.trace, s1.gap)

copy(x::TaperCPW{T}) where {T} =
    TaperCPW{T}(x.trace_start, x.gap_start, x.trace_end, x.gap_end, x.length)
extent(s::TaperCPW, t) =
    (1 - uconvert(NoUnits, t / s.length)) * (0.5 * s.trace_start + s.gap_start) +
    (t / s.length) * (0.5 * s.trace_end + s.gap_end)
trace(s::TaperCPW, t) =
    (1 - uconvert(NoUnits, t / s.length)) * s.trace_start + t / s.length * s.trace_end
gap(s::TaperCPW, t) =
    (1 - uconvert(NoUnits, t / s.length)) * s.gap_start + t / s.length * s.gap_end
function TaperCPW(
    trace_start::Coordinate,
    gap_start::Coordinate,
    trace_end::Coordinate,
    gap_end::Coordinate
)
    (
        (
            dimension(trace_start) != dimension(gap_start) ||
            dimension(trace_end) != dimension(gap_end) ||
            dimension(trace_start) != dimension(trace_end)
        ) && throw(DimensionError(trace, gap))
    )
    t_s, g_s, t_e, g_e =
        promote(float(trace_start), float(gap_start), float(trace_end), float(gap_end))
    return TaperCPW{typeof(t_s)}(t_s, g_s, t_e, g_e)
end

function pin(sty::TaperCPW{T}; start=nothing, stop=nothing) where {T}
    iszero(sty.length) && error("cannot `pin`; length of $sty not yet determined.")
    x0 = isnothing(start) ? zero(sty.length) : start
    x1 = isnothing(stop) ? sty.length : stop
    if (x1 <= x0) || !(zero(x0) <= x0 < sty.length) || !(zero(x1) < x1 <= sty.length)
        if x1 ≈ sty.length
            x1 = sty.length
        else
            throw(
                ArgumentError(
                    "Invalid start and/or stop locations: need 0 < $x0 < $x1 <= $(sty.length)"
                )
            )
        end
    end
    return typeof(sty)(
        convert(T, trace(sty, x0)),
        convert(T, gap(sty, x0)),
        convert(T, trace(sty, x1)),
        convert(T, gap(sty, x1)),
        x1 - x0
    )
end

summary(s::TaperTrace) = string(
    "Tapered trace with initial width ",
    s.width_start,
    " and final width ",
    s.width_end
)
summary(s::TaperCPW) = string(
    "Tapered CPW with initial width ",
    s.trace_start,
    " and initial gap ",
    s.gap_start,
    " tapers to a final width ",
    s.trace_end,
    " and final gap ",
    s.gap_end
)

"""
    Taper()

Constructor for generic Taper style. Will automatically create a linearly tapered region
between an initial `CPW` or `Trace` and an end `CPW` or `Trace` of different dimensions.
"""
struct Taper <: ContinuousStyle{false} end
copy(::Taper) = Taper()

summary(::Taper) = string("Generic linear taper between neighboring segments in a path")

function handle_generic_tapers!(p)
    # Adjust the path so generic tapers render correctly
    generic_taper_inds = findall(x -> isa(style(x), Paths.Taper), nodes(p))
    for i in generic_taper_inds
        tapernode = p[i]
        prevnode = previous(tapernode)
        nextnode = next(tapernode)
        if (prevnode === tapernode) || (nextnode === tapernode)
            error("A generic taper cannot start or finish a path")
        end
        taper_style = get_taper_style(prevnode, nextnode)
        setstyle!(tapernode, taper_style)
    end

    return generic_taper_inds
end

function get_taper_style(prevnode, nextnode)
    prevstyle = style(prevnode)
    nextstyle = style(nextnode)
    beginof_next = zero(pathlength(segment(nextnode)))
    endof_prev = pathlength(segment(prevnode))
    # handle case of compound style (#39)
    if prevstyle isa Paths.CompoundStyle
        prevstyle, endof_prev = prevstyle(endof_prev)
    end
    if nextstyle isa Paths.CompoundStyle
        nextstyle, beginof_next = nextstyle(beginof_next)
    end

    if (
        (prevstyle isa Paths.CPW || prevstyle isa Paths.Trace) &&
        (nextstyle isa Paths.CPW || nextstyle isa Paths.Trace)
    )
        #special case: both ends are Traces, make a Paths.TaperTrace
        if prevstyle isa Paths.Trace && nextstyle isa Paths.Trace
            thisstyle = Paths.TaperTrace(
                Paths.width(prevstyle, endof_prev),
                Paths.width(nextstyle, beginof_next)
            )
        elseif prevstyle isa Paths.Trace #previous segment is Paths.trace
            gap_start = Paths.width(prevstyle, endof_prev) / 2.0
            trace_end = Paths.trace(nextstyle, beginof_next)
            gap_end = Paths.gap(nextstyle, beginof_next)
            thisstyle = Paths.TaperCPW(zero(gap_start), gap_start, trace_end, gap_end)
        elseif nextstyle isa Paths.Trace #next segment is Paths.trace
            trace_start = Paths.trace(prevstyle, endof_prev)
            gap_end = Paths.width(nextstyle, beginof_next) / 2.0
            gap_start = Paths.gap(prevstyle, endof_prev)
            thisstyle = Paths.TaperCPW(trace_start, gap_start, zero(gap_end), gap_end)
        else #both segments are CPW
            trace_start = Paths.trace(prevstyle, endof_prev)
            trace_end = Paths.trace(nextstyle, beginof_next)
            gap_start = Paths.gap(prevstyle, endof_prev)
            gap_end = Paths.gap(nextstyle, beginof_next)
            thisstyle = Paths.TaperCPW(trace_start, gap_start, trace_end, gap_end)
        end
    else
        error("a generic taper must have either a Paths.CPW or Paths.Trace on both ends.")
    end
    return thisstyle
end

function restore_generic_tapers!(p, taper_inds)
    for i in taper_inds
        setstyle!(p[i], Paths.Taper())
    end
end
