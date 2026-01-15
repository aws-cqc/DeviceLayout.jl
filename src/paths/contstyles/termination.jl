for (S, label) in zip((:CPWOpenTermination, :CPWShortTermination), ("Open", "Shorted"))
    doc = """
    struct $(S){T <: Coordinate} <: ContinuousStyle{false}
        trace::T
        gap::T
        rounding::T
        initial::Bool
    end

    Used by `Paths.terminate!`, not constructed directly.
    """
    eval(
        quote
            @doc $doc struct $(S){T <: Coordinate} <: ContinuousStyle{false}
                trace::T
                gap::T
                rounding::T
                initial::Bool
            end
            function $(S)(t, g, r; initial=false)
                tt, gg, rr = promote(t, g, r)
                return $(S){typeof(tt)}(tt, gg, rr, initial)
            end
            function $(S)(pa::Path{T}, rounding=zero(T); initial=false) where {T}
                sty, len = terminal_style(pa, initial)
                return $(S)(sty, len, rounding, initial=initial)
            end
            $(S)(s::CPW, t, rounding=zero(t); initial=false) =
                $(S)(trace(s, t), gap(s, t), rounding; initial=initial)

            copy(s::$S) = $(S)(s.trace, s.gap, s.rounding, s.initial)
            extent(s::$S, t...) = trace(s, t) / 2 + gap(s, t)
            trace(s::$S, t...) = s.trace
            gap(s::$S, t...) = s.gap

            summary(s::$S) = string(
                $label,
                " termination of CPW with width ",
                s.trace,
                ", gap ",
                s.gap,
                ", and rounding radius ",
                s.rounding
            )
        end
    )
end

"""
    struct TraceTermination{T <: Coordinate} <: ContinuousStyle{false}
        width::T
        rounding::T
        initial::Bool
    end

    Used by `Paths.terminate!`, not constructed directly.
"""
struct TraceTermination{T <: Coordinate} <: ContinuousStyle{false}
    width::T
    rounding::T
    initial::Bool
end
function TraceTermination(t, r; initial=false)
    tt, rr = promote(t, r)
    return TraceTermination{typeof(tt)}(tt, rr, initial)
end
function TraceTermination(pa::Path{T}, rounding=zero(T); initial=false) where {T}
    sty, len = terminal_style(pa, initial)
    return TraceTermination(sty, len, rounding; initial=initial)
end
TraceTermination(s::Trace, t, rounding=zero(t); initial=false) =
    TraceTermination(trace(s, t), rounding; initial=initial)

copy(s::TraceTermination) = TraceTermination(s.width, s.rounding, s.initial)
extent(s::TraceTermination, t...) = s.width / 2
trace(s::TraceTermination, t...) = s.width
width(s::TraceTermination, t...) = s.width

summary(s::TraceTermination) =
    string("Termination of Trace with width ", s.width, " and rounding radius ", s.rounding)

function terminal_style(pa::Path{T}, initial) where {T}
    sty = initial ? undecorated(style(pa[begin])) : undecorated(style(pa[end]))
    length_into_sty = initial ? zero(T) : pathlength(pa[end])
    while sty isa AbstractCompoundStyle
        sty, length_into_sty = sty(length_into_sty)
    end
    return sty, length_into_sty
end

function Termination(pa::Path{T}, rounding=zero(T); initial=false, cpwopen=true) where {T}
    sty, length_into_sty = terminal_style(pa, initial)
    return Termination(sty, length_into_sty, rounding; initial=initial, cpwopen=cpwopen)
end

function Termination(sty, length_into_sty::T, rounding=zero(T); initial=false, cpwopen=true) where {T}
    sty isa Trace && return TraceTermination(sty, length_into_sty, rounding; initial=initial)
    if sty isa CPW
        cpwopen && return CPWOpenTermination(sty, length_into_sty, rounding; initial=initial)
        return CPWShortTermination(sty, length_into_sty, rounding; initial=initial)
    end
    return nothing
end

function pin(s::Union{TraceTermination, CPWOpenTermination, CPWShortTermination};
        start=nothing, stop=nothing)
    # Return termination for the part that connects to the path, SimpleNoRender otherwise
    if !s.initial && isnothing(start)
        return s
    elseif s.initial && isnothing(stop)
        return s
    end
    return SimpleNoRender(2*extent(s), virtual=true) # not a user-created NoRender => virtual
end
