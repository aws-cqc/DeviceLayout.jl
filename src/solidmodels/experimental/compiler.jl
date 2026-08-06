# ═══════════════════════════════════════════════════════════════════════════════════════════
# Layer-level operation compiler
# ═══════════════════════════════════════════════════════════════════════════════════════════

"""
    compile_layer_ops(layer_ops, stack, initial_registry) -> (pg_ops, registry, interfaces, deferred)

Compile layer-level operations into PG-level operations suitable for passing to
DeviceLayout's `_postrender!`.

Returns:

  - `pg_ops::Vector{Tuple}`: PG-level postrender operations
  - `registry::Registry`: final state of the layer registry
  - `interfaces::Dict{String, Tuple{String, String}}`: interface PGs and their parents
  - `deferred::Vector{DeferredInterface}`: mixed-dim intersects computed post-fragmentation
"""
function compile_layer_ops(
    layer_ops::Vector,
    stack::SourceStack,
    initial_registry::Registry;
    levels::Union{StackLevels, Nothing}=nothing
)
    registry = deepcopy(initial_registry)
    pg_ops = Tuple[]
    interfaces = Dict{String, Tuple{String, String}}()
    deferred_interfaces = DeferredInterface[]
    # Interior solids from contour_only + !keep_interior extrusions, keyed by layer name.
    # These are subtracted from all 3D volumes before restrict_to_volume!.
    interior_solids = Dict{Symbol, Vector{String}}()

    for (operation_index, op) in enumerate(layer_ops)
        _validate_layer_operation(op, operation_index)
        # Flush interior solids before restrict_to_volume! (subtraction must precede
        # fragmentation). The BV layer is excluded from subtraction since carving
        # holes in it would clip away the shell surfaces during restrict.
        if op[2] == SolidModels.restrict_to_volume!
            bv_layer = op[3][1]
            _flush_interior_solids!(pg_ops, registry, interior_solids, bv_layer)
        end
        _compile_one_op!(
            pg_ops,
            registry,
            interfaces,
            deferred_interfaces,
            interior_solids,
            stack,
            op;
            levels=levels
        )
    end

    # Flush any remaining interior solids (pipelines without restrict_to_volume!). If
    # restrict_to_volume! was previously compiled, the interior_solids array was already
    # emptied, so this call will do nothing.
    _flush_interior_solids!(pg_ops, registry, interior_solids, nothing)

    return pg_ops, registry, interfaces, deferred_interfaces
end

function _compile_one_op!(
    pg_ops::Vector{Tuple},
    registry::Registry,
    interfaces::Dict{String, Tuple{String, String}},
    deferred_interfaces::Vector{DeferredInterface},
    interior_solids::Dict{Symbol, Vector{String}},
    stack::SourceStack,
    op::Tuple;
    levels::Union{StackLevels, Nothing}=nothing
)
    dest = op[1]
    op_fn = op[2]
    args = op[3]
    kwargs = length(op) > 3 ? op[4:end] : ()

    return if op_fn == SolidModels.extrude_z!
        _compile_extrude!(pg_ops, registry, interior_solids, stack, dest; levels=levels)
    elseif op_fn == SolidModels.difference_geom!
        _compile_difference!(pg_ops, registry, dest, args, kwargs)
    elseif op_fn == SolidModels.union_geom!
        _compile_union!(pg_ops, registry, dest, args, kwargs)
    elseif op_fn == SolidModels.intersect_geom!
        _compile_intersect!(
            pg_ops,
            registry,
            interfaces,
            deferred_interfaces,
            dest,
            args,
            kwargs
        )
    elseif op_fn == SolidModels.restrict_to_volume!
        _compile_restrict!(pg_ops, registry, args)
    elseif op_fn == SolidModels.get_boundary
        _compile_get_boundary!(pg_ops, registry, dest, args, kwargs)
    elseif op_fn == SolidModels.translate!
        _compile_translate!(pg_ops, registry, dest, args, kwargs)
    elseif op_fn == SolidModels.remove_group!
        _compile_remove!(pg_ops, registry, args, kwargs)
    elseif op_fn == SolidModels.revolve!
        _compile_revolve!(pg_ops, registry, dest, args, kwargs)
    elseif op_fn == SolidModels.set_periodic!
        _compile_set_periodic!(pg_ops, registry, args)
    else
        throw(ArgumentError("Unsupported layer operation $op_fn for destination :$dest"))
    end
end

"""
    _flush_interior_solids!(pg_ops, registry, interior_solids, bv_layer)

Subtract pending interior solids from all 3D volumes in the registry (except the
bounding volume if specified), then remove the interior solid PGs (keeping entities
so they serve as fragmentation boundaries during `restrict_to_volume!`).
"""
function _flush_interior_solids!(
    pg_ops::Vector{Tuple},
    registry::Registry,
    interior_solids::Dict{Symbol, Vector{String}},
    bv_layer::Union{Symbol, Nothing}
)
    isempty(interior_solids) && return nothing

    interior_pg_names = String[]
    for (_, pgs) in interior_solids
        append!(interior_pg_names, pgs)
    end

    for (layer_name, state) in registry
        state.dim != 3 && continue
        layer_name == bv_layer && continue
        for pgr in state.pgs
            push!(
                pg_ops,
                (
                    pgr.name,
                    SolidModels.difference_geom!,
                    (pgr.name, interior_pg_names, 3, 3),
                    :remove_object => true,
                    :remove_tool => false
                )
            )
        end
    end

    # Remove interior solid PGs (keep entities so they act as fragmentation boundaries)
    for (_, pgs) in interior_solids
        for pg_name in pgs
            push!(
                pg_ops,
                ("_rm", SolidModels.remove_group!, (pg_name, 3), :remove_entities => false)
            )
        end
    end

    empty!(interior_solids)
    return nothing
end

# ─── extrude_z! ───────────────────────────────────────────────────────────────────────────

function _compile_extrude!(
    pg_ops::Vector{Tuple},
    registry::Registry,
    interior_solids::Dict{Symbol, Vector{String}},
    stack::SourceStack,
    layer_name::Symbol;
    levels::Union{StackLevels, Nothing}=nothing
)
    !haskey(registry, layer_name) && throw(
        ArgumentError(
            "Cannot extrude layer :$layer_name because it is absent from the compiler registry"
        )
    )
    !haskey(stack, layer_name) && throw(
        ArgumentError(
            "Cannot extrude generated layer :$layer_name because extrusion requires a SourceStack entry"
        )
    )
    sl = stack[layer_name]
    thickness = levels !== nothing ? resolve_thickness(sl, levels) : sl.thickness
    iszero(thickness) && return nothing

    state = registry[layer_name]
    new_pgs = PGRecord[]

    # Helper: register `bnd_pg` (the full boundary of an interior solid produced by a
    # `keep_interior=false` extrusion) under the synthetic _EXTBND_MISC_LAYER layer. After the
    # interior solid is subtracted from surrounding volumes by `_flush_interior_solids!`,
    # this boundary becomes an exterior boundary of the final mesh. Tagging it via
    # _EXTBND_MISC_LAYER lets `_deduplicate_2d_pgs!` split off any sub-PG whose faces are
    # exterior-only (or shared with another layer) from sub-PGs whose faces are
    # purely interior interfaces, avoiding the "mixed boundary attribute" warning
    # that Palace emits for PGs containing both kinds of faces.
    function _register_extbnd_misc!(bnd_pg, meta)
        if !haskey(registry, _EXTBND_MISC_LAYER)
            registry[_EXTBND_MISC_LAYER] = LayerState(PGRecord[], 2)
        end
        return push!(
            registry[_EXTBND_MISC_LAYER].pgs,
            PGRecord(bnd_pg, _EXTBND_MISC_LAYER, meta)
        )
    end

    for pgr in state.pgs
        pg = pgr.name
        if sl.contour_only
            # Extrude the contour (1D boundary of 2D surface) into a lateral shell
            ctr_pg = pg * "__CTR"
            ext_pg = pg * "__CTREXT"
            push!(pg_ops, (ctr_pg, SolidModels.get_boundary, (pg, 2), :oriented => false))
            push!(pg_ops, (ext_pg, SolidModels.extrude_z!, (ctr_pg, thickness, 1)))
            push!(pg_ops, ("_rm", SolidModels.remove_group!, (ctr_pg, 1)))
            if !sl.keep_interior
                # Also extrude the 2D surface into a solid for interior subtraction
                int_pg = pg * "__INT"
                intbnd_pg = pg * "__INTBND"
                push!(pg_ops, (int_pg, SolidModels.extrude_z!, (pg, thickness, 2)))
                push!(
                    pg_ops,
                    (intbnd_pg, SolidModels.get_boundary, (int_pg, 3), :oriented => false)
                )
                push!(pg_ops, ("_rm", SolidModels.remove_group!, (pg, 2)))
                if !haskey(interior_solids, layer_name)
                    interior_solids[layer_name] = String[]
                end
                push!(interior_solids[layer_name], int_pg)
                _register_extbnd_misc!(intbnd_pg, pgr.entity_meta)
            else
                push!(pg_ops, ("_rm", SolidModels.remove_group!, (pg, 2)))
            end
            push!(new_pgs, PGRecord(ext_pg, layer_name, pgr.entity_meta))
        elseif !sl.keep_interior
            # Boundary-only extrusion: extrude to solid, extract boundary, discard interior.
            # The solid is registered for auto-subtraction from surrounding volumes.
            ext_pg = pg * "__EXN"
            bnd_pg = pg * "__EXTBND"
            push!(pg_ops, (ext_pg, SolidModels.extrude_z!, (pg, thickness, 2)))
            push!(
                pg_ops,
                (bnd_pg, SolidModels.get_boundary, (ext_pg, 3), :oriented => false)
            )
            push!(pg_ops, ("_rm", SolidModels.remove_group!, (pg, 2)))
            if !haskey(interior_solids, layer_name)
                interior_solids[layer_name] = String[]
            end
            push!(interior_solids[layer_name], ext_pg)
            push!(new_pgs, PGRecord(bnd_pg, layer_name, pgr.entity_meta))
            _register_extbnd_misc!(bnd_pg, pgr.entity_meta)
        else
            # Standard extrusion: 2D surface → 3D volume
            ext_pg = pg * "__EXN"
            push!(pg_ops, (ext_pg, SolidModels.extrude_z!, (pg, thickness, 2)))
            push!(pg_ops, ("_rm", SolidModels.remove_group!, (pg, 2)))
            push!(new_pgs, PGRecord(ext_pg, layer_name, pgr.entity_meta))
        end
    end

    new_dim = sl.contour_only ? 2 : (sl.keep_interior ? 3 : 2)
    registry[layer_name] = LayerState(new_pgs, new_dim)
    return nothing
end

# ─── difference_geom! ─────────────────────────────────────────────────────────────────────

function _compile_difference!(
    pg_ops::Vector{Tuple},
    registry::Registry,
    dest::Symbol,
    args::Tuple,
    kwargs
)
    object_layer = args[1]
    tool_layers_raw = args[2]
    # Support both single tool layer and a vector of tool layers
    tool_layers = tool_layers_raw isa AbstractVector ? tool_layers_raw : [tool_layers_raw]

    !haskey(registry, object_layer) && throw(
        ArgumentError("Object layer :$object_layer is absent from the compiler registry")
    )
    for tl in tool_layers
        !haskey(registry, tl) &&
            throw(ArgumentError("Tool layer :$tl is absent from the compiler registry"))
    end

    obj_state = registry[object_layer]
    dim = obj_state.dim
    tool_pg_names = String[]
    for tl in tool_layers
        for pgr in registry[tl].pgs
            push!(tool_pg_names, pgr.name)
        end
    end

    # Determine mode
    dest_is_tool = dest in tool_layers
    mode = if dest == object_layer
        :replace
    elseif dest_is_tool
        :replace
    elseif haskey(registry, dest)
        :append
    else
        :create
    end

    kw_pairs = _parse_kwargs(kwargs)
    remove_object = get(kw_pairs, :remove_object, false)
    remove_tool = get(kw_pairs, :remove_tool, false)

    if mode == :replace && dest == object_layer
        for pgr in obj_state.pgs
            push!(
                pg_ops,
                (
                    pgr.name,
                    SolidModels.difference_geom!,
                    (pgr.name, tool_pg_names, dim, dim),
                    :remove_object => true,
                    :remove_tool => false
                )
            )
        end
    elseif mode == :replace && dest_is_tool
        dest_tool_state = registry[dest]
        obj_pg_names = [p.name for p in obj_state.pgs]
        for pgr in dest_tool_state.pgs
            push!(
                pg_ops,
                (
                    pgr.name,
                    SolidModels.difference_geom!,
                    (pgr.name, obj_pg_names, dim, dim),
                    :remove_object => true,
                    :remove_tool => false
                )
            )
        end
    else
        # create or append mode
        new_records = PGRecord[]
        for pgr in obj_state.pgs
            dest_name = generated_pg_name(
                dest,
                pgr.name,
                tool_pg_names;
                operation=:difference,
                parameters=(dim, remove_object)
            )
            _generated_record_exists(registry, dest, dest_name, new_records) && continue
            push!(
                pg_ops,
                (
                    dest_name,
                    SolidModels.difference_geom!,
                    (pgr.name, tool_pg_names, dim, dim),
                    :remove_object => remove_object,
                    :remove_tool => false
                )
            )
            push!(new_records, PGRecord(dest_name, dest, nothing))
        end

        # Dedup if appending
        if mode == :append
            _require_destination_dimension(registry, dest, dim)
            existing_pgs = [
                pgr.name for pgr in registry[dest].pgs if
                !(pgr.entity_meta !== nothing && pgr.entity_meta.role isa Locator)
            ]
            if !isempty(existing_pgs)
                for rec in new_records
                    push!(
                        pg_ops,
                        (
                            rec.name,
                            SolidModels.difference_geom!,
                            (rec.name, existing_pgs, dim, dim),
                            :remove_object => true,
                            :remove_tool => false
                        )
                    )
                end
            end
            append!(registry[dest].pgs, new_records)
        else
            registry[dest] = LayerState(new_records, dim)
        end
    end

    if remove_tool
        for tl in tool_layers
            tl != dest && delete!(registry, tl)
        end
    end
    if remove_object && dest != object_layer
        delete!(registry, object_layer)
    end

    return nothing
end

# ─── union_geom! ──────────────────────────────────────────────────────────────────────────

function _compile_union!(
    pg_ops::Vector{Tuple},
    registry::Registry,
    dest::Symbol,
    args::Tuple,
    kwargs
)
    source_layers =
        args isa Tuple{Symbol} ? [args[1]] :
        args isa Tuple{Symbol, Symbol} ? [args[1], args[2]] : collect(args)

    if length(source_layers) == 1
        source = source_layers[1]
        !haskey(registry, source) && throw(
            ArgumentError("Source layer :$source is absent from the compiler registry")
        )
        state = registry[source]

        if dest == source
            # Self-heal mode
            for pgr in state.pgs
                push!(pg_ops, (pgr.name, SolidModels.union_geom!, (pgr.name, state.dim)))
            end
        else
            # Self-heal and move into a generated destination. If that destination already
            # exists independently, append distinct records without discarding its state.
            new_records = PGRecord[]
            for pgr in state.pgs
                dest_name = generated_pg_name(
                    dest,
                    pgr.name,
                    String[];
                    operation=:union,
                    parameters=(state.dim,)
                )
                _generated_record_exists(registry, dest, dest_name, new_records) && continue
                push!(pg_ops, (dest_name, SolidModels.union_geom!, (pgr.name, state.dim)))
                push!(new_records, PGRecord(dest_name, dest, pgr.entity_meta))
            end
            if haskey(registry, dest)
                _require_destination_dimension(registry, dest, state.dim)
                existing_pgs = [
                    record.name for record in registry[dest].pgs if !(
                        record.entity_meta !== nothing &&
                        record.entity_meta.role isa Locator
                    )
                ]
                if !isempty(existing_pgs)
                    for record in new_records
                        push!(
                            pg_ops,
                            (
                                record.name,
                                SolidModels.difference_geom!,
                                (record.name, existing_pgs, state.dim, state.dim),
                                :remove_object => true,
                                :remove_tool => false
                            )
                        )
                    end
                end
                append!(registry[dest].pgs, new_records)
            else
                registry[dest] = LayerState(new_records, state.dim)
            end
            delete!(registry, source)
        end
    else
        # Collapse mode: fuse all source PGs into one
        all_pg_names = String[]
        dim = 0
        for src in source_layers
            !haskey(registry, src) && throw(
                ArgumentError("Source layer :$src is absent from the compiler registry")
            )
            append!(all_pg_names, [pgr.name for pgr in registry[src].pgs])
            dim = registry[src].dim
        end

        sorted_pg_names = sort(all_pg_names)
        dest_name = generated_pg_name(
            dest,
            first(sorted_pg_names),
            sorted_pg_names[2:end];
            operation=:union,
            parameters=(dim,)
        )
        new_record = PGRecord(dest_name, dest, nothing)
        duplicate = _generated_record_exists(registry, dest, dest_name)
        duplicate ||
            push!(pg_ops, (dest_name, SolidModels.union_geom!, (all_pg_names, dim)))

        if haskey(registry, dest) && dest ∉ source_layers
            _require_destination_dimension(registry, dest, dim)
            # Append. An exact duplicate operation is a no-op: recompiling it must not copy
            # geometry again or duplicate the layer's physical-group list.
            existing_pgs = [
                pgr.name for pgr in registry[dest].pgs if
                !(pgr.entity_meta !== nothing && pgr.entity_meta.role isa Locator)
            ]
            if !duplicate && !isempty(existing_pgs)
                push!(
                    pg_ops,
                    (
                        dest_name,
                        SolidModels.difference_geom!,
                        (dest_name, existing_pgs, dim, dim),
                        :remove_object => true,
                        :remove_tool => false
                    )
                )
            end
            duplicate || push!(registry[dest].pgs, new_record)
        else
            registry[dest] = LayerState([new_record], dim)
        end

        # Remove source layers from registry if they differ from dest
        for src in source_layers
            src != dest && delete!(registry, src)
        end
    end

    return nothing
end

# ─── intersect_geom! ──────────────────────────────────────────────────────────────────────

function _compile_intersect!(
    pg_ops::Vector{Tuple},
    registry::Registry,
    interfaces::Dict{String, Tuple{String, String}},
    deferred_interfaces::Vector{DeferredInterface},
    dest::Symbol,
    args::Tuple,
    kwargs
)
    object_layer, tool_layer = args[1], args[2]
    !haskey(registry, object_layer) && throw(
        ArgumentError("Object layer :$object_layer is absent from the compiler registry")
    )
    !haskey(registry, tool_layer) &&
        throw(ArgumentError("Tool layer :$tool_layer is absent from the compiler registry"))

    obj_state = registry[object_layer]
    tool_state = registry[tool_layer]
    obj_dim = obj_state.dim
    tool_dim = tool_state.dim

    new_records = PGRecord[]
    for obj_pgr in obj_state.pgs
        for tool_pgr in tool_state.pgs
            dest_name = generated_pg_name(
                dest,
                obj_pgr.name,
                [tool_pgr.name];
                operation=:intersect,
                parameters=(obj_dim, tool_dim)
            )
            _generated_record_exists(registry, dest, dest_name, new_records) && continue
            # All intersections are deferred to post-fragmentation. Same-dim
            # intersections find shared boundary entities (dim-1); mixed-dim
            # intersections find lo-dim entities on the hi-dim boundary.
            push!(
                deferred_interfaces,
                DeferredInterface(
                    dest_name,
                    obj_pgr.name,
                    tool_pgr.name,
                    obj_dim,
                    tool_dim
                )
            )
            push!(new_records, PGRecord(dest_name, dest, nothing))
            interfaces[dest_name] = (obj_pgr.name, tool_pgr.name)
        end
    end

    # Result dimension: mixed-dim intersections produce entities at min(d1, d2).
    # Same-dim intersections (e.g. 3D∩3D) produce shared boundaries at dim-1.
    new_dim = obj_dim == tool_dim ? obj_dim - 1 : min(obj_dim, tool_dim)

    if haskey(registry, dest) && dest != object_layer && dest != tool_layer
        _require_destination_dimension(registry, dest, new_dim)
        append!(registry[dest].pgs, new_records)
    else
        registry[dest] = LayerState(new_records, new_dim)
    end

    return nothing
end

"""
    _execute_deferred_interfaces!(sm, deferred_interfaces)

After fragmentation, compute interface PGs as set intersections of entity memberships.

Handles two cases:

  - Same-dim (e.g. 3D∩3D, 2D∩2D): the interface is the set of shared boundary entities at
    dim-1 (faces for volumes, curves for surfaces).
  - Mixed-dim (e.g. 2D∩3D): the interface is the set of lo-dim entities in the object PG
    that are also boundary faces of entities in the tool PG.
"""
function _compile_restrict!(pg_ops::Vector{Tuple}, registry::Registry, args::Tuple)
    bv_layer = args[1]
    !haskey(registry, bv_layer) && throw(
        ArgumentError(
            "Bounding volume layer :$bv_layer is absent from the compiler registry"
        )
    )
    bv_pgs = registry[bv_layer].pgs
    length(bv_pgs) == 1 || throw(
        ArgumentError(
            "Bounding volume layer :$bv_layer must contain exactly one physical group"
        )
    )
    bv_pg = bv_pgs[1].name
    push!(pg_ops, ("restrict", SolidModels.restrict_to_volume!, (bv_pg,)))
    return nothing
end

# ─── get_boundary ─────────────────────────────────────────────────────────────────────────

function _compile_get_boundary!(
    pg_ops::Vector{Tuple},
    registry::Registry,
    dest::Symbol,
    args::Tuple,
    kwargs
)
    source_layer = args[1]
    !haskey(registry, source_layer) && throw(
        ArgumentError("Source layer :$source_layer is absent from the compiler registry")
    )
    state = registry[source_layer]
    dim = state.dim

    kw_pairs = _parse_kwargs(kwargs)

    if dest == source_layer
        # Replace mode
        for pgr in state.pgs
            push!(pg_ops, (pgr.name, SolidModels.get_boundary, (pgr.name, dim), kwargs...))
        end
        state.dim = dim - 1
    else
        # Create/append mode
        new_records = PGRecord[]
        for pgr in state.pgs
            dest_name = generated_pg_name(
                dest,
                pgr.name,
                String[];
                operation=:boundary,
                parameters=(dim, _content_kwargs(kwargs))
            )
            _generated_record_exists(registry, dest, dest_name, new_records) && continue
            push!(pg_ops, (dest_name, SolidModels.get_boundary, (pgr.name, dim), kwargs...))
            push!(new_records, PGRecord(dest_name, dest, nothing))
        end
        new_dim = dim - 1
        if haskey(registry, dest)
            _require_destination_dimension(registry, dest, new_dim)
            append!(registry[dest].pgs, new_records)
        else
            registry[dest] = LayerState(new_records, new_dim)
        end
    end

    return nothing
end

# ─── translate! ───────────────────────────────────────────────────────────────────────────

function _compile_translate!(
    pg_ops::Vector{Tuple},
    registry::Registry,
    dest::Symbol,
    args::Tuple,
    kwargs
)
    source_layer = args[1]
    dx, dy, dz = args[2], args[3], args[4]
    !haskey(registry, source_layer) && throw(
        ArgumentError("Source layer :$source_layer is absent from the compiler registry")
    )

    kw_pairs = _parse_kwargs(kwargs)
    copy = get(kw_pairs, :copy, false)

    state = registry[source_layer]

    if dest == source_layer && !copy
        # Replace mode (in-place translate)
        for pgr in state.pgs
            push!(
                pg_ops,
                (pgr.name, SolidModels.translate!, (pgr.name, dx, dy, dz), :copy => false)
            )
        end
    else
        # Create/append mode (copy-translate)
        new_records = PGRecord[]
        for pgr in state.pgs
            dest_name = generated_pg_name(
                dest,
                pgr.name,
                String[];
                operation=:translate,
                parameters=(dx, dy, dz)
            )
            _generated_record_exists(registry, dest, dest_name, new_records) && continue
            push!(
                pg_ops,
                (dest_name, SolidModels.translate!, (pgr.name, dx, dy, dz), :copy => true)
            )
            push!(new_records, PGRecord(dest_name, dest, nothing))
        end
        if haskey(registry, dest)
            _require_destination_dimension(registry, dest, state.dim)
            append!(registry[dest].pgs, new_records)
        else
            registry[dest] = LayerState(new_records, state.dim)
        end
    end

    return nothing
end

# ─── remove_group! ────────────────────────────────────────────────────────────────────────

function _compile_remove!(pg_ops::Vector{Tuple}, registry::Registry, args::Tuple, kwargs)
    layer_name = args[1]
    !haskey(registry, layer_name) &&
        throw(ArgumentError("Layer :$layer_name is absent from the compiler registry"))

    kw_pairs = _parse_kwargs(kwargs)
    remove_entities = get(kw_pairs, :remove_entities, true)

    state = registry[layer_name]
    for pgr in state.pgs
        push!(
            pg_ops,
            (
                "_rm",
                SolidModels.remove_group!,
                (pgr.name, state.dim),
                :remove_entities => remove_entities
            )
        )
    end
    delete!(registry, layer_name)
    return nothing
end

# ─── revolve! ─────────────────────────────────────────────────────────────────────────────

function _compile_revolve!(
    pg_ops::Vector{Tuple},
    registry::Registry,
    dest::Symbol,
    args::Tuple,
    kwargs
)
    source_layer = args[1]
    x, y, z, ax, ay, az, theta =
        args[2], args[3], args[4], args[5], args[6], args[7], args[8]
    !haskey(registry, source_layer) && throw(
        ArgumentError("Source layer :$source_layer is absent from the compiler registry")
    )

    state = registry[source_layer]
    dim = state.dim

    if dest == source_layer
        for pgr in state.pgs
            push!(
                pg_ops,
                (
                    pgr.name,
                    SolidModels.revolve!,
                    (pgr.name, dim, x, y, z, ax, ay, az, theta)
                )
            )
        end
        state.dim = dim + 1
    else
        new_records = PGRecord[]
        for pgr in state.pgs
            dest_name = generated_pg_name(
                dest,
                pgr.name,
                String[];
                operation=:revolve,
                parameters=(dim, x, y, z, ax, ay, az, theta)
            )
            _generated_record_exists(registry, dest, dest_name, new_records) && continue
            push!(
                pg_ops,
                (
                    dest_name,
                    SolidModels.revolve!,
                    (pgr.name, dim, x, y, z, ax, ay, az, theta)
                )
            )
            push!(new_records, PGRecord(dest_name, dest, nothing))
        end
        new_dim = dim + 1
        if haskey(registry, dest)
            _require_destination_dimension(registry, dest, new_dim)
            append!(registry[dest].pgs, new_records)
        else
            registry[dest] = LayerState(new_records, new_dim)
        end
    end

    return nothing
end

# ─── set_periodic! ────────────────────────────────────────────────────────────────────────

function _compile_set_periodic!(pg_ops::Vector{Tuple}, registry::Registry, args::Tuple)
    layer_a, layer_b = args[1], args[2]
    !haskey(registry, layer_a) && throw(
        ArgumentError("Periodic layer :$layer_a is absent from the compiler registry")
    )
    !haskey(registry, layer_b) && throw(
        ArgumentError("Periodic layer :$layer_b is absent from the compiler registry")
    )

    pgs_a = registry[layer_a].pgs
    pgs_b = registry[layer_b].pgs
    length(pgs_a) == length(pgs_b) || throw(
        ArgumentError(
            "set_periodic! requires equal physical-group counts in layers :$layer_a and :$layer_b"
        )
    )

    for (pa, pb) in zip(pgs_a, pgs_b)
        push!(
            pg_ops,
            ("Periodic_$(pa.name)", SolidModels.set_periodic!, (pa.name, pb.name, 2, 2))
        )
    end

    return nothing
end

# ─── kwargs helper ────────────────────────────────────────────────────────────────────────

function _parse_kwargs(kwargs)
    d = Dict{Symbol, Any}()
    for kv in kwargs
        if kv isa Pair
            d[kv.first] = kv.second
        end
    end
    return d
end
