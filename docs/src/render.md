## Render methods

```@docs
    render!
```

## Rendering arbitrary paths

A `Segment` and `Style` together define one or more closed curves in the plane.
The job of rendering is to approximate these curves by closed polygons. In many cases, including circular arcs and simple styles along B-spline segments, this discretization uses curvature information to render the curve to a tolerance provided to `render!` using the `atol` keyword (default `1.0nm`). For these curves, assuming small and slowly varying curvature, no point on the true curve is more than approximately `atol` from the discretization. To enable rendering
of styles along generic paths in the plane, an adaptive algorithm based on a maximum allowed change in direction `max_change` is used when no other
method is available.

```@docs
    DeviceLayout.discretize_curve
    DeviceLayout.adapted_grid
```

In some cases, custom rendering methods are implemented when it would improve performance
for simple structures or when special attention is required. The rendering methods can
specialize on either the `Segment` or `Style` types, or both.
