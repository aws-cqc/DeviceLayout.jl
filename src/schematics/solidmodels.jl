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
        prerenderer
    end

Contains information about how to render a `Schematic` to a 3D `SolidModel`.

The `technology` contains parameters like layer heights and thicknesses that are used
to position and extrude 2D geometry elements.

# Metadata Mapping

When rendering entities, metadata is mapped to physical group names as follows:

 1. If `m` is experimental solid model metadata (`SolidModelsExperimental.LayerRef` or `SolidModelsExperimental.LocatorMeta`), or if `layer(m) == layer(DeviceLayout.NORENDER_META)` (i.e., `:norender`), the entity is skipped and not rendered to the solid model.
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

The `prerenderer`, given by the `prerender_ops` keyword, is a list of 2D operations that
[`render_conformal!`](@ref)`(sm, sch, target)` uses instead of the `postrenderer` to form
2D groups, such as the metal, from other groups before they are emitted. It is authored
like the `postrenderer`, with the operations [`union_geom2d!`](@ref) and
[`difference_geom2d!`](@ref), which act on 2D region groups rather than on entities in
the solid model. `render!` doesn't use the `prerenderer`.

!!! warning "Experimental API"

    `prerender_ops`, its operations and `render_conformal!(sm, sch, target)` are experimental
    and may change in minor versions, for example as 3D construction is added.
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
    prerenderer
end
# The positional form without a `prerenderer`
SolidModelTarget(
    technology,
    bounding_layers,
    levelwise_layers,
    indexed_layers,
    substrate_layers,
    wave_port_layers,
    ignored_layers,
    retained_physical_groups,
    rendering_options,
    postrenderer
) = SolidModelTarget(
    technology,
    bounding_layers,
    levelwise_layers,
    indexed_layers,
    substrate_layers,
    wave_port_layers,
    ignored_layers,
    retained_physical_groups,
    rendering_options,
    postrenderer,
    []
)

SolidModelTarget(
    tech;
    bounding_layers=[],
    levelwise_layers=[],
    indexed_layers=[],
    substrate_layers=[],
    wave_port_layers=[],
    ignored_layers=[],
    prerender_ops=[],
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
    postrender_ops,
    collect(Any, prerender_ops) # so that helpers can add any operation
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
                    if layer(m) == ly && !is_experimental_meta(m)
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
                        if layer(m) == ly && level(m) == lev && !is_experimental_meta(m)
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
    is_experimental_meta(m) ||
    layer(m) == layer(DeviceLayout.NORENDER_META) ||
    layer(m) in target.ignored_layers

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
    SolidModels.design_velocities(f, p0::NamedTuple, target::SolidModelTarget; kwargs...)

Return the design velocities of the solid model that `render!(sm, f(p), target)` renders,
with respect to the parameters in `p0`. `f(p::NamedTuple)` returns a planned and checked
`Schematic`.

The metadata mapping, z coordinates, extrusions and rendering options are those of `target`,
as in [`render!(::SolidModel, ::Schematic, ::Target)`](@ref), so that the velocities are those
of the rendered geometry. Keyword arguments are as in
[`SolidModels.design_velocities`](@ref).
"""
function SolidModels.design_velocities(
    f,
    p0::NamedTuple,
    target::SolidModelTarget;
    kwargs...
)
    map_meta = _map_meta_fn(target)
    sch0 = f(p0)
    sch0 isa Schematic || throw(
        ArgumentError("the layout function must return a Schematic, got $(typeof(sch0))")
    )
    extrusions = layer_extrusions_dz(target, sch0)
    function thickness(m)
        name = map_meta(m)
        isnothing(name) && return 0.0μm
        t, dim = get(extrusions, string(name), (0.0μm, 2))
        # Wave port layers are extruded line segments, not sheets.
        return dim == 2 ? t : 0.0μm
    end
    layout(p) = (p == p0 ? sch0 : f(p)).coordinate_system
    return SolidModels.design_velocities(
        layout,
        p0;
        map_meta=map_meta,
        zmap=Base.Fix1(layer_z, target),
        thickness=thickness,
        _without_schematic_options(target.rendering_options)...,
        kwargs...
    )
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

# ─── Conformal schematic render ──────────────────────────────────────────────

# 1D elements (wave ports) are extruded only in 3D, so the 2D conformal render skips them
_is_1d(e) = e isa LineSegment || (e isa DeviceLayout.StyledEntity && _is_1d(e.ent))

# ── Prerender operations ─────────────────────────────────────────────────────
#
# A prerender op is a tuple `(dest, op_fn, args, op_kwargs...)`, as in `postrender_ops`.
# `op_fn(groups, args...; op_kwargs...)` is called with `groups`, a `Dict` from group name
# to geometry, and returns the new `Vector{CurvilinearRegion}` for `dest`. A group holds the
# primitives of its layer's elements, as `to_primitives` gives them with their curves, until
# an op replaces it with regions.

_names(x) = x isa AbstractVector ? string.(x) : [string(x)]
_group_geom(groups, x) = reduce(vcat, (get(groups, n, []) for n in _names(x)); init=[])
_missing_groups(groups, x) = filter(n -> !haskey(groups, n), _names(x))
_not_groups(names) =
    length(names) == 1 ? "$(only(names)) is not a group" :
    "$(join(names, ", ")) are not groups"

function _check_2d(op, d1, d2)
    return d1 == d2 == 2 || throw(
        ArgumentError(
            "$op: prerender operations act on 2D groups, got dimensions $d1, $d2"
        )
    )
end

"""
    union_geom2d!(groups, object, tool=object, d1=2, d2=2;
        remove_object=false, remove_tool=false)
    union_geom2d!(groups, object, d; remove_object=true)

Prerender operation: the union of the groups `object` and `tool`, or of `object` with
itself, each a group name or a vector of names. Returns the merged
`Vector{CurvilinearRegion}` from [`union2d_curved`](@ref), which keeps the curves it doesn't
cut. As in `SolidModels.union_geom!`, missing groups are logged and the others are used,
`remove_object` / `remove_tool` remove the inputs, and the form with a single dimension `d`
is a self-union that removes `object`. The dimensions must be 2. See `prerender_ops` in
[`SolidModelTarget`](@ref).

!!! warning "Experimental API"

    Prerender operations are experimental; see [`render_conformal!`](@ref).
"""
function union_geom2d!(groups::AbstractDict, object, tool=object, d1=2, d2=2; kwargs...)
    _check_2d(:union_geom2d!, d1, d2)
    missing = unique([_missing_groups(groups, object); _missing_groups(groups, tool)])
    if length(missing) == length(unique([_names(object); _names(tool)]))
        @error "union_geom2d!(groups, $object, $tool): $(_not_groups(missing))."
    elseif !isempty(missing)
        @info "union_geom2d!(groups, $object, $tool): $(_not_groups(missing)), using the rest."
    end
    operand = _group_geom(groups, object)
    _names(tool) == _names(object) || append!(operand, _group_geom(groups, tool))
    _consume!(groups, object, tool; kwargs...)
    return isempty(operand) ? CurvilinearRegion[] : union2d_curved(operand)
end
union_geom2d!(groups::AbstractDict, object, d::Integer; remove_object=true, kwargs...) =
    union_geom2d!(groups, object, object, d, d; remove_object, kwargs...)

"""
    difference_geom2d!(groups, object, tool, d1=2, d2=2;
        remove_object=false, remove_tool=false)

Prerender operation: the difference of the groups `object` and `tool`, each a group name or
a vector of names. Returns the resulting `Vector{CurvilinearRegion}` from
[`difference2d_curved`](@ref), which keeps the curves it doesn't cut. As in
`SolidModels.difference_geom!`, a missing `object` is an error, other missing groups are
logged and the rest are used, and `remove_object` / `remove_tool` remove the inputs. The
dimensions `d1` and `d2` must be 2. See `prerender_ops` in [`SolidModelTarget`](@ref).

!!! warning "Experimental API"

    Prerender operations are experimental; see [`render_conformal!`](@ref).
"""
function difference_geom2d!(groups::AbstractDict, object, tool, d1=2, d2=2; kwargs...)
    _check_2d(:difference_geom2d!, d1, d2)
    missing_object = _missing_groups(groups, object)
    missing = unique([missing_object; _missing_groups(groups, tool)])
    if length(missing_object) == length(_names(object))
        @error "difference_geom2d!(groups, $object, $tool): $(_not_groups(missing_object))."
    elseif !isempty(missing)
        @info "difference_geom2d!(groups, $object, $tool): $(_not_groups(missing)), using the rest."
    end
    obj = _group_geom(groups, object)
    result =
        isempty(obj) ? CurvilinearRegion[] :
        collect(difference2d_curved(obj, _group_geom(groups, tool)))
    _consume!(groups, object, tool; kwargs...)
    return result
end

# Honor `remove_object` / `remove_tool`, after the op has read its inputs
function _consume!(groups, object, tool; remove_object=false, remove_tool=false)
    remove_object && foreach(n -> delete!(groups, n), _names(object))
    remove_tool && foreach(n -> delete!(groups, n), _names(tool))
    return nothing
end

# Run `ops` over `groups`, storing each op's result at its destination. `boolean_out` collects
# the names of the groups the ops produced. `zs_by_group` holds the heights of each group's
# elements; a destination gets those of its inputs, which must agree, since each group is
# rendered in one plane.
function _run_prerender_ops!(groups::AbstractDict{String}, ops; zs_by_group, boolean_out)
    for op in ops
        dest, op_fn, args, op_kwargs = string(op[1]), op[2], op[3], op[4:end]
        inputs = filter(a -> !(a isa Integer), collect(args[1:min(2, length(args))]))
        zs = []
        for name in reduce(vcat, _names.(inputs); init=String[]),
            z in get(zs_by_group, name, [])

            _push_z!(zs, z)
        end
        length(zs) > 1 && throw(
            ArgumentError(
                "render_conformal!: the prerender operation forming $dest reads groups at " *
                "z = $(join(zs, ", ")), but each group is rendered in one plane"
            )
        )
        isempty(zs) || (zs_by_group[dest] = zs)
        groups[dest] = op_fn(groups, args...; op_kwargs...)
        push!(boolean_out, dest)
    end
    return groups
end
_push_z!(zs, z) = any(==(z), zs) ? zs : push!(zs, z)

"""
    render_conformal!(sm::SolidModel, sch::Schematic, target::SolidModelTarget;
        strict=:error, context=SolidModels.ConformalRenderContext(), kwargs...)

Render `sch` to `sm` using `target`, as [`render!`](@ref)`(sm, sch, target)` does, but through
the conformal render: shared boundaries resolve to a single OpenCASCADE curve through an
edge cache rather than a fragment pass.

!!! warning "Experimental API"

    This method, the target's `prerender_ops` and the operations [`union_geom2d!`](@ref) and
    [`difference_geom2d!`](@ref) are experimental and may change in minor versions, for
    example as 3D construction is added and as they are harmonized with the experimental
    solid-model pipeline. Current limitations:

      - Only 2D geometry is rendered, each group in the plane at its layer's height, so an
        emitted group, or the inputs of a prerender operation, at several heights throw.
      - `postrender_ops`, `post_fragment_ops` and the target's 3D operations (extrusions,
        `bounding_layers` intersections, bridges) are not run.
      - 1D elements such as wave ports are skipped.
      - `SolidModelComponent` parts are not imported; a warning says so.
      - A curve that a prerender operation cuts, or that an overlapping element of its group
        crosses, comes out as a polyline, where `render!` keeps it a curve (see
        [`recover_curves`](@ref)).
      - The emitted groups must not overlap, as
        [`SolidModels.render_conformal!`](@ref)`(sm, cs)` requires.

The target's layers, levels, indices, `rendering_options` and physical-group names are used
as in `render!`. Each element is converted with `to_primitives` and the rendering options, as
in `render!`, so optional styles resolve the same way: with `simulation=true`,
fabrication-only elements (`not_simulated`) are dropped. The 2D geometry is formed from these
primitives by the target's `prerender_ops` instead of its `postrender_ops`:
[`union_geom2d!`](@ref) and [`difference_geom2d!`](@ref) operations on 2D groups, authored
like `postrender_ops` but run before emission. Shared boundaries between groups are then
noded with [`split_t_junctions!`](@ref), self-touching contours are split with
[`split_pinches`](@ref), and the groups are emitted with
[`SolidModels.render_conformal!`](@ref)`(sm, cs)`.

The groups emitted are the target's `retained_physical_groups` of dimension 2, or all groups
if `retained_physical_groups` is empty. Only these groups are emitted, and each group no
operation formed is unioned, so the rendering options `skip_unused_layers` and `auto_union`
have no effect. Mesh-size control points are sampled from all the elements,
as `render!` does without `skip_unused_layers`, and the mesh-size callback is installed.

`context` is the edge cache passed to `render_conformal!(sm, cs)`, and its
`vertex_merge_atol` is also the tolerance for noding and for splitting pinches. Other
keyword arguments, such as `atol`, are rendering options, overridden by the target's
`rendering_options` as in `render!`.
"""
function SolidModels.render_conformal!(
    sm::SolidModel,
    sch::Schematic,
    target::SolidModelTarget;
    strict=:error,
    context::SolidModels.ConformalRenderContext=SolidModels.ConformalRenderContext(),
    kwargs...
)
    sch.checked[] || error(
        "cannot render an unchecked Schematic. Run check!(sch::Schematic), or override by setting sch.checked[] = true (not recommended!)"
    )
    reopen_logfile(sch, :render_solidmodel)
    try
        with_logger(sch.logger) do
            with_geometry_resolution_context() do
                for ly in indexed_layers(target)
                    !haskey(sch.index_dict, ly) && index_layer!(sch::Schematic, ly)
                end
                return _render_conformal!(sm, sch, target; context, kwargs...)
            end
        end
    finally
        close_logfile(sch)
    end
    return check_render_strict(sch, strict, :render_solidmodel)
end

function _render_conformal!(sm, sch, target; context, kwargs...)
    ropts = merge(
        _without_schematic_options(kwargs),
        _without_schematic_options(target.rendering_options)
    )
    if isempty(target.prerenderer) && !isempty(target.postrenderer)
        @warn "render_conformal!: the target has `postrender_ops` but no `prerender_ops`, " *
              "so the groups its `postrender_ops` form (such as the metal) are not rendered."
    end
    component_ops = component_solidmodel_ops(sch, target)
    if !isempty(component_ops.postrender) || !isempty(component_ops.post_fragment)
        @warn "render_conformal!: the schematic has `SolidModelComponent` parts, which the " *
              "2D conformal render doesn't import."
    end
    mapf = _map_meta_fn(target)
    zmap = Base.Fix1(layer_z, target)
    flat = flatten(sch.coordinate_system)
    T = coordinatetype(flat)
    # Elements that render to a group, for sampling mesh sizes as `render!` does
    mapped = CoordinateSystem{T}(uniquename("render_conformal"))
    by_group = Dict{String, Vector{Any}}()
    zs_by_group = Dict{String, Vector{Any}}()
    skipped_1d = Set{String}()
    for (e, m) in zip(elements(flat), element_metadata(flat))
        name = mapf(m)
        isnothing(name) && continue
        name = string(name)
        place!(mapped, e, m)
        _is_1d(e) && (push!(skipped_1d, name); continue)
        # The primitive form `render!` emits, with optional styles resolved, `NoRender` dropped
        # and curves kept
        prims = SolidModels.to_primitives(sm, e; ropts...)
        prims = prims isa AbstractVector ? prims : [prims]
        isempty(prims) && continue
        _push_z!(get!(zs_by_group, name, []), zmap(m))
        append!(get!(by_group, name, Any[]), prims)
    end
    for name in sort!(collect(skipped_1d))
        @info "render_conformal!: skipping the 1D elements of group $name, which only 3D rendering extrudes."
    end

    boolean_out = Set{String}()
    _run_prerender_ops!(by_group, target.prerenderer; zs_by_group, boolean_out)
    emit_all = isempty(target.retained_physical_groups)
    retained =
        Set(string(name) for (name, dim) in target.retained_physical_groups if dim == 2)
    regions = Dict{String, Vector{CurvilinearRegion{T}}}()
    z_of = Dict{String, Any}()
    for (name, geom) in by_group
        emit_all || name in retained || continue
        zs = get(zs_by_group, name, [])
        length(zs) > 1 && throw(
            ArgumentError(
                "render_conformal!: group $name has elements at z = $(join(zs, ", ")), but " *
                "each group is rendered in one plane; make its layer levelwise in the target"
            )
        )
        # A group no op formed is unioned, which merges overlapping elements
        regs = name in boolean_out ? geom : union2d_curved(geom)
        isempty(regs) && continue
        regions[name] = CurvilinearRegion{T}[r for r in regs]
        z_of[name] = isempty(zs) ? zero(T) : only(zs)
    end
    # Node and split at the tolerance the edge cache merges vertices at
    merge_atol = context.vertex_merge_atol * DeviceLayout.onemicron(T)
    split_t_junctions!(regions; atol=merge_atol)
    regions = split_pinches(regions; atol=merge_atol)
    # Emit the groups through the coordinate-system render, one metadata entry per group
    formed = CoordinateSystem{T}(uniquename("render_conformal_formed"))
    for (name, regs) in regions
        meta = SemanticMeta(Symbol(name))
        foreach(r -> place!(formed, r, meta), regs)
    end
    # The groups are already selected and unioned. `skip_unused_layers` would skip them all
    # if the target retains none, since this render runs no operations, and `auto_union`
    # would union them again.
    SolidModels.render_conformal!(
        sm,
        formed;
        ropts...,
        zmap=m -> z_of[string(layer(m))],
        map_meta=m -> string(layer(m)),
        skip_unused_layers=false,
        auto_union=false,
        context
    )
    # That render samples mesh sizes from the formed regions, which carry no `MeshSized`
    # styles, so sample them again from the original elements, as `render!` does
    SolidModels.populate_size_fields!(
        mapped;
        primitives_of=(el; kw...) -> SolidModels.to_primitives(sm, el; kw...),
        zmap,
        ropts...
    )
    SolidModels.set_mesh_size_callback!()
    return nothing
end
