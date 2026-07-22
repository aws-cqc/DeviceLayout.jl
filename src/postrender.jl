# Post-render passes: operations applied to the rendered geometry of a layer as a whole,
# as opposed to entity styles like `Rounded`, which are applied to entities as they are
# created. The distinguishing feature is that these passes see the union of a layer's
# flattened geometry, so they can handle results that emerge only after composition
# (e.g. corners where separately-rendered polygons meet).

"""
    round_layer(geom::Union{Cell,CoordinateSystem}, layer::DeviceLayout.Meta, radius;
        relative=false, min_side_len=nothing, min_angle=1e-3)

Return the geometry of `geom` in `layer` as a `Vector{CurvilinearRegion}` with corners
rounded to `radius`.

The elements of `geom` matching `layer` (using [`layer_inclusion`](@ref) semantics,
including elements inside references) are flattened and unioned before rounding, so
corners are rounded correctly even where separately-drawn shapes meet. Rounding is
symbolic: the fillets in the result are true arcs, and any holes in the unioned geometry
are preserved as holes of the resulting regions (with their corners rounded too).

For `CoordinateSystem` input, the union preserves curves already present in the input
(arcs from paths, `Rounded` entities, circles, ...) using [`union2d_curved`](@ref), and
corners between straight edges and arcs are rounded natively. For `Cell` input, elements
are already plain polygons; they are unioned with [`union2d`](@ref) after widening integer
coordinates to floating point (fillet arcs are not representable with integer coordinates).

Note that the association between input elements and their metadata is intentionally
aggregated: N input elements produce M ≤ N output regions, and no per-element metadata is
carried over.

# Keyword arguments

  - `relative`: if `true`, `radius` must be a dimensionless number, and the radius of
    curvature at each vertex is `radius * min(l₁, l₂)` where `l₁` and `l₂` are the lengths
    of the two adjacent sides (see [`Polygons.Rounded`](@ref)).
  - `min_side_len`: the minimum side length adjacent to a corner for that corner to be
    rounded. Defaults to `radius` (or to zero if `relative=true`).
  - `min_angle`: corners where adjacent sides are collinear within this tolerance (in
    radians) are not rounded.
"""
function round_layer(
    geom::Union{Cell, CoordinateSystem},
    layer::Meta,
    radius::Coordinate;
    relative::Bool=false,
    min_side_len=nothing,
    min_angle::Real=1e-3
)
    sty = _round_layer_style(
        float(coordinatetype(geom)),
        radius,
        relative,
        min_side_len,
        min_angle
    )
    return _rounded_regions(geom, layer, sty)
end

"""
    round_layer!(geom::Union{Cell,CoordinateSystem}, layer::DeviceLayout.Meta, radius;
        target_layer::DeviceLayout.Meta, remap_originals=nothing,
        relative=false, min_side_len=nothing, min_angle=1e-3, kwargs...)

Round the corners of the geometry of `geom` in `layer` to `radius`, rendering the result
into `geom` itself with metadata `target_layer`.

The rounded result is computed as in [`round_layer`](@ref) (flatten, union, round
symbolically) and rendered at the top level of `geom`. The original elements are left in
place; if `remap_originals` is set to a `DeviceLayout.Meta`, the top-level elements of
`geom` matching `layer` are retagged with that metadata instead (elements inside
referenced structures are not modified, since those structures may be shared). Text
elements are unaffected.

For a `CoordinateSystem` target, the rounded regions are placed symbolically (arcs stay
exact). For a `Cell` target, they are discretized on render; keyword arguments (e.g.
`atol`) are forwarded to `render!` to control the discretization, and `target_layer` and
`remap_originals` must be `GDSMeta`. Because a `Cell` stores the discretized result, this
pass should be applied only once, as a final step before export: re-applying it to its
own output would operate on the sampled arc points rather than true arcs, multiplying
vertices with each pass. (This does not apply to `CoordinateSystem` targets, where the
result stays symbolic.)

See [`round_layer`](@ref) for the rounding keyword arguments.
"""
function round_layer!(
    geom::Union{Cell, CoordinateSystem},
    layer::Meta,
    radius::Coordinate;
    target_layer::Meta,
    remap_originals::Union{Meta, Nothing}=nothing,
    relative::Bool=false,
    min_side_len=nothing,
    min_angle::Real=1e-3,
    kwargs...
)
    if geom isa Cell
        S = coordinatetype(geom)
        float(S) === S || throw(
            ArgumentError(
                "cannot render rounded regions into a `Cell` with integer coordinate type $S; the discretized fillet arcs are not representable. Use `round_layer` to get the rounded regions instead."
            )
        )
        target_layer isa GDSMeta ||
            throw(ArgumentError("`target_layer` must be a `GDSMeta` for a `Cell` target."))
        isnothing(remap_originals) ||
            remap_originals isa GDSMeta ||
            throw(
                ArgumentError("`remap_originals` must be a `GDSMeta` for a `Cell` target.")
            )
    end
    regions = round_layer(geom, layer, radius; relative, min_side_len, min_angle)
    # Remap before rendering the rounded result, so that when `target_layer` matches
    # `layer` the newly rendered elements are not themselves retagged.
    if !isnothing(remap_originals)
        keep = layer_inclusion(layer, [])
        meta = element_metadata(geom)
        for i in eachindex(meta)
            keep(meta[i]) && (meta[i] = remap_originals)
        end
    end
    for r in regions
        render!(geom, r, target_layer; kwargs...)
    end
    return geom
end

# Build the `Rounded` style carrying all rounding parameters, with the style's coordinate
# type pinned to the (float) coordinate type of the input geometry. `RelativeRounded` is
# not used here because it guesses its coordinate type from preferred units, which fails
# for unitless geometry.
function _round_layer_style(
    ::Type{V},
    radius,
    relative::Bool,
    min_side_len,
    min_angle
) where {V}
    if relative
        radius isa Real || throw(
            ArgumentError(
                "`relative=true` requires a dimensionless `radius` (a fraction of the shorter adjacent side length), got $radius."
            )
        )
        msl = isnothing(min_side_len) ? zero(V) : min_side_len
        return Rounded{V}(;
            rel_r=Float64(radius),
            min_side_len=msl,
            min_angle=Float64(min_angle)
        )
    end
    r = convert(V, radius)
    msl = isnothing(min_side_len) ? r : min_side_len
    return Rounded{V}(; abs_r=r, min_side_len=msl, min_angle=Float64(min_angle))
end

function _rounded_regions(cell::Cell{S}, layer, sty) where {S}
    V = float(S)
    polys = flat_elements(cell, layer)
    isempty(polys) && return CurvilinearRegion{V}[]
    # Widen to float before the union so the fillet arcs produced by rounding are
    # representable (they cannot have integer coordinates).
    return to_curvilinear(union2d(convert.(Polygon{V}, polys)), sty)
end

function _rounded_regions(cs::CoordinateSystem{S}, layer, sty) where {S}
    float(S) === S || throw(
        ArgumentError(
            "`round_layer` requires a floating-point coordinate type for `CoordinateSystem` input, got $S."
        )
    )
    ents = flat_elements(cs, layer)
    isempty(ents) && return CurvilinearRegion{S}[]
    # Curve-preserving union: arcs already present in the input survive symbolically
    # rather than being discretized, and line-arc corners are rounded natively.
    return [to_curvilinear(r, sty) for r in union2d_curved(ents)]
end
