"""
    struct SolidModelTarget <: Target
        technology::ProcessTechnology
        bounding_layers::Vector{Symbol}
        levelwise_layers::Vector{Symbol}
        indexed_layers::Vector{Symbol}
        substrate_layers::Vector{Symbol}
        rendering_options::NamedTuple
        postrenderer
    end

Contains information about how to render a `Schematic` to a 3D `SolidModel`.

The `technology` contains parameters like layer heights and thicknesses that are used
to position and extrude 2D geometry elements.

# Metadata Mapping

When rendering entities, metadata is mapped to physical group names as follows:

 1. If `layer(m) == layer(DeviceLayout.NORENDER_META)` (i.e., `:norender`), the entity is skipped and not rendered to the solid model.
 2. The base name is taken from `layername(m)`.
 3. If `layer(m)` is in `levelwise_layers`, `"_L\$(level(m))"` is appended.
 4. If `layer(m)` is in `indexed_layers` and `layerindex(m) != 0`, `"_\$(layerindex(m))"` is appended.

This behavior matches `LayoutTarget` for consistency across rendering targets.

# Rendering Options

The `rendering_options` include any keyword arguments to be passed down to the lower-level
`render!(::SolidModel, ::CoordinateSystem; kwargs...)`. The target also includes some
3D-specific options:

  - `bounding_layers`: A list of layer `Symbol`s. These layers are extruded according to `technology` to
    define the rendered volume, and then all other layers and `technology`-based extrusions are replaced with their
    intersection with the rendered volume.
  - `levelwise_layers`: A list of layer `Symbol`s to be turned into `PhysicalGroup`s "levelwise".
    That is, rather than create a single `PhysicalGroup` for all entities with the given layer symbol,
    a group is created for each `level` value `l` with `"_L\$l"` appended.
  - `indexed_layers`: A list of layer `Symbol`s to be turned into separate `PhysicalGroup`s with `"_\$i"` appended for each index `i`. These layers will be automatically indexed if not already present in a `Schematic`'s `index_dict`.
  - `substrate_layers`: A list of layer `Symbol`s for layers that are extruded by their
    `technology` into the substrate, rather than away from it.

The `postrenderer` is a list of geometry kernel commands that create new named groups of
entities from other groups, for example by geometric Boolean operations like intersection.
These follow the extrusions and `bounding_layers` intersections generated according to
the `technology` and `rendering_options`.
"""
struct SolidModelTarget <: Target
    technology::ProcessTechnology
    bounding_layers::Vector{Symbol}
    levelwise_layers::Vector{Symbol}
    indexed_layers::Vector{Symbol}
    substrate_layers::Vector{Symbol}
    preserved_groups::Vector{Tuple{String, Int}}
    rendering_options
    postrenderer
end

SolidModelTarget(
    tech;
    bounding_layers=[],
    levelwise_layers=[],
    indexed_layers=[],
    substrate_layers=[],
    postrender_ops=[],
    preserved_groups=[],
    kwargs...
) = SolidModelTarget(
    tech,
    bounding_layers,
    levelwise_layers,
    indexed_layers,
    substrate_layers,
    preserved_groups,
    (; solidmodel=true, kwargs...),
    postrender_ops
)

function extrusion_ops(t::SolidModelTarget)
    return [
        (string(layer) * "_extrusion", SolidModels.extrude_z!, (layer, thickness)) for
        (layer, thickness) in pairs(layer_extrusions_dz(t))
    ]
end

function intersection_ops(t::SolidModelTarget)
    bv = string.(bounding_layers(t)) .* "_extrusion"
    isempty(bv) && return []
    if length(bv) == 1
        return [
            ("rendered_volume", SolidModels.restrict_to_volume!, (bv[1],)),
            ("exterior_boundary", SolidModels.get_boundary, ("rendered_volume", 3))
        ]
    end
    return [
        ("rendered_volume", SolidModels.union_geom!, (bv[1], bv[2], 3, 3)),
        [
            ("rendered_volume", SolidModels.union_geom!, ("rendered_volume", bv[i], 3, 3))
            for i = 3:length(bv)
        ]...,
        ("rendered_volume", SolidModels.restrict_to_volume!, ("rendered_volume",)),
        ("exterior_boundary", SolidModels.get_boundary, ("rendered_volume", 3))
    ]
end

bounding_layers(t::SolidModelTarget) = t.bounding_layers

function issublayer(t::SolidModelTarget, ly::Symbol)
    sublayers = t.substrate_layers
    isempty(sublayers) && return false
    return ly in sublayers
end

function layer_extrusions_dz(target)
    thickness = get(target.technology.parameters, :thickness, (;))
    t_dict = Dict{String, Any}()
    for (layer, t) in pairs(thickness)
        sgn = issublayer(target, layer) ? -1 : 1
        if isempty(size(t))
            t_dict[string(layer)] = sgn * t
        else
            for (level, t_level) in pairs(t)
                sgn = isodd(level) ? sgn : -sgn
                t_dict[string(layer) * "_L$level"] = sgn * t_level
            end
        end
    end
    return t_dict
end
layer_height(t::Target, m::DeviceLayout.Meta) = layer_height(t.technology, m)
chip_thicknesses(t::Target) = chip_thicknesses(t.technology)
flipchip_gaps(t::Target) = flipchip_gaps(t.technology)

levelwise_layers(target) = target.levelwise_layers
indexed_layers(target) = target.indexed_layers

layer_z(t::Target, m::DeviceLayout.Meta) = layer_z(t.technology, m)

function _map_meta_fn(target::SolidModelTarget)
    # By default, target maps a layer to layername (string)
    # Append -L$(level) and/or _$(index) if appropriate
    return m -> begin
        # Skip rendering if this is the NORENDER_META layer
        (layer(m) == layer(DeviceLayout.NORENDER_META)) && return nothing

        name = layername(m)
        if layer(m) in levelwise_layers(target)
            name = name * "_L$(level(m))"
        end
        if layer(m) in indexed_layers(target) && layerindex(m) != 0
            name = name * "_$(layerindex(m))"
        end
        return name
    end
end

"""
    render!(sm::SolidModel, sch::Schematic, target::Target; strict=:error, kwargs...)

Render `sch` to `sm`, using rendering settings from `target`.

The `strict` keyword should be `:error`, `:warn`, or `:no`.

The `strict=:error` keyword option causes `render!` to throw an error if any errors were logged while
building component geometries or while rendering geometries to `cs`.
This is enabled by default, but can be disabled with `strict=:no`, in which case any component which was not
successfully built will have an empty geometry, and any non-fatal rendering errors will be
ignored as usual.
Using `strict=:no` is recommended only for debugging purposes.

The `strict=:warn` keyword option causes `render!` to throw an error if any warnings were logged.
This is disabled by default. Using `strict=:warn` is suggested for use in automated
pipelines, where warnings may require human review.

Additional keyword arguments may be used for certain entity types for controlling
how geometry entities are converted to primitives and added to `sm`.
"""
function render!(sm::SolidModel, sch::Schematic, target::Target; strict=:error, kwargs...)
    sch.checked[] || error(
        "Cannot render an unchecked Schematic. Run check!(sch::Schematic), or override by setting sch.checked[] = true (not recommended!)"
    )
    # Finish assembling postrender operations
    # Extrusions
    # Target specific actions
    # Intersections with rendered volume
    postrender_ops =
        vcat(extrusion_ops(target), target.postrenderer, intersection_ops(target))
    # Index layers
    for ly in indexed_layers(target)
        !haskey(sch.index_dict, ly) && index_layer!(sch::Schematic, ly)
    end
    reopen_logfile(sch, :render_solidmodel)
    with_logger(sch.logger) do
        return render!(
            sm,
            sch.coordinate_system;
            zmap=Base.Fix1(layer_z, target),
            postrender_ops=postrender_ops,
            map_meta=_map_meta_fn(target),
            kwargs...,
            target.rendering_options...
        )
    end
    close_logfile(sch)
    if strict == :error
        max_level_logged(sch, :render_solidmodel) >= Logging.Error && error(
            "Encountered errors while rendering. See $(sch.logger.logname) for details. Render with `strict=:no` to continue anyway (not recommended except for debugging)."
        )
    elseif strict == :warn
        max_level_logged(sch, :render_solidmodel) >= Logging.Warn && error(
            "Encountered warnings while rendering. See $(sch.logger.logname) for details. Render with `strict=:error` to continue anyway."
        )
    elseif strict != :no
        @warn "Keyword `strict` in `render!` should be `:error`, `:warn`, or `:no` (got `:$strict`). Proceeding as though `strict=:no` were used."
    end
end
