function _map_artwork_meta(
    stack::SourceStack,
    levels,
    level_increment::GDSMeta,
    m::EntityMeta
)
    sl = _require_source_layer(stack, m; context="artwork EntityMeta")
    isnothing(sl.gds_meta) && return nothing
    source_level = first_level(sl)
    idx = findfirst(==(source_level), levels)
    isnothing(idx) && return nothing

    gds_meta = sl.gds_meta
    if length(levels) > 1
        delta = idx - 1
        return GDSMeta(
            gdslayer(gds_meta) + delta * gdslayer(level_increment),
            datatype(gds_meta) + delta * datatype(level_increment)
        )
    end
    return gds_meta
end
_map_artwork_meta(::SourceStack, ::Any, ::GDSMeta, ::DeviceLayout.Meta) = nothing

"""
    render!(
        cell,
        cs,
        stack::SourceStack;
        levels=[1],
        level_increment=GDSMeta(0, 0),
        kwargs...
    )

Render `EntityMeta` artwork using the GDS mapping stored in `stack`. Layers with
`isnothing(gds_meta)` are omitted independently of `solidmodel` visibility. Metadata
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
    for entity_meta in _entity_metas(cs)
        _require_source_layer(stack, entity_meta; context="artwork EntityMeta")
    end
    mapper =
        entity_meta ->
            _map_artwork_meta(stack, selected_levels, level_increment, entity_meta)
    return DeviceLayout.render!(cell, cs; map_meta=mapper, kwargs...)
end
