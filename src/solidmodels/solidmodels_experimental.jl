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
using ..SolidModels: SolidModel, STP_UNIT, _stp_float

import DeviceLayout: layer, render!, place!

include("experimental/metadata.jl")
include("experimental/stack.jl")
include("experimental/artwork.jl")
include("experimental/compiler.jl")
include("experimental/locators.jl")
include("experimental/serialization.jl")
using DeviceLayout.SchematicDrivenLayout
using Logging: with_logger

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

# Qualify a locator name with the id of the graph node that places it, e.g. `q1.island`.
_qualified(lm::Terminal, id::String) = Terminal(lm.layer, id * "." * lm.name)
_qualified(lm::Tag, id::String) = Tag(lm.layer, id * "." * lm.name)
_qualified(lm::P, id::String) where {P <: Port} = P(lm.layer, id * "." * lm.name, lm.index)
_qualified(m::DeviceLayout.Meta, ::String) = m

# Qualify locator names on placement-specific metadata copies under each graph node. The
# node id applies recursively within its component geometry, while child graph nodes
# receive their own. This implements the v1 top-level prefix contract.
function _qualify_locator_names!(sch::Schematic)
    ref_to_node_id = IdDict{Any, String}(ref => node.id for (node, ref) in sch.ref_dict)
    for (node, node_ref) in sch.ref_dict
        node_cs = structure(node_ref)
        metadata = element_metadata(node_cs)
        for i in eachindex(metadata)
            metadata[i] = _qualified(metadata[i], node.id)
        end
        for (i, ref) in pairs(refs(node_cs))
            haskey(ref_to_node_id, ref) && continue
            # Copy only the mutable reference shell. map_metadata independently copies the
            # referenced structure, so recursively copying it here would be redundant.
            ref_copy = copy(ref)
            # map_metadata resolves each placement-specific component copy here. The active
            # recovery context caches that result so flattening does not resolve it again.
            ref_copy.structure =
                map_metadata(structure(ref), meta -> _qualified(meta, node.id))
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
                    _qualify_locator_names!(sch_copy)
                    return DeviceLayout.flatten(sch_copy.coordinate_system)
                end
            # The flat geometry is the canonical stream of placed annotations.
            locators = resolve_locators(flat, target.stack)
            # Seed compiler state with the physical groups produced directly by artwork.
            layer_refs =
                Set{LayerRef}(m for m in element_metadata(flat) if m isa LayerRef)
            registry = initial_registry(layer_refs, target.stack)
            # Compile layer operations and defer interface discovery until after fragmentation.
            pg_operations, registry, deferred_interfaces =
                compile_ops(target.ops, target.stack, registry)
            check_declared_thicknesses(registry, target.stack)
            # Preserve every compiled physical group needed by later finalization passes.
            retained_groups = retained_physical_groups(registry)

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
            # Void hollowed solids first so interfaces see volumes without their interiors.
            hollow!(sm, registry)
            realize_interfaces!(sm, deferred_interfaces)
            sync_registry!(sm, registry)
            selections = select!(sm, registry, target.stack, locators)

            # Partition entities by exact PG membership so each belongs to one PG. Locator
            # selection PGs and metal connected components overlap 2D layer PGs, so this
            # pass also isolates tagged entities, port surfaces, and connected components.
            for dim = 1:3
                deduplicate_pgs!(sm, registry, dim)
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
