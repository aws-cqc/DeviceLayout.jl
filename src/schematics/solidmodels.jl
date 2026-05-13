"""
    struct SolidModelTarget <: Target
        technology::ProcessTechnology
        bounding_layers::Vector{Symbol}
        levelwise_layers::Vector{Symbol}
        indexed_layers::Vector{Symbol}
        substrate_layers::Vector{Symbol}
        wave_port_layers::Vector{Symbol}
        ignored_layers::Vector{Symbol}
        retained_physical_groups::Vector{Tuple{String, Int}}
        rendering_options
        postrenderer
    end

Contains information about how to render a `Schematic` to a 3D `SolidModel`.

The `technology` contains parameters like layer heights and thicknesses that are used
to position and extrude 2D geometry elements.

# Metadata Mapping

When rendering entities, metadata is mapped to physical group names as follows:

 1. If `layer(m) == layer(DeviceLayout.NORENDER_META)` (i.e., `:norender`), the entity is skipped and not rendered to the solid model.
 2. If `layer(m)` is in `ignored_layers`, the entity is skipped and not rendered to the solid model.
 3. The base name is taken from `layername(m)`.
 4. If `layer(m)` is in `levelwise_layers`, `"_L\$(level(m))"` is appended.
 5. If `layer(m)` is in `indexed_layers` and `layerindex(m) != 0`, `"_\$(layerindex(m))"` is appended.

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
  - `wave_port_layers`: A list of layer `Symbol`s for layers that are 1D line segments extruded to define wave port boundary conditions.
  - `ignored_layers`: A list of layer `Symbol`s for layers that should be ignored during rendering (mapped to `nothing`). This provides an alternative to using `NORENDER_META` for layers that should be conditionally ignored in solid model rendering but may be needed for other rendering targets.
  - `retained_physical_groups`: Vector of `(name, dimension)` tuples specifying which physical groups to keep after rendering. All other groups are removed.

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
    wave_port_layers::Vector{Symbol}
    ignored_layers::Vector{Symbol}
    retained_physical_groups::Vector{Tuple{String, Int}}
    rendering_options
    postrenderer
end

SolidModelTarget(
    tech;
    bounding_layers=[],
    levelwise_layers=[],
    indexed_layers=[],
    substrate_layers=[],
    wave_port_layers=[],
    ignored_layers=[],
    postrender_ops=[],
    retained_physical_groups=[],
    kwargs...
) = SolidModelTarget(
    tech,
    bounding_layers,
    levelwise_layers,
    indexed_layers,
    substrate_layers,
    wave_port_layers,
    ignored_layers,
    retained_physical_groups,
    (; solidmodel=true, retained_physical_groups=retained_physical_groups, kwargs...),
    postrender_ops
)

function extrusion_ops(t::SolidModelTarget, sch::Schematic)
    ops = []
    for (layer, (thickness, dim)) in pairs(layer_extrusions_dz(t, sch))
        ext = dim == 1 ? "" : "_extrusion"
        push!(ops, (string(layer) * ext, SolidModels.extrude_z!, (layer, thickness, dim)))
    end
    return ops
end

function intersection_ops(t::SolidModelTarget, sch::Schematic)
    bv = string.(bounding_layers(t)) .* "_extrusion"
    wave_ports = []
    for m in element_metadata(sch.coordinate_system)
        if iswaveportlayer(t, layer(m))
            layer_name = _map_meta_fn(t)(m)
            !isnothing(layer_name) && push!(wave_ports, layer_name)
        end
    end
    isempty(bv) && return []
    if length(bv) == 1
        return [
            ("rendered_volume", SolidModels.restrict_to_volume!, (bv[1],)),
            ("exterior_boundary", SolidModels.get_boundary, ("rendered_volume", 3)),
            [
                (
                    "exterior_boundary",
                    SolidModels.difference_geom!,
                    ("exterior_boundary", wave_ports[i], 2, 2),
                    :remove_object => true
                ) for i = 1:length(wave_ports)
            ]...
        ]
    end
    return [
        ("rendered_volume", SolidModels.union_geom!, bv, 3),
        ("rendered_volume", SolidModels.restrict_to_volume!, ("rendered_volume",)),
        ("exterior_boundary", SolidModels.get_boundary, ("rendered_volume", 3)),
        [
            (
                "exterior_boundary",
                SolidModels.difference_geom!,
                ("exterior_boundary", wave_ports[i], 2, 2),
                :remove_object => true
            ) for i = 1:length(wave_ports)
        ]...
    ]
end

bounding_layers(t::SolidModelTarget) = t.bounding_layers

wave_port_layers(t::SolidModelTarget) = t.wave_port_layers

function issublayer(t::SolidModelTarget, ly::Symbol)
    sublayers = t.substrate_layers
    isempty(sublayers) && return false
    return ly in sublayers
end

function iswaveportlayer(t::SolidModelTarget, ly::Symbol)
    wavelayers = wave_port_layers(t)
    isempty(wavelayers) && return false
    return ly in wavelayers
end

function layer_extrusions_dz(target, sch)
    thickness = get(target.technology.parameters, :thickness, (;))
    t_dict = Dict{String, Any}()
    for (ly, t) in pairs(thickness)
        dim = iswaveportlayer(target, ly) ? 1 : 2
        sgn = issublayer(target, ly) ? -1 : 1
        if isempty(size(t))
            if ly in indexed_layers(target)
                for m in element_metadata(sch.coordinate_system)
                    if layer(m) == ly
                        t_dict[_map_meta_fn(target)(m)] = (sgn * t, dim)
                    end
                end
            else
                t_dict[string(ly)] = (sgn * t, dim)
            end
        else
            for (lev, t_level) in pairs(t)
                sgn = isodd(lev) ? sgn : -sgn
                if ly in indexed_layers(target)
                    for m in element_metadata(sch.coordinate_system)
                        if layer(m) == ly && level(m) == lev
                            t_dict[_map_meta_fn(target)(m)] = (sgn * t_level, dim)
                        end
                    end
                else
                    t_dict[string(ly) * "_L$lev"] = (sgn * t_level, dim)
                end
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

        # Skip rendering if layer is in ignored_layers
        (layer(m) in target.ignored_layers) && return nothing

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
    port_directions(sch::Schematic, ly::Symbol) -> Dict{Int, String}

For every entity on layer `ly` in `sch.coordinate_system` that has been indexed
(i.e., `layerindex(metadata) != 0`) AND carries a [`WithDirection`](@ref) style in
its wrapper chain, return a dictionary mapping `layerindex(metadata) -> direction string` suitable for Palace's `LumpedPort`/`WavePort` `Direction` field.

Direction strings are `"+X"`, `"-X"`, `"+Y"`, `"-Y"` for axis-aligned orientations
(within `atol=1e-3` degrees of the nearest axis), or `"[dx, dy, 0.0]"` for arbitrary
orientations.

Must be called AFTER indexing has run. Typical usage is after `render!(sm, sch, target)` or `Cell(sch, target)` for a target whose `indexed_layers(target)`
includes `ly`. If no entities on `ly` are indexed or none carry `WithDirection`,
returns an empty `Dict`. This function does NOT call `index_layer!` itself.

# Example

```julia
render!(sm, sch, target)
dirs = port_directions(sch, :lumped_element)
# Dict(1 => "+Y", 2 => "-X")
```

See also: [`WithDirection`](@ref).
"""
function port_directions(sch::Schematic, ly::Symbol)
    dirs = Dict{Int, String}()
    # Traverse all reachable coordinate systems in the schematic (the schematic's
    # own `coordinate_system` plus every reference descendant). `index_layer!`
    # places indexed entities onto per-node coordsyses, recording the node for
    # each index in `sch.index_dict[ly]` and setting in-component indices to 0.
    # Each `(cs, trans)` pair includes the accumulated reference transform;
    # applying it makes the returned direction reflect the entity's global orientation.
    for (cs, trans) in DeviceLayout.traversal(sch.coordinate_system)
        for (el, m) in zip(elements(cs), element_metadata(cs))
            layer(m) == ly || continue
            idx = layerindex(m)
            idx == 0 && continue
            dir = _extract_direction(el)
            dir === nothing && continue
            haskey(dirs, idx) && error("Repeated index $idx. Before calling `port_directions`, \
                layer $ly should be indexed by rendering with a target whose `indexed_layers` \
                include $ly (or indexed directly with `index_layer!`)")
            dirs[idx] = _direction_string(rotated_direction(dir, trans))
        end
    end
    return dirs
end

# Walk through any nesting of StyledEntity wrappers and return the `direction`
# angle of the innermost `WithDirection` style encountered, or `nothing` if no
# `WithDirection` is present. Handles nesting like
# WithDirection(MeshSized(only_simulated(rect))) and the reverse.
_extract_direction(::DeviceLayout.GeometryEntity) = nothing
function _extract_direction(ent::DeviceLayout.StyledEntity)
    return _extract_direction(ent.ent)
end
function _extract_direction(ent::DeviceLayout.StyledEntity{T,U,WithDirection}) where {T, U <: GeometryEntity{T}}
    return ent.sty.direction
end

# Format a direction angle (CCW from +X, in degrees) as a Palace-compatible
# `Direction` string. Axis-aligned directions return one of "+X", "-X", "+Y",
# "-Y"; off-axis returns a unit-vector literal "[dx, dy, 0.0]" with 6-digit
# precision. Input is normalized modulo 360°.
function _direction_string(angle; atol=1e-3)
    a_deg = mod(ustrip(°, angle), 360.0)
    abs(a_deg - 0.0) < atol && return "+X"
    abs(a_deg - 90.0) < atol && return "+Y"
    abs(a_deg - 180.0) < atol && return "-X"
    abs(a_deg - 270.0) < atol && return "-Y"
    abs(a_deg - 360.0) < atol && return "+X"
    a_rad = a_deg * π / 180.0
    dx = round(cos(a_rad), digits=6)
    dy = round(sin(a_rad), digits=6)
    return "[$(dx), $(dy), 0.0]"
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
    # Index layers
    for ly in indexed_layers(target)
        !haskey(sch.index_dict, ly) && index_layer!(sch::Schematic, ly)
    end
    # Finish assembling postrender operations
    # Extrusions
    # Target specific actions
    # Intersections with rendered volume
    postrender_ops =
        vcat(extrusion_ops(target, sch), target.postrenderer, intersection_ops(target, sch))
    reopen_logfile(sch, :render_solidmodel)
    with_logger(sch.logger) do
        return render!(
            sm,
            sch.coordinate_system;
            zmap=Base.Fix1(layer_z, target),
            postrender_ops=postrender_ops,
            map_meta=_map_meta_fn(target),
            retained_physical_groups=target.retained_physical_groups,
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
