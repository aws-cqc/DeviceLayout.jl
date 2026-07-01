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

# Generic fallback method. Route direct segment/style rendering through the same Node path
# used by normal Path rendering.
to_polygons(seg::Paths.Segment{T}, s::Paths.Style; kwargs...) where {T} =
    to_polygons(Paths.Node(seg, s); kwargs...)

function _to_polygons_via_bspline(
    seg::Paths.Segment{T},
    s;
    atol=DeviceLayout.onenanometer(T),
    rtol=nothing,
    kwargs...
) where {T}
    bsp = Paths.bspline_approximation(seg; atol, rtol)
    return to_polygons(bsp, s; atol, rtol, kwargs...)
end

function to_polygons(n::Paths.Node; kwargs...)
    result = pathtopolys(n; kwargs...)
    return _pathtopolys_to_polygons(result; kwargs...)
end

# Convert pathtopolys output to Polygon(s) for GDS rendering.
# pathtopolys returns Polygon (linear), CurvilinearPolygon (curved),
# or vectors of either (CPW styles produce two polygons).
# Uses runtime dispatch rather than type signatures because CurvilinearPolygon
# is defined after this file in the include order.
_pathtopolys_to_polygons(p::Polygon; kwargs...) = p
_pathtopolys_to_polygons(p::Vector{<:Polygon}; kwargs...) = p
_pathtopolys_to_polygons(entity::GeometryEntity; kwargs...) = to_polygons(entity; kwargs...)
function _pathtopolys_to_polygons(v::Vector{<:GeometryEntity{T}}; kwargs...) where {T}
    polys = Polygon{T}[]
    for item in v
        r = _pathtopolys_to_polygons(item; kwargs...)
        r isa Polygon ? push!(polys, r) : append!(polys, r)
    end
    return polys
end
function _pathtopolys_to_polygons(v::Vector; kwargs...)
    polys = Polygon[]
    for item in v
        r = _pathtopolys_to_polygons(item; kwargs...)
        r isa Polygon ? push!(polys, r) : append!(polys, r)
    end
    return polys
end

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
