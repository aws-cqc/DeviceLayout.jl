function to_polygons(seg::Paths.Segment{T}, sty::Paths.PeriodicStyle; kwargs...) where {T}
    subsegs, substys = Paths.resolve_periodic(seg, sty)

    return reduce(vcat, to_polygons.(subsegs, undecorated.(substys); kwargs...), init=Polygon{T}[])
end
