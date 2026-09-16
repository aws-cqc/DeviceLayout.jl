module SolidModelsExperimental

using SHA
using Graphs
using Logging
using MetaGraphs
using SpatialIndexing
using Unitful
using DeviceLayout
using DeviceLayout: Coordinate, GDSMeta, nm, μm, ustrip, element_metadata, elements
using DeviceLayout.SchematicDrivenLayout:
    Schematic, check_render_strict, close_logfile, reopen_logfile
using ..SolidModels
using ..SolidModels: SolidModel, _stp_float

import DeviceLayout: layer, render!, place!

include("experimental/metadata.jl")
include("experimental/stack.jl")
include("experimental/artwork.jl")
include("experimental/compiler.jl")
include("experimental/locators.jl")
include("experimental/serialization.jl")
using DeviceLayout.SchematicDrivenLayout
using Logging: with_logger

# Partition entities of dimension `dim` so that each belongs to exactly one PG, as required
# by Palace (a mesh element may carry only one attribute, and a non-periodic face may not
# carry multiple boundary elements). Entities are grouped by the exact set of PGs containing
# them. An entity in a single PG stays there; each set of entities shared by the same
# combination of PGs is moved into a content-addressed sub-PG that is registered under every
# layer of every PG in that combination. Because 2D selection PGs created by locator
# resolution and metal connected components overlap layer PGs, this pass also isolates
# tagged entities, port surfaces, and connected components.
function _deduplicate_pgs!(sm::SolidModel, registry::LayerRegistry, dim::Int)
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

# Remove compiler records that not point to a real physical group in the model. Keep empty
# layer states so their known dimensions remain available to downstream metadata handling.
function _prune_unrealized_pgs!(sm::SolidModel, registry::LayerRegistry)
    for state in values(registry)
        pgs = SolidModels.dimgroupdict(sm, state.dim)
        filter!(record -> haskey(pgs, record.name), state.pgs)
    end
    return registry
end

function _check_pgs_registered(sm::SolidModel, registry::LayerRegistry)
    registered =
        Set((record.name, state.dim) for state in values(registry) for record in state.pgs)
    unregistered = Tuple{String, Int}[]
    for dim = 0:3, name in keys(SolidModels.dimgroupdict(sm, dim))
        (name, dim) in registered || push!(unregistered, (name, dim))
    end
    isempty(unregistered) || error(
        "solid model contains physical groups absent from the layer registry: " *
        join(["'$name' (dimension $dim)" for (name, dim) in unregistered], ", ")
    )
    return nothing
end

"""
    SolidModelTarget(stack)
    SolidModelTarget(stack, operations)

Opt-in schematic target for the simulation-agnostic solid-model pipeline. Store the
[`SourceStack`](@ref) and ordered layer operations used by schematic [`render!`](@ref).
"""
struct SolidModelTarget{L <: SourceLayer, T <: Coordinate} <: SchematicDrivenLayout.Target
    stack::SourceStack{L, T}
    ops::Vector{LayerOp}
end

SolidModelTarget(stack::SourceStack{L, T}) where {L, T} =
    SolidModelTarget{L, T}(stack, LayerOp[])
SolidModelTarget(stack::SourceStack{L, T}, ops::AbstractVector{<:LayerOp}) where {L, T} =
    SolidModelTarget{L, T}(stack, LayerOp[ops...])

function _map_meta(target::SolidModelTarget)
    return meta -> begin
        meta isa LayerRef || return nothing
        source_layer = sourcelayer(meta, target.stack)
        source_layer.solidmodel || return nothing
        return string(meta.layer)
    end
end

function _retained_physical_groups(reg::LayerRegistry)
    retained = Set{Tuple{String, Int}}()
    for state in values(reg)
        for record in state.pgs
            push!(retained, (record.name, state.dim))
        end
    end
    return retained
end

_prefixed(lr::LayerRef, ::String) = lr
_prefixed(lm::Ground, ::String) = lm
_prefixed(lm::Terminal, p::String) = Terminal(lm.layer, p * "." * lm.name)
_prefixed(lm::Tag, p::String) = Tag(lm.layer, p * "." * lm.name)
_prefixed(lm::P, p::String) where {P <: Port} = P(lm.layer, p * "." * lm.name, lm.index)
_prefixed(m::DeviceLayout.Meta, ::String) = m

# Create placement-specific metadata copies under each graph node. Apply a node prefix
# recursively within its component geometry, while child graph nodes receive their own
# stable prefix. This implements the v1 top-level prefix contract.
function _prefix_placement_names!(sch::Schematic)
    ref_to_node_id = IdDict{Any, String}(ref => node.id for (node, ref) in sch.ref_dict)
    for (node, node_ref) in sch.ref_dict
        node_cs = structure(node_ref)
        metadata = element_metadata(node_cs)
        for i in eachindex(metadata)
            metadata[i] = _prefixed(metadata[i], node.id)
        end
        for (i, ref) in pairs(refs(node_cs))
            haskey(ref_to_node_id, ref) && continue
            # Copy only the mutable reference shell. map_metadata independently copies the
            # referenced structure, so recursively copying it here would be redundant.
            ref_copy = copy(ref)
            # map_metadata resolves each placement-specific component copy here. The active
            # recovery context caches that result so flattening does not resolve it again.
            ref_copy.structure =
                map_metadata(structure(ref), meta -> _prefixed(meta, node.id))
            refs(node_cs)[i] = ref_copy
        end
    end
    return sch
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
and return schema-version `1.0.0` metadata. Set `strict=:error` to fail on logged errors,
`strict=:warn` to fail on warnings or errors, or `strict=:no` to continue after recoverable
diagnostics. This method performs no metadata or model artifact I/O; write the returned
dictionary explicitly when persistence is desired.
"""
function render!(
    sm::SolidModel,
    sch::Schematic,
    target::SolidModelTarget;
    strict=:error,
    kwargs...
)
    sch.checked[] || error("cannot render an unchecked Schematic. Run check!(sch) first.")
    haskey(kwargs, :output_dir) && throw(
        ArgumentError(
            "experimental render! does not accept an output_dir keyword; write the returned metadata explicitly"
        )
    )

    # Prefixing mutates only a disposable schematic copy; the caller's schematic and
    # component geometry caches remain unchanged.
    sch_copy = deepcopy(sch)
    stage = :render_solidmodel
    previous_logger_stage = sch.logger.stage
    # Stage maxima accumulate across invocations. Save the caller's previous value and
    # clear it so check_render_strict considers only warnings and errors from this render.
    had_stage_level = haskey(sch.logger.max_level_logged, stage)
    previous_stage_level = get(sch.logger.max_level_logged, stage, Logging.Debug)
    delete!(sch.logger.max_level_logged, stage)
    try
        # Route geometry preparation, construction, and postprocessing diagnostics through
        # the render stage so the final strictness check sees the complete operation.
        reopen_logfile(sch, stage)
        metadata = with_logger(sch.logger) do
            # Prefix placement names and flatten once under the same recovery scope so
            # geometry failures are logged once and strict=:no can continue.
            flat = DeviceLayout.SchematicDrivenLayout.with_geometry_resolution_context() do
                    _prefix_placement_names!(sch_copy)
                    return DeviceLayout.flatten(sch_copy.coordinate_system)
                end
            # The flat geometry is the canonical stream of placed annotations.
            locators = resolve_locators(flat, target.stack)
            # Seed compiler state with the physical groups produced directly by artwork.
            layer_refs =
                Set{LayerRef}(m for m in element_metadata(flat) if m isa LayerRef)
            registry = initial_registry(layer_refs, target.stack)
            # Prepend required source-layer extrusions to the user-supplied operation schedule.
            layer_ops = vcat(extrusions(target.stack, registry), target.ops)
            # Compile layer operations and defer interface discovery until after fragmentation.
            pg_operations, registry, deferred_interfaces =
                compile_ops(layer_ops, target.stack, registry)
            # Preserve every compiled physical group needed by later finalization passes.
            retained_groups = _retained_physical_groups(registry)

            # Low-level renderer creates and fragments the geometry, then applies
            # the non-interface physical-group operations produced by the compiler.
            SolidModels.render!(
                sm,
                flat;
                preflattened=true,
                map_meta=_map_meta(target),
                postrender_ops=pg_operations,
                retained_physical_groups=retained_groups,
                zmap=meta -> layer_z(meta.layer, target.stack),
                kwargs...
            )

            # Complete global geometry before selecting finalized entities with locators.
            execute_deferred_interfaces!(sm, deferred_interfaces)
            _prune_unrealized_pgs!(sm, registry)
            selections = select!(sm, registry, target.stack, locators)
            # Deduplication registers sub-PGs under the layers of every PG they came from.
            _check_pgs_registered(sm, registry)

            # Partition entities by exact PG membership so each belongs to one PG. Locator
            # selection PGs and metal connected components overlap 2D layer PGs, so this
            # pass also isolates tagged entities, port surfaces, and connected components.
            for dim = 1:3
                _deduplicate_pgs!(sm, registry, dim)
            end

            # All geometry and registry mutation is complete; serialization only reads
            # the finalized model and graph metadata.
            return serialize_metadata(
                registry,
                selections,
                deferred_interfaces,
                target.stack,
                sm
            )
        end
        # Apply strictness only after all render and finalization warnings are logged.
        check_render_strict(sch, strict)
        return metadata
    finally
        close_logfile(sch)
        # Restore the caller's logger bookkeeping after strictness has been evaluated.
        if had_stage_level
            sch.logger.max_level_logged[stage] = previous_stage_level
        else
            delete!(sch.logger.max_level_logged, stage)
        end
        sch.logger.stage = previous_logger_stage
    end
end

end # module SolidModelsExperimental
