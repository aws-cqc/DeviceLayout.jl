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

"""
    SolidModelRenderContext

Context for generating SolidModel operations for one placed component.
"""
struct SolidModelRenderContext{TT, TF, TP}
    target::TT
    transformation::TF
    path::TP
end

"""
    solidmodel_ops(component, ctx::SolidModelRenderContext)

Return postrender operations contributed by a placed component.
"""
solidmodel_ops(::AbstractComponent, ::SolidModelRenderContext) = []

"""
    SolidModelComponent{T} <: AbstractComponent{T}
    SolidModelComponent(filename, meta; name=uniquename("solid"), scale=1.0, hooks=compass(), parameters=(;))

An external CAD solid imported into a `SolidModel` at its solved schematic transform and
the z of layer `meta`.

It emits no 2D geometry and instead contributes an [`import_solid!`](@ref) operation during
solid-model rendering. `scale` applies a uniform scale, such as for unit conversion.

`hooks` supplies named mate points and defaults to a [`compass`](@ref) at the CAD origin.

Requires a `SolidModelTarget` using the OpenCascade kernel.

# Example

```julia
using DeviceLayout, DeviceLayout.SchematicDrivenLayout
using Unitful: μm, °

chip = SolidModelComponent(
    "chip.step",
    SemanticMeta(:chip);
    hooks=(; mount=PointHook(10μm, 0μm, 180°))
)

g = SchematicGraph("demo")
anchor = add_node!(g, Spacer(; p1=Point(100μm, 0μm)))
fuse!(g, anchor => :p1_east, chip => :mount)

sch = plan(g)
check!(sch)
```

Rendering `sch` with a `SolidModelTarget` imports `chip.step` at the solved pose and layer
height.
"""
@compdef struct SolidModelComponent{T} <: AbstractComponent{T}
    name::String = "solid"
    filename::String = ""
    meta::SemanticMeta = SemanticMeta(:solid)
    scale::Float64 = 1.0
    hooks::NamedTuple = compass(p0=zero(Point{T}))
    parameters::NamedTuple = (;)
end

function SolidModelComponent(
    filename::String,
    meta::SemanticMeta;
    name::String=uniquename("solid"),
    scale=1.0,
    hooks::Union{Nothing, NamedTuple}=nothing,
    parameters::NamedTuple=(;)
)
    T = typeof(1.0UPREFERRED)
    hks = isnothing(hooks) ? compass(p0=zero(Point{T})) : hooks
    return SolidModelComponent{T}(;
        name,
        filename,
        meta,
        scale=Float64(scale),
        hooks=hks,
        parameters
    )
end

hooks(c::SolidModelComponent) = c.hooks

function solidmodel_ops(c::SolidModelComponent, ctx::SolidModelRenderContext)
    dest = string(name(c), "_", join(ctx.path, "_"))
    z = layer_z(ctx.target.technology, c.meta)
    return [(
        dest,
        SolidModels.import_solid!,
        (c.filename,),
        :transform => ctx.transformation,
        :z => z,
        :scale => c.scale,
        :groupname => nothing
    )]
end

"""
    component_solidmodel_ops(sch::Schematic, target::Target)

Collect SolidModel operations from placed components using their solved global transforms.
"""
function component_solidmodel_ops(sch::Schematic, target::Target)
    ops = []
    for idx in find_components(AbstractComponent, sch)
        path = idx isa Tuple ? idx : (idx,)
        node = getpath(sch.graph, path...)[end]
        ctx = SolidModelRenderContext(target, transformation(sch, path), path)
        append!(ops, solidmodel_ops(component(node), ctx))
    end
    return ops
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
                # Levelwise thickness is measured away from the substrate surface, using the
                # same level convention as `layer_z`: odd levels are substrate tops (outward
                # is +z), even levels are substrate bottoms (outward is -z).
                lev_sgn = isodd(lev) ? sgn : -sgn
                if ly in indexed_layers(target)
                    for m in element_metadata(sch.coordinate_system)
                        if layer(m) == ly && level(m) == lev
                            t_dict[_map_meta_fn(target)(m)] = (lev_sgn * t_level, dim)
                        end
                    end
                else
                    t_dict[string(ly) * "_L$lev"] = (lev_sgn * t_level, dim)
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
    # Import component solids before target operations that may reference or intersect them.
    postrender_ops = vcat(
        extrusion_ops(target, sch),
        component_solidmodel_ops(sch, target),
        target.postrenderer,
        intersection_ops(target, sch)
    )
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
