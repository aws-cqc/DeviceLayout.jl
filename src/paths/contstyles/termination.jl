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
                sty, len = if initial
                    undecorated(style0(pa)), zero(T)
                else
                    laststyle(pa), pathlength(pa[end])
                end
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
    sty, len = if initial
        undecorated(style0(pa)), zero(T)
    else
        laststyle(pa), pathlength(pa[end])
    end
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

function Termination(pa::Path, rounding=zero(T); initial=false, cpwopen=true)
    sty = initial ? undecorated(style0(pa)) : laststyle(pa)
    sty isa Trace && return TraceTermination(pa, rounding; initial=initial)
    if sty isa CPW
        cpwopen && return CPWOpenTermination(pa, rounding; initial=initial)
        return CPWShortTermination(pa, rounding; initial=initial)
    end
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
