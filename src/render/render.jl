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
    return text!(c, text, meta)
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

####### Rendering pathway through Curvilinear
function round_to_curvilinearpolygon(
    pol::GeometryEntity{T},
    radius::S;
    corner_indices=eachindex(points(pol)),
    line_arc_corner_indices=nothing,
    min_angle=1e-3,
    relative::Bool=(T <: Length) && (S <: Real),
    min_side_len=relative ? zero(T) : radius
) where {T, S <: Coordinate}
    # If radius is dimensional, non-relative rounding.
    V = float(T)
    # Tie break for Real, Real introduces a type instability for non-dimensional.
    relative = ((T <: Length) && (S <: Real)) || (relative && T <: Real && S <: Real)

    poly = points(pol)
    len = length(poly)
    new_points = Point{V}[]
    new_curves = Paths.Turn{V}[]
    new_curve_start_idx = Int[]

    for i in eachindex(poly)
        if !(i in corner_indices)
            push!(new_points, poly[i])
        else
            p0 = poly[mod1(i - 1, len)] # handles the cyclic boundary condition
            p1 = poly[i]
            p2 = poly[mod1(i + 1, len)]
            radius_dim = relative ? radius * min(norm(p0 - p1), norm(p1 - p2)) : radius
            seg_or_p1 = rounded_corner_segment(
                p0,
                p1,
                p2,
                radius_dim,
                min_side_len=min_side_len,
                min_angle=min_angle
            )
            if seg_or_p1 isa Paths.Turn
                push!(new_points, Paths.p0(seg_or_p1))
                push!(new_curves, seg_or_p1)
                push!(new_curve_start_idx, length(new_points))
                push!(new_points, Paths.p1(seg_or_p1))
            else
                push!(new_points, seg_or_p1)
            end
        end
    end

    return CurvilinearPolygon(new_points, new_curves, new_curve_start_idx)
end

function rounded_corner_segment(
    p0::Point{T},
    p1::Point{T},
    p2::Point{T},
    radius::S;
    min_side_len=radius,
    min_angle=1e-3
) where {T, S <: Coordinate}
    V = float(T)
    rad = convert(V, radius)

    v1 = (p1 - p0) / norm(p1 - p0)
    v2 = (p2 - p1) / norm(p2 - p1)
    α1 = atan(v1.y, v1.x) # between -π and π
    α2 = atan(v2.y, v2.x)

    if min_side_len > norm(p1 - p0) || min_side_len > norm(p2 - p1) # checks that the side lengths against min_side_len
        return p1
    elseif isapprox(rem2pi(α1 - α2, RoundNearest), 0, atol=min_angle) # checks if the points are collinear, within tolerance
        return p1
    end

    dir = orientation(p0, p1, p2) # checks the direction of the corner
    dα = α2 - α1 # always between +/- 2π
    if sign(dα) != dir # Make sure turn is in the correct direction
        dα = dα + dir * 2π # Still between +/- 2π
    end

    # p0_seg is the start of the arc, determined by the intersection
    # of lines parallel to v1, v2
    k =
        inv([v1.x -v2.x; v1.y -v2.y]) *
        [p2.x - p0.x + dir * rad * (v1.y - v2.y), p2.y - p0.y + dir * rad * (v2.x - v1.x)]
    p0_seg = p0 + k[1] * v1
    return Paths.Turn(uconvert(°, dα), rad, p0_seg, uconvert(°, α1))
end
