struct PGRecord
    name::String
    layer::Symbol
end

mutable struct LayerState
    pgs::Vector{PGRecord}
    dim::Int
end

const LayerRegistry = Dict{Symbol, LayerState}

# Internal supertypes for typed layer-level operations.
abstract type LayerOp end
abstract type BooleanOp <: LayerOp end

"""
    Extrude(layer)

Extrude a source layer using the thickness and contour behavior in its [`SourceLayer`](@ref).
"""
struct Extrude <: LayerOp
    destination::Symbol
end

function extrusions(stack::SourceStack, reg::LayerRegistry)
    operations = LayerOp[]
    for (layer_name, source_layer) in stack.layers
        haskey(reg, layer_name) || continue
        iszero(thickness(source_layer, stack)) && continue
        push!(operations, Extrude(layer_name))
    end
    return operations
end

"""
    Cut(destination, object, tools)

Subtract one tool layer, or a grouped tuple or vector of tool layers, from `object`.
Non-destination inputs remain available unless consumed by adjacent [`Remove`](@ref)
operations. Duplicate internal output PG names are rejected.
"""
struct Cut{N} <: BooleanOp
    destination::Symbol
    object::Symbol
    tools::NTuple{N, Symbol}
    function Cut{N}(destination, object, tools) where {N}
        iszero(N) && throw(ArgumentError("Cut requires at least one tool layer"))
        return new{N}(destination, object, tools)
    end
end
Cut(dest::Symbol, object::Symbol, tools::NTuple{N, Symbol}) where {N} =
    Cut{N}(dest, object, tools)
Cut(dest::Symbol, object::Symbol, tool::Symbol) = Cut(dest, object, (tool,))
Cut(dest::Symbol, object::Symbol, tools::AbstractVector{Symbol}) =
    Cut(dest, object, Tuple(tools))

"""
    Fuse(source)
    Fuse(destination, sources)

Union one or more source layers into `destination`. Group multiple sources in a tuple or
vector. Append to an existing destination when it is not a source; include it among the
sources to replace its current geometry. Out-of-place sources remain available unless
consumed by adjacent [`Remove`](@ref) operations.
"""
struct Fuse{N} <: BooleanOp
    destination::Symbol
    sources::NTuple{N, Symbol}
    function Fuse{N}(destination, sources) where {N}
        iszero(N) && throw(ArgumentError("Fuse requires at least one source layer"))
        allunique(sources) || throw(ArgumentError("Fuse source layers must be unique"))
        return new{N}(destination, sources)
    end
end
Fuse(dest::Symbol, sources::NTuple{N, Symbol}) where {N} = Fuse{N}(dest, sources)
Fuse(dest::Symbol, sources::AbstractVector{Symbol}) = Fuse(dest, Tuple(sources))
Fuse(source::Symbol) = Fuse(source, (source,))

"""
    Heal(source)
    Heal(destination, source)

Heal one source layer. In-place healing replaces its geometry; assign mode writes healed
geometry to another layer and preserves the source unless consumed by an adjacent
[`Remove`](@ref).
"""
struct Heal <: LayerOp
    destination::Symbol
    source::Symbol
end
Heal(source::Symbol) = Heal(source, source)

"""
    Intersect(destination, object, tool)

Compute the intersection of `object` and `tool`. The destination dimension is the lower
input dimension. In-place operation consumes the replaced OCC input; other inputs remain
available unless consumed by adjacent [`Remove`](@ref) operations. Object and tool layers
must be distinct.
"""
struct Intersect <: BooleanOp
    destination::Symbol
    object::Symbol
    tool::Symbol
    function Intersect(destination::Symbol, object::Symbol, tool::Symbol)
        object == tool &&
            throw(ArgumentError("Intersect requires distinct object and tool layers"))
        return new(destination, object, tool)
    end
end

"""
    GetInterface(destination, object, tool)

Compute the interface between `object` and `tool`. Same-dimensional inputs produce an
interface one dimension lower; mixed-dimensional inputs produce an interface at the lower
input dimension. The destination must differ from both inputs, and every input PG must remain
available through deferred interface execution. Duplicate internal output PG names
are rejected.
"""
struct GetInterface <: BooleanOp
    destination::Symbol
    object::Symbol
    tool::Symbol
    function GetInterface(destination::Symbol, object::Symbol, tool::Symbol)
        destination in (object, tool) && throw(
            ArgumentError("GetInterface destination must differ from its input layers")
        )
        return new(destination, object, tool)
    end
end

"""
    RestrictTo(volume)

Restrict the model to a 3D bounding-volume layer containing exactly one physical group.
"""
struct RestrictTo <: LayerOp
    volume::Symbol
end

"""
    GetBoundary(destination, source; combined=true, oriented=true, recursive=false,
             direction="all", position="all")

Extract the boundary of `source` into `destination`. Use `direction` and `position` to
select axis-aligned boundary entities. The destination must be new or equal to `source`;
appending to an existing unrelated layer is rejected. Boundaries produced from multiple
source PGs are expected to be disjoint.
"""
struct GetBoundary <: LayerOp
    destination::Symbol
    source::Symbol
    combined::Bool
    oriented::Bool
    recursive::Bool
    direction::String
    position::String
    function GetBoundary(
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
            throw(ArgumentError("GetBoundary direction must be all, x, y, or z"))
        position in ("all", "min", "max") ||
            throw(ArgumentError("GetBoundary position must be all, min, or max"))
        return new(destination, source, combined, oriented, recursive, direction, position)
    end
end
function GetBoundary(
    destination::Symbol,
    source::Symbol;
    combined::Bool=true,
    oriented::Bool=true,
    recursive::Bool=false,
    direction::AbstractString="all",
    position::AbstractString="all"
)
    return GetBoundary(
        destination,
        source,
        combined,
        oriented,
        recursive,
        direction,
        position
    )
end

const _EXTERIOR_BOUNDARY_LAYERS = Dict(
    ("X", "min") => :EXTBND_XMIN,
    ("X", "max") => :EXTBND_XMAX,
    ("Y", "min") => :EXTBND_YMIN,
    ("Y", "max") => :EXTBND_YMAX,
    ("Z", "min") => :EXTBND_ZMIN,
    ("Z", "max") => :EXTBND_ZMAX
)

"""
    exterior_boundaries(bounding_volume_layer::Symbol) -> Vector{GetBoundary}

Return operations extracting all six axis-aligned exterior faces of
`bounding_volume_layer` into `:EXTBND_XMIN`, `:EXTBND_XMAX`, `:EXTBND_YMIN`,
`:EXTBND_YMAX`, `:EXTBND_ZMIN`, and `:EXTBND_ZMAX`.
"""
function exterior_boundaries(bounding_volume_layer::Symbol)
    operations = GetBoundary[]
    for direction in ("X", "Y", "Z"), position in ("min", "max")
        destination = _EXTERIOR_BOUNDARY_LAYERS[(direction, position)]
        push!(
            operations,
            GetBoundary(destination, bounding_volume_layer; direction, position)
        )
    end
    return operations
end

"""
    Translate(source, dx, dy, dz; copy=false)
    Translate(destination, source, dx, dy, dz; copy=destination != source)

Translate `source` by `(dx, dy, dz)`. With `copy=true`, assign an independently addressable
copy to `destination` and preserve the source. With `copy=false`, `destination` must equal
`source` and the geometry is translated in place. By default, distinct destinations copy and
in-place translations move. Duplicate internal output PG names are rejected. The
compiler does not check appended copies for geometric overlap.
"""
struct Translate{X <: Coordinate, Y <: Coordinate, Z <: Coordinate} <: LayerOp
    destination::Symbol
    source::Symbol
    dx::X
    dy::Y
    dz::Z
    copy::Bool
    function Translate{X, Y, Z}(
        destination::Symbol,
        source::Symbol,
        dx::X,
        dy::Y,
        dz::Z,
        copy::Bool
    ) where {X <: Coordinate, Y <: Coordinate, Z <: Coordinate}
        !copy &&
            destination != source &&
            throw(ArgumentError("Translate with copy=false requires destination == source"))
        return new{X, Y, Z}(destination, source, dx, dy, dz, copy)
    end
end
Translate(
    destination::Symbol,
    source::Symbol,
    dx::X,
    dy::Y,
    dz::Z,
    copy::Bool
) where {X <: Coordinate, Y <: Coordinate, Z <: Coordinate} =
    Translate{X, Y, Z}(destination, source, dx, dy, dz, copy)
Translate(
    destination::Symbol,
    source::Symbol,
    dx::Coordinate,
    dy::Coordinate,
    dz::Coordinate;
    copy::Bool=destination != source
) = Translate(destination, source, dx, dy, dz, copy)
Translate(
    source::Symbol,
    dx::Coordinate,
    dy::Coordinate,
    dz::Coordinate;
    copy::Bool=false
) = Translate(source, source, dx, dy, dz, copy)

"""
    Remove(source; remove_entities=true)

Remove a layer from the model, or do nothing if it is absent. Preserve its geometric
entities and remove only its physical groups when `remove_entities=false`.
"""
struct Remove <: LayerOp
    source::Symbol
    remove_entities::Bool
end
Remove(source::Symbol; remove_entities::Bool=true) = Remove(source, remove_entities)

"""
    Revolve(source, origin, axis, angle)
    Revolve(destination, source, origin, axis, angle)

Sweep `source` through `angle` radians around the axis passing through `origin` in the
specified axis direction. The one-layer form operates in place. The destination dimension
is one greater than the source dimension; 3D sources and duplicate internal output PG-name
collisions are rejected. The compiler does not check appended revolutions for geometric
overlap.
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
Revolve(source::Symbol, origin::NTuple{3, <:Real}, axis::NTuple{3, <:Real}, angle::Real) =
    Revolve(source, source, origin, axis, angle)

"""
    SetPeriodic(first, second)

Pair two distinct, parallel, axis-aligned 2D periodic layers containing exactly one physical
group each.
"""
struct SetPeriodic <: LayerOp
    first::Symbol
    second::Symbol
    function SetPeriodic(first::Symbol, second::Symbol)
        first == second &&
            throw(ArgumentError("SetPeriodic requires distinct first and second layers"))
        return new(first, second)
    end
end

# ─── Lowered operations ──────────────────────────────────────────────────────

struct _LoweredIntersect <: BooleanOp
    destination::Symbol
    object::Symbol
    tool::Symbol
    remove_object::Bool
    remove_tool::Bool
end

struct _LoweredCut{N} <: BooleanOp
    destination::Symbol
    object::Symbol
    tools::NTuple{N, Symbol}
    remove_object::Bool
    remove_tool::Bool
end

struct _LoweredFuse{N} <: BooleanOp
    destination::Symbol
    sources::NTuple{N, Symbol}
    remove_sources::Bool
end

struct _LoweredHeal <: LayerOp
    destination::Symbol
    source::Symbol
    remove_source::Bool
end

function initial_registry(metas::Set{<:LayerRef}, stack::SourceStack)
    registry = LayerRegistry()
    for meta in metas
        source_layer = sourcelayer(meta, stack)
        source_layer.solidmodel || continue
        record = PGRecord(string(meta.layer), meta.layer)
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
        throw(ArgumentError("GetInterface destination '$dest_pg' is already defined"))
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

# After fragmentation, compute interface PGs as set intersections of entity memberships.
# Same-dimensional inputs produce shared boundary entities at dimension `dim - 1`;
# mixed-dimensional inputs produce lower-dimensional entities on the higher-dimensional
# boundary.
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

# Reconcile the registry with the rendered model. Drop records whose PG was never realized
# (empty operation results, disjoint interfaces) but keep their layer states, and fail if the
# model holds a PG the registry does not know about. Afterwards, registry records and model
# PGs correspond one to one.
function sync_registry!(sm::SolidModel, registry::LayerRegistry)
    for state in values(registry)
        pgs = SolidModels.dimgroupdict(sm, state.dim)
        filter!(record -> haskey(pgs, record.name), state.pgs)
    end
    registered = Set((r.name, s.dim) for s in values(registry) for r in s.pgs)
    unregistered = [
        (name, dim) for dim = 0:3 for
        name in keys(SolidModels.dimgroupdict(sm, dim)) if (name, dim) ∉ registered
    ]
    isempty(unregistered) || error(
        "solid model contains physical groups absent from the layer registry: " *
        join(["'$name' (dimension $dim)" for (name, dim) in unregistered], ", ")
    )
    return registry
end

# Partition entities of dimension `dim` so that each belongs to exactly one PG, as required
# by Palace (a mesh element may carry only one attribute, and a non-periodic face may not
# carry multiple boundary elements). Entities are grouped by the exact set of PGs containing
# them. An entity in a single PG stays there; each set of entities shared by the same
# combination of PGs is moved into a content-addressed sub-PG that is registered under every
# layer of every PG in that combination. Because 2D selection PGs created by locator
# resolution and metal connected components overlap layer PGs, this pass also isolates
# tagged entities, port surfaces, and connected components.
function deduplicate_pgs!(sm::SolidModel, registry::LayerRegistry, dim::Int)
    pgs = SolidModels.dimgroupdict(sm, dim)

    # A PG may be registered under several layers.
    pg_layers = Dict{String, Set{Symbol}}()
    for (layer_name, state) in registry
        state.dim == dim || continue
        for record in state.pgs
            push!(get!(Set{Symbol}, pg_layers, record.name), layer_name)
        end
    end

    entity_pgs = Dict{Int32, Vector{String}}()
    for (pg_name, pg) in pgs, t in SolidModels.entitytags(pg)
        push!(get!(Vector{String}, entity_pgs, t), pg_name)
    end

    # Sorted PG-name signature → entities shared by exactly those PGs.
    groups = Dict{Vector{String}, Vector{Int32}}()
    for (t, names) in entity_pgs
        length(names) > 1 || continue
        push!(get!(Vector{Int32}, groups, sort!(names)), t)
    end

    moved = Dict{String, Set{Int32}}() # original PG → entities moved to sub-PGs
    for signature in sort!(collect(keys(groups)))
        tags = sort!(groups[signature])
        sub_name = "__" * pghash((dim, t) for t in tags)
        sm[sub_name] = Tuple{Int32, Int32}[(Int32(dim), t) for t in tags]
        for layer_name in sort!(collect(union((pg_layers[name] for name in signature)...)))
            push!(registry[layer_name].pgs, PGRecord(sub_name, layer_name))
        end
        for name in signature
            union!(get!(Set{Int32}, moved, name), tags)
        end
    end

    for (pg_name, tags) in moved
        remaining = filter(t -> !(t in tags), SolidModels.entitytags(pgs[pg_name]))
        if isempty(remaining)
            SolidModels.gmsh.model.removePhysicalGroups([(dim, pgs[pg_name].grouptag)])
            delete!(pgs, pg_name)
            for state in values(registry)
                filter!(record -> record.name != pg_name, state.pgs)
            end
        else
            sm[pg_name] = Tuple{Int32, Int32}[(Int32(dim), t) for t in remaining]
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

function _require_destination_dimension(
    reg::LayerRegistry,
    dest::Symbol,
    dim::Int,
    operation_name::AbstractString
)
    if haskey(reg, dest) && reg[dest].dim != dim
        throw(
            ArgumentError(
                "$operation_name destination layer :$dest has dimension $(reg[dest].dim), " *
                "so dimension $dim physical groups cannot be appended"
            )
        )
    end
    return nothing
end

source_layers(op::Extrude) = (op.destination,)
source_layers(op::Cut) = (op.object, op.tools...)
source_layers(op::Intersect) = (op.object, op.tool)
source_layers(op::Fuse) = op.sources
source_layers(op::Heal) = (op.source,)
source_layers(op::GetInterface) = (op.object, op.tool)
source_layers(op::RestrictTo) = (op.volume,)
source_layers(op::GetBoundary) = (op.source,)
source_layers(op::Translate) = (op.source,)
source_layers(op::Remove) = (op.source,)
source_layers(op::Revolve) = (op.source,)
source_layers(op::SetPeriodic) = (op.first, op.second)

source_layers(op::_LoweredCut) = (op.object, op.tools...)
source_layers(op::_LoweredIntersect) = (op.object, op.tool)
source_layers(op::_LoweredFuse) = op.sources
source_layers(op::_LoweredHeal) = (op.source,)

function _lower_with_removals(op::Intersect, removals::Vector{Remove})
    absorb_object =
        op.object != op.destination &&
        any(r -> r.source == op.object && r.remove_entities, removals)
    absorb_tool =
        op.tool != op.destination &&
        any(r -> r.source == op.tool && r.remove_entities, removals)
    remove_object = op.destination == op.object || absorb_object
    remove_tool = op.destination == op.tool || absorb_tool
    absorbed = Set{Symbol}()
    absorb_object && push!(absorbed, op.object)
    absorb_tool && push!(absorbed, op.tool)
    return _LoweredIntersect(
        op.destination,
        op.object,
        op.tool,
        remove_object,
        remove_tool
    ),
    absorbed
end

function _lower_with_removals(op::Cut, removals::Vector{Remove})
    ambiguous = op.object in op.tools
    remove_object =
        !ambiguous &&
        op.object != op.destination &&
        any(r -> r.source == op.object && r.remove_entities, removals)
    remove_tool =
        !ambiguous &&
        op.destination ∉ op.tools &&
        all(tool -> any(r -> r.source == tool && r.remove_entities, removals), op.tools)
    absorbed = Set{Symbol}()
    remove_object && push!(absorbed, op.object)
    remove_tool && union!(absorbed, op.tools)
    return _LoweredCut(op.destination, op.object, op.tools, remove_object, remove_tool),
    absorbed
end

function _lower_with_removals(op::Fuse, removals::Vector{Remove})
    removable = filter(source -> source != op.destination, op.sources)
    remove_sources = all(
        source -> any(r -> r.source == source && r.remove_entities, removals),
        removable
    )
    absorbed = remove_sources ? Set{Symbol}(removable) : Set{Symbol}()
    return _LoweredFuse(op.destination, op.sources, remove_sources), absorbed
end

function _lower_with_removals(op::Heal, removals::Vector{Remove})
    remove_source =
        op.destination != op.source &&
        any(r -> r.source == op.source && r.remove_entities, removals)
    absorbed = remove_source ? Set{Symbol}((op.source,)) : Set{Symbol}()
    return _LoweredHeal(op.destination, op.source, remove_source), absorbed
end

function _absorb_removals(ops::AbstractVector{<:LayerOp})
    result = LayerOp[]
    i = firstindex(ops)
    while i <= lastindex(ops)
        op = ops[i]
        if !(op isa Union{Cut, Intersect, Fuse, Heal})
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

        lowered, absorbed = _lower_with_removals(op, removals)
        push!(result, lowered)
        for removal in removals
            removal.remove_entities && removal.source in absorbed || push!(result, removal)
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

function _check_deferred_inputs_registered(cmp)
    for operation in interface_vertices(cmp.dints)
        for vertex in operation_pgs(cmp.dints, operation)
            name = MetaGraphs.get_prop(cmp.dints, vertex, :name)
            dim = MetaGraphs.get_prop(cmp.dints, vertex, :dim)
            registered = any(values(cmp.reg)) do state
                return state.dim == dim && any(record -> record.name == name, state.pgs)
            end
            registered || throw(
                ArgumentError(
                    "GetInterface input physical group '$name' at dimension $dim must " *
                    "remain available through deferred execution"
                )
            )
        end
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

# Compile layer operations into physical-group postrender operations, the final layer
# registry, and the deferred-interface graph evaluated after fragmentation.
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
        _check_deferred_inputs_registered(cmp)
    end
    _flush_interior_solids!(cmp, nothing)
    return cmp.ops, cmp.reg, cmp.dints
end

# Return every compiled `(name, dim)` PG so the renderer keeps them all and removes the rest.
function retained_physical_groups(registry::LayerRegistry)
    return Set(
        (record.name, state.dim) for state in values(registry) for record in state.pgs
    )
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
            "Extrude cannot process generated layer :$(op.destination) because it requires " *
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
    # mesh. Registering it under `:EXTBND_MISC` as well keeps the sub-PGs that
    # `deduplicate_pgs!` splits off (exterior-only faces versus faces shared with
    # interior interface PGs) cross-referenced from both layers, avoiding the "mixed
    # boundary attribute" warning that Palace emits for PGs containing both kinds of faces.
    function _register_extbnd!(bnd_pg)
        if !haskey(cmp.reg, :EXTBND_MISC)
            cmp.reg[:EXTBND_MISC] = LayerState(PGRecord[], 2)
        end
        return push!(cmp.reg[:EXTBND_MISC].pgs, PGRecord(bnd_pg, :EXTBND_MISC))
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
                _register_extbnd!(intbnd_pg)
            else
                push!(cmp.ops, ("_rm", SolidModels.remove_group!, (pg, 2)))
            end
            push!(new_records, PGRecord(ext_pg, op.destination))
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
            push!(new_records, PGRecord(bnd_pg, op.destination))
            _register_extbnd!(bnd_pg)
        else
            # Standard extrusion: 2D surface → 3D volume
            ext_pg = pg * "__EXN"
            push!(cmp.ops, (ext_pg, SolidModels.extrude_z!, (pg, dz, 2)))
            push!(cmp.ops, ("_rm", SolidModels.remove_group!, (pg, 2)))
            push!(new_records, PGRecord(ext_pg, op.destination))
        end
    end

    new_dim = source_layer.contour_only ? 2 : (source_layer.keep_interior ? 3 : 2)
    cmp.reg[op.destination] = LayerState(new_records, new_dim)
    return nothing
end

function _compile!(cmp::CompilerState, op::_LoweredCut)
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
            ophash(record.name, tool_pg_names; operation=:cut, parameters=(dim,))
        end
        if mode != :replace_object &&
           generated_record_exists(cmp.reg, op.destination, dest_name, new_records)
            throw(
                ArgumentError("Cut destination physical group '$dest_name' already exists")
            )
        end
        push!(compiled, (record, dest_name))
        mode == :replace_object || push!(new_records, PGRecord(dest_name, op.destination))
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
        _require_destination_dimension(cmp.reg, op.destination, dim, "Cut")
        existing_pgs = [record.name for record in cmp.reg[op.destination].pgs]
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

function _compile!(cmp::CompilerState, op::_LoweredFuse)
    dims = unique([cmp.reg[source].dim for source in op.sources])
    length(dims) == 1 ||
        throw(ArgumentError("Fuse source layers must have equal dimensions"))
    dim = only(dims)
    source_pgs =
        sort!([record.name for source in op.sources for record in cmp.reg[source].pgs])
    isempty(source_pgs) && throw(ArgumentError("Fuse requires at least one physical group"))

    dest_name =
        string(op.destination) *
        "__" *
        ophash(first(source_pgs), source_pgs[2:end]; operation=:fuse, parameters=(dim,))
    generated_record_exists(cmp.reg, op.destination, dest_name) &&
        throw(ArgumentError("Fuse destination physical group '$dest_name' already exists"))

    append_mode = haskey(cmp.reg, op.destination) && op.destination ∉ op.sources
    append_mode && _require_destination_dimension(cmp.reg, op.destination, dim, "Fuse")
    push!(
        cmp.ops,
        (
            dest_name,
            SolidModels.union_geom!,
            (source_pgs, dim),
            :remove_object => op.remove_sources
        )
    )
    new_record = PGRecord(dest_name, op.destination)
    if append_mode
        existing_pgs = [record.name for record in cmp.reg[op.destination].pgs]
        if !isempty(existing_pgs)
            push!(
                cmp.ops,
                (
                    dest_name,
                    SolidModels.difference_geom!,
                    (dest_name, existing_pgs, dim, dim),
                    :remove_object => true,
                    :remove_tool => false
                )
            )
        end
        push!(cmp.reg[op.destination].pgs, new_record)
    else
        cmp.reg[op.destination] = LayerState([new_record], dim)
    end
    if op.remove_sources
        for source in op.sources
            source != op.destination && delete!(cmp.reg, source)
        end
    end
    return nothing
end

function _replace_layer_prefix(name::String, source::Symbol, destination::Symbol)
    prefix = string(source, "__")
    startswith(name, prefix) || throw(
        ArgumentError(
            "Heal source physical-group name '$name' does not begin with layer prefix '$prefix'"
        )
    )
    return string(destination, "__", chop(name; head=length(prefix), tail=0))
end

function _compile!(cmp::CompilerState, op::_LoweredHeal)
    state = cmp.reg[op.source]
    if op.destination == op.source
        for record in state.pgs
            push!(
                cmp.ops,
                (
                    record.name,
                    SolidModels.union_geom!,
                    (record.name, state.dim),
                    :remove_object => true
                )
            )
        end
        return nothing
    end

    haskey(cmp.reg, op.destination) &&
        _require_destination_dimension(cmp.reg, op.destination, state.dim, "Heal")
    new_records = [
        PGRecord(
            _replace_layer_prefix(record.name, op.source, op.destination),
            op.destination
        ) for record in state.pgs
    ]
    existing_names =
        haskey(cmp.reg, op.destination) ?
        Set(record.name for record in cmp.reg[op.destination].pgs) : Set{String}()
    collision = findfirst(record -> record.name in existing_names, new_records)
    isnothing(collision) || throw(
        ArgumentError(
            "Heal destination physical-group name '$(new_records[collision].name)' already exists"
        )
    )

    for (record, new_record) in zip(state.pgs, new_records)
        push!(
            cmp.ops,
            (
                new_record.name,
                SolidModels.union_geom!,
                (record.name, state.dim),
                :remove_object => op.remove_source
            )
        )
    end
    if haskey(cmp.reg, op.destination)
        existing_pgs = [record.name for record in cmp.reg[op.destination].pgs]
        if !isempty(existing_pgs)
            for record in new_records
                # Ensure added PGs don't have any overlap with existing PGs in the
                # destination layer
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
    op.remove_source && delete!(cmp.reg, op.source)
    return nothing
end

function _compile!(cmp::CompilerState, op::_LoweredIntersect)
    object_state = cmp.reg[op.object]
    tool_state = cmp.reg[op.tool]
    isempty(object_state.pgs) &&
        throw(ArgumentError("Intersect object layer must contain a physical group"))
    isempty(tool_state.pgs) &&
        throw(ArgumentError("Intersect tool layer must contain a physical group"))

    destination_dim = min(object_state.dim, tool_state.dim)
    append_mode =
        haskey(cmp.reg, op.destination) &&
        op.destination != op.object &&
        op.destination != op.tool
    append_mode && _require_destination_dimension(
        cmp.reg,
        op.destination,
        destination_dim,
        "Intersect"
    )
    existing_pgs =
        append_mode ? [record.name for record in cmp.reg[op.destination].pgs] : String[]

    new_records = PGRecord[]
    for (obj_idx, obj_rec) in enumerate(object_state.pgs)
        for (tool_idx, tool_rec) in enumerate(tool_state.pgs)
            dest_name =
                string(op.destination) *
                "__" *
                ophash(
                    obj_rec.name,
                    [tool_rec.name];
                    operation=:intersect,
                    parameters=(object_state.dim, tool_state.dim)
                )
            remove_object = op.remove_object && tool_idx == length(tool_state.pgs)
            remove_tool = op.remove_tool && obj_idx == length(object_state.pgs)
            generated_record_exists(cmp.reg, op.destination, dest_name, new_records) &&
                throw(
                    ArgumentError(
                        "Intersect destination physical group '$dest_name' already exists in layer " *
                        ":$(op.destination)"
                    )
                )
            push!(
                cmp.ops,
                (
                    dest_name,
                    SolidModels.intersect_geom!,
                    (obj_rec.name, tool_rec.name, object_state.dim, tool_state.dim),
                    :remove_object => remove_object,
                    :remove_tool => remove_tool
                )
            )
            if append_mode && !isempty(existing_pgs)
                push!(
                    cmp.ops,
                    (
                        dest_name,
                        SolidModels.difference_geom!,
                        (dest_name, existing_pgs, destination_dim, destination_dim),
                        :remove_object => true,
                        :remove_tool => false
                    )
                )
            end
            push!(new_records, PGRecord(dest_name, op.destination))
        end
    end

    if append_mode
        append!(cmp.reg[op.destination].pgs, new_records)
    else
        cmp.reg[op.destination] = LayerState(new_records, destination_dim)
    end
    op.remove_object && op.object != op.destination && delete!(cmp.reg, op.object)
    op.remove_tool && op.tool != op.destination && delete!(cmp.reg, op.tool)
    return nothing
end

function _compile!(cmp::CompilerState, op::GetInterface)
    obj_state = cmp.reg[op.object]
    tool_state = cmp.reg[op.tool]
    obj_dim = obj_state.dim
    tool_dim = tool_state.dim

    new_records = PGRecord[]
    for obj_rec in obj_state.pgs
        for tool_rec in tool_state.pgs
            dest_name =
                string(op.destination) *
                "__" *
                ophash(
                    obj_rec.name,
                    [tool_rec.name];
                    operation=:get_interface,
                    parameters=(obj_dim, tool_dim)
                )
            generated_record_exists(cmp.reg, op.destination, dest_name, new_records) &&
                throw(
                    ArgumentError(
                        "GetInterface destination physical group '$dest_name' already exists"
                    )
                )
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
            push!(new_records, PGRecord(dest_name, op.destination))
        end
    end

    # Result dimension: mixed-dim entites produce entities at min(d1, d2).
    # Same-dim entities (e.g. 3D∩3D) produce shared boundaries at dim-1.
    new_dim = obj_dim == tool_dim ? obj_dim - 1 : min(obj_dim, tool_dim)

    if haskey(cmp.reg, op.destination) &&
       op.destination != op.object &&
       op.destination != op.tool
        _require_destination_dimension(cmp.reg, op.destination, new_dim, "GetInterface")
        append!(cmp.reg[op.destination].pgs, new_records)
    else
        cmp.reg[op.destination] = LayerState(new_records, new_dim)
    end

    return nothing
end

function _compile!(cmp::CompilerState, op::RestrictTo)
    state = cmp.reg[op.volume]
    state.dim == 3 ||
        throw(ArgumentError("RestrictTo bounding volume layer :$(op.volume) must be 3D"))
    bv_pgs = state.pgs
    length(bv_pgs) == 1 || throw(
        ArgumentError(
            "RestrictTo bounding volume layer :$(op.volume) must contain exactly one physical group"
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
    hash_parameters,
    operation_name::AbstractString
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
        dest_name =
            string(destination) *
            "__" *
            ophash(
                record.name,
                String[];
                operation=hash_operation,
                parameters=hash_parameters
            )
        generated_record_exists(cmp.reg, destination, dest_name, new_records) && throw(
            ArgumentError(
                "$operation_name destination physical group '$dest_name' already exists"
            )
        )
        push!(cmp.ops, lower(dest_name, record))
        push!(new_records, PGRecord(dest_name, destination))
    end

    if haskey(cmp.reg, destination)
        _require_destination_dimension(
            cmp.reg,
            destination,
            destination_dim,
            operation_name
        )
        append!(cmp.reg[destination].pgs, new_records)
    else
        cmp.reg[destination] = LayerState(new_records, destination_dim)
    end
    return nothing
end

function _compile!(cmp::CompilerState, op::GetBoundary)
    op.destination != op.source &&
        haskey(cmp.reg, op.destination) &&
        throw(
            ArgumentError(
                "GetBoundary destination layer :$(op.destination) already exists"
            )
        )
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
        replace=(op.destination == op.source),
        hash_operation=:get_boundary,
        hash_parameters=(
            dim,
            op.combined,
            op.oriented,
            op.recursive,
            op.direction,
            op.position
        ),
        operation_name="GetBoundary"
    ) do destination, record
        return (destination, SolidModels.get_boundary, (record.name, dim), kwargs...)
    end
end

function _compile!(cmp::CompilerState, op::Translate)
    dim = cmp.reg[op.source].dim
    _compile_unary_layer_op!(
        cmp,
        op.destination,
        op.source,
        dim;
        replace=op.destination == op.source && !op.copy,
        hash_operation=:translate,
        hash_parameters=(op.dx, op.dy, op.dz),
        operation_name="Translate"
    ) do destination, record
        return (
            destination,
            SolidModels.translate!,
            (record.name, op.dx, op.dy, op.dz),
            :copy => op.copy
        )
    end
    return nothing
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
    dim < 3 || throw(ArgumentError("Revolve cannot process a 3D layer"))
    return _compile_unary_layer_op!(
        cmp,
        op.destination,
        op.source,
        dim + 1;
        replace=(op.destination == op.source),
        hash_operation=:revolve,
        hash_parameters=(dim, op.origin, op.axis, op.angle),
        operation_name="Revolve"
    ) do destination, record
        return (
            destination,
            SolidModels.revolve!,
            (record.name, dim, op.origin..., op.axis..., op.angle)
        )
    end
end

function _compile!(cmp::CompilerState, op::SetPeriodic)
    first_state = cmp.reg[op.first]
    second_state = cmp.reg[op.second]
    first_state.dim == 2 && second_state.dim == 2 ||
        throw(ArgumentError("SetPeriodic layers must both be 2D"))
    length(first_state.pgs) == 1 && length(second_state.pgs) == 1 || throw(
        ArgumentError("SetPeriodic layers must each contain exactly one physical group")
    )

    first_pg = only(first_state.pgs).name
    second_pg = only(second_state.pgs).name
    push!(
        cmp.ops,
        ("Periodic_$first_pg", SolidModels.set_periodic!, (first_pg, second_pg, 2, 2))
    )
    return nothing
end
