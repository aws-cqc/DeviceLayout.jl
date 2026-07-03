function to_polygons(seg::Paths.Segment{T}, sty::Paths.PeriodicStyle; kwargs...) where {T}
    subsegs, substys = Paths.resolve_periodic(seg, sty)

    return reduce(
        vcat,
        (to_polygons(Paths.Node(se, st); kwargs...) for (se, st) in zip(subsegs, substys)),
        init=Polygon{T}[]
    )
end

function to_polygons(
    seg::DeviceLayout.Paths.CompoundSegment{T},
    sty::DeviceLayout.Paths.PeriodicStyle;
    kwargs...
) where {T}
    subsegs, substys = Paths.resolve_periodic(seg, sty)

    return reduce(
        vcat,
        (to_polygons(Paths.Node(se, st); kwargs...) for (se, st) in zip(subsegs, substys)),
        init=Polygon{T}[]
    )
end
