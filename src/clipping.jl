# Clipping polygons one at a time
"""
    clip(op::Clipper.ClipType, s, c; kwargs...) where {S<:Coordinate, T<:Coordinate}
    clip(op::Clipper.ClipType, s::AbstractVector{A}, c::AbstractVector{B};
        kwargs...) where {S, T, A<:Polygon{S}, B<:Polygon{T}}
    clip(op::Clipper.ClipType,
        s::AbstractVector{Polygon{T}}, c::AbstractVector{Polygon{T}};
        pfs::Clipper.PolyFillType=Clipper.PolyFillTypeEvenOdd,
        pfc::Clipper.PolyFillType=Clipper.PolyFillTypeEvenOdd) where {T}

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
_normalize_clip_arg(p::AbstractArray{Polygon{T}}) where {T} = p
_normalize_clip_arg(p::AbstractArray{<:GeometryEntity{T}}) where {T} =
    reduce(vcat, to_polygons.(p); init=Polygon{T}[])
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
    pfs::Clipper.PolyFillType=Clipper.PolyFillTypeEvenOdd,
    pfc::Clipper.PolyFillType=Clipper.PolyFillTypeEvenOdd,
    tiled=false
) where {T}
    sc, cc = clipperize(s), clipperize(c)
    polys = if !tiled
        _clip(op, sc, cc; pfs, pfc)
    else
        _clip_tiled(op, sc, cc; pfs, pfc)
    end
    return declipperize(polys, T)
end

"""
    cliptree(op::Clipper.ClipType, s::AbstractPolygon{S}, c::AbstractPolygon{T};
        kwargs...) where {S<:Coordinate, T<:Coordinate}
    cliptree(op::Clipper.ClipType, s::AbstractVector{A}, c::AbstractVector{B};
        kwargs...) where {S, T, A<:AbstractPolygon{S}, B<:AbstractPolygon{T}}
    cliptree(op::Clipper.ClipType,
        s::AbstractVector{Polygon{T}}, c::AbstractVector{Polygon{T}};
        pfs::Clipper.PolyFillType=Clipper.PolyFillTypeEvenOdd,
        pfc::Clipper.PolyFillType=Clipper.PolyFillTypeEvenOdd) where {T}

Return a `Clipper.PolyNode` representing parent-child relationships between polygons and
interior holes. The units and number type may need to be converted.

Uses the [`Clipper`](http://www.angusj.com/delphi/clipper.php) library and the
[`Clipper.jl`](https://github.com/Voxel8/Clipper.jl) wrapper to perform polygon clipping.

## Positional arguments

The first argument must be one of the following types to specify a clipping operation:

  - `Clipper.ClipTypeDifference`
  - `Clipper.ClipTypeIntersection`
  - `Clipper.ClipTypeUnion`
  - `Clipper.ClipTypeXor`

Note that these are types; you should not follow them with `()`. The second and third
arguments are `AbstractPolygon`s or vectors thereof.

## Keyword arguments

`pfs` and `pfc` specify polygon fill rules for the `s` and `c` arguments, respectively.
These arguments may include:

  - `Clipper.PolyFillTypeNegative`
  - `Clipper.PolyFillTypePositive`
  - `Clipper.PolyFillTypeEvenOdd`
  - `Clipper.PolyFillTypeNonZero`

See the [`Clipper` docs](http://www.angusj.com/delphi/clipper/documentation/Docs/Units/ClipperLib/Types/PolyFillType.htm)
for further information.
"""
function cliptree(
    op::Clipper.ClipType,
    s::AbstractPolygon{S},
    c::AbstractPolygon{T};
    kwargs...
) where {S <: Coordinate, T <: Coordinate}
    dimension(S) != dimension(T) && throw(Unitful.DimensionError(oneunit(S), oneunit(T)))
    R = promote_type(S, T)
    return cliptree(op, Polygon{R}[s], Polygon{R}[c]; kwargs...)::Vector{Polygon{R}}
end

function cliptree(
    op::Clipper.ClipType,
    s::AbstractVector{A},
    c::AbstractVector{B};
    kwargs...
) where {S, T, A <: AbstractPolygon{S}, B <: AbstractPolygon{T}}
    dimension(S) != dimension(T) && throw(Unitful.DimensionError(oneunit(S), oneunit(T)))
    R = promote_type(S, T)
    return cliptree(
        op,
        convert(Vector{Polygon{R}}, s),
        convert(Vector{Polygon{R}}, c);
        kwargs...
    )::Vector{Polygon{R}}
end

function cliptree(
    op::Clipper.ClipType,
    s::AbstractVector{Polygon{T}},
    c::AbstractVector{Polygon{T}};
    pfs::Clipper.PolyFillType=Clipper.PolyFillTypeEvenOdd,
    pfc::Clipper.PolyFillType=Clipper.PolyFillTypeEvenOdd
) where {T}
    sc, cc = clipperize(s), clipperize(c)
    cpoly = _clip(op, sc, cc; pfs, pfc)
    return declipperize(cpoly, T).tree
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
    pfs::Clipper.PolyFillType=Clipper.PolyFillTypeEvenOdd,
    pfc::Clipper.PolyFillType=Clipper.PolyFillTypeEvenOdd
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
    offset{S<:Coordinate}(s::AbstractPolygon{S}, delta::Coordinate;
        j::Clipper.JoinType=Clipper.JoinTypeMiter,
        e::Clipper.EndType=Clipper.EndTypeClosedPolygon)
    offset{S<:AbstractPolygon}(subject::AbstractVector{S}, delta::Coordinate;
        j::Clipper.JoinType=Clipper.JoinTypeMiter,
        e::Clipper.EndType=Clipper.EndTypeClosedPolygon)
    offset{S<:Polygon}(s::AbstractVector{S}, delta::Coordinate;
        j::Clipper.JoinType=Clipper.JoinTypeMiter,
        e::Clipper.EndType=Clipper.EndTypeClosedPolygon)

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
    return [Polygon(reinterpret(Point{T}, p)) for p in result]
end

"""
    orientation(p::Polygon)

Return 1 if the points in the polygon contour are going counter-clockwise, -1 if clockwise.
Clipper considers clockwise-oriented polygons to be holes for some polygon fill types.
"""
function orientation(p::Polygon)
    return ccall(
        (:orientation, libcclipper),
        Cuchar,
        (Ptr{Clipper.IntPoint}, Csize_t),
        reinterpret(Clipper.IntPoint, clipperize.(p.p)),
        length(p.p)
    ) == 1 ? 1 : -1
end

"""
    ishole(p::Polygon)

Return `true` if Clipper would consider this polygon to be a hole, for applicable
polygon fill rules.
"""
ishole(p::Polygon) = orientation(p) == -1

"""
    orientation(p1::Point, p2::Point, p3::Point)

Return 1 if the path `p1`--`p2`--`p3` is going counter-clockwise (increasing angle),
-1 if the path is going clockwise (decreasing angle), 0 if `p1`, `p2`, `p3` are colinear.
"""
function orientation(p1::Point, p2::Point, p3::Point)
    return sign((p3.y - p2.y) * (p2.x - p1.x) - (p2.y - p1.y) * (p3.x - p2.x))
end

### cutting algorithm

abstract type D1{T} end
Δy(d1::D1) = d1.p1.y - d1.p0.y
Δx(d1::D1) = d1.p1.x - d1.p0.x

ab(p0, p1) = Point(gety(p1) - gety(p0), getx(p0) - getx(p1))

"""
    LineSegment{T} <: D1{T}

Represents a line segment. By construction, `p0.x <= p1.x`.
"""
struct LineSegment{T} <: D1{T}
    p0::Point{T}
    p1::Point{T}
    function LineSegment(p0::Point{T}, p1::Point{T}) where {T}
        if p1.x < p0.x
            return new{T}(p1, p0)
        else
            return new{T}(p0, p1)
        end
    end
end
LineSegment(p0::Point{S}, p1::Point{T}) where {S, T} = LineSegment(promote(p0, p1)...)

struct LineSegmentView{T} <: AbstractVector{T}
    v::Vector{Point{T}}
end
Base.size(v::LineSegmentView) = size(v.v)
Base.length(v::LineSegmentView) = length(v.v)
Base.firstindex(v::LineSegmentView) = firstindex(v.v)
Base.lastindex(v::LineSegmentView) = lastindex(v.v)
function Base.getindex(v::LineSegmentView, i)
    @boundscheck checkbounds(v.v, i)
    return LineSegment(v.v[i], v.v[ifelse(i == length(v), 1, i + 1)])
end

"""
    Ray{T} <: D1{T}

Represents a ray. The ray starts at `p0` and goes toward `p1`.
"""
struct Ray{T} <: D1{T}
    p0::Point{T}
    p1::Point{T}
end
Ray(p0::Point{S}, p1::Point{T}) where {S, T} = Ray(promote(p0, p1)...)

struct Line{T} <: D1{T}
    p0::Point{T}
    p1::Point{T}
end
Line(p0::Point{S}, p1::Point{T}) where {S, T} = Line(promote(p0, p1)...)
Line(seg::LineSegment) = Line(seg.p0, seg.p1)

Base.promote_rule(::Type{Line{S}}, ::Type{Line{T}}) where {S, T} = Line{promote_type(S, T)}
Base.convert(::Type{Line{S}}, L::Line) where {S} = Line{S}(L.p0, L.p1)

"""
    segmentize(vertices, closed=true)

Make an array of `LineSegment` out of an array of points. If `closed`, a segment should go
between the first and last point, otherwise nah.
"""
function segmentize(vertices, closed=true)
    l = length(vertices)
    if closed
        return [LineSegment(vertices[i], vertices[i == l ? 1 : i + 1]) for i = 1:l]
    else
        return [LineSegment(vertices[i], vertices[i + 1]) for i = 1:(l - 1)]
    end
end

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

isparallel(A::D1, B::D1) = Δy(A) * Δx(B) == Δy(B) * Δx(A)
isdegenerate(A::D1, B::D1) =
    orientation(A.p0, A.p1, B.p0) == orientation(A.p0, A.p1, B.p1) == 0
iscolinear(A::D1, B::Point) = orientation(A.p0, A.p1, B) == orientation(B, A.p1, A.p0) == 0
iscolinear(A::Point, B::D1) = iscolinear(B, A)

"""
    intersects(A::LineSegment, B::LineSegment)

Return two `Bool`s:

 1. Does `A` intersect `B`?
 2. Did an intersection happen at a single point? (`false` if no intersection)
"""
function intersects(A::LineSegment, B::LineSegment)
    sb0 = orientation(A.p0, A.p1, B.p0)
    sb1 = orientation(A.p0, A.p1, B.p1)
    sb = sb0 == sb1

    sa0 = orientation(B.p0, B.p1, A.p0)
    sa1 = orientation(B.p0, B.p1, A.p1)
    sa = sa0 == sa1

    if sa == false && sb == false
        return true, true
    else
        # Test for special case of colinearity
        if sb0 == sb1 == sa0 == sa1 == 0
            y0, y1 = minmax(A.p0.y, A.p1.y)
            xinter = intersect(A.p0.x .. A.p1.x, B.p0.x .. B.p1.x)
            yinter = intersect(A.p0.y .. A.p1.y, B.p0.y .. B.p1.y)
            if !isempty(xinter) && !isempty(yinter)
                if reduce(==, endpoints(xinter)) && reduce(==, endpoints(yinter))
                    return true, true
                else
                    return true, false
                end
            else
                return false, false
            end
        else
            return false, false
        end
    end
end

"""
    intersects_at_endpoint(A::LineSegment, B::LineSegment)

Return three `Bool`s:

 1. Does `A` intersect `B`?
 2. Did an intersection happen at a single point? (`false` if no intersection)
 3. Did an endpoint of `A` intersect an endpoint of `B`?
"""
function intersects_at_endpoint(A::LineSegment, B::LineSegment)
    A_intersects_B, atapoint = intersects(A, B)
    if A_intersects_B
        if atapoint
            if (A.p1 == B.p0) || (A.p1 == B.p1) || (A.p0 == B.p0) || (A.p0 == B.p1)
                return A_intersects_B, atapoint, true
            else
                return A_intersects_B, atapoint, false
            end
        else
            return A_intersects_B, atapoint, false
        end
    else
        return A_intersects_B, atapoint, false
    end
end

"""
    intersects(p::Point, A::Ray)

Does `p` intersect `A`?
"""
function intersects(p::Point, A::Ray)
    correctdir = sign(dot(A.p1 - A.p0, p - A.p0)) >= 0
    return iscolinear(p, A) && correctdir
end

"""
    in_bounds(p::Point, A::Ray)

Is `p` in the halfspace defined by `A`?
"""
function in_bounds(p::Point, A::Ray)
    return sign(dot(A.p1 - A.p0, p - A.p0)) >= 0
end

"""
    intersects(p::Point, A::LineSegment)

Does `p` intersect `A`?
"""
function intersects(p::Point, A::LineSegment)
    if iscolinear(p, A)
        y0, y1 = minmax(A.p0.y, A.p1.y)
        xinter = intersect(A.p0.x .. A.p1.x, p.x .. p.x)
        yinter = intersect(y0 .. y1, p.y .. p.y)
        if !isempty(xinter) && !isempty(yinter)
            return true
        else
            return false
        end
    else
        return false
    end
end

"""
    in_bounds(p::Point, A::LineSegment)

Is `p` in the rectangle defined by the endpoints of `A`?
"""
function in_bounds(p::Point, A::LineSegment)
    y0, y1 = minmax(A.p0.y, A.p1.y)
    xinter = intersect(A.p0.x .. A.p1.x, p.x .. p.x)
    yinter = intersect(y0 .. y1, p.y .. p.y)
    return !isempty(xinter) && !isempty(yinter)
end

function intersection(A::Ray{T}, B::LineSegment{T}) where {T}
    fT = float(T)
    if isparallel(A, B)
        if isdegenerate(A, B)
            # correct direction?
            dist0 = dot(A.p1 - A.p0, B.p0 - A.p0)
            dist1 = dot(A.p1 - A.p0, B.p1 - A.p0)
            if sign(dist0) >= 0
                if sign(dist1) >= 0
                    # Both in correct direction
                    return true, Point{fT}(min(dist0, dist1) == dist0 ? B.p0 : B.p1)
                else
                    return true, Point{fT}(B.p0)
                end
            else
                if sign(dist1) >= 0
                    return true, Point{fT}(B.p1)
                else
                    # Neither in correct direction
                    return false, zero(Point{fT})
                end
            end
        else
            # no intersection
            return false, zero(Point{fT})
        end
    else
        tf, w = intersection(Line(A.p0, A.p1), Line(B.p0, B.p1), false)
        if tf && in_bounds(w, A) && in_bounds(w, B)
            return true, w
        else
            return false, zero(Point{fT})
        end
    end
end

function intersection(A::Line{T}, B::Line{T}, checkparallel=true) where {T}
    if checkparallel
        # parallel checking goes here!
    else
        u = A.p1 - A.p0
        v = B.p1 - B.p0
        w = A.p0 - B.p0
        vp = Point{float(T)}(-v.y, v.x)     # need float or hit overflow

        vp = vp / max(abs(vp.x), abs(vp.y))   # scale this, since its magnitude cancels out
        # dot products will be smaller than maxintfloat(Float64) (assuming |w| and |u| are)
        i = dot(-vp, w) / dot(vp, u)
        return true, A.p0 + i * u
    end
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

        for hole in children(enclosing)
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
"""
    xor2d_layerwise(obj::GeometryStructure, tool::GeometryStructure;
        only_layers=[],
        ignore_layers=[],
        depth=-1,
        pfs=Clipper.PolyFillTypePositive,
        pfc=Clipper.PolyFillTypePositive
    )

Return a `Dict` of `meta => xor2d(obj => meta, tool => meta)` for each unique `meta` in `obj` and `tool`.

Entities with metadata matching `only_layers` or `ignore_layers` are included or excluded based on [`layer_inclusion`](@ref).

Entities in references up to a depth of `depth` are included, where `depth=0` uses only top-level entities in `obj` and `tool`.
Depth is unlimited by default.

If a length is provided to `max_tile_size`, the bounds of the combined geometries are tiled with squares with that maximum
edge length. For each tile, all entities touching that tile are selected. The values in the returned `Dict` are then lazy
iterators over the results for each tile. Because entities touching more than one tile will be included in multiple operations,
resulting polygons may be duplicated or incorrect.

See [`xor2d`](@ref).
"""
function xor2d_layerwise(obj::GeometryStructure, tool::GeometryStructure; kwargs...)
    return clip_layerwise(
        Clipper.ClipTypeXor,
        obj,
        tool;
        pfs=Clipper.PolyFillTypePositive,
        pfc=Clipper.PolyFillTypePositive,
        kwargs...
    )
end

"""
    difference2d_layerwise(obj::GeometryStructure, tool::GeometryStructure;
        only_layers=[],
        ignore_layers=[],
        depth=-1,
        pfs=Clipper.PolyFillTypePositive,
        pfc=Clipper.PolyFillTypePositive
    )

Return a `Dict` of `meta => difference2d(obj => meta, tool => meta)` for each unique `meta` in `obj` and `tool`.

Entities with metadata matching `only_layers` or `ignore_layers` are included or excluded based on [`layer_inclusion`](@ref).

Entities in references up to a depth of `depth` are included, where `depth=0` uses only top-level entities in `obj` and `tool`.
Depth is unlimited by default.

If a length is provided to `max_tile_size`, the bounds of the combined geometries are tiled with squares with that maximum
edge length. For each tile, all entities touching that tile are selected. The values in the returned `Dict` are then lazy
iterators over the results for each tile. Because entities touching more than one tile will be included in multiple operations,
resulting polygons may be duplicated or incorrect.

See [`difference2d`](@ref).
"""
function difference2d_layerwise(obj::GeometryStructure, tool::GeometryStructure; kwargs...)
    return clip_layerwise(
        Clipper.ClipTypeDifference,
        obj,
        tool;
        pfs=Clipper.PolyFillTypePositive,
        pfc=Clipper.PolyFillTypePositive,
        kwargs...
    )
end

"""
    intersect2d_layerwise(obj::GeometryStructure, tool::GeometryStructure;
        only_layers=[],
        ignore_layers=[],
        depth=-1,
        pfs=Clipper.PolyFillTypePositive,
        pfc=Clipper.PolyFillTypePositive
    )

Return a `Dict` of `meta => intersect2d(obj => meta, tool => meta)` for each unique `meta` in `obj` and `tool`.

Entities with metadata matching `only_layers` or `ignore_layers` are included or excluded based on [`layer_inclusion`](@ref).

Entities in references up to a depth of `depth` are included, where `depth=0` uses only top-level entities in `obj` and `tool`.
Depth is unlimited by default.

If a length is provided to `max_tile_size`, the bounds of the combined geometries are tiled with squares with that maximum
edge length. For each tile, all entities touching that tile are selected. The values in the returned `Dict` are then lazy
iterators over the results for each tile. Because entities touching more than one tile will be included in multiple operations,
resulting polygons may be duplicated or incorrect.

See [`intersect2d`](@ref).
"""
function intersect2d_layerwise(obj::GeometryStructure, tool::GeometryStructure; kwargs...)
    return clip_layerwise(
        Clipper.ClipTypeIntersection,
        obj,
        tool;
        pfs=Clipper.PolyFillTypePositive,
        pfc=Clipper.PolyFillTypePositive,
        kwargs...
    )
end

"""
    union2d_layerwise(obj::GeometryStructure, tool::GeometryStructure;
        only_layers=[],
        ignore_layers=[],
        depth=-1,
        pfs=Clipper.PolyFillTypePositive,
        pfc=Clipper.PolyFillTypePositive
    )

Return a `Dict` of `meta => union2d(obj => meta, tool => meta)` for each unique `meta` in `obj` and `tool`.

Entities with metadata matching `only_layers` or `ignore_layers` are included or excluded based on [`layer_inclusion`](@ref).

Entities in references up to a depth of `depth` are included, where `depth=0` uses only top-level entities in `obj` and `tool`.
Depth is unlimited by default.

If a length is provided to `max_tile_size`, the bounds of the combined geometries are tiled with squares with that maximum
edge length. For each tile, all entities touching that tile are selected. The values in the returned `Dict` are then lazy
iterators over the results for each tile. Because entities touching more than one tile will be included in multiple operations,
resulting polygons may be duplicated or incorrect.

See [`union2d`](@ref).
"""
function union2d_layerwise(obj::GeometryStructure, tool::GeometryStructure; kwargs...)
    return clip_layerwise(
        Clipper.ClipTypeUnion,
        obj,
        tool;
        pfs=Clipper.PolyFillTypePositive,
        pfc=Clipper.PolyFillTypePositive,
        kwargs...
    )
end

function clip_layerwise(
    op::Clipper.ClipType,
    obj::GeometryStructure,
    tool::GeometryStructure;
    only_layers=[],
    ignore_layers=[],
    max_tile_size=nothing,
    depth=-1,
    pfs=Clipper.PolyFillTypeEvenOdd,
    pfc=Clipper.PolyFillTypeEvenOdd
)
    metadata_filter = DeviceLayout.layer_inclusion(only_layers, ignore_layers)
    if metadata_filter == DeviceLayout.trivial_inclusion
        metadata_filter = nothing
    end
    obj_flat = DeviceLayout.flatten(obj; metadata_filter, depth)
    tool_flat = DeviceLayout.flatten(tool; metadata_filter, depth)
    obj_metas = unique(DeviceLayout.element_metadata(obj))
    tool_metas = unique(DeviceLayout.element_metadata(tool))
    all_metas = unique([obj_metas; tool_metas])
    if isnothing(max_tile_size)
        res = Dict(
            meta => clip(
                op,
                DeviceLayout.elements(obj_flat)[DeviceLayout.element_metadata(
                    obj_flat
                ) .== meta],
                DeviceLayout.elements(tool_flat)[DeviceLayout.element_metadata(
                    tool_flat
                ) .== meta],
                pfs=pfs,
                pfc=pfc
            ) for meta in all_metas
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
                max_tile_size=max_tile_size,
                pfs=pfs,
                pfc=pfc
            ) for meta in all_metas
        )
    end
    return res
end

### Tiling
function tiles_and_edges(r::Rectangle, max_tile_size)
    d = min(width(r), height(r))
    tile_size = d / ceil(d / max_tile_size)
    nx = width(r) / tile_size
    ny = height(r) / tile_size
    tile0 = r.ll + Rectangle(tile_size, tile_size)
    tiles =
        [tile0 + Point((i - 1) * tile_size, (j - 1) * tile_size) for i = 1:nx for j = 1:ny]
    h_edges = [
        Rectangle(
            Point(r.ll.x, r.ll.y + (i - 1) * tile_size),
            Point(r.ur.x, r.ll.y + (i - 1) * tile_size)
        ) for i = 2:nx
    ]
    v_edges = [
        Rectangle(
            Point(r.ll.x + (i - 1) * tile_size, r.ll.y),
            Point(r.ll.x + (i - 1) * tile_size, r.ur.y)
        ) for i = 2:nx
    ]
    return tiles, vcat(h_edges, v_edges)
end

function clip_tiled(
    op,
    ents1::AbstractArray{Polygon{T}},
    ents2::AbstractArray{Polygon{T}},
    max_tile_size=1000 * DeviceLayout.onemicron(T);
    pfs=Clipper.PolyFillTypeEvenOdd,
    pfc=Clipper.PolyFillTypeEvenOdd
) where {T}
    # Create spatial index for each set of polygons
    tree1 = DeviceLayout.mbr_spatial_index(ents1)
    tree2 = DeviceLayout.mbr_spatial_index(ents2)

    # Get tiles and indices of polygons intersecting tiles
    bnds = SpatialIndexing.combine(mbr(tree1), mbr(tree2))
    bnds_dl = Rectangle(
        Point(bnds.low...) * DeviceLayout.onemicron(T),
        Point(bnds.high...) * DeviceLayout.onemicron(T)
    )
    tiles, edges = tiles_and_edges(bnds_dl, max_tile_size) # DeviceLayout Rectangles
    tile_poly_indices = map(tiles) do tile
        idx1 = DeviceLayout.findbox(tile, tree1; intersects=true)
        idx2 = DeviceLayout.findbox(tile, tree2; intersects=true)
        return (idx1, idx2)
    end
    # Clip within each tile
    res = Iterators.map(tile_poly_indices) do (idx1, idx2)
        return clip(op, ents1[idx1], ents2[idx2]; pfs, pfc)
    end
    return res
end
