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
    Difference(destination, object, tools; remove_object=false, remove_tool=false)

Subtract one tool layer, or a grouped tuple or vector of tool layers, from `object`.
"""
struct Difference{N} <: BooleanOp
    destination::Symbol
    object::Symbol
    tools::NTuple{N, Symbol}
    remove_object::Bool
    remove_tool::Bool
    function Difference{N}(destination, object, tools, remove_object, remove_tool) where {N}
        iszero(N) && throw(ArgumentError("difference requires at least one tool layer"))
        return new{N}(destination, object, tools, remove_object, remove_tool)
    end
end
Difference(
    dest::Symbol,
    object::Symbol,
    tools::NTuple{N, Symbol};
    remove_object::Bool=false,
    remove_tool::Bool=false
) where {N} = Difference{N}(dest, object, tools, remove_object, remove_tool)
Difference(dest::Symbol, object::Symbol, tool::Symbol; kwargs...) =
    Difference(dest, object, (tool,); kwargs...)
Difference(dest::Symbol, object::Symbol, tools::AbstractVector{Symbol}; kwargs...) =
    Difference(dest, object, Tuple(tools); kwargs...)

"""
`Fuse(destination, sources)` unions a grouped tuple or vector of source layers.
"""
struct Fuse{N} <: BooleanOp
    destination::Symbol
    sources::NTuple{N, Symbol}
    function Fuse{N}(destination, sources) where {N}
        iszero(N) && throw(ArgumentError("fuse requires at least one source layer"))
        return new{N}(destination, sources)
    end
end
Fuse(dest::Symbol, sources::NTuple{N, Symbol}) where {N} = Fuse{N}(dest, sources)
Fuse(dest::Symbol, sources::AbstractVector{Symbol}) = Fuse(dest, Tuple(sources))

"""
`Interface(destination, object, tool)` extracts a deferred geometric interface.
"""
struct Interface <: BooleanOp
    destination::Symbol
    object::Symbol
    tool::Symbol
end

"""
`Restrict(volume)` restricts the model to one bounding-volume layer.
"""
struct Restrict <: LayerOp
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
`Remove(source; remove_entities=true)` removes a layer from the model.
"""
struct Remove <: LayerOp
    source::Symbol
    remove_entities::Bool
end
Remove(source::Symbol; remove_entities::Bool=true) = Remove(source, remove_entities)

"""
`Revolve(destination, source, origin, axis, angle)` revolves a layer.
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
`Periodic(first, second)` pairs two periodic layers.
"""
struct Periodic <: LayerOp
    first::Symbol
    second::Symbol
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
        (!source_layer.solidmodel || meta.role isa Locator) && continue
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
source_layers(op::Interface) = (op.object, op.tool)
source_layers(op::Restrict) = (op.volume,)
source_layers(op::Boundary) = (op.source,)
source_layers(op::Translate) = (op.source,)
source_layers(op::Remove) = (op.source,)
source_layers(op::Revolve) = (op.source,)
source_layers(op::Periodic) = (op.first, op.second)

function _validate_source_layers(op::LayerOp, registry::LayerRegistry)
    for source in source_layers(op)
        haskey(registry, source) || throw(
            ArgumentError("source layer :$source is absent from the compiler registry")
        )
    end
    return nothing
end

# ─── Layer-level operation compiler ──────────────────────────────────────────

"""
    compile_ops(ops::AbstractVector{<:LayerOp}, stack, registry)
        -> (pg_ops, registry, deferred_interfaces)

Compile layer-level operations into physical-group-level operations suitable for passing
to DeviceLayout's `_postrender!`.

Returns:

  - `pg_ops::Vector{Tuple}`: physical-group-level postrender operations
  - `registry::LayerRegistry`: final state of the layer registry
  - `deferred_interfaces::MetaGraphs.MetaDiGraph`: interface operations and unique PGs
    evaluated after fragmentation
"""
struct CompilerState{S <: SourceStack}
    pg_ops::Vector{Tuple}
    registry::LayerRegistry
    deferred_interfaces::MetaGraphs.MetaDiGraph
    interior_solids::Dict{Symbol, Vector{String}}
    stack::S
end

function compile_ops(
    ops::AbstractVector{<:LayerOp},
    stack::SourceStack,
    registry::LayerRegistry
)
    state = CompilerState(
        Tuple[],
        deepcopy(registry),
        _deferred_interface_graph(),
        Dict{Symbol, Vector{String}}(),
        stack
    )
    for op in ops
        _validate_source_layers(op, state.registry)
        op isa Restrict && _flush_interior_solids!(
            state.pg_ops,
            state.registry,
            state.interior_solids,
            op.volume
        )
        _compile!(state, op)
    end
    _flush_interior_solids!(state.pg_ops, state.registry, state.interior_solids, nothing)
    return state.pg_ops, state.registry, state.deferred_interfaces
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

function _compile!(compiler::CompilerState, op::Extrude)
    pg_ops = compiler.pg_ops
    registry = compiler.registry
    interior_solids = compiler.interior_solids
    stack = compiler.stack
    layer_name = op.destination
    !haskey(stack.layers, layer_name) && throw(
        ArgumentError(
            "cannot extrude generated layer :$layer_name because extrusion requires " *
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
            # Extrude the contour (1D boundary of 2D surface) to form a shell
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

function _compile!(compiler::CompilerState, op::Difference)
    pg_ops = compiler.pg_ops
    registry = compiler.registry
    dest = op.destination
    object_layer = op.object
    tool_layers = op.tools

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

    remove_object = op.remove_object
    remove_tool = op.remove_tool

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
                    parameters=(dim, op.remove_object, op.remove_tool)
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

# ─── Fuse ────────────────────────────────────────────────────────────────────

function _compile!(compiler::CompilerState, op::Fuse)
    pg_ops = compiler.pg_ops
    registry = compiler.registry
    dest = op.destination
    source_layers = op.sources

    if length(source_layers) == 1
        source_layer = source_layers[1]
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
            state = registry[source_layer]
            append!(all_pg_names, [record.name for record in state.pgs])
            dim = state.dim
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

# ─── Interface ───────────────────────────────────────────────────────────────

function _compile!(compiler::CompilerState, op::Interface)
    registry = compiler.registry
    deferred_interfaces = compiler.deferred_interfaces
    dest = op.destination
    obj_layer, tool_layer = op.object, op.tool
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
    _compile!(compiler, op::Restrict)

Compile a restriction operation using the single physical group in the bounding-volume
layer.
"""
function _compile!(compiler::CompilerState, op::Restrict)
    pg_ops = compiler.pg_ops
    registry = compiler.registry
    bv_layer = op.volume
    bv_pgs = registry[bv_layer].pgs
    length(bv_pgs) == 1 || throw(
        ArgumentError(
            "bounding volume layer :$bv_layer must contain exactly one physical group"
        )
    )
    bv_pg = bv_pgs[1].name
    push!(pg_ops, ("restrict", SolidModels.restrict_to_volume!, (bv_pg,)))
    return nothing
end

# ─── Boundary ────────────────────────────────────────────────────────────────

function _compile!(compiler::CompilerState, op::Boundary)
    pg_ops = compiler.pg_ops
    registry = compiler.registry
    dest = op.destination
    source_layer = op.source
    kwargs = (
        :combined => op.combined,
        :oriented => op.oriented,
        :recursive => op.recursive,
        :direction => op.direction,
        :position => op.position
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
                    parameters=(
                        dim,
                        op.combined,
                        op.oriented,
                        op.recursive,
                        op.direction,
                        op.position
                    )
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

function _compile!(compiler::CompilerState, op::Translate)
    pg_ops = compiler.pg_ops
    registry = compiler.registry
    dest = op.destination
    source_layer = op.source
    dx, dy, dz = op.dx, op.dy, op.dz
    state = registry[source_layer]
    copy_entities = op.copy

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
        # Create/append mode
        new_records = PGRecord[]
        for record in state.pgs
            base_name =
                string(dest) *
                "__" *
                operation_hash(
                    record.name,
                    String[];
                    operation=:translate,
                    parameters=(op.dx, op.dy, op.dz, op.copy)
                )
            dest_name = base_name
            suffix = 2
            # Identical translations must all execute and remain represented in the registry,
            # to match DeviceLayout's PG-level operation semantics. Add a local
            # suffix when the content hash collides.
            while generated_record_exists(registry, dest, dest_name, new_records)
                dest_name = base_name * "__" * string(suffix)
                suffix += 1
            end
            push!(
                pg_ops,
                (
                    dest_name,
                    SolidModels.translate!,
                    (record.name, dx, dy, dz),
                    :copy => copy_entities
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

function _compile!(compiler::CompilerState, op::Remove)
    pg_ops = compiler.pg_ops
    registry = compiler.registry
    layer_name = op.source
    remove_entities = op.remove_entities

    state = registry[layer_name]
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
    delete!(registry, layer_name)
    return nothing
end

# ─── revolve! ────────────────────────────────────────────────────────────────

function _compile!(compiler::CompilerState, op::Revolve)
    pg_ops = compiler.pg_ops
    registry = compiler.registry
    dest = op.destination
    source_layer = op.source
    x, y, z = op.origin
    ax, ay, az = op.axis
    θ = op.angle
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
                    parameters=(dim, op.origin, op.axis, op.angle)
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

# ─── Periodic ────────────────────────────────────────────────────────────────

function _compile!(compiler::CompilerState, op::Periodic)
    pg_ops = compiler.pg_ops
    registry = compiler.registry
    layer_a, layer_b = op.first, op.second
    records_a = registry[layer_a].pgs
    records_b = registry[layer_b].pgs
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
