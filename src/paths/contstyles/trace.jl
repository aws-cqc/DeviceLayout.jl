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

function rounded_transition_width(s, w0, w1, α_max)
    dw = abs(w0 - w1)
    seglength = dw / 2 * (sin(α_max) / (1 - cos(α_max)))
    radius = dw / 4 / (1 - cos(α_max))
    # x from midpoint
    x = s - seglength / 2
    if x <= zero(x)
        return w0 - sign(w0 - w1) * 2 * (radius - sqrt(radius^2 - s^2))
    else
        return w1 + sign(w0 - w1) * 2 * (radius - sqrt(radius^2 - (seglength - s)^2))
    end
end

"""
    round_trace_transitions!(pa::Path; α_max=60°)

Inserts rounded circular-arc tapers between neighboring `SimpleTrace` segments.

`α_max` controls the sharpness of the taper, with `α_max=90°` being
the sharpest possible as the trace edge becomes perpendicular to the
path at the center of the taper. (This causes numerical issues in some
functions, so `α_max` strictly less than `90°` is recommended.)
"""
function round_trace_transitions!(pa::Path; α_max=60°)
    simple_trace = [n.sty isa SimpleTrace for n in pa]
    idx_increment = 0
    for (orig_idx_0, orig_idx_1) in zip(1:(length(pa) - 1), 2:length(pa))
        if (simple_trace[orig_idx_0] && simple_trace[orig_idx_1])
            idx_0 = orig_idx_0 + idx_increment
            idx_1 = orig_idx_1 + idx_increment
            dw = abs(pa[idx_0].sty.width - pa[idx_1].sty.width)
            dl = dw / 4 * (sin(α_max) / (1 - cos(α_max)))
            split0 = split(pa[idx_0], pathlength(pa[idx_0].seg) - dl)
            split1 = split(pa[idx_1], dl)
            new_n0 = split0[1]
            new_n1 = split1[2]
            transition = Path([split0[2], split1[1]])
            rndsty = rounded_transition(new_n0.sty, new_n1.sty; α_max)
            transition[1].sty = rndsty
            transition[2].sty = pin(rndsty; start=dl)
            splice!(pa, idx_0:idx_1, Path([new_n0, transition[1], transition[2], new_n1]))
            idx_increment += 2
        end
    end
end
