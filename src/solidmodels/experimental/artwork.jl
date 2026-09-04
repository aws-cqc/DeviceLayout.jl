import DeviceLayout: datatype, gdslayer

function _map_artwork_meta(
    stack::SourceStack,
    level_increment::GDSMeta,
    apply_increment::Bool
)
    return m -> begin
        source_layer = sourcelayer(m, stack)
        isnothing(source_layer.gds_meta) && return nothing
        apply_increment || return source_layer.gds_meta
        delta = first(source_layer.level) - 1
        return GDSMeta(
            gdslayer(source_layer.gds_meta) + delta * gdslayer(level_increment),
            datatype(source_layer.gds_meta) + delta * datatype(level_increment)
        )
    end
end

"""
    render!(
        cell,
        cs,
        stack::SourceStack;
        levels=[1],
        level_increment=GDSMeta(0, 0),
        kwargs...
    )

Render [`EntityMeta`](@ref) artwork using the GDS mapping stored in `stack`. Layers with
`gds_meta=nothing` are omitted independently of `solidmodel` visibility. Metadata indices
do not alter datatypes.
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
    apply_increment = length(levels) > 1
    map_meta = _map_artwork_meta(stack, level_increment, apply_increment)
    return DeviceLayout.render!(cell, cs; map_meta, kwargs...)
end
