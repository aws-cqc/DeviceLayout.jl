## Polygons

Polygons in DeviceLayout.jl are subtypes of [`DeviceLayout.AbstractPolygon`](@ref), regardless of their representation in memory. Usually, when we write "polygon" in unformatted text, we mean `AbstractPolygon`. (In this documentation, we try to follow this pattern for common words and corresponding abstract types. For example, we'll use "coordinate system" to mean any `AbstractCoordinateSystem` including `Cell`, not necessarily just `CoordinateSystem`.)

The most important polygon subtype is [`Polygon`](@ref), which is defined by a vector of points, where the last point is not repeated. `Polygon` is the primitive entity type for `Cell`—any shape being rendered to a `Cell` must end up represented as one or more `Polygon`s. The `GeometryEntity` interface provides a `to_polygons` function that produces that representation.

Most functions in the geometry interface (besides transformation, which must be implemented by subtypes) will fall back to calling `to_polygons` on entities first if there is no specialized method.
For example, if you ask for the bounding box of a path node (which could define a shape like multiple parallel brushstrokes) `bounds(node)` will simply find the bounding box of the polygon(s) from `to_polygons(node)`, using the default tolerance for discretization of curves.

See [API Reference: Polygons](@ref api-polygons).

## Clipping

Geometric Boolean operations on polygons are called "clipping" operations. For 2D geometry, these—`union2d`, `difference2d`, `intersection2d`, and `xor2d`—are the only geometric Booleans available. Other geometry types are first converted to polygons using `to_polygons` to perform clipping.

!!! warn

    Because clipping converts entities into polygons, rounding should be performed *after* clipping, not before. Otherwise, rounded corners are discretized into many points in the clipping operation, which can make geometry operations expensive and lead to poor 3D meshes.

!!! info
    
    Boolean operations in 3D with `SolidModel` are handled by the Open CASCADE Technology kernel, which works directly with rich geometry types rendered from our native `CoordinateSystem`. If you need boolean operations involving curved geometry whose results can't be achieved by clipping-then-rounding, then your 2D geometry should defer the boolean operation until `SolidModel` postrendering so that the result will still be represented with curves.

For many use cases, `union2d`, `difference2d`, `intersect2d`, and `xor2d` behave as expected and are easiest to use.
More general operations may be accomplished using the `clip` function.

The results of clipping are represented using the `ClippedPolygon <: AbstractPolygon` type, which stores a tree of positive and negative contours. These mainly exist to represent polygons with holes without having to generate "keyhole" polygons as required by the GDSII format. This ends up being convenient for other backends that don't want keyhole polygons as well as for applying different styles to different boundary or hole contours.

A related operation is [`offset`](@ref), which grows or shrinks the polygon by offsetting its edges a given distance.

## Styles

In addition to other generic [entity styles](./geometry.md#Entity-Styles) like `NoRender`, `AbstractPolygon`s can be paired with the `Rounded` style. `ClippedPolygon`s support `StyleDict`, which allows for different styles to be applied to different contours in its tree.
