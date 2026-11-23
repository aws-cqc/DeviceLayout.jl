# Clipper1-style names and types over Clipper2.
#
# DeviceLayout was written against Clipper.jl 0.6, which wraps Clipper1. Clipper.jl 0.7
# wraps Clipper2 with Clipper2's own API and names (#199). This module keeps what
# DeviceLayout and its users rely on: the Clipper1 names that `clip` and `offset` take,
# as aliases of Clipper.jl's enums, the `PolyNode` tree that `ClippedPolygon` stores, and
# a small engine interface for `clipping.jl`. The rest of DeviceLayout refers to
# `Clipper.X` with `Clipper` bound to this module.
#
# `IntPoint` and `PolyNode` with its methods are adapted from Clipper.jl 0.6 (Boost
# Software License 1.0, see THIRDPARTY.md).
module Clipper

# Clipper.jl 0.7. Its names would clash with this module's.
import Clipper as C2
# Methods of Clipper.jl's own tree accessors, so code that calls
# `Clipper.children(cp.tree)` after `import Clipper` keeps working.
import .C2: children, contour, ishole

# Clipper1 names for Clipper.jl's enums. They are the same objects, so values taken from
# Clipper.jl itself are accepted too.
const ClipType = C2.ClipType
const ClipTypeIntersection = C2.ClipTypeIntersection
const ClipTypeUnion = C2.ClipTypeUnion
const ClipTypeDifference = C2.ClipTypeDifference
const ClipTypeXor = C2.ClipTypeXor

const PolyFillType = C2.FillRule
const PolyFillTypeEvenOdd = C2.FillRuleEvenOdd
const PolyFillTypeNonZero = C2.FillRuleNonZero
const PolyFillTypePositive = C2.FillRulePositive
const PolyFillTypeNegative = C2.FillRuleNegative

const JoinType = C2.JoinType
const JoinTypeSquare = C2.JoinTypeSquare
const JoinTypeRound = C2.JoinTypeRound
const JoinTypeMiter = C2.JoinTypeMiter

const EndType = C2.EndType
const EndTypeClosedPolygon = C2.EndTypePolygon
const EndTypeClosedLine = C2.EndTypeJoined
const EndTypeOpenButt = C2.EndTypeButt
const EndTypeOpenSquare = C2.EndTypeSquare
const EndTypeOpenRound = C2.EndTypeRound

# Layout-compatible with Clipper.jl's Point64, so paths convert by reinterpreting.
struct IntPoint
    X::Int64
    Y::Int64
end

mutable struct PolyNode{T}
    contour::Vector{T}
    hole::Bool
    open::Bool
    children::Vector{PolyNode{T}}
    parent::PolyNode{T}
    PolyNode{T}(a, b, c) where {T} = new{T}(a, b, c)
    function PolyNode{T}(a, b, c, d) where {T}
        p = new{T}(a, b, c, d)
        p.parent = p
        return p
    end
    PolyNode{T}(a, b, c, d, e) where {T} = new{T}(a, b, c, d, e)
end

Base.convert(::Type{PolyNode{T}}, x::PolyNode{T}) where {T} = x
function Base.convert(::Type{PolyNode{S}}, x::PolyNode{T}) where {S, T}
    parent(x) !== x && error("must convert a top-level PolyNode (i.e. a PolyTree).")
    pn = PolyNode{S}(convert(Vector{S}, contour(x)), ishole(x), isopen(x))
    pn.children = [PolyNode(y, pn) for y in children(x)]
    return pn.parent = pn
end

function PolyNode(x::PolyNode, parent::PolyNode{S}) where {S}
    pn = PolyNode{S}(contour(x), ishole(x), isopen(x))
    pn.children = [PolyNode(y, pn) for y in children(x)]
    pn.parent = parent
    return pn
end

@inline ishole(x::PolyNode) = x.hole
@inline Base.isopen(x::PolyNode) = x.open
@inline contour(x::PolyNode) = x.contour
@inline children(x::PolyNode) = x.children
@inline Base.parent(x::PolyNode) = x.parent

function Base.show(io::IO, node::PolyNode)
    if parent(node) === node
        print(io, "Top-level PolyNode with $(length(children(node))) immediate children.")
    else
        print(io, isopen(node) ? "Open " : "Closed ")
        print(io, "PolyNode ")
        ishole(node) && print(io, "(hole) ")
        println(io, "with contour:")
        show(io, contour(node))
        println(io, "")
        print(io, "...and $(length(children(node))) immediate children.")
    end
end

# Paths are copied on the way in and out, since IntPoint and Point64 are distinct types.
_p64(path::AbstractVector) = collect(reinterpret(C2.Point64, path))
_p64s(paths) = C2.Path64[_p64(p) for p in paths]
_ip(path::C2.Path64) = collect(reinterpret(IntPoint, path))

struct Clip
    engine::C2.Clipper64
    Clip(; reverse_solution::Bool=false) =
        new(C2.Clipper64(; preserve_collinear=false, reverse_solution))
end

# Clipper1 compat: degenerate paths (such as empty polygons) are dropped. Batch adds leave
# them to the engine, which drops them; a single-path add would throw on them.
add_subject!(c::Clip, paths) = (C2.add_subject!(c.engine, _p64s(paths)); c)
add_clip!(c::Clip, paths) = (C2.add_clip!(c.engine, _p64s(paths)); c)
clear!(c::Clip) = (C2.clear!(c.engine); c)

execute(c::Clip, op::ClipType, fill::PolyFillType) =
    _ip.(first(C2.execute(c.engine, op, fill)))

# Clipper2 can nest a contour under a neighbour it only touches along a near-coincident
# edge (ledger L18): an outer contour returned as a hole of its neighbour, a hole
# returned inside a neighbouring hole, or a hole of an island returned beside the island.
# A true child has the opposite orientation to its parent. A child oriented like its
# parent is attached beside the parent if it is flagged as a hole, or if it lies partly
# outside the parent. Otherwise it is attached under a sibling that contains it. A sliver
# island inside a hole can come back with the wrong orientation too (L8), and lies in no
# sibling, so it stays where it is. Hole flags follow the corrected depth. `parent_src` is
# `nothing` for the root, which has no contour, so `execute_pt` moves the root's strays.
# Returns the node and its orientation.
function _addnode!(parent::PolyNode{IntPoint}, src, parent_src, parent_positive::Bool)
    positive = C2.is_positive(src.polygon)
    misnested =
        !isnothing(parent_src) &&
        positive == parent_positive &&
        (
            src.ishole ||
            any(p -> C2.point_in_polygon(p, parent_src.polygon) === :outside, src.polygon)
        )
    owner = misnested ? parent.parent : parent
    node = PolyNode{IntPoint}(
        _ip(src.polygon),
        owner.parent !== owner && !owner.hole,
        false,
        PolyNode{IntPoint}[],
        owner
    )
    push!(owner.children, node)
    strays = nothing
    for ch in src.children
        child, child_positive = _addnode!(node, ch, src, positive)
        if child.parent === node && child_positive == positive
            strays = push!(something(strays, PolyNode{IntPoint}[]), child)
        end
    end
    isnothing(strays) || _rehome!(node, strays, positive)
    return node, positive
end

function _rehome!(node::PolyNode{IntPoint}, strays, positive::Bool)
    for s in strays
        i = findfirst(node.children) do h
            return _boxes_overlap(s.contour, h.contour) &&
                   is_positive(h.contour) != positive &&
                   _inside(s.contour, h.contour)
        end
        isnothing(i) && continue
        host = node.children[i]
        filter!(h -> h !== s, node.children)
        s.parent = host
        push!(host.children, s)
        _sethole!(s, !host.hole)
    end
end

function _sethole!(node::PolyNode, hole::Bool)
    node.hole = hole
    for ch in node.children
        _sethole!(ch, !hole)
    end
end

# Contours at one level of a valid tree don't overlap, so any substantial overlap means
# `inner` lies in `outer`. Its edges can nearly coincide with `outer`'s, so vertices of
# `inner` may test as just outside.
function _inside(inner::Vector{IntPoint}, outer::Vector{IntPoint})
    a, b = _p64(inner), _p64(outer)
    overlap =
        sum(p -> abs(C2.area(p)), C2.intersect_paths(a, b, C2.FillRuleNonZero); init=0.0)
    return overlap > abs(C2.area(a)) / 2
end

function _boxes_overlap(a::Vector{IntPoint}, b::Vector{IntPoint})
    ax, ay = extrema(p -> p.X, a), extrema(p -> p.Y, a)
    bx, by = extrema(p -> p.X, b), extrema(p -> p.Y, b)
    return ax[1] <= bx[2] && bx[1] <= ax[2] && ay[1] <= by[2] && by[1] <= ay[2]
end

function execute_pt(c::Clip, op::ClipType, fill::PolyFillType)
    root, _ = C2.execute_polytree(c.engine, op, fill)
    pt = PolyNode{IntPoint}(IntPoint[], false, false, PolyNode{IntPoint}[])
    strays = PolyNode{IntPoint}[]
    for ch in root.children
        node, positive = _addnode!(pt, ch, nothing, false)
        positive || push!(strays, node)
    end
    _rehome!(pt, strays, false)
    return pt
end

struct ClipperOffset
    engine::C2.ClipperOffset
    ClipperOffset(miter_limit::Float64, arc_tolerance::Float64) =
        new(C2.ClipperOffset(; miter_limit, arc_tolerance))
end

add_paths!(c::ClipperOffset, paths, j::JoinType, e::EndType) =
    (C2.add_path!(c.engine, _p64s(paths), j, e); c)
execute(c::ClipperOffset, delta::Float64) = _ip.(C2.execute(c.engine, delta))

is_positive(path::AbstractVector) = C2.is_positive(_p64(path))
area(path::AbstractVector) = C2.area(_p64(path))

end # module Clipper
