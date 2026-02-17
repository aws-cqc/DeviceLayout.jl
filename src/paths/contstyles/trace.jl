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

# Quintic Hermite (C²) S-curve width transition
function rounded_transition_width(s, w0, w1, L)
    t = s / L
    return w0 + (w1 - w0) * t^3 * (6t^2 - 15t + 10)
end

# Constructor for rounded transition as GeneralTrace
function rounded_transition(sty0::SimpleTrace, sty1::SimpleTrace, L)
    return Trace(s -> rounded_transition_width(s, sty0.width, sty1.width, L))
end

"""
    resolve_transition_length(dw; α_max, radius=nothing)

Compute taper length for a rounded trace transition with width change `dw`, given
constraints on max taper angle `α_max` and/or minimum edge radius of curvature `radius`.

When both are specified, uses the more conservative (longer taper) of the two.
The `radius` formula uses a small-angle approximation that is conservative (overestimates
the required taper length), so the actual minimum edge radius always meets the constraint.
"""
function resolve_transition_length(dw; α_max, radius=nothing)
    L_from_α = 15 * dw / (16 * tan(α_max))
    isnothing(radius) && return L_from_α
    L_from_r = sqrt(5 * dw * radius / sqrt(3))
    return max(L_from_α, L_from_r)
end

"""
    round_trace_transitions!(pa::Path; α_max=60°, radius=nothing, side=:before)

Replace linear `TaperTrace`s and discontinuous transitions between `SimpleTrace` segments
with smooth (quintic Hermite, C²) tapers.

For discontinuous transitions between adjacent `SimpleTrace` styles:

  - `α_max` controls the maximum angle between the taper edge and the path direction.
    `0° < α_max < 90°` is required.
  - `radius` sets a lower bound on the edge radius of curvature (e.g. for fab constraints).
    When both `α_max` and `radius` are provided, the more conservative constraint wins.
  - `side` controls which segment donates space for the taper: `:before` (default) takes
    from the preceding segment, `:after` takes from the following segment.

`TaperTrace` rounding uses the existing taper length and is unaffected by `α_max`, `radius`,
and `side`. If a segment is too short for the computed taper length, the transition is
skipped with a warning.
"""
function round_trace_transitions!(pa::Path; α_max=60°, radius=nothing, side=:before)
    if α_max >= 90° || α_max <= 0°
        error("Maximum taper angle must be `0° < α_max < 90°`")
    end
    handle_generic_tapers!(pa)
    round_existing_tapers!(pa)
    return insert_rounded_transitions!(pa; α_max, radius, side)
end

function round_existing_tapers!(pa::Path)
    for node in pa
        node.sty isa Paths.TaperTrace || continue
        dw = abs(node.sty.width_start - node.sty.width_end)
        iszero(dw) && continue
        L = pathlength(node.seg)
        sty0 = Trace(node.sty.width_start)
        sty1 = Trace(node.sty.width_end)
        node.sty = rounded_transition(sty0, sty1, L)
    end
end

function insert_rounded_transitions!(pa::Path; α_max, radius, side)
    boundaries = Tuple{Int, Int}[]
    for i = 1:(length(pa) - 1)
        if pa[i].sty isa SimpleTrace && pa[i + 1].sty isa SimpleTrace
            push!(boundaries, (i, i + 1))
        end
    end

    warned = false
    for (idx_0, idx_1) in reverse(boundaries)
        sty0 = pa[idx_0].sty::SimpleTrace
        sty1 = pa[idx_1].sty::SimpleTrace
        dw = abs(sty0.width - sty1.width)
        iszero(dw) && continue

        L = resolve_transition_length(dw; α_max, radius)
        donor_idx = side === :before ? idx_0 : idx_1
        avail = pathlength(pa[donor_idx].seg)
        if L >= avail
            if !warned
                @warn """Rounded trace transition between widths $(sty0.width) and \
                $(sty1.width) at $(p0(pa[idx_1].seg)) on path \"$(pa.name)\" requires \
                taper length $L, but the $(side === :before ? "preceding" : "following") \
                segment has length $avail. Skipping this transition. \
                Further warnings on this path will be suppressed."""
                warned = true
            end
            continue
        end

        rndsty = rounded_transition(sty0, sty1, L)
        if side === :before
            parts = split(pa[donor_idx], avail - L)
            parts[2].sty = rndsty
        else
            parts = split(pa[donor_idx], L)
            parts[1].sty = rndsty
        end
        splice!(pa, donor_idx:donor_idx, parts)
    end
end
