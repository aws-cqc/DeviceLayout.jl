module Paths
using ..Points
using Unitful
using Unitful: Length, DimensionError, °, ustrip, NoUnits
import DeviceLayout: nm, μm
import CoordinateTransformations
import CoordinateTransformations: ∘, LinearMap, AffineMap, Translation, Transformation
import StaticArrays

import Base:
    convert,
    copy,
    deepcopy_internal,
    enumerate,
    isempty,
    empty!,
    deleteat!,
    push!,
    pop!,
    pushfirst!,
    popfirst!,
    insert!,
    append!,
    splice!,
    split,
    intersect!,
    show,
    summary,
    dims2string

import Base.Iterators

using ForwardDiff
using Optim
import IntervalSets.(..)
import DeviceLayout
import DeviceLayout:
    AbstractComponent,
    Coordinate,
    CoordinateSystem,
    CoordinateUnits,
    FloatCoordinate,
    GDSMeta,
    GeometryEntity,
    GeometryReference,
    GeometryStructure,
    HandedPointHook,
    Hook,
    Meta,
    PointHook,
    Polygons,
    Reflection,
    Rotation,
    ScaledIsometry,
    StructureReference,
    XReflection,
    UNDEF_META,
    UPREFERRED,
    addref!,
    coordinatetype,
    elements,
    element_metadata,
    flatten,
    flatten!,
    in_direction,
    isapprox_angle,
    layer,
    mag,
    map_metadata!,
    name,
    origin,
    out_direction,
    place!,
    refs,
    rotated_direction,
    rotation,
    sref,
    structure,
    style,
    transform,
    transformation,
    uniquename,
    xrefl
import DeviceLayout.Polygons: segmentize, intersects
import DeviceLayout: bounds, halo

export Path, Route, StraightAnd90, StraightAnd45, BSplineRouting, CompoundRouteRule

export α0, α1, p0, p1, style0, style1, discretestyle1, contstyle1
export reconcile!,
    attach!,
    bspline!,
    corner!,
    direction,
    laststyle,
    launch!,
    meander!,
    next,
    nodes,
    overlay!,
    pathf,
    pathlength,
    pathlength_nearest,
    previous,
    rotated_direction,
    route!,
    segment,
    setsegment!,
    setstyle!,
    simplify,
    simplify!,
    straight!,
    style,
    terminate!,
    transform,
    turn!,
    undecorated

"""
    abstract type Style end

How to render a given path segment.
"""
abstract type Style end

"""
    abstract type ContinuousStyle{CanStretch} <: Style end

Any style that applies to segments which have non-zero path length. For most styles,
`CanStretch == false`. An example of an exception is a linear taper, e.g.
[`Paths.TaperTrace`](@ref), where you fix the starting and ending trace widths and let the
segment length dictate the abruptness of the transition (hence, stretching the style).
Concrete types inheriting from `ContinuousStyle{true}` should have a length field as the
last field of their structure.
"""
abstract type ContinuousStyle{CanStretch} <: Style end

"""
    abstract type DiscreteStyle <: Style end

Any style that applies to segments which have zero path length.
"""
abstract type DiscreteStyle <: Style end

include("contstyles/interface.jl")

"""
    abstract type Segment{T<:Coordinate} end

Path segment in the plane. All Segment objects should have the implement the following
methods:

  - `pathlength`
  - `p0`
  - `α0`
  - `setp0!`
  - `setα0!`
  - `α1`
"""
abstract type Segment{T <: Coordinate} end
@inline Base.eltype(::Segment{T}) where {T} = T
@inline Base.eltype(::Type{Segment{T}}) where {T} = T

Base.zero(::Segment{T}) where {T} = zero(T)     # TODO: remove and fix for 0.6 only versions
Base.zero(::Type{Segment{T}}) where {T} = zero(T)

# Used only to get dispatch to work right with ForwardDiff.jl.
struct Curv{T}
    s::T
end
(s::Curv)(t) = ForwardDiff.derivative(s.s, t)

"""
    curvature(s, t)

Return the curvature of a function `t->Point(x(t),y(t))` at `t`. The result will have units
of inverse length if units were used for the segment. The result can be interpreted as the
inverse radius of a circle with the same curvature.
"""
curvature(s, t) = ForwardDiff.derivative(Curv(s), t)

abstract type DiscreteSegment{T} <: Segment{T} end
abstract type ContinuousSegment{T} <: Segment{T} end

Base.zero(::Type{ContinuousSegment{T}}) where {T} = zero(T)

# doubly linked-list behavior
mutable struct Node{T} <: GeometryEntity{T}
    seg::Segment{T}
    sty::Style
    prev::Node{T}
    next::Node{T}

    Node{T}(a, b) where {T} = begin
        n = new{T}(a, b)
        n.prev = n
        n.next = n
    end
    Node{T}(a, b, c, d) where {T} = new{T}(a, b, c, d)
end
convert(::Type{Node{T}}, n::Node{T}) where {T} = n
function convert(::Type{Node{T}}, n::Node{S}) where {S, T}
    return Node{T}(convert(Segment{T}, n.seg), n.sty)
end
convert(::Type{GeometryEntity{T}}, n::Node) where {T} = convert(Node{T}, n)

"""
    Node(a::Segment{T}, b::Style) where {T}

Create a node with segment `a` and style `b`.
"""
Node(a::Segment{T}, b::Style) where {T} = Node{T}(a, b)

@inline Base.eltype(::Node{T}) where {T} = T
@inline Base.eltype(::Type{Node{T}}) where {T} = T

"""
    previous(x::Node)

Return the node before `x` in a doubly linked list.
"""
previous(x::Node) = x.prev

"""
    next(x::Node)

Return the node after `x` in a doubly linked list.
"""
next(x::Node) = x.next

"""
    segment(x::Node)

Return the segment associated with node `x`.
"""
segment(x::Node) = x.seg

"""
    style(x::Node)

Return the style associated with node `x`.
"""
style(x::Node) = x.sty

"""
    setsegment!(n::Node, s::Segment)

Set the segment associated with node `n` to `s`. If `reconcile`, then modify fields as
appropriate for internal consistency (possibly including other linked nodes).
"""
function setsegment!(n::Node, s::Segment; reconcile=true)
    n.seg = s
    if reconcile
        reconcilefields!(n)
        reconcilestart!(n, α0(s), p0(s))
        n′ = n
        while next(n′) !== n′
            n′ = next(n′)
            reconcilefields!(n′)
            reconcilestart!(n′)
        end
    end
    return n
end

"""
    setstyle!(n::Node, s::Style; reconcile=true)

Set the style associated with node `n` to `s`. If `reconcile`, then modify fields as
appropriate for internal consistency.
"""
function setstyle!(n::Node, s::Style; reconcile=true)
    n.sty = s
    reconcile && reconcilefields!(n)
    return n
end

function deepcopy_internal(x::Style, stackdict::IdDict)
    if haskey(stackdict, x)
        return stackdict[x]
    end
    y = copy(x)
    stackdict[x] = y
    return y
end

"""
    direction(s, t)

Return the angle at which some function `t->Point(x(t),y(t))` is pointing.
"""
function direction(s, t)
    f′ = ForwardDiff.derivative(s, t)
    fx′, fy′ = getx(f′), gety(f′)
    return uconvert(°, angle(Complex(fx′, fy′)))
end

"""
    p0(s::Segment{T}) where {T}

Return the first point in a segment (calculated).
"""
p0(s::Segment{T}) where {T} = s(zero(T))::Point{T}

"""
    p1(s::Segment{T}) where {T}

Return the last point in a segment (calculated).
"""
p1(s::Segment{T}) where {T} = s(pathlength(s))::Point{T}

"""
    α0(s::Segment)

Return the first angle in a segment (calculated).
"""
α0(s::Segment{T}) where {T} = direction(s, zero(T))

"""
    α1(s::Segment)

Return the last angle in a segment (calculated).
"""
α1(s::Segment) = direction(s, pathlength(s))

function setα0p0!(s::Segment, angle, p::Point)
    setα0!(s, angle)
    return setp0!(s, p)
end

show(io::IO, s::Segment) = print(io, summary(s))
show(io::IO, s::Style) = print(io, summary(s))

function deepcopy_internal(x::Segment, stackdict::IdDict)
    if haskey(stackdict, x)
        return stackdict[x]
    end
    y = copy(x)
    stackdict[x] = y
    return y
end

"""
    pathlength_nearest(seg::Paths.Segment, pt::Point)

Return `s` on `seg` that minimizes `norm(seg(s) - pt)`.

`s` will be between `zero(s)` and `pathlength(seg)`.
"""
function pathlength_nearest(seg::Paths.Segment{T}, pt::Point) where {T}
    errfunc(s) = ustrip(unit(T), norm(seg(s * pathlength(seg)) - pt))
    return Optim.minimizer(optimize(errfunc, 0.0, 1.0))[1] * oneunit(T)
end

"""
    mutable struct Path{T<:Coordinate} <: GeometryStructure{T}

Type for abstracting an arbitrary styled path in the plane. Iterating returns
[`Paths.Node`](@ref) objects.

Convenience constructors for `Path{T}` object:

    Path{T}(p0::Point=zero(Point{T}), α0::typeof(1.0°)=0.0°, metadata::Meta=UNDEF_META)
    Path{T}(name::String, p0::Point=zero(Point{T}), α0::Float64=0.0, metadata::Meta=UNDEF_META)
    Path(p0::Point=zero(Point{typeof(1.0UPREFERRED)}); α0=0.0, name=uniquename("path"), metadata=UNDEF_META)
    Path(p0x::Coordinate, p0y::Coordinate; α0=0.0, name=uniquename("path"), metadata=UNDEF_META)
    Path(u::CoordinateUnits; α0=0.0, name=uniquename("path"), metadata=UNDEF_META)
    Path(v::Vector{Node{T}}; name=uniquename("path"), metadata=UNDEF_META) where {T}
"""
mutable struct Path{T} <: AbstractComponent{T}
    name::String
    p0::Point{T}
    α0::typeof(1.0°)
    metadata::Meta
    nodes::Vector{Node{T}}
    _geometry::CoordinateSystem{T}

    Path{T}(
        name::String,
        p0::Point{T}=zero(Point{T}),
        α0=0.0°,
        meta::Meta=UNDEF_META,
        nodes::Vector{Node{T}}=Node{T}[]
    ) where {T} =
        new{T}(name, p0, α0, meta, nodes, CoordinateSystem{T}(uniquename("cs_" * name)))
end
@inline Base.eltype(::Path{T}) where {T} = Node{T}
@inline Base.eltype(::Type{Path{T}}) where {T} = Node{T}
nodes(p::Path) = p.nodes
name(p::Path) = p.name
laststyle(p::Path) = isempty(nodes(p)) ? nothing : style1(p, ContinuousStyle)

function DeviceLayout._geometry!(cs::CoordinateSystem, p::Path)
    return addref!(cs, p)
end

function DeviceLayout.coordsys_name(p::Path)
    # If empty, rendering path directly
    isempty(p._geometry) && return name(p._geometry)
    # If not empty, p._geometry holds `p` (e.g. `build!` was called)
    # and the path coordsys needs its own uniquename
    return uniquename(name(p))
end

"""
    path_in(h::PointHook)

A `Path` starting at h, pointing along its inward direction.
"""
path_in(h::Hook) = Path(h.p, α0=in_direction(h))

"""
    path_out(h::PointHook)

A `Path` starting at h, pointing along its outward direction.
"""
path_out(h::Hook) = Path(h.p, α0=out_direction(h))

"""
    p0_hook(pa::Path) = PointHook(p0(pa), α0(pa))

A `PointHook` looking into the start of path `pa`.
"""
p0_hook(pa::Path, right_handed=true) = HandedPointHook(p0(pa), α0(pa), right_handed)

"""
    p1_hook(pa::Path) = PointHook(p1(pa), α1(pa) + π)

A `PointHook` looking into the end of path `pa`.
"""
p1_hook(pa::Path, right_handed=true) = HandedPointHook(p1(pa), α1(pa) + π, right_handed)

"""
    hooks(pa::Path)

  - `:p0`: A `HandedPointHook` looking into the start of path `pa`.
  - `:p1`: A `HandedPointHook` looking into the end of path `pa`.
  - `:p0_lh`: A left-handed `HandedPointHook` looking into the start of path `pa`.
  - `:p1_lh`: A left-handed `HandedPointHook` looking into the end of path `pa`.
"""
DeviceLayout.hooks(pa::Path) =
    (p0=p0_hook(pa), p1=p1_hook(pa), p0_lh=p0_hook(pa, false), p1_lh=p1_hook(pa, false))

DeviceLayout.parameters(p::Path) =
    (; name=p.name, p0=p.p0, α0=p.α0, metadata=p.metadata, nodes=p.nodes)

summary(p::Path) =
    string(dims2string(size(p)), " ", typeof(p)) * " from $(p.p0) with ∠$(p.α0)"

pathf(p) = segment(p[1]).f

function show(io::IO, x::Node)
    return print(io, "$(segment(x)) styled as $(style(x))")
end

Path{T}(p0::Point{T}=zero(Point{T}), α0=0.0°, meta::Meta=UNDEF_META) where {T} =
    Path{T}(uniquename("path"), p0, α0, meta, Node{T}[])

function Path(
    p0::Point{T}=zero(Point{typeof(1.0UPREFERRED)});
    α0=0.0°,
    name=uniquename("path"),
    metadata=UNDEF_META
) where {T}
    return Path{float(T)}(name, float.(p0), α0, metadata)
end

Path(p0x::T, p0y::T; kwargs...) where {T <: Coordinate} =
    Path(Point{float(T)}(p0x, p0y); kwargs...)

Path(p0x::S, p0y::T; kwargs...) where {S <: Coordinate, T <: Coordinate} =
    Path(promote(p0x, p0y)...; kwargs...)

function Path(u::DeviceLayout.CoordinateUnits; kwargs...)
    return Path(Point(0.0u, 0.0u); kwargs...)
end
function Path(v::Vector{Node{T}}; name=uniquename("path"), metadata=UNDEF_META) where {T}
    isempty(v) && return Path{T}(zero(Point{T}), 0.0°, v)
    return Path{T}(name, p0(segment(v[1])), α0(segment(v[1])), metadata, v)
end

Path(x::Real, y::Length; kwargs...) = throw(DimensionError(x, y))
Path(x::Length, y::Real; kwargs...) = throw(DimensionError(x, y))

convert(::Type{Path{T}}, p::Path{T}) where {T} = p
function convert(::Type{Path{T}}, p::Path{S}) where {T, S}
    conv_nodes =
        Node{
            T
        }.(convert.(Segment{T}, getproperty.(p.nodes, :seg)), getproperty.(p.nodes, :sty))
    p2 = Path{T}(p.name, convert(Point{T}, p.p0), p.α0, p.metadata, conv_nodes)
    reconcile!(p2)
    return p2
end

transform(x::Path, f::Transformation) = transform(x, ScaledIsometry(f))
function transform(x::Path, f::ScaledIsometry)
    y = deepcopy(x)
    xrefl(f) && change_handedness!.(nodes(y))
    y.p0 = f(y.p0)
    y.α0 = rotated_direction(y.α0, f)
    reconcile!(y)
    return y
end

transform(x::Node, f::Transformation) = transform(x, ScaledIsometry(f))
function transform(x::Node, f::ScaledIsometry)
    y = deepcopy(x)
    xrefl(f) && change_handedness!(y)
    setα0p0!(y.seg, rotated_direction(α0(y.seg), f), f(p0(y.seg)))
    return y
end

function transform(x::Segment, f::Transformation)
    y = deepcopy(x)
    xrefl(f) && change_handedness!(y)
    setα0p0!(y, rotated_direction(α0(y), f), f(p0(y)))
    return y
end

function change_handedness!(x::Node)
    change_handedness!(x.seg)
    return change_handedness!(x.sty)
end
function change_handedness!(::Segment) end
function change_handedness!(::Style) end

function elements(p::Path)
    taper_inds = handle_generic_tapers!(p)
    n = undecorated.(nodes(p)) # breaks linked list (no longer needed)
    restore_generic_tapers!(p, taper_inds)
    return n
end
element_metadata(p::Path) = fill(p.metadata, length(p))

function refs(p::Path{T}) where {T}
    taper_inds = handle_generic_tapers!(p)
    r = GeometryReference{T}[]
    for node in p
        append!(r, _refs(segment(node), style(node)))
    end
    restore_generic_tapers!(p, taper_inds)
    return r
end

_refs(::Segment{T}, ::Style) where {T} = GeometryReference{T}[]

"""
    pathlength(p::Path)
    pathlength(array::AbstractArray{Node{T}}) where {T}
    pathlength(array::AbstractArray{T}) where {T<:Segment}
    pathlength(node::Node)

Physical length of a path. Note that `length` will return the number of
segments in a path, not the physical length of the path.
"""
function pathlength end

pathlength(p::Path) = pathlength(nodes(p))
pathlength(array::AbstractArray{Node{T}}) where {T} =
    mapreduce(pathlength, +, array; init=zero(T))
pathlength(array::AbstractArray{T}) where {T <: Segment} =
    mapreduce(pathlength, +, array; init=zero(T))
pathlength(node::Node) = pathlength(segment(node))

"""
    α0(p::Path)

First angle of a path, returns `p.α0`.
"""
α0(p::Path) = p.α0

"""
    α1(p::Path)

Last angle of a path.
"""
function α1(p::Path)
    isempty(p) && return p.α0
    return α1(segment(nodes(p)[end]))::typeof(1.0°)
end

"""
    p0(p::Path)

First point of a path, returns `p.p0`.
"""
p0(p::Path) = p.p0

"""
    p1(p::Path)

Last point of a path.
"""
function p1(p::Path)
    isempty(p) && return p.p0
    return p1(segment(nodes(p)[end]))
end

"""
    style0(p::Path)

Style of the first segment of a path.
"""
function style0(p::Path)
    isempty(p) && error("path is empty, provide a style.")
    return style(nodes(p)[1])
end

"""
    style1(p::Path)

Undecorated style of the last user-provided (non-virtual) segment of a path.

Throws an error if the path is empty.
"""
style1(p::Path) = style1(p, Style)

function style1(p::Path, T)
    isempty(p) && error("path is empty, provide a style.")
    A = view(nodes(p), reverse(1:length(nodes(p))))
    i = findfirst(x -> isa(style(x), T) && !isvirtual(style(x)), A)
    if isnothing(i)
        error("No $T found in the path.")
    else
        s = undecorated(style(A[i]))
        return _style1(s, T) # could be compound style
    end
end
_style1(s::Paths.Style, _) = s

"""
    line_segments(path::Paths.Path)

Turns a [`Paths.Path`](@ref) into an array of [`Polygons.LineSegment`](@ref) approximating
the path. Returns indices to mark which `LineSegment`s came from which [`Paths.Segment`](@ref).
"""
function line_segments(path::Path{T}) where {T}
    segs0 = Polygons.LineSegment{T}[]
    inds0 = Int[]
    for (i, n) in enumerate(nodes(path))
        segs = line_segments(segment(n))
        inds = repeat([i], length(segs))
        append!(segs0, segs)
        append!(inds0, inds)
    end
    return inds0, segs0
end

"""
    line_segments(seg::Paths.Segment)

Generic fallback, approximating a [`Paths.Segment`](@ref) using many
[`Polygons.LineSegment`](@ref) objects. Returns a vector of `LineSegment`s.
"""
function line_segments(seg::Paths.Segment)
    return Polygons.segmentize(seg.(discretization(seg)), false)
end

"""
    discretization(seg)

Return a set of coordinates `s` sufficient to approximate `seg` with the points `seg.(s)`.
"""
function discretization(seg::Paths.Segment; kwargs...)
    len = pathlength(seg)
    bnds = (zero(len), len)
    return DeviceLayout.adapted_grid(t -> Paths.direction(seg, t), bnds)
end

function DeviceLayout.map_metadata!(path::Path, map_meta)
    path.metadata = map_meta(path.metadata)
    for s in structure.(refs(path))
        map_metadata!(s, map_meta)
    end
    # Overlay styles store their own metadata
    overlay_inds = findall(x -> isa(style(x), Paths.OverlayStyle), path.nodes)
    for i in overlay_inds
        path[i].sty.overlay_metadata .= map_meta.(path[i].sty.overlay_metadata)
    end
end

include("contstyles/trace.jl")
include("contstyles/cpw.jl")
include("contstyles/compound.jl")
include("contstyles/decorated.jl")
include("contstyles/tapers.jl")
include("contstyles/strands.jl")
include("contstyles/termination.jl")
include("discretestyles/simple.jl")
include("norender.jl")

include("segments/straight.jl")
include("segments/turn.jl")
include("segments/corner.jl")
include("segments/compound.jl")
include("segments/bspline.jl")
include("segments/offset.jl")
include("segments/bspline_approximation.jl")

include("routes.jl")

function change_handedness!(seg::Union{Turn, Corner})
    return seg.α = -seg.α
end

"""
    discretestyle1(p::Path)

Return the last-used discrete style in the path.
"""
discretestyle1(p::Path) = style1(p, DiscreteStyle)

"""
    contstyle1(p::Path)

Return the undecorated last user-provided (non-virtual) continuous style in the path.

Throws an error if the path is empty.
"""
function contstyle1(p::Path)
    sty = laststyle(p)
    isnothing(sty) && error("path is empty, provide a style.")
    return sty
end

"""
    reconcilelinkedlist!(p::Path, m::Integer)

Paths have both array-like access and linked-list-like access (most often you use array
access, but segments/styles need to know about their neighbors sometimes). When doing array
operations on the path, the linked list can become inconsistent. This function restores
consistency for the node at index `m`, with previous node `m-1` and next node `m+1`.
First and last node are treated specially.
"""
function reconcilelinkedlist!(p::Path, m::Integer)
    if m == 1
        seg = segment(nodes(p)[1])
        nodes(p)[1].prev = nodes(p)[1]
        if length(p) == 1
            nodes(p)[1].next = nodes(p)[1]
        end
    else
        nodes(p)[m - 1].next = nodes(p)[m]
        nodes(p)[m].prev = nodes(p)[m - 1]
        if m == length(p)
            nodes(p)[m].next = nodes(p)[m]
        end
    end
end

"""
    reconcilefields!(n::Node)

Segments or styles can have fields that depend on the properties of neighbors. Examples:

  - Corners need to know their extents based on previous/next styles.
  - Tapers need to know their length for `extent(s, t)` to work.
    This function reconciles node `n` for consistency with neighbors in this regard.
"""
function reconcilefields!(n::Node)
    seg, sty = segment(n), style(n)
    if isa(seg, Corner)
        seg.extent = extent(style(previous(n)), pathlength(segment(previous(n))))
    end
    return n.sty = _withlength!(sty, pathlength(seg)) # may modify or create new style
end

_withlength!(sty::Style, l) = sty
function _withlength!(sty::ContinuousStyle{true}, l)
    return typeof(sty)((getfield(sty, i) for i = 1:(nfields(sty) - 1))..., l)
end
function _withlength!(sty::DecoratedStyle, l)
    sty.s = _withlength!(sty.s, l)
    return sty
end
function _withlength!(sty::OverlayStyle, l)
    sty.s = _withlength!(sty.s, l)
    sty.overlay .= _withlength!.(sty.overlay, Ref(l))
    return sty
end

"""
    reconcilestart!(n::Node{T}, α0=0, p0=Point(zero(T), zero(T))) where {T}

This function reconciles the starting position and angle of the segment at path node `n`
to match the ending position and angle of the previous node.
"""
function reconcilestart!(n::Node{T}, α0=0, p0=Point(zero(T), zero(T))) where {T}
    if previous(n) == n # first node
        setα0p0!(segment(n), α0, p0)
    else
        seg = segment(n)
        seg0 = segment(previous(n))
        setα0p0!(seg, α1(seg0), p1(seg0))
    end
end

"""
    reconcile!(p::Path, n::Integer=1)

Reconcile all inconsistencies in a path starting from index `n`. Used internally whenever
segments are inserted into the path, but can be safely used by the user as well.
"""
function reconcile!(p::Path, n::Integer=1)
    isempty(p) && return
    for j = n:lastindex(p)
        reconcilelinkedlist!(p, j)
        reconcilefields!(p[j])
        reconcilestart!(p[j], α0(p), p0(p))
    end
end

# Methods for Path as AbstractArray

function splice!(p::Path, inds; reconcile=true)
    n = splice!(nodes(p), inds)
    reconcile && reconcile!(p, first(inds))
    return n
end
function splice!(p::Path, inds, p2::Path; reconcile=true)
    n = splice!(nodes(p), inds, nodes(p2))
    reconcile && reconcile!(p, first(inds))
    return n
end

#### Interface methods for Path
# Iteration
Base.iterate(p::Path) = iterate(nodes(p))
Base.iterate(p::Path, state) = iterate(nodes(p), state)
Base.length(p::Path) = length(nodes(p))
Base.size(p::Path) = size(nodes(p))
Base.size(p::Path, dim) = size(nodes(p), dim)
Base.isdone(p::Path) = Base.isdone(nodes(p))
Base.isdone(p::Path, state) = Base.isdone(nodes(p), state)
# Indexing
Base.firstindex(p::Path) = 1
Base.lastindex(p::Path) = length(nodes(p))
Base.getindex(p::Path, i) = nodes(p)[i]
function Base.getindex(c::Path, nom::AbstractString, index::Integer=1)
    inds = findall(x -> name(x) == nom, refs(c))
    return refs(c)[inds[index]]
end
function Base.setindex!(p::Path, v::Node, i::Integer; reconcile=true)
    nodes(p)[i] = v
    return reconcile && reconcile!(p, i)
end
function Base.setindex!(p::Path, v::Segment, i::Integer; reconcile=true)
    return setsegment!(nodes(p)[i], v; reconcile=reconcile)
end
function Base.setindex!(p::Path, v::Style, i::Integer; reconcile=true)
    return setstyle!(nodes(p)[i], v; reconcile=reconcile)
end

isempty(p::Path) = isempty(nodes(p))
empty!(p::Path) = empty!(nodes(p))
function deleteat!(p::Path, inds; reconcile=true)
    deleteat!(nodes(p), inds)
    return reconcile && reconcile!(p, first(inds))
end

function push!(p::Path, node::Node; reconcile=true)
    push!(nodes(p), node)
    return reconcile && reconcile!(p, length(p))
end
function pushfirst!(p::Path, node::Node; reconcile=true)
    pushfirst!(nodes(p), node)
    return reconcile && reconcile!(p)
end

for x in (:push!, :pushfirst!)
    @eval function ($x)(p::Path, seg::Segment, sty::Style; reconcile=true)
        return ($x)(p, Node(seg, sty); reconcile=reconcile)
    end
    @eval function ($x)(p::Path, segsty0::Node, segsty::Node...; reconcile=true)
        ($x)(p, segsty0; reconcile=reconcile)
        for x in segsty
            ($x)(p, x; reconcile=reconcile)
        end
    end
end

function pop!(p::Path; reconcile=true)
    x = pop!(nodes(p))
    reconcile && reconcile!(p, length(p))
    return x
end

function popfirst!(p::Path; reconcile=true)
    x = popfirst!(nodes(p))
    reconcile && reconcile!(p)
    return x
end

function insert!(p::Path, i::Integer, segsty::Node; reconcile=true)
    insert!(nodes(p), i, segsty)
    return reconcile && reconcile!(p, i)
end

insert!(p::Path, i::Integer, seg::Segment, sty::Style; reconcile=true) =
    insert!(p, i, Node(seg, sty); reconcile=reconcile)

function insert!(p::Path, i::Integer, seg::Segment; reconcile=true)
    if i == 1
        sty = style0(p)
    else
        sty = style(nodes(p)[i - 1])
    end
    return insert!(p, i, Node(seg, sty); reconcile=reconcile)
end

function insert!(p::Path, i::Integer, segsty0::Node, segsty::Node...; reconcile=true)
    insert!(p, i, segsty0; reconcile=reconcile)
    for x in segsty
        insert!(p, i, x; reconcile=reconcile)
    end
end

"""
    append!(p::Path, p′::Path; reconcile=true)

Given paths `p` and `p′`, path `p′` is appended to path `p`.
The p0 and initial angle of the first segment from path `p′` is
modified to match the last point and last angle of path `p`.
"""
function append!(p::Path, p′::Path; reconcile=true)
    isempty(p′) && return
    i = length(p)
    lp, la = p1(p), α1(p)
    append!(nodes(p), nodes(p′))
    reconcile && reconcile!(p, i + 1)
    return nothing
end

"""
    simplify(p::Path, inds::UnitRange=firstindex(p):lastindex(p))

At `inds`, segments of a path are turned into a `CompoundSegment` and
styles of a path are turned into a `CompoundStyle`. The method returns a `Paths.Node`,
`(segment, style)`.

  - Indexing the path becomes more sane when you can combine several path segments into one
    logical element. A launcher would have several indices in a path unless you could simplify
    it.
  - You don't need to think hard about boundaries between straights and turns when you want a
    continuous styling of a very long path.
"""
function simplify(p::Path, inds::UnitRange=firstindex(p):lastindex(p))
    tag = gensym()
    cseg = CompoundSegment(nodes(p)[inds], tag)
    csty = CompoundStyle(cseg.segments, map(style, nodes(p)[inds]), tag)
    return Node(cseg, csty)
end

"""
    simplify!(p::Path, inds::UnitRange=firstindex(p):lastindex(p))

In-place version of [`simplify`](@ref).
"""
function simplify!(p::Path, inds::UnitRange=firstindex(p):lastindex(p))
    x = simplify(p, inds)
    # Replace inds with x
    deleteat!(p, inds)
    insert!(p, inds[1], x)
    return p
end

"""
    meander!(p::Path, len, straightlen, r, α)

Alternate between going straight with length `straightlen` and turning with radius `r` and
angle `α`. Each turn goes the opposite direction of the previous. The total length is `len`.
Useful for making resonators.

The straight and turn segments are combined into a `CompoundSegment` and appended to the
path `p`.
"""
function meander!(p::Path, len, straightlen, r, α)
    unit = straightlen + r * abs(α)
    ratio = len / unit
    fl = floor(ratio)
    nsegs = Int(fl)
    rem = (ratio - fl) * unit

    for pm in Iterators.take(Iterators.cycle((1, -1)), nsegs)
        straight!(p, straightlen, style1(p))
        turn!(p, pm * α, r, style1(p))           # alternates left and right
    end
    straight!(p, rem)
    return p
end

"""
    transformappend(path::Path, point::Point)

Coordinates of `point` relative to the reference frame of the end-point of `path`,
i.e. with origin at `p1(path)` and with x-axis pointing along `α1(path)`.
"""
function transformappend(path::Path, point::Point)
    dr = point - p1(path)
    ux = cos(α1(path))
    uy = sin(α1(path))
    return Point{typeof(p1(path).x)}(dr.x * ux + dr.y * uy, -dr.x * uy + dr.y * ux)
end

"""
    function radiator(endp::Point, len, nseg::Int, r, sty::Paths.Style; offset = zero(r))

Path from origin to `endp` of length `len`.
The path extends in the +x direction, makes a first 90° turn,
then `2*nseg` U-turns in alternate rotations, then a last 90° turn
(with straight segments in between all these turns),
then finally extend in +x direction then go straight to `endp`.
Note that if you specify arguments which are impossible constraints
to satisfy, i.e. `endp.x` is too small to fit in the pattern,
or `len` is too short to actually make so many turns,
then the method tries to path-extend by a negative amount, which throws an error.

  - `r`: the turn radius
  - `offset`: shifts the bulk of the pattern in y-direction
"""
function radiator(endp::Point, len, nseg::Int, r, sty::Paths.Style; offset=zero(r))
    x, y = endp
    len1 = len - (x - 2 * nseg * 2 * r) + (4 - π) * r - abs(y)
    z = (len1 / (2 * nseg) + abs(y) - π * r) / 2
    p = Path(zero(endp))
    straight!(p, x / 2 - 2 * nseg * r - r, sty)
    t = y < zero(y) ? -90° : 90°
    isapprox(y, zero(y); atol=1e-8 * oneunit(y)) && (t = 90°)
    turn!(p, t, r)
    straight!(p, (z - r) * (1 + offset))
    t *= -2
    for _ = 2:(2 * nseg)
        turn!(p, t, r)
        straight!(p, 2 * z - abs(y))
        t = -t
    end
    turn!(p, t, r)
    straight!(p, (z - r) * (1 - offset))
    turn!(p, -t / 2, r)
    straight!(p, x / 2 - 2 * nseg * r - r, sty)
    return p
end
"""
    meander!(p::Path, endpoint::Point, len, nseg::Int, r, sty::Paths.Style = style1(p); offset = 0)

Another meander method, this one extends Path `p` from its current end-point
to meet `endpoint`, such that the resulting final total path length will be `len`.

  - `nseg`: the number of U-turns in the meander will be 2*nseg
"""
meander!(
    p::Path,
    endpoint::Point,
    len,
    nseg::Int,
    r,
    sty::Paths.Style=style1(p);
    offset=0
) = append!(
    p,
    radiator(
        transformappend(p, endpoint),
        len - pathlength(p),
        nseg::Int,
        r,
        sty::Paths.Style;
        offset=offset
    )
)

"""
    bellow(endp::Point, l, r, sty::Paths.Style)

Path from origin to `endp` of length `l`.
The path extends in the +x direction, turns with radius `r`,
extend (by distance needed to obtain total length), U-turns and comes back,
and makes a 90° turn and extend horizontally to meet endp.
End point should have sufficiently positive x-coordinate
so that we don't try to path-extend by a negative amount.
"""
function bellow(endp::Point, l, r, sty::Paths.Style)
    x, y = endp
    p = Path(zero(endp))
    xsl = l - 2 * π * abs(r) - (x - 4 * abs(r)) # extra straights length
    straight!(p, x / 2 - 2 * abs(r), sty)
    turn!(p, sign(r) * 90°, abs(r))
    straight!(p, xsl / 2 + sign(r) * y / 2)
    turn!(p, -sign(r) * 180°, abs(r))
    straight!(p, xsl / 2 - sign(r) * y / 2)
    turn!(p, sign(r) * 90°, abs(r))
    straight!(p, x / 2 - 2 * abs(r))
    return p
end
"""
    bellow!(p::Path, endpoint::Point, l, r)

Extend Path `p` to `endpoint` using a bellow of bend radius `r`
such that the final total path length will equal `l`.
"""
bellow!(p::Path, endpoint::Point, l, r) =
    append!(p, bellow(transformappend(p, endpoint), l - pathlength(p), r, style1(p)))

const launchdefaults = Dict([
    (:extround, 5.0),
    (:trace0, 300.0),
    (:trace1, 10.0),
    (:gap0, 150.0),
    (:gap1, 6.0),
    (:flatlen, 250.0),
    (:taperlen, 250.0)
])

"""
    launch!(p::Path; kwargs...)

Add a coplanar-waveguide "launcher" structure to `p`.

If `p` is empty, start the path with a launcher; otherwise, terminate with a launcher.

This method exists mainly for use in demonstrations. The launcher design is not optimized
for microwave properties.

Keywords:

  - `extround = 5.0μm`: Rounding of the "back" of the pad and external ground plane "behind" the launcher
  - `trace0 = 300.0μm`: Trace width of the pad
  - `trace1 = 10.0μm`: Trace width of the launched CPW
  - `gap0 = 150.0μm`: Gap width of the pad
  - `gap1 = 6.0μm`: Gap width of the final CPW
  - `flatlen = 250.0μm`: Length of the pad
  - `taperlen = 250.0μm`: Length of the taper between pad and launched CPW
"""
launch!(p::Path{<:Real}; kwargs...) = _launch!(p; launchdefaults..., kwargs...)

function launch!(p::Path{T}; kwargs...) where {T <: Length}
    u = DeviceLayout.onemicron(T)
    return _launch!(
        p;
        Dict(zip(keys(launchdefaults), collect(values(launchdefaults)) * u))...,
        kwargs...
    )
end

function _launch!(p::Path{T}; kwargs...) where {T <: Coordinate}
    d = Dict{Symbol, T}(kwargs)
    extround = d[:extround]
    trace0, trace1 = d[:trace0], d[:trace1]
    gap0, gap1 = d[:gap0], d[:gap1]
    flatlen, taperlen = d[:flatlen], d[:taperlen]

    y = isempty(p)
    s2 = CPW(trace0, gap0)

    u, v = ifelse(y, (trace0, trace1), (trace1, trace0))
    w, x = ifelse(y, (gap0, gap1), (gap1, gap0))
    s3 = TaperCPW(u, w, v, x)

    if y
        args = (flatlen, taperlen)
        styles = (s2, s3)
    else
        args = (taperlen, flatlen)
        styles = (s3, s2)
    end

    for (a, b) in zip(args, styles)
        !iszero(a) && straight!(p, a, b)
    end

    terminate!(p; rounding=extround, initial=y)

    return CPW(trace1, gap1)
end

"""
    terminate!(pa::Path{T}; gap=Paths.terminationlength(pa), rounding=zero(T), initial=false) where {T}

End a `Paths.Path` with a termination.

If the preceding style is a CPW, this is a "short termination" if `iszero(gap)` and is an
"open termination" with a gap of `gap` otherwise, defaulting to the gap of the preceding CPW.

Rounding of corners may be specified with radius given by `rounding`. Rounding keeps the
trace length constant by removing some length from the preceding segment and adding a
rounded section of equivalent maximum length.

Terminations can be applied on curves without changing the underlying curve. If you add a
segment after a termination, it will start a straight distance `gap` away from where the original
curve ended. However, rounded terminations are always drawn as though straight from the point where
rounding starts, slightly before the end of the curve. This allows the rounded corners to be represented
as exact circular arcs.

If the preceding style is a trace, the termination only rounds the corners at the end of the
segment or does nothing if `iszero(rounding)`.

If `initial`, the termination is appended before the beginning of the `Path`.
"""
function terminate!(
    pa::Path{T};
    rounding=zero(T),
    initial=false,
    gap=terminationlength(pa, initial)
) where {T}
    termlen = gap + rounding
    iszero(termlen) && return
    termsty = Termination(pa, rounding; initial=initial, cpwopen=!iszero(gap))
    # Nonzero rounding: splice and delete to make room for rounded part
    if !iszero(rounding)
        orig_sty = initial ? undecorated(style0(pa)) : laststyle(pa)
        round_gap = (orig_sty isa CPW && iszero(gap))
        split_idx = initial ? firstindex(pa) : lastindex(pa)
        split_node = pa[split_idx]
        len = pathlength(split_node)
        len > rounding || throw(
            ArgumentError(
                "`rounding` $rounding too large for previous segment path length $len."
            )
        )

        split_len = initial ? rounding : len - rounding
        !round_gap &&
            (2 * rounding > trace(orig_sty, split_len)) &&
            throw(
                ArgumentError(
                    "`rounding` $rounding too large for previous segment trace width $(trace(orig_sty, split_len))."
                )
            )
        round_gap &&
            (2 * rounding > Paths.gap(orig_sty, split_len)) &&
            throw(
                ArgumentError(
                    "`rounding` $rounding too large for previous segment gap $(Paths.gap(orig_sty, split_len))."
                )
            )
        splice!(pa, split_idx, split(split_node, split_len))
        termsty = if initial
            Termination(Path(pa[2:end]), rounding; initial=initial, cpwopen=!iszero(gap))
        else
            Termination(Path(pa[1:(end - 1)]), rounding; initial=initial, cpwopen=!iszero(gap))
        end
    end

    if initial
        α = α0(pa)
        p = p0(pa) - gap * Point(cos(α), sin(α))
        pa.p0 = p
        pushfirst!(pa, Straight{T}(gap, p, α), termsty)
        if !iszero(rounding)
            # merge first two segments and apply termsty
            simplify!(pa, 1:2)
            setstyle!(pa[1], termsty)
        end
    else
        straight!(pa, gap, termsty)
        if !iszero(rounding)
            # merge last two segments and apply termsty
            simplify!(pa, (length(pa) - 1):length(pa))
            setstyle!(pa[end], termsty)
        end
    end
end

function terminationlength(pa::Path{T}, initial::Bool) where {T}
    initial && return terminationlength(undecorated(style0(pa)), zero(T))
    return terminationlength(laststyle(pa), pathlength(pa[end]))
end

terminationlength(s, t) = zero(t)
terminationlength(s::CPW, t) = gap(s, t)

"""
    split(n::Node, x::Coordinate)
    split(n::Node, x::AbstractVector{<:Coordinate}; issorted=false)

Splits a path node at position(s) `x` along the segment, returning a path.
If `issorted`, don't sort `x` first (otherwise required for this to work).

A useful idiom, splitting and splicing back into a path:
splice!(path, i, split(path[i], x))
"""
function split(n::Node, x::Coordinate)
    seg1, seg2, sty1, sty2 = split(segment(n), style(n), x)

    n1 = Node(seg1, sty1)
    n2 = Node(seg2, sty2)
    n1.prev = n.prev
    n1.next = n2
    n2.prev = n1
    n2.next = n.next

    return Path([n1, n2])
end

function split(n::Node, x::AbstractVector{<:Coordinate}; issorted=false)
    isempty(x) && throw(ArgumentError("List of positions to split at cannot be empty"))
    sortedx = issorted ? x : sort(x)

    i = 2
    L = first(sortedx)
    path = split(n, L)
    for pos in view(sortedx, (firstindex(sortedx) + 1):lastindex(sortedx))
        splice!(path, i, split(path[i], pos - L); reconcile=false)
        L = pos
        i += 1
    end
    reconcile!(path)
    return path
end

function split(seg::Segment, sty::Style, x)
    return (split(seg, x)..., split(sty, x)...)
end

function split(seg::ContinuousSegment, x)
    if !(zero(x) < x < pathlength(seg))
        throw(ArgumentError("x must be between 0 and pathlength(seg)"))
    end
    return _split(seg, x)
end

function split(sty::ContinuousStyle, x)
    return _split(sty, x)
end

function _split(sty::Style, x)
    s1, s2 = pin(sty; stop=x), pin(sty; start=x)
    undecorate!(s1, x)  # don't duplicate attachments at the split point!
    return s1, s2
end

function _split(sty::CompoundStyle, x, tag1, tag2)
    return pin(sty; stop=x, tag=tag1), pin(sty; start=x, tag=tag2)
end

"""
    place!(cs::CoordinateSystem, p::Path, metadata=p.metadata)

Place a reference to `p` in `cs` and set metadata to `metadata`.
"""
function DeviceLayout.place!(cs::CoordinateSystem, p::Path, metadata::Meta=p.metadata)
    p.metadata = metadata
    return addref!(cs, p)
end

"""
    halo(pa::Path, outer_delta, inner_delta; only_layers=[], ignore_layers=[])

Return a `Path` forming the halo of `pa`, equivalent to offsetting the geometry by `outer_delta`, then subtracting the offset by `inner_delta` if it is not `nothing`.

Extends the start and/or end by `delta` (for each inner/outer offset) when `pa` has nonzero extent at the endpoints.
Each segment's style is the halo style of the original segment.

For the segments of the `Path` and any attached references,
any entities in layers in `ignore_layers` will be skipped. Note that even if the segments
are ignored, attachments may not be.
If `only_layers` is not empty, only those layers will be used to generate the halo.
Layers for inclusion and exclusion can be provided as layer name `Symbol`s, in which case
only the layer name needs to be matched, or as full `DeviceLayout.Meta` objects, in which case all
metadata fields (e.g., index and level for `SemanticMeta`) must match.

Returns a Path.
"""
function halo(
    pa::Path{T},
    outer_delta,
    inner_delta;
    only_layers=[],
    ignore_layers=[],
    memoized_halos=Dict{GeometryStructure, GeometryStructure}()
) where {T}
    haskey(memoized_halos, pa) && return memoized_halos[pa]
    if isempty(pa)
        halopath = deepcopy(pa)
        halopath.name = uniquename("halo" * name(pa))
        memoized_halos[pa] = halopath
        return halopath
    end
    taper_inds = handle_generic_tapers!(pa)

    # If initial extent is nonzero, add delta to halo before start
    ext0 = Paths.extent(pa[1].sty, zero(outer_delta))
    p0 = (
        iszero(ext0) ? pa.p0 :
        pa.p0 - Point{T}(outer_delta * cos(pa.α0), outer_delta * sin(pa.α0))
    )

    halopath = Path(p0, α0=pa.α0, metadata=pa.metadata, name=uniquename("halo" * name(pa)))

    # check if path's halo should be excluded
    exclude = !(DeviceLayout.layer_included(pa.metadata, only_layers, ignore_layers))

    if exclude # path metadata is excluded, but still compute halos of path's decorations
        # compute halos of decorations
        cs = DeviceLayout.CoordinateSystem{T}(uniquename("halo" * name(pa)))
        cs.refs =
            halo.(
                refs(pa),
                outer_delta,
                inner_delta,
                only_layers=only_layers,
                ignore_layers=ignore_layers,
                memoized_halos=memoized_halos
            )

        # return a path, to preserve type
        halopath = Path(zero(pa.p0), metadata=pa.metadata)
        straight!(halopath, zero(outer_delta), Paths.NoRender())
        attach!(halopath, sref(cs), zero(pa.p0[1]))

        return halopath
    end

    if !iszero(ext0)
        extsty = halo(Paths.SimpleTrace(2 * ext0), outer_delta, inner_delta)
        straight!(halopath, outer_delta, extsty)
    end

    # Create the halo of each original path segment
    dup_path = deepcopy(pa)
    reconcile!(dup_path)
    for node in dup_path
        # Set the style to the halo style
        # Convert any NoRender halo to ContinuousStyle or DiscreteStyle as appropriate
        node.sty = if node.sty isa DiscreteStyle
            convert(
                DiscreteStyle,
                halo(
                    node.sty,
                    outer_delta,
                    inner_delta,
                    only_layers=only_layers,
                    ignore_layers=ignore_layers,
                    memoized_halos=memoized_halos
                )
            )
        else
            convert(
                ContinuousStyle,
                halo(
                    node.sty,
                    outer_delta,
                    inner_delta,
                    only_layers=only_layers,
                    ignore_layers=ignore_layers,
                    memoized_halos=memoized_halos
                )
            )
        end
    end
    append!(halopath, dup_path)

    # If final extent is nonzero, add termination to halo
    ext1 = Paths.extent(pa[end].sty, pathlength(pa[end]))

    restore_generic_tapers!(pa, taper_inds)

    if !iszero(ext1)
        extsty = halo(Paths.SimpleTrace(2 * ext1), outer_delta, inner_delta)
        straight!(halopath, outer_delta, extsty)
    end
    memoized_halos[pa] = halopath
    return halopath
end

function halo(node::Paths.Node{T}, outer_delta, inner_delta=nothing; kwargs...) where {T}
    halosty = if node.sty isa DiscreteStyle
        convert(DiscreteStyle, halo(node.sty, outer_delta, inner_delta; kwargs...))
    else
        convert(ContinuousStyle, halo(node.sty, outer_delta, inner_delta; kwargs...))
    end
    # Add front/back halos if necessary
    ext0 = Paths.extent(node.sty, zero(outer_delta))
    pre_halo_start = (
        iszero(ext0) ? p0(node.seg) :
        p0(node.seg) -
        Point{T}(outer_delta * cos(α0(node.seg)), outer_delta * sin(α0(node.seg)))
    )
    pre_halo = Path(pre_halo_start, α0=α0(node.seg))
    post_halo = Path(p1(node.seg), α0=α1(node.seg))
    if node.prev === node
        if !iszero(ext0)
            extsty = halo(Paths.SimpleTrace(2 * ext0), outer_delta, inner_delta)
            straight!(pre_halo, outer_delta, extsty)
        end
    end
    if node.next === node
        ext1 = Paths.extent(node.sty, pathlength(node.seg))
        if !iszero(ext1)
            extsty = halo(Paths.SimpleTrace(2 * ext1), outer_delta, inner_delta)
            straight!(post_halo, outer_delta, extsty)
        end
    end
    halonode = Node{T}(node.seg, halosty)
    reconcilefields!(halonode)
    return [elements(pre_halo)..., halonode, elements(post_halo)...]
end

"""
    halo(sty::Paths.Style, outer_delta, inner_delta=nothing; kwargs...)

Return a `Trace` or `CPW` style covering the extent of `sty` from an offset of `inner_delta` to `outer_delta`.
"""
function halo(sty::Union{TaperTrace, TaperCPW}, outer_delta, inner_delta=nothing; kwargs...)
    iszero(extent(sty, zero(outer_delta))) && return Paths.NoRender()
    if isnothing(inner_delta)
        return _withlength!(
            Paths.TaperTrace(
                2 * (extent(sty, zero(outer_delta)) + outer_delta),
                2 * (extent(sty, sty.length) + outer_delta)
            ),
            sty.length
        )
    end
    return _withlength!(
        Paths.TaperCPW(
            2 * (extent(sty, zero(delta)) + inner_delta),
            outer_delta - inner_delta,
            2 * (extent(sty, sty.length) + inner_delta),
            outer_delta - inner_delta
        ),
        sty.length
    )
end

function halo(
    sty::Union{SimpleTrace, SimpleCPW},
    outer_delta,
    inner_delta=nothing;
    kwargs...
)
    iszero(extent(sty, zero(outer_delta))) && return Paths.NoRender()
    isnothing(inner_delta) && return Paths.SimpleTrace(2 * (extent(sty) + outer_delta))
    return Paths.SimpleCPW(2 * (extent(sty) + inner_delta), outer_delta - inner_delta)
end

function halo(sty::Style, outer_delta, inner_delta=nothing; kwargs...)
    # If it starts with zero extent then no halo
    # Could be a problem if we allow tapers that start at zero
    iszero(extent(sty, zero(outer_delta))) && return Paths.NoRender()
    isnothing(inner_delta) && return Paths.Trace(t -> 2 * (extent(sty, t) + outer_delta))
    return Paths.CPW(
        t -> 2 * (extent(sty, t) + inner_delta),
        t -> outer_delta - inner_delta
    )
end

function halo(sty::CompoundStyle, outer_delta, inner_delta=nothing; kwargs...)
    newsty = copy(sty)
    newsty.styles .= halo.(newsty.styles, Ref(outer_delta), Ref(inner_delta); kwargs...)
    return newsty
end

function halo(sty::DecoratedStyle, outer_delta, inner_delta=nothing; kwargs...)
    undec = halo(sty.s, outer_delta, inner_delta; kwargs...)
    return DecoratedStyle(
        undec,
        sty.ts,
        sty.dirs,
        Vector{GeometryReference}(halo.(sty.refs, outer_delta, inner_delta; kwargs...))
    )
end

function halo(
    sty::OverlayStyle,
    outer_delta,
    inner_delta=nothing;
    only_layers=[],
    ignore_layers=[],
    kwargs...
)
    idx =
        DeviceLayout.layer_included.(
            sty.overlay_metadata,
            Ref(only_layers),
            Ref(ignore_layers)
        )
    return OverlayStyle(
        halo(sty.s, outer_delta, inner_delta; only_layers, ignore_layers, kwargs...),
        halo.(
            sty.overlay[idx],
            Ref(outer_delta),
            Ref(inner_delta);
            only_layers,
            ignore_layers,
            kwargs...
        ),
        sty.overlay_metadata[idx]
    )
end

end
