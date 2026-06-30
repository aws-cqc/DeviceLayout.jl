# Optimized rendering of straight tapered segments
function to_polygons(segment::Paths.Straight{T}, s::Paths.TaperTrace; kwargs...) where {T}
    dir = direction(segment, zero(T))
    dp, dm = dir + 90.0°, dir - 90.0°

    ext_start = Paths.extent(s, zero(T))
    ext_end = Paths.extent(s, pathlength(segment))

    tangents = StaticArrays.@SVector [
        ext_start * Point(cos(dm), sin(dm)),
        ext_end * Point(cos(dm), sin(dm)),
        ext_end * Point(cos(dp), sin(dp)),
        ext_start * Point(cos(dp), sin(dp))
    ]

    a, b = segment(zero(T)), segment(pathlength(segment))
    origins = StaticArrays.@SVector [a, b, b, a]

    return Polygon(origins .+ tangents)
end

function to_polygons(segment::Paths.Straight{T}, s::Paths.TaperCPW; kwargs...) where {T}
    dir = direction(segment, zero(T))
    dp = dir + 90.0°

    ext_start = Paths.extent(s, zero(T))
    ext_end = Paths.extent(s, pathlength(segment))
    trace_start = Paths.trace(s, zero(T))
    trace_end = Paths.trace(s, pathlength(segment))

    tangents = StaticArrays.@SVector [
        Point(cos(dp), sin(dp)),
        Point(cos(dp), sin(dp)),
        Point(cos(dp), sin(dp)),
        Point(cos(dp), sin(dp))
    ]

    extents_p =
        StaticArrays.@SVector [0.5 * trace_start, 0.5 * trace_end, ext_end, ext_start]
    extents_m =
        StaticArrays.@SVector [ext_start, ext_end, 0.5 * trace_end, 0.5 * trace_start]

    a, b = segment(zero(T)), segment(pathlength(segment))
    origins = StaticArrays.@SVector [a, b, b, a]

    return [
        Polygon(origins .+ extents_p .* tangents),
        Polygon(origins .- extents_m .* tangents)
    ]
end
