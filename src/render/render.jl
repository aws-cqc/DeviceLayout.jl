include("polygons.jl")
include("paths.jl")
include("corners.jl")
include("trace.jl")
include("cpw.jl")
include("decorated.jl")
include("compound.jl")
include("tapers.jl")
include("strands.jl")
include("termination.jl")
include("periodic.jl")

function uniquepoints(pts)
    return pts[.![i == 1 ? false : (pts[i] ≈ pts[max(1, i - 1)]) for i = 1:size(pts, 1)]]
end

function _map_render!(
    cell::Cell{S},
    obj::GeometryEntity,
    meta_obj::Meta;
    map_meta=default_meta_map,
    kwargs...
) where {S}
    isnothing(map_meta(meta_obj)) && return

    # Warn if using default mapping with non-GDSMeta
    if map_meta === default_meta_map && !(meta_obj isa GDSMeta)
        @warn "Automatically converting $(typeof(meta_obj)) to GDSMeta using hash-based mapping. " *
              "Layer $(layer(meta_obj)) → GDS layer $(gdslayer(default_meta_map(meta_obj))). " *
              "Provide explicit map_meta function or LayoutTarget to customize this behavior." _group =
            :render
    end

    mapped_meta = convert(GDSMeta, map_meta(meta_obj))
    return render!(cell, obj, mapped_meta; map_meta=map_meta, kwargs...)
end

function render!(
    cell::Cell{S},
    obj::GeometryEntity,
    meta::GDSMeta=GDSMeta();
    kwargs...
) where {S}
    render!.(cell, to_polygons(obj; kwargs...), meta; kwargs...)
    return cell
end

# Vectorize render
function render!(
    c::Cell{S},
    p,
    meta::Union{Vector{GDSMeta}, GDSMeta}=GDSMeta();
    kwargs...
) where {S}
    # Even polygons have to be rendered one by one in case of num_points > GDS_POLYGON_MAX, can't just append
    render!.(c, p, meta; kwargs...)
    return c
end

function render!(c::Cell{S}, text::Texts.Text, meta::GDSMeta=GDSMeta(); kwargs...) where {S}
    return text!(c, text, meta; kwargs...)
end

function render!(c::Cell{S}, text::Vector{Texts.Text{S}}, meta::Vector{GDSMeta}) where {S}
    return text!(c, text, meta) # Can just append
end

function render!(::Cell, ::Nothing; kwargs...) end
function render!(::Cell, ::Nothing, ::GDSMeta; kwargs...) end

function _render_elements!(
    cell::Cell,
    cs::GeometryStructure;
    memoized_cells=Dict{GeometryStructure, Cell}(),
    map_meta=default_meta_map,
    kwargs...
)
    return _map_render!.(
        cell,
        elements(cs),
        element_metadata(cs);
        map_meta=map_meta,
        memoized_cells=memoized_cells,
        kwargs...
    )
end

function _render!(
    cell::Cell{S},
    cs::GeometryStructure;
    memoized_cells=Dict{GeometryStructure, Cell}(),
    map_meta=default_meta_map,
    kwargs...
) where {S}
    stack = Vector{Tuple{Cell, GeometryReference}}()
    _render_elements!(cell, cs; map_meta=map_meta, memoized_cells=memoized_cells, kwargs...)

    for csr in refs(cs)
        push!(stack, (cell, csr))
    end
    while length(stack) > 0
        parentcell, cur_cs_ref = pop!(stack)
        cur_cs = structure(cur_cs_ref)

        already_seen = haskey(memoized_cells, cur_cs)
        # If it's a previously-seen CS, use the corresponding cell; otherwise, make a new one
        cur_cell = if already_seen
            memoized_cells[cur_cs]
        else
            Cell{S}(coordsys_name(cur_cs))
        end

        # If it's a new CS, render the contents, push refs to the stack, and add to memoized_cells
        if !already_seen
            try
                _render_elements!(
                    cur_cell,
                    cur_cs;
                    map_meta=map_meta,
                    memoized_cells=memoized_cells,
                    kwargs...
                )
            catch e
                @error "Failed to render structure $(name(cur_cs)) under $(name(parentcell))" exception =
                    (e, catch_backtrace()) _group = :render
            end
            try
                for csr in refs(cur_cs)
                    push!(stack, (cur_cell, csr))
                end
            catch e
                @error "Failed to render references in structure $(name(cur_cs)) under $(name(parentcell))" exception =
                    (e, catch_backtrace()) _group = :render
            end
            memoized_cells[cur_cs] = cur_cell
        end

        # Add a reference to the cell to the parent cell
        cur_cellref = if cur_cs_ref isa ArrayReference
            CellArray{S, typeof(cell)}(
                cur_cell,
                cur_cs_ref.origin,
                cur_cs_ref.deltacol,
                cur_cs_ref.deltarow,
                cur_cs_ref.col,
                cur_cs_ref.row,
                cur_cs_ref.xrefl,
                cur_cs_ref.mag,
                cur_cs_ref.rot
            )
        else
            CellReference{S, typeof(cell)}(
                cur_cell,
                origin(cur_cs_ref),
                xrefl(cur_cs_ref),
                mag(cur_cs_ref),
                rotation(cur_cs_ref)
            )
        end
        push!(parentcell.refs, cur_cellref)
    end
    memoized_cells[cs] = cell
    return cell
end

"""
    Cell(cs::CoordinateSystem{S}) = Cell{S}(cs)
    Cell(cs::CoordinateSystem, unit::CoordinateUnits) = Cell{typeof(1.0unit)}(cs)
    Cell{S}(cs::CoordinateSystem) where {S}

Construct a `Cell` from a `CoordinateSystem` by rendering its contents, reproducing the reference hierarchy.
"""
Cell(cs::CoordinateSystem{S}; kwargs...) where {S} = Cell{S}(cs; kwargs...)
Cell(cs::CoordinateSystem, unit::DeviceLayout.CoordinateUnits; kwargs...) =
    Cell{typeof(1.0unit)}(cs; kwargs...)
function Cell{S}(
    cs::CoordinateSystem;
    memoized_cells=Dict{GeometryStructure, Cell}(),
    kwargs...
) where {S}
    c = Cell{S}(cs.name)
    _render!(c, cs; memoized_cells=memoized_cells, kwargs...)
    return c
end

"""
    render!(cell::Cell{S}, cs::GeometryStructure;
        memoized_cells=Dict{GeometryStructure, Cell}(),
        map_meta = default_meta_map,
        kwargs...) where {S}

Render a geometry structure (e.g., `CoordinateSystem`) to a cell.

Passes each element and its metadata (mapped by `map_meta` if a method is supplied) to
`render!(::Cell, element, ::Meta)`,
traversing the references such that if a structure is referred to in multiple
places, it will become a single cell referred to in multiple places.

Rendering a `GeometryStructure` to a `Cell` uses the optional keyword arguments

  - `map_meta`, a function that takes a `Meta` object and returns a `GDSMeta` object
    (or `nothing`, in which case rendering is skipped). Defaults to [`DeviceLayout.default_meta_map`](@ref),
    which passes `GDSMeta` through unchanged. Other metadata types will be converted using hash-based
    layer assignment, but this conversion is provided for quick GDS viewing and should not be relied on
    in production workflows.
  - `memoized_cells`, a dictionary used internally to make sure that if a structure is referred to in multiple
    places, it will become a single cell referred to in multiple places. Calling this function with non-empty dictionary
    `memoized_cells = Dict{GeometryStructure, Cell}(geom => prerendered_cell)`
    is effectively a manual override that forces `geom` (which may be `cs` or any structure in
    its reference hierarchy) to render as `prerendered_cell`.

Additional keyword arguments are passed to [`to_polygons`](@ref) for each entity and may be used for
certain entity types to control how they are converted to polygons.
"""
render!(c::Cell, s::GeometryStructure; kwargs...) = _render!(c, s; kwargs...)
