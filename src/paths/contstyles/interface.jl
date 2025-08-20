"""
    extent(s::Style, t)

For a style `s`, returns a distance tangential to the path specifying the lateral extent
of the polygons rendered. The extent is measured from the center of the path to the edge
of the polygon (half the total width along the path). The extent is evaluated at path length
`t` from the start of the associated segment.
"""
function extent end

"""
    width(s::Style, t)

For a style `s` and parametric argument `t`, returns the width of paths rendered.
"""
function width end

"""
    translate(s::ContinuousStyle, x)

Creates a style `s′` such that all properties `f(s′, t) == f(s, t+x)`. Basically, advance
the style forward by path length `x`.
"""
function translate end

"""
    pin(s::ContinuousStyle; start=nothing, stop=nothing)

Imagine having a styled segment of length `L` split into two, the first segment having
length `l` and the second having length `L-l`. In all but the simplest styles, the styles
need to be modified in order to maintain the rendered appearances. A style appropriate for
the segment of length `l` (`L-l`) is given by `pin(s; stop=l)` (`pin(s; start=l)`).
"""
function pin(s::ContinuousStyle{false}; start=nothing, stop=nothing)
    if !isnothing(start)
        return translate(s, start)
    end
    return s
end
