######## Design velocities: geometry preparation
#
# The boundary loops of the entities that a layout renders, with their planes and
# extrusions, in STP_UNIT.

import Clipper
import DeviceLayout: clip
import DeviceLayout.Polygons: _all_contours

struct _LayoutEntity
    index::Int # position in the flattened coordinate system
    meta::Meta
    z::Float64
    thickness::Float64
    loops::Vector{Matrix{Float64}} # 2 × n vertices of each boundary loop, in STP_UNIT
    # Whether the entity has curves other than lines and arcs. These, such as B-splines, are
    # discretized adaptively, so their vertices follow points of the curve only when it
    # moves rigidly.
    adaptive::Bool
end

function _layout_entities(cs, map_meta, zmap, thickness; kwargs...)
    cs isa AbstractCoordinateSystem || throw(
        ArgumentError(
            "the layout function must return an AbstractCoordinateSystem, got $(typeof(cs))"
        )
    )
    flat = flatten(cs)
    entities = _LayoutEntity[]
    for (i, (e, m)) in enumerate(zip(elements(flat), element_metadata(flat)))
        isnothing(map_meta(m)) && continue
        loops = _boundary_loops(e; kwargs...)
        isempty(loops) && continue
        push!(
            entities,
            _LayoutEntity(
                i,
                m,
                _stp_float(zmap(m)),
                _stp_float(thickness(m)),
                loops,
                _has_adaptive_curves(e; kwargs...)
            )
        )
    end
    return entities
end

# The boundary loops of an entity as rendered to a solid model: the contours of a clipped
# polygon (not the keyholed polygons of `to_polygons`), or the vertex loops of its polygons.
_boundary_loops(e::ClippedPolygon; kwargs...) = _contour_loops(e)
_boundary_loops(
    e::StyledEntity{T, <:ClippedPolygon, <:Union{Plain, MeshSized}};
    kwargs...
) where {T} = _contour_loops(e.ent)
function _boundary_loops(e::GeometryEntity; kwargs...)
    polys = to_polygons(e; kwargs...)
    loops = Matrix{Float64}[]
    for p in (polys isa AbstractArray ? polys : [polys])
        if p isa ClippedPolygon
            append!(loops, _contour_loops(p))
        elseif _is_self_touching(points(p))
            # A keyholed polygon: its cuts are not edges of the rendered geometry.
            append!(
                loops,
                _contour_loops(
                    clip(
                        Clipper.ClipTypeUnion,
                        [p],
                        typeof(p)[];
                        pfs=Clipper.PolyFillTypeNonZero,
                        pfc=Clipper.PolyFillTypeNonZero
                    )
                )
            )
        else
            loop = _stp_loop(points(p))
            size(loop, 2) >= 3 && push!(loops, loop)
        end
    end
    return loops
end

# Whether `e` has curves that `to_polygons` discretizes adaptively: all but lines and arcs.
_has_adaptive_curves(e; kwargs...) = false
_has_adaptive_curves(e::StyledEntity; kwargs...) = _has_adaptive_curves(e.ent; kwargs...)
_has_adaptive_curves(e::AbstractVector; kwargs...) = any(_has_adaptive_curves, e)
# A path node's edges are the curves of `pathtopolys`: the offsets of a turn, for example, are
# arcs for a constant width but not for a taper.
_has_adaptive_curves(e::Paths.Node; kwargs...) =
    _has_adaptive_curves(DeviceLayout.pathtopolys(e))
_has_adaptive_curves(e::CurvilinearPolygon; kwargs...) = any(_is_adaptive, e.curves)
_has_adaptive_curves(e::CurvilinearRegion; kwargs...) =
    _has_adaptive_curves(e.exterior) || any(_has_adaptive_curves, e.holes)
_has_adaptive_curves(e::Ellipse; Δθ=nothing, kwargs...) =
    isnothing(Δθ) && !DeviceLayout.Polygons.iscircle(e)
_is_adaptive(::Paths.Segment) = true
_is_adaptive(::Paths.Straight) = false
_is_adaptive(::Paths.Turn) = false
_is_adaptive(s::Paths.ConstantOffset) = _is_adaptive(s.seg)
_is_adaptive(s::Paths.CompoundSegment) = any(_is_adaptive, s.segments)

_contour_loops(p::ClippedPolygon) =
    [l for l in (_stp_loop(c) for c in _all_contours(p.tree)) if size(l, 2) >= 3]

function _is_self_touching(pts)
    seen = Set{eltype(pts)}()
    for q in pts
        q in seen && return true
        push!(seen, q)
    end
    return false
end

# Vertices in STP_UNIT, without consecutive duplicates or a repeated first vertex.
function _stp_loop(pts)
    xs, ys = Float64[], Float64[]
    for q in pts
        x, y = _stp_float(getx(q)), _stp_float(gety(q))
        !isempty(xs) && xs[end] == x && ys[end] == y && continue
        push!(xs, x)
        push!(ys, y)
    end
    if length(xs) > 1 && xs[1] == xs[end] && ys[1] == ys[end]
        pop!(xs)
        pop!(ys)
    end
    return permutedims(hcat(xs, ys))
end
