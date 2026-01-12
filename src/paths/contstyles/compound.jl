abstract type AbstractCompoundStyle <: ContinuousStyle{false} end

for x in (:extent, :width, :trace, :gap)
    @eval function ($x)(s::AbstractCompoundStyle, t)
        sty, teff = s(t)
        return ($x)(sty, teff)
    end
    @eval function ($x)(s::AbstractCompoundStyle)
        # If all the xs are the same constant we can just return the constant
        uniquexs = unique(($x).(s.styles))
        if length(uniquexs) == 1 && only(uniquexs) isa Coordinate
            return only(uniquexs)
        end
        return Base.Fix1(($x), s)
    end
end

isvirtual(s::AbstractCompoundStyle) = all(isvirtual.(s.styles))
change_handedness!(sty::AbstractCompoundStyle) = change_handedness!.(sty.styles)

"""
    struct CompoundStyle{T<:FloatCoordinate} <: AbstractCompoundStyle
        styles::Vector{Style}
        grid::Vector{T}
    end

Combines styles together, typically for use with a [`CompoundSegment`](@ref).

  - `styles`: Array of styles making up the object. This is deep-copied by the outer
    constructor.
  - `grid`: An array of `t` values needed for rendering the parametric path.
"""
struct CompoundStyle{T <: FloatCoordinate} <: AbstractCompoundStyle
    styles::Vector{Style}
    grid::Vector{T}
    tag::Symbol
end
function (s::CompoundStyle)(t)
    l0 = s.grid[1]
    t < l0 && return s.styles[1], t - l0
    for i = 2:(length(s.grid) - 1)
        l1 = s.grid[i]
        (l0 <= t) && (t < l1) && return s.styles[i - 1], t - l0
        l0 = s.grid[i]
    end
    return s.styles[length(s.grid) - 1], t - l0
end
copy(s::CompoundStyle, tag=s.tag) = (typeof(s))(deepcopy(s.styles), copy(s.grid), tag)
CompoundStyle(
    seg::AbstractVector{Segment{T}},
    sty::AbstractVector,
    tag=gensym()
) where {T} = CompoundStyle(deepcopy(Vector{Style}(sty)), makegrid(seg, sty), tag)

function _style1(s::CompoundStyle, T)
    # would work in standard cases: return last(s.styles)
    # Can't simplify corners, the only behind-the-scenes source of virtual styles
    # But just in case the user is manually adding a virtual style then simplifying
    # Similarly simplifying compound or decorated nodes is risky, but just in case
    i = findlast(x -> isa(x, T) && !isvirtual(x), s.styles)
    return _style1(undecorated(s.styles[i]), T)
end

"""
    makegrid(segments::AbstractVector{T}, styles) where {T<:Segment}

Return a collection with the values of `t` to use for
rendering a `CompoundSegment` with a `CompoundStyle`.
"""
function makegrid(segments::AbstractVector{T}, styles) where {T <: Segment}
    isempty(segments) && error("Cannot use makegrid with zero segments.")
    length(segments) != length(styles) &&
        error("Must have same number of segments and styles.")

    grid = Vector{eltype(T)}(undef, length(segments) + 1)
    grid[1] = zero(eltype(T))
    v = view(grid, 2:length(grid))
    v .= pathlength.(segments)
    return cumsum!(grid, grid)
end
summary(::CompoundStyle) = "Compound style"

function translate(s::CompoundStyle, x, tag=gensym())
    s′ = copy(s, tag)
    s′.grid .-= x
    return s′
end

function pin(s::CompoundStyle; start=nothing, stop=nothing, tag=gensym())
    if start !== nothing
        return translate(s, start, tag)
    end
    return copy(s, tag)
end
