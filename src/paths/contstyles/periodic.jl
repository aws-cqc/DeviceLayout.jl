"""
    struct PeriodicStyle{T <: Coordinate} <: AbstractCompoundStyle

Continuous style cycling through a series of underlying styles, each for a fixed length.

If a path has two consecutive segments with the same periodic style, then
the second will continue the cycle from where the first ended.

    PeriodicStyle(styles::Vector{<:Style}, lengths::Vector{T}, l0=zero(T))

Style cycling through each style in `style` for the corresponding length in `lengths`, repeating
after every `sum(lengths)`. Periodicity starts at `l0`.

    PeriodicStyle(styles::Vector{<:Style}; period::T, weights=ones(length(styles)), l0=zero(T))

Convenience constructor using a `period` keyword with `weights` rather than explicit `lengths`,
such that the length for each style in a period is given by `lengths = period * weights/sum(weights)`.

    PeriodicStyle(pa::Path{T}; l0=zero(T))

Convenience constructor for a periodic style cycling between the styles in `pa`, each for
the length of the corresponding segment in `pa`.
"""
struct PeriodicStyle{T <: Coordinate} <: AbstractCompoundStyle
    styles::Vector{Style}
    lengths::Vector{T}
    l0::T
    function PeriodicStyle{T}(styles, lengths, l0) where {T}
        while any(isa.(styles, CompoundStyle))
            # Get rid of Compound styles to simplify decoration handling
            idx = findfirst(x -> isa(x, CompoundStyle), styles)
            splice!(lengths, idx, diff(styles[idx].grid))
            splice!(styles, idx, styles[idx].styles)
        end
        styles .= _withlength!.(styles, lengths)
        return new{T}(styles, lengths, l0)
    end
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

function PeriodicStyle(sty::CompoundStyle{T}; l0=zero(T)) where {T}
    return PeriodicStyle(sty.styles, diff(sty.grid), l0)
end

function PeriodicStyle(pa::Path{T}; l0=zero(T)) where {T}
    pacopy = deepcopy(pa)
    handle_generic_tapers!(pacopy)
    return PeriodicStyle(simplify(pacopy).sty; l0)
end

same_cycle(sty0::PeriodicStyle, sty1::Style) = false
function same_cycle(sty0::PeriodicStyle, sty1::PeriodicStyle)
    return all(sty0.styles .== sty1.styles) && all(sty0.lengths .== sty1.lengths)
end

# AbstractCompoundStyle interface: Return style and length into style
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
    # Unreachable
    return s.styles[end], dt - l0
end

# User may create a periodic path that actually has a uniform cross-section
# In particular, users may have periodic decorations on a uniform style
# Detect this so that we can avoid splitting segments
_isuniform(
    sty::Union{SimpleCPW, SimpleTrace, SimpleStrands, NoRender, NoRenderContinuous}
) = true
_isuniform(sty::Paths.DecoratedStyle) = _isuniform(sty.s)
_isuniform(sty::Paths.OverlayStyle) = (_isuniform(sty.s) && all(_isuniform.(sty.overlay)))
_isuniform(sty::Paths.PeriodicStyle) =
    (length(sty.styles) == 1 && _isuniform(only(sty.styles)))
_isuniform(::Paths.Style) = false

function resolve_periodic(seg::Paths.Segment{T}, sty::PeriodicStyle) where {T}
    if _isuniform(sty)
        return [seg], [only(sty.styles)]
    end
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

function _expand_periodic_decorations(seg::Paths.Segment{T}, sty) where {T}
    subts = T[]
    subdirs = Int[]
    subrefs = GeometryReference{T}[]

    # Get decorations within a period, starting from the beginning of a period
    l0 = zero(T)
    for (l, substy) in zip(sty.lengths, sty.styles)
        if substy isa DecoratedStyle
            append!(subts, substy.ts .+ l0)
            append!(subdirs, substy.dirs)
            append!(subrefs, substy.refs)
        end
        l0 += l
    end
    # Repeat for as many periods as necessary, including partial initial/final periods
    period = sum(sty.lengths)
    n_periods = Int(round((pathlength(seg) + sty.l0) / period, RoundUp))
    ts = [t + (i - 1) * period for t in subts for i = 1:n_periods]
    dirs = repeat(subdirs, n_periods)
    refs = repeat(subrefs, n_periods)
    # Subtract off the initial l0 and take only those within the pathlength
    ts .= ts .- sty.l0
    idx = (ts .>= zero(T) .&& ts .<= pathlength(seg))
    return (@view ts[idx]), (@view dirs[idx]), (@view refs[idx])
end

function _refs(seg::Paths.Segment{T}, sty::PeriodicStyle) where {T}
    # Uses the fact that DecoratedStyle always goes outside OverlayStyle
    # And that there are no CompoundStyles within a PeriodicStyle

    # Overlay style requires breaking up into segments
    if any(isa.(sty.styles, OverlayStyle))
        return vcat(_refs.(resolve_periodic(seg, sty)...)...)
    end
    # Otherwise if there are no decorations, no need to do anything
    if !any(isa.(sty.styles, DecoratedStyle))
        return GeometryReference{T}[]
    end
    # Expand periodic references to allow calculation without splitting `seg`
    ts, dirs, refs = _expand_periodic_decorations(seg, sty)
    # Base style unwraps DecoratedStyle but doesn't use `undecorated` because that removes overlays
    without_attachments = map(sty.styles) do substy # without attachments but with overlays
        substy isa DecoratedStyle && return substy.s
        return substy
    end
    base_sty = PeriodicStyle(without_attachments, sty.lengths, sty.l0)
    return _refs(seg, DecoratedStyle{T}(base_sty, ts, dirs, refs))
end

undecorated(sty::PeriodicStyle) =
    PeriodicStyle(undecorated.(sty.styles), sty.lengths, sty.l0)

function translate(sty::PeriodicStyle, x)
    return PeriodicStyle(sty.styles, sty.lengths, sty.l0 + x)
end
