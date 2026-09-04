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

"""
Supertype for typed layer-level solid-model operations.
"""
abstract type LayerOp end

"""
Supertype for layer-level Boolean operations.
"""
abstract type BooleanOp <: LayerOp end

"""
`Extrude(layer)` extrudes a source layer using its `SourceStack` thickness.
"""
struct Extrude <: LayerOp
    destination::Symbol
end

"""
    Difference(destination, object, tools)

Subtract one tool layer, or a grouped tuple or vector of tool layers, from `object`.
Use adjacent [`Remove`](@ref) operations to remove inputs.
"""
struct Difference{N} <: BooleanOp
    destination::Symbol
    object::Symbol
    tools::NTuple{N, Symbol}
    function Difference{N}(destination, object, tools) where {N}
        iszero(N) && throw(ArgumentError("difference requires at least one tool layer"))
        return new{N}(destination, object, tools)
    end
end
Difference(dest::Symbol, object::Symbol, tools::NTuple{N, Symbol}) where {N} =
    Difference{N}(dest, object, tools)
Difference(dest::Symbol, object::Symbol, tool::Symbol) = Difference(dest, object, (tool,))
Difference(dest::Symbol, object::Symbol, tools::AbstractVector{Symbol}) =
    Difference(dest, object, Tuple(tools))

"""
    Fuse(source)
    Fuse(destination, sources)

Collapse every physical group in one or more source layers into one generated physical
group in `destination`.
"""
struct Fuse{N} <: BooleanOp
    destination::Symbol
    sources::NTuple{N, Symbol}
    function Fuse{N}(destination, sources) where {N}
        iszero(N) && throw(ArgumentError("fuse requires at least one source layer"))
        allunique(sources) || throw(ArgumentError("fuse source layers must be unique"))
        return new{N}(destination, sources)
    end
end
Fuse(dest::Symbol, sources::NTuple{N, Symbol}) where {N} = Fuse{N}(dest, sources)
Fuse(dest::Symbol, sources::AbstractVector{Symbol}) = Fuse(dest, Tuple(sources))
Fuse(source::Symbol) = Fuse(source, (source,))

"""
    Heal(source)
    Heal(destination, source)

Heal (i.e. self-union) every physical group in one source layer independently, preserving its identity and
metadata, optionally under a new layer namespace.
"""
struct Heal <: LayerOp
    destination::Symbol
    source::Symbol
end
Heal(source::Symbol) = Heal(source, source)

"""
`Interface(destination, object, tool)` extracts a deferred geometric interface.
"""
struct Interface <: BooleanOp
    destination::Symbol
    object::Symbol
    tool::Symbol
end

"""
`RestrictTo(volume)` restricts the model to a 3D bounding-volume layer containing
exactly one physical group.
"""
struct RestrictTo <: LayerOp
    volume::Symbol
end

"""
    Boundary(destination, source; combined=true, oriented=true, recursive=false,
             direction="all", position="all")

Extract the boundary of a source layer.
"""
struct Boundary <: LayerOp
    destination::Symbol
    source::Symbol
    combined::Bool
    oriented::Bool
    recursive::Bool
    direction::String
    position::String
    function Boundary(
        destination::Symbol,
        source::Symbol,
        combined::Bool,
        oriented::Bool,
        recursive::Bool,
        direction::AbstractString,
        position::AbstractString
    )
        direction = lowercase(direction)
        position = lowercase(position)
        direction in ("all", "x", "y", "z") ||
            throw(ArgumentError("direction must be all, x, y, or z"))
        position in ("all", "min", "max") ||
            throw(ArgumentError("position must be all, min, or max"))
        return new(destination, source, combined, oriented, recursive, direction, position)
    end
end
function Boundary(
    destination::Symbol,
    source::Symbol;
    combined::Bool=true,
    oriented::Bool=true,
    recursive::Bool=false,
    direction::AbstractString="all",
    position::AbstractString="all"
)
    return Boundary(destination, source, combined, oriented, recursive, direction, position)
end

"""
    Translate(destination, source, dx, dy, dz; copy=true)

Translate a layer, copying its entities by default.
"""
struct Translate{X <: Coordinate, Y <: Coordinate, Z <: Coordinate} <: LayerOp
    destination::Symbol
    source::Symbol
    dx::X
    dy::Y
    dz::Z
    copy::Bool
end
Translate(
    destination::Symbol,
    source::Symbol,
    dx::Coordinate,
    dy::Coordinate,
    dz::Coordinate;
    copy::Bool=true
) = Translate(destination, source, dx, dy, dz, copy)

"""
`Remove(source; remove_entities=true)` removes a layer from the model, or does nothing
if the layer is absent.
"""
struct Remove <: LayerOp
    source::Symbol
    remove_entities::Bool
end
Remove(source::Symbol; remove_entities::Bool=true) = Remove(source, remove_entities)

"""
`Revolve(destination, source, origin, axis, angle)` sweeps a layer around an axis,
retaining the swept entities at dimension `source_dimension + 1`.
"""
struct Revolve <: LayerOp
    destination::Symbol
    source::Symbol
    origin::NTuple{3, Float64}
    axis::NTuple{3, Float64}
    angle::Float64
end
function Revolve(
    destination::Symbol,
    source::Symbol,
    origin::NTuple{3, <:Real},
    axis::NTuple{3, <:Real},
    angle::Real
)
    return Revolve(destination, source, Float64.(origin), Float64.(axis), Float64(angle))
end

"""
`Periodic(first, second)` pairs two 2D periodic layers containing one physical group each.
"""
struct Periodic <: LayerOp
    first::Symbol
    second::Symbol
end

# ─── Lowered operations ──────────────────────────────────────────────────────

struct _LoweredDifference{N} <: BooleanOp
    destination::Symbol
    object::Symbol
    tools::NTuple{N, Symbol}
    remove_object::Bool
    remove_tool::Bool
end

function inspect_registry(registry::LayerRegistry; io::IO=stdout)
    for (layer, state) in sort!(collect(registry); by=first)
        println(io, layer, " (dim=", state.dim, ")")
        for record in state.pgs
            print(io, "  ", record.name, " [", record.layer, "]")
            if !isnothing(record.meta)
                meta = record.meta
                print(
                    io,
                    " ",
                    nameof(typeof(meta)),
                    "(name=",
                    repr(meta.name),
                    ", index=",
                    meta.index,
                    ", role=",
                    nameof(typeof(meta.role)),
                    ")"
                )
            end
            println(io)
        end
    end
    return nothing
end

function inspect_ops(ops::AbstractVector; io::IO=stdout)
    for (idx, op) in enumerate(ops)
        print(io, idx, ": ")
        show(io, op[1])
        print(io, " = ", nameof(op[2]))
        show(io, op[3])
        for keyword in op[4:end]
            print(io, "; ")
            show(io, keyword)
        end
        println(io)
    end
    return nothing
end

function initial_registry(metas::AbstractVector{<:EntityMeta}, stack::SourceStack)
    registry = LayerRegistry()
    for meta in unique(metas)
        source_layer = sourcelayer(meta, stack)
        (!source_layer.solidmodel || islocator(meta)) && continue
        record = PGRecord(pgname(meta), meta.layer, meta)
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
        throw(ArgumentError("deferred interface '$dest_pg' is already defined"))
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

function ophash(obj_pg::String, tool_pgs::Vector{String}; operation::Symbol, parameters=())
    content =
        join((string(operation), obj_pg, join(sort(tool_pgs), "&"), repr(parameters)), "\0")
    return bytes2hex(sha1(content))[1:16]
end

function generated_record_exists(
    reg::LayerRegistry,
    dest::Symbol,
    name::String,
    pending::Vector{PGRecord}=PGRecord[]
)
    any(record -> record.name == name, pending) && return true
    return haskey(reg, dest) && any(record -> record.name == name, reg[dest].pgs)
end

function _require_destination_dimension(reg::LayerRegistry, dest::Symbol, dim::Int)
    if haskey(reg, dest) && reg[dest].dim != dim
        throw(
            ArgumentError(
                "destination layer :$dest has dimension $(reg[dest].dim), " *
                "so dimension $dim physical groups cannot be appended"
            )
        )
    end
    return nothing
end

source_layers(op::Extrude) = (op.destination,)
source_layers(op::Difference) = (op.object, op.tools...)
source_layers(op::Fuse) = op.sources
source_layers(op::Heal) = (op.source,)
source_layers(op::Interface) = (op.object, op.tool)
source_layers(op::RestrictTo) = (op.volume,)
source_layers(op::Boundary) = (op.source,)
source_layers(op::Translate) = (op.source,)
source_layers(op::Remove) = (op.source,)
source_layers(op::Revolve) = (op.source,)
source_layers(op::Periodic) = (op.first, op.second)

source_layers(op::_LoweredDifference) = (op.object, op.tools...)

function _absorb_removals(ops::AbstractVector{<:LayerOp})
    result = LayerOp[]
    i = firstindex(ops)
    while i <= lastindex(ops)
        op = ops[i]
        if !(op isa Difference)
            push!(result, op)
            i += 1
            continue
        end

        j = i + 1
        removals = Remove[]
        while j <= lastindex(ops) && ops[j] isa Remove
            push!(removals, ops[j])
            j += 1
        end

        ambiguous = op.object in op.tools
        remove_object =
            !ambiguous &&
            op.object != op.destination &&
            any(r -> r.source == op.object && r.remove_entities, removals)
        remove_tool =
            !ambiguous &&
            op.destination ∉ op.tools &&
            all(tool -> any(r -> r.source == tool && r.remove_entities, removals), op.tools)
        push!(
            result,
            _LoweredDifference(
                op.destination,
                op.object,
                op.tools,
                remove_object,
                remove_tool
            )
        )

        for removal in removals
            absorbed =
                removal.remove_entities && (
                    remove_object && removal.source == op.object ||
                    remove_tool && removal.source in op.tools
                )
            absorbed || push!(result, removal)
        end
        i = j
    end
    return result
end

_validate_source_layers(::Remove, ::LayerRegistry) = nothing

function _validate_source_layers(op::LayerOp, registry::LayerRegistry)
    for source in source_layers(op)
        haskey(registry, source) || throw(
            ArgumentError("source layer :$source is absent from the compiler registry")
        )
    end
    return nothing
end

struct CompilerState{S <: SourceStack}
    ops::Vector{Tuple}                       # Compiled physical-group operations
    reg::LayerRegistry                       # Evolving layer-to-PG registry
    dints::MetaGraphs.MetaDiGraph             # Deferred interface operations
    intsol::Dict{Symbol, Vector{String}}      # Pending temporary interior solids
    stack::S                                 # Source-layer geometry configuration
end

"""
    compile_ops(ops::AbstractVector{<:LayerOp}, stack, registry)
        -> (pg_ops, registry, deferred_interfaces)

Compile layer-level operations into physical-group-level operations suitable for passing
to DeviceLayout's `_postrender!`.

Returns:

  - `ops::Vector{Tuple}`: physical-group-level postrender operations
  - `registry::LayerRegistry`: final state of the layer registry
  - `deferred_interfaces::MetaGraphs.MetaDiGraph`: interface operations and unique PGs
    evaluated after fragmentation
"""
function compile_ops(
    ops::AbstractVector{<:LayerOp},
    stack::SourceStack,
    registry::LayerRegistry
)
    cmp = CompilerState(
        Tuple[],
        deepcopy(registry),
        _deferred_interface_graph(),
        Dict{Symbol, Vector{String}}(),
        stack
    )
    optimized_ops = _absorb_removals(ops)
    for op in optimized_ops
        _validate_source_layers(op, cmp.reg)
        op isa RestrictTo && _flush_interior_solids!(cmp, op.volume)
        _compile!(cmp, op)
    end
    _flush_interior_solids!(cmp, nothing)
    return cmp.ops, cmp.reg, cmp.dints
end

# Subtract pending interior solids from all 3D volumes in the registry (except the
# bounding volume if specified), then remove the interior solid PGs (keeping entities
# so they serve as fragmentation boundaries during `restrict_to_volume!`).
function _flush_interior_solids!(cmp::CompilerState, bv_layer::Union{Symbol, Nothing})
    isempty(cmp.intsol) && return nothing

    interior_pg_names = String[]
    for pgs in values(cmp.intsol)
        append!(interior_pg_names, pgs)
    end

    for (layer_name, state) in cmp.reg
        state.dim != 3 && continue
        layer_name == bv_layer && continue
        for record in state.pgs
            push!(
                cmp.ops,
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
    for pgs in values(cmp.intsol)
        for pg_name in pgs
            push!(
                cmp.ops,
                ("_rm", SolidModels.remove_group!, (pg_name, 3), :remove_entities => false)
            )
        end
    end

    empty!(cmp.intsol)
    return nothing
end

function _compile!(cmp::CompilerState, op::Extrude)
    !haskey(cmp.stack.layers, op.destination) && throw(
        ArgumentError(
            "cannot extrude generated layer :$(op.destination) because extrusion requires " *
            "a SourceStack entry"
        )
    )
    source_layer = cmp.stack.layers[op.destination]
    dz = thickness(source_layer, cmp.stack)
    iszero(dz) && return nothing

    state = cmp.reg[op.destination]
    new_records = PGRecord[]

    # Helper: register `bnd_pg` (the full boundary of an interior solid produced by a
    # `keep_interior=false` extrusion) under the generated `:EXTBND_MISC` layer.
    # After the interior solid is subtracted from surrounding volumes by
    # `_flush_interior_solids!`, this boundary becomes an exterior boundary of the final
    # mesh. Tagging it via `:EXTBND_MISC` lets `_deduplicate_2d_pgs!` split off any sub-PG
    # whose faces are
    # exterior-only (or shared with another layer) from sub-PGs whose faces are
    # purely interior interfaces, avoiding the "mixed boundary attribute" warning
    # that Palace emits for PGs containing both kinds of faces.
    function _register_extbnd!(bnd_pg, meta)
        if !haskey(cmp.reg, :EXTBND_MISC)
            cmp.reg[:EXTBND_MISC] = LayerState(PGRecord[], 2)
        end
        return push!(cmp.reg[:EXTBND_MISC].pgs, PGRecord(bnd_pg, :EXTBND_MISC, meta))
    end

    for record in state.pgs
        pg = record.name
        if source_layer.contour_only
            # Extrude the contour (1D boundary of 2D surface) to form a shell
            ctr_pg = pg * "__CTR"
            ext_pg = pg * "__CTREXT"
            push!(cmp.ops, (ctr_pg, SolidModels.get_boundary, (pg, 2), :oriented => false))
            push!(cmp.ops, (ext_pg, SolidModels.extrude_z!, (ctr_pg, dz, 1)))
            push!(cmp.ops, ("_rm", SolidModels.remove_group!, (ctr_pg, 1)))
            if !source_layer.keep_interior
                # Also extrude the 2D surface into a solid for interior subtraction
                int_pg = pg * "__INT"
                intbnd_pg = pg * "__INTBND"
                push!(cmp.ops, (int_pg, SolidModels.extrude_z!, (pg, dz, 2)))
                push!(
                    cmp.ops,
                    (intbnd_pg, SolidModels.get_boundary, (int_pg, 3), :oriented => false)
                )
                push!(cmp.ops, ("_rm", SolidModels.remove_group!, (pg, 2)))
                push!(get!(cmp.intsol, op.destination, String[]), int_pg)
                _register_extbnd!(intbnd_pg, record.meta)
            else
                push!(cmp.ops, ("_rm", SolidModels.remove_group!, (pg, 2)))
            end
            push!(new_records, PGRecord(ext_pg, op.destination, record.meta))
        elseif !source_layer.keep_interior
            # Boundary-only extrusion: extrude to solid, extract boundary, discard interior.
            # The solid is registered for auto-subtraction from surrounding volumes.
            ext_pg = pg * "__EXN"
            bnd_pg = pg * "__EXTBND"
            push!(cmp.ops, (ext_pg, SolidModels.extrude_z!, (pg, dz, 2)))
            push!(
                cmp.ops,
                (bnd_pg, SolidModels.get_boundary, (ext_pg, 3), :oriented => false)
            )
            push!(cmp.ops, ("_rm", SolidModels.remove_group!, (pg, 2)))
            push!(get!(cmp.intsol, op.destination, String[]), ext_pg)
            push!(new_records, PGRecord(bnd_pg, op.destination, record.meta))
            _register_extbnd!(bnd_pg, record.meta)
        else
            # Standard extrusion: 2D surface → 3D volume
            ext_pg = pg * "__EXN"
            push!(cmp.ops, (ext_pg, SolidModels.extrude_z!, (pg, dz, 2)))
            push!(cmp.ops, ("_rm", SolidModels.remove_group!, (pg, 2)))
            push!(new_records, PGRecord(ext_pg, op.destination, record.meta))
        end
    end

    new_dim = source_layer.contour_only ? 2 : (source_layer.keep_interior ? 3 : 2)
    cmp.reg[op.destination] = LayerState(new_records, new_dim)
    return nothing
end

function _compile!(cmp::CompilerState, op::_LoweredDifference)
    object_state = cmp.reg[op.object]
    dim = object_state.dim
    tool_pg_names =
        String[record.name for tool_layer in op.tools for record in cmp.reg[tool_layer].pgs]
    mode = if op.destination == op.object
        :replace_object
    elseif op.destination in op.tools
        :replace_tool
    elseif haskey(cmp.reg, op.destination)
        :append
    else
        :create
    end

    new_records = PGRecord[]
    compiled = Tuple{PGRecord, String}[]
    for record in object_state.pgs
        dest_name = if mode == :replace_object
            record.name
        else
            string(op.destination) *
            "__" *
            ophash(
                record.name,
                tool_pg_names;
                operation=:difference,
                parameters=(dim, op.remove_object, op.remove_tool)
            )
        end
        if mode != :replace_object &&
           generated_record_exists(cmp.reg, op.destination, dest_name, new_records)
            continue
        end
        push!(compiled, (record, dest_name))
        mode == :replace_object ||
            push!(new_records, PGRecord(dest_name, op.destination, nothing))
    end

    for (idx, (record, dest_name)) in enumerate(compiled)
        push!(
            cmp.ops,
            (
                dest_name,
                SolidModels.difference_geom!,
                (record.name, tool_pg_names, dim, dim),
                :remove_object => op.remove_object,
                :remove_tool => op.remove_tool && idx == length(compiled)
            )
        )
    end

    if mode == :append
        _require_destination_dimension(cmp.reg, op.destination, dim)
        existing_pgs = [
            record.name for record in cmp.reg[op.destination].pgs if !islocator(record.meta)
        ]
        if !isempty(existing_pgs)
            for record in new_records
                # Keep newly appended PGs disjoint from existing PGs in the same layer.
                push!(
                    cmp.ops,
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
        append!(cmp.reg[op.destination].pgs, new_records)
    elseif mode != :replace_object
        cmp.reg[op.destination] = LayerState(new_records, dim)
    end

    # Flush removed references from registry
    if !isempty(compiled)
        if op.remove_tool
            for tool_layer in op.tools
                tool_layer != op.destination && delete!(cmp.reg, tool_layer)
            end
        end
        op.remove_object && op.destination != op.object && delete!(cmp.reg, op.object)
    end

    return nothing
end

function _compile!(cmp::CompilerState, op::Fuse)
    haskey(cmp.reg, op.destination) &&
        op.destination ∉ op.sources &&
        throw(
            ArgumentError(
                "a Fuse destination that already exists must be included among its sources"
            )
        )

    dims = unique([cmp.reg[source].dim for source in op.sources])
    length(dims) == 1 ||
        throw(ArgumentError("fuse source layers must have equal dimensions"))
    dim = only(dims)
    source_pgs =
        sort!([record.name for source in op.sources for record in cmp.reg[source].pgs])
    isempty(source_pgs) && throw(ArgumentError("fuse requires at least one physical group"))

    dest_name =
        string(op.destination) *
        "__" *
        ophash(first(source_pgs), source_pgs[2:end]; operation=:union, parameters=(dim,))
    push!(cmp.ops, (dest_name, SolidModels.union_geom!, (source_pgs, dim)))
    for source in op.sources
        source != op.destination && delete!(cmp.reg, source)
    end
    cmp.reg[op.destination] =
        LayerState([PGRecord(dest_name, op.destination, nothing)], dim)
    return nothing
end

function _replace_layer_prefix(name::String, source::Symbol, destination::Symbol)
    prefix = string(source, "__")
    startswith(name, prefix) || throw(
        ArgumentError(
            "physical-group name '$name' does not begin with layer prefix '$prefix'"
        )
    )
    return string(destination, "__", chop(name; head=length(prefix), tail=0))
end

function _compile!(cmp::CompilerState, op::Heal)
    state = cmp.reg[op.source]
    if op.destination == op.source
        for record in state.pgs
            push!(cmp.ops, (record.name, SolidModels.union_geom!, (record.name, state.dim)))
        end
        return nothing
    end

    haskey(cmp.reg, op.destination) &&
        _require_destination_dimension(cmp.reg, op.destination, state.dim)
    new_records = [
        PGRecord(
            _replace_layer_prefix(record.name, op.source, op.destination),
            op.destination,
            record.meta
        ) for record in state.pgs
    ]
    existing_names =
        haskey(cmp.reg, op.destination) ?
        Set(record.name for record in cmp.reg[op.destination].pgs) : Set{String}()
    collision = findfirst(record -> record.name in existing_names, new_records)
    isnothing(collision) || throw(
        ArgumentError(
            "healed physical-group name '$(new_records[collision].name)' already exists"
        )
    )

    for (record, new_record) in zip(state.pgs, new_records)
        push!(cmp.ops, (new_record.name, SolidModels.union_geom!, (record.name, state.dim)))
    end
    if haskey(cmp.reg, op.destination)
        existing_pgs = [
            record.name for record in cmp.reg[op.destination].pgs if !islocator(record.meta)
        ]
        if !isempty(existing_pgs)
            for record in new_records
                # Ensure added PGs don't have any overlap with existing PGs in the
                # destination laye
                push!(
                    cmp.ops,
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
        append!(cmp.reg[op.destination].pgs, new_records)
    else
        cmp.reg[op.destination] = LayerState(new_records, state.dim)
    end
    delete!(cmp.reg, op.source)
    return nothing
end

function _compile!(cmp::CompilerState, op::Interface)
    obj_state = cmp.reg[op.object]
    tool_state = cmp.reg[op.tool]
    obj_dim = obj_state.dim
    tool_dim = tool_state.dim

    new_recs = PGRecord[]
    for obj_rec in obj_state.pgs
        for tool_rec in tool_state.pgs
            dest_name =
                string(op.destination) *
                "__" *
                ophash(
                    obj_rec.name,
                    [tool_rec.name];
                    operation=:interface,
                    parameters=(obj_dim, tool_dim)
                )
            generated_record_exists(cmp.reg, op.destination, dest_name, new_recs) &&
                continue
            # All interface calculations are deferred to post-fragmentation. Interfaces of
            # same-dim entities are shared boundary entities (dim-1); interfaces of
            # mixed-dim entities are lo-dim entities on the hi-dim boundary.
            defer_interface!(
                cmp.dints,
                dest_name,
                obj_rec.name,
                tool_rec.name,
                obj_dim,
                tool_dim,
                op.destination,
                obj_rec.layer,
                tool_rec.layer
            )
            push!(new_recs, PGRecord(dest_name, op.destination, nothing))
        end
    end

    # Result dimension: mixed-dim entites produce entities at min(d1, d2).
    # Same-dim entities (e.g. 3D∩3D) produce shared boundaries at dim-1.
    new_dim = obj_dim == tool_dim ? obj_dim - 1 : min(obj_dim, tool_dim)

    if haskey(cmp.reg, op.destination) &&
       op.destination != op.object &&
       op.destination != op.tool
        _require_destination_dimension(cmp.reg, op.destination, new_dim)
        append!(cmp.reg[op.destination].pgs, new_recs)
    else
        cmp.reg[op.destination] = LayerState(new_recs, new_dim)
    end

    return nothing
end

function _compile!(cmp::CompilerState, op::RestrictTo)
    state = cmp.reg[op.volume]
    state.dim == 3 || throw(ArgumentError("bounding volume layer :$(op.volume) must be 3D"))
    bv_pgs = state.pgs
    length(bv_pgs) == 1 || throw(
        ArgumentError(
            "bounding volume layer :$(op.volume) must contain exactly one physical group"
        )
    )
    bv_pg = bv_pgs[1].name
    push!(cmp.ops, ("restrict", SolidModels.restrict_to_volume!, (bv_pg,)))
    return nothing
end

# Compile the shared replace and create/append modes for one-source layer operations.
function _compile_unary_layer_op!(
    lower,
    cmp::CompilerState,
    destination::Symbol,
    source::Symbol,
    destination_dim::Int;
    replace::Bool,
    hash_operation::Symbol,
    hash_parameters
)
    state = cmp.reg[source]
    if replace
        for record in state.pgs
            push!(cmp.ops, lower(record.name, record))
        end
        state.dim = destination_dim
        return nothing
    end

    new_records = PGRecord[]
    for record in state.pgs
        base_name =
            string(destination) *
            "__" *
            ophash(
                record.name,
                String[];
                operation=hash_operation,
                parameters=hash_parameters
            )
        dest_name = base_name
        suffix = 2
        while generated_record_exists(cmp.reg, destination, dest_name, new_records)
            dest_name = base_name * "__" * string(suffix)
            suffix += 1
        end
        push!(cmp.ops, lower(dest_name, record))
        push!(new_records, PGRecord(dest_name, destination, nothing))
    end

    if haskey(cmp.reg, destination)
        _require_destination_dimension(cmp.reg, destination, destination_dim)
        append!(cmp.reg[destination].pgs, new_records)
    else
        cmp.reg[destination] = LayerState(new_records, destination_dim)
    end
    return nothing
end

function _compile!(cmp::CompilerState, op::Boundary)
    dim = cmp.reg[op.source].dim
    kwargs = (
        :combined => op.combined,
        :oriented => op.oriented,
        :recursive => op.recursive,
        :direction => op.direction,
        :position => op.position
    )
    return _compile_unary_layer_op!(
        cmp,
        op.destination,
        op.source,
        max(dim - 1, 0);
        replace=op.destination == op.source,
        hash_operation=:boundary,
        hash_parameters=(
            dim,
            op.combined,
            op.oriented,
            op.recursive,
            op.direction,
            op.position
        )
    ) do destination, record
        return (destination, SolidModels.get_boundary, (record.name, dim), kwargs...)
    end
end

function _compile!(cmp::CompilerState, op::Translate)
    dim = cmp.reg[op.source].dim
    return _compile_unary_layer_op!(
        cmp,
        op.destination,
        op.source,
        dim;
        replace=op.destination == op.source && !op.copy,
        hash_operation=:translate,
        hash_parameters=(op.dx, op.dy, op.dz, op.copy)
    ) do destination, record
        return (
            destination,
            SolidModels.translate!,
            (record.name, op.dx, op.dy, op.dz),
            :copy => op.copy
        )
    end
end

function _compile!(cmp::CompilerState, op::Remove)
    haskey(cmp.reg, op.source) || return nothing
    state = cmp.reg[op.source]
    for record in state.pgs
        push!(
            cmp.ops,
            (
                "_rm",
                SolidModels.remove_group!,
                (record.name, state.dim),
                :remove_entities => op.remove_entities
            )
        )
    end
    delete!(cmp.reg, op.source)
    return nothing
end

function _compile!(cmp::CompilerState, op::Revolve)
    dim = cmp.reg[op.source].dim
    dim < 3 || throw(ArgumentError("cannot revolve a 3D layer"))
    return _compile_unary_layer_op!(
        cmp,
        op.destination,
        op.source,
        dim + 1;
        replace=op.destination == op.source,
        hash_operation=:revolve,
        hash_parameters=(dim, op.origin, op.axis, op.angle)
    ) do destination, record
        return (
            destination,
            SolidModels.revolve!,
            (record.name, dim, op.origin..., op.axis..., op.angle)
        )
    end
end

function _compile!(cmp::CompilerState, op::Periodic)
    first_state = cmp.reg[op.first]
    second_state = cmp.reg[op.second]
    first_state.dim == 2 && second_state.dim == 2 ||
        throw(ArgumentError("periodic layers must both be 2D"))
    length(first_state.pgs) == 1 && length(second_state.pgs) == 1 ||
        throw(ArgumentError("periodic layers must each contain exactly one physical group"))

    first_pg = only(first_state.pgs).name
    second_pg = only(second_state.pgs).name
    push!(
        cmp.ops,
        ("Periodic_$first_pg", SolidModels.set_periodic!, (first_pg, second_pg, 2, 2))
    )
    return nothing
end
