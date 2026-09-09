module Align
import DeviceLayout: AbstractGeometry, Point, center, centered, upperright, lowerleft
import DeviceLayout: Translation

export aligned_to, centered_on
export leftof, rightof, below, above, flushleft, flushright, flushbottom, flushtop
export LeftEdge, RightEdge, XCenter, TopEdge, BottomEdge, YCenter
export centered, centered_on

# Convenience functions for getting min/max/center coordinates (as Points, intercepts) of bounding box
function _leftedge(p::AbstractGeometry{T}) where {T}
    return Point(lowerleft(p).x, zero(T))
end

function _rightedge(p::AbstractGeometry{T}) where {T}
    return Point(upperright(p).x, zero(T))
end

function _xcenter(p::AbstractGeometry{T}) where {T}
    return Point(center(p).x, zero(T))
end

function _topedge(p::AbstractGeometry{T}) where {T}
    return Point(zero(T), upperright(p).y)
end

function _bottomedge(p::AbstractGeometry{T}) where {T}
    return Point(zero(T), lowerleft(p).y)
end

function _ycenter(p::AbstractGeometry{T}) where {T}
    return Point(zero(T), center(p).y)
end

"""
`AlignRule`s are singleton types corresponding to functions that can be used in alignment
methods to specify which part of the source is being aligned, or what it's being aligned to.
`XAlignRule` and `YAlignRule` functions return `(x, 0)` and `(0, y)` coordinates,
respectively, and are distinguished to enable making sure source and target rules are
compatible.
"""
abstract type AlignRule end
abstract type RectAlignRule <: AlignRule end # Rectilinear
abstract type XAlignRule <: RectAlignRule end
abstract type YAlignRule <: RectAlignRule end
struct LeftEdge <: XAlignRule end
struct RightEdge <: XAlignRule end
struct XCenter <: XAlignRule end
struct TopEdge <: YAlignRule end
struct BottomEdge <: YAlignRule end
struct YCenter <: YAlignRule end
_alignfn(r::LeftEdge) = _leftedge
_alignfn(r::RightEdge) = _rightedge
_alignfn(r::XCenter) = _xcenter
_alignfn(r::TopEdge) = _topedge
_alignfn(r::BottomEdge) = _bottomedge
_alignfn(r::YCenter) = _ycenter

"""
    _get_coord(p::AbstractGeometry, rule::AlignRule)

Compute the `Point` object associated with `p` according to `rule`.
"""
function _get_coord(p::AbstractGeometry, rule::AlignRule)
    return _alignfn(rule)(p)
end

"""
    _is_alignable(f::AlignRule, g::AlignRule)

Check whether a pair of `AlignRule`s are compatible.
"""
function _is_alignable(f::RectAlignRule, g::RectAlignRule)
    return (f isa XAlignRule && g isa XAlignRule) || (f isa YAlignRule && g isa YAlignRule)
end

"""
    _disp(source, target, align_source::AlignRule, align_target::AlignRule, offset=0)

Calculate the displacement required to perform an alignment (as in `aligned_to()`).
"""
function _disp(
    source::AbstractGeometry{T},
    target::AbstractGeometry{S},
    align_source::XAlignRule,
    align_target::XAlignRule;
    offset=zero(promote_type(S, T))
) where {S, T}
    source_coord = _get_coord(source, align_source)
    target_coord = _get_coord(target, align_target)
    offset_point = Point(offset, zero(offset))
    return target_coord - source_coord + offset_point
end

function _disp(
    source::AbstractGeometry{T},
    target::AbstractGeometry{S},
    align_source::YAlignRule,
    align_target::YAlignRule;
    offset=zero(promote_type(S, T))
) where {S, T}
    source_coord = _get_coord(source, align_source)
    target_coord = _get_coord(target, align_target)
    offset_point = Point(zero(offset), offset)
    return target_coord - source_coord + offset_point
end

"""
    aligned_to(source::AbstractGeometry{T}, target::AbstractGeometry{S},
               align_source::RectAlignRule, align_target::RectAlignRule;
               offset=convert(S, zero(T))) where {T,S}

Aligns a copy of `source` with its `align_source` aligned to `align_target` of `target`.

For alignment in only one coordinate, the other coordinate is left unchanged.
An optional `offset` will further displace the result in the aligned coordinate.
Coordinates will be promoted if necessary when centering.

`align_source` and `align_target` must match coordinates; that is, both must
refer to the `x` coordinate (`Align.LeftEdge`, `Align.RightEdge`, or `Align.XCenter`)
or both to the `y` coordinate (`Align.TopEdge`, `Align.BottomEdge`, or `Align.YCenter`).

Convenience functions `(leftof, rightof, above, below, flushleft, flushright, flushtop, flushbottom)`
are also defined as wrappers around `aligned_to` with pre-specified `AlignRule`s.

# Examples

```jldoctest
julia> Align.aligned_to(Rectangle(2, 2), Rectangle(4, 4), Align.LeftEdge(), Align.XCenter())
Rectangle((2.0,0.0), (4.0,2.0))
```
"""
function aligned_to(
    source::AbstractGeometry{T},
    target::AbstractGeometry{S},
    align_source::RectAlignRule,
    align_target::RectAlignRule;
    offset=zero(promote_type(S, T))
) where {T, S}
    disp = _disp(source, target, align_source, align_target, offset=offset)
    return Translation(disp)(source)
end

"""
    aligned_to(source::AbstractGeometry{T}, target::AbstractGeometry{S},
        align_source::Tuple{XAlignRule, YAlignRule},
        align_target::Tuple{XAlignRule, YAlignRule};
        offset::Point = zero(Point{promote_type(S, T)})) where {T,S}

Align a copy of `source` to `target` in `x` and `y` coordinates simultaneously.
"""
function aligned_to(
    source::AbstractGeometry{T},
    target::AbstractGeometry{S},
    align_source::Tuple{XAlignRule, YAlignRule},
    align_target::Tuple{XAlignRule, YAlignRule};
    offset::Point=zero(Point{promote_type(S, T)})
) where {T, S}
    disp =
        _disp(source, target, align_source[1], align_target[1], offset=offset.x) +
        _disp(source, target, align_source[2], align_target[2], offset=offset.y)
    return Translation(disp)(source)
end

# Simple alignment functions align a copy of `source` to `target` in one coordinate.

# These are just convenience wrappers around `aligned_to()` calls that have
# their `AlignRule`s built in. An optional `offset` can still be specified, and
# the result can optionally be `centered` in the other coordinate. (By default
# the other coordinate is left alone.)

# Could use metaprogramming only but I want to play nicely with linting and docs
"""
    leftof(source, target; offset=0, centered=false)

Align a copy of `source` with its bounding box right side aligned on the left of `target`'s.
"""
function leftof end

"""
    rightof(source, target; offset=0, centered=false)

Align a copy of `source` with its bounding box left side aligned on the right of `target`'s.
"""
function rightof end

"""
    above(source, target; offset=0, centered=false)

Align a copy of `source` with its bounding box bottom aligned with the top of `target`'s.
"""
function above end

"""
    below(source, target; offset=0, centered=false)

Align a copy of `source` with its bounding box top aligned with the bottom of `target`'s.
"""
function below end

"""
    flushleft(source, target; offset=0, centered=false)

Align a copy of `source` with its bounding box left side flush with that of `target`.
"""
function flushleft end

"""
    flushright(source, target; offset=0, centered=false)

Align a copy of `source` with its bounding box right side flush with that of `target`.
"""
function flushright end

"""
    flushtop(source, target; offset=0, centered=false)

Align a copy of `source` with its bounding box top flush with that of `target`.
"""
function flushtop end

"""
    flushbottom(source, target; offset=0, centered=false)

Align a copy of `source` with its bounding box bottom flush with that of `target`.
"""
function flushbottom end

_simple_alignment = Dict(
    :leftof => :(RightEdge, LeftEdge),
    :rightof => :(LeftEdge, RightEdge),
    :above => :(BottomEdge, TopEdge),
    :below => :(TopEdge, BottomEdge),
    :flushright => :(RightEdge, RightEdge),
    :flushleft => :(LeftEdge, LeftEdge),
    :flushtop => :(TopEdge, TopEdge),
    :flushbottom => :(BottomEdge, BottomEdge)
)
for (alignfn, rules) in _simple_alignment
    @eval function ($alignfn)(
        source::AbstractGeometry{T},
        target::AbstractGeometry{S};
        offset=zero(promote_type(S, T)),
        centered=false
    ) where {T, S}
        res = aligned_to(source, target, $rules[1](), $rules[2](), offset=offset)
        if centered # align centers in other coordinate
            if $rules[1]() isa XAlignRule
                res = aligned_to(res, target, YCenter(), YCenter())
            else
                res = aligned_to(res, target, XCenter(), XCenter())
            end
        end
        return res
    end
end

"""
    centered_on(source::AbstractGeometry, target::AbstractGeometry)

Centers a copy of `source` centered on the center of `target`, promoting coordinates if necessary.
"""
function centered_on(source::AbstractGeometry, target::AbstractGeometry)
    return centered(source, on_pt=center(target))
end

end
