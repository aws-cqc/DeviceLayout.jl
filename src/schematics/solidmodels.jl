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
        prerenderer
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

The `prerenderer` is a list of curve-preserving 2D operations used by
[`render_conformal!`](@ref)`(sm, sch, target)` to form the 2D metal geometry from
named layer groups *before* they are emitted to the solid model, so native curves
(CPW turns, rounded corners, circles) survive as exact arcs. It is authored exactly
like `postrenderer`, but its operations ([`union2d_curved!`](@ref) /
[`difference2d_curved!`](@ref)) run on region groups rather than through the OCC
kernel. The stock `render!` does not use `prerenderer`; the conformal render does not
run `postrenderer` (see the note in [`render_conformal!`](@ref)).
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
    prerenderer
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
    prerender_ops,
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

# ─── Conformal (curve-preserving) schematic render ───────────────────────────

# Resolve an `OptionalStyle` chain for the given rendering flags, returning
# `nothing` when the element resolves to `NoRender` (e.g. fabrication-only autofill
# wrapped `not_simulated`, which must be excluded from a `simulation` model).
#
# Naming: stock has no single named OptionalStyle resolver — it inlines the same
# `get(kwargs, opt.flag, opt.default) ? opt.true_style : opt.false_style` idiom in
# several places (e.g. `to_polygons(::GeometryEntity, ::OptionalStyle)` in
# styles.jl); the only named helper, `default_style`, ignores flags. This is a
# flag-aware, recursive version of that idiom.
#
# Why it exists here but not in stock `render!`: stock never resolves OptionalStyle
# eagerly. It passes `target.rendering_options...` (which carries `simulation=true`)
# down into `render!(sm, cs; …)`, which threads it as a kwarg into
# `to_polygons(ent; simulation=true)` AT EMIT TIME — so the flag is honored
# implicitly when each entity is discretized. The conformal path can't rely on
# that: its Clipper booleans run BEFORE emit, and `union2d_curved` /
# `difference2d_curved` → `recover_curves` → `to_polygons(ent)` do NOT thread
# rendering keywords. So a `not_simulated` autofill circle would come back as a
# real polygon (`to_polygons()` = 1 poly) and be pulled into the metal boolean,
# instead of being dropped (`to_polygons(; simulation=true)` = 0 polys). We
# therefore resolve the SAME simulation flag stock uses, just eagerly, up front.
# (We can't instead thread `simulation` through an early `to_curvilinear`: that
# would pre-build regions from entities, which collapses recovered arcs — the raw
# entities must reach the boolean untouched.)
function _resolve_optional(e; kwargs...)
    if e isa DeviceLayout.StyledEntity && e.sty isa OptionalStyle
        use_true = get(values(kwargs), e.sty.flag, e.sty.default)
        rs = use_true ? e.sty.true_style : e.sty.false_style
        rs isa DeviceLayout.NoRender && return nothing
        inner = _resolve_optional(e.ent; kwargs...)
        inner === nothing && return nothing
        return rs isa DeviceLayout.Plain ? inner : DeviceLayout.StyledEntity(inner, rs)
    elseif e isa DeviceLayout.StyledEntity
        inner = _resolve_optional(e.ent; kwargs...)
        inner === nothing && return nothing
        return DeviceLayout.StyledEntity(inner, e.sty)
    end
    return e
end

# One `CurvilinearRegion` per (already-resolved) entity, curves preserved. Used
# only for groups emitted WITHOUT a boolean (ports, lumped elements, …). Groups
# formed by a boolean keep the regions the boolean returned — never round-trip a
# post-boolean region back through this, which would discretize recovered arcs.
function _curvilinear_regions(ents)
    regs = CurvilinearRegion[]
    for e in ents
        e isa CurvilinearRegion && (push!(regs, e); continue)
        loops =
            e isa DeviceLayout.StyledEntity ? DeviceLayout.to_curvilinear(e.ent, e.sty) :
            DeviceLayout.to_curvilinear(e, DeviceLayout.Plain())
        for l in (loops isa AbstractVector ? loops : [loops])
            (l isa CurvilinearPolygon && !isempty(DeviceLayout.points(l))) || continue
            push!(regs, CurvilinearRegion(l))
        end
    end
    return regs
end

# ── Curve-preserving prerender operations ────────────────────────────────────
#
# These form the 2D metal geometry from named layer groups BEFORE emission,
# using Clipper's curve-preserving booleans so native arcs survive. They are the
# curve-preserving analogs of the OCC `union_geom!` / `difference_geom!` postrender
# operations, and are referenced in a target's `prerender_ops` the same way:
#
#     prerender_ops = [
#         ("metal_negative", union2d_curved!,      ("metal_negative",)),          # self-union
#         ("metal",          difference2d_curved!, ("writeable_area", "metal_negative")),
#         ("metal",          union2d_curved!,      ("metal", "metal_positive")),
#     ]
#
# A prerender op is a tuple `(dest, op_fn, args, op_kwargs...)`, mirroring
# `postrender_ops`. `op_fn(groups, args...; op_kwargs...)` is called with `groups`
# — a `Dict` from physical-group name to geometry — and returns the destination
# group's new `Vector{CurvilinearRegion}` (the executor stores it at `dest`).
#
# `groups[name]` is either the RAW resolved entities (for a layer not yet touched
# by a boolean) or a `Vector{CurvilinearRegion}` (a previous op's output). BOTH are
# valid boolean inputs, and — crucially — the booleans run on the raw entities, not
# on regions pre-built from them: `recover_curves` tracks each source curve's
# provenance through discretization, and stitching entities into `CurvilinearRegion`
# contours first loses that and collapses recovered arcs.

_group_geom(groups, name) = get(groups, string(name), [])

"""
    union2d_curved!(groups, object, [tool]; remove_object=false, remove_tool=false)

Prerender op: curve-preserving union of physical-group `object` with `tool` (or a
self-union of `object` if `tool` is omitted or equals `object`). Returns the merged
`Vector{CurvilinearRegion}`. See `prerender_ops` in [`SolidModelTarget`](@ref).
"""
function union2d_curved!(groups::AbstractDict, object, tool=object; kwargs...)
    obj = _group_geom(groups, object)
    operand =
        string(object) == string(tool) ? collect(obj) :
        vcat(collect(obj), collect(_group_geom(groups, tool)))
    _consume!(groups, object, tool; kwargs...)
    return isempty(operand) ? CurvilinearRegion[] : union2d_curved(operand)
end

"""
    difference2d_curved!(groups, object, tool; remove_object=false, remove_tool=false)

Prerender op: curve-preserving difference `object − tool` over physical groups.
Returns the resulting `Vector{CurvilinearRegion}`. See `prerender_ops` in
[`SolidModelTarget`](@ref).
"""
function difference2d_curved!(groups::AbstractDict, object, tool; kwargs...)
    obj = _group_geom(groups, object)
    tool_geom = _group_geom(groups, tool)
    result =
        isempty(obj) ? CurvilinearRegion[] :
        isempty(tool_geom) ? _curvilinear_regions(obj) :
        collect(difference2d_curved(obj, tool_geom))
    _consume!(groups, object, tool; kwargs...)
    return result
end

# Honor remove_object / remove_tool (deferred so the op reads inputs first).
function _consume!(groups, object, tool; remove_object=false, remove_tool=false)
    remove_object && delete!(groups, string(object))
    remove_tool && delete!(groups, string(tool))
    return nothing
end

# Run a target's `prerender_ops` over the region-group dict. Each op tuple is
# `(dest, op_fn, args, op_kwargs...)`; the destination group is replaced by the
# op's return value. `boolean_out` records which names were produced by an op (so
# the caller can distinguish derived groups from raw ones), and `z_by_group`
# propagates a planar z from the first positional arg to `dest`.
function _run_prerender_ops!(
    groups::AbstractDict{String},
    ops;
    z_by_group=nothing,
    boolean_out=nothing
)
    for op in ops
        dest = string(op[1])
        op_fn = op[2]
        args = op[3]
        op_kwargs = op[4:end]
        if z_by_group !== nothing && !isempty(args) && haskey(z_by_group, string(args[1]))
            get!(z_by_group, dest, z_by_group[string(args[1])])
        end
        groups[dest] = op_fn(groups, args...; op_kwargs...)
        boolean_out !== nothing && push!(boolean_out, dest)
    end
    return groups
end

# Detect a `MeshSized` style anywhere in an entity's style chain, so the conformal
# path can warn that per-entity mesh-size hints won't survive (curve-preserving
# booleans strip `MeshSized`, and the emit path has no conformal mesh-size support
# yet — see the TODO at the emit site).
_has_meshsized(e) =
    e isa DeviceLayout.StyledEntity &&
    (e.sty isa DeviceLayout.MeshSized || _has_meshsized(e.ent))

"""
    render_conformal!(sm::SolidModel, sch::Schematic, target::SolidModelTarget;
        strict=:error, kwargs...)

Curve-preserving counterpart to [`render!`](@ref)`(sm, sch, target)`: renders `sch`
to `sm` using `target`, but with native curves (CPW turns, rounded corners,
circles) kept as exact OCC arcs instead of discretized to line-segment chords.

This is a drop-in replacement for the schematic-level `render!` — the same
`SolidModelTarget`, layers, ports, lumped elements, `simulation` option, and
physical-group names are used unchanged.

The 2D metal geometry is formed by the target's **`prerender_ops`** — a list of
curve-preserving operations ([`union2d_curved!`](@ref) / [`difference2d_curved!`](@ref))
authored exactly like `postrender_ops`, but run on region groups BEFORE emission so
native arcs survive (rather than through the OCC kernel's `union_geom!` /
`difference_geom!`, which fragment recovered arcs back to chords in a many-way
boolean). Each group's self-touching contours (zero-width necks / figure-8s that
curve-preserving booleans routinely produce, e.g. a multiply-holed ground plane) are
cleaved into simple sub-regions with [`SolidModels.split_pinches`](@ref); shared
boundaries between groups are then made conformal with [`split_t_junctions!`](@ref)
and emitted with [`SolidModels.render_conformal_groups!`](@ref) so each shared
boundary resolves to a single OCC curve. The target's `postrender_ops` (3D extrusions
/ volume booleans) are NOT run here — they apply after emission and are out of this 2D
scope.

The groups emitted are exactly the target's `retained_physical_groups` at dim 2.
Elements are resolved for the simulation model up front (`simulation=true` by
default via the target's `rendering_options`), so fabrication-only fill
(`not_simulated`, e.g. autofill ground-plane holes) is dropped, exactly as the
stock render does.

!!! note "Scope"

    This renders the 2D geometry (metal + device groups such as ports and lumped
    elements). The target's 3D operations (substrate/vacuum extrusion, bridges)
    are not yet applied here; for a 3D simulation domain, extrude and mesh the
    result using the same machinery as the stock flow (see
    `examples/DemoQPU17/solidmodel.jl`).
"""
function SolidModels.render_conformal!(
    sm::SolidModel,
    sch::Schematic,
    target::SolidModelTarget;
    strict=:error,
    kwargs...
)
    sch.checked[] || error(
        "Cannot render an unchecked Schematic. Run check!(sch::Schematic), or override by setting sch.checked[] = true (not recommended!)"
    )
    for ly in indexed_layers(target)
        !haskey(sch.index_dict, ly) && index_layer!(sch::Schematic, ly)
    end

    mapf = _map_meta_fn(target)
    ropts = merge((; simulation=false), NamedTuple(target.rendering_options))

    reopen_logfile(sch, :render_solidmodel)
    with_logger(sch.logger) do
        flat = flatten(sch.coordinate_system)

        # Collect elements by physical-group name, resolving OptionalStyle for the
        # simulation model up front (fab-only `not_simulated` fill → dropped). Also
        # record a representative z per group name (all elements mapped to a group
        # share a layer, hence a `layer_z`). `by_group` values are the RAW resolved
        # entities until a prerender op replaces them with regions.
        by_group = Dict{String, Any}()
        z_by_group = Dict{String, Any}()
        meshsized_seen = false
        for (e, m) in zip(elements(flat), element_metadata(flat))
            nm = mapf(m)
            isnothing(nm) && continue
            meshsized_seen |= _has_meshsized(e)
            re = _resolve_optional(e; ropts...)
            isnothing(re) && continue
            push!(get!(by_group, string(nm), Any[]), re)
            get!(z_by_group, string(nm), layer_z(target, m))
        end
        if meshsized_seen
            @warn "render_conformal!: `MeshSized` mesh-size hints are not applied on the " *
                  "conformal path — curve-preserving booleans strip `MeshSized`, and the " *
                  "conformal emit has no per-entity sizing yet. Size the mesh downstream " *
                  "(e.g. `SolidModels.set_meshsize!` / meshing fields on the rendered model)."
        end

        # Run the target's curve-preserving `prerender_ops` to form the 2D metal
        # geometry, operating on the RAW entities in `by_group` (pre-converting to
        # regions would collapse recovered arcs). Each op replaces its destination
        # group with a `Vector{CurvilinearRegion}`; inputs consumed via
        # `remove_object`/`remove_tool` are deleted. (The target's `postrender_ops`
        # — 3D extrusions/volume booleans — are NOT run here; they apply after
        # emission and are out of the 2D-conformal scope.)
        boolean_out = Set{String}()
        _run_prerender_ops!(by_group, target.prerenderer; z_by_group, boolean_out)

        # Build the region groups to emit: exactly the target's dim-2
        # `retained_physical_groups`. This naturally selects `metal`, ports, lumped
        # elements, … and excludes 3D-only groups (substrate/vacuum/exterior_boundary,
        # which this 2D path never builds) and postrender scratch groups. Boolean
        # outputs emit as-is; remaining raw groups convert to curve-preserving regions.
        T = DeviceLayout.coordinatetype(sch.coordinate_system)
        keep = Set(string(nm) for (nm, d) in target.retained_physical_groups if d == 2)
        regions_by_name = Dict{String, Vector{CurvilinearRegion{T}}}()
        for (nm, geom) in by_group
            nm in keep || continue
            regs = nm in boolean_out ? collect(geom) : _curvilinear_regions(geom)
            # Split self-touching contours (zero-width necks / figure-8s) into simple
            # sub-regions. Curve-preserving booleans routinely produce these — e.g. a
            # ground plane with many holes — and OCC rejects a pinched loop with
            # "Curve loop is not closed". `split_pinches` cleaves them while carrying
            # native arcs through (see `SolidModels.split_pinches`).
            regs = SolidModels.split_pinches(regs)
            isempty(regs) && continue
            regions_by_name[nm] = CurvilinearRegion{T}[r for r in regs]
        end

        # Node shared boundaries so both sides of every shared edge carry the
        # identical ordered vertex sequence — what the emit cache needs to resolve a
        # boundary to one OCC curve.
        split_t_junctions!(regions_by_name)

        # Emit through the conformal edge cache, keyed by group NAME (identity
        # map_meta). Derived groups (e.g. `metal`, produced by a boolean and named for
        # its destination) inherit their object group's z via `z_by_group`; anything
        # missing falls back to the coordinate-type zero.
        # TODO(conformal-meshsize): thread per-group / per-entity mesh sizing through
        #   this emit so `MeshSized` hints survive (see the `MeshSized` @warn above).
        z0 = zero(T)
        zmap = name -> get(z_by_group, string(name), z0)
        return SolidModels.render_conformal_groups!(
            sm,
            regions_by_name;
            zmap,
            map_meta=identity
        )

        # ─── GAP: 3D domain not yet built (see the "Scope" note in the docstring) ───
        # `sm` now holds the curve-preserving 2D geometry (metal + device groups) at
        # z = layer_z. Stock `render!(sm, sch, target)` goes further and produces a
        # completed 3D simulation domain — the equivalent of the geometry handed to
        # the mesher — by then running, in order:
        #   1. `extrusion_ops(target, sch)`   — extrude substrate/bounding/wave-port
        #                                        layers to 3D
        #   2. the 3D half of `target.postrenderer` — substrate/vacuum volume booleans,
        #                                        staple bridges, port cuts
        #   3. `intersection_ops(target, sch)` — restrict_to_volume! + exterior_boundary
        # `render_conformal!` stops before all three: it currently emits 2D only.
        # Closing this gap means fragmenting the 2D conformal metal onto an extruded
        # substrate top and building the vacuum volume while preserving the native arcs
        # through the extrusion/fragment. Until then, assemble a 3D domain downstream
        # with the stock extrusion/mesh machinery as in `examples/DemoQPU17/solidmodel.jl`.
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
