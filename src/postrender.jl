# Post-render passes: operations applied to the rendered geometry of a layer as a whole,
# as opposed to entity styles like `Rounded`, which are applied to entities as they are
# created. The distinguishing feature is that these passes see the union of a layer's
# flattened geometry, so they can handle results that emerge only after composition
# (e.g. corners where separately-rendered polygons meet).

"""
    round_layer(geom::Union{Cell,CoordinateSystem}, layer::DeviceLayout.Meta, radius;
        min_side_len=radius, min_angle=1e-3)

Return the geometry of `geom` in `layer` as a `Vector{CurvilinearRegion}` with corners
rounded to `radius`.

The elements of `geom` matching `layer` (using [`layer_inclusion`](@ref) semantics,
including elements inside references) are flattened and unioned before rounding, so
corners are rounded correctly even where separately-drawn shapes meet. Rounding is
symbolic: the fillets in the result are true arcs, and any holes in the unioned geometry
are preserved as holes of the resulting regions (with their corners rounded too).

For `CoordinateSystem` input, the union preserves curves already present in the input
(arcs from paths, `Rounded` entities, circles, ...) using [`union2d_curved`](@ref), and
corners between straight edges and arcs are rounded natively. Curve recovery is currently
all-or-nothing: an input curve cut by the union falls back to a polyline, as described in
[`recover_curves`](@ref). For `Cell` input, elements are already plain polygons, which are
unioned with [`union2d`](@ref), then converted to rounded `CurvilinearRegion`s.

# Keyword arguments

  - `min_side_len`: the minimum side length adjacent to a corner for that corner to be
    rounded. Defaults to `radius`.
  - `min_angle`: corners where adjacent sides are collinear within this tolerance (in
    radians) are not rounded.
"""
function round_layer(
    geom::Union{Cell, CoordinateSystem},
    layer::Meta,
    radius::Coordinate;
    min_side_len=radius,
    min_angle::Real=1e-3
)
    sty = Rounded(radius; min_side_len, min_angle)
    return _rounded_regions(geom, layer, sty)
end

"""
    round_layer!(geom::Union{Cell,CoordinateSystem}, layer::DeviceLayout.Meta, radius;
        target_layer::DeviceLayout.Meta, remap_originals=nothing,
        min_side_len=radius, min_angle=1e-3, kwargs...)

Round the corners of the geometry of `geom` in `layer` to `radius`, rendering the result
into `geom` itself with metadata `target_layer`.

The rounded result is computed as in [`round_layer`](@ref) (flatten, union, round
symbolically) and rendered at the top level of `geom`. The original elements are left in
place; if `remap_originals` is set to a `DeviceLayout.Meta`, the elements of
`geom` matching `layer` are retagged with that metadata instead, including elements
inside references (which may be shared by structures outside `geom`, making this operation
unsafe). Text elements are unaffected.

For a `CoordinateSystem` target, the rounded regions are placed symbolically (arcs stay
exact). For a `Cell` target, they are discretized on render; keyword arguments (e.g.
`atol`) are forwarded to `render!` to control the discretization, and `target_layer` and
`remap_originals` must be `GDSMeta`. Rendering to an integer coordinate type may throw an
`InexactError` if a discretized point is not representable; in that case `geom` is left
unchanged.

See [`round_layer`](@ref) for the rounding keyword arguments.
"""
function round_layer!(
    geom::Union{Cell, CoordinateSystem},
    layer::Meta,
    radius::Coordinate;
    target_layer::Meta,
    remap_originals::Union{Meta, Nothing}=nothing,
    min_side_len=radius,
    min_angle::Real=1e-3,
    kwargs...
)
    regions = round_layer(geom, layer, radius; min_side_len, min_angle)

    # Stage rendering so conversion or discretization failures leave `geom` unchanged.
    staged = coordsys_type(geom)("round_layer_staging")
    for r in regions
        render!(staged, r, target_layer; kwargs...)
    end

    # Remap before adding new elements in case `layer == target_layer`
    !isnothing(remap_originals) &&
        map_metadata!(geom, m -> m == layer ? remap_originals : m)

    append!(elements(geom), elements(staged))
    append!(element_metadata(geom), element_metadata(staged))
    return geom
end

function _rounded_regions(cell::Cell{S}, layer, sty) where {S}
    polys = flat_elements(cell, layer)
    isempty(polys) && return CurvilinearRegion{S}[]
    return to_curvilinear(union2d(polys), sty)
end

function _rounded_regions(cs::CoordinateSystem{S}, layer, sty) where {S}
    ents = flat_elements(cs, layer)
    isempty(ents) && return CurvilinearRegion{S}[]
    # Curve-preserving union: arcs already present in the input survive symbolically
    # rather than being discretized, and line-arc corners are rounded natively.
    return [to_curvilinear(r, sty) for r in union2d_curved(ents)]
end
