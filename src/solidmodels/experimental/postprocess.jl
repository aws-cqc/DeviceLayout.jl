"""
    _execute_deferred_interfaces!(sm, deferred_interfaces)

After fragmentation, compute interface PGs as set intersections of entity memberships.

Handles two cases:

  - Same-dimension (for example, 3D∩3D or 2D∩2D): the interface is the set of shared
    boundary entities at dimension `dim - 1` (faces for volumes, curves for surfaces).
  - Mixed-dimension (for example, 2D∩3D): the interface is the set of lower-dimensional
    entities in one PG that are also boundary faces of entities in the other PG.
"""
function _execute_deferred_interfaces!(sm::SolidModel, interfs::MetaGraphs.MetaDiGraph)
    Graphs.nv(interfs) == 0 && return nothing

    dimtag_cache = Dict{Int, Any}()
    boundary_cache = Dict{Int, Any}()

    function pg_dimtags(vertex)
        return get!(dimtag_cache, vertex) do
            name = MetaGraphs.get_prop(interfs, vertex, :name)
            dim = MetaGraphs.get_prop(interfs, vertex, :dim)
            SolidModels.hasgroup(sm, name, dim) || return nothing
            return SolidModels.dimtags(sm[name, dim])
        end
    end

    function pg_boundary_tags(vertex, boundary_dim)
        boundaries = get!(boundary_cache, vertex) do
            dimtags = pg_dimtags(vertex)
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

    for operation in _interface_vertices(interfs)
        object, tool = _interface_pgs(interfs, operation)
        obj_dim = MetaGraphs.get_prop(interfs, object, :dim)
        tool_dim = MetaGraphs.get_prop(interfs, tool, :dim)
        dest_name = MetaGraphs.get_prop(interfs, operation, :dest_name)

        if obj_dim == tool_dim
            boundary_dim = obj_dim - 1
            obj_tags = pg_boundary_tags(object, boundary_dim)
            tool_tags = pg_boundary_tags(tool, boundary_dim)
            (isnothing(obj_tags) || isnothing(tool_tags)) && continue
            interface_tags = intersect(obj_tags, tool_tags)
            isempty(interface_tags) && continue
            sm[dest_name] =
                Tuple{Int32, Int32}[(Int32(boundary_dim), tag) for tag in interface_tags]
        else
            lo_dim = min(obj_dim, tool_dim)
            lo = obj_dim <= tool_dim ? object : tool
            hi = obj_dim <= tool_dim ? tool : object
            lo_dimtags = pg_dimtags(lo)
            hi_tags = pg_boundary_tags(hi, lo_dim)
            (isnothing(lo_dimtags) || isnothing(hi_tags)) && continue
            lo_tags = Set(Int32(tag) for (_, tag) in lo_dimtags)
            interface_tags = intersect(lo_tags, hi_tags)
            isempty(interface_tags) && continue
            sm[dest_name] =
                Tuple{Int32, Int32}[(Int32(lo_dim), tag) for tag in interface_tags]
        end
    end

    return nothing
end

# ─── 2D PG deduplication ─────────────────────────────────────────────────────

"""
    _deduplicate_2d_pgs!(sm, registry)

Ensure each mesh face belongs to exactly one 2D physical group by splitting PGs that
span multiple layers into layer-homogeneous sub-PGs.

For each 2D entity, computes its "membership signature" (the set of layers whose PGs
contain it). PGs where all entities share a single signature are left unchanged. PGs
with mixed signatures are split into sub-PGs, one per distinct signature. Each sub-PG
is then cross-referenced into all layers of its signature, and duplicate entity
assignments are removed from the original PGs.

After this step, the mesh has non-overlapping 2D elements and each layer's PG list in
the registry can recover its full original surface.
"""
function _deduplicate_2d_pgs!(sm::SolidModel, registry::Registry)
    # Phase 1: Build entity → layer membership map
    pg_to_layer = Dict{String, Symbol}()
    for (layer_name, state) in registry
        state.dim != 2 && continue
        for record in state.pgs
            pg_to_layer[record.name] = layer_name
        end
    end

    entity_layers = Dict{Int32, Set{Symbol}}()  # entity tag → set of layers
    for (pg_name, pg) in SolidModels.dimgroupdict(sm, 2)
        layer = get(pg_to_layer, pg_name, nothing)
        isnothing(layer) && continue
        for t in SolidModels.entitytags(pg)
            layers_set = get!(Set{Symbol}, entity_layers, t)
            push!(layers_set, layer)
        end
    end

    # Phase 2: For each PG, group entities by membership signature.
    # Identify which PGs need splitting.
    # signature = sorted tuple of layers (frozen for use as dict key)
    Signature = Tuple{Vararg{Symbol}}

    pgs_to_split = Dict{String, Dict{Signature, Vector{Int32}}}()
    for (pg_name, pg) in SolidModels.dimgroupdict(sm, 2)
        haskey(pg_to_layer, pg_name) || continue
        tags = SolidModels.entitytags(pg)
        isempty(tags) && continue

        groups = Dict{Signature, Vector{Int32}}()
        for t in tags
            signature = Tuple(sort!(collect(get(entity_layers, t, Set{Symbol}()))))
            tag_list = get!(Vector{Int32}, groups, signature)
            push!(tag_list, t)
        end

        # If there's only one group and its signature matches the PG's own layer alone,
        # no split needed (homogeneous PG)
        if length(groups) == 1
            only_sig = first(keys(groups))
            pg_layer = pg_to_layer[pg_name]
            if length(only_sig) == 1 && only_sig[1] == pg_layer
                continue
            end
        end

        pgs_to_split[pg_name] = groups
    end

    # Phase 3: Split heterogeneous PGs into sub-PGs
    # Track: original PG name → list of (sub_pg_name, signature) created from it
    split_results = Dict{String, Vector{Tuple{String, Signature}}}()

    for (pg_name, groups) in pgs_to_split
        pg_layer = pg_to_layer[pg_name]
        sub_pgs = Tuple{String, Signature}[]

        for (signature, tags) in groups
            if length(signature) == 1 && signature[1] == pg_layer && length(groups) > 1
                # Residual: entities exclusive to this PG's own layer — keep original name
                sub_name = pg_name
            else
                # Shared or foreign: generate a content-addressed name
                dimtags_str = join(sort(["2,$(t)" for t in tags]), "&")
                digest = sha1(dimtags_str)
                sub_name = "__" * bytes2hex(digest)[1:16]
            end
            push!(sub_pgs, (sub_name, signature))

            # Create or update the PG in Gmsh
            if sub_name == pg_name
                # Rewrite the original PG to contain only its residual entities
                sm[pg_name] = Tuple{Int32, Int32}[(Int32(2), t) for t in tags]
            else
                # Create new sub-PG
                sm[sub_name] = Tuple{Int32, Int32}[(Int32(2), t) for t in tags]
            end
        end

        # If the original PG name was NOT used as residual, remove it from the model
        if !any(name == pg_name for (name, _) in sub_pgs)
            if SolidModels.hasgroup(sm, pg_name, 2)
                grouptag = sm[pg_name, 2].grouptag
                SolidModels.gmsh.model.removePhysicalGroups([(2, grouptag)])
                delete!(SolidModels.dimgroupdict(sm, 2), pg_name)
            end
        end

        split_results[pg_name] = sub_pgs
    end

    # Phase 4: Remove duplicate entity assignments.
    # After splitting, entities that were in multiple original PGs now have a dedicated
    # sub-PG. Remove them from any other PG that still contains them.
    entity_owner = Dict{Int32, String}()  # entity tag → owning PG name
    # First assign: sub-PGs take priority (they were just created with exact entity sets)
    for (_, sub_pgs) in split_results
        for (sub_name, _) in sub_pgs
            SolidModels.hasgroup(sm, sub_name, 2) || continue
            for t in SolidModels.entitytags(sm[sub_name, 2])
                entity_owner[t] = sub_name
            end
        end
    end
    # Then assign remaining entities from unsplit PGs
    for (pg_name, pg) in SolidModels.dimgroupdict(sm, 2)
        for t in SolidModels.entitytags(pg)
            if !haskey(entity_owner, t)
                entity_owner[t] = pg_name
            end
        end
    end

    # Rewrite any PG that contains entities it doesn't own
    for (pg_name, pg) in collect(SolidModels.dimgroupdict(sm, 2))
        current_tags = SolidModels.entitytags(pg)
        owned_tags = Int32[t for t in current_tags if get(entity_owner, t, "") == pg_name]
        if length(owned_tags) < length(current_tags)
            if isempty(owned_tags)
                SolidModels.gmsh.model.removePhysicalGroups([(2, pg.grouptag)])
                delete!(SolidModels.dimgroupdict(sm, 2), pg_name)
            else
                sm[pg_name] = Tuple{Int32, Int32}[(Int32(2), t) for t in owned_tags]
            end
        end
    end

    # Phase 5: Update registry cross-references.
    # For each sub-PG, add it to all layers in its signature.
    for (original_pg_name, sub_pgs) in split_results
        original_layer = pg_to_layer[original_pg_name]

        for (sub_name, signature) in sub_pgs
            # Create a PGRecord for the sub-PG
            sub_record = PGRecord(sub_name, original_layer, nothing)

            for layer_name in signature
                !haskey(registry, layer_name) && continue
                registry[layer_name].dim != 2 && continue
                # Avoid duplicates
                any(record -> record.name == sub_name, registry[layer_name].pgs) && continue
                push!(registry[layer_name].pgs, sub_record)
            end
        end

        # Remove the original PG from registry if it was fully replaced
        if !any(name == original_pg_name for (name, _) in sub_pgs)
            if haskey(registry, original_layer)
                filter!(
                    record -> record.name != original_pg_name,
                    registry[original_layer].pgs
                )
            end
        end
    end

    return split_results
end

# ─── restrict_to_volume! ─────────────────────────────────────────────────────

struct LocatorRecord
    name::String
    index::Int
    role::Locator
    layer::Symbol
    center_x::Float64
    center_y::Float64
    z::Float64
end

"""
    _locators(cs, stack) -> Vector{LocatorRecord}

Extract one locator record per transformed reference occurrence without flattening `cs`.
Locator geometry is excluded from the mesh but remains visible to this discovery pass.
"""
function _locators(cs, stack::SourceStack)
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
                    cx,
                    cy,
                    z
                )
            )
        end
    end
    return records
end

"""
    find_terminals!(
        sm::SolidModel,
        registry::Registry,
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
function find_terminals!(
    sm::SolidModel,
    registry::Registry,
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
    # _resolve_tag_locators!).
    ground_cc_indices = Set{Int}()
    terminal_locators =
        filter(locator -> locator.role isa Terminal || locator.role isa Ground, locators)
    for locator in terminal_locators
        matched_cc_idx = 0
        hit_count = 0
        for (dimtag, cc_idx) in tag_to_cc
            dim, tag = dimtag
            _, _, zmin, _, _, zmax =
                SolidModels.gmsh.model.getBoundingBox(Int(dim), Int(tag))
            # Only match horizontal (flat) surfaces coplanar with the locator
            z_tol = 1e-6
            (abs(zmax - zmin) < z_tol && abs(zmin - locator.z) < z_tol) || continue
            inside_count = SolidModels.gmsh.model.isInside(
                Int(dim),
                Int(tag),
                [locator.center_x, locator.center_y, locator.z]
            )
            if inside_count > 0
                hit_count += 1
                matched_cc_idx = cc_idx
            end
        end
        if hit_count > 1
            error(
                "Locator '$(locator.name)' at " *
                "($(locator.center_x), $(locator.center_y), $(locator.z)) matched " *
                "$hit_count entities; expected exactly 1 on a fragmented plane"
            )
        end
        if matched_cc_idx > 0
            if locator.role isa Ground
                push!(ground_cc_indices, matched_cc_idx)
            else
                push!(cc_locators[cc_names[matched_cc_idx]], locator.name)
            end
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
    _resolve_tag_locators!(sm, registry, locators, deferred_interfaces)
        -> Vector{Tuple{String, String, Symbol}}

After fragmentation, resolve Tag locators by finding the 2D surface entity that
contains each locator's center point and creating a dedicated PG for it. The PG is named
using `physical_group_name` with the Tag locator's layer, name, and index, and is
registered in the final registry under the locator's layer.

For each Tag PG, any pending deferred interfaces whose object references the parent
PG are duplicated with the Tag PG as object, so that `_execute_deferred_interfaces!`
naturally produces per-Tag interface PGs via the cross product. Return records containing
each resolved Tag PG name, locator name, and layer.
"""
function _resolve_tag_locators!(
    sm::SolidModel,
    registry::Registry,
    locators::Vector{LocatorRecord},
    deferred_interfaces::MetaGraphs.MetaDiGraph
)
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

        found_tag = Int32(0)
        hit_count = 0
        for tag in layer_tags
            _, _, zmin, _, _, zmax = SolidModels.gmsh.model.getBoundingBox(2, Int(tag))
            z_tol = 1e-6
            (abs(zmax - zmin) < z_tol && abs(zmin - locator.z) < z_tol) || continue
            inside_count = SolidModels.gmsh.model.isInside(
                2,
                Int(tag),
                [locator.center_x, locator.center_y, locator.z]
            )
            if inside_count > 0
                hit_count += 1
                found_tag = tag
            end
        end
        if hit_count > 1
            error(
                "Tag locator '$(locator.name)' at " *
                "($(locator.center_x), $(locator.center_y), $(locator.z)) matched " *
                "$hit_count entities; expected exactly 1 on a fragmented plane"
            )
        end
        if found_tag == 0
            @warn "Tag locator '$(locator.name)' at " *
                  "($(locator.center_x), $(locator.center_y), $(locator.z)) did not " *
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
                _, tool = _interface_pgs(deferred_interfaces, operation)
                tool_name = MetaGraphs.get_prop(deferred_interfaces, tool, :name)
                tool_dim = MetaGraphs.get_prop(deferred_interfaces, tool, :dim)
                dest_layer =
                    MetaGraphs.get_prop(deferred_interfaces, operation, :dest_layer)
                _, tool_layer =
                    MetaGraphs.get_prop(deferred_interfaces, operation, :parent_layers)
                dest_name = generated_pg_name(
                    dest_layer,
                    pg_name,
                    [tool_name];
                    operation=:intersect,
                    parameters=(2, tool_dim)
                )
                _generated_record_exists(registry, dest_layer, dest_name) && continue
                _defer_interface!(
                    deferred_interfaces,
                    dest_name,
                    pg_name,
                    tool_name,
                    2,
                    tool_dim,
                    dest_layer,
                    locator.layer,
                    tool_layer
                )
                push!(registry[dest_layer].pgs, PGRecord(dest_name, dest_layer, nothing))
            end
        end

        # Register in the final registry
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

function _resolve_split_pgs(pg::String, split_results::AbstractDict, sm::SolidModel)
    if haskey(split_results, pg)
        return String[
            name for (name, _) in split_results[pg] if SolidModels.hasgroup(sm, name, 2)
        ]
    elseif SolidModels.hasgroup(sm, pg, 2)
        return [pg]
    else
        return String[]
    end
end

"""
    _resolve_entity_pgs(cc_entity_tags, cc_name, sm) -> Vector{String}

Return the current 2D PGs containing entities from a specific CC.

Callers must first call [`_split_shared_cc_pgs!`](@ref) so each returned PG belongs to only
one CC and no PG tag appears in multiple terminal or ground entries.
"""
function _resolve_entity_pgs(
    cc_entity_tags::Dict{String, Vector{Int32}},
    cc_name::String,
    sm::SolidModel
)
    !haskey(cc_entity_tags, cc_name) && return String[]
    target_tags = Set(cc_entity_tags[cc_name])
    pg_names = String[]
    for (name, pg) in SolidModels.dimgroupdict(sm, 2)
        for t in SolidModels.entitytags(pg)
            if t in target_tags
                push!(pg_names, name)
                break
            end
        end
    end
    return sort(pg_names)
end

"""
    _split_shared_cc_pgs!(sm, registry, split_results, cc_entity_tags)

Split any 2D PG containing entities from multiple CCs into content-addressed sub-PGs and
update the registry and prior layer-partition results to reference them.
"""
function _split_shared_cc_pgs!(
    sm::SolidModel,
    registry::Registry,
    split_results::AbstractDict,
    cc_entity_tags::Dict{String, Vector{Int32}}
)
    entity_to_cc = Dict{Int32, String}(
        tag => cc_name for (cc_name, tags) in cc_entity_tags for tag in tags
    )
    Signature = Tuple{Vararg{Symbol}}

    for (pg_name, pg) in collect(SolidModels.dimgroupdict(sm, 2))
        cc_groups = Dict{String, Vector{Int32}}()
        non_cc_tags = Int32[]
        for tag in SolidModels.entitytags(pg)
            cc_name = get(entity_to_cc, tag, nothing)
            if isnothing(cc_name)
                push!(non_cc_tags, tag)
            else
                push!(get!(Vector{Int32}, cc_groups, cc_name), tag)
            end
        end
        length(cc_groups) <= 1 && continue

        cc_names = sort!(collect(keys(cc_groups)))
        tag_groups = [vcat(non_cc_tags, cc_groups[first(cc_names)])]
        append!(tag_groups, [cc_groups[cc_name] for cc_name in cc_names[2:end]])

        sub_names = String[]
        for tags in tag_groups
            dimtags_str = join(sort(["2,$tag" for tag in tags]), "&")
            sub_name = "__" * bytes2hex(sha1(dimtags_str))[1:16]
            sm[sub_name] = Tuple{Int32, Int32}[(Int32(2), tag) for tag in tags]
            push!(sub_names, sub_name)
        end

        registered_layers = Symbol[]
        for (layer_name, state) in registry
            state.dim == 2 || continue
            matching_records = filter(record -> record.name == pg_name, state.pgs)
            isempty(matching_records) && continue
            push!(registered_layers, layer_name)
            filter!(record -> record.name != pg_name, state.pgs)

            entity_meta = first(matching_records).entity_meta
            for sub_name in sub_names
                any(record -> record.name == sub_name, state.pgs) && continue
                push!(state.pgs, PGRecord(sub_name, layer_name, entity_meta))
            end
        end

        replaced_in_split_results = false
        for original_name in collect(keys(split_results))
            sub_pgs = split_results[original_name]
            updated_sub_pgs = similar(sub_pgs, 0)
            for (sub_name, signature) in sub_pgs
                if sub_name == pg_name
                    append!(updated_sub_pgs, [(name, signature) for name in sub_names])
                    replaced_in_split_results = true
                else
                    push!(updated_sub_pgs, (sub_name, signature))
                end
            end
            split_results[original_name] = unique(updated_sub_pgs)
        end
        if !replaced_in_split_results
            signature = Tuple(sort!(unique(registered_layers)))
            split_results[pg_name] =
                Tuple{String, Signature}[(sub_name, signature) for sub_name in sub_names]
        end

        grouptag = sm[pg_name, 2].grouptag
        SolidModels.gmsh.model.removePhysicalGroups([(2, grouptag)])
        delete!(SolidModels.dimgroupdict(sm, 2), pg_name)
    end
    return nothing
end

"""
    remap_to_visualization_pgs!(sm::SolidModel, visualization_metadata::AbstractDict)

Replace the chopped 2D physical groups in `sm` with a smaller set of human-readable PGs
from `visualization_metadata`. Intended for `.viz.msh2` exports opened in the Gmsh GUI;
the resulting model is **not** Palace-compatible (entities will belong to multiple PGs,
producing duplicated element lines).

Five passes (in order) collect entities from chopped PGs and union them into new named
PGs:

 1. one PG per `visualization_metadata["layers"]` entry (skipping `METAL_CC`), named
    after the layer
 2. one PG per `visualization_metadata["terminals"]` entry, named
    `TERMINAL_<loc1>+<loc2>+...`
 3. a single `GROUND` PG covering all `visualization_metadata["ground"]` entries
 4. one PG per `visualization_metadata["tagged"]` entry, named `TAG_<tag_name>`
 5. one PG per `visualization_metadata["physical_groups"]` entry whose `entity_meta` is
    non-null—the original PG already carries useful info, so the existing PG is left in
    place

After the new PGs are added, every chopped sub-PG (those whose record was absorbed into a
layer/terminal/etc. PG and whose original name carries no information) is removed via
`SolidModels.remove_group!` with `recursive=false, remove_entities=false`. The mesh
entities themselves are never touched.
"""
function remap_to_visualization_pgs!(sm::SolidModel, visualization_metadata::AbstractDict)
    layers = get(visualization_metadata, "layers", Dict{String, Any}())
    terminals = get(visualization_metadata, "terminals", Dict{String, Any}())
    ground = get(visualization_metadata, "ground", Dict{String, Any}())
    tagged = get(visualization_metadata, "tagged", Dict{String, Any}())
    physical_groups = get(visualization_metadata, "physical_groups", Dict{String, Any}())

    # PGs whose entity_meta is non-null already have useful names — keep them
    # in place and never remove them.
    keep_existing = Set{String}()
    for (pg_name, pg_data) in physical_groups
        if !isnothing(get(pg_data, "entity_meta", nothing))
            push!(keep_existing, pg_name)
        end
    end

    # Helper: union of entity tags across a list of chopped 2D PG names.
    function _union_entity_tags(pg_names)
        entity_tags = Set{Int32}()
        for pg_name in pg_names
            SolidModels.hasgroup(sm, pg_name, 2) || continue
            for t in SolidModels.entitytags(sm[pg_name, 2])
                push!(entity_tags, t)
            end
        end
        return entity_tags
    end

    # Track which chopped PGs were absorbed and should be removed at the end.
    absorbed = Set{String}()

    # Pass 1: layers (skip METAL_CC and 3D layers).
    for (layer_name, layer_data) in layers
        layer_name == string(:METAL_CC) && continue
        get(layer_data, "dim", 2) == 2 || continue
        pg_names = get(layer_data, "pgs", String[])
        entity_tags = _union_entity_tags(pg_names)
        isempty(entity_tags) && continue
        sm[layer_name] = [(Int32(2), t) for t in sort!(collect(entity_tags))]
        for pg_name in pg_names
            pg_name in keep_existing && continue
            push!(absorbed, pg_name)
        end
    end

    # Pass 2: terminals (one PG per CC, named after the locators).
    for (cc_name, cc_data) in terminals
        pg_names = get(cc_data, "pgs", String[])
        locators = get(cc_data, "locators", String[])
        if isempty(locators)
            @warn "Terminal CC '$cc_name' has no locators; skipping in viz remap."
            continue
        end
        if isempty(pg_names)
            @warn "Terminal CC '$cc_name' has no PGs; skipping in viz remap."
            continue
        end
        entity_tags = _union_entity_tags(pg_names)
        isempty(entity_tags) && continue
        new_name = "TERMINAL_" * join(locators, "+")
        sm[new_name] = [(Int32(2), t) for t in sort!(collect(entity_tags))]
        for pg_name in pg_names
            pg_name in keep_existing && continue
            push!(absorbed, pg_name)
        end
    end

    # Pass 3: ground (single GROUND PG covering all ground CCs).
    ground_entity_tags = Set{Int32}()
    for (cc_name, cc_data) in ground
        pg_names = get(cc_data, "pgs", String[])
        if isempty(pg_names)
            @warn "Ground CC '$cc_name' has no PGs; skipping in viz remap."
            continue
        end
        union!(ground_entity_tags, _union_entity_tags(pg_names))
        for pg_name in pg_names
            pg_name in keep_existing && continue
            push!(absorbed, pg_name)
        end
    end
    if !isempty(ground_entity_tags)
        sm["GROUND"] = [(Int32(2), t) for t in sort!(collect(ground_entity_tags))]
    end

    # Pass 4: tagged (one PG per tag, named TAG_<tag_name>).
    for (tag_name, tag_data) in tagged
        pg_names = get(tag_data, "pgs", String[])
        if isempty(pg_names)
            @warn "Tag '$tag_name' has no PGs; skipping in viz remap."
            continue
        end
        entity_tags = _union_entity_tags(pg_names)
        isempty(entity_tags) && continue
        sm["TAG_" * tag_name] = [(Int32(2), t) for t in sort!(collect(entity_tags))]
        for pg_name in pg_names
            pg_name in keep_existing && continue
            push!(absorbed, pg_name)
        end
    end

    # Pass 5: PGs with non-null entity_meta are already readable — no-op.

    # Remove the absorbed chopped PGs (record only, leaving entities alone).
    for pg_name in absorbed
        SolidModels.hasgroup(sm, pg_name, 2) || continue
        SolidModels.remove_group!(sm, pg_name, 2; recursive=false, remove_entities=false)
    end

    return sm
end

"""
    _warn_potential_overlaps(registry::Registry, stack::SourceStack)

Emit warnings for 3D source layers with non-NULL material that remain in the final
registry and have overlapping z-ranges. This pattern often leads to overlapping volumes
that crash the OCC kernel during fragmentation.
"""
function _warn_potential_overlaps(registry::Registry, stack::SourceStack)
    # Collect all 3D source layers with material in the final registry
    extruded_source_layers = Set{Symbol}()
    for (layer_name, state) in registry
        state.dim == 3 || continue
        haskey(stack.layers, layer_name) || continue
        stack.layers[layer_name].material == NULL && continue
        push!(extruded_source_layers, layer_name)
    end

    length(extruded_source_layers) < 2 && return nothing

    # Compute actual z-ranges using pair-derived thickness when needed.
    layer_z_ranges = Dict{Symbol, Tuple{Float64, Float64}}()
    for layer_name in extruded_source_layers
        source_layer = stack.layers[layer_name]
        z_base = SolidModels._stp_float(layer_z(layer_name, stack))
        dz = SolidModels._stp_float(thickness(source_layer, stack))
        z_min = min(z_base, z_base + dz)
        z_max = max(z_base, z_base + dz)
        layer_z_ranges[layer_name] = (z_min, z_max)
    end

    for layer_a in extruded_source_layers
        za_min, za_max = layer_z_ranges[layer_a]
        for layer_b in extruded_source_layers
            layer_b <= layer_a && continue
            zb_min, zb_max = layer_z_ranges[layer_b]
            if za_min <= zb_max && zb_min <= za_max
                @warn "Layers $layer_a and $layer_b are both 3D volumes with overlapping " *
                      "z-ranges that remain in the final registry. If they occupy the " *
                      "same spatial region, one must be subtracted from the other to " *
                      "avoid OCC geometry failures."
            end
        end
    end

    return nothing
end
