
struct PeriodicStyle{T <: Coordinate} <: ContinuousStyle{false}
    styles::Vector{Style}
    lengths::Vector{T}
    l0::T
end
Base.copy(s::PeriodicStyle{T}) where {T} = PeriodicStyle{T}(copy(s.styles), copy(s.lengths), s.l0)
summary(s::PeriodicStyle) = "Periodic style with $(length(s.styles)) substyles"

function PeriodicStyle(styles, lengths::Vector{T}; l0=zero(T)) where {T}
    return PeriodicStyle{T}(styles, lengths, l0)
end

function PeriodicStyle(styles, period; weights=weights, l0=l0)
    return PeriodicStyle(styles, period * ustrip(NoUnits, weights ./ sum(weights)), l0)
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

function nextstyle(p::Path, sty::PeriodicStyle{T}) where {T}
    if sty != p[end].sty # there is a virtual or non-continuous style, reset periodicity
        return PeriodicStyle{T}(sty.styles, sty.period, sty.weights, zero(T))
    end
    # Add last segment length to l0 so periodicity continues from there
    return PeriodicStyle{T}(sty.styles, sty.period, sty.weights, sty.l0 + pathlength(p[end].seg))
end

function translate(sty::PeriodicStyle, x)
    return PeriodicStyle(sty.styles, sty.lengths, l0=sty.l0 + x)
end

# Forward other functions like we do with CompoundStyle
for x in (:extent, :width, :trace, :gap)
    @eval function ($x)(s::PeriodicStyle, t)
        sty, teff = s(t)
        return ($x)(sty, teff)
    end
end