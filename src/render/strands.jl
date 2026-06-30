function to_polygons(
    segment::Paths.Straight{T},
    s::Paths.SimpleStrands;
    kwargs...
) where {T}
    dir = direction(segment, zero(T))
    dp = dir + 90.0°

    tangents = [
        Point(cos(dp), sin(dp)),
        Point(cos(dp), sin(dp)),
        Point(cos(dp), sin(dp)),
        Point(cos(dp), sin(dp))
    ]

    p = Polygon{T}[]
    for i = 0:(Paths.num(s) - 1)
        i_offset = i * (Paths.width(s) + Paths.spacing(s))
        o = Paths.offset(s) + i_offset
        ow = o + Paths.width(s)

        extents_p = [o, o, ow, ow]
        extents_m = [ow, ow, o, o]

        a, b = segment(zero(T)), segment(pathlength(segment))
        origins = [a, b, b, a]

        push!(p, Polygon(origins .+ extents_p .* tangents))
        push!(p, Polygon(origins .- extents_m .* tangents))
    end
    return p
end
