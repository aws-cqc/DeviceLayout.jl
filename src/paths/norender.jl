"""
    struct NoRender <: Style

Style for suppressing rendering. When asked, it will claim to have zero width.
Converts to a continuous or discrete style as needed by `straight!`, `turn!`, `corner!`,
etc.
"""
struct NoRender <: Style end
struct NoRenderDiscrete <: DiscreteStyle end
struct NoRenderContinuous <: ContinuousStyle{false} end

"""
    struct SimpleNoRender{T} <: ContinuousStyle{false}
    SimpleNoRender(width::T; virtual=false)

A style that inhibits path rendering, but pretends to have a finite width for
[`Paths.attach!`](@ref).

May be "virtual", in which case it is ignored when looking up the last style of a Path with
`laststyle` or `contstyle1`, or when extending a Path with (for example) `straight!`.
"""
struct SimpleNoRender{T} <: ContinuousStyle{false}
    width::T
    virtual::Bool
end
SimpleNoRender(x::T; virtual=false) where {T <: Coordinate} = SimpleNoRender{T}(x, virtual)
isvirtual(x::Paths.Style) = false
isvirtual(x::SimpleNoRender) = x.virtual

copy(x::NoRender) = NoRender()
copy(x::T) where {T <: NoRenderDiscrete} = T()
copy(x::T) where {T <: NoRenderContinuous} = T()
copy(x::SimpleNoRender) = SimpleNoRender(x.width, x.virtual)

@inline extent(s::NoRender, t) = zero(t)
@inline extent(s::NoRenderContinuous, t) = zero(t)
@inline extent(s::NoRenderDiscrete, t) = zero(t)
@inline extent(s::SimpleNoRender, t...) = s.width / 2
# @inline extent(s::GeneralNoRender, t...) = s.extent(t)

# The idea here is that the user should be able to specify NoRender() for either continuous
# or discrete styles, or NoRender(width) for SimpleNoRender.
convert(::Type{DiscreteStyle}, x::NoRender) = NoRenderDiscrete()
convert(::Type{ContinuousStyle}, x::NoRender) = NoRenderContinuous()
NoRender(width::Coordinate) = SimpleNoRender(float(width))

translate(s::NoRender, t) = s
translate(s::SimpleNoRender, t) = copy(s)
translate(s::NoRenderContinuous, t) = copy(s)

pin(s::NoRender; start=nothing, stop=nothing) = s

reverse(s::Union{NoRender, NoRenderDiscrete, NoRenderContinuous, SimpleNoRender}, l) = s
