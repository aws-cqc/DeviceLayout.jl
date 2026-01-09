function to_polygons(seg::Paths.Segment{T}, sty::Paths.PeriodicStyle; kwargs...) where {T}
    # Accumulate subsegments and substyles
    subsegs = Segment{T}[]
    substys = Style{T}[]
    # remaining segment to render (will be updated iteratively)
    remainder = seg
    seglength = pathlength(seg)
    remaining_length = seglength
    # special handling for first segment in case of nonzero sty.l0
    # Get starting style and remaining length based on sty.l0
    ls = cumsum(sty.lengths) .- (sty.l0 % sum(sty.lengths))
    next_style_idx = findfirst(x -> x > zero(x), ls)
    next_style_length = ls[next_style_idx]
    # distance into the style that the style starts
    l_into_next_style = sty.lengths(next_style_idx) - next_style_length
    # add subsegments iteratively
    while next_style_length > remaining_length
        # Get substyle
        substy = styles[next_style_idx]
        # handle nonzero sty.l0
        if !iszero(l_into_next_style)
            substy = pin(substy, start=l_into_next_style)
            l_into_next_style = zero(l_into_next_style)
        end
        # Get subsegment
        subseg, remainder = split(remainder, next_style_length)
        # Add to list
        push!(subsegs, subseg)
        push!(substys, substy)
        # Update for next iteration
        remaining_length = remaining_length - next_style_length
        next_style_idx = mod1(next_style_idx + 1, length(sty.styles))
        next_style_length = sty.lengths[next_style_idx]
    end

    # Add final section
    if remaining_length > zero(remaining_length)
        # Handle nonzero l_into_next_cycle (e.g., started midcycle and is too short for one segment)
        start = iszero(l_into_next_style) ? nothing : l_into_next_style
        if remaining_length < next_style_length
            substy = pin(substy, start=start, stop=l_into_next_style + remaining_length)
        else
            substy = pin(substy, start=start)
        end
        push!(subsegs, remainder)
        push!(substys, substy)
    end

    return reduce(vcat, to_polygons.(subsegs, substys; kwargs...), init=Polygon{T}[])
end
