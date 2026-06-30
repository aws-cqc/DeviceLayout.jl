function to_polygons(segment::Paths.Straight{T}, s::Paths.SimpleTrace; kwargs...) where {T}
    dir = direction(segment, zero(T))
    dp, dm = dir + 90.0°, dir - 90.0°

    ext = Paths.extent(s, zero(T))
    tangents = StaticArrays.@SVector [
        ext * Point(cos(dm), sin(dm)),
        ext * Point(cos(dm), sin(dm)),
        ext * Point(cos(dp), sin(dp)),
        ext * Point(cos(dp), sin(dp))
    ]

    a, b = segment(zero(T)), segment(pathlength(segment))
    origins = StaticArrays.@SVector [a, b, b, a]

    return Polygon(origins .+ tangents)
end
