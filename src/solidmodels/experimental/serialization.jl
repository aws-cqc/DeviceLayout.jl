# ─── Metadata JSON serialization ─────────────────────────────────────────────

"""
    serialize_metadata(
        registry, terminal_result, tag_records, split_results,
        cc_entity_tags, interface_layer_parents, stack, sm,
        lumped_port_directions
    ) -> Dict{String, Any}

Serialize the solid model metadata to a JSON-compatible dictionary.
"""
function serialize_metadata(
    registry::Registry,
    terminal_result::NamedTuple{(:terminals, :ground)},
    tag_records::Vector{Tuple{String, String, Symbol}},
    split_results::AbstractDict,
    cc_entity_tags::Dict{String, Vector{Int32}},
    interface_layer_parents::Dict{Symbol, Vector{String}},
    stack::SourceStack,
    sm::SolidModel,
    lumped_port_directions::Dict{String, Vector{Float64}}
)
    metadata = Dict{String, Any}(
        "schema_version" => "1.0.0",
        "length_units" => "um",
        "assembly" => Dict{String, Any}(
            "levels" => Dict(
                string(level) => SolidModels._stp_float(z) for (level, z) in stack.levels
            )
        )
    )

    physical_groups = Dict{String, Any}()
    for (_, state) in registry
        dimension_groups = SolidModels.dimgroupdict(sm, state.dim)
        for record in state.pgs
            # Skip PGs that do not exist in the solid model (for example, empty deferred
            # intersections).
            haskey(dimension_groups, record.name) || continue

            pg_entry = Dict{String, Any}(
                "tag" => dimension_groups[record.name].grouptag,
                "dim" => state.dim
            )

            # Entity metadata.
            if !isnothing(record.entity_meta)
                entity_meta = record.entity_meta
                role_dict = Dict{String, Any}("type" => string(entity_meta.role))
                if entity_meta.role isa LumpedPort
                    source_name = physical_group_name(entity_meta)
                    haskey(lumped_port_directions, source_name) || error(
                        "Internal metadata serialization error: LumpedPort record " *
                        "'$(record.name)' has no resolved direction for source identity " *
                        "'$source_name'"
                    )
                    role_dict["direction"] = lumped_port_directions[source_name]
                end
                pg_entry["entity_meta"] = Dict{String, Any}(
                    "name" => entity_meta.name,
                    "index" => entity_meta.index,
                    "role" => role_dict
                )
            else
                pg_entry["entity_meta"] = nothing
            end

            physical_groups[record.name] = pg_entry
        end
    end

    # Build layers map: layer name → {pgs, layer metadata, parents (for interfaces)}
    layers_dict = Dict{String, Any}()
    for (layer_name, state) in registry
        dimension_groups = SolidModels.dimgroupdict(sm, state.dim)
        pg_names = String[]
        for record in state.pgs
            haskey(dimension_groups, record.name) || continue
            push!(pg_names, record.name)
        end
        isempty(pg_names) && continue

        layer_entry = Dict{String, Any}("pgs" => pg_names, "dim" => state.dim)
        if haskey(stack.layers, layer_name)
            source_layer = stack.layers[layer_name]
            layer_entry["type"] = "source"
            layer_entry["level"] = first(source_layer.level)
            layer_entry["height"] = SolidModels._stp_float(first(source_layer.height))
            layer_entry["thickness"] =
                SolidModels._stp_float(thickness(source_layer, stack))
        else
            layer_entry["type"] = "generated"
        end
        if haskey(interface_layer_parents, layer_name)
            layer_entry["parents"] = interface_layer_parents[layer_name]
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
    for (cc_name, cc_locators) in terminal_result.terminals
        sub_pg_names = _resolve_entity_pgs(cc_entity_tags, cc_name, sm)
        terminals_dict[cc_name] =
            Dict{String, Any}("pgs" => sub_pg_names, "locators" => cc_locators)
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
    write_metadata(path::AbstractString, metadata::AbstractDict)

Write a metadata dictionary as indented JSON. Rendering never calls this function.
"""
function write_metadata(path::AbstractString, metadata::AbstractDict)
    return open(path, "w") do io
        return JSON.print(io, metadata, 4)
    end
end
