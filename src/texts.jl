module Texts

using ..Points
import ..Align:
    XAlignRule, YAlignRule, LeftEdge, RightEdge, XCenter, TopEdge, BottomEdge, YCenter

import DeviceLayout:
    GeometryEntity,
    Meta,
    Polygon,
    ScaledIsometry,
    layer,
    datatype,
    origin,
    rotation,
    xrefl,
    mag
import DeviceLayout: to_polygons, transform, transformation, Transformation

# cannot do the following since `Text` was exported from `Base`
# export Text

"""
    Text{S} <: GeometryEntity{S}

Text element in a layout. Distinct from rendering text as polygons (`PolyText`).

Text rendering may be viewer or system dependent. Use `PolyText` for text with
well-defined geometry.

Arguments:

  - `text`: the text string.
  - `origin`: location of the text in parent coordinate system.
  - `width`: character size
  - `can_scale`: defaults to `false`, set to `true` if the text size should not be affected
    by scaling of parent coordinate system.
  - `xalign`: horizontal alignment of text with respect to `origin`. Can be any instance of
    abstract type `Align.XAlignRule` and defaults to `LeftEdge()`.
  - `yalign`: vertical alignment of text with respect to `origin`. Can be any instance of
    abstract type `Align.YAlignRule` and defaults to `TopEdge()`.
  - `xrefl`: Reflect across x-axis. Defaults to `false`.
  - `mag`: Magnification factor.
  - `rot`: Rotation in radians.
"""
struct Text{S} <: GeometryEntity{S}
    text::String
    origin::Point{S}
    width::S
    can_scale::Bool
    xalign::XAlignRule
    yalign::YAlignRule
    xrefl::Bool
    mag::Float64
    rot::Float64
end
Base.convert(::Type{GeometryEntity{T}}, t::Text) where {T} = convert(Text{T}, t)
function Base.convert(::Type{Text{T}}, t::Text) where {T}
    origin = convert(Point{T}, t.origin)
    width = convert(T, t.width)
    return Text(;
        t.text,
        origin,
        width,
        t.can_scale,
        t.xalign,
        t.yalign,
        t.xrefl,
        t.mag,
        t.rot
    )
end
Base.convert(::Type{Text{T}}, t::Text{T}) where {T} = t

transformation(t::Text) = ScaledIsometry(t.origin, t.rot, t.xrefl, t.mag)

function transform(t::Text{S}, f::Transformation) where {S}
    tf = f ∘ transformation(t)
    return Text(;
        text=t.text,
        origin=origin(tf),
        width=t.width,
        can_scale=t.can_scale,
        xalign=t.xalign,
        yalign=t.yalign,
        xrefl=xrefl(tf),
        mag=mag(tf),
        rot=rotation(tf)
    )
end

to_polygons(t::Text{S}; kwargs...) where {S} = Polygon{S}[]

Base.:(==)(t1::Text, t2::Text) = all([
    t1.text == t2.text,
    transformation(t1) == transformation(t2),
    t1.width == t2.width,
    t1.can_scale == t2.can_scale,
    t1.xalign == t2.xalign,
    t1.yalign == t2.yalign
])
Base.isapprox(t1::Text, t2::Text) = all([
    t1.text == t2.text,
    transformation(t1) ≈ transformation(t2),
    t1.width == t2.width,
    t1.can_scale == t2.can_scale,
    t1.xalign == t2.xalign,
    t1.yalign == t2.yalign
])

function Text(;
    text,
    origin,
    width=zero(eltype(origin)),
    can_scale=false,
    xalign=LeftEdge(),
    yalign=TopEdge(),
    xrefl=false,
    mag=1.0,
    rot=0.0
)
    S = promote_type(typeof(width), eltype(origin))
    return Text{S}(text, origin, width, can_scale, xalign, yalign, xrefl, mag, rot)
end
Text(text, origin; kwargs...) = Text(; text, origin, kwargs...)

end
