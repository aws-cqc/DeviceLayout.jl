abstract type Trace{T} <: ContinuousStyle{T} end

"""
    struct GeneralTrace{T} <: Trace{false}
        width::T
    end

A single trace with variable width as a function of path length. `width` is callable.
"""
struct GeneralTrace{T} <: Trace{false}
    width::T
end
copy(x::GeneralTrace) = GeneralTrace(x.width)
extent(s::GeneralTrace, t) = 0.5 * s.width(t)
extent(s::GeneralTrace) = Base.Fix1(extent, s)
width(s::GeneralTrace, t) = s.width(t)
width(s::GeneralTrace) = s.width
trace(s::GeneralTrace, t) = s.width(t)
trace(s::GeneralTrace) = s.width
translate(s::GeneralTrace, t) = GeneralTrace(x -> s.width(x + t))

"""
    struct SimpleTrace{T <: Coordinate} <: Trace{false}
        width::T
    end

A single trace with fixed width as a function of path length.
"""
struct SimpleTrace{T <: Coordinate} <: Trace{false}
    width::T
end
copy(x::SimpleTrace) = Trace(x.width)
extent(s::SimpleTrace, t...) = 0.5 * s.width
width(s::SimpleTrace, t...) = s.width
trace(s::SimpleTrace, t...) = s.width
translate(s::SimpleTrace, t) = copy(s)

"""
    Trace(width)
    Trace(width::Coordinate)
    Trace(width_start::Coordinate, width_end::Coordinate)

Constructor for Trace styles. Automatically chooses `SimpleTrace`, `GeneralTrace`,
and `TaperTrace` as appropriate.
"""
Trace(width) = GeneralTrace(width)
Trace(width::Coordinate) = SimpleTrace(float(width))

summary(::GeneralTrace) = "Trace with variable width"
summary(s::SimpleTrace) = string("Trace with width ", s.width)

# Constructor for rounded taper as GeneralTrace
function rounded_transition(sty0::SimpleTrace, sty1::SimpleTrace; α_max=60°)
    return Trace(s -> rounded_transition_width(s, sty0.width, sty1.width, α_max))
end

function rounded_transition(sty0::SimpleTrace, sty1::SimpleTrace, taper_length, radius)
    return Trace(
        s -> rounded_transition_width(s, sty0.width, sty1.width, taper_length, radius)
    )
end

function rounded_transition_width(s, w0, w1, α_max)
    dw = abs(w0 - w1)
    taper_length = dw / 2 * (sin(α_max) / (1 - cos(α_max)))
    radius = dw / 4 / (1 - cos(α_max))
    return rounded_transition_width(s, w0, w1, taper_length, radius)
end

function rounded_transition_width(s, w0, w1, taper_length, radius)
    # x from midpoint
    x = s - taper_length / 2
    if x < zero(x) || (iszero(x) && w1 > w0)
        return w0 - sign(w0 - w1) * 2 * (radius - sqrt(radius^2 - s^2))
    else
        return w1 + sign(w0 - w1) * 2 * (radius - sqrt(radius^2 - (taper_length - s)^2))
    end
end

"""
    round_trace_transitions!(pa::Path; α_max=60°, radius=nothing)

Replace linear `TaperTrace`s or discontinuous transitions between `SimpleTrace` with
rounded (circular-arc) tapers.

For rounding of discontinuous transitions between adjacent `SimpleTrace` styles,
`α_max` controls the sharpness of the taper (maximum angle between taper edge and the path direction),
so that `α_max=90°` would be the sharpest possible taper as the trace edge becomes
perpendicular to the path at the center of the taper. 90° tapers cause numerical issues in some
functions, so `α_max` strictly less than `90°` is required.

If provided, `radius` overrides `α_max` and sets the arc radius used for the taper.
`radius > abs(width_start - width_end)/4` is required to avoid 90° tapers.

`TaperTrace` rounding ignores both `α_max` and `radius`. Instead, it uses the largest
radius possible given the taper length. Taper length must be strictly greater than
`abs(width_start - width_end)/2` to avoid 90° tapers.
"""
function round_trace_transitions!(pa::Path; α_max=60°, radius=nothing)
    if α_max >= 90° || α_max <= 0°
        error("Maximum taper angle must be `0° < α_max < 90°`")
    end

    handle_generic_tapers!(pa)

    # Replace linear tapers with rounded tapers
    for node in pa
        if node.sty isa Paths.TaperTrace
            sty0 = Trace(node.sty.width_start)
            sty1 = Trace(node.sty.width_end)
            dw = abs(sty0.width - sty1.width)
            iszero(dw) && continue
            taper_length = pathlength(node.seg)
            taper_α_max = 2 * acot(2 * taper_length / dw)
            if taper_α_max >= 90°
                @warn "Skipping taper rounding: Taper length $taper_length must be greater than `abs(width_start - width_end) = $dw`"
                continue
            else
                node.sty = rounded_transition(sty0, sty1; α_max=taper_α_max)
            end
        end
    end

    # Splice rounded tapers between discrete jumps
    simple_trace = [n.sty isa SimpleTrace for n in pa]
    idx_increment = 0 # For updating index as we splice in additional taper segments
    for (orig_idx_0, orig_idx_1) in zip(1:(length(pa) - 1), 2:length(pa))
        if (simple_trace[orig_idx_0] && simple_trace[orig_idx_1])
            idx_0 = orig_idx_0 + idx_increment
            idx_1 = orig_idx_1 + idx_increment
            sty0 = pa[idx_0].sty
            sty1 = pa[idx_1].sty
            dw = abs(sty0.width - sty1.width) # Change in trace width
            iszero(dw) && continue
            # Rounded style based on α_max
            dl = dw / 4 * (sin(α_max) / (1 - cos(α_max))) # Half taper length assuming two circular arcs with max taper angle α_max
            rndsty = rounded_transition(sty0, sty1; α_max)
            if !isnothing(radius) # Explicitly specified radius overrides α_max
                if radius <= dw / 4 # Radius is too sharp
                    @warn "Skipping transition rounding: Radius $radius must be greater than `abs(width_start - width_end)/4 = $dw`"
                    continue
                else
                    α = acos(1 - dw / (4 * radius))
                    dl = dw / 4 * (sin(α) / (1 - cos(α)))
                    rndsty = rounded_transition(sty0, sty1; α_max=α)
                end
            end
            # Split off dl from each segment at the interface, then apply rounded style
            split0 = split(pa[idx_0], pathlength(pa[idx_0].seg) - dl)
            split1 = split(pa[idx_1], dl)
            new_n0 = split0[1]
            new_n1 = split1[2]
            transition = Path([split0[2], split1[1]])
            transition[1].sty = rndsty # Assign directly, nothing to reconcile
            transition[2].sty = pin(rndsty; start=dl)
            # Splice back in and increment the number of nodes
            splice!(pa, idx_0:idx_1, Path([new_n0, transition[1], transition[2], new_n1]))
            idx_increment += 2
        end
    end
end
