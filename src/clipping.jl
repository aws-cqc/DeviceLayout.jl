### Clipper operations and helpers
"""
    clip(op::Clipper.ClipType, s, c; kwargs...)
    clip(op::Clipper.ClipType, s::AbstractVector{A}, c::AbstractVector{B};
        kwargs...) where {S, T, A<:Polygon{S}, B<:Polygon{T}}
    clip(op::Clipper.ClipType,
        s::AbstractVector{Polygon{T}}, c::AbstractVector{Polygon{T}};
        pfs::Clipper.PolyFillType=Clipper.PolyFillTypePositive,
        pfc::Clipper.PolyFillType=Clipper.PolyFillTypePositive) where {T}

Return the `ClippedPolygon` resulting from a polygon clipping operation.

Uses the [`Clipper`](http://www.angusj.com/delphi/clipper.php) library and the
[`Clipper.jl`](https://github.com/Voxel8/Clipper.jl) wrapper to perform polygon clipping.

## Positional arguments

The first argument must be one of the following types to specify a clipping operation:

  - `Clipper.ClipTypeDifference`
  - `Clipper.ClipTypeIntersection`
  - `Clipper.ClipTypeUnion`
  - `Clipper.ClipTypeXor`

Note that these are types; you should not follow them with `()`.

The second and third argument may be a `GeometryEntity` or array of `GeometryEntity`. All entities
are first converted to polygons using [`to_polygons`](@ref).
Each can also be a `GeometryStructure` or `GeometryReference`, in which case
`elements(flatten(p))` will be converted to polygons.
Each can also be a pair `geom => layer`, where `geom` is a
`GeometryStructure` or `GeometryReference`, while `layer` is a `DeviceLayout.Meta`, a layer name `Symbol`, and/or a collection
of either, in which case only the elements in those layers will be taken from the flattened structure.

## Keyword arguments

`pfs` and `pfc` specify polygon fill rules for the `s` and `c` arguments, respectively.
These arguments may include:

  - `Clipper.PolyFillTypeNegative`
  - `Clipper.PolyFillTypePositive`
  - `Clipper.PolyFillTypeEvenOdd`
  - `Clipper.PolyFillTypeNonZero`

See the [`Clipper` docs](http://www.angusj.com/delphi/clipper/documentation/Docs/Units/ClipperLib/Types/PolyFillType.htm)
for further information.

See also [union2d](@ref), [difference2d](@ref), [intersect2d](@ref), and [xor2d](@ref).
"""
function clip(op::Clipper.ClipType, s, c; kwargs...)
    return clip(op, _normalize_clip_arg(s), _normalize_clip_arg(c); kwargs...)
end

# Clipping requires an AbstractVector{Polygon{T}}
_normalize_clip_arg(p::Polygon) = [p]
_normalize_clip_arg(p::GeometryEntity) = _normalize_clip_arg(to_polygons(p))
_normalize_clip_arg(p::ClippedPolygon{T}) where {T} =
    Polygon{T}[Polygon(c) for c in _all_contours(p.tree)]
_normalize_clip_arg(p::AbstractArray{Polygon{T}}) where {T} = p
_normalize_clip_arg(p::AbstractArray{<:GeometryEntity{T}}) where {T} =
    reduce(vcat, _normalize_clip_arg.(p); init=Polygon{T}[])
_normalize_clip_arg(p::Union{GeometryStructure, GeometryReference}) =
    _normalize_clip_arg(flat_elements(p))
_normalize_clip_arg(p::Pair{<:Union{GeometryStructure, GeometryReference}}) =
    _normalize_clip_arg(flat_elements(p))
_normalize_clip_arg(p::AbstractArray) =
    reduce(vcat, _normalize_clip_arg.(p); init=Polygon{DeviceLayout.coordinatetype(p)}[])

# Clipping arrays of AbstractPolygons
function clip(
    op::Clipper.ClipType,
    s::AbstractVector{A},
    c::AbstractVector{B};
    kwargs...
) where {S, T, A <: Polygon{S}, B <: Polygon{T}}
    dimension(S) != dimension(T) && throw(Unitful.DimensionError(oneunit(S), oneunit(T)))
    R = promote_type(S, T)

    return clip(
        op,
        convert(Vector{Polygon{R}}, s),
        convert(Vector{Polygon{R}}, c);
        kwargs...
    )
end

# Clipping two identically-typed arrays of <: Polygon
function clip(
    op::Clipper.ClipType,
    s::AbstractVector{Polygon{T}},
    c::AbstractVector{Polygon{T}};
    pfs::Clipper.PolyFillType=Clipper.PolyFillTypePositive,
    pfc::Clipper.PolyFillType=Clipper.PolyFillTypePositive
) where {T}
    sc, cc = clipperize(s), clipperize(c)
    polys = _clip(op, sc, cc; pfs, pfc)
    return declipperize(polys, T)
end

"""
    cliptree(op, s, c; kwargs...)

!!! warning "Deprecated"

    `cliptree` is deprecated. Use `clip(op, s, c; kwargs...).tree` instead.
"""
function cliptree(op, s, c; kwargs...)
    Base.depwarn(
        "`cliptree` is deprecated, use `clip(op, s, c; kwargs...).tree` instead",
        :cliptree
    )
    return clip(op, s, c; kwargs...).tree
end

"""
    union2d(p1, p2)

Return the geometric union of p1 and p2 as a `ClippedPolygon`.

Each of `p1` and `p2` may be a `GeometryEntity` or array of `GeometryEntity`. All entities
are first converted to polygons using [`to_polygons`](@ref).

Each of `p1` and `p2` can also be a `GeometryStructure` or `GeometryReference`, in which case
`elements(flatten(p))` will be converted to polygons.

Each can also be a pair `geom => layer`, where `geom` is a
`GeometryStructure` or `GeometryReference`, while `layer` is a `DeviceLayout.Meta`, a layer name `Symbol`, and/or a collection
of either, in which case only the elements in those layers will used.

This is not implemented as a method of `union` because you can have a set union of arrays of
polygons, which is a distinct operation.

The Clipper polyfill rule is PolyFillTypePositive, meaning as long as a
region lies within more non-hole (by orientation) than hole polygons, it lies
in the union.
"""
function union2d(p1, p2)
    return clip(
        Clipper.ClipTypeUnion,
        p1,
        p2,
        pfs=Clipper.PolyFillTypePositive,
        pfc=Clipper.PolyFillTypePositive
    )
end

"""
    union2d(p)

Return the geometric union of `p` or all entities in `p`.
"""
union2d(p::AbstractGeometry{T}) where {T} = union2d(p, Polygon{T}[])
union2d(p::AbstractArray) = union2d(p, Polygon{DeviceLayout.coordinatetype(p)}[])
union2d(p::Pair{<:AbstractGeometry{T}}) where {T} = union2d(p, Polygon{T}[])

"""
    difference2d(p1, p2)

Return the geometric union of `p1` minus the geometric union of `p2` as a `ClippedPolygon`.

Each of `p1` and `p2` may be a `GeometryEntity` or array of `GeometryEntity`. All entities
are first converted to polygons using [`to_polygons`](@ref).

Each of `p1` and `p2` can also be a `GeometryStructure` or `GeometryReference`, in which case
`elements(flatten(p))` will be converted to polygons.

Each can also be a pair `geom => layer`, where `geom` is a
`GeometryStructure` or `GeometryReference`, while `layer` is a `DeviceLayout.Meta`, a layer name `Symbol`, and/or a collection
of either, in which case only the elements in those layers will be used.
"""
function difference2d(plus, minus)
    return clip(
        Clipper.ClipTypeDifference,
        plus,
        minus,
        pfs=Clipper.PolyFillTypePositive,
        pfc=Clipper.PolyFillTypePositive
    )
end

"""
    intersect2d(p1, p2)

Return the geometric union of `p1` intersected with the geometric union of `p2`  as a `ClippedPolygon`.

Each of `p1` and `p2` may be a `GeometryEntity` or array of `GeometryEntity`. All entities
are first converted to polygons using [`to_polygons`](@ref).

Each of `p1` and `p2` can also be a `GeometryStructure` or `GeometryReference`, in which case
`elements(flatten(p))` will be converted to polygons.

Each can also be a pair `geom => layer`, where `geom` is a
`GeometryStructure` or `GeometryReference`, while `layer` is a `DeviceLayout.Meta`, a layer name `Symbol`, and/or a collection
of either, in which case only the elements in those layers will be used.
"""
function intersect2d(plus, minus)
    return clip(
        Clipper.ClipTypeIntersection,
        plus,
        minus,
        pfs=Clipper.PolyFillTypePositive,
        pfc=Clipper.PolyFillTypePositive
    )
end

"""
    xor2d(p1, p2)

Return the symmetric difference (XOR) of `p1` and `p2` as a `ClippedPolygon`.

The XOR operation returns regions that are in either `p1` or `p2`, but not in both.
This is useful for finding non-overlapping regions between two sets of polygons.

Each of `p1` and `p2` may be a `GeometryEntity` or array of `GeometryEntity`. All entities
are first converted to polygons using [`to_polygons`](@ref).

Each of `p1` and `p2` can also be a `GeometryStructure` or `GeometryReference`, in which case
`elements(flatten(p))` will be converted to polygons.

Each can also be a pair `geom => layer`, where `geom` is a
`GeometryStructure` or `GeometryReference`, while `layer` is a `DeviceLayout.Meta`, a layer name `Symbol`, and/or a collection
of either, in which case only the elements in those layers will be used.
"""
function xor2d(p1, p2)
    return clip(
        Clipper.ClipTypeXor,
        p1,
        p2,
        pfs=Clipper.PolyFillTypePositive,
        pfc=Clipper.PolyFillTypePositive
    )
end

function add_path!(
    c::Clipper.Clip,
    path::Vector{Point{T}},
    polyType::Clipper.PolyType,
    closed::Bool
) where {T <: Union{Int64, Unitful.Quantity{Int64}}}
    return ccall(
        (:add_path, libcclipper),
        Cuchar,
        (Ptr{Cvoid}, Ptr{Clipper.IntPoint}, Csize_t, Cint, Cuchar),
        c.clipper_ptr,
        path,
        length(path),
        Int(polyType),
        closed
    ) == 1 ? true : false
end

# Clipping two identically-typed arrays of "Int64-based" Polygons.
# Internal method which should not be called by user (but does the heavy lifting)
function _clip(
    op::Clipper.ClipType,
    s::AbstractVector{Polygon{T}},
    c::AbstractVector{Polygon{T}};
    pfs::Clipper.PolyFillType=Clipper.PolyFillTypePositive,
    pfc::Clipper.PolyFillType=Clipper.PolyFillTypePositive
) where {T <: Union{Int64, Unitful.Quantity{Int64}}}
    clip = clipper()
    Clipper.clear!(clip)
    for s0 in s
        add_path!(clip, s0.p, Clipper.PolyTypeSubject, true)
    end
    for c0 in c
        add_path!(clip, c0.p, Clipper.PolyTypeClip, true)
    end
    result =
        convert(Clipper.PolyNode{Point{Int64}}, Clipper.execute_pt(clip, op, pfs, pfc)[2])

    return ClippedPolygon(recast(Clipper.PolyNode{Point{T}}, result))
end

#    recast(::Type{Clipper.PolyNode{T}}, x::Clipper.PolyNode}) where {T}
#  Creates a `Clipper.PolyNode{T}` by reinterpreting vectors of points in `x`.
recast(::Type{Clipper.PolyNode{T}}, x::Clipper.PolyNode{T}) where {T} = x
function recast(::Type{Clipper.PolyNode{S}}, x::Clipper.PolyNode{T}) where {S, T}
    pn = Clipper.PolyNode{S}(
        reinterpret(S, Clipper.contour(x)),
        Clipper.ishole(x),
        Clipper.isopen(x)
    )
    pn.children = [recast(y, pn) for y in Clipper.children(x)]
    return pn.parent = pn
end
#    recast(x::Clipper.PolyNode, parent::Clipper.PolyNode{S}) where {S}
#  Creates a `Clipper.PolyNode{S}` from `x` given a new `parent` node.
function recast(x::Clipper.PolyNode, parent::Clipper.PolyNode{S}) where {S}
    pn = Clipper.PolyNode{S}(
        reinterpret(S, Clipper.contour(x)),
        Clipper.ishole(x),
        Clipper.isopen(x)
    )
    pn.children = [recast(y, pn) for y in Clipper.children(x)]
    pn.parent = parent
    return pn
end

#   Int64like(x::Point{T}) where {T}
#   Int64like(x::Polygon{T}) where {T}
# Converts Points or Polygons to an Int64-based representation (possibly with units).
Int64like(x::Point{T}) where {T} = convert(Point{typeof(Int64(1) * unit(T))}, x)
Int64like(x::Polygon{T}) where {T} = convert(Polygon{typeof(Int64(1) * unit(T))}, x)

#   prescale(x::Point{<:Real})
# Since the Clipper library works on Int64-based points, we multiply floating-point-based
# `x` by `10.0^9` before rounding to retain high resolution. Since` 1.0` is interpreted
# to mean `1.0 um`, this yields `fm` resolution, which is more than sufficient for most uses.
prescale(x::Point{<:Real}) = x * SCALE  # 2^29.897...

#   prescale(x::Point{<:Quantity})
# Since the Clipper library works on Int64-based points, we unit-convert `x` to `fm` before
# rounding to retain high resolution, which is more than sufficient for most uses.
prescale(x::Point{<:Quantity}) = convert(Point{typeof(USCALE)}, x)

#   clipperize(A::AbstractVector{Polygon{T}}) where {T}
#   clipperize(A::AbstractVector{Polygon{T}}) where {S<:Integer, T<:Union{S, Unitful.Quantity{S}}}
#   clipperize(A::AbstractVector{Polygon{T}}) where {T <: Union{Int64, Unitful.Quantity{Int64}}}
# Prepare a vector of Polygons for being operated upon by the Clipper library,
# which expects Int64-based points (Quantity{Int64} is okay after using `reinterpret`).
function clipperize(A::AbstractVector{Polygon{T}}) where {T}
    return [Polygon(clipperize.(points(x))) for x in A]
end

# Already Integer-based, so no need to do rounding or scaling. Just convert to Int64-like.
function clipperize(
    A::AbstractVector{Polygon{T}}
) where {S <: Integer, T <: Union{S, Unitful.Quantity{S}}}
    return Int64like.(A)
end

# Already Int64-based, so just pass through, nothing to do here.
function clipperize(
    A::AbstractVector{Polygon{T}}
) where {T <: Union{Int64, Unitful.Quantity{Int64}}}
    return A
end

function clipperize(x::Point{T}) where {S <: Real, T <: Union{S, Unitful.Quantity{S}}}
    return Int64like(unsafe_round(prescale(x)))
end
function clipperize(
    x::Point{T}
) where {S <: Integer, D, U, T <: Union{S, Unitful.Quantity{S, D, U}}}
    return Int64like(x)
end

unscale(p::Point, ::Type{T}) where {T <: Quantity} = convert(Point{T}, p)
unscale(p::Point, ::Type{T}) where {T} = convert(Point{T}, p ./ SCALE)

# Declipperize methods are used to get back to the original type.
declipperize(p, ::Type{T}) where {T} = Polygon{T}((x -> unscale(x, T)).(points(p)))
declipperize(p, ::Type{T}) where {T <: Union{Int64, Unitful.Quantity{Int64}}} =
    Polygon{T}(reinterpret(Point{T}, points(p)))

# Prepare a ClippedPolygon for use with Clipper.
function clipperize(p::ClippedPolygon)
    R = typeof(clipperize(p.tree.children[1].contour[1]))
    t = deepcopy(p.tree)
    function prescale(p::Clipper.PolyNode)
        Clipper.contour(p) .= (x -> unsafe_round(x * SCALE)).(Clipper.contour(p))
        for x in p.children
            prescale(x)
        end
    end
    prescale(t)
    x = ClippedPolygon(convert(Clipper.PolyNode{R}, t))
    return x
end
function clipperize(p::ClippedPolygon{T}) where {T <: Quantity}
    return ClippedPolygon(clipperize(p.tree))
end

# Prepare the data within a Clipper.PolyNode for use with Clipper.
function clipperize(p::Clipper.PolyNode)
    # Create a tree by clipperizing contours recursively.
    function buildtree(p)
        T = typeof(clipperize.(p.contour)).parameters[1]
        return Clipper.PolyNode{T}(
            clipperize.(p.contour),
            p.hole,
            p.open,
            buildtree.(p.children)
        )
    end
    t = buildtree(p)

    # Inform children of their heritage.
    function labelchildren(node, parent)
        for c ∈ node.children
            c.parent = parent
            labelchildren(c, node)
        end
    end
    labelchildren(t, t)
    return t
end

# Convert a "clipperized" ClippedPolygon to a given type.
# Real valued clipping: convert the integer value back to float by dividing.
function declipperize(p::ClippedPolygon, ::Type{T}) where {T}
    x = ClippedPolygon(convert(Clipper.PolyNode{Point{T}}, p.tree))
    function unscale(p::Clipper.PolyNode)
        Clipper.contour(p) .= (x -> x / SCALE).(Clipper.contour(p))
        for x in p.children
            unscale(x)
        end
    end
    unscale(x.tree)
    return x
end
# Unitful quantities and integers use conversion directly. Extra methods resolve type
# ambiguities for aqua.
function declipperize(
    p::ClippedPolygon{T},
    ::Type{T}
) where {T <: Union{Int, Quantity{Int}}}
    return ClippedPolygon(convert(Clipper.PolyNode{Point{T}}, p.tree))
end
function declipperize(p::ClippedPolygon, ::Type{T}) where {T <: Union{Int, Quantity{Int}}}
    return ClippedPolygon(convert(Clipper.PolyNode{Point{T}}, p.tree))
end
function declipperize(p::ClippedPolygon{<:Quantity}, ::Type{T}) where {T}
    return ClippedPolygon(convert(Clipper.PolyNode{Point{T}}, p.tree))
end
function declipperize(
    p::ClippedPolygon{<:Quantity},
    ::Type{T}
) where {T <: Union{Int, Quantity{Int}}}
    return ClippedPolygon(convert(Clipper.PolyNode{Point{T}}, p.tree))
end

"""
    offset(s::AbstractPolygon{T}, delta::Coordinate;
        j::Clipper.JoinType=Clipper.JoinTypeMiter,
        e::Clipper.EndType=Clipper.EndTypeClosedPolygon) where {T <: Coordinate}
    offset(s::AbstractVector{A}, delta::Coordinate;
        j::Clipper.JoinType=Clipper.JoinTypeMiter,
        e::Clipper.EndType=Clipper.EndTypeClosedPolygon) where {T, A <: AbstractPolygon{T}}
    offset(s::AbstractVector{Polygon{T}}, delta::T;
        j::Clipper.JoinType=Clipper.JoinTypeMiter,
        e::Clipper.EndType=Clipper.EndTypeClosedPolygon) where {T <: Coordinate}

Using the [`Clipper`](http://www.angusj.com/delphi/clipper.php) library and
the [`Clipper.jl`](https://github.com/Voxel8/Clipper.jl) wrapper, perform
polygon offsetting.

The orientations of polygons must be consistent, such that outer polygons share the same
orientation, and any holes have the opposite orientation. Additionally, any holes should be
contained within outer polygons; offsetting hole edges may create positive artifacts at
corners.

The first argument should be an [`AbstractPolygon`](@ref). The second argument
is how much to offset the polygon. Keyword arguments include a
[join type](http://www.angusj.com/delphi/clipper/documentation/Docs/Units/ClipperLib/Types/JoinType.htm):

  - `Clipper.JoinTypeMiter`
  - `Clipper.JoinTypeRound`
  - `Clipper.JoinTypeSquare`

and also an
[end type](http://www.angusj.com/delphi/clipper/documentation/Docs/Units/ClipperLib/Types/EndType.htm):

  - `Clipper.EndTypeClosedPolygon`
  - `Clipper.EndTypeClosedLine`
  - `Clipper.EndTypeOpenSquare`
  - `Clipper.EndTypeOpenRound`
  - `Clipper.EndTypeOpenButt`
"""
function offset end

function offset(
    s::AbstractPolygon{T},
    delta::Coordinate;
    j::Clipper.JoinType=Clipper.JoinTypeMiter,
    e::Clipper.EndType=Clipper.EndTypeClosedPolygon
) where {T <: Coordinate}
    dimension(T) != dimension(delta) && throw(Unitful.DimensionError(oneunit(T), delta))
    S = promote_type(T, typeof(delta))
    return offset(Polygon{S}[s], convert(S, delta); j=j, e=e)
end

function offset(
    s::AbstractVector{A},
    delta::Coordinate;
    j::Clipper.JoinType=Clipper.JoinTypeMiter,
    e::Clipper.EndType=Clipper.EndTypeClosedPolygon
) where {T, A <: AbstractPolygon{T}}
    dimension(T) != dimension(delta) && throw(Unitful.DimensionError(oneunit(T), delta))
    S = promote_type(T, typeof(delta))

    mask = typeof.(s) .<: ClippedPolygon
    return offset(
        convert(
            Vector{Polygon{S}},
            [s[.!mask]..., reduce(vcat, to_polygons.(s[mask]); init=Polygon{S}[])...]
        ),
        convert(S, delta);
        j=j,
        e=e
    )
end

prescaledelta(x::Real) = x * SCALE
prescaledelta(x::Integer) = x
prescaledelta(x::Length{<:Real}) = convert(typeof(USCALE), x)
prescaledelta(x::Length{<:Integer}) = x

function offset(
    s::AbstractVector{Polygon{T}},
    delta::T;
    j::Clipper.JoinType=Clipper.JoinTypeMiter,
    e::Clipper.EndType=Clipper.EndTypeClosedPolygon
) where {T <: Coordinate}
    sc = clipperize(s)
    d = prescaledelta(delta)
    polys = _offset(sc, d, j=j, e=e)
    return declipperize.(polys, T)
end

function offset(
    s::ClippedPolygon,
    delta::T;
    j::Clipper.JoinType=Clipper.JoinTypeMiter,
    e::Clipper.EndType=Clipper.EndTypeClosedPolygon
) where {T <: Coordinate}
    return offset(to_polygons(s), delta, j=j, e=e)
end

function add_path!(
    c::Clipper.ClipperOffset,
    path::Vector{Point{T}},
    joinType::Clipper.JoinType,
    endType::Clipper.EndType
) where {T <: Union{Int64, Unitful.Quantity{Int64}}}
    return ccall(
        (:add_offset_path, libcclipper),
        Cvoid,
        (Ptr{Cvoid}, Ptr{Clipper.IntPoint}, Csize_t, Cint, Cint),
        c.clipper_ptr,
        path,
        length(path),
        Int(joinType),
        Int(endType)
    )
end

function _offset(
    s::AbstractVector{Polygon{T}},
    delta;
    j::Clipper.JoinType=Clipper.JoinTypeMiter,
    e::Clipper.EndType=Clipper.EndTypeClosedPolygon
) where {T <: Union{Int64, Unitful.Quantity{Int64}}}
    c = coffset()
    Clipper.clear!(c)
    for s0 in s
        add_path!(c, s0.p, j, e)
    end
    result = Clipper.execute(c, Float64(ustrip(delta))) #TODO: fix in clipper
    polys = [Polygon(reinterpret(Point{T}, p)) for p in result]
    # Fast path: single or zero contours cannot contain holes
    if length(polys) <= 1
        return polys
    end
    # Check whether Clipper returned mixed orientations (holes among outer contours).
    # CW contours are holes in Clipper's convention; CCW are outer boundaries.
    orientations = [orientation(p) for p in polys]
    if all(==(first(orientations)), orientations)
        return polys  # All same orientation — no holes
    end
    # Mixed orientations mean holes are present — recombine via union2d so that the
    # PolyTree keeps hole topology, then flatten back to Polygons with interior cuts.
    return to_polygons(union2d(polys))
end

### cutting algorithm
"""
    uniqueray(v::Vector{Point{T}}) where {T <: Real}

Given an array of points (thought to indicate a polygon or a hole in a polygon),
find the lowest / most negative y-coordinate[s] `miny`, then the lowest / most negative
x-coordinate `minx` of the points having that y-coordinate. This `Point(minx,miny)` ∈ `v`.
Return a ray pointing in -ŷ direction from that point.
"""
function uniqueray(v::Vector{Point{T}}) where {T <: Real}
    nopts = reinterpret(T, v)
    yarr = view(nopts, 2:2:length(nopts))
    miny, indy = findmin(yarr)
    xarr = view(nopts, (findall(x -> x == miny, yarr) .* 2) .- 1)
    minx, indx = findmin(xarr)
    indv = findall(x -> x == Point(minx, miny), v)[1]
    return Ray(Point(minx, miny), Point(minx, miny - 1)), indv
end

mutable struct InteriorCutNode{T}
    point::T
    prev::InteriorCutNode{T}
    next::InteriorCutNode{T}

    InteriorCutNode{T}(point, prev, next) where {T} = new{T}(point, prev, next)
    function InteriorCutNode{T}(point) where {T}
        node = new{T}(point)
        node.prev = node
        node.next = node
        return node
    end
end
segment(n::InteriorCutNode) = LineSegment(n.point, n.next.point)

InteriorCutNode(val::T) where {T} = InteriorCutNode{T}(val)

"""
    interiorcuts(nodeortree::Clipper.PolyNode, outpolys::Vector{Polygon{T}}) where {T}

Clipper gives polygons with holes as separate contours. The GDSII format doesn't support
this. This function makes cuts between the inner/outer contours so that ultimately there
is just one contour with one or more overlapping edges.

Example:
┌────────────┐               ┌────────────┐
│ ┌──┐       │   becomes...  │ ┌──┐       │
│ └──┘  ┌──┐ │               │ ├──┘  ┌──┐ │
│       └──┘ │               │ │     ├──┘ │
└────────────┘               └─┴─────┴────┘
"""
function interiorcuts(nodeortree::Clipper.PolyNode, outpolys::Vector{Polygon{T}}) where {T}
    # Assumes we have first element an enclosing polygon with the rest being holes.
    # We also assume no hole collision.

    minpt = Point(-Inf, -Inf)
    for enclosing in children(nodeortree)
        enclosing_contour = contour(enclosing)

        # If a contour is empty, the PolyNode is effectively removed. This also effectively
        # removes any further nodes, as they are no longer well defined.
        isempty(enclosing_contour) && continue

        # No need to copy a large array of points, make a view giving line segments.
        segs = LineSegmentView(enclosing_contour)

        # note to self: the problem has to do with segments reordering points...

        # Construct an interval tree of the x-extents of each line segment.
        arr = reshape(reinterpret(Int, xinterval.(segs)), 2, :)
        nodes = map(InteriorCutNode, enclosing_contour)
        node1 = first(nodes)
        for i in eachindex(nodes)
            i == firstindex(nodes) || (nodes[i].prev = nodes[i - 1])
            i == lastindex(nodes) || (nodes[i].next = nodes[i + 1])
        end
        IVT = IntervalValue{Int, InteriorCutNode{Point{Int}}}
        iv = sort!(IVT.(view(arr, 1, :), view(arr, 2, :), nodes))
        itree = IntervalTree{Int, IVT}()
        for v in iv
            # We should be able to to bulk insertion, but it appears like this
            # results in some broken trees for large enough initial insertion.
            # see comments in merge request 21.
            push!(itree, v)
        end
        loop_node = InteriorCutNode(enclosing_contour[1])
        loop_node.prev = last(nodes)
        last(nodes).next = loop_node

        for hole in sort(children(enclosing), by=h -> uniqueray(contour(h))[1].p0.y)
            # process all the holes.
            interiorcuts(hole, outpolys)

            # Intersect the unique ray with the line segments of the polygon.
            hole_contour = contour(hole)
            ray, m = uniqueray(hole_contour)
            x0 = ray.p0.x

            # Find nearest intersection of the ray with the enclosing polygon.
            best_intersection_point = minpt
            local best_node

            # See which segments could possibly intersect with a line defined by `x = x0`
            for interval in IntervalTrees.intersect(itree, (x0, x0))
                # Retrieve the segment index from the node.
                node = IntervalTrees.value(interval)
                seg = segment(node)

                # this is how we'll mark a "deleted" segment even though we don't
                # actually remove it from the interval tree
                (node.prev == node) && (node.next == node) && continue

                # See if it actually intersected with the segment
                intersected, intersection_point = intersection(ray, seg)
                if intersected
                    if gety(intersection_point) > gety(best_intersection_point)
                        best_intersection_point = intersection_point
                        best_node = node
                    end
                end
            end

            # Since the polygon was enclosing, an intersection had to happen *somewhere*.
            if best_intersection_point != minpt
                w = Point{Int64}(
                    round(getx(best_intersection_point)),
                    round(gety(best_intersection_point))
                )

                # We are going to replace `best_node`
                # need to do all of the following...
                last_node = best_node.next
                n0 = best_node.prev

                first_node = InteriorCutNode(best_node.point)
                first_node.prev = n0
                n0.next = first_node
                n0, p0 = first_node, w

                for r in (m:length(hole_contour), 1:m)
                    for i in r
                        n = InteriorCutNode(p0)
                        n.prev = n0
                        n0.next = n
                        push!(itree, IntervalValue(xinterval(segment(n0))..., n0))
                        n0, p0 = n, hole_contour[i]
                    end
                end

                n = InteriorCutNode(p0)
                n.prev = n0
                n0.next = n
                push!(itree, IntervalValue(xinterval(segment(n0))..., n0))
                n0, p0 = n, w

                n = InteriorCutNode(p0)
                n.prev = n0
                n0.next = n
                push!(itree, IntervalValue(xinterval(segment(n0))..., n0))

                n.next = last_node
                last_node.prev = n
                push!(itree, IntervalValue(xinterval(segment(n))..., n))

                # serving the purpose of delete!(itree, best_node)
                best_node.prev = best_node
                best_node.next = best_node

                # in case we deleted node1...
                if best_node === node1
                    node1 = first_node
                end
            end
        end
        n = node1
        p = Point{Int}[]
        while n.next != n
            push!(p, n.point)
            n = n.next
        end
        push!(outpolys, Polygon(reinterpret(Point{T}, p)))
    end
    return outpolys
end

xinterval(l::LineSegment) = (l.p0.x, l.p1.x)
yinterval(l::LineSegment) = swap((l.p0.y, l.p1.y))
swap(x) = x[1] > x[2] ? (x[2], x[1]) : x

### Layerwise
function xor2d_layerwise(obj::GeometryStructure, tool::GeometryStructure; kwargs...)
    return clip_layerwise(Clipper.ClipTypeXor, obj, tool; kwargs...)
end

function difference2d_layerwise(obj::GeometryStructure, tool::GeometryStructure; kwargs...)
    return clip_layerwise(Clipper.ClipTypeDifference, obj, tool; kwargs...)
end

function intersect2d_layerwise(obj::GeometryStructure, tool::GeometryStructure; kwargs...)
    return clip_layerwise(Clipper.ClipTypeIntersection, obj, tool; kwargs...)
end

function union2d_layerwise(obj::GeometryStructure, tool::GeometryStructure; kwargs...)
    return clip_layerwise(Clipper.ClipTypeUnion, obj, tool; kwargs...)
end

for func in ("union2d", "difference2d", "intersect2d", "xor2d")
    func_layerwise = Symbol(string(func) * "_layerwise")
    doc = """
        $(func)_layerwise(obj::GeometryStructure, tool::GeometryStructure;
            only_layers=[],
            ignore_layers=[],
            depth=-1,
            tiled=false,
            tile_size=nothing
        )

    Return a `Dict` of `meta => [$(func)(obj => meta, tool => meta)]` for each unique element metadata `meta` in `obj` and `tool`.

    Entities with metadata matching `only_layers` or `ignore_layers` are included or excluded based on [`layer_inclusion`](@ref).

    Entities in references up to a depth of `depth` are included, where `depth=0` uses only top-level entities in `obj` and `tool`.
    Depth is unlimited by default.

    See also [`$(func)`](@ref).

    # Tiling

    Using `tiled=true` or manually setting a `tile_size` can significantly speed up operations and reduce maximum memory usage for large geometries.
    It does this by breaking up the geometry into smaller portions ("tiles") and operating on them one at a time.

    If a length is provided to `tile_size`, the bounds of the combined geometries are tiled with squares with that
    edge length, starting from the lower left corner.

    If `tiled` is `true` but `tile_size` is not specified, a tile size will be set automatically based on the total number of entities in the operation,
    such that there is about one square tile per 100 entities. This is usually a reasonable choice, but you may want to benchmark your use case.

    Entities crossing between tiles are split into their intersections with each tile before clipping.
    For each tile, those intersection results and all entities inside that tile are selected.
    The values for each layer in the returned `Dict` are then lazy iterators over clipping results for
    selected entities in each tile.
    """
    eval(quote
        @doc $doc $func_layerwise
    end)
end

function clip_layerwise(
    op::Clipper.ClipType,
    obj::GeometryStructure,
    tool::GeometryStructure;
    only_layers=[],
    ignore_layers=[],
    tiled=false,
    tile_size=nothing,
    depth=-1,
    pfs=Clipper.PolyFillTypePositive,
    pfc=Clipper.PolyFillTypePositive
)
    metadata_filter = DeviceLayout.layer_inclusion(only_layers, ignore_layers)
    if metadata_filter == DeviceLayout.trivial_inclusion
        metadata_filter = nothing
    end
    obj_flat = DeviceLayout.flatten(obj; metadata_filter, depth)
    tool_flat = DeviceLayout.flatten(tool; metadata_filter, depth)
    obj_metas = unique(DeviceLayout.element_metadata(obj_flat))
    tool_metas = unique(DeviceLayout.element_metadata(tool_flat))
    all_metas = unique([obj_metas; tool_metas])
    if !tiled && isnothing(tile_size)
        res = Dict(
            meta => [
                clip(
                    op,
                    DeviceLayout.elements(obj_flat)[DeviceLayout.element_metadata(
                        obj_flat
                    ) .== meta],
                    DeviceLayout.elements(tool_flat)[DeviceLayout.element_metadata(
                        tool_flat
                    ) .== meta],
                    pfs=pfs,
                    pfc=pfc
                )
            ] for meta in all_metas
        )
    else
        res = Dict(
            meta => clip_tiled(
                op,
                DeviceLayout.elements(obj_flat)[DeviceLayout.element_metadata(
                    obj_flat
                ) .== meta],
                DeviceLayout.elements(tool_flat)[DeviceLayout.element_metadata(
                    tool_flat
                ) .== meta],
                tile_size,
                pfs=pfs,
                pfc=pfc
            ) for meta in all_metas
        )
    end
    return res
end

### Tiling
function tiles_and_edges(r::Rectangle, tile_size)
    nx = ceil(width(r) / tile_size)
    ny = ceil(height(r) / tile_size)
    tile0 = r.ll + Rectangle(tile_size, tile_size)
    tiles =
        [tile0 + Point((i - 1) * tile_size, (j - 1) * tile_size) for i = 1:nx for j = 1:ny]
    h_edges = [
        Rectangle(
            Point(r.ll.x, r.ll.y + (i - 1) * tile_size),
            Point(r.ur.x, r.ll.y + (i - 1) * tile_size)
        ) for i = 2:ny
    ]
    v_edges = [
        Rectangle(
            Point(r.ll.x + (i - 1) * tile_size, r.ll.y),
            Point(r.ll.x + (i - 1) * tile_size, r.ur.y)
        ) for i = 2:nx
    ]
    return tiles, vcat(h_edges, v_edges) # Edges could be used for healing
end

function _auto_tile_size(bnds::Rectangle, num_ents)
    target_ents_per_tile = 100
    target_num_tiles = max(1.0, round(num_ents / target_ents_per_tile))
    target_size = sqrt(width(bnds) * height(bnds) / target_num_tiles)
    # Return the closest tile size that evenly divides width
    return width(bnds) / max(1.0, round(width(bnds) / target_size))
end

"""
    function clip_tiled(
        op,
        ents1::AbstractArray{<:GeometryEntity{T}},
        ents2::AbstractArray{<:GeometryEntity{T}},
        tile_size=nothing;
        pfs=Clipper.PolyFillTypePositive,
        pfc=Clipper.PolyFillTypePositive
    )

Return a lazy iterator that applies `op(ents1, ents2)` tile by tile.

The bounds of the combined geometries are tiled with squares with edge length `tile_size`, starting at the bottom left
corner. Entities crossing between tiles are split into their intersections with each tile before clipping.
For each tile, those intersection results and all entities inside that tile are selected.
The return value is a lazy iterator over clipping results for selected entities per tile.

A rough guideline for choosing tile size is to aim for 100 polygons per tile, but you may want to
benchmark your use case. If an explicit tile size is not provided, then tile size will be set automatically
based on the total number of entities in the operation, such that there is about one square tile per 100 entities.
"""
function clip_tiled(
    op,
    ents1::AbstractArray{<:GeometryEntity{T}},
    ents2::AbstractArray{<:GeometryEntity{T}},
    tile_size=nothing;
    pfs=Clipper.PolyFillTypePositive,
    pfc=Clipper.PolyFillTypePositive
) where {T}
    (isempty(ents1) && isempty(ents2)) &&
        return Iterators.map(identity, ClippedPolygon{T}[])
    # Create spatial index for each set of polygons
    if isempty(ents2)
        tree1 = DeviceLayout.mbr_spatial_index(ents1)
        bnds = mbr(tree1)
    elseif isempty(ents1)
        tree2 = DeviceLayout.mbr_spatial_index(ents2)
        bnds = mbr(tree2)
    else
        tree1 = DeviceLayout.mbr_spatial_index(ents1)
        tree2 = DeviceLayout.mbr_spatial_index(ents2)
        bnds = SpatialIndexing.combine(mbr(tree1), mbr(tree2))
    end

    # Get tiles and indices of polygons intersecting tiles
    bnds_dl = Rectangle(
        Point(bnds.low...) * DeviceLayout.onemicron(T),
        Point(bnds.high...) * DeviceLayout.onemicron(T)
    )

    if isnothing(tile_size)
        tile_size = _auto_tile_size(bnds_dl, length(ents1) + length(ents2))
    end

    tiles, edges = tiles_and_edges(bnds_dl, tile_size) # DeviceLayout Rectangles
    # Get single vector of all entity indices touching any edge
    edge_touching_idx1 = Set( # Use Set because we'll be testing membership
        mapreduce(vcat, edges, init=Int[]) do edge
            return isempty(ents1) ? Int[] : DeviceLayout.findbox(edge, tree1; intersects=true)
        end
    )
    # Same for ents2
    edge_touching_idx2 = Set(
        mapreduce(vcat, edges, init=Int[]) do edge
            return isempty(ents2) ? Int[] : DeviceLayout.findbox(edge, tree2; intersects=true)
        end
    )
    # Get vector of (ents1 indices, ents2 indices) for each tile
    tile_poly_indices = map(tiles) do tile
        idx1 = isempty(ents1) ? Int[] : DeviceLayout.findbox(tile, tree1; intersects=true)
        idx2 =
            isempty(ents2) ? Int[] : DeviceLayout.findbox(tile, tree2; intersects=true)
        return (idx1, idx2)
    end
    # Clip within each tile
    res = Iterators.map(enumerate(tile_poly_indices)) do (tile_idx, poly_idxs)
        idx1, idx2 = poly_idxs
        # If an entity is touching a tile edge, clip it to the tile with intersect2d
        idx1_on_edge = in.(idx1, Ref(edge_touching_idx1))
        idx2_on_edge = in.(idx2, Ref(edge_touching_idx2))
        edge_idx1 = idx1[idx1_on_edge]
        bulk_idx1 = idx1[(!).(idx1_on_edge)]
        edge_idx2 = idx2[idx2_on_edge]
        bulk_idx2 = idx2[(!).(idx2_on_edge)]
        tile = tiles[tile_idx]
        ents1_clipped_to_tile =
            vcat(ents1[bulk_idx1], intersect2d(tile, ents1[edge_idx1]))
        ents2_clipped_to_tile =
            vcat(ents2[bulk_idx2], intersect2d(tile, ents2[edge_idx2]))
        return clip(op, ents1_clipped_to_tile, ents2_clipped_to_tile; pfs, pfc)
    end
    return res
end
