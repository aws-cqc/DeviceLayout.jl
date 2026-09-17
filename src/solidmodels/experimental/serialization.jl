function _entity_pg_map(sm::SolidModel)
    tag_to_pgs = Dict{Int32, Vector{String}}()
    for (name, pg) in SolidModels.dimgroupdict(sm, 2)
        for tag in SolidModels.entitytags(pg)
            push!(get!(Vector{String}, tag_to_pgs, tag), name)
        end
    end
    return tag_to_pgs
end

function _resolve_entity_pgs(tag_to_pgs::Dict{Int32, Vector{String}}, tags::Vector{Int32})
    pgs = Set{String}()
    for tag in tags
        union!(pgs, get(tag_to_pgs, tag, String[]))
    end
    return sort!(collect(pgs))
end

# ─── Metadata JSON serialization ─────────────────────────────────────────────

"""
    serialize_metadata(registry, selections, deferred_interfaces, stack, sm)
        -> Dict{String, Any}

Serialize the finalized solid model to a schema-version `1.0.0`, JSON-compatible
metadata dictionary. Length values are expressed in micrometers.
"""
function serialize_metadata(
    registry::LayerRegistry,
    selections::Vector{Selection},
    deferred_interfaces::Vector{DeferredInterface},
    stack::SourceStack,
    sm::SolidModel
)
    metadata = Dict{String, Any}(
        "schema_version" => "1.0.0",
        "length_units" => "um",
        "assembly" => Dict{String, Any}(
            "levels" =>
                Dict(string(level) => _stp_float(z) for (level, z) in stack.levels)
        )
    )

    physical_groups = Dict{String, Any}()
    for (_, state) in registry
        dimension_groups = SolidModels.dimgroupdict(sm, state.dim)
        for name in state.pgs
            physical_groups[name] = Dict{String, Any}(
                "tag" => dimension_groups[name].grouptag,
                "dim" => state.dim
            )
        end
    end

    # Build layers map: layer name → {pgs, layer metadata, parents (for interfaces)}
    interface_layer_parents = Dict(
        di.destination => unique([string(di.object), string(di.tool)]) for
        di in deferred_interfaces
    )

    layers_dict = Dict{String, Any}()
    for (layer_name, state) in registry
        isempty(state.pgs) && continue
        layer_entry = Dict{String, Any}("pgs" => copy(state.pgs), "dim" => state.dim)
        if haskey(stack.layers, layer_name)
            source_layer = stack.layers[layer_name]
            layer_entry["type"] = "source"
            layer_entry["level"] = first(source_layer.level)
            layer_entry["offset"] = _stp_float(first(source_layer.offset))
            layer_entry["thickness"] = _stp_float(thickness(source_layer, stack))
        else
            layer_entry["type"] = "generated"
            isnothing(state.dz) || (layer_entry["thickness"] = state.dz)
        end
        if haskey(interface_layer_parents, layer_name)
            layer_entry["parents"] = interface_layer_parents[layer_name]
        end
        layers_dict[string(layer_name)] = layer_entry
    end

    # Name each selection after its locators, resolving its entity tags to final PGs.
    entity_to_pgs = _entity_pg_map(sm)
    sections = (;
        tagged=Dict{String, Any}(),
        ports=Dict{String, Any}(),
        terminals=Dict{String, Any}(),
        ground=Dict{String, Any}()
    )
    for sel in selections
        _serialize!(sections, sel, _resolve_entity_pgs(entity_to_pgs, sel.entity_tags))
    end

    return Dict{String, Any}(
        "metadata" => metadata,
        "physical_groups" => physical_groups,
        "layers" => layers_dict,
        "tagged" => sections.tagged,
        "ports" => sections.ports,
        "terminals" => sections.terminals,
        "ground" => sections.ground
    )
end

# A tag or port selection has exactly one locator. A metal connected component has any
# number of terminal and ground locators and is ground if any of them is a `Ground`.
function _serialize!(sections, sel::Selection, pgs::Vector{String})
    if any(rl -> rl.meta isa Union{Tag, Port}, sel.locators)
        rl = only(sel.locators)
        return _serialize!(sections, rl, rl.meta, pgs)
    end
    cc_name = "METAL_CC__" * pghash((2, t) for t in sel.entity_tags)
    if any(rl -> rl.meta isa Ground, sel.locators)
        sections.ground[cc_name] = Dict{String, Any}("pgs" => pgs)
    else
        names = [rl.meta.name for rl in sel.locators]
        sections.terminals[cc_name] = Dict{String, Any}("pgs" => pgs, "locators" => names)
    end
    return sections
end

function _serialize!(sections, ::ResolvedLocator, lm::Tag, pgs::Vector{String})
    haskey(sections.tagged, lm.name) &&
        throw(ArgumentError("duplicate serialized tags with name '$(lm.name)'"))
    sections.tagged[lm.name] = Dict{String, Any}("pgs" => pgs, "layer" => string(lm.layer))
    return sections
end

function _serialize!(sections, rl::ResolvedLocator, lm::Port, pgs::Vector{String})
    key = lm.index == 1 ? lm.name : "$(lm.name)_$(lm.index)"
    haskey(sections.ports, key) &&
        throw(ArgumentError("duplicate serialized ports with name '$key'"))
    sections.ports[key] = Dict{String, Any}(
        "name" => lm.name,
        "index" => lm.index,
        "type" => string(nameof(typeof(lm))),
        "layer" => string(lm.layer),
        "direction" => rl.direction,
        "pgs" => pgs
    )
    return sections
end
