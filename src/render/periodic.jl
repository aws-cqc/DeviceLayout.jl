function to_polygons(seg::Paths.Segment{T}, sty::Paths.PeriodicStyle; kwargs...) where {T}
    subsegs, substys = Paths.resolve_periodic(seg, sty)

    return reduce(vcat, to_polygons.(subsegs, substys; kwargs...), init=Polygon{T}[])
end

function to_polygons(
    seg::DeviceLayout.Paths.CompoundSegment{T},
    sty::DeviceLayout.Paths.PeriodicStyle;
    kwargs...
) where {T}
    subsegs, substys = Paths.resolve_periodic(seg, sty)

    return reduce(vcat, to_polygons.(subsegs, substys; kwargs...), init=Polygon{T}[])
end
