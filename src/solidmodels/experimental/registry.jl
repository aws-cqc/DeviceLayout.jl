struct PGRecord
    name::String
    layer::Symbol
    entity_meta::Union{EntityMeta, Nothing}
end

mutable struct LayerState
    pgs::Vector{PGRecord}
    dim::Int
end

const Registry = Dict{Symbol, LayerState}

struct DeferredInterface
    dest_name::String
    obj_pg_name::String
    tool_pg_name::String
    obj_dim::Int
    tool_dim::Int
end

"""
    generated_pg_name(dest, obj_pg, tool_pgs; operation, parameters=()) -> String

Return the content-addressed physical-group name for a generated layer operation.
"""
function generated_pg_name(
    dest::Symbol,
    obj_pg::String,
    tool_pgs::Vector{String};
    operation::Symbol,
    parameters=()
)
    content =
        join((string(operation), obj_pg, join(sort(tool_pgs), "&"), repr(parameters)), "\0")
    digest = sha1(content)
    return string(dest) * "__" * bytes2hex(digest)[1:16]
end

_content_kwargs(kwargs) = Tuple(sort(collect(kwargs); by=keyword -> string(first(keyword))))

function _generated_record_exists(
    reg::Registry,
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

function _require_destination_dimension(reg::Registry, dest::Symbol, dim::Int)
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

    require_arity(n) =
        length(args) == n || throw(
            _operation_argument_error(
                operation_idx,
                dest,
                "expects $n argument$(n == 1 ? "" : "s"), got $(length(args))"
            )
        )
    require_symbol(value, label) =
        value isa Symbol || throw(
            _operation_argument_error(
                operation_idx,
                dest,
                "requires $label to be a Symbol"
            )
        )
    allowed_keywords = Symbol[]

    if operation_fn == SolidModels.extrude_z!
        require_arity(0)
    elseif operation_fn == SolidModels.difference_geom!
        append!(allowed_keywords, (:remove_object, :remove_tool))
        require_arity(2)
        require_symbol(args[1], "the object layer")
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
        require_arity(2)
        require_symbol(args[1], "the object layer")
        require_symbol(args[2], "the tool layer")
    elseif operation_fn == SolidModels.restrict_to_volume!
        require_arity(1)
        require_symbol(args[1], "the bounding-volume layer")
    elseif operation_fn == SolidModels.get_boundary
        append!(allowed_keywords, (:combined, :oriented, :recursive, :direction, :position))
        require_arity(1)
        require_symbol(args[1], "the source layer")
    elseif operation_fn == SolidModels.translate!
        push!(allowed_keywords, :copy)
        require_arity(4)
        require_symbol(args[1], "the source layer")
        all(value -> value isa Coordinate, args[2:4]) || throw(
            _operation_argument_error(
                operation_idx,
                dest,
                "requires Coordinate translation offsets"
            )
        )
    elseif operation_fn == SolidModels.remove_group!
        push!(allowed_keywords, :remove_entities)
        require_arity(1)
        require_symbol(args[1], "the source layer")
    elseif operation_fn == SolidModels.revolve!
        require_arity(8)
        require_symbol(args[1], "the source layer")
        all(value -> value isa Real, args[2:8]) || throw(
            _operation_argument_error(
                operation_idx,
                dest,
                "requires seven Real revolution values"
            )
        )
    elseif operation_fn == SolidModels.set_periodic!
        require_arity(2)
        require_symbol(args[1], "the first periodic layer")
        require_symbol(args[2], "the second periodic layer")
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

const _EXTERIOR_BOUNDARY_LAYERS = Dict(
    ("X", "min") => :EXTBND_XMIN,
    ("X", "max") => :EXTBND_XMAX,
    ("Y", "min") => :EXTBND_YMIN,
    ("Y", "max") => :EXTBND_YMAX,
    ("Z", "min") => :EXTBND_ZMIN,
    ("Z", "max") => :EXTBND_ZMAX
)

function _entity_metas(cs)
    metas = EntityMeta[]
    for (subcs, _) in DeviceLayout.traversal(cs)
        for entity_meta in element_metadata(subcs)
            entity_meta isa EntityMeta && push!(metas, entity_meta)
        end
    end
    return metas
end

function _preflight(cs, stack::SourceStack, ops::Vector{Tuple})
    _validate_stack(stack)
    for entity_meta in _entity_metas(cs)
        sourcelayer(entity_meta, stack)
    end
    # Validate operation syntax before Gmsh. Registry-aware source-layer validation happens
    # during compilation, where previously generated destination layers are available.
    for (operation_idx, operation) in enumerate(ops)
        _validate_layer_operation(operation, operation_idx)
    end
    return nothing
end

function _map_meta_for_stack(stack::SourceStack, m::EntityMeta)
    sl = sourcelayer(m, stack)
    (!sl.solidmodel || m.role isa Locator) && return nothing
    return physical_group_name(m)
end
_map_meta_for_stack(::SourceStack, ::DeviceLayout.Meta) = nothing

function _build_initial_registry(cs, stack::SourceStack)
    registry = Registry()
    for entity_meta in unique(_entity_metas(cs))
        source_layer = sourcelayer(entity_meta, stack)
        (!source_layer.solidmodel || entity_meta.role isa Locator) && continue
        record = PGRecord(physical_group_name(entity_meta), entity_meta.layer, entity_meta)
        state = get!(registry, entity_meta.layer) do
            return LayerState(PGRecord[], 2)
        end
        any(existing -> existing.name == record.name, state.pgs) || push!(state.pgs, record)
    end
    return registry
end

function _schedule_extrusions(stack::SourceStack, reg::Registry)
    operations = Tuple[]
    for (layer_name, source_layer) in stack.layers
        haskey(reg, layer_name) || continue
        iszero(thickness(source_layer, stack)) && continue
        push!(operations, (layer_name, SolidModels.extrude_z!, ()))
    end
    return operations
end

function _retained_physical_groups(reg::Registry, deferred::Vector{DeferredInterface})
    deferred_names = Set(interface.dest_name for interface in deferred)
    retained = Set{Tuple{String, Int}}()
    for state in values(reg)
        for record in state.pgs
            record.name in deferred_names && continue
            !isnothing(record.entity_meta) &&
                record.entity_meta.role isa Locator &&
                continue
            push!(retained, (record.name, state.dim))
        end
    end
    return retained
end

"""
    exnboundaries(bounding_volume_layer::Symbol) -> Vector{Tuple}

Return operations extracting all six axis-aligned exterior faces of
`bounding_volume_layer` into `:EXTBND_XMIN`, `:EXTBND_XMAX`, `:EXTBND_YMIN`,
`:EXTBND_YMAX`, `:EXTBND_ZMIN`, and `:EXTBND_ZMAX`.
"""
function exnboundaries(bounding_volume_layer::Symbol)
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
