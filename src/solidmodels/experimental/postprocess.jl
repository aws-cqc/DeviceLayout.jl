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
