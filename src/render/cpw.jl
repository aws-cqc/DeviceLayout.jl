# Return the four corners of a straight CPW cross section in the order
# right outer, right inner, left inner, left outer.
function _cpw_corners(f::Paths.Straight, s, t)
    center = f(t)
    normal = Point(-sin(Paths.α0(f)), cos(Paths.α0(f)))
    inner = Paths.trace(s) / 2
    outer = inner + Paths.gap(s)
    return [
        center - outer * normal,
        center - inner * normal,
        center + inner * normal,
        center + outer * normal
    ]
end

function to_polygons(f::Paths.Straight{T}, s::Paths.SimpleCPW; kwargs...) where {T}
    c0 = _cpw_corners(f, s, zero(T))
    c1 = _cpw_corners(f, s, pathlength(f))

    return [Polygon([c0[3], c1[3], c1[4], c0[4]]), Polygon([c0[1], c1[1], c1[2], c0[2]])]
end
