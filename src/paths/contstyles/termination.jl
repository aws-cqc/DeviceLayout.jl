for (S, label) in zip((:CPWOpenTermination, :CPWShortTermination), ("Open", "Shorted"))
    doc = """
    struct $(S){T <: Coordinate} <: ContinuousStyle{false}
        trace::T
        gap::T
        open_gap::T
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
                open_gap::T
                rounding::T
                initial::Bool
            end
            function $(S)(t, g, r, o=g; initial=false)
                tt, gg, rr, oo = promote(t, g, r, o)
                return $(S){typeof(tt)}(tt, gg, oo, rr, initial)
            end
            $(S)(s::CPW, t, rounding=zero(t), o=gap(s, t); initial=false) =
                $(S)(trace(s, t), gap(s, t), rounding, o; initial=initial)

            copy(s::$S) = $(S)(s.trace, s.gap, s.open_gap, s.rounding, s.initial)
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
TraceTermination(s::Trace, t, rounding=zero(t); initial=false) =
    TraceTermination(trace(s, t), rounding; initial=initial)

copy(s::TraceTermination) = TraceTermination(s.width, s.rounding, s.initial)
extent(s::TraceTermination, t...) = s.width / 2
trace(s::TraceTermination, t...) = s.width
width(s::TraceTermination, t...) = s.width

summary(s::TraceTermination) =
    string("Termination of Trace with width ", s.width, " and rounding radius ", s.rounding)

# Return actual style (inside any compound styles) and length into that style at the end of the path [+/- rounding]
function terminal_style(pa::Path{T}, initial, rounding=zero(T)) where {T}
    idx = initial ? firstindex(pa) : lastindex(pa)
    sty = without_attachments(style(pa[idx]))
    length_into_sty = initial ? rounding : pathlength(pa[end]) - rounding
    return terminal_style(sty, length_into_sty)
end

function terminal_style(sty::Paths.AbstractCompoundStyle, length_into_sty)
    return sty(length_into_sty)
end
function terminal_style(sty::Paths.Style, length_into_sty)
    return sty, length_into_sty
end

# Default length of non-rounded termination segment
function terminationlength(pa::Path{T}, initial::Bool; overlay_index=0) where {T}
    sty, len = terminal_style(pa, initial)
    return terminationlength(sty, len; overlay_index)
end

terminationlength(s, t; overlay_index=0) = zero(t)
terminationlength(s::CPW, t; overlay_index=0) = gap(s, t)
function terminationlength(s::OverlayStyle, t; overlay_index=0)
    iszero(overlay_index) && return terminationlength(s.s, t)
    return terminationlength(s.overlay[overlay_index], t)
end

function Termination(
    pa::Path{T},
    rounding=zero(T);
    initial=false,
    overlay_index=0,
    gap=terminationlength(pa, initial; overlay_index)
) where {T}
    sty, length_into_sty = terminal_style(pa, initial, rounding)
    return _termination(
        sty,
        length_into_sty,
        rounding;
        initial,
        overlay_index,
        open_gap=gap
    )
end

function _termination(
    sty,
    length_into_sty::T,
    rounding=zero(T);
    initial=false,
    overlay_index=0,
    open_gap=zero(T)
) where {T}
    sty, length_into_sty = terminal_style(sty, length_into_sty)
    if sty isa OverlayStyle
        # Terminate the indicated style
        if iszero(overlay_index)
            termsty = _termination(sty.s, length_into_sty, rounding; initial, open_gap)
            newsty = copy(sty)
            newsty.s = termsty
        else
            oversty = sty.overlay[overlay_index]
            termsty = _termination(oversty, length_into_sty, rounding; initial, open_gap)
            newsty = copy(sty)
            newsty.overlay[overlay_index] = termsty
        end
        # Pin other styles
        if !iszero(overlay_index)
            if initial
                newsty.s = pin(newsty.s, stop=length_into_sty)
            else
                newsty.s = pin(newsty.s, start=length_into_sty)
            end
        end
        for idx in eachindex(sty.overlay)
            idx == overlay_index && continue
            if initial
                # Wrong if overlay is compound...
                newsty.overlay[idx] = pin(newsty.overlay[idx], stop=length_into_sty)
            else
                newsty.overlay[idx] = pin(newsty.overlay[idx], start=length_into_sty)
            end
        end
        return newsty
    end
    !iszero(overlay_index) && error(
        "Terminal style must be an OverlayStyle to terminate with nonzero `overlay_index"
    )
    sty isa Trace &&
        return TraceTermination(sty, length_into_sty, rounding; initial=initial)
    if sty isa CPW
        !iszero(open_gap) && return CPWOpenTermination(
            sty,
            length_into_sty,
            rounding,
            open_gap;
            initial=initial
        )
        return CPWShortTermination(sty, length_into_sty, rounding; initial=initial)
    end
    return error("Cannot terminate style '$sty': Path must end in Trace or CPW style")
end

function pin(
    s::Union{TraceTermination, CPWOpenTermination, CPWShortTermination};
    start=nothing,
    stop=nothing
)
    # Return termination for the part that connects to the path, SimpleNoRender otherwise
    if !s.initial && (isnothing(start) || iszero(start))
        return s
    elseif s.initial && (isnothing(stop) || stop == _termlength(s))
        return s
    end
    return SimpleNoRender(2 * extent(s), virtual=true) # not a user-created NoRender => virtual
end

# Actual length of termination polygon
_termlength(s::Paths.TraceTermination) = s.rounding
_termlength(s::Paths.CPWOpenTermination) = s.rounding + s.open_gap
_termlength(s::Paths.CPWShortTermination) = s.rounding

"""
    terminate!(pa::Path{T}; gap=Paths.terminationlength(pa), rounding=zero(T), initial=false, overlay_index=0) where {T}

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

`overlay_index` can be used to indicate that the termination should be applied to an overlay
layer in a path.

If `initial`, the termination is appended before the beginning of the `Path`.
"""
function terminate!(
    pa::Path{T};
    rounding=zero(T),
    initial=false,
    overlay_index=0,
    gap=terminationlength(pa, initial; overlay_index)
) where {T}
    termlen = gap + rounding
    iszero(termlen) && return
    termsty = Termination(pa, rounding; initial, gap, overlay_index)
    # Nonzero rounding: splice and delete to make room for rounded part
    if !iszero(rounding)
        orig_sty, l_into_style = terminal_style(pa, initial)
        round_gap = (orig_sty isa CPW && iszero(gap))
        split_idx = initial ? firstindex(pa) : lastindex(pa)
        split_node = pa[split_idx]
        len = pathlength(split_node)
        l_into_style = initial ? rounding : l_into_style - rounding
        _check_termination(orig_sty, l_into_style, len, rounding, round_gap, overlay_index)
        split_len = initial ? rounding : len - rounding
        if split_len > zero(split_len) && split_len < len
            # If rounding doesn't eat the whole node, split off the part that gets eaten
            splice!(pa, split_idx, split(split_node, split_len))
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

function _check_termination(
    termsty,
    l_into_style,
    len,
    rounding,
    round_gap,
    overlay_index=0
)
    len >= rounding || throw(
        ArgumentError(
            "`rounding` $rounding too large for previous segment path length $len."
        )
    )
    !round_gap &&
        (2 * rounding > trace(termsty, l_into_style)) &&
        throw(
            ArgumentError(
                "`rounding` $rounding too large for previous segment trace width $(trace(termsty, l_into_style)))."
            )
        )
    return round_gap &&
           (2 * rounding > Paths.gap(termsty, l_into_style)) &&
           throw(
               ArgumentError(
                   "`rounding` $rounding too large for previous segment gap $(Paths.gap(termsty, l_into_style))."
               )
           )
end

function _check_termination(
    termsty::OverlayStyle,
    l_into_style,
    len,
    rounding,
    round_gap,
    overlay_index
)
    iszero(overlay_index) &&
        return _check_termination(termsty.s, l_into_style, len, rounding, round_gap)
    return _check_termination(
        termsty.overlay[overlay_index],
        l_into_style,
        len,
        rounding,
        round_gap
    )
end

function nextstyle(::Union{TraceTermination, CPWOpenTermination, CPWShortTermination})
    return NoRenderContinuous()
end
