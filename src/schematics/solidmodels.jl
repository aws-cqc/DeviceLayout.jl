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
    SolidModelComponent{T} <: AbstractComponent{T}
    SolidModelComponent(filename, meta; name=uniquename("solid"), scale=1.0, hooks=compass(),
                        parameters=(;))

An external CAD solid imported into a `SolidModel` at its solved schematic transform and
the z of layer `meta`.

!!! warning "Experimental API"

    `SolidModelComponent` and [`SolidModels.import_solid!`](@ref) are experimental and may
    change in minor versions as they are stress tested and harmonized with the experimental
    solid-model pipeline. The names of the generated physical groups are the most likely to
    change. `SolidModelComponent` is not exported.

The level of `meta` only enters the z-height calculation. Unlike rendered layers, a part on
an even level is not mirrored to face the other way.

Like rendered geometry, the part is skipped if its layer is in the target's
`ignored_layers` or is the `NORENDER_META` layer.

It emits no 2D geometry and instead contributes an [`SolidModels.import_solid!`](@ref)
operation during solid-model rendering. `scale` applies a uniform scale, such as for unit
conversion.

`hooks` supplies named mate points and defaults to a [`compass`](@ref) at the CAD origin.

The imported solid lands in a physical group named after its node `id`. Physical groups
carried by the file (a `.xao`) are registered as `"<id>_<name>"`, so the same component
placed in several nodes gives distinct group names that trace back to the schematic.

The `component_fragment` option of `render!(sm, sch, target)` selects when the parts are
imported and made conformal with the rest of the model.

Requires a `SolidModelTarget` using the OpenCascade kernel.

# Example

```julia
using DeviceLayout, DeviceLayout.SchematicDrivenLayout
using Unitful: μm, °

chip = SchematicDrivenLayout.SolidModelComponent(
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
    filename::String
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

# The `import_solid!` operation for `c` placed in node `id` with global transformation `tr`.
function _import_op(c::SolidModelComponent, id::String, tr, target::Target)
    return (
        id,
        SolidModels.import_solid!,
        (c.filename,),
        :transform => tr,
        :z => layer_z(target.technology, c.meta),
        :scale => c.scale,
        :groupname => nothing,
        :group_map => nm -> string(id, "_", nm)
    )
end

# `fragment_near!` over every imported part at once. Fragmentation updates the parts' own
# groups, and returning no entities leaves the destination group untouched, so one call
# does not merge the parts into a single group.
function _fragment_components!(sm::SolidModels.SolidModel, ids)
    SolidModels.fragment_near!(sm, ids)
    return []
end

const _COMPONENT_FRAGMENT_MODES = (:global, :near)

"""
    component_solidmodel_ops(sch::Schematic, target::Target; fragment=:global)
        -> (; postrender, post_fragment)

Collect the import operations of the `SolidModelComponent`s in `sch` at their solved global
transforms, split by when they run. With `fragment=:global` they all go in `postrender`.
With `fragment=:near` they go in `post_fragment`, followed by one
[`SolidModels.fragment_near!`](@ref) over all of them, so every part is in place before any
is fragmented.
"""
function component_solidmodel_ops(sch::Schematic, target::Target; fragment=:global)
    fragment in _COMPONENT_FRAGMENT_MODES || throw(
        ArgumentError(
            "component_fragment must be one of $(_COMPONENT_FRAGMENT_MODES), got $(repr(fragment))"
        )
    )
    ops = map(find_components(SolidModelComponent, sch)) do idx
        # A component inside a composite is found by its path of node indices; its id is
        # the node ids along that path joined by "." as in `add_graph!`.
        path = idx isa Tuple ? idx : (idx,)
        nodes = getpath(sch.graph, path...)
        c = component(nodes[end])
        _isignored(target, c.meta) && return nothing
        id = join((n.id for n in nodes), ".")
        return _import_op(c, id, transformation(sch, path), target)
    end
    ops = filter(!isnothing, ops)
    (fragment == :global || isempty(ops)) && return (; postrender=ops, post_fragment=[])
    ids = first.(ops)
    near = (first(ids), _fragment_components!, (ids,))
    return (; postrender=[], post_fragment=vcat(ops, [near]))
end

# Keyword arguments that `render!(sm, sch, target)` consumes itself rather than passing on.
_without_schematic_options(kw) = (;
    (
        k => v for (k, v) in pairs(kw) if !(k in (:post_fragment_ops, :component_fragment))
    )...
)

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

# Whether geometry on `m`'s layer is left out of a `SolidModel` rendered with `target`.
_isignored(target::SolidModelTarget, m::DeviceLayout.Meta) =
    layer(m) == layer(DeviceLayout.NORENDER_META) || layer(m) in target.ignored_layers

function _map_meta_fn(target::SolidModelTarget)
    # By default, target maps a layer to layername (string)
    # Append -L$(level) and/or _$(index) if appropriate
    return m -> begin
        # Skip rendering if this is the NORENDER_META layer or in ignored_layers
        _isignored(target, m) && return nothing

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

`component_fragment` and `post_fragment_ops` may be given as keywords or in the target's
rendering options.

`component_fragment` selects how
[`SolidModelComponent`](@ref SchematicDrivenLayout.SolidModelComponent) parts are made
conformal with the rest of the model:

  - `:global` (default) imports them before the global fragmentation pass, which fragments
    everything with everything. Like other postrender geometry, they are clipped to the
    target's `bounding_layers`.
  - `:near` imports them after that pass and runs one [`SolidModels.fragment_near!`](@ref)
    over all of them, which fragments only the entities near the parts. This is faster for
    a large model, at the cost of the caveats listed for `fragment_near!`. The parts are not
    clipped to `bounding_layers`, so faces of a part extending past the bounding volume are
    not in the `"exterior_boundary"` group.

`post_fragment_ops` run after the components' operations, so that for example
[`SolidModels.apply_precedence`](@ref) sees the imported parts already conformal.

A large part that is already conformal inside can be imported faster by hand: an [`SolidModels.import_solid!`](@ref) in `post_fragment_ops`, followed by a
`fragment_near!` of the parts that touch it rather than of the large part itself.
"""
function render!(sm::SolidModel, sch::Schematic, target::Target; strict=:error, kwargs...)
    sch.checked[] || error(
        "cannot render an unchecked Schematic. Run check!(sch::Schematic), or override by setting sch.checked[] = true (not recommended!)"
    )
    reopen_logfile(sch, :render_solidmodel)
    try
        with_logger(sch.logger) do
            with_geometry_resolution_context() do
                # Index layers
                for ly in indexed_layers(target)
                    !haskey(sch.index_dict, ly) && index_layer!(sch::Schematic, ly)
                end
                # Import component solids before target operations that may reference or
                # intersect them.
                component_ops = component_solidmodel_ops(
                    sch,
                    target;
                    fragment=get(
                        kwargs,
                        :component_fragment,
                        get(target.rendering_options, :component_fragment, :global)
                    )
                )
                # Finish assembling postrender operations: extrusions, imported component
                # solids, target-specific actions, and intersections with the rendered volume.
                postrender_ops = vcat(
                    extrusion_ops(target, sch),
                    component_ops.postrender,
                    target.postrenderer,
                    intersection_ops(target, sch)
                )
                # Components' operations come first, so that user operations (e.g.
                # `apply_precedence`) see the imported parts already fragmented with the model.
                post_fragment_ops = vcat(
                    component_ops.post_fragment,
                    get(target.rendering_options, :post_fragment_ops, []),
                    get(kwargs, :post_fragment_ops, [])
                )
                return render!(
                    sm,
                    sch.coordinate_system;
                    zmap=Base.Fix1(layer_z, target),
                    postrender_ops=postrender_ops,
                    post_fragment_ops=post_fragment_ops,
                    map_meta=_map_meta_fn(target),
                    retained_physical_groups=target.retained_physical_groups,
                    _without_schematic_options(kwargs)...,
                    _without_schematic_options(target.rendering_options)...
                )
            end
        end
    finally
        close_logfile(sch)
    end
    return check_render_strict(sch, strict, :render_solidmodel)
end
