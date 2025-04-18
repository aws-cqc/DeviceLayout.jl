
"""
    struct CompoundSegment{T} <: ContinuousSegment{T}

Consider an array of segments as one contiguous segment.
Useful e.g. for applying styles, uninterrupted over segment changes.
The array of segments given to the constructor is copied and retained
by the compound segment.

Note that [`Corner`](@ref)s introduce a discontinuity in the derivative of the
path function, and are not allowed in a `CompoundSegment`.
"""
struct CompoundSegment{T} <: ContinuousSegment{T}
    segments::Vector{Segment{T}}
    tag::Symbol

    function CompoundSegment{T}(segments, tag=gensym()) where {T}
        if any(x -> isa(x, Corner), segments)
            error(
                "cannot have corners in a `CompoundSegment`. You may have ",
                "tried to simplify a path containing `Corner` objects."
            )
        else
            new{T}(deepcopy(Array(segments)), tag)
        end
    end
end
copy(s::CompoundSegment) = (typeof(s))(s.segments, s.tag)
CompoundSegment(nodes::AbstractVector{Node{T}}, tag=gensym()) where {T} =
    CompoundSegment{T}(map(segment, nodes), tag)
CompoundSegment(segments::AbstractVector{Segment{T}}, tag=gensym()) where {T} =
    CompoundSegment{T}(segments, tag)

convert(::Type{CompoundSegment{T}}, x::CompoundSegment) where {T} =
    CompoundSegment{T}(convert.(Segment{T}, x.segments), x.tag)
convert(::Type{Segment{T}}, x::CompoundSegment) where {T} = convert(CompoundSegment{T}, x)

function subsegment(s::CompoundSegment{T}, t) where {T}
    l0 = zero(T)
    for seg in s.segments
        l1 = l0 + pathlength(seg)
        t < l1 && return seg, t - l0
        l0 = l1
    end
    return last(s.segments), t - l0
end

function curvatureradius(s::CompoundSegment, t)
    return curvatureradius(subsegment(s, t)...)
end

# Parametric function over the domain [zero(T),pathlength(c)] that represents the
# compound segments.
function (s::CompoundSegment{T})(t) where {T}
    c = s.segments
    R = promote_type(typeof(t), T)
    isempty(c) && error("cannot parameterize with zero segments.")

    L = pathlength(c)
    l0 = zero(L)

    if t < l0
        g = c[1]
        g′ = ForwardDiff.derivative(g, zero(L))::Point{Float64}
        D0x, D0y = getx(g′), gety(g′)
        a0 = p0(c[1])
        x = a0 + Point(D0x * t, D0y * t)
        return x::Point{R}
    end

    for i = 1:length(c)
        seg = c[i]
        l1 = l0 + pathlength(seg)
        if t < l1
            x = (seg)(t - l0)
            return x::Point{R}
        end
        l0 = l1
    end

    h = c[end]
    h′ = ForwardDiff.derivative(h, pathlength(h))::Point{Float64}
    D1x, D1y = getx(h′), gety(h′)
    a = p1(c[end])
    x = a + Point(D1x * (t - L), D1y * (t - L))
    return x::Point{R}
end

function _split(seg::CompoundSegment{T}, x, tag1=gensym(), tag2=gensym()) where {T}
    @assert zero(x) < x < pathlength(seg)
    c = seg.segments
    isempty(c) && error("cannot split a CompoundSegment based on zero segments.")

    L = pathlength(seg)
    l0 = zero(L)

    for i = firstindex(c):lastindex(c)
        seg = c[i]
        l1 = l0 + pathlength(seg)
        if l0 <= x < l1
            if x == l0 # can't happen on the firstindex because we have an assertion earlier
                # This is a clean split between segments
                seg1 = CompoundSegment(c[firstindex(c):(i - 1)], tag1)
                seg2 = CompoundSegment(c[i:lastindex(c)], tag2)
                return seg1, seg2
            else
                s1, s2 = split(seg, x - l0)
                seg1 = CompoundSegment(push!(c[firstindex(c):(i - 1)], s1), tag1)
                seg2 = CompoundSegment(pushfirst!(c[(i + 1):lastindex(c)], s2), tag2)
                return seg1, seg2
            end
        end
        l0 = l1
    end
end

summary(s::CompoundSegment) = string(length(s.segments), " segments")
pathlength(s::CompoundSegment) = sum(pathlength, s.segments)

function setα0p0!(s::CompoundSegment, angle, p::Point)
    setα0p0!(s.segments[1], angle, p)
    for i = 2:length(s.segments)
        setα0p0!(s.segments[i], α1(s.segments[i - 1]), p1(s.segments[i - 1]))
    end
end

function _refs(segment::CompoundSegment{T}, s::CompoundStyle) where {T}
    return vcat(_refs.(segment.segments, s.styles)...)
end

function change_handedness!(seg::CompoundSegment)
    return change_handedness!.(seg.segments)
end

function direction(seg::CompoundSegment{T}, t) where {T}
    l0 = zero(T)
    t < l0 && return α0(seg.segments[1])
    for se in seg.segments
        l = l0 + pathlength(se)
        t < l && return direction(se, t - l0)
        l0 = l
    end
    return α1(seg.segments[end])
end
