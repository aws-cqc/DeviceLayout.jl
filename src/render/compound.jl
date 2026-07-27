# Shared compound style-pinning loop. Callers provide the per-subsegment renderer.
function _compound_pin_render(f::Paths.CompoundSegment{T}, s::Paths.Style, leaf) where {T}
    starts = cumsum([zero(T); pathlength.(f.segments[1:(end - 1)])])
    stops = starts .+ pathlength.(f.segments)

    pieces = map(f.segments, starts, stops) do se, l0, l
        # Zero-length subsegments (e.g. zero-angle turns) carry no geometry; skip them
        # so their coincident endpoints don't trip the closed-segment check (issue #269).
        iszero(pathlength(se)) && return Polygon{T}[]
        return vcat(leaf(se, Paths.pin(s; start=l0, stop=l)))
    end

    return reduce(vcat, pieces)
end
