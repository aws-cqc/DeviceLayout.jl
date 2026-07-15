## Polygons

Polygons in DeviceLayout.jl are subtypes of [`DeviceLayout.AbstractPolygon`](@ref), regardless of their representation in memory. Usually, when we write "polygon" in unformatted text, we mean `AbstractPolygon`. (In this documentation, we try to follow this pattern for common words and corresponding abstract types. For example, we'll use "coordinate system" to mean any `AbstractCoordinateSystem` including `Cell`, not necessarily just `CoordinateSystem`.)

The most important polygon subtype is [`Polygon`](@ref), which is defined by a vector of points, where the last point is not repeated. `Polygon` is the primitive entity type for `Cell`—any shape being rendered to a `Cell` must end up represented as one or more `Polygon`s. The `GeometryEntity` interface provides a `to_polygons` function that produces that representation.

Other `AbstractPolygon`s include [`Rectangle`](@ref) and [`ClippedPolygon`](@ref).

Most functions in the geometry interface (besides transformation, which must be implemented by subtypes) will fall back to calling `to_polygons` on entities first if there is no specialized method.
For example, if you ask for the bounding box of a path node (which could define a shape like multiple parallel brushstrokes) `bounds(node)` will simply find the bounding box of the polygon(s) from `to_polygons(node)`, using the default tolerance for discretization of curves.

See [API Reference: Polygons](@ref api-polygons).

## Clipping

Geometric Boolean operations on polygons are called "clipping" operations. For 2D geometry, these—`union2d`, `difference2d`, `intersection2d`, and `xor2d`—are the only geometric Booleans available. Other geometry types are first converted to polygons using `to_polygons` to perform clipping.

!!! warning

    Because clipping converts entities into polygons, rounding should be performed *after* clipping, not before. Otherwise, rounded corners are discretized into many points in the clipping operation, which can make geometry operations expensive and lead to poor 3D meshes.

!!! info

    Boolean operations in 3D with `SolidModel` are handled by the Open CASCADE Technology kernel, which works directly with rich geometry types rendered from our native `CoordinateSystem`. If you need boolean operations involving curved geometry whose results can't be achieved by clipping-then-rounding, you have two options: keep curves in 2D using the curve-preserving Boolean variants (see [Recovering curves through clipping](@ref) below), or defer the boolean operation until `SolidModel` postrendering so that the result will still be represented with curves.

For many use cases, `union2d`, `difference2d`, `intersect2d`, and `xor2d` behave as expected and are easiest to use.
More general operations may be accomplished using the `clip` function.

The results of clipping are represented using the `ClippedPolygon <: AbstractPolygon` type, which stores a tree of positive and negative contours. These mainly exist to represent polygons with holes without having to generate "keyhole" polygons as required by the GDSII format. This ends up being convenient for other backends that don't want keyhole polygons as well as for applying different styles to different boundary or hole contours.

A related operation is [`offset`](@ref), which grows or shrinks the polygon by offsetting its edges a given distance.

## Curvilinear polygons

A [`CurvilinearPolygon`](@ref) is a polygon where some edges are replaced by circular arcs
(stored as [`Paths.Turn`](@ref) segments). This preserves exact arc geometry for the
`SolidModel` rendering path while still supporting discretization to a plain `Polygon` for
`Cell` / GDS output.

`CurvilinearPolygon`s arise naturally when rendering [`Path`](@ref) segments (e.g.,
`SimpleTrace`, `CPW`) and can also be constructed directly.

A [`CurvilinearRegion`](@ref) pairs a `CurvilinearPolygon` exterior with zero or more
`CurvilinearPolygon` holes. Holes are normalized to clockwise winding on construction,
matching the convention `ClippedPolygon` uses for hole contours.

See [API Reference: Curvilinear geometry](@ref api-curvilinear).

### Recovering curves through clipping

Boolean operations (`union2d`, `difference2d`, etc.) discretize curved geometry to polygons
before passing them to the Clipper library. Normally, the original curves (arcs, splines)
are lost in this process. The [`recover_curves`](@ref) function and its convenience
wrappers (`difference2d_curved`, `union2d_curved`, `intersect2d_curved`, `xor2d_curved`)
track each input curve's discretized integer-grid footprint and substitute the original
curve back into the result wherever that footprint survived the boolean operation intact.

The curve-preserving variants return a `Vector{CurvilinearRegion}` rather than a single
`ClippedPolygon`. Each region in the vector corresponds to one outer contour in the clipped
result (the disjoint pieces each become a separate region). For example:

```julia
# Standard clipping discretizes curves to polygons:
result = difference2d(a, b)  # ClippedPolygon

# Curve-preserving variant recovers arcs where possible:
regions = difference2d_curved(a, b)  # Vector{CurvilinearRegion}, arcs preserved

# Single-argument self-union merges overlapping curved entities (for example the
# nodes of a `Path`) into one region per disjoint piece:
merged = union2d_curved(path)
```

Curve-bearing inputs are expanded to their exact arc geometry before clipping via the same
converter the `SolidModel` render path uses, so `Rounded` applied to `Polygon`, `Rectangle`,
`ClippedPolygon`, `CurvilinearRegion`, and `CurvilinearPolygon`, as well as nestings with
no-op styles (`MeshSized`, `WithDirection`) and per-contour `StyleDict`s — including on
`Path` nodes — all recover their arcs where the footprint survives.

**Current limitations:** A curve is recovered only if its entire discretized run survives
the boolean operation with exact integer equality. If the operation cuts through a curve
(e.g., a straight edge crossing an arc's interior), that curve falls back to a polyline.
Partial-curve recovery is not supported.

An input entity with no curve-recovery method (for example an `Ellipse`, or a style
combination not listed above) is discretized via `to_polygons` with no provenance, so any
curves it carries cannot be recovered; a warning is logged once per entity type when this
happens.

## Styles

In addition to other generic [entity styles](./geometry.md#Entity-Styles) like `NoRender`, `AbstractPolygon`s can be paired with the `Rounded` style. `ClippedPolygon`s support `StyleDict`, which allows for different styles to be applied to different contours in its tree.

### Rounding

The [`Rounded`](@ref Polygons.Rounded) style applies fillet arcs to selected corners of a
polygon. It handles two kinds of corners:

  - **Straight-straight corners** (two straight edges meeting at a vertex) — available for
    both `Polygon` and `CurvilinearPolygon`.
  - **Line-arc corners** (a straight edge meeting a circular arc) — for
    `CurvilinearPolygon` only.

Arc-arc corners (two arcs meeting at a vertex) are not supported and are left as-is.

Corner selection uses the `p0` keyword to target specific vertices by their coordinates.
When `p0` is empty (the default), all eligible corners are rounded. The
`inverse_selection` flag inverts the selection.

#### Per-corner fillet radii (nested rounding)

Different corners can be rounded with different radii by stacking `Rounded` styles:

```julia
poly = Rectangle(10mm, 6mm)
r1_pts = [Point(0, 0)mm, Point(10, 6)mm]
r2_pts = [Point(10, 0)mm, Point(0, 6)mm]

inner  = Rounded(1mm; p0=r1_pts)(poly)
result = Rounded(0.3mm; p0=r2_pts)(inner)
to_polygons(result)  # all four corners rounded with two different radii
```

This works for both the Cell and SolidModel rendering paths. The inner `Rounded` produces
a `CurvilinearPolygon` with exact fillet arcs, and the outer `Rounded` applies line-arc
rounding at the transitions.

#### Circles and rings

`RelativeRounded(0.5)` on a square places all four fillet arc centers at the square's
center, so the result is an exact circle built from four 90° arcs:

```julia
mycircle(r) = RelativeRounded(0.5)(centered(Rectangle(2r, 2r)))
```

An idiomatic ring (annulus) is then the same rounding applied to the difference of
two such squares, which is exact for both the Cell and SolidModel rendering paths:

```julia
myring(r_outer, r_inner) = RelativeRounded(0.5)(
    difference2d(
        centered(Rectangle(2r_outer, 2r_outer)),
        centered(Rectangle(2r_inner, 2r_inner))
    )
)
```

(A ring can also be drawn as a `Path` with a full 360° turn, which renders as two
half-annulus polygons.)

#### Selecting line-arc corners

[`Curvilinear.line_arc_cornerindices`](@ref) identifies vertices where a straight edge meets a curve.
This is useful for components that need to round only arc-to-straight transitions while leaving other corners sharp:

```julia
cp = some_curvilinear_polygon()
la_pts = cp.p[line_arc_cornerindices(cp)]
rounded = Rounded(r; p0=la_pts)(cp)  # only line-arc corners get filleted
```
