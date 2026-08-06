# ═══════════════════════════════════════════════════════════════════════════════════════════
# Metadata JSON serialization
# ═══════════════════════════════════════════════════════════════════════════════════════════

"""
    serialize_metadata(
        registry, terminal_result, tag_records, split_results,
        cc_entity_tags, iface_layer_parents, target, sm
    ) -> Dict

Serialize the solid model metadata to a JSON-compatible dictionary.
"""
function serialize_metadata(
    registry::Registry,
    terminal_result::NamedTuple{(:terminals, :ground)},
    tag_records::Vector{Tuple{String, String, Symbol}},
    split_results::Dict,
    cc_entity_tags::Dict{String, Vector{Int32}},
    iface_layer_parents::Dict{Symbol, Vector{String}},
    stack::SourceStack,
    levels::StackLevels,
    sm::SolidModel
)::Dict{String, Any}
    metadata = Dict{String, Any}(
        "schema_version" => "1.0.0",
        "length_units" => "um",
        "assembly" => Dict{String, Any}(
            "levels" => Dict(string(k) => _micron_value(v) for (k, v) in levels.levels)
        )
    )

    physical_groups = Dict{String, Any}()
    for (layer_name, state) in registry
        for pgr in state.pgs
            # Skip PGs that don't exist in the solid model (e.g. empty deferred intersections)
            gd = SolidModels.dimgroupdict(sm, state.dim)
            haskey(gd, pgr.name) || continue

            pg_entry = Dict{String, Any}("tag" => gd[pgr.name].grouptag, "dim" => state.dim)

            # Entity meta
            if pgr.entity_meta !== nothing
                em = pgr.entity_meta
                role_dict = Dict{String, Any}("type" => _role_tag(em.role))
                if em.role isa LumpedPort
                    role_dict["direction"] = em.role.direction
                end
                pg_entry["entity_meta"] = Dict{String, Any}(
                    "name" => em.name,
                    "index" => em.index,
                    "role" => role_dict
                )
            else
                pg_entry["entity_meta"] = nothing
            end

            physical_groups[pgr.name] = pg_entry
        end
    end

    # Build layers map: layer name → {pgs, layer metadata, parents (for interfaces)}
    layers_dict = Dict{String, Any}()
    for (layer_name, state) in registry
        pg_names = String[]
        for pgr in state.pgs
            gd = SolidModels.dimgroupdict(sm, state.dim)
            haskey(gd, pgr.name) || continue
            push!(pg_names, pgr.name)
        end
        isempty(pg_names) && continue

        layer_entry = Dict{String, Any}("pgs" => pg_names, "dim" => state.dim)
        if haskey(stack, layer_name)
            sl = stack[layer_name]
            layer_entry["type"] = "source"
            layer_entry["level"] = first_level(sl)
            layer_entry["height"] = _micron_value(first_height(sl))
            layer_entry["thickness"] = _micron_value(resolve_thickness(sl, levels))
        else
            layer_entry["type"] = "generated"
        end
        if haskey(iface_layer_parents, layer_name)
            layer_entry["parents"] = iface_layer_parents[layer_name]
        end
        layers_dict[string(layer_name)] = layer_entry
    end

    # Build tagged dict: Tag locators → their underlying PGs after dedup
    tagged_dict = Dict{String, Any}()
    for (pg_name, locator_name, layer_name) in tag_records
        sub_pg_names = _resolve_split_pgs(pg_name, split_results, sm)
        tagged_dict[locator_name] =
            Dict{String, Any}("pgs" => sub_pg_names, "layer" => string(layer_name))
    end

    # Build terminals dict with sub-PG references
    terminals_dict = Dict{String, Any}()
    for (cc_name, locator_tags) in terminal_result.terminals
        sub_pg_names = _resolve_entity_pgs(cc_entity_tags, cc_name, sm)
        terminals_dict[cc_name] =
            Dict{String, Any}("pgs" => sub_pg_names, "locators" => locator_tags)
    end

    # Build ground dict with sub-PG references
    ground_dict = Dict{String, Any}()
    for cc_name in terminal_result.ground
        sub_pg_names = _resolve_entity_pgs(cc_entity_tags, cc_name, sm)
        ground_dict[cc_name] = Dict{String, Any}("pgs" => sub_pg_names)
    end

    return Dict{String, Any}(
        "metadata" => metadata,
        "physical_groups" => physical_groups,
        "layers" => layers_dict,
        "tagged" => tagged_dict,
        "terminals" => terminals_dict,
        "ground" => ground_dict
    )
end

"""
Write a metadata dictionary as indented JSON. Rendering never calls this function.
"""
function write_metadata(path::AbstractString, metadata::AbstractDict)
    return open(path, "w") do io
        return JSON.print(io, metadata, 4)
    end
end
