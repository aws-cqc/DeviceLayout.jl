function _execute_deferred_interfaces!(
    sm::SolidModel,
    deferred_interfaces::Vector{DeferredInterface}
)
    isempty(deferred_interfaces) && return nothing

    for di in deferred_interfaces
        obj_dim, tool_dim = di.obj_dim, di.tool_dim

        if obj_dim == tool_dim
            # Same-dim: shared boundary entities (dim-1) between adjacent groups
            dim = obj_dim
            bdy_dim = dim - 1
            if !SolidModels.hasgroup(sm, di.obj_pg_name, dim)
                continue
            end
            if !SolidModels.hasgroup(sm, di.tool_pg_name, dim)
                continue
            end

            obj_dts = SolidModels.dimtags(sm[di.obj_pg_name, dim])
            tool_dts = SolidModels.dimtags(sm[di.tool_pg_name, dim])
            obj_bdy = SolidModels.gmsh.model.getBoundary(obj_dts, false, false, false)
            tool_bdy = SolidModels.gmsh.model.getBoundary(tool_dts, false, false, false)
            obj_bdy_tags = Set(abs(t) for (d, t) in obj_bdy if d == bdy_dim)
            tool_bdy_tags = Set(abs(t) for (d, t) in tool_bdy if d == bdy_dim)

            interface_tags = intersect(obj_bdy_tags, tool_bdy_tags)
            if !isempty(interface_tags)
                sm[di.dest_name] =
                    Tuple{Int32, Int32}[(Int32(bdy_dim), Int32(t)) for t in interface_tags]
            end
        else
            # Mixed-dim: lo-dim entities that are boundary faces of hi-dim entities
            lo_dim = min(obj_dim, tool_dim)
            hi_dim = max(obj_dim, tool_dim)

            lo_name = obj_dim <= tool_dim ? di.obj_pg_name : di.tool_pg_name
            hi_name = obj_dim <= tool_dim ? di.tool_pg_name : di.obj_pg_name

            if !SolidModels.hasgroup(sm, lo_name, lo_dim)
                continue
            end
            if !SolidModels.hasgroup(sm, hi_name, hi_dim)
                continue
            end

            lo_tags = Set(SolidModels.entitytags(sm[lo_name, lo_dim]))
            hi_dts = SolidModels.dimtags(sm[hi_name, hi_dim])
            bdy = SolidModels.gmsh.model.getBoundary(hi_dts, false, false, false)
            bdy_tags = Set(abs(t) for (d, t) in bdy if d == lo_dim)

            interface_tags = intersect(lo_tags, bdy_tags)
            if !isempty(interface_tags)
                sm[di.dest_name] =
                    Tuple{Int32, Int32}[(Int32(lo_dim), Int32(t)) for t in interface_tags]
            end
        end
    end

    return nothing
end

# ─── 2D PG deduplication ─────────────────────────────────────────────────────────────────

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
        for pgr in state.pgs
            pg_to_layer[pgr.name] = layer_name
        end
    end

    entity_layers = Dict{Int32, Set{Symbol}}()  # entity tag → set of layers
    for (pg_name, pg) in SolidModels.dimgroupdict(sm, 2)
        layer = get(pg_to_layer, pg_name, nothing)
        layer === nothing && continue
        for t in SolidModels.entitytags(pg)
            layers_set = get!(Set{Symbol}, entity_layers, t)
            push!(layers_set, layer)
        end
    end

    # Phase 2: For each PG, group entities by membership signature.
    # Identify which PGs need splitting.
    # signature = sorted tuple of layers (frozen for use as dict key)
    Signature = Vector{Symbol}

    pgs_to_split = Dict{String, Dict{Signature, Vector{Int32}}}()
    for (pg_name, pg) in SolidModels.dimgroupdict(sm, 2)
        haskey(pg_to_layer, pg_name) || continue
        tags = SolidModels.entitytags(pg)
        isempty(tags) && continue

        groups = Dict{Signature, Vector{Int32}}()
        for t in tags
            sig = sort(collect(get(entity_layers, t, Set{Symbol}())))
            tag_list = get!(Vector{Int32}, groups, sig)
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

        for (sig, tags) in groups
            if length(sig) == 1 && sig[1] == pg_layer && length(groups) > 1
                # Residual: entities exclusive to this PG's own layer — keep original name
                sub_name = pg_name
            else
                # Shared or foreign: generate a content-addressed name
                dimtags_str = join(sort(["2,$(t)" for t in tags]), "&")
                digest = sha1(Vector{UInt8}(dimtags_str))
                sub_name = "__" * bytes2hex(digest)[1:16]
            end
            push!(sub_pgs, (sub_name, sig))

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

        for (sub_name, sig) in sub_pgs
            # Create a PGRecord for the sub-PG
            sub_record = PGRecord(sub_name, original_layer, nothing)

            for layer_name in sig
                !haskey(registry, layer_name) && continue
                registry[layer_name].dim != 2 && continue
                # Avoid duplicates
                any(r -> r.name == sub_name, registry[layer_name].pgs) && continue
                push!(registry[layer_name].pgs, sub_record)
            end
        end

        # Remove the original PG from registry if it was fully replaced
        if !any(name == original_pg_name for (name, _) in sub_pgs)
            if haskey(registry, original_layer)
                filter!(r -> r.name != original_pg_name, registry[original_layer].pgs)
            end
        end
    end

    return split_results
end

# ─── restrict_to_volume! ──────────────────────────────────────────────────────────────────

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
    _extract_locator_positions(cs, stack, levels) -> Vector{LocatorRecord}

Extract one locator record per transformed reference occurrence without flattening `cs`.
Locator geometry is excluded from the mesh but remains visible to this discovery pass.
"""
function _extract_locator_positions(
    cs,
    stack::SourceStack,
    levels::StackLevels
)::Vector{LocatorRecord}
    records = LocatorRecord[]
    for (structure, transformation) in DeviceLayout.traversal(cs)
        for (meta, elem) in zip(element_metadata(structure), elements(structure))
            meta isa EntityMeta || continue
            meta.role isa Locator || continue
            meta.role isa Terminal && isempty(meta.name) && continue
            meta.role isa Tag &&
                isempty(meta.name) &&
                throw(ArgumentError("Tag locators must have a nonempty name"))
            source_layer = _require_source_layer(stack, meta; context="locator")
            source_layer.solidmodel || continue
            global_elem = transformation(elem)
            ctr = center(bounds(global_elem))
            cx = _micron_value(getx(ctr))
            cy = _micron_value(gety(ctr))
            z = _micron_value(
                _stack_z(levels[first_level(source_layer)], first_height(source_layer))
            )
            push!(
                records,
                LocatorRecord(meta.name, meta.index, meta.role, meta.layer, cx, cy, z)
            )
        end
    end
    return records
end

"""
    find_terminals(sm::SolidModel, registry::Registry, stack::SourceStack, locators::Vector{LocatorRecord})

Identify electrostatic terminals and ground via connected components of metal surfaces.
Locator positions are matched to CCs using exact point-in-surface queries
(`gmsh.model.isInside`). Ground is identified by the `Ground` locator (required).
CCs with no locators at all emit a warning.

Returns a named tuple `(terminals, ground)` where:

  - `terminals::Dict{String, Vector{String}}`: CC name → locator tags (non-ground CCs only)
  - `ground::Vector{String}`: CC names designated as ground
"""
function find_terminals(
    sm::SolidModel,
    registry::Registry,
    stack::SourceStack,
    locators::Vector{LocatorRecord}
)
    empty_result = (terminals=Dict{String, Vector{String}}(), ground=String[])

    # Collect all 2D PGs whose layer material is METAL (including Tag PGs, which
    # are real mesh entities; only Terminal/Ground locators are excluded)
    metal_pg_names = String[]
    for (layer_name, state) in registry
        !haskey(stack, layer_name) && continue
        sl = stack[layer_name]
        sl.material != METAL && continue
        state.dim != 2 && continue
        for pgr in state.pgs
            if pgr.entity_meta !== nothing
                role = pgr.entity_meta.role
                (role isa Terminal || role isa Ground) && continue
            end
            push!(metal_pg_names, pgr.name)
        end
    end

    isempty(metal_pg_names) && return empty_result

    ccs = SolidModels.connected_components(sm, metal_pg_names)

    # Build a map from surface entity tag -> CC index
    tag_to_cc = Dict{Tuple{Int32, Int32}, Int}()
    for (i, cc) in enumerate(ccs)
        for dt in cc
            tag_to_cc[dt] = i
        end
    end

    # For each CC, compute a hash name and assign PG
    cc_names = Vector{String}(undef, length(ccs))
    all_ccs = Dict{String, Vector{String}}()
    for (i, cc) in enumerate(ccs)
        cc_str = join(sort(["$(d),$(t)" for (d, t) in cc]), "&")
        digest = sha1(Vector{UInt8}(cc_str))
        ccn = string(_METAL_CC_LAYER) * "__" * bytes2hex(digest)[1:16]
        cc_names[i] = ccn
        sm[ccn] = cc
        all_ccs[ccn] = String[]
    end

    # Assign locator tags to CCs using gmsh.model.isInside for exact point-in-surface
    # geometric queries. For each locator, find the single coplanar entity that contains
    # its center point, then tag that entity's CC.
    # Only Terminal and Ground locators participate (Tags are handled by _resolve_tag_locators!).
    ground_cc_indices = Set{Int}()
    terminal_locators =
        filter(loc -> loc.role isa Terminal || loc.role isa Ground, locators)
    for loc in terminal_locators
        found_cc = 0
        n_hits = 0
        for (dt, cc_idx) in tag_to_cc
            dim, tag = dt
            bb = SolidModels.gmsh.model.getBoundingBox(Int(dim), Int(tag))
            xmin, ymin, zmin, xmax, ymax, zmax = bb
            # Only match horizontal (flat) surfaces coplanar with the locator
            z_tol = 1e-6
            (abs(zmax - zmin) < z_tol && abs(zmin - loc.z) < z_tol) || continue
            n = SolidModels.gmsh.model.isInside(
                Int(dim),
                Int(tag),
                [loc.center_x, loc.center_y, loc.z]
            )
            if n > 0
                n_hits += 1
                found_cc = cc_idx
            end
        end
        if n_hits > 1
            error(
                "Locator '$(loc.name)' at ($(loc.center_x), $(loc.center_y), $(loc.z)) " *
                "matched $n_hits entities; expected exactly 1 on a fragmented plane"
            )
        end
        if found_cc > 0
            if loc.role isa Ground
                push!(ground_cc_indices, found_cc)
            else
                push!(all_ccs[cc_names[found_cc]], loc.name)
            end
        end
    end

    # Partition into terminals and ground
    terminals = Dict{String, Vector{String}}()
    ground = String[]
    for (i, ccn) in enumerate(cc_names)
        if i in ground_cc_indices
            push!(ground, ccn)
        else
            if isempty(all_ccs[ccn])
                @warn "Metal CC '$ccn' has no locators (neither Terminal nor Ground). " *
                      "Did you forget a Ground locator?"
            end
            terminals[ccn] = all_ccs[ccn]
        end
    end

    return (; terminals, ground)
end

# ═══════════════════════════════════════════════════════════════════════════════════════════
# Tag locator resolution
# ═══════════════════════════════════════════════════════════════════════════════════════════

"""
    _resolve_tag_locators!(sm, registry, locators, deferred_interfaces, interfaces)

After fragmentation, resolve Tag locators by finding the 2D surface entity that
contains each locator's center point and creating a dedicated PG for it. The PG
is named using `map_meta` with the Tag locator's layer, name, and index, and is
registered in the final registry under the locator's layer.

For each Tag PG, any pending deferred interfaces whose object references the parent
PG are duplicated with the Tag PG as object, so that `_execute_deferred_interfaces!`
naturally produces per-Tag interface PGs via the cross product.
"""
function _resolve_tag_locators!(
    sm::SolidModel,
    registry::Registry,
    locators::Vector{LocatorRecord},
    deferred_interfaces::Vector{DeferredInterface},
    interfaces::Dict{String, Tuple{String, String}}
)
    tag_locators = filter(loc -> loc.role isa Tag, locators)
    isempty(tag_locators) && return nothing

    for loc in tag_locators
        # A Tag is meaningful only within its declared source layer. Searching all 2D
        # groups could attach it to an unrelated coplanar or overlapping layer.
        haskey(registry, loc.layer) || continue
        layer_state = registry[loc.layer]
        layer_state.dim == 2 || continue
        layer_tags = Set{Int32}()
        for record in layer_state.pgs
            SolidModels.hasgroup(sm, record.name, 2) || continue
            union!(layer_tags, SolidModels.entitytags(sm[record.name, 2]))
        end

        found_tag = Int32(0)
        n_hits = 0
        for tag in layer_tags
            bb = SolidModels.gmsh.model.getBoundingBox(2, Int(tag))
            xmin, ymin, zmin, xmax, ymax, zmax = bb
            z_tol = 1e-6
            (abs(zmax - zmin) < z_tol && abs(zmin - loc.z) < z_tol) || continue
            n = SolidModels.gmsh.model.isInside(
                2,
                Int(tag),
                [loc.center_x, loc.center_y, loc.z]
            )
            if n > 0
                n_hits += 1
                found_tag = tag
            end
        end
        if n_hits > 1
            error(
                "Tag locator '$(loc.name)' at ($(loc.center_x), $(loc.center_y), $(loc.z)) " *
                "matched $n_hits entities; expected exactly 1 on a fragmented plane"
            )
        end
        if found_tag == 0
            @warn "Tag locator '$(loc.name)' at ($(loc.center_x), $(loc.center_y), $(loc.z)) " *
                  "did not match any 2D entity"
            continue
        end

        meta = EntityMeta(loc.layer; name=loc.name, index=loc.index, role=Tag())
        pg_name = map_meta(meta)

        # Create PG in the solid model
        sm[pg_name] = Tuple{Int32, Int32}[(Int32(2), found_tag)]

        # Remove tagged entity from all other 2D PGs on the same layer and
        # duplicate deferred interfaces for the Tag PG
        parent_pg_names = String[]
        if haskey(registry, loc.layer) && registry[loc.layer].dim == 2
            for pgr in registry[loc.layer].pgs
                SolidModels.hasgroup(sm, pgr.name, 2) || continue
                existing_dts = SolidModels.dimtags(sm[pgr.name, 2])
                filtered = filter(dt -> dt[2] != found_tag, existing_dts)
                if length(filtered) < length(existing_dts)
                    sm[pgr.name] = filtered
                    push!(parent_pg_names, pgr.name)
                end
            end
        end

        # For each deferred interface that references a parent PG as object,
        # add a parallel entry with the Tag PG as object
        for parent_name in parent_pg_names
            for di in copy(deferred_interfaces)
                if di.obj_pg_name == parent_name
                    dest_layer = _find_pg_layer(di.dest_name, registry)
                    dest_layer === nothing && continue
                    new_dest = generated_pg_name(
                        dest_layer,
                        pg_name,
                        [di.tool_pg_name];
                        operation=:intersect,
                        parameters=(di.obj_dim, di.tool_dim)
                    )
                    _generated_record_exists(registry, dest_layer, new_dest) && continue
                    push!(
                        deferred_interfaces,
                        DeferredInterface(
                            new_dest,
                            pg_name,
                            di.tool_pg_name,
                            di.obj_dim,
                            di.tool_dim
                        )
                    )
                    # Register in the interface layer
                    new_record = PGRecord(new_dest, dest_layer, nothing)
                    push!(registry[dest_layer].pgs, new_record)
                    interfaces[new_dest] = (pg_name, di.tool_pg_name)
                end
            end
        end

        # Register in the final registry
        record = PGRecord(pg_name, loc.layer, meta)
        if haskey(registry, loc.layer)
            push!(registry[loc.layer].pgs, record)
        else
            registry[loc.layer] = LayerState([record], 2)
        end
    end

    return nothing
end

function _find_pg_layer(pg_name::String, registry::Registry)::Union{Symbol, Nothing}
    for (layer_name, state) in registry
        any(record -> record.name == pg_name, state.pgs) && return layer_name
    end
    return nothing
end

function _resolve_split_pgs(
    pg_name::String,
    split_results::Dict,
    sm::SolidModel
)::Vector{String}
    if haskey(split_results, pg_name)
        return String[
            name for
            (name, _) in split_results[pg_name] if SolidModels.hasgroup(sm, name, 2)
        ]
    elseif SolidModels.hasgroup(sm, pg_name, 2)
        return [pg_name]
    else
        return String[]
    end
end

"""
Find which current 2D PGs contain entities exclusively from a specific CC.

If a PG contains entities from multiple CCs, it is split first so that each CC
gets its own dedicated sub-PG. This ensures no PG tag appears in multiple
terminal/ground entries.
"""
function _resolve_entity_pgs(
    cc_entity_tags::Dict{String, Vector{Int32}},
    cc_name::String,
    sm::SolidModel
)::Vector{String}
    !haskey(cc_entity_tags, cc_name) && return String[]
    # First call triggers a one-time split of any PGs shared between CCs.
    # Use a closure-captured cache to avoid re-splitting on subsequent calls.
    # (Handled at the call site via _split_shared_cc_pgs! instead.)
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
Split any 2D PG that contains entities from multiple CCs into per-CC sub-PGs.
"""
function _split_shared_cc_pgs!(sm::SolidModel, cc_entity_tags::Dict{String, Vector{Int32}})
    # Build entity → CC name map
    entity_to_cc = Dict{Int32, String}()
    for (cc_name, tags) in cc_entity_tags
        for t in tags
            entity_to_cc[t] = cc_name
        end
    end

    all_cc_entities = Set(keys(entity_to_cc))

    # Find PGs that contain entities from multiple CCs
    for (pg_name, pg) in collect(SolidModels.dimgroupdict(sm, 2))
        pg_tags = SolidModels.entitytags(pg)
        # Group this PG's entities by which CC they belong to
        cc_groups = Dict{String, Vector{Int32}}()
        non_cc_tags = Int32[]
        for t in pg_tags
            cc = get(entity_to_cc, t, nothing)
            if cc !== nothing
                push!(get!(Vector{Int32}, cc_groups, cc), t)
            else
                push!(non_cc_tags, t)
            end
        end

        # If entities from 2+ CCs are in this PG, split it
        length(cc_groups) <= 1 && continue

        # Keep non-CC entities + first CC's entities in the original PG
        cc_names_sorted = sort(collect(keys(cc_groups)))
        keep_cc = cc_names_sorted[1]
        keep_tags = vcat(non_cc_tags, cc_groups[keep_cc])
        sm[pg_name] = Tuple{Int32, Int32}[(Int32(2), t) for t in keep_tags]

        # Create new sub-PGs for remaining CCs
        for cc in cc_names_sorted[2:end]
            tags = cc_groups[cc]
            dimtags_str = join(sort(["2,$(t)" for t in tags]), "&")
            digest = sha1(Vector{UInt8}(dimtags_str))
            sub_name = "__" * bytes2hex(digest)[1:16]
            sm[sub_name] = Tuple{Int32, Int32}[(Int32(2), t) for t in tags]
        end
    end
end

"""
    remap_to_visualization_pgs!(sm::SolidModel, sm_metadata::Dict)

Replace the chopped 2D physical groups in `sm` with a smaller set of human-
readable PGs derived from `sm_metadata`. Intended for `.viz.msh2` exports
opened in the gmsh GUI; the resulting model is **not** Palace-compatible
(entities will belong to multiple PGs, producing duplicated element lines).

Five passes (in order) collect entities from chopped PGs and union them
into new named PGs:

 1. one PG per `metadata.layers` entry (skipping `METAL_CC`), named after
    the layer
 2. one PG per `metadata.terminals` entry, named
    `TERMINAL_<loc1>+<loc2>+...`
 3. a single `GROUND` PG covering all `metadata.ground` entries
 4. one PG per `metadata.tagged` entry, named `TAG_<tag_name>`
 5. one PG per `metadata.physical_groups` entry whose `entity_meta` is
    non-null — the original PG already carries useful info, so the
    existing PG is left in place

After the new PGs are added, every chopped sub-PG (those whose record was
absorbed into a layer/terminal/etc. PG and whose original name carries no
information) is removed via `SolidModels.remove_group!` with
`recursive=false, remove_entities=false`. The mesh entities themselves are
never touched.
"""
function remap_to_visualization_pgs!(sm::SolidModels.SolidModel, sm_metadata::Dict)
    layers = get(sm_metadata, "layers", Dict{String, Any}())
    terminals = get(sm_metadata, "terminals", Dict{String, Any}())
    ground = get(sm_metadata, "ground", Dict{String, Any}())
    tagged = get(sm_metadata, "tagged", Dict{String, Any}())
    physical_groups = get(sm_metadata, "physical_groups", Dict{String, Any}())

    # PGs whose entity_meta is non-null already have useful names — keep them
    # in place and never remove them.
    keep_existing = Set{String}()
    for (pg_name, pg_data) in physical_groups
        if get(pg_data, "entity_meta", nothing) !== nothing
            push!(keep_existing, pg_name)
        end
    end

    # Helper: union of entity tags across a list of chopped 2D PG names.
    function _union_entities(pg_names)
        ets = Set{Int32}()
        for pg_name in pg_names
            SolidModels.hasgroup(sm, pg_name, 2) || continue
            for t in SolidModels.entitytags(sm[pg_name, 2])
                push!(ets, t)
            end
        end
        return ets
    end

    # Track which chopped PGs were absorbed and should be removed at the end.
    absorbed = Set{String}()

    # Pass 1: layers (skip METAL_CC and 3D layers).
    for (layer_name, layer_data) in layers
        layer_name == string(_METAL_CC_LAYER) && continue
        get(layer_data, "dim", 2) == 2 || continue
        pg_names = get(layer_data, "pgs", String[])
        ets = _union_entities(pg_names)
        isempty(ets) && continue
        sm[layer_name] = [(Int32(2), t) for t in sort!(collect(ets))]
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
        ets = _union_entities(pg_names)
        isempty(ets) && continue
        new_name = "TERMINAL_" * join(locators, "+")
        sm[new_name] = [(Int32(2), t) for t in sort!(collect(ets))]
        for pg_name in pg_names
            pg_name in keep_existing && continue
            push!(absorbed, pg_name)
        end
    end

    # Pass 3: ground (single GROUND PG covering all ground CCs).
    ground_ets = Set{Int32}()
    for (cc_name, cc_data) in ground
        pg_names = get(cc_data, "pgs", String[])
        if isempty(pg_names)
            @warn "Ground CC '$cc_name' has no PGs; skipping in viz remap."
            continue
        end
        union!(ground_ets, _union_entities(pg_names))
        for pg_name in pg_names
            pg_name in keep_existing && continue
            push!(absorbed, pg_name)
        end
    end
    if !isempty(ground_ets)
        sm["GROUND"] = [(Int32(2), t) for t in sort!(collect(ground_ets))]
    end

    # Pass 4: tagged (one PG per tag, named TAG_<tag_name>).
    for (tag_name, tag_data) in tagged
        pg_names = get(tag_data, "pgs", String[])
        if isempty(pg_names)
            @warn "Tag '$tag_name' has no PGs; skipping in viz remap."
            continue
        end
        ets = _union_entities(pg_names)
        isempty(ets) && continue
        sm["TAG_" * tag_name] = [(Int32(2), t) for t in sort!(collect(ets))]
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
    _warn_potential_overlaps(registry::Registry, stack::SourceStack, levels::StackLevels)

Emit warnings for 3D source layers with non-NULL material that remain in the final
registry and have overlapping z-ranges. This pattern often leads to overlapping volumes
that crash the OCC kernel during fragmentation.
"""
function _warn_potential_overlaps(
    registry::Registry,
    stack::SourceStack,
    levels::StackLevels
)
    # Collect all 3D source layers with material in the final registry
    extruded_source_layers = Set{Symbol}()
    for (layer_name, state) in registry
        state.dim == 3 || continue
        haskey(stack, layer_name) || continue
        stack[layer_name].material == NULL && continue
        push!(extruded_source_layers, layer_name)
    end

    length(extruded_source_layers) < 2 && return nothing

    # Compute actual z-ranges using resolve_thickness (handles level-pair syntax)
    layer_z_ranges = Dict{Symbol, Tuple{Float64, Float64}}()
    for ln in extruded_source_layers
        sl = stack[ln]
        z_base = _micron_value(_stack_z(levels[first_level(sl)], first_height(sl)))
        thick = _micron_value(resolve_thickness(sl, levels))
        z_min = min(z_base, z_base + thick)
        z_max = max(z_base, z_base + thick)
        layer_z_ranges[ln] = (z_min, z_max)
    end

    for ln_a in extruded_source_layers
        za_min, za_max = layer_z_ranges[ln_a]
        for ln_b in extruded_source_layers
            ln_b <= ln_a && continue
            zb_min, zb_max = layer_z_ranges[ln_b]
            if za_min <= zb_max && zb_min <= za_max
                @warn "Layers $ln_a and $ln_b are both 3D volumes with overlapping " *
                      "z-ranges that remain in the final registry. If they occupy the " *
                      "same spatial region, one must be subtracted from the other to " *
                      "avoid OCC geometry failures."
            end
        end
    end

    return nothing
end

# ═══════════════════════════════════════════════════════════════════════════════════════════
# Top-level render! method
# ═══════════════════════════════════════════════════════════════════════════════════════════
