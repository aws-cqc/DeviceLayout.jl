struct PGRecord
    name::String
    layer::Symbol
    meta::Union{EntityMeta, Nothing}
end

mutable struct LayerState
    pgs::Vector{PGRecord}
    dim::Int
end

const LayerRegistry = Dict{Symbol, LayerState}

function initial_registry(metas::AbstractVector{<:EntityMeta}, stack::SourceStack)
    registry = LayerRegistry()
    for meta in unique(metas)
        source_layer = sourcelayer(meta, stack)
        (!source_layer.solidmodel || meta.role isa Locator) && continue
        record = PGRecord(physical_group_name(meta), meta.layer, meta)
        state = get!(registry, meta.layer) do
            return LayerState(PGRecord[], 2)
        end
        any(existing -> existing.name == record.name, state.pgs) || push!(state.pgs, record)
    end
    return registry
end

# Directed bipartite graph of unique PG vertices and deferred-interface vertices. Edges
# `PG → interface → PG` identify object and tool roles; execution caches Gmsh data once per
# PG vertex, then evaluates each interface vertex using in-memory set intersections.
# Interface vertices also retain destination and parent layers for metadata serialization.
function _deferred_interface_graph()
    graph = MetaGraphs.MetaDiGraph()
    MetaGraphs.set_indexing_prop!(graph, :key)
    return graph
end

function _pg_vertex!(graph::MetaGraphs.MetaDiGraph, name::String, dim::Int)
    key = (:pg, name, dim)
    haskey(graph, key, :key) && return graph[key, :key]
    Graphs.add_vertex!(
        graph,
        Dict{Symbol, Any}(:kind => :pg, :key => key, :name => name, :dim => dim)
    )
    return Graphs.nv(graph)
end

function defer_interface!(
    graph::MetaGraphs.MetaDiGraph,
    dest_pg::String,
    obj_pg::String,
    tool_pg::String,
    obj_dim::Int,
    tool_dim::Int,
    dest_layer::Symbol,
    obj_layer::Symbol,
    tool_layer::Symbol
)
    key = (:interface, dest_pg)
    haskey(graph, key, :key) &&
        throw(ArgumentError("Deferred interface '$dest_pg' is already defined"))
    obj = _pg_vertex!(graph, obj_pg, obj_dim)
    tool = _pg_vertex!(graph, tool_pg, tool_dim)
    Graphs.add_vertex!(
        graph,
        Dict{Symbol, Any}(
            :kind => :interface,
            :key => key,
            :dest_pg => dest_pg,
            :dest_layer => dest_layer,
            :parent_layers => (obj_layer, tool_layer)
        )
    )
    operation = Graphs.nv(graph)
    Graphs.add_edge!(graph, obj, operation)
    Graphs.add_edge!(graph, operation, tool)
    return operation
end

interface_vertices(graph::MetaGraphs.MetaDiGraph) = filter(
    vertex -> MetaGraphs.get_prop(graph, vertex, :kind) == :interface,
    Graphs.vertices(graph)
)

function operation_pgs(graph::MetaGraphs.MetaDiGraph, operation::Integer)
    return only(Graphs.inneighbors(graph, operation)),
    only(Graphs.outneighbors(graph, operation))
end

"""
    execute_deferred_interfaces!(sm, deferred_interfaces)

After fragmentation, compute interface PGs as set intersections of entity memberships.

Handles two cases:

  - Same-dimension (for example, 3D∩3D or 2D∩2D): the interface is the set of shared
    boundary entities at dimension `dim - 1` (faces for volumes, curves for surfaces).
  - Mixed-dimension (for example, 2D∩3D): the interface is the set of lower-dimensional
    entities in one PG that are also boundary faces of entities in the other PG.
"""
function execute_deferred_interfaces!(sm::SolidModel, interfs::MetaGraphs.MetaDiGraph)
    Graphs.nv(interfs) == 0 && return nothing

    dimtag_cache = Dict{Int, Any}()
    boundary_cache = Dict{Int, Any}()

    function _pg_dimtags(vertex)
        return get!(dimtag_cache, vertex) do
            name = MetaGraphs.get_prop(interfs, vertex, :name)
            dim = MetaGraphs.get_prop(interfs, vertex, :dim)
            SolidModels.hasgroup(sm, name, dim) || return nothing
            return SolidModels.dimtags(sm[name, dim])
        end
    end

    function _pg_boundary_tags(vertex, boundary_dim)
        boundaries = get!(boundary_cache, vertex) do
            dimtags = _pg_dimtags(vertex)
            isnothing(dimtags) && return nothing
            boundary_dimtags =
                SolidModels.gmsh.model.getBoundary(dimtags, false, false, false)
            result = Dict{Int, Set{Int32}}()
            for (dim, tag) in boundary_dimtags
                push!(get!(Set{Int32}, result, Int(dim)), Int32(abs(tag)))
            end
            return result
        end
        isnothing(boundaries) && return nothing
        return get(boundaries, boundary_dim, Set{Int32}())
    end

    for operation in interface_vertices(interfs)
        object, tool = operation_pgs(interfs, operation)
        obj_dim = MetaGraphs.get_prop(interfs, object, :dim)
        tool_dim = MetaGraphs.get_prop(interfs, tool, :dim)
        dest_pg = MetaGraphs.get_prop(interfs, operation, :dest_pg)

        if obj_dim == tool_dim
            boundary_dim = obj_dim - 1
            obj_tags = _pg_boundary_tags(object, boundary_dim)
            tool_tags = _pg_boundary_tags(tool, boundary_dim)
            (isnothing(obj_tags) || isnothing(tool_tags)) && continue
            interface_tags = intersect(obj_tags, tool_tags)
            isempty(interface_tags) && continue
            sm[dest_pg] =
                Tuple{Int32, Int32}[(Int32(boundary_dim), tag) for tag in interface_tags]
        else
            lo_dim = min(obj_dim, tool_dim)
            lo = obj_dim <= tool_dim ? object : tool
            hi = obj_dim <= tool_dim ? tool : object
            lo_dimtags = _pg_dimtags(lo)
            hi_tags = _pg_boundary_tags(hi, lo_dim)
            (isnothing(lo_dimtags) || isnothing(hi_tags)) && continue
            lo_tags = Set(Int32(tag) for (_, tag) in lo_dimtags)
            interface_tags = intersect(lo_tags, hi_tags)
            isempty(interface_tags) && continue
            sm[dest_pg] =
                Tuple{Int32, Int32}[(Int32(lo_dim), tag) for tag in interface_tags]
        end
    end

    return nothing
end

function pghash(dimtags)
    content = join(sort(["$dim,$tag" for (dim, tag) in dimtags]), "&")
    return bytes2hex(sha1(content))[1:16]
end

"""
    operation_hash(obj_pg, tool_pgs; operation, parameters=()) -> String

Return the content hash for a generated layer operation.
"""
function operation_hash(
    obj_pg::String,
    tool_pgs::Vector{String};
    operation::Symbol,
    parameters=()
)
    content =
        join((string(operation), obj_pg, join(sort(tool_pgs), "&"), repr(parameters)), "\0")
    return bytes2hex(sha1(content))[1:16]
end

_content_kwargs(kwargs) = Tuple(sort(collect(kwargs); by=keyword -> string(first(keyword))))

function generated_record_exists(
    reg::LayerRegistry,
    dest::Symbol,
    name::String,
    pending::Vector{PGRecord}=PGRecord[]
)
    any(record -> record.name == name, pending) && return true
    return haskey(reg, dest) && any(record -> record.name == name, reg[dest].pgs)
end

function _operation_argument_error(idx::Integer, dest, msg::AbstractString)
    dest_repr = dest isa Symbol ? ":$dest" : repr(dest)
    return ArgumentError("Layer operation $idx for destination $dest_repr $msg")
end

function _require_destination_dimension(reg::LayerRegistry, dest::Symbol, dim::Int)
    if haskey(reg, dest) && reg[dest].dim != dim
        throw(
            ArgumentError(
                "Destination layer :$dest has dimension $(reg[dest].dim), " *
                "so dimension $dim physical groups cannot be appended"
            )
        )
    end
    return nothing
end

function _validate_layer_operation(operation, operation_idx::Integer)
    operation isa Tuple || throw(
        ArgumentError(
            "Layer operation $operation_idx must be a Tuple, got $(typeof(operation))"
        )
    )
    length(operation) >= 3 || throw(
        ArgumentError(
            "Layer operation $operation_idx must contain destination, function, and arguments"
        )
    )
    dest, operation_fn, args = operation[1], operation[2], operation[3]
    dest isa Symbol || throw(
        ArgumentError(
            "Layer operation $operation_idx has non-Symbol destination $(repr(dest))"
        )
    )
    args isa Tuple || throw(
        _operation_argument_error(operation_idx, dest, "must use a Tuple of arguments")
    )
    for keyword in operation[4:end]
        (keyword isa Pair && first(keyword) isa Symbol) || throw(
            _operation_argument_error(
                operation_idx,
                dest,
                "has malformed keyword $(repr(keyword)); expected :name => value"
            )
        )
    end
    keyword_values = Dict{Symbol, Any}(operation[4:end])
    length(keyword_values) == length(operation) - 3 || throw(
        _operation_argument_error(operation_idx, dest, "contains duplicate keyword names")
    )

    _require_arity(n) =
        length(args) == n || throw(
            _operation_argument_error(
                operation_idx,
                dest,
                "expects $n argument$(n == 1 ? "" : "s"), got $(length(args))"
            )
        )
    _require_symbol(value, label) =
        value isa Symbol || throw(
            _operation_argument_error(
                operation_idx,
                dest,
                "requires $label to be a Symbol"
            )
        )
    allowed_keywords = Symbol[]

    if operation_fn == SolidModels.extrude_z!
        _require_arity(0)
    elseif operation_fn == SolidModels.difference_geom!
        append!(allowed_keywords, (:remove_object, :remove_tool))
        _require_arity(2)
        _require_symbol(args[1], "the object layer")
        tools = args[2] isa AbstractVector ? args[2] : (args[2],)
        isempty(tools) && throw(
            _operation_argument_error(
                operation_idx,
                dest,
                "requires at least one tool layer"
            )
        )
        all(tool -> tool isa Symbol, tools) || throw(
            _operation_argument_error(operation_idx, dest, "requires Symbol tool layers")
        )
    elseif operation_fn == SolidModels.union_geom!
        isempty(args) && throw(
            _operation_argument_error(
                operation_idx,
                dest,
                "requires at least one source layer"
            )
        )
        all(source -> source isa Symbol, args) || throw(
            _operation_argument_error(operation_idx, dest, "requires Symbol source layers")
        )
    elseif operation_fn == SolidModels.intersect_geom!
        _require_arity(2)
        _require_symbol(args[1], "the object layer")
        _require_symbol(args[2], "the tool layer")
    elseif operation_fn == SolidModels.restrict_to_volume!
        _require_arity(1)
        _require_symbol(args[1], "the bounding-volume layer")
    elseif operation_fn == SolidModels.get_boundary
        append!(allowed_keywords, (:combined, :oriented, :recursive, :direction, :position))
        _require_arity(1)
        _require_symbol(args[1], "the source layer")
    elseif operation_fn == SolidModels.translate!
        push!(allowed_keywords, :copy)
        _require_arity(4)
        _require_symbol(args[1], "the source layer")
        all(value -> value isa Coordinate, args[2:4]) || throw(
            _operation_argument_error(
                operation_idx,
                dest,
                "requires Coordinate translation offsets"
            )
        )
    elseif operation_fn == SolidModels.remove_group!
        push!(allowed_keywords, :remove_entities)
        _require_arity(1)
        _require_symbol(args[1], "the source layer")
    elseif operation_fn == SolidModels.revolve!
        _require_arity(8)
        _require_symbol(args[1], "the source layer")
        all(value -> value isa Real, args[2:8]) || throw(
            _operation_argument_error(
                operation_idx,
                dest,
                "requires seven Real revolution values"
            )
        )
    elseif operation_fn == SolidModels.set_periodic!
        _require_arity(2)
        _require_symbol(args[1], "the first periodic layer")
        _require_symbol(args[2], "the second periodic layer")
    else
        throw(
            _operation_argument_error(
                operation_idx,
                dest,
                "uses unsupported operation $operation_fn"
            )
        )
    end
    for keyword in operation[4:end]
        first(keyword) in allowed_keywords || throw(
            _operation_argument_error(
                operation_idx,
                dest,
                "does not support keyword :$(first(keyword)) for $operation_fn"
            )
        )
    end

    for keyword_name in intersect(
        keys(keyword_values),
        (
            :copy,
            :remove_object,
            :remove_tool,
            :remove_entities,
            :combined,
            :oriented,
            :recursive
        )
    )
        keyword_values[keyword_name] isa Bool || throw(
            _operation_argument_error(
                operation_idx,
                dest,
                "requires keyword :$keyword_name to have a Bool value"
            )
        )
    end
    for (keyword_name, choices) in
        (:direction => ("all", "x", "y", "z"), :position => ("all", "min", "max"))
        haskey(keyword_values, keyword_name) || continue
        value = keyword_values[keyword_name]
        valid_value = value isa AbstractString && lowercase(value) in choices
        # SolidModels.get_boundary accepts case-insensitive axis names, but its all-axis
        # fast path currently requires the exact lowercase spelling.
        if keyword_name == :direction &&
           value isa AbstractString &&
           lowercase(value) == "all"
            valid_value = value == "all"
        end
        valid_value || throw(
            _operation_argument_error(
                operation_idx,
                dest,
                "requires keyword :$keyword_name to be one of $(join(choices, ", "))"
            )
        )
    end
    return nothing
end

# ─── Layer-level operation compiler ──────────────────────────────────────────

"""
    compile_layer_ops(layer_ops, stack, initial_registry)
        -> (pg_ops, registry, deferred_interfaces)

Compile layer-level operations into physical-group-level operations suitable for passing
to DeviceLayout's `_postrender!`.

Returns:

  - `pg_ops::Vector{Tuple}`: physical-group-level postrender operations
  - `registry::LayerRegistry`: final state of the layer registry
  - `deferred_interfaces::MetaGraphs.MetaDiGraph`: interface operations and unique PGs
    evaluated after fragmentation
"""
function compile_layer_ops(
    layer_ops::AbstractVector,
    stack::SourceStack,
    initial_registry::LayerRegistry
)
    registry = deepcopy(initial_registry)
    pg_ops = Tuple[]
    deferred_interfaces = _deferred_interface_graph()
    # Interior solids from contour_only + !keep_interior extrusions, keyed by layer name.
    # These are subtracted from all 3D volumes before restrict_to_volume!.
    interior_solids = Dict{Symbol, Vector{String}}()

    for (operation_idx, operation) in enumerate(layer_ops)
        _validate_layer_operation(operation, operation_idx)
        # Flush interior solids before restrict_to_volume! (subtraction must precede
        # fragmentation). The BV layer is excluded from subtraction since carving
        # holes in it would clip away the shell surfaces during restrict.
        if operation[2] == SolidModels.restrict_to_volume!
            bounding_volume_layer = operation[3][1]
            _flush_interior_solids!(
                pg_ops,
                registry,
                interior_solids,
                bounding_volume_layer
            )
        end
        _compile_one_op!(
            pg_ops,
            registry,
            deferred_interfaces,
            interior_solids,
            stack,
            operation
        )
    end

    # Flush any remaining interior solids (pipelines without restrict_to_volume!). If
    # restrict_to_volume! was previously compiled, the interior_solids array was already
    # emptied, so this call will do nothing.
    _flush_interior_solids!(pg_ops, registry, interior_solids, nothing)

    return pg_ops, registry, deferred_interfaces
end

function _compile_one_op!(
    pg_ops::Vector{Tuple},
    registry::LayerRegistry,
    deferred_interfaces::MetaGraphs.MetaDiGraph,
    interior_solids::Dict{Symbol, Vector{String}},
    stack::SourceStack,
    op::Tuple
)
    dest = op[1]
    op_fn = op[2]
    args = op[3]
    kwargs = op[4:end]

    return if op_fn == SolidModels.extrude_z!
        _compile_extrude!(pg_ops, registry, interior_solids, stack, dest)
    elseif op_fn == SolidModels.difference_geom!
        _compile_difference!(pg_ops, registry, dest, args, kwargs)
    elseif op_fn == SolidModels.union_geom!
        _compile_union!(pg_ops, registry, dest, args, kwargs)
    elseif op_fn == SolidModels.intersect_geom!
        _compile_intersect!(pg_ops, registry, deferred_interfaces, dest, args, kwargs)
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
    registry::LayerRegistry,
    interior_solids::Dict{Symbol, Vector{String}},
    bv_layer::Union{Symbol, Nothing}
)
    isempty(interior_solids) && return nothing

    interior_pg_names = String[]
    for pgs in values(interior_solids)
        append!(interior_pg_names, pgs)
    end

    for (layer_name, state) in registry
        state.dim != 3 && continue
        layer_name == bv_layer && continue
        for record in state.pgs
            push!(
                pg_ops,
                (
                    record.name,
                    SolidModels.difference_geom!,
                    (record.name, interior_pg_names, 3, 3),
                    :remove_object => true,
                    :remove_tool => false
                )
            )
        end
    end

    # Remove interior solid PGs (keep entities so they act as fragmentation boundaries)
    for pgs in values(interior_solids)
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

# ─── extrude_z! ──────────────────────────────────────────────────────────────

function _compile_extrude!(
    pg_ops::Vector{Tuple},
    registry::LayerRegistry,
    interior_solids::Dict{Symbol, Vector{String}},
    stack::SourceStack,
    layer_name::Symbol
)
    !haskey(registry, layer_name) && throw(
        ArgumentError(
            "Cannot extrude layer :$layer_name because it is absent from the " *
            "compiler registry"
        )
    )
    !haskey(stack.layers, layer_name) && throw(
        ArgumentError(
            "Cannot extrude generated layer :$layer_name because extrusion requires " *
            "a SourceStack entry"
        )
    )
    source_layer = stack.layers[layer_name]
    dz = thickness(source_layer, stack)
    iszero(dz) && return nothing

    state = registry[layer_name]
    new_records = PGRecord[]

    # Helper: register `bnd_pg` (the full boundary of an interior solid produced by a
    # `keep_interior=false` extrusion) under the synthetic `:EXTBND_MISC` layer.
    # After the interior solid is subtracted from surrounding volumes by
    # `_flush_interior_solids!`, this boundary becomes an exterior boundary of the final
    # mesh. Tagging it via `:EXTBND_MISC` lets `_deduplicate_2d_pgs!` split off any sub-PG
    # whose faces are
    # exterior-only (or shared with another layer) from sub-PGs whose faces are
    # purely interior interfaces, avoiding the "mixed boundary attribute" warning
    # that Palace emits for PGs containing both kinds of faces.
    function _register_extbnd_misc!(bnd_pg, meta)
        if !haskey(registry, :EXTBND_MISC)
            registry[:EXTBND_MISC] = LayerState(PGRecord[], 2)
        end
        return push!(registry[:EXTBND_MISC].pgs, PGRecord(bnd_pg, :EXTBND_MISC, meta))
    end

    for record in state.pgs
        pg = record.name
        if source_layer.contour_only
            # Extrude the contour (1D boundary of 2D surface) into a lateral shell
            ctr_pg = pg * "__CTR"
            ext_pg = pg * "__CTREXT"
            push!(pg_ops, (ctr_pg, SolidModels.get_boundary, (pg, 2), :oriented => false))
            push!(pg_ops, (ext_pg, SolidModels.extrude_z!, (ctr_pg, dz, 1)))
            push!(pg_ops, ("_rm", SolidModels.remove_group!, (ctr_pg, 1)))
            if !source_layer.keep_interior
                # Also extrude the 2D surface into a solid for interior subtraction
                int_pg = pg * "__INT"
                intbnd_pg = pg * "__INTBND"
                push!(pg_ops, (int_pg, SolidModels.extrude_z!, (pg, dz, 2)))
                push!(
                    pg_ops,
                    (intbnd_pg, SolidModels.get_boundary, (int_pg, 3), :oriented => false)
                )
                push!(pg_ops, ("_rm", SolidModels.remove_group!, (pg, 2)))
                push!(get!(interior_solids, layer_name, String[]), int_pg)
                _register_extbnd_misc!(intbnd_pg, record.meta)
            else
                push!(pg_ops, ("_rm", SolidModels.remove_group!, (pg, 2)))
            end
            push!(new_records, PGRecord(ext_pg, layer_name, record.meta))
        elseif !source_layer.keep_interior
            # Boundary-only extrusion: extrude to solid, extract boundary, discard interior.
            # The solid is registered for auto-subtraction from surrounding volumes.
            ext_pg = pg * "__EXN"
            bnd_pg = pg * "__EXTBND"
            push!(pg_ops, (ext_pg, SolidModels.extrude_z!, (pg, dz, 2)))
            push!(
                pg_ops,
                (bnd_pg, SolidModels.get_boundary, (ext_pg, 3), :oriented => false)
            )
            push!(pg_ops, ("_rm", SolidModels.remove_group!, (pg, 2)))
            push!(get!(interior_solids, layer_name, String[]), ext_pg)
            push!(new_records, PGRecord(bnd_pg, layer_name, record.meta))
            _register_extbnd_misc!(bnd_pg, record.meta)
        else
            # Standard extrusion: 2D surface → 3D volume
            ext_pg = pg * "__EXN"
            push!(pg_ops, (ext_pg, SolidModels.extrude_z!, (pg, dz, 2)))
            push!(pg_ops, ("_rm", SolidModels.remove_group!, (pg, 2)))
            push!(new_records, PGRecord(ext_pg, layer_name, record.meta))
        end
    end

    new_dim = source_layer.contour_only ? 2 : (source_layer.keep_interior ? 3 : 2)
    registry[layer_name] = LayerState(new_records, new_dim)
    return nothing
end

# ─── difference_geom! ────────────────────────────────────────────────────────

function _compile_difference!(
    pg_ops::Vector{Tuple},
    registry::LayerRegistry,
    dest::Symbol,
    args::Tuple,
    kwargs
)
    object_layer = args[1]
    tool_layers_raw = args[2]
    # Support both a single tool layer and a vector of tool layers.
    tool_layers = tool_layers_raw isa AbstractVector ? tool_layers_raw : (tool_layers_raw,)

    !haskey(registry, object_layer) && throw(
        ArgumentError("Object layer :$object_layer is absent from the compiler registry")
    )
    for tool_layer in tool_layers
        !haskey(registry, tool_layer) && throw(
            ArgumentError("Tool layer :$tool_layer is absent from the compiler registry")
        )
    end

    object_state = registry[object_layer]
    dim = object_state.dim
    tool_pg_names = String[]
    for tool_layer in tool_layers
        for record in registry[tool_layer].pgs
            push!(tool_pg_names, record.name)
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

    kwargs_dict = _parse_kwargs(kwargs)
    remove_object = get(kwargs_dict, :remove_object, false)
    remove_tool = get(kwargs_dict, :remove_tool, false)

    if mode == :replace && dest == object_layer
        for record in object_state.pgs
            push!(
                pg_ops,
                (
                    record.name,
                    SolidModels.difference_geom!,
                    (record.name, tool_pg_names, dim, dim),
                    :remove_object => true,
                    :remove_tool => false
                )
            )
        end
    elseif mode == :replace && dest_is_tool
        tool_state = registry[dest]
        object_pg_names = [record.name for record in object_state.pgs]
        for record in tool_state.pgs
            push!(
                pg_ops,
                (
                    record.name,
                    SolidModels.difference_geom!,
                    (record.name, object_pg_names, dim, dim),
                    :remove_object => true,
                    :remove_tool => false
                )
            )
        end
    else
        # Create or append mode.
        new_records = PGRecord[]
        for record in object_state.pgs
            dest_name =
                string(dest) *
                "__" *
                operation_hash(
                    record.name,
                    tool_pg_names;
                    operation=:difference,
                    parameters=(dim, remove_object)
                )
            generated_record_exists(registry, dest, dest_name, new_records) && continue
            push!(
                pg_ops,
                (
                    dest_name,
                    SolidModels.difference_geom!,
                    (record.name, tool_pg_names, dim, dim),
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
                record.name for record in registry[dest].pgs if
                isnothing(record.meta) || !(record.meta.role isa Locator)
            ]
            if !isempty(existing_pgs)
                for record in new_records
                    push!(
                        pg_ops,
                        (
                            record.name,
                            SolidModels.difference_geom!,
                            (record.name, existing_pgs, dim, dim),
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
        for tool_layer in tool_layers
            tool_layer != dest && delete!(registry, tool_layer)
        end
    end
    if remove_object && dest != object_layer
        delete!(registry, object_layer)
    end

    return nothing
end

# ─── union_geom! ─────────────────────────────────────────────────────────────

function _compile_union!(
    pg_ops::Vector{Tuple},
    registry::LayerRegistry,
    dest::Symbol,
    args::Tuple,
    ::Any
)
    source_layers = collect(args)

    if length(source_layers) == 1
        source_layer = source_layers[1]
        !haskey(registry, source_layer) && throw(
            ArgumentError(
                "Source layer :$source_layer is absent from the compiler registry"
            )
        )
        state = registry[source_layer]

        if dest == source_layer
            # Self-heal mode
            for record in state.pgs
                push!(
                    pg_ops,
                    (record.name, SolidModels.union_geom!, (record.name, state.dim))
                )
            end
        else
            # Self-heal and move into a generated destination. If that destination already
            # exists independently, append distinct records without discarding its state.
            new_records = PGRecord[]
            for record in state.pgs
                dest_name =
                    string(dest) *
                    "__" *
                    operation_hash(
                        record.name,
                        String[];
                        operation=:union,
                        parameters=(state.dim,)
                    )
                generated_record_exists(registry, dest, dest_name, new_records) && continue
                push!(
                    pg_ops,
                    (dest_name, SolidModels.union_geom!, (record.name, state.dim))
                )
                push!(new_records, PGRecord(dest_name, dest, record.meta))
            end
            if haskey(registry, dest)
                _require_destination_dimension(registry, dest, state.dim)
                existing_pgs = [
                    record.name for record in registry[dest].pgs if
                    !(!isnothing(record.meta) && record.meta.role isa Locator)
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
            delete!(registry, source_layer)
        end
    else
        # Collapse mode: fuse all source PGs into one
        all_pg_names = String[]
        dim = 0
        for source_layer in source_layers
            !haskey(registry, source_layer) && throw(
                ArgumentError(
                    "Source layer :$source_layer is absent from the compiler registry"
                )
            )
            append!(all_pg_names, [record.name for record in registry[source_layer].pgs])
            dim = registry[source_layer].dim
        end

        sorted_pg_names = sort(all_pg_names)
        dest_name =
            string(dest) *
            "__" *
            operation_hash(
                first(sorted_pg_names),
                sorted_pg_names[2:end];
                operation=:union,
                parameters=(dim,)
            )
        new_record = PGRecord(dest_name, dest, nothing)
        duplicate = generated_record_exists(registry, dest, dest_name)
        duplicate ||
            push!(pg_ops, (dest_name, SolidModels.union_geom!, (all_pg_names, dim)))

        if haskey(registry, dest) && dest ∉ source_layers
            _require_destination_dimension(registry, dest, dim)
            # Append. An exact duplicate operation is a no-op: recompiling it must not copy
            # geometry again or duplicate the layer's physical-group list.
            existing_pgs = [
                record.name for record in registry[dest].pgs if
                isnothing(record.meta) || !(record.meta.role isa Locator)
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
        for source_layer in source_layers
            source_layer != dest && delete!(registry, source_layer)
        end
    end

    return nothing
end

# ─── intersect_geom! ─────────────────────────────────────────────────────────

function _compile_intersect!(
    ::Vector{Tuple},
    registry::LayerRegistry,
    deferred_interfaces::MetaGraphs.MetaDiGraph,
    dest::Symbol,
    args::Tuple,
    ::Any
)
    obj_layer, tool_layer = args[1], args[2]
    !haskey(registry, obj_layer) && throw(
        ArgumentError("Object layer :$obj_layer is absent from the compiler registry")
    )
    !haskey(registry, tool_layer) &&
        throw(ArgumentError("Tool layer :$tool_layer is absent from the compiler registry"))

    obj_state = registry[obj_layer]
    tool_state = registry[tool_layer]
    obj_dim = obj_state.dim
    tool_dim = tool_state.dim

    new_recs = PGRecord[]
    for obj_rec in obj_state.pgs
        for tool_rec in tool_state.pgs
            dest_name =
                string(dest) *
                "__" *
                operation_hash(
                    obj_rec.name,
                    [tool_rec.name];
                    operation=:intersect,
                    parameters=(obj_dim, tool_dim)
                )
            generated_record_exists(registry, dest, dest_name, new_recs) && continue
            # All intersections are deferred to post-fragmentation. Same-dim
            # intersections find shared boundary entities (dim-1); mixed-dim
            # intersections find lo-dim entities on the hi-dim boundary.
            defer_interface!(
                deferred_interfaces,
                dest_name,
                obj_rec.name,
                tool_rec.name,
                obj_dim,
                tool_dim,
                dest,
                obj_rec.layer,
                tool_rec.layer
            )
            push!(new_recs, PGRecord(dest_name, dest, nothing))
        end
    end

    # Result dimension: mixed-dim intersections produce entities at min(d1, d2).
    # Same-dim intersections (e.g. 3D∩3D) produce shared boundaries at dim-1.
    new_dim = obj_dim == tool_dim ? obj_dim - 1 : min(obj_dim, tool_dim)

    if haskey(registry, dest) && dest != obj_layer && dest != tool_layer
        _require_destination_dimension(registry, dest, new_dim)
        append!(registry[dest].pgs, new_recs)
    else
        registry[dest] = LayerState(new_recs, new_dim)
    end

    return nothing
end

"""
    _compile_restrict!(pg_ops, reg, args)

Compile a restriction operation using the single physical group in the bounding-volume
layer.
"""
function _compile_restrict!(pg_ops::Vector{Tuple}, reg::LayerRegistry, args::Tuple)
    bv_layer = args[1]
    !haskey(reg, bv_layer) && throw(
        ArgumentError(
            "Bounding volume layer :$bv_layer is absent from the compiler registry"
        )
    )
    bv_pgs = reg[bv_layer].pgs
    length(bv_pgs) == 1 || throw(
        ArgumentError(
            "Bounding volume layer :$bv_layer must contain exactly one physical group"
        )
    )
    bv_pg = bv_pgs[1].name
    push!(pg_ops, ("restrict", SolidModels.restrict_to_volume!, (bv_pg,)))
    return nothing
end

# ─── get_boundary ────────────────────────────────────────────────────────────

function _compile_get_boundary!(
    pg_ops::Vector{Tuple},
    registry::LayerRegistry,
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

    if dest == source_layer
        # Replace mode
        for record in state.pgs
            push!(
                pg_ops,
                (record.name, SolidModels.get_boundary, (record.name, dim), kwargs...)
            )
        end
        state.dim = dim - 1
    else
        # Create/append mode
        new_records = PGRecord[]
        for record in state.pgs
            dest_name =
                string(dest) *
                "__" *
                operation_hash(
                    record.name,
                    String[];
                    operation=:boundary,
                    parameters=(dim, _content_kwargs(kwargs))
                )
            generated_record_exists(registry, dest, dest_name, new_records) && continue
            push!(
                pg_ops,
                (dest_name, SolidModels.get_boundary, (record.name, dim), kwargs...)
            )
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

# ─── translate! ──────────────────────────────────────────────────────────────

function _compile_translate!(
    pg_ops::Vector{Tuple},
    registry::LayerRegistry,
    dest::Symbol,
    args::Tuple,
    kwargs
)
    source_layer = args[1]
    dx, dy, dz = args[2], args[3], args[4]
    !haskey(registry, source_layer) && throw(
        ArgumentError("Source layer :$source_layer is absent from the compiler registry")
    )

    kwargs_dict = _parse_kwargs(kwargs)
    copy_entities = get(kwargs_dict, :copy, false)

    state = registry[source_layer]

    if dest == source_layer && !copy_entities
        # Replace mode (in-place translate)
        for record in state.pgs
            push!(
                pg_ops,
                (
                    record.name,
                    SolidModels.translate!,
                    (record.name, dx, dy, dz),
                    :copy => false
                )
            )
        end
    else
        # Create/append mode (copy-translate)
        new_records = PGRecord[]
        for record in state.pgs
            dest_name =
                string(dest) *
                "__" *
                operation_hash(
                    record.name,
                    String[];
                    operation=:translate,
                    parameters=(dx, dy, dz)
                )
            generated_record_exists(registry, dest, dest_name, new_records) && continue
            push!(
                pg_ops,
                (
                    dest_name,
                    SolidModels.translate!,
                    (record.name, dx, dy, dz),
                    :copy => true
                )
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

# ─── remove_group! ───────────────────────────────────────────────────────────

function _compile_remove!(pg_ops::Vector{Tuple}, reg::LayerRegistry, args::Tuple, kwargs)
    layer_name = args[1]
    !haskey(reg, layer_name) &&
        throw(ArgumentError("Layer :$layer_name is absent from the compiler registry"))

    kwargs_dict = _parse_kwargs(kwargs)
    remove_entities = get(kwargs_dict, :remove_entities, true)

    state = reg[layer_name]
    for record in state.pgs
        push!(
            pg_ops,
            (
                "_rm",
                SolidModels.remove_group!,
                (record.name, state.dim),
                :remove_entities => remove_entities
            )
        )
    end
    delete!(reg, layer_name)
    return nothing
end

# ─── revolve! ────────────────────────────────────────────────────────────────

function _compile_revolve!(
    pg_ops::Vector{Tuple},
    registry::LayerRegistry,
    dest::Symbol,
    args::Tuple,
    ::Any
)
    source_layer = args[1]
    x, y, z, ax, ay, az, θ = args[2], args[3], args[4], args[5], args[6], args[7], args[8]
    !haskey(registry, source_layer) && throw(
        ArgumentError("Source layer :$source_layer is absent from the compiler registry")
    )

    state = registry[source_layer]
    dim = state.dim

    if dest == source_layer
        for record in state.pgs
            push!(
                pg_ops,
                (
                    record.name,
                    SolidModels.revolve!,
                    (record.name, dim, x, y, z, ax, ay, az, θ)
                )
            )
        end
        state.dim = dim + 1
    else
        new_records = PGRecord[]
        for record in state.pgs
            dest_name =
                string(dest) *
                "__" *
                operation_hash(
                    record.name,
                    String[];
                    operation=:revolve,
                    parameters=(dim, x, y, z, ax, ay, az, θ)
                )
            generated_record_exists(registry, dest, dest_name, new_records) && continue
            push!(
                pg_ops,
                (
                    dest_name,
                    SolidModels.revolve!,
                    (record.name, dim, x, y, z, ax, ay, az, θ)
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

# ─── set_periodic! ───────────────────────────────────────────────────────────

function _compile_set_periodic!(pg_ops::Vector{Tuple}, reg::LayerRegistry, args::Tuple)
    layer_a, layer_b = args[1], args[2]
    !haskey(reg, layer_a) && throw(
        ArgumentError("Periodic layer :$layer_a is absent from the compiler registry")
    )
    !haskey(reg, layer_b) && throw(
        ArgumentError("Periodic layer :$layer_b is absent from the compiler registry")
    )

    records_a = reg[layer_a].pgs
    records_b = reg[layer_b].pgs
    length(records_a) == length(records_b) || throw(
        ArgumentError(
            "set_periodic! requires equal physical-group counts in layers " *
            ":$layer_a and :$layer_b"
        )
    )

    for (record_a, record_b) in zip(records_a, records_b)
        push!(
            pg_ops,
            (
                "Periodic_$(record_a.name)",
                SolidModels.set_periodic!,
                (record_a.name, record_b.name, 2, 2)
            )
        )
    end

    return nothing
end

# ─── Keyword-argument helper ─────────────────────────────────────────────────

function _parse_kwargs(kwargs)
    kwargs_dict = Dict{Symbol, Any}()
    for kwarg in kwargs
        if kwarg isa Pair
            kwargs_dict[first(kwarg)] = last(kwarg)
        end
    end
    return kwargs_dict
end
