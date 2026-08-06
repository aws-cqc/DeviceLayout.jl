function _map_artwork_meta(
    stack::SourceStack,
    levels,
    level_increment::GDSMeta,
    meta::EntityMeta
)::Union{GDSMeta, Nothing}
    source_layer = _require_source_layer(stack, meta; context="artwork EntityMeta")
    source_layer.gds_meta === nothing && return nothing
    source_level = first_level(source_layer)
    selected_index = findfirst(==(source_level), levels)
    selected_index === nothing && return nothing

    gds_meta = source_layer.gds_meta
    if length(levels) > 1
        delta = selected_index - 1
        return GDSMeta(
            gdslayer(gds_meta) + delta * gdslayer(level_increment),
            datatype(gds_meta) + delta * datatype(level_increment)
        )
    end
    return gds_meta
end
_map_artwork_meta(::SourceStack, levels, increment::GDSMeta, ::DeviceLayout.Meta) = nothing

"""
    render!(cell, cs, stack::SourceStack; levels=[1], level_increment=GDSMeta(0, 0), kwargs...)

Render `EntityMeta` artwork using the GDS mapping stored in `stack`. Layers with
`gds_meta === nothing` are omitted independently of `solidmodel` visibility. Metadata
indices do not alter datatypes.
"""
function render!(
    cell::DeviceLayout.Cell,
    cs,
    stack::SourceStack;
    levels=[1],
    level_increment=GDSMeta(0, 0),
    kwargs...
)
    selected_levels = collect(levels)
    isempty(selected_levels) &&
        throw(ArgumentError("levels must contain at least one level"))
    for meta in _entity_metas(cs)
        source_layer = _require_source_layer(stack, meta; context="artwork EntityMeta")
        first_level(source_layer) in selected_levels || continue
    end
    mapper = meta -> _map_artwork_meta(stack, selected_levels, level_increment, meta)
    return DeviceLayout.render!(cell, cs; map_meta=mapper, kwargs...)
end
