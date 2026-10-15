# Physical groups of a layer, their dimension, and the extrusion distance in STP units once
# extruded. Until rendering, every layer holds exactly one PG, named after the layer; the
# post-render passes (locator selection, deduplication) add further PGs.
mutable struct LayerState
    pgs::Vector{String}
    dim::Int
    dz::Union{Nothing, Float64}
end
LayerState(pgs::Vector{String}, dim::Int) = LayerState(pgs, dim, nothing)

const LayerRegistry = Dict{Symbol, LayerState}

# Internal supertypes for typed layer-level operations.
abstract type LayerOp end
abstract type BooleanOp <: LayerOp end

"""
    Extrude(source)
    Extrude(source, dz)
    Extrude(source; to_level, offset=nothing)
    Extrude(destination, source[, dz]; to_level, offset)

Extrude a 1D or 2D layer along z. The one-argument forms build a source-stack layer to its
declared thickness or level span. An explicit distance `dz`, or a target level `to_level`
displaced by `offset`, is required for generated layers and must agree with the
declaration for source-stack layers. The one-layer forms operate in place; a distinct
destination receives a copy. 3D sources are rejected.
"""
struct Extrude <: LayerOp
    destination::Symbol
    source::Symbol
    dz::Union{Nothing, Coordinate}
    to_level::Union{Nothing, Int}
    offset::Union{Nothing, Coordinate}
    function Extrude(
        destination::Symbol,
        source::Symbol,
        dz::Union{Nothing, Coordinate},
        to_level::Union{Nothing, Int},
        offset::Union{Nothing, Coordinate}
    )
        !isnothing(dz) &&
            !isnothing(to_level) &&
            throw(ArgumentError("Extrude accepts either dz or to_level, not both"))
        isnothing(to_level) &&
            !isnothing(offset) &&
            throw(ArgumentError("Extrude offset requires to_level"))
        return new(destination, source, dz, to_level, offset)
    end
end
Extrude(destination::Symbol, source::Symbol; to_level=nothing, offset=nothing) =
    Extrude(destination, source, nothing, to_level, offset)
Extrude(destination::Symbol, source::Symbol, dz::Coordinate) =
    Extrude(destination, source, dz, nothing, nothing)
Extrude(source::Symbol; kwargs...) = Extrude(source, source; kwargs...)
Extrude(source::Symbol, dz::Coordinate) = Extrude(source, source, dz)

"""
    Cut(destination, object, tools)

Subtract one tool layer, or a grouped tuple or vector of tool layers, from `object`. The
destination must be new or one of the inputs. Non-destination inputs remain available unless
consumed by adjacent [`Remove`](@ref) operations.
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
vector; the one-layer form heals a layer in place, merging its own overlapping or coincident
geometry. The destination must be new or one of the sources. Out-of-place sources remain
available unless consumed by adjacent [`Remove`](@ref) operations.
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
    Intersect(destination, object, tool)

Compute the intersection of `object` and `tool`. The destination dimension is the lower
input dimension. The destination must be new or one of the inputs; in-place operation
consumes the replaced OCC input, and other inputs remain available unless consumed by
adjacent [`Remove`](@ref) operations. Object and tool layers must be distinct.
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
input dimension. The destination must be new, and every input PG must remain available
through deferred interface execution.
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

Restrict the model to a 3D bounding-volume layer.
"""
struct RestrictTo <: LayerOp
    volume::Symbol
end

"""
    GetBoundary(destination, source; combined=true, oriented=true, recursive=false,
             direction="all", position="all")

Extract the boundary of `source` into `destination`. Use `direction` and `position` to
select axis-aligned boundary entities. The destination must be new or equal to `source`.
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
    Translate(source, dx, dy, dz)
    Translate(destination, source, dx, dy, dz)

Translate `source` by `(dx, dy, dz)`. The one-layer form moves the layer in place; a distinct
destination receives a translated copy and the source is preserved.
"""
struct Translate{X <: Coordinate, Y <: Coordinate, Z <: Coordinate} <: LayerOp
    destination::Symbol
    source::Symbol
    dx::X
    dy::Y
    dz::Z
end
Translate(source::Symbol, dx::Coordinate, dy::Coordinate, dz::Coordinate) =
    Translate(source, source, dx, dy, dz)

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
is one greater than the source dimension; 3D sources are rejected.
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
    Hollow(layer)

Replace a 3D layer by its boundary shell and remove the enclosed volume from the model after
fragmentation, so the interior is absent from the final mesh regardless of operation order
and of which other volumes it overlaps.
"""
struct Hollow <: LayerOp
    layer::Symbol
end

# Internal registry layer holding hollowed solids until `hollow!` removes them.
const _HOLLOWED = :__hollowed

"""
    SetPeriodic(first, second)

Pair two distinct, parallel, axis-aligned 2D periodic layers.
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

function initial_registry(metas::Set{<:LayerRef}, stack::SourceStack)
    registry = LayerRegistry()
    for meta in metas
        sourcelayer(meta, stack).solidmodel || continue
        registry[meta.layer] = LayerState([string(meta.layer)], 2)
    end
    return registry
end

# An interface between two layers, computed after fragmentation from the entity memberships
# of their PGs. Layers hold one PG named after them at compile time, so layer names identify
# the PGs; the dimensions are recorded so later operations cannot silently replace an input.
struct DeferredInterface
    destination::Symbol
    object::Symbol
    tool::Symbol
    obj_dim::Int
    tool_dim::Int
end

# After fragmentation, compute interface PGs as set intersections of entity memberships, in
# order, so an interface may consume an earlier one. Same-dimensional inputs share boundary
# entities at dimension `dim - 1`; mixed-dimensional inputs share lower-dimensional entities
# on the higher-dimensional boundary. Interfaces with an unrealized input or an empty result
# create no PG.
function realize_interfaces!(sm::SolidModel, interfaces::Vector{DeferredInterface})
    entities = Dict{Tuple{Symbol, Int}, Set{Int32}}()
    boundaries = Dict{Tuple{Symbol, Int}, Dict{Int, Set{Int32}}}()
    function _entities(layer, dim)
        return get!(entities, (layer, dim)) do
            SolidModels.hasgroup(sm, string(layer), dim) || return Set{Int32}()
            return Set(SolidModels.entitytags(sm[string(layer), dim]))
        end
    end
    function _boundary(layer, dim, boundary_dim)
        by_dim = get!(boundaries, (layer, dim)) do
            dimtags = [(Int32(dim), t) for t in _entities(layer, dim)]
            result = Dict{Int, Set{Int32}}()
            for (d, t) in SolidModels.gmsh.model.getBoundary(dimtags, false, false, false)
                push!(get!(Set{Int32}, result, Int(d)), Int32(abs(t)))
            end
            return result
        end
        return get(by_dim, boundary_dim, Set{Int32}())
    end

    for di in interfaces
        if di.obj_dim == di.tool_dim
            dim = di.obj_dim - 1
            tags = intersect(
                _boundary(di.object, di.obj_dim, dim),
                _boundary(di.tool, di.tool_dim, dim)
            )
        else
            (lo, lo_dim), (hi, hi_dim) =
                sort([(di.object, di.obj_dim), (di.tool, di.tool_dim)]; by=last)
            dim = lo_dim
            tags = intersect(_entities(lo, lo_dim), _boundary(hi, hi_dim, lo_dim))
        end
        isempty(tags) && continue
        sm[string(di.destination)] = Tuple{Int32, Int32}[(Int32(dim), t) for t in tags]
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
        filter!(name -> haskey(pgs, name), state.pgs)
    end
    registered = Set((name, s.dim) for s in values(registry) for name in s.pgs)
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
        for name in state.pgs
            push!(get!(Set{Symbol}, pg_layers, name), layer_name)
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
            push!(registry[layer_name].pgs, sub_name)
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
                filter!(name -> name != pg_name, state.pgs)
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

source_layers(op::Extrude) = (op.source,)
source_layers(op::Hollow) = (op.layer,)
source_layers(op::Cut) = (op.object, op.tools...)
source_layers(op::Intersect) = (op.object, op.tool)
source_layers(op::Fuse) = op.sources
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

function _absorb_removals(ops::AbstractVector{<:LayerOp})
    result = LayerOp[]
    i = firstindex(ops)
    while i <= lastindex(ops)
        op = ops[i]
        if !(op isa Union{Cut, Intersect, Fuse})
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
    for di in cmp.dints, (layer, dim) in ((di.object, di.obj_dim), (di.tool, di.tool_dim))
        haskey(cmp.reg, layer) && cmp.reg[layer].dim == dim || throw(
            ArgumentError(
                "GetInterface input layer :$layer at dimension $dim must remain " *
                "available through deferred execution"
            )
        )
    end
    return nothing
end

struct _CompilerState{S <: SourceStack}
    ops::Vector{Tuple}                       # Compiled physical-group operations
    reg::LayerRegistry                       # Evolving layer-to-PG registry
    dints::Vector{DeferredInterface}         # Interfaces computed after fragmentation
    stack::S                                 # Source-layer geometry configuration
end

# Compile layer operations into physical-group postrender operations, the final layer
# registry, and the deferred-interface graph evaluated after fragmentation.
function compile_ops(
    ops::AbstractVector{<:LayerOp},
    stack::SourceStack,
    registry::LayerRegistry
)
    cmp = _CompilerState(Tuple[], deepcopy(registry), DeferredInterface[], stack)
    for op in _absorb_removals(ops)
        _validate_source_layers(op, cmp.reg)
        _compile!(cmp, op)
        _check_deferred_inputs_registered(cmp)
    end
    return cmp.ops, cmp.reg, cmp.dints
end

# Every source-stack layer still in the compiled registry with a declared thickness must have
# been built by an `Extrude`, so the stack and the model never disagree.
function check_declared_thicknesses(registry::LayerRegistry, stack::SourceStack)
    for (layer_name, state) in registry
        source_layer = get(stack.layers, layer_name, nothing)
        isnothing(source_layer) && continue
        iszero(thickness(source_layer, stack)) && continue
        isnothing(state.dz) && throw(
            ArgumentError(
                "source layer :$layer_name declares a thickness but is never extruded"
            )
        )
    end
    return nothing
end

# Return every compiled `(name, dim)` PG so the renderer keeps them all and removes the rest.
function retained_physical_groups(registry::LayerRegistry)
    return Set((name, state.dim) for state in values(registry) for name in state.pgs)
end

# Compile-time layers hold exactly one PG, named after the layer.
_pg(cmp::_CompilerState, layer::Symbol) = only(cmp.reg[layer].pgs)

# Register the layer produced by an operation. A destination must be new or one of the
# operation's own inputs, in which case the caller updates the existing state instead.
function _create!(cmp::_CompilerState, destination::Symbol, dim::Int)
    haskey(cmp.reg, destination) &&
        throw(ArgumentError("destination layer :$destination already exists"))
    return cmp.reg[destination] = LayerState([string(destination)], dim)
end

# Resolve the extrusion distance of an `Extrude`. Source-stack layers must agree with their
# declaration; generated layers need an explicit `dz`, or a `to_level` resolved against the
# source geometry's z when the operation executes.
function _extrusion_distance(cmp::_CompilerState, op::Extrude)
    source_layer = get(cmp.stack.layers, op.source, nothing)
    target_z = if isnothing(op.to_level)
        nothing
    else
        haskey(cmp.stack.levels, op.to_level) || throw(
            ArgumentError("Extrude references missing assembly level $(op.to_level)")
        )
        level_z = cmp.stack.levels[op.to_level]
        level_z + (isnothing(op.offset) ? zero(level_z) : op.offset)
    end

    if isnothing(source_layer)
        isnothing(op.dz) &&
            isnothing(target_z) &&
            throw(
                ArgumentError(
                    "Extrude of generated layer :$(op.source) requires dz or to_level"
                )
            )
        return isnothing(op.dz) ? (:to_z, _stp_float(target_z)) : op.dz
    end

    declared = thickness(source_layer, cmp.stack)
    iszero(declared) &&
        throw(ArgumentError("source layer :$(op.source) declares no thickness to extrude"))
    requested = if !isnothing(op.dz)
        op.dz
    elseif !isnothing(target_z)
        target_z - layer_z(source_layer, cmp.stack)
    else
        declared
    end
    requested == declared || throw(
        ArgumentError(
            "Extrude of :$(op.source) by $requested disagrees with its declared " *
            "thickness $declared"
        )
    )
    return declared
end

# Extrude a physical group so that its planar source geometry reaches `z` (STP units), and
# record the resolved distance on the destination layer's state.
function _extrude_to_z!(
    sm::SolidModel,
    pg_name::String,
    z::Float64,
    dim::Int,
    destination::LayerState
)
    SolidModels.hasgroup(sm, pg_name, dim) || return Tuple{Int32, Int32}[]
    dimtags = SolidModels.dimtags(sm[pg_name, dim])
    points = SolidModels.gmsh.model.getBoundary(dimtags, false, false, true)
    zs = [SolidModels.gmsh.model.getValue(0, abs(tag), Float64[])[3] for (_, tag) in points]
    zmin, zmax = extrema(zs)
    abs(zmax - zmin) < _stp_float(1nm) || error(
        "Extrude to_level requires planar source geometry; '$pg_name' spans z ∈ [$zmin, $zmax]"
    )
    destination.dz = z - zmin
    return SolidModels.extrude_z!(sm, pg_name, (z - zmin) * STP_UNIT, dim)
end

function _compile!(cmp::_CompilerState, op::Extrude)
    dim = cmp.reg[op.source].dim
    dim < 3 || throw(ArgumentError("Extrude cannot process a 3D layer"))
    dz = _extrusion_distance(cmp, op)
    source_pg = _pg(cmp, op.source)
    replace = op.destination == op.source
    state = replace ? cmp.reg[op.source] : _create!(cmp, op.destination, dim + 1)
    if dz isa Tuple
        # The distance is only known once the source geometry exists; the operation records
        # it on the state when it executes.
        push!(
            cmp.ops,
            (string(op.destination), _extrude_to_z!, (source_pg, last(dz), dim, state))
        )
    else
        push!(
            cmp.ops,
            (string(op.destination), SolidModels.extrude_z!, (source_pg, dz, dim))
        )
        state.dz = _stp_float(dz)
    end
    if replace
        # The source geometry is consumed by the extrusion.
        push!(cmp.ops, ("_rm", SolidModels.remove_group!, (source_pg, dim)))
        state.dim = dim + 1
    end
    return nothing
end

function _compile!(cmp::_CompilerState, op::Hollow)
    state = cmp.reg[op.layer]
    state.dim == 3 || throw(ArgumentError("Hollow requires a 3D layer"))
    solid_pg = _pg(cmp, op.layer)
    # The shell takes the layer's name at dimension 2; the solid is parked for `hollow!`.
    push!(cmp.ops, (solid_pg, SolidModels.get_boundary, (solid_pg, 3), :oriented => false))
    push!(get!(() -> LayerState(String[], 3), cmp.reg, _HOLLOWED).pgs, solid_pg)
    state.dim = 2
    return nothing
end

# Remove the volumes of hollowed layers from the fragmented model, leaving their shells.
# Faces that bounded only removed volumes are removed as well. Must run before interfaces are
# realized so that volume boundaries no longer include faces toward voided interiors.
function hollow!(sm::SolidModel, registry::LayerRegistry)
    haskey(registry, _HOLLOWED) || return nothing
    faces = Set{Int32}()
    for name in registry[_HOLLOWED].pgs
        SolidModels.hasgroup(sm, name, 3) || continue
        for tag in SolidModels.entitytags(sm[name, 3])
            union!(faces, last(SolidModels.gmsh.model.getAdjacencies(3, tag)))
        end
        SolidModels.remove_group!(sm[name, 3]; recursive=false, remove_entities=true)
    end
    SolidModels._synchronize!(sm)
    dangling = Tuple{Int32, Int32}[
        (Int32(2), tag) for
        tag in faces if isempty(first(SolidModels.gmsh.model.getAdjacencies(2, tag)))
    ]
    if !isempty(dangling)
        SolidModels.gmsh.model.occ.remove(dangling, false)
        SolidModels._synchronize!(sm)
    end
    delete!(registry, _HOLLOWED)
    return nothing
end

function _compile!(cmp::_CompilerState, op::_LoweredCut)
    dim = cmp.reg[op.object].dim
    object_pg = _pg(cmp, op.object)
    tool_pgs = [_pg(cmp, tool) for tool in op.tools]
    op.destination in (op.object, op.tools...) || _create!(cmp, op.destination, dim)
    push!(
        cmp.ops,
        (
            string(op.destination),
            SolidModels.difference_geom!,
            (object_pg, tool_pgs, dim, dim),
            :remove_object => op.remove_object,
            :remove_tool => op.remove_tool
        )
    )
    if op.remove_tool
        for tool in op.tools
            tool != op.destination && delete!(cmp.reg, tool)
        end
    end
    op.remove_object && op.destination != op.object && delete!(cmp.reg, op.object)
    return nothing
end

function _compile!(cmp::_CompilerState, op::_LoweredFuse)
    dims = unique([cmp.reg[source].dim for source in op.sources])
    length(dims) == 1 ||
        throw(ArgumentError("Fuse source layers must have equal dimensions"))
    dim = only(dims)
    source_pgs = [_pg(cmp, source) for source in op.sources]
    op.destination in op.sources || _create!(cmp, op.destination, dim)
    push!(
        cmp.ops,
        (
            string(op.destination),
            SolidModels.union_geom!,
            (source_pgs, dim),
            :remove_object => op.remove_sources
        )
    )
    if op.remove_sources
        for source in op.sources
            source != op.destination && delete!(cmp.reg, source)
        end
    end
    return nothing
end

function _compile!(cmp::_CompilerState, op::_LoweredIntersect)
    obj_dim = cmp.reg[op.object].dim
    tool_dim = cmp.reg[op.tool].dim
    push!(
        cmp.ops,
        (
            string(op.destination),
            SolidModels.intersect_geom!,
            (_pg(cmp, op.object), _pg(cmp, op.tool), obj_dim, tool_dim),
            :remove_object => op.remove_object,
            :remove_tool => op.remove_tool
        )
    )
    if op.destination in (op.object, op.tool)
        cmp.reg[op.destination].dim = min(obj_dim, tool_dim)
    else
        _create!(cmp, op.destination, min(obj_dim, tool_dim))
    end
    op.remove_object && op.object != op.destination && delete!(cmp.reg, op.object)
    op.remove_tool && op.tool != op.destination && delete!(cmp.reg, op.tool)
    return nothing
end

function _compile!(cmp::_CompilerState, op::GetInterface)
    obj_dim = cmp.reg[op.object].dim
    tool_dim = cmp.reg[op.tool].dim
    # Same-dimensional inputs share boundary entities one dimension lower; mixed-dimensional
    # inputs share lower-dimensional entities on the higher-dimensional boundary. Computed
    # after fragmentation.
    dim = obj_dim == tool_dim ? obj_dim - 1 : min(obj_dim, tool_dim)
    _create!(cmp, op.destination, dim)
    push!(
        cmp.dints,
        DeferredInterface(op.destination, op.object, op.tool, obj_dim, tool_dim)
    )
    return nothing
end

function _compile!(cmp::_CompilerState, op::RestrictTo)
    cmp.reg[op.volume].dim == 3 ||
        throw(ArgumentError("RestrictTo bounding volume layer :$(op.volume) must be 3D"))
    push!(cmp.ops, ("restrict", SolidModels.restrict_to_volume!, (_pg(cmp, op.volume),)))
    return nothing
end

function _compile!(cmp::_CompilerState, op::GetBoundary)
    dim = cmp.reg[op.source].dim
    source_pg = _pg(cmp, op.source)
    replace = op.destination == op.source
    state = replace ? cmp.reg[op.source] : _create!(cmp, op.destination, dim)
    state.dim = max(dim - 1, 0)
    push!(
        cmp.ops,
        (
            string(op.destination),
            SolidModels.get_boundary,
            (source_pg, dim),
            :combined => op.combined,
            :oriented => op.oriented,
            :recursive => op.recursive,
            :direction => op.direction,
            :position => op.position
        )
    )
    return nothing
end

function _compile!(cmp::_CompilerState, op::Translate)
    dim = cmp.reg[op.source].dim
    source_pg = _pg(cmp, op.source)
    copy = op.destination != op.source
    copy && _create!(cmp, op.destination, dim)
    push!(
        cmp.ops,
        (
            string(op.destination),
            SolidModels.translate!,
            (source_pg, op.dx, op.dy, op.dz),
            :copy => copy
        )
    )
    return nothing
end

function _compile!(cmp::_CompilerState, op::Remove)
    haskey(cmp.reg, op.source) || return nothing
    push!(
        cmp.ops,
        (
            "_rm",
            SolidModels.remove_group!,
            (_pg(cmp, op.source), cmp.reg[op.source].dim),
            :remove_entities => op.remove_entities
        )
    )
    delete!(cmp.reg, op.source)
    return nothing
end

function _compile!(cmp::_CompilerState, op::Revolve)
    dim = cmp.reg[op.source].dim
    dim < 3 || throw(ArgumentError("Revolve cannot process a 3D layer"))
    source_pg = _pg(cmp, op.source)
    replace = op.destination == op.source
    state = replace ? cmp.reg[op.source] : _create!(cmp, op.destination, dim)
    state.dim = dim + 1
    push!(
        cmp.ops,
        (
            string(op.destination),
            SolidModels.revolve!,
            (source_pg, dim, op.origin..., op.axis..., op.angle)
        )
    )
    return nothing
end

function _compile!(cmp::_CompilerState, op::SetPeriodic)
    cmp.reg[op.first].dim == 2 && cmp.reg[op.second].dim == 2 ||
        throw(ArgumentError("SetPeriodic layers must both be 2D"))
    first_pg = _pg(cmp, op.first)
    second_pg = _pg(cmp, op.second)
    push!(
        cmp.ops,
        ("Periodic_$first_pg", SolidModels.set_periodic!, (first_pg, second_pg, 2, 2))
    )
    return nothing
end
