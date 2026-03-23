render!(c::CoordinateSystem, p::Path, meta::Meta=p.metadata) = place!(c, p, meta)

function render!(c::Cell, p::Path, meta::Meta=p.metadata; kwargs...)
    if meta === UNDEF_META
        p.metadata = GDSMeta()  # Backward compat: default to (0,0) when unset
    else
        p.metadata = meta
    end
    return _render!(c, p; kwargs...)
end

# Disambiguate with render!(::Cell{S}, ::Any, ::Union{GDSMeta,Vector{GDSMeta}}) in render.jl
function render!(c::Cell{S}, p::Path, meta::GDSMeta; kwargs...) where {S}
    p.metadata = meta
    return _render!(c, p; kwargs...)
end

# Generic fallback method
# If there's no specific method for this segment type, use the fallback method for the style.
to_polygons(seg::Paths.Segment{T}, s::Paths.Style; kwargs...) where {T} =
    to_polygons(seg, pathlength(seg), s; kwargs...)

to_polygons(n::Paths.Node; kwargs...) = to_polygons(n.seg, n.sty; kwargs...)

# NoRender and friends
to_polygons(seg::Paths.Segment{T}, s::Paths.NoRenderContinuous; kwargs...) where {T} =
    Polygon{T}[]
to_polygons(seg::Paths.Segment{T}, s::Paths.NoRenderDiscrete; kwargs...) where {T} =
    Polygon{T}[]
to_polygons(seg::Paths.Segment{T}, s::Paths.SimpleNoRender; kwargs...) where {T} =
    Polygon{T}[]
to_polygons(seg::Paths.Segment{T}, s::Paths.NoRender; kwargs...) where {T} = Polygon{T}[]

# Disambiguate
to_polygons(
    seg::Paths.CompoundSegment{T},
    s::Paths.NoRenderContinuous;
    kwargs...
) where {T} = Polygon{T}[]
to_polygons(seg::Paths.CompoundSegment{T}, s::Paths.NoRenderDiscrete; kwargs...) where {T} =
    Polygon{T}[]
to_polygons(seg::Paths.CompoundSegment{T}, s::Paths.SimpleNoRender; kwargs...) where {T} =
    Polygon{T}[]
to_polygons(seg::Paths.CompoundSegment{T}, s::Paths.NoRender; kwargs...) where {T} =
    Polygon{T}[]
