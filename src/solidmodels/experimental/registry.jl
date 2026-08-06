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

function generated_pg_name(
    dest::Symbol,
    obj_pg::String,
    tool_pgs::Vector{String};
    operation::Symbol,
    parameters=()
)::String
    content =
        join((string(operation), obj_pg, join(sort(tool_pgs), "&"), repr(parameters)), "\0")
    digest = sha1(Vector{UInt8}(content))
    return string(dest) * "__" * bytes2hex(digest)[1:16]
end

_content_kwargs(kwargs) = Tuple(sort(collect(kwargs); by=keyword -> string(first(keyword))))

function _generated_record_exists(
    registry::Registry,
    dest::Symbol,
    name::String,
    pending::Vector{PGRecord}=PGRecord[]
)
    any(record -> record.name == name, pending) && return true
    return haskey(registry, dest) && any(record -> record.name == name, registry[dest].pgs)
end

function _operation_argument_error(index::Integer, dest, message::AbstractString)
    destination = dest isa Symbol ? ":$dest" : repr(dest)
    return ArgumentError("Layer operation $index for destination $destination $message")
end

function _require_destination_dimension(registry::Registry, dest::Symbol, dim::Int)
    if haskey(registry, dest) && registry[dest].dim != dim
        throw(
            ArgumentError(
                "Destination layer :$dest has dimension $(registry[dest].dim), " *
                "so dimension $dim physical groups cannot be appended"
            )
        )
    end
    return nothing
end

function _validate_layer_operation(operation, index::Integer)
    operation isa Tuple || throw(
        ArgumentError("Layer operation $index must be a Tuple, got $(typeof(operation))")
    )
    length(operation) >= 3 || throw(
        ArgumentError(
            "Layer operation $index must contain destination, function, and arguments"
        )
    )
    dest, op_fn, args = operation[1], operation[2], operation[3]
    dest isa Symbol || throw(
        ArgumentError("Layer operation $index has non-Symbol destination $(repr(dest))")
    )
    args isa Tuple ||
        throw(_operation_argument_error(index, dest, "must use a Tuple of arguments"))
    for keyword in operation[4:end]
        (keyword isa Pair && first(keyword) isa Symbol) || throw(
            _operation_argument_error(
                index,
                dest,
                "has malformed keyword $(repr(keyword)); expected :name => value"
            )
        )
    end
    keyword_values = Dict{Symbol, Any}(operation[4:end])
    length(keyword_values) == length(operation) - 3 ||
        throw(_operation_argument_error(index, dest, "contains duplicate keyword names"))

    require_arity(n) =
        length(args) == n || throw(
            _operation_argument_error(
                index,
                dest,
                "expects $n argument$(n == 1 ? "" : "s"), got $(length(args))"
            )
        )
    require_symbol(value, label) =
        value isa Symbol ||
        throw(_operation_argument_error(index, dest, "requires $label to be a Symbol"))
    allowed_keywords = Symbol[]

    if op_fn == SolidModels.extrude_z!
        require_arity(0)
    elseif op_fn == SolidModels.difference_geom!
        append!(allowed_keywords, (:remove_object, :remove_tool))
        require_arity(2)
        require_symbol(args[1], "the object layer")
        tools = args[2] isa AbstractVector ? args[2] : (args[2],)
        isempty(tools) && throw(
            _operation_argument_error(index, dest, "requires at least one tool layer")
        )
        all(tool -> tool isa Symbol, tools) ||
            throw(_operation_argument_error(index, dest, "requires Symbol tool layers"))
    elseif op_fn == SolidModels.union_geom!
        isempty(args) && throw(
            _operation_argument_error(index, dest, "requires at least one source layer")
        )
        all(source -> source isa Symbol, args) ||
            throw(_operation_argument_error(index, dest, "requires Symbol source layers"))
    elseif op_fn == SolidModels.intersect_geom!
        require_arity(2)
        require_symbol(args[1], "the object layer")
        require_symbol(args[2], "the tool layer")
    elseif op_fn == SolidModels.restrict_to_volume!
        require_arity(1)
        require_symbol(args[1], "the bounding-volume layer")
    elseif op_fn == SolidModels.get_boundary
        append!(allowed_keywords, (:combined, :oriented, :recursive, :direction, :position))
        require_arity(1)
        require_symbol(args[1], "the source layer")
    elseif op_fn == SolidModels.translate!
        push!(allowed_keywords, :copy)
        require_arity(4)
        require_symbol(args[1], "the source layer")
        all(value -> value isa Coordinate, args[2:4]) || throw(
            _operation_argument_error(
                index,
                dest,
                "requires Coordinate translation offsets"
            )
        )
    elseif op_fn == SolidModels.remove_group!
        push!(allowed_keywords, :remove_entities)
        require_arity(1)
        require_symbol(args[1], "the source layer")
    elseif op_fn == SolidModels.revolve!
        require_arity(8)
        require_symbol(args[1], "the source layer")
        all(value -> value isa Real, args[2:8]) || throw(
            _operation_argument_error(index, dest, "requires seven Real revolution values")
        )
    elseif op_fn == SolidModels.set_periodic!
        require_arity(2)
        require_symbol(args[1], "the first periodic layer")
        require_symbol(args[2], "the second periodic layer")
    else
        throw(_operation_argument_error(index, dest, "uses unsupported operation $op_fn"))
    end
    for keyword in operation[4:end]
        first(keyword) in allowed_keywords || throw(
            _operation_argument_error(
                index,
                dest,
                "does not support keyword :$(first(keyword)) for $op_fn"
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
                index,
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
                index,
                dest,
                "requires keyword :$keyword_name to be one of $(join(choices, ", "))"
            )
        )
    end
    return nothing
end

const _EXTBND_MISC_LAYER = :EXTBND_MISC
const _METAL_CC_LAYER = :METAL_CC
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
    for (structure, _) in DeviceLayout.traversal(cs)
        for meta in element_metadata(structure)
            meta isa EntityMeta && push!(metas, meta)
        end
    end
    return metas
end

function _preflight(cs, stack::SourceStack, levels::StackLevels, ops::Vector{Tuple})
    _validate_stack(stack, levels)
    for meta in _entity_metas(cs)
        _require_source_layer(stack, meta; context="placed EntityMeta")
    end
    # Validate operation syntax before Gmsh. Registry-aware source-layer validation happens
    # during compilation, where previously generated destination layers are available.
    for (index, operation) in enumerate(ops)
        _validate_layer_operation(operation, index)
    end
    return nothing
end

function _meta_z(stack::SourceStack, levels::StackLevels, meta::EntityMeta)
    source_layer = _require_source_layer(stack, meta)
    return _stack_z(levels[first_level(source_layer)], first_height(source_layer))
end

function _map_meta_for_stack(stack::SourceStack, meta::EntityMeta)
    source_layer = _require_source_layer(stack, meta)
    (!source_layer.solidmodel || meta.role isa Locator) && return nothing
    return physical_group_name(meta)
end
_map_meta_for_stack(::SourceStack, ::DeviceLayout.Meta) = nothing

function _build_initial_registry(cs, stack::SourceStack)::Registry
    registry = Registry()
    for meta in unique(_entity_metas(cs))
        source_layer = _require_source_layer(stack, meta)
        (!source_layer.solidmodel || meta.role isa Locator) && continue
        record = PGRecord(physical_group_name(meta), meta.layer, meta)
        state = get!(registry, meta.layer) do
            return LayerState(PGRecord[], 2)
        end
        any(existing -> existing.name == record.name, state.pgs) || push!(state.pgs, record)
    end
    return registry
end

function _schedule_extrusions(
    stack::SourceStack,
    registry::Registry,
    levels::StackLevels
)::Vector{Tuple}
    operations = Tuple[]
    for (layer_name, source_layer) in stack
        haskey(registry, layer_name) || continue
        iszero(resolve_thickness(source_layer, levels)) && continue
        push!(operations, (layer_name, SolidModels.extrude_z!, ()))
    end
    return operations
end

function _retained_physical_groups(registry::Registry, deferred::Vector{DeferredInterface})
    deferred_names = Set(interface.dest_name for interface in deferred)
    retained = Set{Tuple{String, Int}}()
    for state in values(registry)
        for record in state.pgs
            record.name in deferred_names && continue
            record.entity_meta !== nothing &&
                record.entity_meta.role isa Locator &&
                continue
            push!(retained, (record.name, state.dim))
        end
    end
    return retained
end

"""
Return operations extracting all six axis-aligned exterior faces of a volume layer.
"""
function exnboundaries(bounding_volume_layer::Symbol)::Vector{Tuple}
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
