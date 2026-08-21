struct LocatorRecord
    name::String
    index::Int
    role::Locator
    layer::Symbol
    position::NTuple{3, Float64}
end

"""
    find_locators(cs, stack) -> Vector{LocatorRecord}

Extract one locator record per transformed reference occurrence without flattening `cs`.
Locator geometry is excluded from the mesh but remains visible to this discovery pass.
"""
function find_locators(cs, stack::SourceStack)
    records = LocatorRecord[]
    for (subcs, trans) in DeviceLayout.traversal(cs)
        for (entity_meta, element) in zip(element_metadata(subcs), elements(subcs))
            entity_meta isa EntityMeta || continue
            entity_meta.role isa Locator || continue
            entity_meta.role isa Terminal && isempty(entity_meta.name) && continue
            entity_meta.role isa Tag &&
                isempty(entity_meta.name) &&
                throw(ArgumentError("Tag locators must have a nonempty name"))
            source_layer = sourcelayer(entity_meta, stack)
            source_layer.solidmodel || continue
            global_element = trans(element)
            ctr = center(bounds(global_element))
            cx = SolidModels._stp_float(getx(ctr))
            cy = SolidModels._stp_float(gety(ctr))
            z = SolidModels._stp_float(layer_z(entity_meta.layer, stack))
            push!(
                records,
                LocatorRecord(
                    entity_meta.name,
                    entity_meta.index,
                    entity_meta.role,
                    entity_meta.layer,
                    (cx, cy, z)
                )
            )
        end
    end
    return records
end

function _containing_entity_tag(locator::LocatorRecord, entity_tags; z_tol=1e-6)
    x, y, z = locator.position
    found_tag = Int32(0)
    hit_count = 0
    for tag in entity_tags
        _, _, zmin, _, _, zmax = SolidModels.gmsh.model.getBoundingBox(2, Int(tag))
        (abs(zmax - zmin) < z_tol && abs(zmin - z) < z_tol) || continue
        inside_count = SolidModels.gmsh.model.isInside(2, Int(tag), [x, y, z])
        if inside_count > 0
            hit_count += 1
            found_tag = tag
        end
    end
    if hit_count > 1
        error(
            "Locator '$(locator.name)' at $(locator.position) matched " *
            "$hit_count entities; expected exactly 1 on a fragmented plane"
        )
    end
    return found_tag
end

"""
    add_terminals!(
        sm::SolidModel,
        registry::LayerRegistry,
        stack::SourceStack,
        locators::Vector{LocatorRecord}
    )

Identify electrostatic terminals and ground via connected components of metal surfaces.
Locator positions are matched to CCs using exact point-in-surface queries
(`gmsh.model.isInside`). Ground locators designate the CCs reported as ground. CCs with
no locators at all emit a warning.

Returns a named tuple `(terminals, ground, cc_entity_tags)` where:

  - `terminals::Dict{String, Vector{String}}`: CC name → locator names (non-ground CCs only)
  - `ground::Vector{String}`: CC names designated as ground
  - `cc_entity_tags::Dict{String, Vector{Int32}}`: CC name → surface entity tags
"""
function add_terminals!(
    sm::SolidModel,
    registry::LayerRegistry,
    stack::SourceStack,
    locators::Vector{LocatorRecord}
)
    terminals = Dict{String, Vector{String}}()
    ground = String[]
    cc_entity_tags = Dict{String, Vector{Int32}}()

    # Collect all 2D PGs whose layer material is METAL (including Tag PGs, which
    # are real mesh entities; only Terminal/Ground locators are excluded)
    metal_pg_names = String[]
    for (layer_name, state) in registry
        !haskey(stack.layers, layer_name) && continue
        source_layer = stack.layers[layer_name]
        source_layer.material != METAL && continue
        state.dim != 2 && continue
        for record in state.pgs
            if !isnothing(record.entity_meta)
                role = record.entity_meta.role
                (role isa Terminal || role isa Ground) && continue
            end
            push!(metal_pg_names, record.name)
        end
    end

    isempty(metal_pg_names) && return (; terminals, ground, cc_entity_tags)

    ccs = SolidModels.connected_components(sm, metal_pg_names)

    # Build a map from surface entity tag -> CC index
    tag_to_cc = Dict{Tuple{Int32, Int32}, Int}()
    for (idx, cc) in enumerate(ccs)
        for dimtag in cc
            tag_to_cc[dimtag] = idx
        end
    end

    # For each CC, compute a hash name and assign PG
    cc_names = Vector{String}(undef, length(ccs))
    cc_locators = Dict{String, Vector{String}}()
    for (idx, cc) in enumerate(ccs)
        cc_str = join(sort(["$(d),$(t)" for (d, t) in cc]), "&")
        digest = sha1(cc_str)
        cc_name = string(:METAL_CC) * "__" * bytes2hex(digest)[1:16]
        cc_names[idx] = cc_name
        sm[cc_name] = cc
        cc_locators[cc_name] = String[]
        cc_entity_tags[cc_name] = Int32[tag for (_, tag) in cc]
    end
    registry[:METAL_CC] =
        LayerState([PGRecord(name, :METAL_CC, nothing) for name in cc_names], 2)

    # Assign locator names to CCs using gmsh.model.isInside for exact point-in-surface
    # geometric queries. For each locator, find the single coplanar entity that contains
    # its center point, then associate the locator with that entity's CC.
    # Only Terminal and Ground locators participate (Tags are handled by
    # add_tagged_pgs!).
    ground_cc_indices = Set{Int}()
    terminal_locators =
        filter(locator -> locator.role isa Terminal || locator.role isa Ground, locators)
    for locator in terminal_locators
        candidate_tags = [dimtag[2] for dimtag in keys(tag_to_cc)]
        matched_tag = _containing_entity_tag(locator, candidate_tags)
        matched_cc_idx = iszero(matched_tag) ? 0 : tag_to_cc[(Int32(2), matched_tag)]
        if iszero(matched_cc_idx)
            @warn "$(nameof(typeof(locator.role))) locator '$(locator.name)' at " *
                  "$(locator.position) did not match any metal connected component"
        elseif locator.role isa Ground
            push!(ground_cc_indices, matched_cc_idx)
        else
            push!(cc_locators[cc_names[matched_cc_idx]], locator.name)
        end
    end

    # Partition into terminals and ground
    for (idx, cc_name) in enumerate(cc_names)
        if idx in ground_cc_indices
            push!(ground, cc_name)
        else
            if isempty(cc_locators[cc_name])
                @warn "Metal CC '$cc_name' has no locators " *
                      "(neither Terminal nor Ground). Did you forget a Ground locator?"
            end
            terminals[cc_name] = cc_locators[cc_name]
        end
    end

    return (; terminals, ground, cc_entity_tags)
end

# ─── Tag locator resolution ──────────────────────────────────────────────────

"""
    add_tagged_pgs!(sm, registry, locators, deferred_interfaces)
        -> Vector{Tuple{String, String, Symbol}}

After fragmentation, resolve Tag locators by finding the 2D surface entity that
contains each locator's center point and creating a dedicated PG for it. The PG is named
using `physical_group_name` with the Tag locator's layer, name, and index, and is
registered in the final registry under the locator's layer.

For each Tag PG, any pending deferred interfaces whose object references the parent
PG are duplicated with the Tag PG as object, so that `execute_deferred_interfaces!`
naturally produces per-Tag interface PGs via the cross product. Return records containing
each resolved Tag PG name, locator name, and layer.
"""
function add_tagged_pgs!(
    sm::SolidModel,
    registry::LayerRegistry,
    locators::Vector{LocatorRecord},
    deferred_interfaces::MetaGraphs.MetaDiGraph
)
    # return 0
    tag_records = Tuple{String, String, Symbol}[]
    tag_locators = filter(locator -> locator.role isa Tag, locators)

    for locator in tag_locators
        # A Tag is meaningful only within its declared source layer. Searching all 2D
        # groups could attach it to an unrelated coplanar or overlapping layer.
        haskey(registry, locator.layer) || continue
        layer_state = registry[locator.layer]
        layer_state.dim == 2 || continue
        layer_tags = Set{Int32}()
        for record in layer_state.pgs
            SolidModels.hasgroup(sm, record.name, 2) || continue
            union!(layer_tags, SolidModels.entitytags(sm[record.name, 2]))
        end

        found_tag = _containing_entity_tag(locator, layer_tags)
        if found_tag == 0
            @warn "Tag locator '$(locator.name)' at $(locator.position) did not " *
                  "match any 2D entity"
            continue
        end

        entity_meta =
            EntityMeta(locator.layer; name=locator.name, index=locator.index, role=Tag())
        pg_name = physical_group_name(entity_meta)

        # Create PG in the solid model
        sm[pg_name] = Tuple{Int32, Int32}[(Int32(2), found_tag)]

        # Remove tagged entity from all other 2D PGs on the same layer and
        # duplicate deferred interfaces for the Tag PG
        parent_pg_names = String[]
        if haskey(registry, locator.layer) && registry[locator.layer].dim == 2
            for record in registry[locator.layer].pgs
                SolidModels.hasgroup(sm, record.name, 2) || continue
                existing_dimtags = SolidModels.dimtags(sm[record.name, 2])
                filtered = filter(dimtag -> dimtag[2] != found_tag, existing_dimtags)
                if length(filtered) < length(existing_dimtags)
                    sm[record.name] = filtered
                    push!(parent_pg_names, record.name)
                end
            end
        end

        # For each deferred interface that references a parent PG as object,
        # add a parallel entry with the Tag PG as object
        for parent_name in parent_pg_names
            parent_key = (:pg, parent_name, 2)
            haskey(deferred_interfaces, parent_key, :key) || continue
            parent = deferred_interfaces[parent_key, :key]
            for operation in collect(Graphs.outneighbors(deferred_interfaces, parent))
                MetaGraphs.get_prop(deferred_interfaces, operation, :kind) == :interface ||
                    continue
                _, tool = operation_pgs(deferred_interfaces, operation)
                tool_name = MetaGraphs.get_prop(deferred_interfaces, tool, :name)
                tool_dim = MetaGraphs.get_prop(deferred_interfaces, tool, :dim)
                dest_layer =
                    MetaGraphs.get_prop(deferred_interfaces, operation, :dest_layer)
                _, tool_layer =
                    MetaGraphs.get_prop(deferred_interfaces, operation, :parent_layers)
                dest_pg = generated_pg_name(
                    dest_layer,
                    pg_name,
                    [tool_name];
                    operation=:intersect,
                    parameters=(2, tool_dim)
                )
                generated_record_exists(registry, dest_layer, dest_pg) && continue
                defer_interface!(
                    deferred_interfaces,
                    dest_pg,
                    pg_name,
                    tool_name,
                    2,
                    tool_dim,
                    dest_layer,
                    locator.layer,
                    tool_layer
                )
                push!(registry[dest_layer].pgs, PGRecord(dest_pg, dest_layer, nothing))
            end
        end

        # Add to registry
        record = PGRecord(pg_name, locator.layer, entity_meta)
        if haskey(registry, locator.layer)
            push!(registry[locator.layer].pgs, record)
        else
            registry[locator.layer] = LayerState([record], 2)
        end
        push!(tag_records, (pg_name, locator.name, locator.layer))
    end

    return tag_records
end
