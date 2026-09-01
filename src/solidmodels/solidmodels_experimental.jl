module SolidModelsExperimental

using SHA
import Graphs
using Logging
import MetaGraphs
import SpatialIndexing
using Unitful
using DeviceLayout
using DeviceLayout: Coordinate, GDSMeta, μm, ustrip
using ..SolidModels
using ..SolidModels: SolidModel, _stp_float

import DeviceLayout: datatype, gdslayer, layer, layerindex, name, render!

include("experimental/entitymeta.jl")
include("experimental/stack.jl")
include("experimental/compiler.jl")
include("experimental/locators.jl")
include("experimental/serialization.jl")
using DeviceLayout.SchematicDrivenLayout
using Logging: with_logger

import DeviceLayout: element_metadata, elements
import DeviceLayout.SchematicDrivenLayout:
    Schematic, check_render_strict, close_logfile, reopen_logfile

const _EXTERIOR_BOUNDARY_LAYERS = Dict(
    ("X", "min") => :EXTBND_XMIN,
    ("X", "max") => :EXTBND_XMAX,
    ("Y", "min") => :EXTBND_YMIN,
    ("Y", "max") => :EXTBND_YMAX,
    ("Z", "min") => :EXTBND_ZMIN,
    ("Z", "max") => :EXTBND_ZMAX
)

"""
    exterior_boundaries(bounding_volume_layer::Symbol) -> Vector{Tuple}

Return operations extracting all six axis-aligned exterior faces of
`bounding_volume_layer` into `:EXTBND_XMIN`, `:EXTBND_XMAX`, `:EXTBND_YMIN`,
`:EXTBND_YMAX`, `:EXTBND_ZMIN`, and `:EXTBND_ZMAX`.
"""
function exterior_boundaries(bounding_volume_layer::Symbol)
    operations = Tuple[]
    for direction in ("X", "Y", "Z"), position in ("min", "max")
        destination = _EXTERIOR_BOUNDARY_LAYERS[(direction, position)]
        push!(
            operations,
            (
                destination,
                SolidModels.get_boundary,
                (bounding_volume_layer,),
                :direction => direction,
                :position => position
            )
        )
    end
    return operations
end

function _entity_metas(cs)
    metas = EntityMeta[]
    for (subcs, _) in DeviceLayout.traversal(cs)
        for meta in element_metadata(subcs)
            meta isa EntityMeta && push!(metas, meta)
        end
    end
    return metas
end

function _map_artwork_meta(
    stack::SourceStack,
    level_increment::GDSMeta,
    apply_increment::Bool
)
    return m -> begin
        sl = sourcelayer(m, stack)
        isnothing(sl.gds_meta) && return nothing
        apply_increment || return sl.gds_meta
        delta = first(sl.level) - 1
        return GDSMeta(
            gdslayer(sl.gds_meta) + delta * gdslayer(level_increment),
            datatype(sl.gds_meta) + delta * datatype(level_increment)
        )
    end
end

"""
    render!(
        cell,
        cs,
        stack::SourceStack;
        levels=[1],
        level_increment=GDSMeta(0, 0),
        kwargs...
    )

Render `EntityMeta` artwork using the GDS mapping stored in `stack`. Layers with
`isnothing(gds_meta)` are omitted independently of `solidmodel` visibility. Metadata
indices do not alter datatypes.
"""
function render!(
    cell::DeviceLayout.Cell,
    cs,
    stack::SourceStack;
    levels=[1],
    level_increment=GDSMeta(0, 0),
    kwargs...
)
    selected_levels = collect(levels)
    isempty(selected_levels) &&
        throw(ArgumentError("levels must contain at least one level"))
    for meta in _entity_metas(cs)
        sourcelayer(meta, stack)
    end
    apply_increment = length(levels) > 1
    map_meta = _map_artwork_meta(stack, level_increment, apply_increment)
    return DeviceLayout.render!(cell, cs; map_meta, kwargs...)
end

# ─── 2D PG deduplication ─────────────────────────────────────────────────────

"""
    _deduplicate_2d_pgs!(sm, registry)

Ensure each mesh face belongs to exactly one 2D physical group by splitting PGs that
span multiple layers into layer-homogeneous sub-PGs.

For each 2D entity, computes its "membership signature" (the set of layers whose PGs
contain it). PGs where all entities share a single signature are left unchanged. PGs
with mixed signatures are split into sub-PGs, one per distinct signature. Each sub-PG
is then cross-referenced into all layers of its signature, and duplicate entity
assignments are removed from the original PGs.

After this step, the mesh has non-overlapping 2D elements and each layer's PG list in
the registry can recover its full original surface.
"""
function _deduplicate_2d_pgs!(sm::SolidModel, registry::LayerRegistry)
    # Phase 1: Build entity → layer membership map
    pg_to_layer = Dict{String, Symbol}()
    for (layer_name, state) in registry
        state.dim != 2 && continue
        for record in state.pgs
            pg_to_layer[record.name] = layer_name
        end
    end

    entity_layers = Dict{Int32, Set{Symbol}}()  # entity tag → set of layers
    for (pg_name, pg) in SolidModels.dimgroupdict(sm, 2)
        layer = get(pg_to_layer, pg_name, nothing)
        isnothing(layer) && continue
        for t in SolidModels.entitytags(pg)
            layers_set = get!(Set{Symbol}, entity_layers, t)
            push!(layers_set, layer)
        end
    end

    # Phase 2: For each PG, group entities by membership signature.
    # Identify which PGs need splitting.
    # signature = sorted tuple of layers (frozen for use as dict key)
    Signature = Tuple{Vararg{Symbol}}

    pgs_to_split = Dict{String, Dict{Signature, Vector{Int32}}}()
    for (pg_name, pg) in SolidModels.dimgroupdict(sm, 2)
        haskey(pg_to_layer, pg_name) || continue
        tags = SolidModels.entitytags(pg)
        isempty(tags) && continue

        groups = Dict{Signature, Vector{Int32}}()
        for t in tags
            signature = Tuple(sort!(collect(get(entity_layers, t, Set{Symbol}()))))
            tag_list = get!(Vector{Int32}, groups, signature)
            push!(tag_list, t)
        end

        # If there's only one group and its signature matches the PG's own layer alone,
        # no split needed (homogeneous PG)
        if length(groups) == 1
            only_sig = first(keys(groups))
            pg_layer = pg_to_layer[pg_name]
            if length(only_sig) == 1 && only_sig[1] == pg_layer
                continue
            end
        end

        pgs_to_split[pg_name] = groups
    end

    # Phase 3: Split heterogeneous PGs into sub-PGs
    # Track: original PG name → list of (sub_pg_name, signature) created from it
    split_results = Dict{String, Vector{Tuple{String, Signature}}}()

    for (pg_name, groups) in pgs_to_split
        pg_layer = pg_to_layer[pg_name]
        sub_pgs = Tuple{String, Signature}[]

        for (signature, tags) in groups
            if length(signature) == 1 && signature[1] == pg_layer && length(groups) > 1
                # Residual: entities exclusive to this PG's own layer — keep original name
                sub_name = pg_name
            else
                # Shared or foreign: generate a content-addressed name
                sub_name = "__" * pghash((2, tag) for tag in tags)
            end
            push!(sub_pgs, (sub_name, signature))

            # Create or update the PG in Gmsh
            if sub_name == pg_name
                # Rewrite the original PG to contain only its residual entities
                sm[pg_name] = Tuple{Int32, Int32}[(Int32(2), t) for t in tags]
            else
                # Create new sub-PG
                sm[sub_name] = Tuple{Int32, Int32}[(Int32(2), t) for t in tags]
            end
        end

        # If the original PG name was NOT used as residual, remove it from the model
        if !any(name == pg_name for (name, _) in sub_pgs)
            if SolidModels.hasgroup(sm, pg_name, 2)
                grouptag = sm[pg_name, 2].grouptag
                SolidModels.gmsh.model.removePhysicalGroups([(2, grouptag)])
                delete!(SolidModels.dimgroupdict(sm, 2), pg_name)
            end
        end

        split_results[pg_name] = sub_pgs
    end

    # Phase 4: Remove duplicate entity assignments.
    # After splitting, entities that were in multiple original PGs now have a dedicated
    # sub-PG. Remove them from any other PG that still contains them.
    entity_owner = Dict{Int32, String}()  # entity tag → owning PG name
    # First assign: sub-PGs take priority (they were just created with exact entity sets)
    for (_, sub_pgs) in split_results
        for (sub_name, _) in sub_pgs
            SolidModels.hasgroup(sm, sub_name, 2) || continue
            for t in SolidModels.entitytags(sm[sub_name, 2])
                entity_owner[t] = sub_name
            end
        end
    end
    # Then assign remaining entities from unsplit PGs
    for (pg_name, pg) in SolidModels.dimgroupdict(sm, 2)
        for t in SolidModels.entitytags(pg)
            if !haskey(entity_owner, t)
                entity_owner[t] = pg_name
            end
        end
    end

    # Rewrite any PG that contains entities it doesn't own
    for (pg_name, pg) in collect(SolidModels.dimgroupdict(sm, 2))
        current_tags = SolidModels.entitytags(pg)
        owned_tags = Int32[t for t in current_tags if get(entity_owner, t, "") == pg_name]
        if length(owned_tags) < length(current_tags)
            if isempty(owned_tags)
                SolidModels.gmsh.model.removePhysicalGroups([(2, pg.grouptag)])
                delete!(SolidModels.dimgroupdict(sm, 2), pg_name)
            else
                sm[pg_name] = Tuple{Int32, Int32}[(Int32(2), t) for t in owned_tags]
            end
        end
    end

    # Phase 5: Update registry cross-references.
    # For each sub-PG, add it to all layers in its signature.
    for (original_pg_name, sub_pgs) in split_results
        original_layer = pg_to_layer[original_pg_name]

        for (sub_name, signature) in sub_pgs
            # Create a PGRecord for the sub-PG
            sub_record = PGRecord(sub_name, original_layer, nothing)

            for layer_name in signature
                !haskey(registry, layer_name) && continue
                registry[layer_name].dim != 2 && continue
                # Avoid duplicates
                any(record -> record.name == sub_name, registry[layer_name].pgs) && continue
                push!(registry[layer_name].pgs, sub_record)
            end
        end

        # Remove the original PG from registry if it was fully replaced
        if !any(name == original_pg_name for (name, _) in sub_pgs)
            if haskey(registry, original_layer)
                filter!(
                    record -> record.name != original_pg_name,
                    registry[original_layer].pgs
                )
            end
        end
    end

    return split_results
end

"""
    _split_shared_cc_pgs!(sm, registry, split_results, cc_entity_tags)

Split any 2D PG containing entities from multiple CCs into content-addressed sub-PGs and
update the registry and prior layer-partition results to reference them.
"""
function _split_shared_cc_pgs!(
    sm::SolidModel,
    registry::LayerRegistry,
    split_results::AbstractDict,
    cc_entity_tags::Dict{String, Vector{Int32}}
)
    entity_to_cc = Dict{Int32, String}(
        tag => cc_name for (cc_name, tags) in cc_entity_tags for tag in tags
    )
    Signature = Tuple{Vararg{Symbol}}

    for (pg_name, pg) in collect(SolidModels.dimgroupdict(sm, 2))
        cc_groups = Dict{String, Vector{Int32}}()
        non_cc_tags = Int32[]
        for tag in SolidModels.entitytags(pg)
            cc_name = get(entity_to_cc, tag, nothing)
            if isnothing(cc_name)
                push!(non_cc_tags, tag)
            else
                push!(get!(Vector{Int32}, cc_groups, cc_name), tag)
            end
        end
        length(cc_groups) <= 1 && continue

        cc_names = sort!(collect(keys(cc_groups)))
        tag_groups = [vcat(non_cc_tags, cc_groups[first(cc_names)])]
        append!(tag_groups, [cc_groups[cc_name] for cc_name in cc_names[2:end]])

        sub_names = String[]
        for tags in tag_groups
            sub_name = "__" * pghash((2, tag) for tag in tags)
            sm[sub_name] = Tuple{Int32, Int32}[(Int32(2), tag) for tag in tags]
            push!(sub_names, sub_name)
        end

        registered_layers = Symbol[]
        for (layer_name, state) in registry
            state.dim == 2 || continue
            matching_records = filter(record -> record.name == pg_name, state.pgs)
            isempty(matching_records) && continue
            push!(registered_layers, layer_name)
            filter!(record -> record.name != pg_name, state.pgs)

            meta = first(matching_records).meta
            for sub_name in sub_names
                any(record -> record.name == sub_name, state.pgs) && continue
                push!(state.pgs, PGRecord(sub_name, layer_name, meta))
            end
        end

        replaced_in_split_results = false
        for original_name in collect(keys(split_results))
            sub_pgs = split_results[original_name]
            updated_sub_pgs = similar(sub_pgs, 0)
            for (sub_name, signature) in sub_pgs
                if sub_name == pg_name
                    append!(updated_sub_pgs, [(name, signature) for name in sub_names])
                    replaced_in_split_results = true
                else
                    push!(updated_sub_pgs, (sub_name, signature))
                end
            end
            split_results[original_name] = unique(updated_sub_pgs)
        end
        if !replaced_in_split_results
            signature = Tuple(sort!(unique(registered_layers)))
            split_results[pg_name] =
                Tuple{String, Signature}[(sub_name, signature) for sub_name in sub_names]
        end

        grouptag = sm[pg_name, 2].grouptag
        SolidModels.gmsh.model.removePhysicalGroups([(2, grouptag)])
        delete!(SolidModels.dimgroupdict(sm, 2), pg_name)
    end
    return nothing
end

function _check_pgs_registered(sm::SolidModel, registry::LayerRegistry)
    registered =
        Set((record.name, state.dim) for state in values(registry) for record in state.pgs)
    unregistered = Tuple{String, Int}[]
    for dim = 0:3, name in keys(SolidModels.dimgroupdict(sm, dim))
        (name, dim) in registered || push!(unregistered, (name, dim))
    end
    isempty(unregistered) || error(
        "solid model contains physical groups absent from the layer registry: " *
        join(["'$name' (dimension $dim)" for (name, dim) in unregistered], ", ")
    )
    return nothing
end

"""
    _warn_potential_overlaps(registry::LayerRegistry, stack::SourceStack)

Emit warnings for 3D source layers with non-NULL material that remain in the final
registry and have overlapping z-ranges. This pattern often leads to overlapping volumes
that crash the OCC kernel during fragmentation.
"""
function _warn_potential_overlaps(registry::LayerRegistry, stack::SourceStack)
    # Collect all 3D source layers with material in the final registry
    extruded_source_layers = Set{Symbol}()
    for (layer_name, state) in registry
        state.dim == 3 || continue
        haskey(stack.layers, layer_name) || continue
        stack.layers[layer_name].material == NULL && continue
        push!(extruded_source_layers, layer_name)
    end

    length(extruded_source_layers) < 2 && return nothing

    # Compute actual z-ranges using pair-derived thickness when needed.
    layer_z_ranges = Dict{Symbol, Tuple{Float64, Float64}}()
    for layer_name in extruded_source_layers
        source_layer = stack.layers[layer_name]
        z_base = _stp_float(layer_z(layer_name, stack))
        dz = _stp_float(thickness(source_layer, stack))
        z_min = min(z_base, z_base + dz)
        z_max = max(z_base, z_base + dz)
        layer_z_ranges[layer_name] = (z_min, z_max)
    end

    for layer_a in extruded_source_layers
        za_min, za_max = layer_z_ranges[layer_a]
        for layer_b in extruded_source_layers
            layer_b <= layer_a && continue
            zb_min, zb_max = layer_z_ranges[layer_b]
            if za_min <= zb_max && zb_min <= za_max
                @warn "Layers $layer_a and $layer_b are both 3D volumes with overlapping " *
                      "z-ranges that remain in the final registry. If they occupy the " *
                      "same spatial region, one must be subtracted from the other to " *
                      "avoid OCC geometry failures."
            end
        end
    end

    return nothing
end

"""
    struct SolidModelTarget{L <: SourceLayer, T <: Coordinate} <: SchematicDrivenLayout.Target
        stack::SourceStack{L, T}
        ops::Vector{Tuple}
    end

    SolidModelTarget(stack::SourceStack)
    SolidModelTarget(stack::SourceStack, ops::AbstractVector{<:Tuple})

Opt-in schematic target for the simulation-agnostic solid-model pipeline.

The target stores the source `stack` and layer-level operations `ops`. Rendering behavior
is supplied by `render!` keywords.
"""
struct SolidModelTarget{L <: SourceLayer, T <: Coordinate} <: SchematicDrivenLayout.Target
    stack::SourceStack{L, T}
    ops::Vector{Tuple}
end

SolidModelTarget(stack::SourceStack{L, T}) where {L, T} =
    SolidModelTarget{L, T}(stack, Tuple[])
SolidModelTarget(stack::SourceStack{L, T}, ops::AbstractVector{<:Tuple}) where {L, T} =
    SolidModelTarget{L, T}(stack, Tuple[ops...])

function _map_meta(target::SolidModelTarget)
    return meta -> begin
        meta isa EntityMeta || return nothing
        source_layer = sourcelayer(meta, target.stack)
        (!source_layer.solidmodel || meta.role isa Locator) && return nothing
        return pgname(meta)
    end
end

function _extrusions(stack::SourceStack, reg::LayerRegistry)
    operations = Tuple[]
    for (layer_name, source_layer) in stack.layers
        haskey(reg, layer_name) || continue
        iszero(thickness(source_layer, stack)) && continue
        push!(operations, (layer_name, SolidModels.extrude_z!, ()))
    end
    return operations
end

function _retained_physical_groups(reg::LayerRegistry)
    retained = Set{Tuple{String, Int}}()
    for state in values(reg)
        for record in state.pgs
            !isnothing(record.meta) && record.meta.role isa Locator && continue
            push!(retained, (record.name, state.dim))
        end
    end
    return retained
end

function _prefixed_meta(m::EntityMeta, prefix::String)
    isempty(m.name) && return m
    return EntityMeta(m.layer; name=prefix * "." * m.name, index=m.index, role=m.role)
end
_prefixed_meta(m::DeviceLayout.Meta, ::String) = m

"""
    _prefix_placement_names!(sch::Schematic)

Create placement-specific metadata copies under each graph node. A node prefix is applied
recursively to its component geometry, but not to child graph-node coordinate systems;
those receive their own stable node prefix. This deliberately implements the v1 top-level
prefix contract rather than arbitrary-depth composite paths.
"""
function _prefix_placement_names!(sch::Schematic)
    ref_to_node_id = IdDict{Any, String}(ref => node.id for (node, ref) in sch.ref_dict)
    for (node, node_ref) in sch.ref_dict
        node_cs = structure(node_ref)
        metadata = element_metadata(node_cs)
        for idx in eachindex(metadata)
            metadata[idx] = _prefixed_meta(metadata[idx], node.id)
        end
        for (idx, ref) in pairs(refs(node_cs))
            haskey(ref_to_node_id, ref) && continue
            # Copy only the mutable reference shell. map_metadata independently copies the
            # referenced structure, so recursively copying it here would be redundant.
            ref_copy = copy(ref)
            # map_metadata resolves each placement-specific component copy here. The active
            # recovery context caches that result so flattening does not resolve it again.
            ref_copy.structure =
                map_metadata(structure(ref), meta -> _prefixed_meta(meta, node.id))
            refs(node_cs)[idx] = ref_copy
        end
    end
    return sch
end

"""
    render!(
        sm::SolidModel,
        sch::Schematic,
        target::SolidModelTarget;
        strict=:error,
        kwargs...
    ) -> Dict{String, Any}

Build and render a private working copy of `sch`, finalize post-fragmentation discovery,
and return schema-v1 metadata. This method performs no metadata or model artifact I/O;
write the returned dictionary explicitly when persistence is desired.
"""
function render!(
    sm::SolidModel,
    sch::Schematic,
    target::SolidModelTarget;
    strict=:error,
    kwargs...
)
    sch.checked[] || error("cannot render an unchecked Schematic. Run check!(sch) first.")
    haskey(kwargs, :output_dir) && throw(
        ArgumentError(
            "experimental render! does not accept an output_dir keyword; write the returned metadata explicitly"
        )
    )

    # Prefixing mutates only a disposable schematic copy; the caller's schematic and
    # component geometry caches remain unchanged.
    sch_copy = deepcopy(sch)
    stage = :render_solidmodel
    previous_logger_stage = sch.logger.stage
    # Stage maxima accumulate across invocations. Save the caller's previous value and
    # clear it so check_render_strict considers only warnings and errors from this render.
    had_stage_level = haskey(sch.logger.max_level_logged, stage)
    previous_stage_level = get(sch.logger.max_level_logged, stage, Logging.Debug)
    delete!(sch.logger.max_level_logged, stage)
    try
        # Route geometry preparation, construction, and postprocessing diagnostics through
        # the render stage so the final strictness check sees the complete operation.
        reopen_logfile(sch, stage)
        metadata = with_logger(sch.logger) do
            # Prefix placement names and flatten once under the same recovery scope so
            # geometry failures are logged once and strict=:no can continue.
            flat = DeviceLayout.SchematicDrivenLayout.with_geometry_resolution_context() do
                    _prefix_placement_names!(sch_copy)
                    return DeviceLayout.flatten(sch_copy.coordinate_system)
                end
            # The flat geometry is the canonical stream of placed metadata occurrences.
            # Collect compiler metadata and role-specific geometric info.
            lumped_port_directions = Dict{String, Vector{Float64}}()
            metas = EntityMeta[]
            locator_candidates = Tuple{Any, EntityMeta}[]
            for (entity, meta) in zip(elements(flat), element_metadata(flat))
                meta isa EntityMeta || continue
                push!(metas, meta)
                if meta.role isa LumpedPort
                    pg_name = pgname(meta)
                    local_direction = DeviceLayout.extract_direction(entity)
                    isnothing(local_direction) && throw(
                        ArgumentError(
                            "placed LumpedPort '$pg_name' has no WithDirection style; " *
                            "annotate its geometry with `WithDirection(angle)`"
                        )
                    )
                    haskey(lumped_port_directions, pg_name) && throw(
                        ArgumentError(
                            "multiple placed LumpedPort occurrences in physical group " *
                            "'$pg_name'; assign distinct EntityMeta `name` or " *
                            "`index` values"
                        )
                    )
                    turns = Float64(ustrip(°, local_direction)) / 180
                    direction = Float64[cospi(turns), sinpi(turns), 0.0]
                    lumped_port_directions[pg_name] = direction
                elseif meta.role isa Locator
                    push!(locator_candidates, (entity, meta))
                end
            end

            # Resolve locators only after every port is validated, preserving error priority.
            locators = LocatorRecord[]
            for (entity, meta) in locator_candidates
                meta.role isa Terminal && isempty(meta.name) && continue
                meta.role isa Tag &&
                    isempty(meta.name) &&
                    throw(ArgumentError("tag locators must have a nonempty name"))
                source_layer = sourcelayer(meta, target.stack)
                source_layer.solidmodel || continue
                r = center(bounds(entity))
                position =
                    _stp_float.((getx(r), gety(r), layer_z(meta.layer, target.stack)))
                push!(locators, LocatorRecord(meta, position))
            end

            # Seed compiler state with the physical groups produced directly by artwork.
            registry = initial_registry(metas, target.stack)
            # Prepend required source-layer extrusions to the user-supplied operation schedule.
            layer_ops = vcat(_extrusions(target.stack, registry), target.ops)
            # Compile layer operations and defer interface discovery until after fragmentation.
            pg_operations, registry, deferred_interfaces =
                compile_ops(layer_ops, target.stack, registry)
            # Preserve every compiled physical group needed by later finalization passes.
            retained_groups = _retained_physical_groups(registry)

            # Warn about source-layer volume overlaps before invoking the geometry kernel.
            _warn_potential_overlaps(registry, target.stack)
            # Low-level renderer creates and fragments the geometry, then applies
            # the non-interface physical-group operations produced by the compiler.
            SolidModels.render!(
                sm,
                flat;
                preflattened=true,
                map_meta=_map_meta(target),
                postrender_ops=pg_operations,
                retained_physical_groups=retained_groups,
                zmap=meta -> layer_z(meta.layer, target.stack),
                kwargs...
            )

            # Cache entity bounding boxes across both locator-resolution passes.
            bbox_cache = Dict{Int32, NTuple{6, Float64}}()

            # Create tagged PGs first because this routine removes tagged surfaces from
            # their parent PGs and adds them to the deferred interfaces.
            # Execute all interfaces next, then discover connected metal components.
            tag_records =
                add_tagged_pgs!(sm, registry, locators, deferred_interfaces, bbox_cache)
            execute_deferred_interfaces!(sm, deferred_interfaces)
            # Downstream discovery assumes every realized PG has semantic registry data.
            _check_pgs_registered(sm, registry)
            terminal_result =
                add_terminals!(sm, registry, target.stack, locators, bbox_cache)

            # First partition PGs by identical layer-membership signatures, then split
            # any remaining PG that spans multiple metal connected components. Keeping
            # these passes separate makes each transformation and its bookkeeping clear.
            split_results = _deduplicate_2d_pgs!(sm, registry)
            _split_shared_cc_pgs!(
                sm,
                registry,
                split_results,
                terminal_result.cc_entity_tags
            )

            # All geometry and registry mutation is complete; serialization only reads
            # the finalized model and graph metadata.
            return serialize_metadata(
                registry,
                terminal_result,
                tag_records,
                split_results,
                deferred_interfaces,
                target.stack,
                sm,
                lumped_port_directions
            )
        end
        # Apply strictness only after all render and finalization warnings are logged.
        check_render_strict(sch, strict)
        return metadata
    finally
        close_logfile(sch)
        # Restore the caller's logger bookkeeping after strictness has been evaluated.
        if had_stage_level
            sch.logger.max_level_logged[stage] = previous_stage_level
        else
            delete!(sch.logger.max_level_logged, stage)
        end
        sch.logger.stage = previous_logger_stage
    end
end

"""
    remap_to_visualization_pgs!(sm::SolidModel, metadata::AbstractDict)

Replace the chopped 2D physical groups in `sm` with a smaller set of human-readable PGs
set by the layer assignments in `metadata`.

The resulting model is **not** Palace-compatible (entities will belong to multiple PGs,
producing duplicated element lines).
"""
function remap_to_visualization_pgs!(sm::SolidModel, metadata::AbstractDict)
    layers = get(metadata, "layers", Dict{String, Any}())
    terminals = get(metadata, "terminals", Dict{String, Any}())
    ground = get(metadata, "ground", Dict{String, Any}())
    tagged = get(metadata, "tagged", Dict{String, Any}())
    physical_groups = get(metadata, "physical_groups", Dict{String, Any}())

    # PGs whose entity_meta is non-null already have useful names — keep them
    # in place and never remove them.
    keep_existing = Set{String}()
    for (pg_name, pg_data) in physical_groups
        if !isnothing(get(pg_data, "entity_meta", nothing))
            push!(keep_existing, pg_name)
        end
    end

    # Helper: union of entity tags across a list of chopped 2D PG names.
    function _union_entity_tags(pg_names)
        entity_tags = Set{Int32}()
        for pg_name in pg_names
            SolidModels.hasgroup(sm, pg_name, 2) || continue
            for t in SolidModels.entitytags(sm[pg_name, 2])
                push!(entity_tags, t)
            end
        end
        return entity_tags
    end

    # Track which chopped PGs were absorbed and should be removed at the end.
    absorbed = Set{String}()

    # Pass 1: layers (skip METAL_CC and 3D layers).
    for (layer_name, layer_data) in layers
        layer_name == "METAL_CC" && continue
        get(layer_data, "dim", 2) == 2 || continue
        pg_names = get(layer_data, "pgs", String[])
        entity_tags = _union_entity_tags(pg_names)
        isempty(entity_tags) && continue
        sm[layer_name] = [(Int32(2), t) for t in sort!(collect(entity_tags))]
        for pg_name in pg_names
            pg_name in keep_existing && continue
            push!(absorbed, pg_name)
        end
    end

    # Pass 2: terminals (one PG per CC, named after the locators).
    for (cc_name, cc_data) in terminals
        pg_names = get(cc_data, "pgs", String[])
        locators = get(cc_data, "locators", String[])
        if isempty(locators)
            @warn "Terminal CC '$cc_name' has no locators; skipping in viz remap."
            continue
        end
        if isempty(pg_names)
            @warn "Terminal CC '$cc_name' has no PGs; skipping in viz remap."
            continue
        end
        entity_tags = _union_entity_tags(pg_names)
        isempty(entity_tags) && continue
        new_name = "TERMINAL_" * join(locators, "+")
        sm[new_name] = [(Int32(2), t) for t in sort!(collect(entity_tags))]
        for pg_name in pg_names
            pg_name in keep_existing && continue
            push!(absorbed, pg_name)
        end
    end

    # Pass 3: ground (single GROUND PG covering all ground CCs).
    ground_entity_tags = Set{Int32}()
    for (cc_name, cc_data) in ground
        pg_names = get(cc_data, "pgs", String[])
        if isempty(pg_names)
            @warn "Ground CC '$cc_name' has no PGs; skipping in viz remap."
            continue
        end
        union!(ground_entity_tags, _union_entity_tags(pg_names))
        for pg_name in pg_names
            pg_name in keep_existing && continue
            push!(absorbed, pg_name)
        end
    end
    if !isempty(ground_entity_tags)
        sm["GROUND"] = [(Int32(2), t) for t in sort!(collect(ground_entity_tags))]
    end

    # Pass 4: tagged (one PG per tag, named TAG_<tag_name>).
    for (tag_name, tag_data) in tagged
        pg_names = get(tag_data, "pgs", String[])
        if isempty(pg_names)
            @warn "Tag '$tag_name' has no PGs; skipping in viz remap."
            continue
        end
        entity_tags = _union_entity_tags(pg_names)
        isempty(entity_tags) && continue
        sm["TAG_" * tag_name] = [(Int32(2), t) for t in sort!(collect(entity_tags))]
        for pg_name in pg_names
            pg_name in keep_existing && continue
            push!(absorbed, pg_name)
        end
    end

    # Remove the absorbed chopped PGs (record only, leaving entities alone).
    for pg_name in absorbed
        SolidModels.hasgroup(sm, pg_name, 2) || continue
        SolidModels.remove_group!(sm, pg_name, 2; recursive=false, remove_entities=false)
    end

    return sm
end

export SolidModelTarget

export METAL, DIELECTRIC, NULL
export Generic, Terminal, Ground, Tag, WavePort, LumpedPort
export SourceLayer, SourceStack, EntityMeta
export exterior_boundaries, serialize_metadata
export inspect_registry, inspect_ops

end # module SolidModelsExperimental
