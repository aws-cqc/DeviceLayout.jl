module Curvilinear

using LinearAlgebra

import Base: convert

import CoordinateTransformations: Transformation

import DeviceLayout
import DeviceLayout:
    AbstractPolygon,
    GeometryEntity,
    GeometryEntityStyle,
    Paths,
    Reflection,
    Rotation,
    ScaledIsometry,
    Transformation,
    Translation
import DeviceLayout: to_polygons, points, rotation, origin, mag, xrefl, transform, perimeter
using DeviceLayout.Paths
import DeviceLayout.Polygons: cornerindices

using ..Points
using ..Polygons
using ..Paths

export CurvilinearPolygon, CurvilinearRegion, pathtopolys

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
    # A negative start idx like -3 means that the corresponding curve
    # between p[3] and p[4] is actually parameterized from p[4] to p[3]
    function CurvilinearPolygon{T}(p, c, csi) where {T} # Make sure you don't have zero-length curves
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
        return new{T}(p, c, csi)
    end
end
CurvilinearPolygon(points::Vector{Point{T}}, curves, curve_start_idx) where {T} =
    CurvilinearPolygon{T}(points, curves, curve_start_idx)
function CurvilinearPolygon(points::Vector{Point{T}}) where {T}
    # Straight segments are implicit
    return CurvilinearPolygon{T}(points, Paths.Segment[], Int[])
end
CurvilinearPolygon(p::Polygon{T}) where {T} = CurvilinearPolygon{T}(points(p))

### Conversion methods
function to_polygons(
    e::CurvilinearPolygon{T};
    atol=DeviceLayout.onenanometer(T),
    kwargs...
) where {T}
    i = 1
    p = Point{T}[]

    # TODO: Use ToTolerance
    for (idx, (csi, c)) ∈ enumerate(zip(e.curve_start_idx, e.curves))
        # Add the points from current to start of curve
        append!(p, e.p[i:abs(csi)])

        # Discretize segment with 181 pts (1° over 180° turn).
        wrapped_i = mod1(abs(csi) + 1, length(e.p))
        pp = c.(range(zero(T), pathlength(c), 181))

        # Remove the calculated points corresponding to start and end.
        term_p = csi < 0 ? popfirst!(pp) : pop!(pp)
        init_p = csi < 0 ? pop!(pp) : popfirst!(pp)

        # Add interior points and bump counter.
        append!(p, csi < 0 ? reverse(pp) : pp)
        i = abs(csi) + 1

        # Ensure that the calculated start and end points match the non-calculated points.
        @assert !isapprox(init_p, term_p; atol=1e-3 * DeviceLayout.onenanometer(T)) "Curve $idx must have non-zero length!"
        @assert isapprox(term_p, e.p[wrapped_i]; atol=1e-3 * DeviceLayout.onenanometer(T)) "Curve $idx must $(csi < 0 ? "start" : "end") at point $(wrapped_i)!"
        @assert isapprox(init_p, e.p[abs(csi)]; atol=1e-3 * DeviceLayout.onenanometer(T)) "Curve $idx must $(csi < 0 ? "end" : "start") at point $(abs(csi))!"
    end
    append!(p, e.p[i:end])

    return Polygon{T}(p)
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
        xrefl(f) ? reverse(csi_rev.(e.curve_start_idx, length(e.p))) : e.curve_start_idx
    )
end

convert(::Type{GeometryEntity{T}}, e::CurvilinearPolygon) where {T} =
    convert(CurvilinearPolygon{T}, e)
convert(::Type{GeometryEntity{T}}, e::CurvilinearPolygon{T}) where {T} = e
function convert(::Type{CurvilinearPolygon{T}}, e::CurvilinearPolygon{S}) where {T, S}
    return CurvilinearPolygon{T}(
        convert(Vector{Point{T}}, e.p),
        e.curves,
        e.curve_start_idx
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
"""
struct CurvilinearRegion{T} <: GeometryEntity{T}
    exterior::CurvilinearPolygon{T}
    holes::Vector{CurvilinearPolygon{T}}
    CurvilinearRegion{T}(ext::CurvilinearPolygon, holes=CurvilinearPolygon{T}[]) where {T} =
        new(ext, holes)
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

to_polygons(e::CurvilinearRegion{T}; kwargs...) where {T} =
    difference2d(to_polygons(e.exterior), to_polygons.(e.holes))

function transform(e::CurvilinearRegion{T}, f::Transformation) where {T}
    return CurvilinearRegion{T}(transform(e.exterior, f), transform.(e.holes, Ref(f)))
end

convert(::Type{GeometryEntity{T}}, e::CurvilinearRegion) where {T} =
    convert(CurvilinearRegion{T}, e)
convert(::Type{GeometryEntity{T}}, e::CurvilinearRegion{T}) where {T} = e
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
    @warn "Discretizing path segment ($f, $s) for CurvilinearRegion construction"
    return to_polygons(f, s; kwargs...)
end

# NoRender and friends — effectively the same as above but without the warning
pathtopolys(seg::Paths.Segment{T}, s::Paths.NoRenderContinuous; kwargs...) where {T} =
    Polygon{T}[]
pathtopolys(seg::Paths.Segment{T}, s::Paths.NoRenderDiscrete; kwargs...) where {T} =
    Polygon{T}[]
pathtopolys(seg::Paths.Segment{T}, s::Paths.SimpleNoRender; kwargs...) where {T} =
    Polygon{T}[]
pathtopolys(seg::Paths.Segment{T}, s::Paths.NoRender; kwargs...) where {T} = Polygon{T}[]

pathtopolys(p::Paths.Path; kwargs...) =
    vcat(pathtopolys.(filter(x -> !iszero(pathlength(x)), p.nodes)))

function pathtopolys(
    f::Paths.CompoundSegment{T},
    s::Paths.CompoundStyle;
    kwargs...
) where {T}
    return vcat(pathtopolys.(f.segments, s.styles; kwargs...)...)
end

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

# Traces generate one surface
# SimpleTrace can use constant offset
function pathtopolys(seg::Paths.Segment{T}, sty::Paths.SimpleTrace; kwargs...) where {T}
    pts = corner_points(seg, sty, true)
    # Check if the points are degenerate
    if isapprox(pts[1], pts[2])
        return CurvilinearPolygon(pts[2:end], [Paths.offset(seg, Paths.extent(sty))], [-2])
    elseif isapprox(pts[3], pts[4])
        return CurvilinearPolygon(pts[1:3], [Paths.offset(seg, -Paths.extent(sty))], [1])
    end
    return CurvilinearPolygon(
        pts,
        [Paths.offset(seg, -Paths.extent(sty)), Paths.offset(seg, Paths.extent(sty))],
        [1, -3]
    )
end

function pathtopolys(seg::Paths.Segment{T}, sty::Paths.Trace; kwargs...) where {T}
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
function pathtopolys(seg::Paths.Segment{T}, sty::Paths.SimpleCPW; kwargs...) where {T}
    pts = corner_points(seg, sty, true)
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

function pathtopolys(seg::Paths.Segment{T}, sty::Paths.CPW; kwargs...) where {T}
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

# Terminations are only used with Straight and generate one or two [Rounded] Polygons
function pathtopolys(
    seg::Paths.Straight{T},
    sty::Union{Paths.TraceTermination, Paths.CPWOpenTermination, Paths.CPWShortTermination};
    kwargs...
) where {T}
    p = DeviceLayout._poly(seg, sty)
    return p isa Vector ? CurvilinearPolygon.(p) : CurvilinearPolygon(p)
end

# Types that together can use straight lines only
const LinearSegment{T} =
    Union{Paths.Straight{T}, Paths.ConstantOffset{T, Paths.Straight{T}}}
const LinearStyle =
    Union{Paths.SimpleTrace, Paths.SimpleCPW, Paths.TaperTrace, Paths.TaperCPW}
islinear(::LinearSegment{T}, ::LinearStyle) where {T} = Val(true)
islinear(::Paths.Segment{T}, ::Paths.Style) where {T} = Val(false)

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
    curve_bound_ind =
        vcat((x -> [abs(x), (abs(x) % length(p.p)) + 1]).(p.curve_start_idx)...)
    valid_ind = setdiff(1:length(p.p), curve_bound_ind)
    return valid_ind
end
function cornerindices(p::CurvilinearPolygon, p0::Vector{<:Point}; tol)
    isempty(p0) && return Int[]
    valid_ind = cornerindices(p)
    isempty(valid_ind) && return Int[]
    # Pick the closest to p0 satisfying tolerance.
    return filter!(
        x -> x > 0,
        valid_ind[map(p0) do px
            idx = findfirst(p_idx -> isapprox(px, p_idx), p.p[valid_ind])
            !isnothing(idx) && return idx
            d, idx = findmin(norm.(p.p[valid_ind] .- px))
            return d < tol ? idx : -1
        end]
    )
end
function cornerindices(p::CurvilinearPolygon, r::Polygons.Rounded)
    corner_indices =
        isempty(p0(r)) ? cornerindices(p) :
        cornerindices(p, p0(r); tol=r.selection_tolerance)
    return r.inverse_selection ? setdiff(cornerindices(p), corner_indices) : corner_indices
end

end # module
