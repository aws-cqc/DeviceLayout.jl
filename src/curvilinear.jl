module Curvilinear

using LinearAlgebra

import Base: convert

import CoordinateTransformations: Transformation

import DeviceLayout
import DeviceLayout:
    AbstractPolygon,
    GeometryEntity,
    GeometryEntityStyle,
    GeometryStructure,
    GeometryReference,
    Paths,
    Reflection,
    Rotation,
    ScaledIsometry,
    StyledEntity,
    Transformation,
    Translation
import DeviceLayout:
    _compound_pin_render,
    flat_elements,
    to_polygons,
    points,
    rotation,
    origin,
    mag,
    xrefl,
    transform,
    perimeter,
    isapprox_angle
import DeviceLayout: MeshSized, WithDirection, OptionalStyle, Plain, NoRender
using DeviceLayout.Paths
import DeviceLayout.Polygons: cornerindices, iscircle, StyleDict, Rounded
import DeviceLayout.Polygons.Clipper: PolyNode, contour
import Unitful: uconvert, °, Length

using ..Points
using ..Polygons
using ..Paths

export CurvilinearPolygon,
    CurvilinearRegion,
    pathtopolys,
    line_arc_cornerindices,
    round_to_curvilinearpolygon,
    rounded_corner_segment,
    rounded_corner_segment_line_arc,
    to_curvilinear,
    styled_loop
export recover_curves, difference2d_curved, intersect2d_curved, union2d_curved, xor2d_curved

"""
    struct CurvilinearPolygon{T} <: GeometryEntity{T}
        p::Vector{Point{T}}
        curves::Vector{<:Paths.Segment}
        curve_start_idx::Vector{Int}
    end

A curvilinear polygon defined by a list of coordinates and curves between them. Straight
sections are implicit, whereas any curve is specified by the start index. A `Polygon` can be
represented using a `CurvilinearPolygon` with an empty `curves` and `curve_start_idx`.

The key distinction between `CurvilinearPolygon` and `Polygon` comes in their interaction
with boolean operations. A `Polygon` can be differenced using `Clipper` (see
`difference2d`), however a `CurvilinearPolygon` cannot directly. This is because `Clipper`
will discretize the curved sections of a `CurvilinearPolygon`. This is particularly
important for representing a geometry precisely for purposes of rendering to `SolidModel`.

See `CurvilinearRegion{T} <: GeometryEntity{T}` for the means of representing a difference
operation between `CurvilinearPolygon`.
"""
struct CurvilinearPolygon{T} <: GeometryEntity{T}
    p::Vector{Point{T}}
    curves::Vector{<:Paths.Segment} # Only need to store non-line-segment curves
    curve_start_idx::Vector{Int} # And the indices at which they start
    # Backward-parameterized curves (negative start idx) are normalized in the constructor:
    # the segment is reversed and the index flipped positive.
    function CurvilinearPolygon{T}(p, c, csi) where {T} # Make sure you don't have zero-length curves
        # Normalize backward-parameterized curves: reverse segment, flip index positive.
        for i in eachindex(csi)
            if csi[i] < 0
                c[i] = reverse(c[i])
                csi[i] = -csi[i]
            end
        end
        # Don't treat duplicates in any different fashion -> view as user error
        # Some endpoint pairs may be identical; delete the duplicates
        # Maybe inefficient but least confusing to iterate to find them and then delete
        dup_idx = Int[]
        for (idx, endpoints) in enumerate(zip(p, circshift(p, -1)))
            isapprox(
                endpoints[1],
                endpoints[2];
                atol=1e-3 * DeviceLayout.onenanometer(T)
            ) && push!(dup_idx, idx)
        end
        deleteat!(p, dup_idx)
        # Some curves may be between duplicated points; delete them
        dup_curve_idx = Int[] # Again, just iterate to find them, then delete
        for (curve_idx, start_idx) in enumerate(csi)
            (start_idx in dup_idx) && push!(dup_curve_idx, curve_idx)
        end
        deleteat!(c, dup_curve_idx)
        deleteat!(csi, dup_curve_idx)
        # Update remaining curve start indices to account for lost points
        for (curve_idx, start_idx) in enumerate(csi)
            csi[curve_idx] = start_idx - count(dup_idx .< start_idx)
        end
        # Consumers (`to_polygons`, `_collect_provenance!`) walk curves with a running
        # cursor and slice `p[i:csi]`, which requires `csi` ascending. Producers such as
        # `_reverse` and reflective `transform` can emit unsorted indices when a curve
        # wraps around to the last vertex, so sort curves and indices jointly here to
        # restore the invariant for every producer.
        if length(csi) > 1
            perm = sortperm(csi)
            c = c[perm]
            csi = csi[perm]
        end
        return new{T}(p, c, csi)
    end
end
CurvilinearPolygon(points::Vector{Point{T}}, curves, curve_start_idx) where {T} =
    CurvilinearPolygon{T}(points, curves, curve_start_idx)
function CurvilinearPolygon(points::Vector{Point{T}}) where {T}
    # Straight segments are implicit
    return CurvilinearPolygon{T}(points, Paths.Segment[], Int[])
end
CurvilinearPolygon(p::Polygon{T}) where {T} = CurvilinearPolygon(points(p))
# A circle as four 90° CCW arcs meeting at the axis-aligned extreme points. Four arcs
# rather than one or two: a single 360° curve collapses in the duplicate-endpoint dedup
# above (its lone vertex pairs with itself under `circshift`), and 180° arcs hit the OCC
# semicircle split path plus the collinear-endpoint guard in `add_circle_arc`.
function CurvilinearPolygon(e::Ellipse{T}) where {T}
    iscircle(e) || throw(
        ArgumentError(
            "an Ellipse with unequal radii is not exactly representable as arcs; " *
            "only circles (see `iscircle`) convert to CurvilinearPolygon"
        )
    )
    r = e.radii[1]
    p = [
        e.center + Point(r, zero(r)),
        e.center + Point(zero(r), r),
        e.center - Point(r, zero(r)),
        e.center - Point(zero(r), r)
    ]
    curves = [Paths.Turn(90.0°, r; p0=p[i], α0=i * 90.0°) for i = 1:4]
    return CurvilinearPolygon{T}(p, curves, [1, 2, 3, 4])
end

### Conversion methods
function to_polygons(
    e::CurvilinearPolygon{T};
    atol=DeviceLayout.onenanometer(T),
    rtol=nothing,
    kwargs...
) where {T}
    i = 1
    p = Point{T}[]

    for (idx, (csi, c)) ∈ enumerate(zip(e.curve_start_idx, e.curves))
        # Add the points from current to start of curve
        append!(p, e.p[i:csi])

        # Discretize segment using tolerance-based adaptive grid.
        wrapped_i = mod1(csi + 1, length(e.p))
        pp = DeviceLayout.discretize_curve(c, atol; rtol=rtol)

        # Remove the calculated points corresponding to start and end.
        term_p = pop!(pp)
        init_p = popfirst!(pp)

        # Add interior points and bump counter.
        append!(p, pp)
        i = csi + 1

        # Ensure that the calculated start and end points match the non-calculated points.
        @assert !isapprox(init_p, term_p; atol=1e-3 * DeviceLayout.onenanometer(T)) "Curve $idx must have non-zero length!"
        @assert isapprox(term_p, e.p[wrapped_i]; atol=1e-3 * DeviceLayout.onenanometer(T)) "Curve $idx must end at point $(wrapped_i)!"
        @assert isapprox(init_p, e.p[csi]; atol=1e-3 * DeviceLayout.onenanometer(T)) "Curve $idx must start at point $(csi)!"
    end
    append!(p, e.p[i:end])

    return Polygon{T}(p)
end

function _reverse(e::CurvilinearPolygon)
    # Reversing the point list sends old index j → N + 1 - j and flips each curve's
    # traversal direction. A curve starting at old index i spans i → i + 1 (cyclic), so
    # its reversed start is the old i + 1, at new index N - i (or N when i == N). csi_rev
    # emits that as the negative index -(N - i) (-N for i == N), which the constructor
    # normalizes by reversing the segment and flipping the index positive.
    csi_rev = (i, N) -> mod1(i + 1, N) - N - 1
    return CurvilinearPolygon(
        reverse(e.p),
        reverse(e.curves),
        reverse(csi_rev.(e.curve_start_idx, length(e.p)))
    )
end

function transform(e::CurvilinearPolygon, f::Transformation)
    # If the transformation is a reflection, have to fix the winding.
    # curve_start_idx are shifted forward 1, reversed, then negated.
    # Reverse ordering of curve_start_idx and curves to ensure consecutive.
    csi_rev = (i, N) -> mod1(i + 1, N) - N - 1
    return CurvilinearPolygon(
        f.(xrefl(f) ? reverse(e.p) : e.p),
        isempty(e.curves) ? deepcopy(e.curves) :
        transform.(xrefl(f) ? reverse(e.curves) : e.curves, Ref(f)),
        xrefl(f) ? reverse(csi_rev.(e.curve_start_idx, length(e.p))) :
        copy(e.curve_start_idx)
    )
end

convert(::Type{GeometryEntity{T}}, e::CurvilinearPolygon) where {T} =
    convert(CurvilinearPolygon{T}, e)
convert(::Type{GeometryEntity{T}}, e::CurvilinearPolygon{T}) where {T} = e
convert(::Type{CurvilinearPolygon{T}}, e::CurvilinearPolygon{T}) where {T} = e
function convert(::Type{CurvilinearPolygon{T}}, e::CurvilinearPolygon{S}) where {T, S}
    return CurvilinearPolygon{T}(
        convert(Vector{Point{T}}, e.p),
        convert(Vector{Paths.Segment{T}}, e.curves),
        copy(e.curve_start_idx)
    )
end

### Utility methods -- accessing members or derived information
points(e::CurvilinearPolygon) = e.p

"""
    struct CurvilinearRegion{T} <: GeometryEntity{T}
        exterior::CurvilinearPolygon{T}
        holes::Vector{CurvilinearPolygon{T}}
    end

A curvilinear region made up of an exterior::CurvilinearPolygon{T} and optional interior
holes made up of CurvilinearPolygon{T}. These holes cannot intersect each other or the
exterior.

Holes are normalized to clockwise (negative) winding on construction, opposite the
counterclockwise exterior. This matches `ClippedPolygon` hole contours, so that `to_polygons`
can reconstitute the region with `union2d` under Clipper's positive fill rule. See issue #241.
"""
struct CurvilinearRegion{T} <: GeometryEntity{T}
    exterior::CurvilinearPolygon{T}
    holes::Vector{CurvilinearPolygon{T}}
    CurvilinearRegion{T}(ext::CurvilinearPolygon, holes=CurvilinearPolygon{T}[]) where {T} =
        new(ext, _to_hole_winding.(holes))
end

# Normalize a hole to clockwise (negative) winding, matching `ClippedPolygon` hole contours,
# so `to_polygons` subtracts it via positive-fill `union2d`. For curve-bearing holes, winding
# is read from the discretized loop because vertices alone can't determine it (a two-vertex
# loop closed by two arcs has no vertex winding at all). Clipper-derived holes already arrive
# clockwise, making this a no-op. Degenerate loops (< 3 discretized points) pass through.
function _to_hole_winding(h::CurvilinearPolygon)
    pg = isempty(h.curves) ? Polygon(h.p) : to_polygons(h)
    length(points(pg)) < 3 && return h
    return Polygons.orientation(pg) > 0 ? _reverse(h) : h
end
CurvilinearRegion(x) = CurvilinearRegion(CurvilinearPolygon(x))
CurvilinearRegion(ext::CurvilinearPolygon{T}) where {T} = CurvilinearRegion{T}(ext)
CurvilinearRegion(
    exterior::CurvilinearPolygon{T},
    holes::Vector{CurvilinearPolygon{T}}
) where {T} = CurvilinearRegion{T}(exterior, holes)
CurvilinearRegion(exterior::Vector{Point{T}}, holes::Vector{Vector{Point{T}}}) where {T} =
    CurvilinearRegion{T}(CurvilinearPolygon(exterior), CurvilinearPolygon.(holes))
CurvilinearRegion(points::Vector{Point{T}}, segments) where {T} =
    CurvilinearRegion(CurvilinearPolygon(points, segments))
CurvilinearRegion(points::Vector{Point{T}}, curves, curve_start_idx) where {T} =
    CurvilinearRegion(CurvilinearPolygon(points, curves, curve_start_idx))

# Holes carry clockwise winding (normalized in the constructor), opposite the exterior, so a
# single `union2d` over [exterior, holes...] subtracts them under Clipper's positive fill rule.
# The exterior and holes must share one input: positive fill is applied per input before the
# union, which would drop a clockwise hole passed as a separate argument as a "hole in nothing".
# Using `union2d` rather than `difference2d` keeps hole winding consistent with `ClippedPolygon`
# and is robust to styles (e.g. composed `Rounded`) that round each loop independently and
# preserve winding. See #241.
function to_polygons(e::CurvilinearRegion; kwargs...)
    isempty(e.holes) && return [to_polygons(e.exterior; kwargs...)]
    return to_polygons(
        union2d(
            vcat(to_polygons(e.exterior; kwargs...), _hole_polygon.(e.holes; kwargs...))
        )
    )
end

# Discretize a hole through its reversed (counterclockwise) traversal, then flip the point
# list back to clockwise. The marching discretizer is direction-dependent, and holes store
# their curves reversed to match the clockwise loop; the reversed walk restores each curve's
# forward parameterization, so a hole produced by curve recovery re-discretizes to the exact
# footprint its curves had when first clipped (recover → re-discretize is xor2d-empty
# against the raw clip result).
function _hole_polygon(h::CurvilinearPolygon; kwargs...)
    return Polygon(reverse(points(to_polygons(_reverse(h); kwargs...))))
end
function to_polygons(e::CurvilinearRegion, sty::Polygons.Rounded; kwargs...)
    isempty(e.holes) && return [to_polygons(e.exterior, sty; kwargs...)]
    return to_polygons(
        union2d(
            vcat(
                to_polygons(e.exterior, sty; kwargs...),
                [to_polygons(h, sty; kwargs...) for h in e.holes]
            )
        )
    )
end

function transform(e::CurvilinearRegion{T}, f::Transformation) where {T}
    return CurvilinearRegion{T}(transform(e.exterior, f), transform.(e.holes, Ref(f)))
end

convert(::Type{GeometryEntity{T}}, e::CurvilinearRegion) where {T} =
    convert(CurvilinearRegion{T}, e)
convert(::Type{GeometryEntity{T}}, e::CurvilinearRegion{T}) where {T} = e
convert(::Type{CurvilinearRegion{T}}, e::CurvilinearRegion{T}) where {T} = e
function convert(::Type{CurvilinearRegion{T}}, e::CurvilinearRegion{S}) where {T, S}
    return CurvilinearRegion{T}(
        convert(CurvilinearPolygon{T}, e.exterior),
        convert.(CurvilinearPolygon{T}, e.holes)
    )
end

points(e::CurvilinearRegion) = vcat(points(e.exterior), points.(e.holes))

### Construction from Paths

"""
    pathtopolys(f::Paths.Segment{T}, s::Paths.Style; kwargs...)

Given a path node represented with a segment and style, construct an equivalent set of
polygons. For some linear segments and styles, a set of `Polygon{T}` is sufficient, for others
such as curves then `CurvilinearRegion{T}` is necessary.

This is particularly helpful if a Path is being used within the construction of a component
rather than as part of the SchematicGraph.
"""
function pathtopolys(f::Paths.Segment{T}, s::Paths.Style; kwargs...) where {T}
    # All supported segment/style combinations have specific methods; landing here means
    # nothing can render this pair
    throw(ArgumentError("no method converting path segment $f with style $s to polygons"))
end
pathtopolys(f::Paths.Corner{T}, s::Paths.SimpleTraceCorner; kwargs...) where {T} =
    to_polygons(f, s; kwargs...)

# Offset segments must be resolved before building curvilinear polygons: corner_points and
# Paths.offset use different parameter frames. After resolving, update any length-carrying style
# and re-dispatch through Node so the linearity check sees the concrete segment type.
# TODO: the BSpline fallback in resolve_offset is an atol approximation, not exact. See #237.
function _pathtopolys_resolved_offset(
    f::Paths.OffsetSegment{T},
    s::Paths.Style;
    kwargs...
) where {T}
    # Keep render-only kwargs away from bspline_approximation inside resolve_offset.
    kw = values(kwargs)
    resolved =
        Paths.resolve_offset(f; atol=get(kw, :atol, nothing), rtol=get(kw, :rtol, nothing))
    s = Paths._withlength!(s, pathlength(resolved))
    return pathtopolys(Paths.Node(resolved, s); kwargs...)
end
pathtopolys(f::Paths.OffsetSegment{T}, s::Paths.Style; kwargs...) where {T} =
    _pathtopolys_resolved_offset(f, s; kwargs...)
pathtopolys(f::Paths.OffsetSegment{T}, s::Paths.PeriodicStyle; kwargs...) where {T} =
    _pathtopolys_resolved_offset(f, s; kwargs...)
# CompoundStyle grids are expressed in the original segment's arclength frame, which
# offset resolution does not preserve — style transitions would land in the wrong
# places. Fail loudly rather than render subtly wrong geometry.
pathtopolys(f::Paths.OffsetSegment{T}, s::Paths.CompoundStyle; kwargs...) where {T} = throw(
    ArgumentError(
        "cannot render offset segment $f with a CompoundStyle: the style grid is in " *
        "the original segment's arclength frame, which offset resolution does not preserve"
    )
)
pathtopolys(::Paths.OffsetSegment{T}, ::Paths.NoRenderContinuous; kwargs...) where {T} =
    Polygon{T}[]
pathtopolys(::Paths.OffsetSegment{T}, ::Paths.NoRenderDiscrete; kwargs...) where {T} =
    Polygon{T}[]
pathtopolys(::Paths.OffsetSegment{T}, ::Paths.SimpleNoRender; kwargs...) where {T} =
    Polygon{T}[]
pathtopolys(::Paths.OffsetSegment{T}, ::Paths.NoRender; kwargs...) where {T} = Polygon{T}[]
# DecoratedStyles: strip the decoration and delegate to the underlying style.
# Attachments are handled by render!(Cell, Path), not here. (The per-wrapper methods
# below exist for dispatch specificity; they share this body.)
function _pathtopolys_ignoring_attachments(seg, sty; kwargs...)
    @warn "Ignoring attachments on path segment $seg with style $sty when converting to polygons. Did you write `render!.(cell, path, ...)` instead of `render!(cell, path, ...)`?"
    return pathtopolys(seg, Paths.undecorated(sty); kwargs...)
end

pathtopolys(
    f::Paths.OffsetSegment{T},
    sty::Paths.AbstractDecoratedStyle;
    kwargs...
) where {T} = _pathtopolys_ignoring_attachments(f, sty; kwargs...)

# NoRender and friends — effectively the same as above but without the warning
pathtopolys(seg::Paths.Segment{T}, s::Paths.NoRenderContinuous; kwargs...) where {T} =
    Polygon{T}[]
pathtopolys(seg::Paths.Segment{T}, s::Paths.NoRenderDiscrete; kwargs...) where {T} =
    Polygon{T}[]
pathtopolys(seg::Paths.Segment{T}, s::Paths.SimpleNoRender; kwargs...) where {T} =
    Polygon{T}[]
pathtopolys(seg::Paths.Segment{T}, s::Paths.NoRender; kwargs...) where {T} = Polygon{T}[]

function pathtopolys(p::Paths.Path{T}; kwargs...) where {T}
    nodes = filter(x -> !iszero(pathlength(x)), p.nodes)
    isempty(nodes) && return CurvilinearPolygon{T}[]
    # Normalize scalar and vector node outputs into one flat result.
    return reduce(vcat, vcat.(pathtopolys.(nodes; kwargs...)))
end

# The two PeriodicStyle methods below exist for dispatch specificity (CompoundSegment
# has its own generic-Style method); they share this body.
function _pathtopolys_periodic(
    seg::Paths.Segment{T},
    sty::Paths.PeriodicStyle;
    kwargs...
) where {T}
    subsegs, substys = Paths.resolve_periodic(seg, sty)
    return reduce(
        vcat,
        (
            vcat(pathtopolys(Paths.Node(se, st); kwargs...)) for
            (se, st) in zip(subsegs, substys)
        ),
        init=GeometryEntity{T}[]
    )
end
pathtopolys(seg::Paths.Segment{T}, sty::Paths.PeriodicStyle; kwargs...) where {T} =
    _pathtopolys_periodic(seg, sty; kwargs...)
pathtopolys(seg::Paths.CompoundSegment{T}, sty::Paths.PeriodicStyle; kwargs...) where {T} =
    _pathtopolys_periodic(seg, sty; kwargs...)

function _compound_segment_slice(f::Paths.Segment{T}, start, stop) where {T}
    len = pathlength(f)
    iszero(start) && stop == len && return f

    if iszero(start)
        piece, _ = split(f, stop)
        return piece
    elseif stop == len
        _, piece = split(f, start)
        return piece
    end

    _, tail = split(f, start)
    piece, _ = split(tail, stop - start)
    return piece
end

function _compound_style_grid_render(
    f::Paths.Segment{T},
    s::Paths.CompoundStyle;
    kwargs...
) where {T}
    if length(s.styles) != length(s.grid) - 1
        throw(
            ArgumentError(
                "Number of grid points in compound style must equal the number of styles minus one."
            )
        )
    end

    len = pathlength(f)
    last_style = lastindex(s.styles)
    valid = filter(eachindex(s.styles)) do i
        start = max(s.grid[i], zero(T))
        stop = min(i == last_style ? len : s.grid[i + 1], len)
        return start < stop
    end
    isempty(valid) && return Polygon{T}[]

    pieces = map(valid) do i
        grid_start = s.grid[i]
        start = max(grid_start, zero(T))
        stop = min(i == last_style ? len : s.grid[i + 1], len)
        piece = _compound_segment_slice(f, start, stop)
        sty = Paths.pin(s.styles[i]; start=start - grid_start, stop=stop - grid_start)
        return vcat(pathtopolys(Paths.Node(piece, sty); kwargs...))
    end
    return reduce(vcat, pieces)
end

function pathtopolys(
    f::Paths.CompoundSegment{T},
    s::Paths.CompoundStyle;
    kwargs...
) where {T}
    # Same simplification tag: segment/style boundaries align.
    if f.tag == s.tag
        return vcat(
            (
                pathtopolys(Paths.Node(se, st); kwargs...) for
                (se, st) in zip(f.segments, s.styles)
            )...
        )
    end
    # Mismatched tags use the CompoundStyle grid over the whole path.
    return _compound_style_grid_render(f, s; kwargs...)
end

pathtopolys(f::Paths.CompoundSegment{T}, s::Paths.Style; kwargs...) where {T} =
    _compound_pin_render(f, s, (se, sty) -> pathtopolys(se, sty; kwargs...))
# Wrapper segments route here; concrete-style methods only accept BaseContinuousSegment.
pathtopolys(
    f::Paths.CompoundSegment{T},
    sty::Paths.AbstractDecoratedStyle;
    kwargs...
) where {T} = _pathtopolys_ignoring_attachments(f, sty; kwargs...)
pathtopolys(::Paths.CompoundSegment{T}, ::Paths.NoRender; kwargs...) where {T} =
    Polygon{T}[]
pathtopolys(::Paths.CompoundSegment{T}, ::Paths.NoRenderContinuous; kwargs...) where {T} =
    Polygon{T}[]
pathtopolys(::Paths.CompoundSegment{T}, ::Paths.NoRenderDiscrete; kwargs...) where {T} =
    Polygon{T}[]
pathtopolys(::Paths.CompoundSegment{T}, ::Paths.SimpleNoRender; kwargs...) where {T} =
    Polygon{T}[]

# 4-----3
# trace->
# 1-----2
function corner_points(seg::Paths.Segment{T}, sty::Paths.Trace, clip::Bool) where {T}
    dir0 = Paths.α0(seg)
    dir1 = Paths.α1(seg)
    dp0, dm0 = dir0 + π / 2, dir0 - π / 2
    dp1, dm1 = dir1 + π / 2, dir1 - π / 2

    ext0 = Paths.Paths.extent(sty, zero(T))
    ext1 = Paths.Paths.extent(sty, pathlength(seg))
    if !clip
        tangents = [
            ext0 * Point(cos(dm0), sin(dm0)),
            ext1 * Point(cos(dm1), sin(dm1)),
            ext1 * Point(cos(dp1), sin(dp1)),
            ext0 * Point(cos(dp0), sin(dp0))
        ]
    else
        rad0 = Paths.curvatureradius(seg, zero(T))
        rad1 = Paths.curvatureradius(seg, pathlength(seg))
        ext0m = rad0 < zero(T) ? -max(-ext0, rad0) : ext0
        ext0p = rad0 > zero(T) ? min(ext0, rad0) : ext0
        ext1m = rad1 < zero(T) ? -max(-ext1, rad1) : ext1
        ext1p = rad1 > zero(T) ? min(ext1, rad1) : ext1
        tangents = [
            ext0m * Point(cos(dm0), sin(dm0)),
            ext1m * Point(cos(dm1), sin(dm1)),
            ext1p * Point(cos(dp1), sin(dp1)),
            ext0p * Point(cos(dp0), sin(dp0))
        ]
    end
    a, b = Paths.p0(seg), Paths.p1(seg)
    origins = [a, b, b, a]
    return origins .+ tangents
end

# 8-----7
# 5-----6
# trace->
# 4-----3
# 1-----2
function corner_points(seg::Paths.Segment{T}, sty::Paths.CPW, clip::Bool) where {T}
    dir0 = Paths.α0(seg)
    dir1 = Paths.α1(seg)
    dp0, dm0 = dir0 + π / 2, dir0 - π / 2
    dp1, dm1 = dir1 + π / 2, dir1 - π / 2

    ext00 = Paths.Paths.extent(sty, zero(T))
    ext01 = Paths.Paths.extent(sty, pathlength(seg))
    ext11 = Paths.trace(sty, pathlength(seg)) / 2
    ext10 = Paths.trace(sty, zero(T)) / 2

    if !clip
        tangents = [
            ext00 * Point(cos(dm0), sin(dm0)),
            ext01 * Point(cos(dm1), sin(dm1)),
            ext11 * Point(cos(dm1), sin(dm1)),
            ext10 * Point(cos(dm0), sin(dm0)),
            ext10 * Point(cos(dp0), sin(dp0)),
            ext11 * Point(cos(dp1), sin(dp1)),
            ext01 * Point(cos(dp1), sin(dp1)),
            ext00 * Point(cos(dp0), sin(dp0))
        ]
    else
        rad0 = Paths.curvatureradius(seg, zero(T))
        rad1 = Paths.curvatureradius(seg, pathlength(seg))
        # Ambiguous if inner points are identical

        ext00m = rad0 < zero(T) ? -max(-ext00, rad0) : ext00
        ext00p = rad0 > zero(T) ? min(ext00, rad0) : ext00
        ext10m = rad0 < zero(T) ? -max(-ext10, rad0) : ext10
        ext10p = rad0 > zero(T) ? min(ext10, rad0) : ext10

        ext01m = rad1 < zero(T) ? -max(-ext01, rad1) : ext01
        ext01p = rad1 > zero(T) ? min(ext01, rad1) : ext01
        ext11m = rad1 < zero(T) ? -max(-ext11, rad1) : ext11
        ext11p = rad1 > zero(T) ? min(ext11, rad1) : ext11

        tangents = [
            ext00m * Point(cos(dm0), sin(dm0)),
            ext01m * Point(cos(dm1), sin(dm1)),
            ext11m * Point(cos(dm1), sin(dm1)),
            ext10m * Point(cos(dm0), sin(dm0)),
            ext10p * Point(cos(dp0), sin(dp0)),
            ext11p * Point(cos(dp1), sin(dp1)),
            ext01p * Point(cos(dp1), sin(dp1)),
            ext00p * Point(cos(dp0), sin(dp0))
        ]
    end

    a, b = Paths.p0(seg), Paths.p1(seg)
    origins = [a, b, b, a, a, b, b, a]
    return origins .+ tangents
end

# The "base" continuous segment types a CurvilinearPolygon can be built from directly. The
# per-style methods below dispatch on this rather than Paths.Segment so the wrapper segments
# (CompoundSegment, OffsetSegment) route to their own generic-Style methods without a dispatch
# ambiguity (which otherwise forced one disambiguation method per wrapper/style pair).
const BaseContinuousSegment{T} = Union{Paths.Straight{T}, Paths.Turn{T}, Paths.BSpline{T}}

pathtopolys(f::BaseContinuousSegment{T}, s::Paths.CompoundStyle; kwargs...) where {T} =
    _compound_style_grid_render(f, s; kwargs...)

# A Turn sweeping a full multiple of 360° has coincident endpoints, which CurvilinearPolygon
# and the `pathtopolys` degenerate-point clipping logic would not handle correctly (issue #252)
_is_full_turn(seg::Paths.Segment) = false
function _is_full_turn(seg::Paths.Turn{T}) where {T}
    # Check endpoint coincidence with same tolerance as CurvilinearPolygon constructor deduplication
    return abs(seg.α) > 270° &&
           isapprox(Paths.p0(seg), Paths.p1(seg); atol=1e-3 * DeviceLayout.onenanometer(T))
end

# Full turns split into two nodes (avoid closed-loop segments and OCC-unfriendly keyhole geometry)
function _split_full_turn(seg::Paths.Turn{T}, sty::Paths.Style; kwargs...) where {T}
    seg1, seg2, sty1, sty2 = split(seg, sty, pathlength(seg) / 2)
    return vcat(
        vcat(pathtopolys(Paths.Node(seg1, sty1); kwargs...)),
        vcat(pathtopolys(Paths.Node(seg2, sty2); kwargs...))
    )
end

# Closed segments other than full turns (e.g. a closed BSpline) are not split but fail loudly
function _assert_open_segment(seg::Paths.Segment{T}) where {T}
    if isapprox(Paths.p0(seg), Paths.p1(seg); atol=1e-3 * DeviceLayout.onenanometer(T))
        throw(
            ArgumentError(
                "cannot represent closed segment $seg as a single curvilinear polygon; " *
                "split it (e.g. with `Paths.split`) so each piece has distinct endpoints"
            )
        )
    end
end

# Traces generate one surface
# SimpleTrace can use constant offset
function pathtopolys(
    seg::BaseContinuousSegment{T},
    sty::Paths.SimpleTrace;
    kwargs...
) where {T}
    _is_full_turn(seg) && return _split_full_turn(seg, sty; kwargs...)
    pts = corner_points(seg, sty, true)
    # Check if the points are degenerate (inner edge clipped to the curve origin when
    # radius ≤ extent). Coincident segment endpoints also make these checks fire — for
    # the wrong reason — so closed segments that are not split above fail loudly.
    if isapprox(pts[1], pts[2])
        _assert_open_segment(seg)
        return CurvilinearPolygon(pts[2:end], [Paths.offset(seg, Paths.extent(sty))], [-2])
    elseif isapprox(pts[3], pts[4])
        _assert_open_segment(seg)
        return CurvilinearPolygon(pts[1:3], [Paths.offset(seg, -Paths.extent(sty))], [1])
    end
    return CurvilinearPolygon(
        pts,
        [Paths.offset(seg, -Paths.extent(sty)), Paths.offset(seg, Paths.extent(sty))],
        [1, -3]
    )
end

function pathtopolys(seg::Paths.BSpline{T}, sty::Paths.SimpleTrace; kwargs...) where {T}
    pts = corner_points(seg, sty, false)
    return CurvilinearPolygon(
        pts,
        [Paths.offset(seg, -Paths.extent(sty)), Paths.offset(seg, Paths.extent(sty))],
        [1, -3]
    )
end

function pathtopolys(seg::BaseContinuousSegment{T}, sty::Paths.Trace; kwargs...) where {T}
    _is_full_turn(seg) && return _split_full_turn(seg, sty; kwargs...)
    pts = corner_points(seg, sty, false)
    return CurvilinearPolygon(
        pts,
        [
            Paths.offset(seg, t -> -Paths.extent(sty, t)),
            Paths.offset(seg, t -> Paths.extent(sty, t))
        ],
        [1, -3]
    )
end

# CPWs generate two surfaces
function pathtopolys(
    seg::BaseContinuousSegment{T},
    sty::Paths.SimpleCPW;
    kwargs...
) where {T}
    _is_full_turn(seg) && return _split_full_turn(seg, sty; kwargs...)
    pts = corner_points(seg, sty, true)
    # As for SimpleTrace above: the degenerate-point checks below are for the
    # radius ≤ extent clip, not for closed segments.
    (isapprox(pts[1], pts[2]) || isapprox(pts[7], pts[8])) && _assert_open_segment(seg)
    return [
        isapprox(pts[1], pts[2]) ?
        CurvilinearPolygon(pts[2:4], [Paths.offset(seg, -Paths.trace(sty) / 2)], [-2]) :
        CurvilinearPolygon(
            pts[1:4],
            [
                Paths.offset(seg, -Paths.extent(sty)),
                Paths.offset(seg, -Paths.trace(sty) / 2)
            ],
            [1, -3]
        ),
        isapprox(pts[7], pts[8]) ?
        CurvilinearPolygon(pts[5:7], [Paths.offset(seg, Paths.trace(sty) / 2)], [1]) :
        CurvilinearPolygon(
            pts[5:8],
            [Paths.offset(seg, Paths.trace(sty) / 2), Paths.offset(seg, Paths.extent(sty))],
            [1, -3]
        )
    ]
end

function pathtopolys(seg::Paths.BSpline{T}, sty::Paths.SimpleCPW; kwargs...) where {T}
    pts = corner_points(seg, sty, false)
    return [
        CurvilinearPolygon(
            pts[1:4],
            [
                Paths.offset(seg, -Paths.extent(sty)),
                Paths.offset(seg, -Paths.trace(sty) / 2)
            ],
            [1, -3]
        ),
        CurvilinearPolygon(
            pts[5:8],
            [Paths.offset(seg, Paths.trace(sty) / 2), Paths.offset(seg, Paths.extent(sty))],
            [1, -3]
        )
    ]
end

function pathtopolys(seg::BaseContinuousSegment{T}, sty::Paths.CPW; kwargs...) where {T}
    _is_full_turn(seg) && return _split_full_turn(seg, sty; kwargs...)
    pts = corner_points(seg, sty, false)
    return [
        CurvilinearPolygon(
            pts[1:4],
            [
                Paths.offset(seg, t -> -Paths.extent(sty, t)),
                Paths.offset(seg, t -> -Paths.trace(sty, t) / 2)
            ],
            [1, -3]
        ),
        CurvilinearPolygon(
            pts[5:end],
            [
                Paths.offset(seg, t -> Paths.trace(sty, t) / 2),
                Paths.offset(seg, t -> Paths.extent(sty, t))
            ],
            [1, -3]
        )
    ]
end

# Strands generate 2*num polygons (plus and minus side for each strand).
# Each strand is a trace-like shape at a computed offset from center.
function pathtopolys(seg::BaseContinuousSegment{T}, sty::Paths.Strands; kwargs...) where {T}
    _is_full_turn(seg) && return _split_full_turn(seg, sty; kwargs...)
    polys = Union{CurvilinearPolygon{T}, Polygon{T}}[]
    for i = 0:(Paths.num(sty) - 1)
        # Offset to center of strand i, plus half-width for edges
        strand_inner(t) =
            Paths.offset(sty, t) + i * (Paths.width(sty, t) + Paths.spacing(sty, t))
        strand_outer(t) = strand_inner(t) + Paths.width(sty, t)
        # Plus side (left of path)
        p_pts = _strand_corners(seg, strand_inner, strand_outer)
        push!(
            polys,
            CurvilinearPolygon(
                p_pts,
                [Paths.offset(seg, strand_inner), Paths.offset(seg, strand_outer)],
                [1, -3]
            )
        )
        # Minus side (right of path)
        m_pts = _strand_corners(seg, t -> -strand_outer(t), t -> -strand_inner(t))
        push!(
            polys,
            CurvilinearPolygon(
                m_pts,
                [
                    Paths.offset(seg, t -> -strand_outer(t)),
                    Paths.offset(seg, t -> -strand_inner(t))
                ],
                [1, -3]
            )
        )
    end
    return polys
end

function _strand_corners(seg::Paths.Segment{T}, inner_offset, outer_offset) where {T}
    l = pathlength(seg)
    dir0 = Paths.α0(seg)
    dir1 = Paths.α1(seg)
    a, b = Paths.p0(seg), Paths.p1(seg)
    return [
        a + inner_offset(zero(T)) * Point(-sin(dir0), cos(dir0)),
        b + inner_offset(l) * Point(-sin(dir1), cos(dir1)),
        b + outer_offset(l) * Point(-sin(dir1), cos(dir1)),
        a + outer_offset(zero(T)) * Point(-sin(dir0), cos(dir0))
    ]
end

# Rounded terminations use the shared symbolic rounding producer so GDS and SolidModel keep the
# same fillet geometry until the final renderer decides whether to discretize.
const TerminationStyle =
    Union{Paths.TraceTermination, Paths.CPWOpenTermination, Paths.CPWShortTermination}

_termination_curvilinear(e::Polygon) = e
function _termination_curvilinear(
    e::StyledEntity{T, Polygon{T}, <:Polygons.Rounded}
) where {T}
    return round_to_curvilinearpolygon(
        e.ent,
        Polygons.radius(e.sty);
        corner_indices=cornerindices(points(e.ent), e.sty),
        min_side_len=e.sty.min_side_len,
        min_angle=e.sty.min_angle
    )
end

function pathtopolys(
    seg::BaseContinuousSegment{T},
    sty::TerminationStyle;
    kwargs...
) where {T}
    # vcat normalizes the scalar-vs-vector shape of _poly (one or two polygons).
    return _termination_curvilinear.(vcat(DeviceLayout._poly(seg, sty)))
end
function pathtopolys(
    seg::Paths.CompoundSegment{T},
    sty::TerminationStyle;
    kwargs...
) where {T}
    return _termination_curvilinear.(vcat(DeviceLayout._poly(seg, sty)))
end

# Types that together can use straight lines only
const LinearSegment{T} =
    Union{Paths.Straight{T}, Paths.ConstantOffset{T, Paths.Straight{T}}}
const LinearStyle = Union{
    Paths.SimpleTrace,
    Paths.SimpleCPW,
    Paths.SimpleStrands,
    Paths.TaperTrace,
    Paths.TaperCPW
}
islinear(::LinearSegment{T}, ::LinearStyle) where {T} = Val(true)
islinear(::Paths.Segment{T}, ::Paths.Style) where {T} = Val(false)

to_polygons(
    seg::Paths.ConstantOffset{T, Paths.Straight{T}},
    sty::LinearStyle;
    kwargs...
) where {T} = to_polygons(Paths.resolve_offset(seg), sty; kwargs...)

pathtopolys(seg::Paths.Segment{T}, sty::Paths.AbstractDecoratedStyle; kwargs...) where {T} =
    _pathtopolys_ignoring_attachments(seg, sty; kwargs...)

# Segment-level calls bypass the Node linearity gate, so straight linear cases need explicit
# polygon-producing methods. Dispatch on Paths.Straight keeps these methods below the wrapper
# handlers and above the generic curvilinear segment methods.
# TODO: Could return CurvilinearPolygon(corner_points(...)) with empty curve list instead,
# keeping everything in the CurvilinearPolygon representation. Currently falls back to
# to_polygons because discretize_curve doesn't handle zero-curvature segments efficiently.
pathtopolys(seg::Paths.Straight{T}, sty::Paths.SimpleTrace; kwargs...) where {T} =
    to_polygons(seg, sty; kwargs...)
pathtopolys(seg::Paths.Straight{T}, sty::Paths.SimpleCPW; kwargs...) where {T} =
    to_polygons(seg, sty; kwargs...)
pathtopolys(seg::Paths.Straight{T}, sty::Paths.SimpleStrands; kwargs...) where {T} =
    to_polygons(seg, sty; kwargs...)
pathtopolys(seg::Paths.Straight{T}, sty::Paths.TaperTrace; kwargs...) where {T} =
    to_polygons(seg, sty; kwargs...)
pathtopolys(seg::Paths.Straight{T}, sty::Paths.TaperCPW; kwargs...) where {T} =
    to_polygons(seg, sty; kwargs...)

# Dispatch node->primitive based on kernel and requirements for representing node exactly
function pathtopolys(node::Paths.Node; kwargs...)
    return pathtopolys(node, islinear(node.seg, node.sty); kwargs...)
end
# A linear path can be exactly represented using plain Polygons.
function pathtopolys(node::Paths.Node, ::Val{true}; kwargs...)
    return to_polygons(node.seg, node.sty; kwargs...)
end

function pathtopolys(node::Paths.Node, ::Val{false}; kwargs...)
    return pathtopolys(node.seg, node.sty; kwargs...)
end

## Helper methods
function perimeter(p::CurvilinearRegion)
    return sum(norm.(points(p.exterior) .- circshift(points(p.exterior), -1)))
end

function perimeter(p::CurvilinearPolygon)
    return sum(norm.(points(p) .- circshift(points(p), -1)))
end

# Only indices that don't start or end a curve are available for rounding.
# cornerindices(p::CurvilinearPolygon, s::GeometryEntityStyle) = cornerindices(p, p0(s))
function cornerindices(p::CurvilinearPolygon{T}) where {T}
    curve_bound_ind = vcat((x -> [x, (x % length(p.p)) + 1]).(p.curve_start_idx)...)
    valid_ind = setdiff(1:length(p.p), curve_bound_ind)
    return valid_ind
end
function cornerindices(p::CurvilinearPolygon, p0::Vector{<:Point}; tol)
    isempty(p0) && return Int[]
    valid_ind = cornerindices(p)
    return isempty(valid_ind) ? Int[] : valid_ind[cornerindices(p.p[valid_ind], p0; tol)]
end
function cornerindices(p::CurvilinearPolygon, r::Polygons.Rounded)
    ss = cornerindices(p)
    isempty(ss) && return Int[]
    if isempty(p0(r))
        selected = ss
    else
        # Match p0 against all roundable vertices (straight-straight + line-arc + arc-arc)
        # jointly, so a p0 point targeting a line-arc or arc-arc corner doesn't accidentally
        # claim a straight-straight corner for inverse_selection.
        la = line_arc_cornerindices(p)
        aa = arc_arc_cornerindices(p)
        all_roundable = vcat(ss, la, aa)
        roundable_pts = p.p[all_roundable]
        matched = Polygons.cornerindices(roundable_pts, p0(r); tol=r.selection_tolerance)
        matched_orig = isempty(matched) ? Int[] : all_roundable[matched]
        selected = filter(i -> i in ss, matched_orig)
    end
    return r.inverse_selection ? setdiff(ss, selected) : selected
end

"""
    line_arc_cornerindices(p::CurvilinearPolygon)

Return indices of vertices where one edge is straight and the other is a curve (line-arc
corners). These are the vertices at curve boundaries that can be fillet-rounded.
"""
line_arc_cornerindices(::AbstractPolygon) = Int[]
line_arc_cornerindices(::AbstractPolygon, ::Polygons.Rounded) = Int[]

function line_arc_cornerindices(p::CurvilinearPolygon)
    indices = Int[]
    n = length(p.p)
    for i = 1:n
        edge = edge_type_at_vertex(p, i)
        is_line_arc = (edge.incoming == :straight) != (edge.outgoing == :straight)
        if is_line_arc
            push!(indices, i)
        end
    end
    return indices
end
function line_arc_cornerindices(p::CurvilinearPolygon, sty::Polygons.Rounded)
    all_la = line_arc_cornerindices(p)
    isempty(all_la) && return Int[]
    if isempty(p0(sty))
        selected = all_la
    else
        # Match each p0 point to the closest roundable vertex across ALL corner types
        # (straight-straight, line-arc, and arc-arc). Only select line-arc corners where the
        # line-arc vertex is genuinely the closest match for that p0 point. The candidate set
        # must include arc-arc vertices too, so a p0 sitting on an arc-arc corner isn't
        # mis-snapped here — keeping this selector consistent with arc_arc_cornerindices.
        straight = cornerindices(p)
        all_roundable = vcat(straight, all_la, arc_arc_cornerindices(p))
        roundable_pts = p.p[all_roundable]
        matched =
            Polygons.cornerindices(roundable_pts, p0(sty); tol=sty.selection_tolerance)
        matched_orig = isempty(matched) ? Int[] : all_roundable[matched]
        selected = filter(i -> i in all_la, matched_orig)
    end
    return sty.inverse_selection ? setdiff(all_la, selected) : selected
end

"""
    arc_arc_cornerindices(p::CurvilinearPolygon)

Return indices of vertices where both edges are curves (arc-arc corners). These are the
vertices where two `Paths.Turn` arcs meet and can be fillet-rounded against each other.
"""
arc_arc_cornerindices(::AbstractPolygon) = Int[]
arc_arc_cornerindices(::AbstractPolygon, ::Polygons.Rounded) = Int[]

function arc_arc_cornerindices(p::CurvilinearPolygon)
    indices = Int[]
    n = length(p.p)
    for i = 1:n
        edge = edge_type_at_vertex(p, i)
        is_arc_arc = (edge.incoming != :straight) && (edge.outgoing != :straight)
        if is_arc_arc
            push!(indices, i)
        end
    end
    return indices
end
function arc_arc_cornerindices(p::CurvilinearPolygon, sty::Polygons.Rounded)
    all_aa = arc_arc_cornerindices(p)
    isempty(all_aa) && return Int[]
    if isempty(p0(sty))
        selected = all_aa
    else
        # Match each p0 point to the closest roundable vertex across all corner types
        # (straight-straight, line-arc, and arc-arc). Only select arc-arc corners where the
        # arc-arc vertex is genuinely the closest match for that p0 point — otherwise a p0
        # placed on a nearby line-arc/straight corner could be mis-snapped to an arc-arc one.
        straight = cornerindices(p)
        all_la = line_arc_cornerindices(p)
        all_roundable = vcat(straight, all_la, all_aa)
        roundable_pts = p.p[all_roundable]
        matched =
            Polygons.cornerindices(roundable_pts, p0(sty); tol=sty.selection_tolerance)
        matched_orig = isempty(matched) ? Int[] : all_roundable[matched]
        selected = filter(i -> i in all_aa, matched_orig)
    end
    return sty.inverse_selection ? setdiff(all_aa, selected) : selected
end

"""
    edge_type_at_vertex(p::CurvilinearPolygon, i::Int)

For vertex `i`, determine whether the incoming and outgoing edges are straight or curved.

Returns a NamedTuple `(incoming=..., outgoing=...)` where each field is either
`:straight` or the `Paths.Segment` (e.g., `Paths.Turn`) for that edge.

  - **Outgoing edge** (from `p[i]` to `p[i+1]`): curved if any
    `curve_start_idx[k] == i`
  - **Incoming edge** (from `p[i-1]` to `p[i]`): curved if any
    `curve_start_idx[k] == mod1(i-1, n)`
"""
function edge_type_at_vertex(p::CurvilinearPolygon, i::Int)
    n = length(p.p)
    prev_i = mod1(i - 1, n)

    incoming = :straight
    outgoing = :straight
    for (k, csi) in enumerate(p.curve_start_idx)
        if csi == prev_i
            incoming = p.curves[k]
        end
        if csi == i
            outgoing = p.curves[k]
        end
    end
    return (; incoming=incoming, outgoing=outgoing)
end

"""
    to_polygons(ent::CurvilinearPolygon{S}, sty::Polygons.Rounded{T}; kwargs...)

Apply rounding to a CurvilinearPolygon and discretize the result to a plain `Polygon`.

This routes through the single symbolic rounding producer `round_to_curvilinearpolygon`,
which rounds both straight-straight corners and line-arc corners and returns a
`CurvilinearPolygon` whose fillets (and trimmed original arcs) are kept as symbolic
`Paths.Turn`s. The resulting curves are then discretized by the shared
`to_polygons(::CurvilinearPolygon; atol, rtol)` so that *all* curve discretization in the
package — paths and rounding alike — goes through one tolerance-controlled code path.

This is the GDS-side consumer; the SolidModel side keeps the `CurvilinearPolygon` symbolic
as native arcs. Both call the same producer (see `round_to_curvilinearpolygon`).

Known limitation: routing GDS rounding through the shared marching discretizer can over-refine
small fillets. The geometry stays within tolerance; only the point density is excessive. The
root cause is the t_scale-dependent curvature guard in `discretization_grid`, so the fix belongs
there rather than in the rounding producer.
"""
function to_polygons(
    ent::CurvilinearPolygon{S},
    sty::Polygons.Rounded{T};
    atol=Polygons._round_atol(S, T),
    rtol=nothing,
    kwargs...
) where {S, T}
    iszero(Polygons.radius(sty)) && return to_polygons(ent; atol=atol, rtol=rtol, kwargs...)

    # Reuse Rounded's corner selection and radius semantics, but keep fillets symbolic until
    # the CurvilinearPolygon discretizer runs.
    rounded = round_to_curvilinearpolygon(
        ent,
        Polygons.radius(sty);
        corner_indices=cornerindices(ent, sty),
        line_arc_corner_indices=line_arc_cornerindices(ent, sty),
        min_angle=sty.min_angle,
        min_side_len=sty.min_side_len
    )
    return to_polygons(rounded; atol=atol, rtol=rtol, kwargs...)
end

"""
    round_to_curvilinearpolygon(pol, radius; kwargs...)

Round selected polygon corners and return a `CurvilinearPolygon` whose fillets remain symbolic
`Paths.Turn` arcs. GDS later discretizes those arcs through `to_polygons(::CurvilinearPolygon)`;
SolidModel/OpenCascade can keep them native.
"""
function round_to_curvilinearpolygon(
    pol::GeometryEntity{T},
    radius::S;
    corner_indices=eachindex(points(pol)),
    line_arc_corner_indices=nothing,
    min_angle=1e-3,
    relative::Bool=(T <: Length) && (S <: Real),
    min_side_len=relative ? zero(T) : radius
)::CurvilinearPolygon{T} where {T, S <: DeviceLayout.Coordinate}
    # A curve-free CurvilinearPolygon has no line-arc corners, so this reduces to
    # straight-straight rounding in the CurvilinearPolygon method below.
    return round_to_curvilinearpolygon(
        CurvilinearPolygon(points(pol)),
        radius;
        corner_indices,
        line_arc_corner_indices,
        min_angle,
        relative,
        min_side_len
    )
end

function round_to_curvilinearpolygon(
    pol::CurvilinearPolygon{T},
    radius::S;
    corner_indices=eachindex(points(pol)),
    line_arc_corner_indices=nothing,
    min_angle=1e-3,
    relative::Bool=(T <: Length) && (S <: Real),
    min_side_len=relative ? zero(T) : radius
)::CurvilinearPolygon{T} where {T, S <: DeviceLayout.Coordinate}
    # If radius is dimensional, non-relative rounding.
    V = float(T)
    # Tie break for Real, Real introduces a type instability for non-dimensional.
    relative = ((T <: Length) && (S <: Real)) || (relative && T <: Real && S <: Real)

    poly = points(pol)
    len = length(poly)
    new_points = Point{V}[]
    new_curves = Paths.Turn{V}[]
    new_curve_start_idx = Int[]

    # Track trims for existing curves when rounding line-arc corners
    trim_start_pts = Dict{Int, Point{V}}()
    trim_end_pts = Dict{Int, Point{V}}()

    # Determine which line-arc corners to round
    la_indices = if !isnothing(line_arc_corner_indices)
        line_arc_corner_indices
    else
        line_arc_cornerindices(pol)
    end

    # Per-vertex membership checks below run once per polygon point; use Set/Dict to keep this O(n).
    la_set = Set(la_indices)
    corner_set = Set(corner_indices)
    curve_index_at_vertex = Dict{Int, Int}()
    for (k, v) in pairs(pol.curve_start_idx)
        curve_index_at_vertex[v] = k
    end

    for i in eachindex(poly)
        edge = edge_type_at_vertex(pol, i)
        is_line_arc = i in la_set

        if is_line_arc
            # A line-arc corner has a straight edge on one side and an arc on the other.
            # `arc_is_outgoing` records which: true means line→arc (line incoming, arc
            # outgoing), false means arc→line. This picks the arc curve to fillet against
            # and the far end of the straight edge (`p_line`) to fillet against.
            arc_is_outgoing = edge.outgoing != :straight
            arc_curve = arc_is_outgoing ? edge.outgoing : edge.incoming
            p_line = arc_is_outgoing ? poly[mod1(i - 1, len)] : poly[mod1(i + 1, len)]
            straight_len = norm(p_line - poly[i])
            arc_len = Paths.pathlength(arc_curve)
            radius_dim = relative ? radius * min(straight_len, arc_len) : radius
            result = rounded_corner_segment_line_arc(
                p_line,
                poly[i],
                arc_curve,
                arc_is_outgoing,
                radius_dim;
                min_side_len=min_side_len,
                min_angle=min_angle
            )
            if !isnothing(result)
                push!(new_points, Paths.p0(result.fillet))
                push!(new_curves, result.fillet)
                push!(new_curve_start_idx, length(new_points))
                push!(new_points, Paths.p1(result.fillet))
                # Record where this fillet meets the original arc (T_arc) so the arc can be
                # trimmed back to that tangent point in the second pass below. Which end of
                # the arc is trimmed depends on orientation: a line→arc corner (outgoing)
                # cuts the arc's START, an arc→line corner cuts its END.
                arc_start_vtx = arc_is_outgoing ? i : mod1(i - 1, len)
                curve_k = get(curve_index_at_vertex, arc_start_vtx, nothing)
                if !isnothing(curve_k)
                    if arc_is_outgoing
                        trim_start_pts[curve_k] = result.T_arc
                    else
                        trim_end_pts[curve_k] = result.T_arc
                    end
                end
            else
                push!(new_points, poly[i])
            end
        elseif !(i in corner_set)
            push!(new_points, poly[i])
        else
            p0 = poly[mod1(i - 1, len)]
            p1 = poly[i]
            p2 = poly[mod1(i + 1, len)]
            radius_dim = relative ? radius * min(norm(p0 - p1), norm(p1 - p2)) : radius
            seg_or_p1 = rounded_corner_segment(
                p0,
                p1,
                p2,
                radius_dim,
                min_side_len=min_side_len,
                min_angle=min_angle
            )
            if seg_or_p1 isa Paths.Turn
                push!(new_points, Paths.p0(seg_or_p1))
                push!(new_curves, seg_or_p1)
                push!(new_curve_start_idx, length(new_points))
                push!(new_points, Paths.p1(seg_or_p1))
            else
                push!(new_points, seg_or_p1)
            end
        end
    end

    # Need to shift start indices for all old curves if new points were introduced
    # behind them by the additional curves. Need to do this iteratively, in case the
    # shifted point overtakes added in points.
    old_curve_start_idx = deepcopy(pol.curve_start_idx)
    for nci ∈ new_curve_start_idx
        old_curve_start_idx[old_curve_start_idx .>= nci] .+= 1
    end

    for (k, csi) in enumerate(old_curve_start_idx)
        original = pol.curves[k]
        has_start = haskey(trim_start_pts, k)
        has_end = haskey(trim_end_pts, k)
        if has_start || has_end
            total_len = Paths.pathlength(original)
            t_s =
                has_start ? Paths.pathlength_nearest(original, trim_start_pts[k]) :
                zero(total_len)
            t_e = has_end ? Paths.pathlength_nearest(original, trim_end_pts[k]) : total_len
            # Keep the arc only if a positive-length segment remains between the trim
            # points. t_e <= t_s means the two fillets' tangent points crossed over — the
            # requested radius was too large for this arc, so both fillets overlap. In that
            # case we drop the original arc entirely and let the fillets meet directly
            # (building a Turn here would give a zero- or negative-length arc).
            if t_e > t_s
                # Rebuild the surviving span as a fresh Turn: start at the trim point,
                # inherit the original direction there, and scale the sweep by the fraction
                # of arc length that survives the trim.
                p0_new = original(t_s)
                α0_new = Paths.direction(original, t_s)
                α_new = original.α * (t_e - t_s) / total_len
                push!(new_curves, Paths.Turn(α_new, original.r; p0=p0_new, α0=α0_new))
                push!(new_curve_start_idx, csi)
            end
        else
            push!(new_curves, original)
            push!(new_curve_start_idx, csi)
        end
    end

    # Constructor will sort curves by start index
    return CurvilinearPolygon(new_points, new_curves, new_curve_start_idx)
end

# Straight-straight corner fillet, returning a symbolic `Paths.Turn` (or `p1` if the corner
# can't be rounded). The `k`-matrix solve intersects the two edge-parallel offset lines to
# locate the rounding circle — the same geometry as `Polygons.rounded_corner`, but that one
# discretizes to points while this keeps the arc symbolic.
function rounded_corner_segment(
    p0::Point{T},
    p1::Point{T},
    p2::Point{T},
    radius::S;
    min_side_len=radius,
    min_angle=1e-3
) where {T, S <: DeviceLayout.Coordinate}
    geom = Polygons._rounded_corner_geometry(
        p0,
        p1,
        p2,
        radius;
        atol=Polygons._round_atol(T, S),
        min_side_len=min_side_len,
        min_angle=min_angle
    )
    isnothing(geom) && return p1
    return Paths.Turn(uconvert(°, geom.dα), geom.radius, geom.start, uconvert(°, geom.α0))
end

"""
    rounded_corner_segment_line_arc(
        p_line, p_corner, arc_curve, arc_is_outgoing, radius;
        min_side_len, min_angle
    )

Compute a fillet arc at the corner where a straight edge meets a circular arc, returning a
`Paths.Turn` segment (the symbolic fillet kept un-discretized). Used by
`round_to_curvilinearpolygon` for line-arc corners.

  - `p_line`: far endpoint of the straight edge (not the corner)
  - `p_corner`: vertex where the straight edge meets the arc
  - `arc_curve`: `Paths.Turn` representing the circular arc
  - `arc_is_outgoing`: `true` if the arc leaves from `p_corner`, `false` if it arrives
  - `radius`: fillet radius

Returns `(; fillet::Paths.Turn, T_line::Point, T_arc::Point)` or `nothing`.
"""
function rounded_corner_segment_line_arc(
    p_line::Point{T},
    p_corner::Point{T},
    arc_curve::Paths.Turn,
    arc_is_outgoing::Bool,
    radius::S;
    min_side_len=radius,
    min_angle=1e-3
) where {T, S <: DeviceLayout.Coordinate}
    V = float(T)
    r = convert(V, radius)
    atol = DeviceLayout.Polygons._round_atol(T, S)

    # Validate straight edge length
    line_len = norm(p_corner - p_line)
    if line_len < min_side_len && !isapprox(line_len, min_side_len, atol=atol)
        return nothing
    end

    # Line direction: from p_line toward p_corner
    v_line = (p_corner - p_line) / line_len
    α_line = atan(v_line.y, v_line.x)

    # Arc tangent direction at the corner
    arc_len = Paths.pathlength(arc_curve)
    α_arc = if arc_is_outgoing
        Paths.direction(arc_curve, zero(arc_len))
    else
        Paths.direction(arc_curve, arc_len)
    end

    # Check if line and arc tangent are nearly parallel (already smooth)
    if isapprox_angle(α_line, α_arc; atol=min_angle) ||
       isapprox_angle(α_line, α_arc + π; atol=min_angle)
        return nothing
    end

    # Arc geometry
    O = Paths.curvaturecenter(arc_curve)
    R = arc_curve.r

    # Determine which side of the line the polygon interior is on.
    # Use a coordinate-derived offset to avoid both collinear degeneracy and
    # Unitful ContextUnits mismatches (atol may have different unit context).
    offset_scale = line_len * 1e-6
    p_virtual = p_corner + Point(cos(α_arc), sin(α_arc)) * offset_scale
    turn_sign = DeviceLayout.orientation(p_line, p_corner, p_virtual)
    if !arc_is_outgoing
        turn_sign = -turn_sign
    end
    # If orientation is degenerate (collinear), skip this corner
    iszero(turn_sign) && return nothing

    # Fillet center C_f must satisfy:
    #   (1) distance to straight edge = r  (tangent to line)
    #   (2) distance to arc center O  = D  (tangent to arc)
    # Constraint (1): C_f lies on a line parallel to the edge, offset by r.
    # Constraint (2): C_f lies on a circle of radius D centered at O.
    n_line = Point(-v_line.y, v_line.x)
    fillet_side = sign(turn_sign)
    p_offset = p_corner + (r * fillet_side) * n_line

    function solve_for_D(D_val)
        w = p_offset - O
        b = w.x * v_line.x + w.y * v_line.y
        c = w.x * w.x + w.y * w.y - D_val * D_val
        disc = b * b - c
        disc < zero(disc) && return Point{float(V)}[]
        sq = sqrt(disc)
        s1 = -b + sq
        s2 = -b - sq
        return [p_offset + s * v_line for s in (s1, s2)]
    end

    function validate_t_line(cf)
        t = (cf - p_line).x * v_line.x + (cf - p_line).y * v_line.y
        return -atol < t < line_len + atol
    end

    function find_best_center(D_val)
        candidates = solve_for_D(D_val)
        isempty(candidates) && return nothing
        valid = filter(validate_t_line, candidates)
        isempty(valid) && return nothing
        _, idx = findmin(cf -> norm(cf - p_corner), valid)
        return valid[idx]
    end

    C_f_ext = find_best_center(R + r)
    C_f_int = abs(R - r) > zero(R) ? find_best_center(abs(R - r)) : nothing
    ext_ok = !isnothing(C_f_ext)
    int_ok = !isnothing(C_f_int)

    C_f = if ext_ok && int_ok
        norm(C_f_ext - p_corner) < norm(C_f_int - p_corner) ? C_f_ext : C_f_int
    elseif ext_ok
        C_f_ext
    elseif int_ok
        C_f_int
    else
        return nothing
    end

    # Tangent point on line: foot of perpendicular from C_f
    t_proj = (C_f - p_line).x * v_line.x + (C_f - p_line).y * v_line.y
    T_line = p_line + t_proj * v_line

    # Tangent point on arc: point on arc in direction of fillet center
    # When C_f ≈ O (fillet_r ≈ arc_r), the direction is undefined
    # and the fillet geometry is degenerate — skip rounding this corner.
    norm_cf_o = norm(C_f - O)
    norm_cf_o < atol && return nothing
    cf_dir = (C_f - O) / norm_cf_o
    T_arc_pt = O + R * cf_dir

    # Construct fillet Turn segment
    # Winding order determines start/end:
    #   arc_is_outgoing=true:  ...line → T_line → [fillet] → T_arc → arc...
    #   arc_is_outgoing=false: ...arc → T_arc → [fillet] → T_line → line...
    start_pt, end_pt = arc_is_outgoing ? (T_line, T_arc_pt) : (T_arc_pt, T_line)

    # When tangent points coincide with C_f (fillet_r < atol),
    # the direction vectors are undefined — skip rounding this corner.
    norm_start = norm(start_pt - C_f)
    norm_end = norm(end_pt - C_f)
    (norm_start < atol || norm_end < atol) && return nothing
    d_start = (start_pt - C_f) / norm_start
    d_end = (end_pt - C_f) / norm_end

    cross_val = d_start.x * d_end.y - d_start.y * d_end.x
    dot_val = d_start.x * d_end.x + d_start.y * d_end.y
    dα = atan(cross_val, dot_val)

    # When the fillet sweep angle is tiny, the arc sagitta
    # (r·(1 - cos(dα/2))) is sub-nanometer — GMSH can't distinguish it from
    # a line and rejects it. Skip rounding this corner.
    abs(dα) < min_angle && return nothing

    # Tangent direction at start: perpendicular to radius, rotated by sweep direction
    angle_start = atan(d_start.y, d_start.x)
    α0 = angle_start + sign(dα) * π / 2

    fillet = Paths.Turn(uconvert(°, dα), r; p0=start_pt, α0=uconvert(°, α0))

    return (; fillet, T_line, T_arc=T_arc_pt)
end

######## Styled entity → curvilinear geometry
#
# `to_curvilinear` expands a (possibly nested) styled entity into curve-bearing geometry —
# a `CurvilinearPolygon`, a `CurvilinearRegion`, or a `Vector` of those — preserving arcs
# instead of discretizing them. It is the single source of truth shared by the SolidModel
# render path, the GDS `Rounded` bridge (`to_polygons(::StyledEntity, ::Rounded)`), and
# curve recovery (`_normalize_curved_clip_arg`). `styled_loop` is the per-contour worker that applies one
# resolved style to one loop; `to_curvilinear` drives the recursion over nesting and trees.

# Given a loop (Polygon or CurvilinearPolygon) and one resolved style, produce a
# CurvilinearPolygon. Rounded produces exact fillet arcs; Plain/NoRender are pass-through.
styled_loop(p::Polygon, ::Plain; kwargs...) = CurvilinearPolygon(points(p))
styled_loop(::Polygon{T}, ::NoRender; kwargs...) where {T} = CurvilinearPolygon(Point{T}[])
function styled_loop(p::GeometryEntity, sty::OptionalStyle; kwargs...)
    return styled_loop(
        p,
        get(kwargs, sty.flag, sty.default) ? sty.true_style : sty.false_style;
        kwargs...
    )
end
function styled_loop(p::GeometryEntity, sty::Rounded; kwargs...)
    return round_to_curvilinearpolygon(
        p,
        radius(sty),
        min_side_len=sty.min_side_len,
        corner_indices=cornerindices(p, sty),
        line_arc_corner_indices=line_arc_cornerindices(p, sty),
        min_angle=sty.min_angle
    )
end
# Styles that don't affect geometry (mesh sizing, direction annotation) leave the loop as-is.
styled_loop(p::Polygon, ::Union{MeshSized, WithDirection}; kwargs...) =
    CurvilinearPolygon(points(p))
styled_loop(l::CurvilinearPolygon, ::Union{MeshSized, WithDirection}; kwargs...) = l
# Clipper `PolyNode`s carry their loop in `contour`; convert then apply the style. Restricted
# to `PolyNode` so unrelated types fail at dispatch instead of hitting a missing `contour`.
styled_loop(n::PolyNode, sty; kwargs...) = styled_loop(Polygon(contour(n)), sty; kwargs...)

styled_loop(l::CurvilinearPolygon, sty::Plain; kwargs...) = l
styled_loop(::CurvilinearPolygon{T}, ::NoRender; kwargs...) where {T} =
    CurvilinearPolygon(Point{T}[])

# Expand a styled entity into curve-bearing geometry. Entry points accept a bare style
# (single style applied to the whole entity) and dispatch by entity type below.
# To AbstractPolygon, CurvilinearPolygon, CurvilinearRegion, or vector of those.
# If this produces an AbstractPolygon and the styled entity should be curve-bearing, warn for curve loss.
to_curvilinear(ent::GeometryEntity, sty; kwargs...) =
    _to_curvilinear_discretize(ent, sty; kwargs...)
function _to_curvilinear_discretize(ent, sty; kwargs...)
    expanded = to_polygons(ent, sty; kwargs...)
    discretized =
        expanded isa AbstractPolygon ||
        (expanded isa AbstractVector && any(x -> x isa AbstractPolygon, expanded))
    discretized && _maybe_warn_curve_loss(sty(ent))
    return expanded
end
# A circle is exactly representable as four arcs, so styled circles keep their curves
# (and participate in curve recovery) instead of falling to the discretizing fallback.
# Unequal-radii ellipses are not representable as arcs and discretize as before.
to_curvilinear(ent::Ellipse, sty; kwargs...) =
    iscircle(ent) ? to_curvilinear(CurvilinearPolygon(ent), sty; kwargs...) :
    _to_curvilinear_discretize(ent, sty; kwargs...)
# Nested styles: expand the inner style first (inner-out), then apply the outer style to the
# resulting curvilinear geometry so both rounding passes see exact arcs.
function to_curvilinear(ent::StyledEntity, sty; kwargs...)
    return to_curvilinear(to_curvilinear(ent.ent, ent.sty; kwargs...), sty; kwargs...)
end
to_curvilinear(ents::AbstractVector, sty; kwargs...) =
    vcat(to_curvilinear.(ents, Ref(sty); kwargs...)...)
to_curvilinear(ent::AbstractPolygon, sty; kwargs...) =
    styled_loop(convert(Polygon, ent), sty; kwargs...)
to_curvilinear(ent::CurvilinearPolygon, sty; kwargs...) = styled_loop(ent, sty; kwargs...)
# Path nodes expand through `pathtopolys`, which preserves curves; geometry-transparent
# styles pass through. Without this method a `MeshSized` path node falls to the generic
# `to_polygons` fallback and silently discretizes its arcs. Zero-length continuous-style
# nodes (as left around `attach!`/`launch!`) expand to nothing, matching `_normalize_curved_clip_arg`.
function to_curvilinear(
    n::Paths.Node{T},
    ::Union{MeshSized, WithDirection};
    kwargs...
) where {T}
    iszero(pathlength(n.seg)) &&
        n.sty isa Paths.ContinuousStyle &&
        return CurvilinearPolygon{T}[]
    return pathtopolys(n; kwargs...)
end
to_curvilinear(ent::ClippedPolygon, sty; kwargs...) =
    to_curvilinear(ent, StyleDict(sty); kwargs...)
to_curvilinear(ent::CurvilinearRegion, sty; kwargs...) =
    to_curvilinear(ent, StyleDict(sty); kwargs...)
function to_curvilinear(ent::ClippedPolygon{T}, sty::StyleDict; kwargs...) where {T}
    # Flatten the tree into a collection of CurvilinearRegion with style applied per contour.
    flat = CurvilinearRegion{T}[]
    function add_region(node)
        push!(
            flat,
            CurvilinearRegion{T}(
                styled_loop(node, sty[node]; kwargs...),
                styled_loop.(node.children, getindex.(Ref(sty), node.children); kwargs...)
            )
        )
        for n in node.children
            add_region.(n.children) # Add all grandchildren -- positives
        end
    end
    add_region.(ent.tree.children)
    return flat
end
function to_curvilinear(ent::CurvilinearRegion{T}, sty::StyleDict; kwargs...) where {T}
    return CurvilinearRegion{T}(
        styled_loop(ent.exterior, sty[1]; kwargs...),
        styled_loop.(ent.holes, getindex.(sty, 1, 1:length(ent.holes)); kwargs...)
    )
end

# Whether discretizing this entity to plain polygons loses curve geometry. Plain polygon
# types and linear path nodes are exactly representable as polygons; other entity types
# are assumed to carry curves unless they declare otherwise, so that unrecognized
# curve-bearing entities still trigger the loss warning below.
_carries_curves(e) = true
_carries_curves(::AbstractPolygon) = false
_carries_curves(e::CurvilinearPolygon) = !isempty(e.curves)
_carries_curves(e::CurvilinearRegion) =
    _carries_curves(e.exterior) || any(_carries_curves, e.holes)
_carries_curves(n::Paths.Node) = islinear(n.seg, n.sty) isa Val{false}
_carries_curves(e::StyledEntity{T, U, <:Rounded}) where {T, U} = true
function _carries_curves(e::StyledEntity{T, U, <:StyleDict}) where {T, U}
    return e.sty.default isa Rounded ||
           any(x -> x isa Rounded, values(e.sty.styles)) ||
           _carries_curves(e.ent)
end
_carries_curves(e::StyledEntity{T, U}) where {T, U} = _carries_curves(e.ent)

# Entities without a curve-preserving method are discretized.
# Warn once per entity type so the loss is observable.
const _curve_loss_warned = Set{Symbol}()
function _maybe_warn_curve_loss(e)
    _carries_curves(e) || return nothing
    key = Symbol("$(typeof(e))")
    key in _curve_loss_warned && return nothing
    push!(_curve_loss_warned, key)
    @warn "recover_curves: entities of type $(typeof(e)) have no curve-recovery method " *
          "and are discretized via to_polygons — any curves they carry will not be " *
          "recovered. (This warning is shown once per entity type.)"
    return nothing
end

# Bridge for nested Rounded styles in the Cell/GDS rendering path. Without it, the inner
# style resolves to a plain Polygon (losing arc info), so the outer Rounded could only do
# line-line rounding. Routing the inner styles through `to_curvilinear` yields exact fillet
# arcs, so the outer Rounded can apply line-arc rounding via to_polygons(_, ::Rounded).
function to_polygons(ent::StyledEntity, sty::Rounded; kwargs...)
    inner = to_curvilinear(ent.ent, ent.sty; kwargs...)
    if inner isa AbstractVector
        return vcat(to_polygons.(inner, Ref(sty); kwargs...)...)
    end
    return to_polygons(sty(inner); kwargs...)
end

include("curve_recovery.jl")

end # module
