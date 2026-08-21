using DeviceLayout.SchematicDrivenLayout
using Logging: with_logger

import DeviceLayout: element_metadata, elements, map_metadata, refs, render!, structure
import DeviceLayout.SchematicDrivenLayout:
    Schematic, build!, close_logfile, max_level_logged, reopen_logfile

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
    graph_refs = IdDict{Any, String}(ref => node.id for (node, ref) in sch.ref_dict)
    for (node, node_ref) in sch.ref_dict
        node_cs = structure(node_ref)
        metadata = element_metadata(node_cs)
        for idx in eachindex(metadata)
            metadata[idx] = _prefixed_meta(metadata[idx], node.id)
        end
        for (idx, ref) in pairs(refs(node_cs))
            haskey(graph_refs, ref) && continue
            ref_copy = deepcopy(ref)
            ref_copy.structure =
                map_metadata(structure(ref), meta -> _prefixed_meta(meta, node.id))
            refs(node_cs)[idx] = ref_copy
        end
    end
    return sch
end

function _direction_vector(direction)
    turns = Float64(ustrip(°, direction)) / 180
    return Float64[cospi(turns), sinpi(turns), 0.0]
end

"""
    _extract_lumped_port_directions(cs) -> Dict{String, Vector{Float64}}

Resolve the final in-plane direction of every placed lumped-port occurrence without
flattening the hierarchy. Keys are source physical-group identities, which remain stable
when compiler operations generate new physical-group names while preserving `entity_meta`.
"""
function _extract_lumped_port_directions(cs)::Dict{String, Vector{Float64}}
    directions = Dict{String, Vector{Float64}}()
    for (subcs, trans) in DeviceLayout.traversal(cs)
        for (ent, meta) in zip(elements(subcs), element_metadata(subcs))
            (meta isa EntityMeta && meta.role isa LumpedPort) || continue
            group_name = physical_group_name(meta)
            local_direction = DeviceLayout.extract_direction(ent)
            isnothing(local_direction) && throw(
                ArgumentError(
                    "Placed LumpedPort '$group_name' has no WithDirection style; " *
                    "annotate its geometry with `entity |> WithDirection(angle)`"
                )
            )
            direction =
                _direction_vector(DeviceLayout.rotated_direction(local_direction, trans))
            if haskey(directions, group_name) &&
               !isapprox(directions[group_name], direction; atol=1e-12, rtol=1e-12)
                throw(
                    ArgumentError(
                        "Placed LumpedPort occurrences for physical-group identity " *
                        "'$group_name' have inconsistent final directions; assign distinct " *
                        "EntityMeta `name` or `index` values"
                    )
                )
            end
            directions[group_name] = direction
        end
    end
    return directions
end

"""
    _working_schematic(sch::Schematic{S}) where {S}

Create a private schematic for rendering. The geometry and node-reference values are copied
together to preserve shared-reference identity, while the graph-node keys retain their
identity from `sch`.
"""
function _working_schematic(sch::Schematic{S}) where {S}
    node_ref_pairs = collect(sch.ref_dict)
    root_copy, ref_copies = deepcopy((sch.coordinate_system, last.(node_ref_pairs)))

    working_sch = Schematic{S}(sch.graph; log_dir=nothing)
    working_sch.coordinate_system.name = root_copy.name
    working_sch.coordinate_system.elements = root_copy.elements
    working_sch.coordinate_system.element_metadata = root_copy.element_metadata
    working_sch.coordinate_system.refs = root_copy.refs
    working_sch.coordinate_system.create = root_copy.create
    for ((node, _), ref) in zip(node_ref_pairs, ref_copies)
        working_sch.ref_dict[node] = ref
    end
    for (layer_name, nodes) in sch.index_dict
        working_sch.index_dict[layer_name] = copy(nodes)
    end
    working_sch.checked[] = sch.checked[]

    # Reuse normal schematic logging without copying streams. reopen_logfile replaces the
    # working logger's file sink for each stage; the caller retains its own logger object.
    working_sch.logger.max_level_logged = sch.logger.max_level_logged
    working_sch.logger.stage = sch.logger.stage
    working_sch.logger.logname = sch.logger.logname
    working_sch.logger.logger = sch.logger.logger
    return working_sch
end

function _check_render_strict(sch::Schematic, strict)
    if strict == :error
        max_level_logged(sch, :render_solidmodel) >= Logging.Error && error(
            "Encountered errors while rendering. See $(sch.logger.logname) for details."
        )
    elseif strict == :warn
        max_level_logged(sch, :render_solidmodel) >= Logging.Warn && error(
            "Encountered warnings while rendering. See $(sch.logger.logname) for details."
        )
    elseif strict != :no
        @warn "Keyword `strict` should be `:error`, `:warn`, or `:no` (got :$strict); proceeding as :no"
    end
    return nothing
end

function _safe_close_logfile(sch::Schematic)
    try
        close_logfile(sch)
    catch e
        e isa InvalidStateException || rethrow()
    end
    return nothing
end

function _capture_finalization_inputs(
    sm::SolidModel,
    registry::Registry,
    interfaces,
    terminal_result
)
    tag_records = Tuple{String, String, Symbol}[]
    for (layer_name, state) in registry
        state.dim == 2 || continue
        for record in state.pgs
            isnothing(record.entity_meta) && continue
            record.entity_meta.role isa Tag || continue
            push!(tag_records, (record.name, record.entity_meta.name, layer_name))
        end
    end

    cc_names = Iterators.flatten((keys(terminal_result.terminals), terminal_result.ground))
    cc_entity_tags = Dict{String, Vector{Int32}}()
    for cc_name in cc_names
        if SolidModels.hasgroup(sm, cc_name, 2)
            cc_entity_tags[cc_name] = collect(SolidModels.entitytags(sm[cc_name, 2]))
        end
    end

    interface_layer_parents = Dict{Symbol, Vector{String}}()
    for (interface_name, (parent1, parent2)) in interfaces
        interface_layer = _find_pg_layer(interface_name, registry)
        isnothing(interface_layer) && continue
        parents = get!(Vector{String}, interface_layer_parents, interface_layer)
        for parent_group in (parent1, parent2)
            parent_layer = _find_pg_layer(parent_group, registry)
            isnothing(parent_layer) && continue
            parent_name = string(parent_layer)
            parent_name in parents || push!(parents, parent_name)
        end
    end
    return tag_records, cc_entity_tags, interface_layer_parents
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
and return schema-v1 metadata. This method performs no metadata or model artifact I/O; call
`write_metadata` explicitly when persistence is desired.
"""
function render!(
    sm::SolidModel,
    sch::Schematic,
    target::SolidModelTarget;
    strict=:error,
    kwargs...
)
    sch.checked[] || error("Cannot render an unchecked Schematic. Run check!(sch) first.")
    haskey(kwargs, :output_dir) && throw(
        ArgumentError(
            "Experimental.render! has no output_dir keyword; use write_metadata(path, metadata) explicitly"
        )
    )

    working_sch = _working_schematic(sch)
    try
        build!(working_sch; strict=strict)
        _prefix_placement_names!(working_sch)
        lumped_port_directions =
            _extract_lumped_port_directions(working_sch.coordinate_system)
        entity_metas = _entity_metas(working_sch.coordinate_system)
        locators = _extract_locator_positions(working_sch.coordinate_system, target.stack)
        initial_registry = _build_initial_registry(entity_metas, target.stack)
        layer_operations =
            vcat(_schedule_extrusions(target.stack, initial_registry), target.ops)
        pg_operations, final_registry, interfaces, deferred_interfaces =
            compile_layer_ops(layer_operations, target.stack, initial_registry)
        retained_groups = _retained_physical_groups(final_registry, deferred_interfaces)

        reopen_logfile(working_sch, :render_solidmodel)
        metadata = with_logger(working_sch.logger) do
            _warn_potential_overlaps(final_registry, target.stack)
            try
                SolidModels.render!(
                    sm,
                    working_sch.coordinate_system;
                    map_meta=meta -> _map_meta_for_stack(target.stack, meta),
                    postrender_ops=pg_operations,
                    retained_physical_groups=retained_groups,
                    zmap=meta -> layer_z(meta.layer, target.stack),
                    kwargs...
                )
            catch e
                if e isa ErrorException && contains(e.msg, "Could not fix wire")
                    error(
                        "OCC geometry failure: $(e.msg)\nThis typically indicates overlapping " *
                        "entities. Subtract source layers that extrude into the same region."
                    )
                end
                rethrow()
            end

            # Required post-fragmentation ordering. Keep finalization under the render
            # logger so strict=:warn also observes discovery/finalization warnings.
            _resolve_tag_locators!(
                sm,
                final_registry,
                locators,
                deferred_interfaces,
                interfaces
            )
            _execute_deferred_interfaces!(sm, deferred_interfaces)
            terminal_result = find_terminals(sm, final_registry, target.stack, locators)

            cc_records = PGRecord[]
            for cc_name in Iterators.flatten((
                keys(terminal_result.terminals),
                terminal_result.ground
            ))
                push!(cc_records, PGRecord(cc_name, :METAL_CC, nothing))
            end
            isempty(cc_records) ||
                (final_registry[:METAL_CC] = LayerState(cc_records, 2))

            tag_records, cc_entity_tags, interface_layer_parents =
                _capture_finalization_inputs(
                    sm,
                    final_registry,
                    interfaces,
                    terminal_result
                )
            split_results = _deduplicate_2d_pgs!(sm, final_registry)
            _split_shared_cc_pgs!(sm, final_registry, split_results, cc_entity_tags)

            return serialize_metadata(
                final_registry,
                terminal_result,
                tag_records,
                split_results,
                cc_entity_tags,
                interface_layer_parents,
                target.stack,
                sm,
                lumped_port_directions
            )
        end
        _check_render_strict(working_sch, strict)
        return metadata
    finally
        _safe_close_logfile(working_sch)
    end
end

export SolidModelTarget
