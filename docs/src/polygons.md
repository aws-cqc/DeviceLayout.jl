## Abstract polygons

In this package, any polygon regardless of its concrete representation in memory
should be a subtype of [`DeviceLayout.AbstractPolygon`](@ref). Usually, when we write "polygon" in unformatted text, we mean `AbstractPolygon`. (In this documentation, we try to follow this pattern for common words and corresponding abstract types. For example, we'll use "coordinate system" to mean any `AbstractCoordinateSystem` including `Cell`, not necessarily just `CoordinateSystem`.)

```@docs
    DeviceLayout.AbstractPolygon
```

The most important polygon subtype is [`Polygon`](@ref), which is defined by a vector of points. `Polygon` is the primitive entity type for `Cell`—any shape being rendered to a `Cell` must end up represented as one or more `Polygon`s. The `GeometryEntity` interface provides a `to_polygons` function that produces that representation.

Most functions in the geometry interface (besides transformation, which must be implemented by subtypes) will fall back to calling `to_polygons` on entities first if there is no specialized method.
For example, if you ask for the bounding box of a path node (which could define a shape like multiple parallel brushstrokes) `bounds(node)` will simply find the bounding box of the polygon(s) from `to_polygons(node)`, using the default tolerance for discretization of curves.

## Clipping

Geometric Boolean operations on polygons are called "clipping" operations. For 2D geometry, these—`union2d`, `difference2d`, and `intersection2d`—are the only geometric Booleans available. Other geometry types are first converted to polygons using `to_polygons` to perform clipping.

!!! info
    
    Boolean operations in 3D with `SolidModel` are handled by the Open CASCADE Technology kernel, which works directly with rich geometry types rendered from our native `CoordinateSystem`.

For many use cases, `union2d`, `difference2d`, and `intersect2d` behave as expected and are easiest to use.
More general operations may be accomplished using the `clip` function.

```@docs
    union2d
    difference2d
    intersect2d
    clip
    cliptree
```

The results of clipping are represented using the `ClippedPolygon <: AbstractPolygon` type, which stores a tree of positive and negative contours. These mainly exist to represent polygons with holes without having to generate "keyhole" polygons as required by the GDSII format. This ends up being convenient for other backends that don't want keyhole polygons as well as for applying different styles to different boundary or hole contours.

```@docs
    Polygons.ClippedPolygon
```

## Styles

In addition to other generic [entity styles](entitystyles.md) like `NoRender`, `AbstractPolygon`s can be paired with the `Rounded` style. `ClippedPolygon`s support `StyleDict`, which allows for different styles to be applied to different contours in its tree.

```@docs
    Polygons.Rounded
    Polygons.StyleDict
```

## Offsetting

```@docs
    offset
```

## Rectangle API

```@docs
    Rectangle
    Rectangle(::Point, ::Point)
    Rectangle(::Any, ::Any)
    bounds(::Rectangle)
    height(::Rectangle)
    isproper(::Rectangle)
    lowerleft(::Rectangle)
    upperright(::Rectangle)
    points(::Rectangle{T}) where {T<:Real}
    width(::Rectangle)
```

## Polygon API

```@docs
    Polygon
    Polygon(::AbstractVector{Point{T}}) where {T}
    Polygon(::Point, ::Point, ::Point, ::Point...)
    perimeter
    points
    sweep_poly
    gridpoints_in_polygon
```
