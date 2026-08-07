using DeviceLayout.SchematicDrivenLayout
using Logging: with_logger

import DeviceLayout: element_metadata, elements, map_metadata, refs, render!, structure
import DeviceLayout.SchematicDrivenLayout:
    Schematic, build!, close_logfile, max_level_logged, reopen_logfile

"""
    SolidModelTarget(levels, stack, ops=Tuple[])

Opt-in schematic target for the simulation-agnostic solid-model pipeline. Rendering
behavior is supplied by `render!` keywords; the target stores only assembly levels, the
source stack, and layer-level operations.
"""
struct SolidModelTarget <: SchematicDrivenLayout.Target
    levels::StackLevels
    stack::SourceStack
    ops::Vector{Tuple}
end
SolidModelTarget(levels::StackLevels, stack::SourceStack) =
    SolidModelTarget(levels, stack, Tuple[])
SolidModelTarget(levels::StackLevels, stack::SourceStack, ops::AbstractVector{<:Tuple}) =
    SolidModelTarget(levels, stack, Tuple[ops...])

function _prefixed_meta(meta::EntityMeta, prefix::String)
    isempty(meta.name) && return meta
    return EntityMeta(
        meta.layer;
        name=prefix * "." * meta.name,
        index=meta.index,
        role=meta.role
    )
end
_prefixed_meta(meta::DeviceLayout.Meta, ::String) = meta

"""
Create placement-specific metadata copies under each graph node. A node prefix is applied
recursively to its component geometry, but not to child graph-node coordinate systems;
those receive their own stable node prefix. This deliberately implements the v1 top-level
prefix contract rather than arbitrary-depth composite paths.
"""
function _prefix_placement_names!(schematic::Schematic)
    graph_node_refs = IdDict{Any, String}(
        reference => node.id for (node, reference) in schematic.ref_dict
    )
    for (node, node_reference) in schematic.ref_dict
        node_cs = structure(node_reference)
        metadata = element_metadata(node_cs)
        for index in eachindex(metadata)
            metadata[index] = _prefixed_meta(metadata[index], node.id)
        end
        for (index, reference) in pairs(refs(node_cs))
            haskey(graph_node_refs, reference) && continue
            copied_reference = deepcopy(reference)
            copied_reference.structure =
                map_metadata(structure(reference), meta -> _prefixed_meta(meta, node.id))
            refs(node_cs)[index] = copied_reference
        end
    end
    return schematic
end

function _direction_vector(direction)
    turns = Float64(ustrip(°, direction)) / 180
    return Float64[cospi(turns), sinpi(turns), 0.0]
end

"""
Resolve the final in-plane direction of every placed lumped-port occurrence without
flattening the hierarchy. Keys are source physical-group identities, which remain stable
when compiler operations generate new physical-group names while preserving `entity_meta`.
"""
function _extract_lumped_port_directions(cs)::Dict{String, Vector{Float64}}
    directions = Dict{String, Vector{Float64}}()
    for (structure, transformation) in DeviceLayout.traversal(cs)
        for (entity, meta) in zip(elements(structure), element_metadata(structure))
            meta isa EntityMeta && meta.role isa LumpedPort || continue
            identity = physical_group_name(meta)
            local_direction = DeviceLayout.extract_direction(entity)
            local_direction === nothing && throw(
                ArgumentError(
                    "Placed LumpedPort '$identity' has no WithDirection style; " *
                    "annotate its geometry with `entity |> WithDirection(angle)`"
                )
            )
            direction = _direction_vector(
                DeviceLayout.rotated_direction(local_direction, transformation)
            )
            if haskey(directions, identity) &&
               !isapprox(directions[identity], direction; atol=1e-12, rtol=1e-12)
                throw(
                    ArgumentError(
                        "Placed LumpedPort occurrences for physical-group identity " *
                        "'$identity' have inconsistent final directions; assign distinct " *
                        "EntityMeta `name` or `index` values"
                    )
                )
            end
            directions[identity] = direction
        end
    end
    return directions
end

function _working_schematic(schematic::Schematic{S}) where {S}
    # Copy the geometry tree and node-reference values together so shared-reference identity is
    # preserved. Keep graph-node keys from the caller: identity, rather than coordinate-system
    # names, remains the placement mapping authority.
    node_reference_pairs = collect(schematic.ref_dict)
    copied_root, copied_references =
        deepcopy((schematic.coordinate_system, last.(node_reference_pairs)))

    working = Schematic{S}(schematic.graph; log_dir=nothing)
    working.coordinate_system.name = copied_root.name
    working.coordinate_system.elements = copied_root.elements
    working.coordinate_system.element_metadata = copied_root.element_metadata
    working.coordinate_system.refs = copied_root.refs
    working.coordinate_system.create = copied_root.create
    for ((node, _), reference) in zip(node_reference_pairs, copied_references)
        working.ref_dict[node] = reference
    end
    for (layer_name, nodes) in schematic.index_dict
        working.index_dict[layer_name] = copy(nodes)
    end
    working.checked[] = schematic.checked[]

    # Reuse normal schematic logging without copying streams. reopen_logfile replaces the
    # working logger's file sink for each stage; the caller retains its own logger object.
    working.logger.max_level_logged = schematic.logger.max_level_logged
    working.logger.stage = schematic.logger.stage
    working.logger.logname = schematic.logger.logname
    working.logger.logger = schematic.logger.logger
    return working
end

function _check_render_strict(schematic::Schematic, strict)
    if strict == :error
        max_level_logged(schematic, :render_solidmodel) >= Logging.Error && error(
            "Encountered errors while rendering. See $(schematic.logger.logname) for details."
        )
    elseif strict == :warn
        max_level_logged(schematic, :render_solidmodel) >= Logging.Warn && error(
            "Encountered warnings while rendering. See $(schematic.logger.logname) for details."
        )
    elseif strict != :no
        @warn "Keyword `strict` should be `:error`, `:warn`, or `:no` (got :$strict); proceeding as :no"
    end
    return nothing
end

function _safe_close_logfile(schematic::Schematic)
    try
        close_logfile(schematic)
    catch error
        error isa InvalidStateException || rethrow()
    end
    return nothing
end

function _capture_finalization_inputs(
    solid_model::SolidModel,
    registry::Registry,
    interfaces,
    terminal_result
)
    tag_records = Tuple{String, String, Symbol}[]
    for (layer_name, state) in registry
        state.dim == 2 || continue
        for record in state.pgs
            record.entity_meta === nothing && continue
            record.entity_meta.role isa Tag || continue
            push!(tag_records, (record.name, record.entity_meta.name, layer_name))
        end
    end

    component_names =
        Iterators.flatten((keys(terminal_result.terminals), terminal_result.ground))
    cc_entity_tags = Dict{String, Vector{Int32}}()
    for component_name in component_names
        if SolidModels.hasgroup(solid_model, component_name, 2)
            cc_entity_tags[component_name] =
                collect(SolidModels.entitytags(solid_model[component_name, 2]))
        end
    end

    interface_layer_parents = Dict{Symbol, Vector{String}}()
    for (interface_name, (parent1, parent2)) in interfaces
        interface_layer = _find_pg_layer(interface_name, registry)
        interface_layer === nothing && continue
        parents = get!(Vector{String}, interface_layer_parents, interface_layer)
        for parent_group in (parent1, parent2)
            parent_layer = _find_pg_layer(parent_group, registry)
            parent_layer === nothing && continue
            parent_name = string(parent_layer)
            parent_name in parents || push!(parents, parent_name)
        end
    end
    return tag_records, cc_entity_tags, interface_layer_parents
end

"""
    render!(sm, schematic, target::Experimental.SolidModelTarget; strict=:error, kwargs...)
        -> Dict{String,Any}

Build and render a private working copy, finalize post-fragmentation discovery, and return
schema-v1 metadata. This method performs no metadata or model artifact file IO; call
`Experimental.write_metadata` explicitly when persistence is desired.
"""
function render!(
    solid_model::SolidModel,
    schematic::Schematic,
    target::SolidModelTarget;
    strict=:error,
    kwargs...
)
    schematic.checked[] ||
        error("Cannot render an unchecked Schematic. Run check!(schematic) first.")
    haskey(kwargs, :output_dir) && throw(
        ArgumentError(
            "Experimental.render! has no output_dir keyword; use write_metadata(path, metadata) explicitly"
        )
    )

    working = _working_schematic(schematic)
    try
        build!(working; strict=strict)
        _prefix_placement_names!(working)
        lumped_port_directions = _extract_lumped_port_directions(working.coordinate_system)
        _preflight(working.coordinate_system, target.stack, target.levels, target.ops)

        locators = _extract_locator_positions(
            working.coordinate_system,
            target.stack,
            target.levels
        )
        initial_registry = _build_initial_registry(working.coordinate_system, target.stack)
        layer_operations = vcat(
            _schedule_extrusions(target.stack, initial_registry, target.levels),
            target.ops
        )
        pg_operations, final_registry, interfaces, deferred_interfaces = compile_layer_ops(
            layer_operations,
            target.stack,
            initial_registry;
            levels=target.levels
        )
        retained_groups = _retained_physical_groups(final_registry, deferred_interfaces)

        reopen_logfile(working, :render_solidmodel)
        metadata = try
            with_logger(working.logger) do
                _warn_potential_overlaps(final_registry, target.stack, target.levels)
                try
                    SolidModels.render!(
                        solid_model,
                        working.coordinate_system;
                        map_meta=meta -> _map_meta_for_stack(target.stack, meta),
                        postrender_ops=pg_operations,
                        retained_physical_groups=retained_groups,
                        zmap=meta -> _meta_z(target.stack, target.levels, meta),
                        kwargs...
                    )
                catch error
                    if error isa ErrorException && contains(error.msg, "Could not fix wire")
                        throw(
                            ErrorException(
                                "OCC geometry failure: $(error.msg)\nThis typically indicates overlapping " *
                                "entities. Subtract source layers that extrude into the same region."
                            )
                        )
                    end
                    rethrow()
                end

                # Required post-fragmentation ordering. Keep finalization under the render
                # logger so strict=:warn also observes discovery/finalization warnings.
                _resolve_tag_locators!(
                    solid_model,
                    final_registry,
                    locators,
                    deferred_interfaces,
                    interfaces
                )
                _execute_deferred_interfaces!(solid_model, deferred_interfaces)
                terminal_result =
                    find_terminals(solid_model, final_registry, target.stack, locators)

                cc_records = PGRecord[]
                for component_name in Iterators.flatten((
                    keys(terminal_result.terminals),
                    terminal_result.ground
                ))
                    push!(cc_records, PGRecord(component_name, _METAL_CC_LAYER, nothing))
                end
                isempty(cc_records) ||
                    (final_registry[_METAL_CC_LAYER] = LayerState(cc_records, 2))

                tag_records, cc_entity_tags, interface_layer_parents =
                    _capture_finalization_inputs(
                        solid_model,
                        final_registry,
                        interfaces,
                        terminal_result
                    )
                split_results = _deduplicate_2d_pgs!(solid_model, final_registry)
                _split_shared_cc_pgs!(solid_model, cc_entity_tags)

                return serialize_metadata(
                    final_registry,
                    terminal_result,
                    tag_records,
                    split_results,
                    cc_entity_tags,
                    interface_layer_parents,
                    target.stack,
                    target.levels,
                    solid_model,
                    lumped_port_directions
                )
            end
        finally
            _safe_close_logfile(working)
        end
        _check_render_strict(working, strict)
        return metadata
    finally
        _safe_close_logfile(working)
    end
end

export SolidModelTarget
