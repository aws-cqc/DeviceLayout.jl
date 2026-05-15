function to_polygons(f, len, s::Paths.CompoundStyle; kwargs...)
    if length(s.styles) != length(s.grid) - 1
        throw(
            ArgumentError(
                "Number of grid points in compound style must equal the number of styles minus one."
            )
        )
    end
    p = Polygon{typeof(len)}[]
    for (i, sty) in enumerate(s.styles)
        @inbounds x0, x1 = s.grid[i], s.grid[i + 1]
        @inbounds s.grid[i] >= len && break
        @inbounds l = ifelse(
            i == length(s.styles),
            len - s.grid[i],
            ifelse(s.grid[i + 1] > len, len - s.grid[i], s.grid[i + 1] - s.grid[i])
        )
        @inbounds ps = to_polygons(x -> f(x + s.grid[i]), l, s.styles[i]; kwargs...)
        p = vcat(p, ps)
    end
    return p
end

function to_polygons(
    seg::Paths.CompoundSegment{T},
    sty::Paths.CompoundStyle;
    kwargs...
) where {T}
    if seg.tag == sty.tag
        # Tagging mechanism: if some nodes have been simplified, but neither the segment
        # nor the style have been swapped out, we'll just render as if we never simplified.
        p = Polygon{T}[]
        for (se, st) in zip(seg.segments, sty.styles)
            p = vcat(p, to_polygons(se, st; kwargs...))
        end
        return p
    else
        # Something has been done post-simplification, so we fall back to generic rendering
        return to_polygons(seg, pathlength(seg), sty; kwargs...)
    end
end

function to_polygons(seg::Paths.CompoundSegment{T}, sty::Paths.Style; kwargs...) where {T}
    p = Polygon{T}[]
    l0 = zero(T)
    for se in seg.segments
        l = l0 + pathlength(se)
        p = vcat(p, to_polygons(se, Paths.pin(sty; start=l0, stop=l); kwargs...))
        l0 = l
    end
    return p
end
