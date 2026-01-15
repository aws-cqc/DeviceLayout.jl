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

function terminationlength(pa::Path{T}, initial::Bool) where {T}
    sty, len = terminal_style(pa, initial)
    return terminationlength(sty, len)
end

terminationlength(s, t) = zero(t)
terminationlength(s::CPW, t) = gap(s, t)

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

"""
    terminate!(pa::Path{T}; gap=Paths.terminationlength(pa), rounding=zero(T), initial=false) where {T}

End a `Paths.Path` with a termination.

If the preceding style is a CPW, this is a "short termination" if `iszero(gap)` and is an
"open termination" with a gap of `gap` otherwise, defaulting to the gap of the preceding CPW.

Rounding of corners may be specified with radius given by `rounding`. Rounding keeps the
trace length constant by removing some length from the preceding segment and adding a
rounded section of equivalent maximum length.

Terminations can be applied on curves without changing the underlying curve. If you add a
segment after a termination, it will start a straight distance `gap` away from where the original
curve ended. However, rounded terminations are always drawn as though straight from the point where
rounding starts, slightly before the end of the curve. This allows the rounded corners to be represented
as exact circular arcs.

If the preceding style is a trace, the termination only rounds the corners at the end of the
segment or does nothing if `iszero(rounding)`.

If `initial`, the termination is appended before the beginning of the `Path`.
"""
function terminate!(
    pa::Path{T};
    rounding=zero(T),
    initial=false,
    gap=terminationlength(pa, initial)
) where {T}
    termlen = gap + rounding
    iszero(termlen) && return
    termsty = Termination(pa, rounding; initial=initial, cpwopen=(!iszero(gap)))
    # Nonzero rounding: splice and delete to make room for rounded part
    if !iszero(rounding)
        orig_sty, l_into_style = terminal_style(pa, initial)
        round_gap = (orig_sty isa CPW && iszero(gap))
        split_idx = initial ? firstindex(pa) : lastindex(pa)
        split_node = pa[split_idx]
        len = pathlength(split_node)
        len > rounding || throw(
            ArgumentError(
                "`rounding` $rounding too large for previous segment path length $len."
            )
        )

        split_len = initial ? rounding : len - rounding
        # length into style may be different if orig_sty is a substyle
        l_into_style = initial ? l_into_style + rounding : l_into_style - rounding

        !round_gap &&
            (2 * rounding > trace(orig_sty, l_into_style)) &&
            throw(
                ArgumentError(
                    "`rounding` $rounding too large for previous segment trace width $(trace(orig_sty, split_len))."
                )
            )
        @show orig_sty, split_len
        round_gap &&
            (2 * rounding > Paths.gap(orig_sty, l_into_style)) &&
            throw(
                ArgumentError(
                    "`rounding` $rounding too large for previous segment gap $(Paths.gap(orig_sty, split_len))."
                )
            )
        splice!(pa, split_idx, split(split_node, split_len))
        termsty = if initial
            Termination(Path(pa[2:end]), rounding; initial=initial, cpwopen=(!iszero(gap)))
        else
            Termination(
                Path(pa[1:(end - 1)]),
                rounding;
                initial=initial,
                cpwopen=(!iszero(gap))
            )
        end
    end

    if initial
        α = α0(pa)
        p = p0(pa) - gap * Point(cos(α), sin(α))
        pa.p0 = p
        pushfirst!(pa, Straight{T}(gap, p, α), termsty)
        if !iszero(rounding)
            # merge first two segments and apply termsty
            simplify!(pa, 1:2)
            setstyle!(pa[1], termsty)
        end
    else
        straight!(pa, gap, termsty)
        if !iszero(rounding)
            # merge last two segments and apply termsty
            simplify!(pa, (length(pa) - 1):length(pa))
            setstyle!(pa[end], termsty)
        end
    end
end
