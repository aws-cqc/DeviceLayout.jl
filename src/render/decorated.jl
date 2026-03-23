"""
    to_polygons(segment::Paths.Segment, sty::Paths.AbstractDecoratedStyle; kwargs...)

Return the polygons of a `segment` with decorated style `s`.

References are ignored.
"""
function to_polygons(segment::Paths.Segment, sty::Paths.AbstractDecoratedStyle; kwargs...)
    @warn "Ignoring attachments on path segment $segment with style $sty when converting to polygons. Did you write `render!.(cell, path, ...)` instead of `render!(cell, path, ...)`?"
    return to_polygons(segment, undecorated(sty); kwargs...)
end

function to_polygons(f, len, sty::Paths.AbstractDecoratedStyle; kwargs...)
    @warn "Ignoring attachments on path segment $f with style $sty when converting to polygons. Did you write `render!.(cell, path, ...)` instead of `render!(cell, path, ...)`?"
    return to_polygons(f, len, undecorated(sty); kwargs...)
end

# Disambiguation
function to_polygons(
    segment::Paths.CompoundSegment{T},
    sty::Paths.AbstractDecoratedStyle;
    kwargs...
) where {T}
    @warn "Ignoring attachments on path segment $segment with style $sty when converting to polygons. Did you write `render!.(cell, path, ...)` instead of `render!(cell, path, ...)`?"
    return to_polygons(segment, undecorated(sty); kwargs...)
end
