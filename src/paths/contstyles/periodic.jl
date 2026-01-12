"""
    struct PeriodicStyle{T <: Coordinate} <: AbstractCompoundStyle

Continuous style repeating a series of underlying styles.

When extending a path that ends in a `PeriodicStyle` without explicitly providing a new style,
the periodicity will be resumed from where it ended on the final segment.

    PeriodicStyle(styles::Vector{<:Style}, lengths::Vector{T}, l0=zero(T))

Style for `Path` each style in `style` for the corresponding length in `lengths`, repeating
after every `sum(lengths)`. Periodicity starts at `l0`.

    PeriodicStyle(styles::Vector{<:Style}; period, weights=ones(length(styles)))

Convenience constructor using a `period` keyword with `weights` rather than explicit `lengths`,
such that the length for each style in a period is given by
`lengths = period * weights/sum(weights)`.

    PeriodicStyle(pa::Path)

Convenience constructor for a periodic style cycling between the styles in `pa`, each for
the length of the corresponding segment in `pa`.
"""
struct PeriodicStyle{T <: Coordinate} <: AbstractCompoundStyle
    styles::Vector{Style}
    lengths::Vector{T}
    l0::T
end
Base.copy(s::PeriodicStyle{T}) where {T} =
    PeriodicStyle{T}(copy(s.styles), copy(s.lengths), s.l0)
summary(s::PeriodicStyle) = "Periodic style with $(length(s.styles)) substyles"

function PeriodicStyle(styles, lengths::Vector{T}, l0=zero(T)) where {T}
    return PeriodicStyle{float(T)}(styles, lengths, l0)
end

function PeriodicStyle(styles; period, weights=ones(length(styles)), l0=zero(period))
    return PeriodicStyle(styles, period * uconvert.(NoUnits, weights ./ sum(weights)), l0)
end

function PeriodicStyle(sty::CompoundStyle)
    return PeriodicStyle(sty.styles, diff(sty.grid))
end

function PeriodicStyle(pa::Path)
    pacopy = deepcopy(pa)
    handle_generic_tapers!(pacopy)
    return PeriodicStyle(simplify(pacopy).sty)
end

# Return style and length into style
function (s::PeriodicStyle)(t)
    ls = s.lengths
    dt = (t + s.l0) % sum(ls)
    l0 = zero(t)
    l1 = zero(t)
    for i = 1:length(s.styles)
        l1 = l1 + ls[i]
        dt < l1 && return (s.styles[i], dt - l0)
        l0 = l1
    end
    # Should be unreachable
    return s.styles[end], dt - l0
end

function resolve_periodic(seg::Paths.Segment{T}, sty::PeriodicStyle) where {T}
    # Accumulate subsegments and substyles
    subsegs = Segment{T}[]
    substys = Style[]
    # remaining segment to render (will be updated iteratively)
    remainder = seg
    remaining_length = pathlength(seg)
    # special handling for first segment in case of nonzero sty.l0
    # Get starting style and remaining length based on sty.l0
    ls = cumsum(sty.lengths) .- (sty.l0 % sum(sty.lengths))
    next_style_idx = findfirst(x -> x > zero(x), ls)
    next_style_length = ls[next_style_idx]
    # distance into the style that the style starts
    l_into_next_style = sty.lengths[next_style_idx] - next_style_length
    # add subsegments iteratively
    while next_style_length < remaining_length
        # Get substyle
        substy = sty.styles[next_style_idx]
        # handle nonzero sty.l0
        if !iszero(l_into_next_style)
            substy = pin(substy, start=l_into_next_style)
            l_into_next_style = zero(l_into_next_style)
        end
        # Get subsegment
        subseg, remainder = split(remainder, next_style_length)
        # Add to list
        push!(subsegs, subseg)
        push!(substys, substy)
        # Update for next iteration
        remaining_length = remaining_length - next_style_length
        next_style_idx = mod1(next_style_idx + 1, length(sty.styles))
        next_style_length = sty.lengths[next_style_idx]
    end

    # Add final section
    if remaining_length > zero(remaining_length)
        # Handle nonzero l_into_next_cycle (e.g., started midcycle and is too short for one segment)
        start = iszero(l_into_next_style) ? nothing : l_into_next_style
        substy = sty.styles[next_style_idx]
        if remaining_length < next_style_length
            substy = pin(substy, start=start, stop=l_into_next_style + remaining_length)
        else
            substy = pin(substy, start=start)
        end
        push!(subsegs, remainder)
        push!(substys, substy)
    end
    return subsegs, substys
end

function _refs(seg::Paths.Segment{T}, sty::PeriodicStyle) where {T}
    return vcat(_refs.(resolve_periodic(seg, sty)...)...)
end

function nextstyle(p::Path, sty::PeriodicStyle{T}) where {T}
    if sty !== p[end].sty # there is a virtual or non-continuous style, reset periodicity
        @show sty
        return PeriodicStyle(sty.styles, sty.lengths, zero(T))
    end
    # Add last segment length to l0 so periodicity continues from there
    return PeriodicStyle(sty.styles, sty.lengths, sty.l0 + pathlength(p[end].seg))
end

function translate(sty::PeriodicStyle, x)
    return PeriodicStyle(sty.styles, sty.lengths, sty.l0 + x)
end
