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

The `prerenderer`, given by the `prerender_ops` keyword, is a list of curve-preserving 2D
operations that
[`render_conformal!`](@ref)`(sm, sch, target)` uses instead of the `postrenderer` to form
2D groups, such as the metal, from other groups before they are emitted. It is authored
like the `postrenderer`, with the operations [`union2d_curved!`](@ref) and
[`difference2d_curved!`](@ref), which act on 2D region groups rather than on entities in
the solid model. `render!` doesn't use the `prerenderer`.
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
# Without a `prerenderer`, as before it was added
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

# ─── Conformal schematic render ──────────────────────────────────────────────

# Resolve the `OptionalStyle`s of `e` for the rendering options `kwargs`, the way
# `to_polygons` resolves them when `render!` emits an entity. Returns `nothing` if `e`
# resolves to `NoRender`. The conformal render resolves them before its booleans, which
# don't take rendering options: otherwise a `not_simulated` element would end up in a
# `simulation=true` model.
function _resolve_optional(e; kwargs...)
    e isa DeviceLayout.StyledEntity || return e
    inner = _resolve_optional(e.ent; kwargs...)
    isnothing(inner) && return nothing
    sty = e.sty
    while sty isa OptionalStyle
        sty = get(values(kwargs), sty.flag, sty.default) ? sty.true_style : sty.false_style
    end
    sty isa DeviceLayout.NoRender && return nothing
    return sty isa DeviceLayout.Plain ? inner : DeviceLayout.StyledEntity(inner, sty)
end

# 1D elements (wave ports) are extruded only in 3D, so the 2D conformal render skips them
_is_1d(e) = e isa LineSegment || (e isa DeviceLayout.StyledEntity && _is_1d(e.ent))

# ── Prerender operations ─────────────────────────────────────────────────────
#
# A prerender op is a tuple `(dest, op_fn, args, op_kwargs...)`, as in `postrender_ops`.
# `op_fn(groups, args...; op_kwargs...)` is called with `groups`, a `Dict` from group name
# to geometry, and returns the new `Vector{CurvilinearRegion}` for `dest`. A group holds the
# resolved entities of its layer until an op replaces it with regions. The booleans take
# either, and run on the entities themselves so that their curves are recovered.

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
    union2d_curved!(groups, object, tool=object, d1=2, d2=2;
        remove_object=false, remove_tool=false)
    union2d_curved!(groups, object, d; remove_object=true)

Prerender operation: the curve-preserving union of the groups `object` and `tool`, or of
`object` with itself. Each is a group name or a vector of names. Returns the merged
`Vector{CurvilinearRegion}`. As in `SolidModels.union_geom!`, missing groups are logged and
the others are used, `remove_object` / `remove_tool` remove the inputs, and the form with
a single dimension `d` is a self-union that removes `object`. The dimensions must be 2. See
`prerender_ops` in [`SolidModelTarget`](@ref).
"""
function union2d_curved!(groups::AbstractDict, object, tool=object, d1=2, d2=2; kwargs...)
    _check_2d(:union2d_curved!, d1, d2)
    missing = unique([_missing_groups(groups, object); _missing_groups(groups, tool)])
    if length(missing) == length(unique([_names(object); _names(tool)]))
        @error "union2d_curved!(groups, $object, $tool): $(_not_groups(missing))."
    elseif !isempty(missing)
        @info "union2d_curved!(groups, $object, $tool): $(_not_groups(missing)), using the rest."
    end
    operand = _group_geom(groups, object)
    _names(tool) == _names(object) || append!(operand, _group_geom(groups, tool))
    _consume!(groups, object, tool; kwargs...)
    return isempty(operand) ? CurvilinearRegion[] : union2d_curved(operand)
end
union2d_curved!(groups::AbstractDict, object, d::Integer; remove_object=true, kwargs...) =
    union2d_curved!(groups, object, object, d, d; remove_object, kwargs...)

"""
    difference2d_curved!(groups, object, tool, d1=2, d2=2;
        remove_object=false, remove_tool=false)

Prerender operation: the curve-preserving difference of the groups `object` and `tool`.
Each is a group name or a vector of names. Returns the resulting
`Vector{CurvilinearRegion}`. As in `SolidModels.difference_geom!`, a missing `object` is an
error, other missing groups are logged and the rest are used, and `remove_object` /
`remove_tool` remove the inputs. The dimensions `d1` and `d2` must be 2. See
`prerender_ops` in [`SolidModelTarget`](@ref).
"""
function difference2d_curved!(groups::AbstractDict, object, tool, d1=2, d2=2; kwargs...)
    _check_2d(:difference2d_curved!, d1, d2)
    missing_object = _missing_groups(groups, object)
    missing = unique([missing_object; _missing_groups(groups, tool)])
    if length(missing_object) == length(_names(object))
        @error "difference2d_curved!(groups, $object, $tool): $(_not_groups(missing_object))."
    elseif !isempty(missing)
        @info "difference2d_curved!(groups, $object, $tool): $(_not_groups(missing)), using the rest."
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
        strict=:error, context=SolidModels.ConformalRenderContext(), atol=nothing, kwargs...)

Render `sch` to `sm` using `target`, as [`render!`](@ref)`(sm, sch, target)` does, but through
the conformal render: shared boundaries resolve to a single OpenCASCADE curve through an
edge cache rather than a fragment pass, and curves stay exact arcs.

The target's layers, levels, indices, `rendering_options` and physical-group names are used
as in `render!`. The 2D geometry is formed by the target's `prerender_ops` instead of its
`postrender_ops`: [`union2d_curved!`](@ref) and [`difference2d_curved!`](@ref) operations
on 2D groups, authored like `postrender_ops` but run before emission. Shared boundaries
between groups are then noded with [`split_t_junctions!`](@ref), self-touching contours are
split with [`split_pinches`](@ref), and the groups are emitted with
[`SolidModels.render_conformal_groups!`](@ref).

The groups emitted are the target's `retained_physical_groups` of dimension 2, or all groups
if `retained_physical_groups` is empty; they must not overlap. Optional styles are resolved with the rendering
options, as in `render!`, so with `simulation=true` fabrication-only elements
(`not_simulated`) are dropped. As in `render!`, mesh-size control points are sampled from the
elements and the mesh-size callback is installed.

`context` and `atol` are passed to `render_conformal_groups!`. Other keyword arguments are
rendering options, overridden by the target's `rendering_options` as in `render!`.

!!! note "Scope"

    This renders 2D geometry only, with each group in the plane at its layer's height, so
    an emitted group, or the inputs of a prerender operation, at several heights throw. The
    target's `postrender_ops` and 3D operations (extrusions, `bounding_layers`
    intersections, bridges) are not run, and 1D elements such as wave ports are skipped.
"""
function SolidModels.render_conformal!(
    sm::SolidModel,
    sch::Schematic,
    target::SolidModelTarget;
    strict=:error,
    context::SolidModels.ConformalRenderContext=SolidModels.ConformalRenderContext(),
    atol=nothing,
    kwargs...
)
    sch.checked[] || error(
        "Cannot render an unchecked Schematic. Run check!(sch::Schematic), or override by setting sch.checked[] = true (not recommended!)"
    )
    for ly in indexed_layers(target)
        !haskey(sch.index_dict, ly) && index_layer!(sch::Schematic, ly)
    end
    reopen_logfile(sch, :render_solidmodel)
    with_logger(sch.logger) do
        return _render_conformal!(sm, sch, target; context, atol, kwargs...)
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
        @warn "Keyword `strict` in `render_conformal!` should be `:error`, `:warn`, or `:no` (got `:$strict`). Proceeding as though `strict=:no` were used."
    end
    return sm
end

function _render_conformal!(sm, sch, target; context, atol, kwargs...)
    SolidModels.gmsh.model.set_current(SolidModels.name(sm))
    ropts = merge(NamedTuple(kwargs), NamedTuple(target.rendering_options))
    SolidModels.set_gmsh_option(
        get(ropts, :gmsh_options, Dict{String, Union{String, Int, Float64}}())
    )
    if isempty(target.prerenderer) && !isempty(target.postrenderer)
        @warn "render_conformal!: the target has `postrender_ops` but no `prerender_ops`, " *
              "so the groups its `postrender_ops` form (such as the metal) are not rendered."
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
        re = _resolve_optional(e; ropts...)
        isnothing(re) && continue
        _is_1d(re) && (push!(skipped_1d, name); continue)
        _push_z!(get!(zs_by_group, name, []), zmap(m))
        push!(get!(by_group, name, Any[]), re)
    end
    for name in sort!(collect(skipped_1d))
        @info "render_conformal!: skipping the 1D elements of group $name, which only 3D rendering extrudes."
    end
    SolidModels.populate_size_fields!(
        mapped;
        primitives_of=(el; kw...) -> SolidModels.to_primitives(sm, el; kw...),
        zmap,
        ropts...
    )

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
        # A group no op formed is unioned, which keeps its curves and merges overlaps
        regs = name in boolean_out ? geom : union2d_curved(geom)
        isempty(regs) && continue
        regions[name] = CurvilinearRegion{T}[r for r in regs]
        z_of[name] = isempty(zs) ? zero(T) : only(zs)
    end
    split_t_junctions!(regions)
    regions = split_pinches(regions)
    SolidModels.render_conformal_groups!(
        sm,
        regions;
        zmap=name -> z_of[name],
        map_meta=identity,
        context,
        atol
    )
    SolidModels.set_mesh_size_callback!()
    return nothing
end
