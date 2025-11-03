######## Rendering
import Clipper: children, contour, ishole, PolyNode
import Unitful: Length
import StaticArrays: SVector
import NearestNeighbors: nn

"""
    to_primitives(::SolidModel, ent::GeometryEntity; kwargs...)

Return a `GeometryEntity` or a vector of entities equivalent to `ent`.

Called inside `render!` before adding entities to the `SolidModel`. Each resulting entity
corresponds to a single entity in that `SolidModel`'s geometry kernel.

If there is no special handling for `ent` in the kernel, then the result will be
`to_polygons(ent; kwargs...)`.
"""
to_primitives(::SolidModel, ent::GeometryEntity; kwargs...) = to_polygons(ent; kwargs...)

# Types that together can use straight lines only
const LinearSegment{T} =
    Union{Paths.Straight{T}, Paths.ConstantOffset{T, Paths.Straight{T}}}
const LinearStyle =
    Union{Paths.SimpleTrace, Paths.SimpleCPW, Paths.TaperTrace, Paths.TaperCPW}
islinear(::LinearSegment{T}, ::LinearStyle) where {T} = Val(true)
islinear(::Paths.Segment{T}, ::Paths.Style) where {T} = Val(false)

# Dispatch node->primitive based on kernel and requirements for representing node exactly
function to_primitives(sm::SolidModel{OpenCascade}, node::Paths.Node; kwargs...)
    return to_primitives(sm, node, islinear(node.seg, node.sty); kwargs...)
end
function to_primitives(sm::SolidModel{GmshNative}, node::Paths.Node; kwargs...)
    return to_primitives(sm, node, Val(true); kwargs...)
end
# Path nodes that can be drawn with only polygons (in OCC) or all paths (GmshNative)
function to_primitives(::SolidModel, node::Paths.Node, ::Val{true}; kwargs...)
    return to_polygons(node.seg, node.sty; kwargs...)
end

to_primitives(sm::SolidModel, ent::StyledEntity{T, U, S}; kwargs...) where {T, U, S} =
    to_primitives(sm, ent.ent; kwargs...)
function to_primitives(
    sm::SolidModel{OpenCascade},
    ent::StyledEntity{T, U, S};
    kwargs...
) where {T, U, S <: Rounded}
    inner_prim = to_primitives(sm, ent.ent; kwargs...)
    if inner_prim isa Vector
        return to_primitives(sm, ent.sty.(inner_prim); kwargs...)
    end
    return to_primitives(sm, ent.sty(inner_prim); kwargs...)
end

function to_primitives(sm::SolidModel, ent::Vector{<:GeometryEntity}; kwargs...)
    return vcat(to_primitives.(sm, ent; kwargs...)...)
end

# Flatten the ClippedPolygon to a collection of non-overlapping CurvilinearRegion
function to_primitives(::SolidModel, ent::ClippedPolygon{T}; kwargs...) where {T}
    # Flatten the tree into a collection of CurvilinearRegion
    flat = CurvilinearRegion{T}[]
    function add_region(node)
        push!(flat, CurvilinearRegion(contour(node), contour.(node.children)))
        for n ∈ node.children
            add_region.(n.children) # Add all grand children -- positives
        end
    end
    add_region.(ent.tree.children)
    return flat
end

function to_primitives(
    ::SolidModel,
    ent::StyledEntity{T, ClippedPolygon{T}, <:StyleDict};
    kwargs...
) where {T}
    # Flatten the tree into a collection of CurvilinearRegion with style applied to subpolygons.
    flat = CurvilinearRegion{T}[]
    function add_region(node)
        push!(
            flat,
            CurvilinearRegion{T}(
                styled_loop(node, ent.sty[node]; kwargs...),
                styled_loop.(
                    node.children,
                    getindex.(Ref(ent.sty), node.children);
                    kwargs...
                )
            )
        )
        for n ∈ node.children
            add_region.(n.children) # Add all grand children -- positives
        end
    end
    add_region.(ent.ent.tree.children)
    return flat
end

function to_primitives(::SolidModel, ent::Ellipse; rounded=nothing, Δθ=nothing, kwargs...)
    if !isnothing(rounded)
        Base.depwarn(
            "The `rounded` keyword for Ellipse is deprecated. Use `Δθ=nothing` (default) to keep as ellipse primitive, or `Δθ=some_angle` to discretize to polygon. For the same discretization as `rounded=false` with `Δθ` not specified, use `Δθ=360°/8`",
            :to_primitives
        )
        rounded && return ent  # Keep as ellipse primitive
        # Otherwise, use the old default Δθ for backward compatibility
        return to_polygons(ent; Δθ=(isnothing(Δθ) ? 360° / 8 : Δθ), kwargs...)
    else
        isnothing(Δθ) && return ent  # Keep as ellipse primitive (default code path)
        # Otherwise, use specified Δθ
        return to_polygons(ent; Δθ, kwargs...)  # Discretize to polygon
    end
end

# Path nodes that can be drawn with native curves (in OCC)
# Gmsh does have its own native curves but we don't use them (the APIs and particularly
# spline representations are different)
function to_primitives(sm::SolidModel, node::Paths.Node, ::Val{false}; kwargs...)
    return to_primitives(sm, node.seg, node.sty; kwargs...)
end

# CurvilinearRegion is a primitive
to_primitives(::SolidModel, ent::CurvilinearPolygon; kwargs...) = CurvilinearRegion(ent)
to_primitives(::SolidModel, ent::CurvilinearRegion; kwargs...) = ent

# LineSegment is a primitive
to_primitives(::SolidModel, ent::LineSegment; kwards...) = ent

######## Optional Render
function to_primitives(
    sm::SolidModel,
    e::StyledEntity{T, U, NoRender};
    kwargs...
) where {T, U}
    return Polygon{T}[]
end

function to_primitives(
    sm::SolidModel,
    ent::StyledEntity{T, U, OptionalStyle};
    kwargs...
) where {T, U <: GeometryEntity}
    sty =
        get(kwargs, ent.sty.flag, ent.sty.default) ? ent.sty.true_style :
        ent.sty.false_style
    return to_primitives(sm, StyledEntity(ent.ent, sty); kwargs...)
end

######## Rounded polygons
# Rounded polygons
function to_primitives(
    ::SolidModel{OpenCascade},
    ent::StyledEntity{T, Polygon{T}, <:Rounded};
    kwargs...
) where {T}
    return CurvilinearRegion(
        round_to_curvilinearpolygon(
            ent.ent,
            radius(ent.sty),
            min_side_len=ent.sty.min_side_len,
            corner_indices=cornerindices(ent.ent, ent.sty),
            min_angle=ent.sty.min_angle
        )
    )
end

# Convert a single style to a style dict
function to_primitives(
    sm::SolidModel{OpenCascade},
    ent::StyledEntity{T, CurvilinearRegion{T}};
    kwargs...
) where {T}
    return to_primitives(sm, StyleDict(ent.sty)(ent.ent); kwargs...)
end

function to_primitives(
    ::SolidModel{OpenCascade},
    ent::StyledEntity{T, CurvilinearRegion{T}, <:StyleDict};
    kwargs...
) where {T}
    return CurvilinearRegion{T}(
        styled_loop(ent.ent.exterior, ent.sty[1]; kwargs...),
        styled_loop.(
            ent.ent.holes,
            getindex.(ent.sty, 1, 1:length(ent.ent.holes));
            kwargs...
        )
    )
end

function round_to_curvilinearpolygon(
    pol::GeometryEntity{T},
    radius::S;
    corner_indices = eachindex(points(pol)),
    min_angle      = 1e-3,
    relative::Bool = (T <: Length) && (S <: Real),
    min_side_len   = relative ? zero(T) : radius
)::CurvilinearPolygon{T} where {T, S <: Coordinate}
    # If radius is dimensional, non-relative rounding.
    V = ((S <: Length && T <: Length) || (S <: Real && T <: Real)) ? promote_type(T, S) : T
    # Tie break for Real, Real introduces a type instability for non-dimensional.
    relative = ((T <: Length) && (S <: Real)) || (relative && T <: Real && S <: Real)

    poly = points(pol)
    len = length(poly)
    new_points = Point{float(V)}[]
    new_curves = Paths.Turn{float(V)}[]
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

    if pol isa CurvilinearPolygon
        # Need to shift start indices for all old curves if new points were introduced
        # behind them by the additional curves. Need to do this iteratively, in case the
        # shifted point overtakes added in points.
        old_curve_start_idx = deepcopy(pol.curve_start_idx)
        for nci ∈ new_curve_start_idx
            old_curve_start_idx[old_curve_start_idx .>= nci] .+= 1
        end

        append!(new_curve_start_idx, old_curve_start_idx)
        append!(new_curves, pol.curves)
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
    V = promote_type(T, S)
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

######## Styled Polygon and CurvilinearPolygon

# Given a polygon and style, create a CurvilinearPolygon
styled_loop(p::Polygon, ::Plain; kwargs...) = CurvilinearPolygon(points(p))
styled_loop(::Polygon{T}, ::NoRender; kwargs...) where {T} = CurvilinearPolygon{T}([])
function styled_loop(p::GeometryEntity, sty::OptionalStyle; kwargs...)
    return styled_loop(
        p,
        get(kwargs, sty.flag, sty.default) ? sty.true_style : sty.false_style;
        kwargs...
    )
end
function styled_loop(p::GeometryEntity, sty::Rounded; kwargs...)
    return round_to_curvilinearpolygon(
        p,
        radius(sty),
        min_side_len=sty.min_side_len,
        corner_indices=cornerindices(p, sty),
        min_angle=sty.min_angle
    )
end
styled_loop(n, sty; kwargs...) = styled_loop(Polygon(contour(n)), sty; kwargs...)

styled_loop(l::CurvilinearPolygon, sty::Plain; kwargs...) = l
styled_loop(::CurvilinearPolygon{T}, ::NoRender; kwargs...) where {T} =
    CurvilinearPolygon{T}([])

######## Ellipse
function _add_to_current_solidmodel!(
    e::Ellipse{T},
    m::Meta,
    k;
    zmap=(_) -> zero(T),
    kwargs...
) where {T}
    z = zmap(m) # map from m using kwargs

    c = ustrip(STP_UNIT, center(e))
    line = k.add_ellipse(
        c[1],
        c[2],
        ustrip(STP_UNIT, z),
        ustrip(STP_UNIT, r1(e)),
        ustrip(STP_UNIT, r2(e)),
        -1,
        0.0,
        2 * π,
        [0.0, 0.0, 1.0],
        [cos(angle(e)), sin(angle(e)), 0.0]
    )
    loop = k.add_curve_loop([line])
    surf = k.add_plane_surface([loop])

    return (Int32(2), surf)
end

######## Path nodes to primitives
# Note: this is called during SolidModel rendering after flattening, so we don't worry about decorations
# Similarly generic tapers have been resolved

# Fallback: use pathtopolys to get CurvilinearPolygons
function to_primitives(
    ::SolidModel,
    f::Paths.Segment{T},
    s::Paths.Style;
    kwargs...
) where {T}
    return pathtopolys(f, s; kwargs...)
end

# Need this so we don't send `Rounded` from termination to `pathtopolys`
function to_primitives(
    sm::SolidModel,
    f::Paths.CompoundSegment{T},
    s::Paths.CompoundStyle;
    kwargs...
) where {T}
    return vcat(to_primitives.(sm, f.segments, s.styles; kwargs...)...)
end

# Terminations generate up to two [Rounded] Polygons
function to_primitives(
    sm::SolidModel,
    seg::Paths.Segment{T},
    sty::Union{Paths.TraceTermination, Paths.CPWOpenTermination, Paths.CPWShortTermination};
    kwargs...
) where {T}
    return to_primitives(sm, DeviceLayout._poly(seg, sty); kwargs...)
end

meshsize(::GeometryEntity{T}; kwargs...) where {T} = float(ustrip(STP_UNIT, zero(T)))
meshsize(::GeometryEntity{<:Real}; kwargs...) = 0.0
meshsize(ent::StyledEntity{T, StyledEntity{T, R, U}, S}; kwargs...) where {T, R, U, S} =
    meshsize(ent.ent; kwargs...)
# Always choose outermost MeshSized
meshsize(
    ent::StyledEntity{T, StyledEntity{T, R, U}, S};
    kwargs...
) where {T, R, U, S <: MeshSized} = meshsize(ent.sty; kwargs...)
meshsize(ent::StyledEntity; kwargs...) = meshsize(ent.sty; kwargs...)
meshsize(s::GeometryEntityStyle; kwargs...) = 0.0
meshsize(s::MeshSized{T}; kwargs...) where {T} = ustrip(STP_UNIT, s.h)
meshsize(s::OptionalStyle; kwargs...) =
    get(kwargs, s.flag, s.default) ? meshsize(s.true_style; kwargs...) :
    meshsize(s.false_style; kwargs...)
# Path node mesh depends only on style
meshsize(node::Paths.Node{T}; kwargs...) where {T} =
    ustrip(STP_UNIT, meshsize(node.seg, node.sty; kwargs...))
meshsize(node::Paths.Node{<:Real}; kwargs...) = meshsize(node.seg, node.sty; kwargs...)
# Various path styles
meshsize(seg::Paths.Segment, ::Paths.Style; kwargs...) = zero(eltype(seg))
meshsize(::Paths.Segment, sty::Paths.SimpleTrace; kwargs...) = 2 * sty.width
meshsize(::Paths.Segment, sty::Paths.SimpleCPW; kwargs...) = 2 * max(sty.trace, sty.gap)
meshsize(::Paths.Segment, sty::Paths.TaperTrace; kwargs...) =
    2 * max(sty.width_start, sty.width_end)
meshsize(::Paths.Segment, sty::Paths.TaperCPW; kwargs...) =
    2 * max(sty.trace_start, sty.trace_end, sty.gap_start, sty.gap_end)
# For GeneralCPW and GeneralTrace, just sample.
function meshsize(seg::Paths.Segment, sty::Paths.GeneralTrace; kwargs...)
    l = pathlength(seg)
    return maximum(sty.width.(range(zero(l), l, length=11)))
end
function meshsize(seg::Paths.Segment, sty::Paths.GeneralCPW; kwargs...)
    l = pathlength(seg)
    maxtrace = maximum(sty.trace.(range(zero(l), l, length=11)))
    maxgap = maximum(sty.gap.(range(zero(l), l, length=11)))
    return 2 * max(maxtrace, maxgap)
end
# Compound
function meshsize(seg::Paths.CompoundSegment, sty::Paths.CompoundStyle; kwargs...)
    return maximum(meshsize.(seg.segments, sty.styles))
end
# There should be no DecoratedStyles at SolidModel rendering
meshgrading(::GeometryEntity{T}; kwargs...) where {T} = -1.0
meshgrading(ent::StyledEntity{T, StyledEntity{T, R, U}, S}; kwargs...) where {T, R, U, S} =
    meshgrading(ent.ent; kwargs...)
# Always choose outermost MeshSized
meshgrading(
    ent::StyledEntity{T, StyledEntity{T, R, U}, S};
    kwargs...
) where {T, R, U, S <: MeshSized} = meshgrading(ent.sty; kwargs...)
meshgrading(ent::StyledEntity; kwargs...) = meshgrading(ent.sty; kwargs...)
meshgrading(::GeometryEntityStyle; kwargs...) = -1.0
meshgrading(s::OptionalStyle; kwargs...) =
    get(kwargs, s.flag, s.default) ? meshgrading(s.true_style; kwargs...) :
    meshgrading(s.false_style; kwargs...)
meshgrading(s::MeshSized{T}; kwargs...) where {T} = s.α
# All paths default to background grading
meshgrading(node::Paths.Node; kwargs...) = -1.0

# Used to define keys for grouping mesh size fields.
sizeandgrading(e::GeometryEntity; kwargs...) =
    (float(meshsize(e; kwargs...)), float(meshgrading(e; kwargs...)))

"""
    Global defaults for key meshing parameters.
"""
MESHSIZE_PARAMS[:mesh_scale] = 1.0
MESHSIZE_PARAMS[:mesh_order] = 1
MESHSIZE_PARAMS[:global_α] = 0.9

"""
    set_gmsh_option(s, o::Number)
    set_gmsh_option(s, o::AbstractString)

Set options within the gmsh API.
"""
set_gmsh_option(s, o::Number) = gmsh.option.set_number(s, o)
set_gmsh_option(s, o::AbstractString) = gmsh.option.set_string(s, o)

"""
    mesh_scale()
    mesh_scale(s)

Get and set the mesh scale which applies multiplicatively to the smallest size specified by any size field
function, comparing to the formula in the `MeshSized` style, this results in all mesh size
fields being rescaled where `h` ← `mesh_scale` * `h`.
"""
mesh_scale(s) = MESHSIZE_PARAMS[:mesh_scale]::Float64 = s
mesh_scale() = MESHSIZE_PARAMS[:mesh_scale]::Float64

"""
    mesh_order()
    mesh_order(order::Number, higher_order_optimize::Number=1)

Get or set the order of polynomials to use in representing the geometry, this
is important if curved geometric features are present, `mesh_order == 1` will represent
the geometry with linear polynomials, whilst `mesh_order == 2` will represent it with
quadratic polynomials, and `mesh_order == 3` with cubic polynomials. Increasing the value
of `mesh_order` results in greater geometric fidelity, whilst making meshing more
difficult (and prone to errors).
"""
mesh_order() = SolidModels.gmsh.get_number("Mesh.ElementOrder")
function mesh_order(order::Number, higher_order_optimize::Number=1)
    set_gmsh_option("Mesh.ElementOrder", order)
    set_gmsh_option("Mesh.HighOrderOptimize", higher_order_optimize)
    return nothing
end

"""
    mesh_grading_default()
    mesh_grading_default(α)

Get or set the default value of `α` to use for `MeshSized` entities where `α`
is set to less than 0, `global_α ∈ (0, 1]` is particularly used for the default grading
of `Path` entities. A value closer to 1 can result in an unstable meshing algorithm in gmsh,
particularly for complex geometries.
"""
mesh_grading_default() = MESHSIZE_PARAMS[:global_α]::Float64
function mesh_grading_default(α)
    @assert 0 < α <= 1
    MESHSIZE_PARAMS[:global_α]::Float64 = α
    return finalize_size_fields!()
end

"""
    add_mesh_size_point(; h, α=-1, p)

Add a mesh size control point to the global mesh sizing parameters.

# Arguments

  - `p`: 3D point coordinates where mesh size is controlled. Can be a single point, or array
    of concatenated points [x1,y1,z1,x2,y2,z2,...].
  - `h`: Target mesh size at the point
  - `α`: Mesh grading parameter (α ≤ 1). If negative the default global value will be used
    when the size trees are regenerated. All negative values are mapped together for efficient
    KDTree calculations.

The point is added to a collection grouped by `(h, α)` values for efficient mesh size field computation.
"""
function add_mesh_size_point(p; h, α=-1)
    return push!(
        get!(
            SolidModels.MESHSIZE_PARAMS[:cp],
            (h, α < 0 ? -1 : α),
            Vector{SVector{3, Float64}}()
        ),
        reinterpret(SVector{3, Float64}, p)
    )
end

"""
    finalize_size_fields!()

Rebuild KDTree data structures for mesh size field computation.

Must be called after manually adding mesh size points with [`add_mesh_size_point`](@ref)
to enable efficient spatial queries during meshing. Creates KDTrees grouped by `(h, α)`
parameters for fast nearest-neighbor lookups.
"""
function finalize_size_fields!()
    # For each collection of (h, α), can assemble a KDTree to find closest. This will be the
    # smallest mesh size over that collection of vertices, as size is proportional to
    # distance for this subset. Thereby the comparison over lengths need only be over the
    # number of different (h, α) combinations. This is most impactful for large graphs with
    # many duplicates of a given component, where there will be many points per (h, α).
    SolidModels.MESHSIZE_PARAMS[:ct] = Dict{
        Tuple{Float64, Float64},
        KDTree{SVector{3, Float64}, Euclidean, Float64, SVector{3, Float64}}
    }()
    for (h, α) in keys(SolidModels.MESHSIZE_PARAMS[:cp])
        # Substitute any negative grading value for the global default. Delaying this
        # substitution allows for modifying the size field after rendering, without needing
        # to recompute the locations of all control points.
        SolidModels.MESHSIZE_PARAMS[:ct][(
            h,
            α < 0 ? SolidModels.MESHSIZE_PARAMS[:global_α] : α
        )] = KDTree(SolidModels.MESHSIZE_PARAMS[:cp][(h, α)])
    end
    return nothing
end

"""
    mesh_control_points()

Get the dictionary of mesh size control points grouped by `(h, α)` parameters.

Returns a `Dict{Tuple{Float64, Float64}, Vector{SVector{3, Float64}}}` where keys are
`(mesh_size, grading_parameter)` tuples and values are vectors of 3D points.

If this dictionary is modified, by erasing points or adding points using
[`add_mesh_size_point`](@ref), then it is necessary to call [`finalize_size_fields`](@ref)
to rebuild the KDTree from the data, else any resulting mesh will not reflect the change in
data.
"""
mesh_control_points() = SolidModels.MESHSIZE_PARAMS[:cp]

"""
    mesh_control_trees()

Get the dictionary of KDTrees for efficient spatial queries of mesh size control points.

Returns a `Dict{Tuple{Float64, Float64}, KDTree}` where keys are `(mesh_size, grading_parameter)`
tuples and values are KDTrees for fast nearest-neighbor lookups.
"""
mesh_control_trees() = SolidModels.MESHSIZE_PARAMS[:ct]

"""
    clear_mesh_control_points!()

Clear all mesh size control points and associated KDTrees.
"""
function clear_mesh_control_points!()
    empty!(SolidModels.MESHSIZE_PARAMS[:cp])
    return empty!(SolidModels.MESHSIZE_PARAMS[:ct])
end

"""
    reset_mesh_control!()

Reset the mesh scaling and grading to the original defaults of (1.0, 0.9).
"""
function reset_mesh_control!()
    mesh_scale(1.0)
    return mesh_grading_default(0.9)
end

"""
    render!(sm::SolidModel, cs::AbstractCoordinateSystem{T}; map_meta=layer, postrender_ops=[], zmap=(_) -> zero(T), kwargs...) where {T}

Render `cs` to `sm`.

# Keywords

  - `map_meta`: Function (m::SemanticMeta) -> name of `PhysicalGroup` (as `String` or `Symbol`; may also return `nothing` to skip rendering `m`)
  - `postrender_ops`: Vector of Tuples `(destination, op, args, op_kwargs...)` specifying "postrendering"
    of `PhysicalGroup`s executed after entities have been rendered to to `sm`.
    Each operation `op` creates a new `PhysicalGroup` defined as
    `sm[destination] = op(sm, args...; op_kwargs...)`. That is, `args` are the arguments to
    `op` (following the first argument, which is always the model `sm` being rendered to).
    For most operations, these arguments include the names and dimensions of groups being
    operated on, and `op_kwargs` are the keyword arguments passed to `op`. For example,
    `("base", difference_geom!, ("writeable_area", "base_negative"), :remove_object => true, :remove_tool => true)`
    defines a postrendering step that subtracts the `PhysicalGroup` named `"base_negative"`
    from `"writeable_area"` (by default using dimension 2 for each group) to define a new group called
    `"base"`. The keyword pairs `:remove_object=>true` and `:remove_tool=>true` mean
    that the "object" (first argument) group `"writeable_area"` and the "tool" (second argument)
    group `"base_negative"` are both removed when `"base"` is created.
  - `zmap`: Function (m::SemanticMeta) -> `z` coordinate of corresponding elements. Default:
    Map all metadata to zero.

Available postrendering operations include [`translate!`](@ref), [`extrude_z!`](@ref), [`revolve!`](@ref),
[`union_geom!`](@ref), [`intersect_geom!`](@ref), [`difference_geom!`](@ref), [`fragment_geom!`](@ref), and [`box_selection`](@ref).
(The geometric Boolean operations are only available for models using the OpenCASCADE kernel.)

Additional keyword arguments are passed to [`SolidModels.to_primitives`](@ref) (which falls back to
[`to_polygons`](@ref)) and may be used for
certain entity types to control how entities of `cs` are converted to primitives and added to `sm`.
"""
function render!(
    sm::SolidModel,
    cs::AbstractCoordinateSystem{T};
    map_meta=layer,
    postrender_ops=[],
    retained_physical_groups=[],
    zmap=(_) -> zero(T),
    gmsh_options=Dict{String, Union{String, Float64}}(),
    kwargs...
) where {T}
    gmsh.model.set_current(name(sm))

    for (k, v) ∈ gmsh_options
        set_gmsh_option(k, v)
    end

    flat = flatten(cs)

    # Collections of dimtags corresponding to a given sizing field
    sizeandgrading_dimtags = Dict{Tuple{Float64, Float64}, Vector{Tuple{Int32, Int32}}}()

    # Create RTree for avoiding duplicating points
    points_tree = RTree{Float64, 3}(Int32)

    # Create physical groups
    for meta in unique(element_metadata(flat)) # For each unique (layer, level, index) triple
        isnothing(map_meta(meta)) && continue
        idx = (element_metadata(flat) .== meta) # Get the corresponding elements
        els = to_primitives.(sm, elements(flat)[idx]; kwargs...)
        meshsizes = sizeandgrading.(elements(flat)[idx]; kwargs...)

        # Add to model using kernel
        group_dimtags_unflattened = _add_to_current_solidmodel!(
            els,
            meta,
            kernel(sm);
            zmap=zmap,
            points_tree=points_tree,
            kwargs...
        )

        group_dimtags = reduce(vcat, group_dimtags_unflattened, init=Tuple{Int32, Int32}[])
        # If group already exists, add to it
        for dim in unique(first.(group_dimtags))
            if hasgroup(sm, map_meta(meta), dim)
                append!(group_dimtags, dimtags(sm[map_meta(meta), dim]))
            end
        end

        # Make physical group for each dimension
        sm[map_meta(meta)] = group_dimtags

        # Collect dimtags for each sizeandgrading
        for (s, dts) ∈ zip(meshsizes, group_dimtags_unflattened)
            h_dimtags = (dts isa Vector ? dts : [dts])
            append!(get!(sizeandgrading_dimtags, s, []), h_dimtags)
        end
    end
    # Synchronize the entities to the model, so can find subentities.
    _synchronize!(sm)

    SolidModels.MESHSIZE_PARAMS[:cp] =
        Dict{Tuple{Float64, Float64}, Vector{SVector{3, Float64}}}()
    for ((h, α), dts) in sizeandgrading_dimtags
        iszero(h) && continue
        bdts = gmsh.model.get_boundary(dts, true, false, false) # line segments

        for (dim, tag) in bdts
            @assert dim == 1
            bounds = gmsh.model.get_parametrization_bounds(dim, tag)
            curv = gmsh.model.get_curvature(
                dim,
                tag,
                [bounds[1][1], (bounds[1][1] + bounds[2][1])/2, bounds[2][1]]
            )
            # Calculate a sampling rate on a per segment basis.
            if maximum(curv) <= 1e-14
                # Straight.
                xyz = gmsh.model.get_value(dim, tag, [bounds[1][1], bounds[2][1]])
                l = sqrt((xyz[1] - xyz[4])^2 + (xyz[2] - xyz[5])^2 + (xyz[3] - xyz[6])^2)
                Ns = cld(l, h)
            elseif abs(minimum(curv) - maximum(curv)) < 1e-9  # a circular arc
                # For a circular arc, use the midpoint to construct the swept angle, and
                # from that the arc length and number of required samples.
                xyz = gmsh.model.get_value(
                    dim,
                    tag,
                    [bounds[1][1], (bounds[1][1] + bounds[2][1])/2]
                )
                δ =
                    sqrt((xyz[1] - xyz[4])^2 + (xyz[2] - xyz[5])^2 + (xyz[3] - xyz[6])^2) /
                    2
                mcurv = sum(curv) / length(curv)
                l = 1/mcurv * (2 * atan(δ, 1/mcurv)) # rθ
                Ns = cld(l, h)
            else
                Ns = 11
                # Approximate the spline with 10 linear segments, and use the corresponding
                # linear length to compute the sample rate.
                t = [bounds[1][1] + i * (bounds[2][1] - bounds[1][1]) / Ns for i = 0:Ns]
                xyz = gmsh.model.get_value(dim, tag, t) # [x1,y1,z1,x2,y2,z2,...]
                XYZ = reinterpret(SVector{3, Float64}, xyz)
                l = sum(norm.(XYZ[2:end] .- XYZ[1:(end - 1)]))
                Ns = cld(l, h)
            end
            t = [bounds[1][1] + i * (bounds[2][1] - bounds[1][1]) / Ns for i = 0:(Ns - 1)]
            xyz = gmsh.model.get_value(dim, tag, t) # [x1,y1,z1,x2,y2,z2,...]

            append!(
                get!(
                    SolidModels.MESHSIZE_PARAMS[:cp],
                    (h, α < 0 ? -1 : α),
                    Vector{SVector{3, Float64}}()
                ),
                reinterpret(SVector{3, Float64}, xyz)
            )
        end
    end

    # Generate the KDTrees corresponding to the meshing control points.
    finalize_size_fields!()

    # Extrusions, Booleans, etc
    _synchronize!(sm)
    _postrender!(sm, postrender_ops)
    # Get rid of redundant entities and update groups accordingly
    _synchronize!(sm)
    _fragment_and_map!(sm)

    SolidModels.gmsh.option.setNumber("General.NumThreads", 0)

    # Pass in call back function for meshing against the vertices found previously.
    gmsh.model.mesh.setSizeCallback(gmsh_meshsize)

    gmsh.option.set_number(
        "Mesh.MeshSizeFromPoints",
        get(gmsh_options, "Mesh.MeshSizeFromPoints", 0)
    )
    gmsh.option.set_number(
        "Mesh.MeshSizeFromCurvature",
        get(gmsh_options, "Mesh.MeshSizeFromCurvature", 0)
    )
    gmsh.option.set_number(
        "Mesh.MeshSizeExtendFromBoundary",
        get(gmsh_options, "Mesh.MeshSizeExtendFromBoundary", 0)
    )
    gmsh.option.set_number(
        "Mesh.MeshSizeFromPoints",
        get(gmsh_options, "Mesh.Algorithm", 6)
    )
    gmsh.option.set_number(
        "Mesh.MeshSizeFromCurvature",
        get(gmsh_options, "Mesh.Algorithm3D", 1)
    )

    # With the setting below, Gmsh will look for OMP_NUM_THREADS environment variables;
    # this needs to be >1 for HXT algorithm to use parallelism.
    gmsh.option.set_number("General.NumThreads", 1)

    # Always save meshes in binary for faster disk I/O
    gmsh.option.set_number("Mesh.Binary", 1)

    # Remove all physical groups except those on the retained list.
    if !isempty(retained_physical_groups)
        for d ∈ 0:3
            retain_groups = getindex.(filter(x -> x[2] == d, retained_physical_groups), 1)
            all_groups = keys(dimgroupdict(sm, d))
            setdiff(all_groups, retain_groups)
            for k ∈ setdiff(all_groups, retain_groups)
                remove_group!(sm[k, d], remove_entities=false)
            end
        end

        # Reindex the physical groups to improve human readability
        reindex_physical_groups!(sm)
    end

    return _synchronize!(sm)
end

# Callback function that access module global parameters. This is passed into gmsh as a
# callback function, but presumes that the global MESHSIZE_PARAMS have been set
# appropriately, otherwise will error. Usage of a global is necessary to avoid an LLVM
# limitation on apple silicon, where closures are not supported.
function gmsh_meshsize(
    dim::Cint,
    tag::Cint,
    x::Cdouble,
    y::Cdouble,
    z::Cdouble,
    lc::Cdouble
)
    # If true, use KDTree for evaluating the map, if false use a direct loop over control
    # points. KDTree appears to use more memory, but can be significantly faster, especially
    # for highly repetitive geometries.
    if true
        l1 = Inf64
        # Explicit type tag here to remove hypothetical type instability.
        for ((h, α), tree) in SolidModels.MESHSIZE_PARAMS[:ct]::Dict{
            Tuple{Float64, Float64},
            KDTree{SVector{3, Float64}, Euclidean, Float64, SVector{3, Float64}}
        }

            _, d::Float64 = nn(tree, SVector{3}(x, y, z))
            l1 = min(
                l1,
                h * max(SolidModels.MESHSIZE_PARAMS[:mesh_scale]::Float64, (d/h)^α)
            )::Float64
        end
        return l1
    else
        l2 = Inf64
        # Explicit type tag here to remove hypothetical type instability.
        for ((h, α), vs) in SolidModels.MESHSIZE_PARAMS[:cp]::Dict{
            Tuple{Float64, Float64},
            Vector{SVector{3, Float64}}
        }

            α_local = α < 0 ? SolidModels.MESHSIZE_PARAMS[:alpha_default] : α
            for v in vs
                d = sqrt((x - v[1])^2 + (y - v[2])^2 + (z - v[3])^2)
                l2 = min(
                    l2,
                    h * max(SolidModels.MESHSIZE_PARAMS[:mesh_scale]::Float64, (d/h)^α)
                )
            end
        end
        return l2
    end
end

# Utility intended for very last step in rendering, to get rid of overlapping geometry
# All groups will point to the same volume/area/etc, but tags, entity count, etc may change.
# frag_dims specifies the dimensions to be included in fragmentation, whilst
# excluded_physical_groups are physical groups not to be included in the fragmentation.
function _fragment_and_map!(
    sm::SolidModel,
    frag_dims=[0, 2, 3];
    excluded_physical_groups=PhysicalGroup[]
)
    gmsh.model.set_current(name(sm))
    # Get the tags of entities in existing groups
    groups = [
        (name, dimtags(pg)) for dim in frag_dims for
        (name, pg) in pairs(dimgroupdict(sm, dim))
    ]
    allents = vcat([gmsh.model.get_entities(dim) for dim in frag_dims]...)

    # Remove any excluded groups from the fragment.
    if !isempty(excluded_physical_groups)
        allents = setdiff(allents, [dimtags(pg) for pg in excluded_physical_groups]...)
        groups =
            setdiff(groups, [(name(pg), dimtags(pg)) for pg ∈ excluded_physical_groups])
    end

    # Fragment will preserve tags if possible
    # but otherwise will remove entities and create new ones
    if true
        frags, entmap = kernel(sm).fragment(allents, [])
    else
        # Manual fragment map construction for debugging purposes.
        frags, _ = kernel(sm).fragment(allents, [], -1, false, false)

        # Each returned fragment will be subset of at least one incoming entity.
        # TODO: Speed this up by exploiting that an entity that maps to itself will never be
        # found again, so can be removed from a copy of the origin entities.
        function collect_entity_map(entity, origin_entities, exact_matches)
            e = [entity]
            m = Tuple{Int32, Int32}[]
            # Filter to only look for entities of the same dimensionality, not already found
            for o ∈ setdiff(filter(x -> x[1] == entity[1], origin_entities), exact_matches)
                if entity == o
                    @assert isempty(m)
                    # An exact match cannot map onto any other entity, so add to the filter.
                    push!(exact_matches, o)
                    return e # exact match don't need to keep searching.
                end
                i, _ = kernel(sm).intersect(e, [o], -1, false, false)
                if !isempty(i)
                    # If the intersection is non empty, count it.
                    push!(m, o)
                    if i[1] != entity && i[1] != o
                        # If the intersection is neither input, the newly created entry
                        # should be removed.
                        kernel(sm).remove(i)
                    end
                end
            end
            return m
        end
        # Buffer to collect entities that were fragments when input. Once the exact map is
        # discovered, do not include in the search on remaining outputs.
        incoming_fragments = Tuple{Int32, Int32}[]
        entmap = collect_entity_map.(allents, Ref(frags), Ref(incoming_fragments))

        # Remove all entities that are not also output fragments.
        kernel(sm).remove(setdiff(allents, frags))
    end

    # For each original group,
    # reassign the group to the fragments its elements were mapped to
    for (name, dim_tags) in groups
        isempty(dim_tags) && continue
        sm[name] = vcat((entmap[indexin(dim_tags, allents)])...)
    end
    return _synchronize!(sm)
end
# GmshNative has no fragment
function _fragment_and_map!(
    ::SolidModel{GmshNative},
    frag_dims;
    excluded_physical_groups=PhysicalGroup[]
) end

# Assumes `gmsh` has been initialized and the current model has been set beforehand, and that
# the model will be synchronized afterward.
function _add_to_current_solidmodel! end

# render! broadcasts this over vectors of vectors, and it broadcasts itself over vectors...
function _add_to_current_solidmodel!(els, m::Meta, k; kwargs...)
    return _add_to_current_solidmodel!.(els, m, k; kwargs...)
end

_get_boundary_points(dt::Tuple) = _get_boundary_points([dt])
function _get_boundary_points(dts)
    ents = gmsh.model.get_boundary(dts, false, true, true) # not combined, oriented, recursive
    return filter(ent -> iszero(first(ent)), ents)
end

const POINT_MERGE_ATOL = 1e-9 # in STP_UNIT, i.e. atol=1e-6nm
function _get_or_add_points!(k, pts_xy, z, points_tree; atol=POINT_MERGE_ATOL)
    return _get_or_add_point!.(
        k,
        getx.(pts_xy),
        gety.(pts_xy),
        z,
        Ref(points_tree);
        atol=atol
    )
end

function _get_or_add_point!(
    k,
    x::Length,
    y::Length,
    z::Length,
    points_tree;
    atol=POINT_MERGE_ATOL
)
    return _get_or_add_point!(
        k,
        float(ustrip(STP_UNIT, x)),
        float(ustrip(STP_UNIT, y)),
        float(ustrip(STP_UNIT, z)),
        points_tree,
        atol=atol
    )
end

function _get_or_add_point!(
    k,
    x::Float64,
    y::Float64,
    z::Float64,
    points_tree::Nothing;
    atol=POINT_MERGE_ATOL
)
    return k.add_point(x, y, z)
end

function _get_or_add_point!(
    k::GmshNative,
    x::Float64,
    y::Float64,
    z::Float64,
    points_tree::RTree;
    atol=POINT_MERGE_ATOL
)
    return k.add_point(x, y, z)
end

function _get_or_add_point!(
    k,
    x::Float64,
    y::Float64,
    z::Float64,
    points_tree::RTree;
    atol=POINT_MERGE_ATOL
)
    reg =
        SpatialIndexing.Rect((x - atol, y - atol, z - atol), (x + atol, y + atol, z + atol))
    if isempty(points_tree, reg)
        tag = k.add_point(x, y, z)
        insert!(points_tree, SpatialIndexing.Point((x, y, z)), tag)
        return tag
    end
    pts = SpatialIndexing.contained_in(points_tree, reg)
    tag = only(pts).val
    current_points = k.get_entities(0)
    if tag in last.(current_points)
        return tag
    end
    # point must have gotten relabeled — can happen if you're trying to connect to a point that was on a hole
    # just add the point again, don't bother with the tree
    # (for some reason k.get_entities_in_bounding_box may not find the point either, even with a +/- 1nm box)
    tag = k.add_point(x, y, z)
    return tag
end

# Add primitives to solid model
function _add_to_current_solidmodel!(
    poly::AbstractPolygon{T},
    m::Meta,
    k;
    zmap=(_) -> zero(T),
    points_tree=nothing,
    atol=DeviceLayout.onenanometer(T),
    kwargs...
) where {T}
    z = zmap(m) # map from m using kwargs
    # Add as curve loop to get point deduplication
    loop = _add_loop!(CurvilinearPolygon(points(poly)), k, z; points_tree, atol)
    surf = k.add_plane_surface([loop])

    return (Int32(2), surf)
end

_add_to_current_solidmodel!(
    x::CurvilinearPolygon,
    m::Meta,
    k;
    zmap=(_) -> zero(T),
    points_tree=nothing,
    kwargs...
) = _add_to_current_solidmodel!(CurvilinearRegion(x), m, k; zmap, points_tree, kwargs...)

function _add_to_current_solidmodel!(
    surf::CurvilinearRegion{T},
    m::Meta,
    k;
    zmap=(_) -> zero(T),
    points_tree=nothing,
    atol=DeviceLayout.onenanometer(T),
    kwargs...
) where {T}
    z = zmap(m) # map from m using kwargs
    outer_loop = _add_loop!(surf.exterior, k, z; points_tree, atol)
    hole_loops = _add_loop!.(surf.holes, k, z; points_tree, atol)

    surftag = k.add_plane_surface([outer_loop])
    if !isempty(hole_loops)
        holes = [k.add_plane_surface([h]) for h ∈ hole_loops]
        out_dim_tags, _ = k.cut([(2, surftag)], [(2, x) for x ∈ holes])
        surftag = out_dim_tags[1][2]
    end
    return (Int32(2), surftag)
end

function _add_to_current_solidmodel!(
    line::LineSegment{T},
    m::Meta,
    k;
    zmap=(_) -> zero(T),
    points_tree=nothing,
    atol=DeviceLayout.onenanometer(T),
    kwargs...
) where {T}
    z = zmap(m)
    p0 = _get_or_add_point!(k, getx(line.p0), gety(line.p0), z, points_tree)
    p1 = _get_or_add_point!(k, getx(line.p1), gety(line.p1), z, points_tree)
    linetag = k.add_line(p0, p1)
    return (Int32(1), linetag)
end

# Sub-primitive methods for loops and curves
function _add_loop!(
    cl::CurvilinearPolygon,
    k,
    z;
    points_tree=nothing,
    atol=DeviceLayout.onenanometer(coordinatetype(cl))
)
    pts = _get_or_add_points!(k, points(cl), z, points_tree)
    endpoint_pairs = zip(pts, circshift(pts, -1))
    curves = map(enumerate(endpoint_pairs)) do (i, endpoints)
        curve_idx = findfirst(isequal(i), cl.curve_start_idx)
        if isnothing(curve_idx) # not found
            # see if the negative of the index is in there
            curve_idx = findfirst(isequal(-i), cl.curve_start_idx)
            if isnothing(curve_idx) # nope, just a line
                return k.add_line(endpoints[1], endpoints[2])
            else # negative index => reverse endpoints
                c = _add_curve!(reverse(endpoints), cl.curves[curve_idx], k, z; atol)
                !isempty(size(c)) && return reverse(c)
                return c
            end
        else # add the curve whose start index is i
            return _add_curve!(endpoints, cl.curves[curve_idx], k, z; atol)
        end
    end
    return k.add_curve_loop(collect(Iterators.flatten(curves)))
end

# Exact circular arc
function _add_curve!(endpoints, seg::Paths.Turn, k::OpenCascade, z; kwargs...)
    center_pt =
        seg.p0 + Point(-seg.r * sign(seg.α)sin(seg.α0), seg.r * sign(seg.α)cos(seg.α0))
    cen = k.add_point(
        ustrip(STP_UNIT, getx(center_pt)),
        ustrip(STP_UNIT, gety(center_pt)),
        ustrip(STP_UNIT, z)
    )
    # Split the arc in 2 if necessary
    if abs(seg.α) >= 180° # Arcs have to be strictly less than pi
        n_180 = abs(seg.α) / 180°
        n_arcs = if ceil(n_180) == n_180
            Int(n_180 + 1)
        else
            Int(ceil(n_180))
        end
        arclengths = range(zero(pathlength(seg)), pathlength(seg), length=n_arcs + 1)
        middle_pts = seg.(arclengths[(begin + 1):(end - 1)])
        middle_tags = k.add_point.(
            ustrip.(STP_UNIT, getx.(middle_pts)),
            ustrip.(STP_UNIT, gety.(middle_pts)),
            ustrip(STP_UNIT, z)
        )
        tags = [endpoints[1]; middle_tags; endpoints[2]]
        return k.add_circle_arc.(tags[1:(end - 1)], cen, tags[2:end], -1)
    end
    return k.add_circle_arc(endpoints[1], cen, endpoints[2], -1)
end

# Exact *interpolating* cubic BSpline in OCC
# (occ.addBSpline and geo.addBSpline instead use control points, and geo.addSpline uses Catmull-Rom splines)
function _add_curve!(endpoints, seg::Paths.BSpline, k::OpenCascade, z; kwargs...)
    midpts = k.add_point.(
        ustrip.(STP_UNIT, getx.(seg.p[2:(end - 1)])),
        ustrip.(STP_UNIT, gety.(seg.p[2:(end - 1)])),
        ustrip(STP_UNIT, z)
    )
    pts = [endpoints[1], midpts..., endpoints[2]]
    # Tangents for start and end as concatenated 3d vectors
    tangents = [
        ustrip(STP_UNIT, seg.t0.x),
        ustrip(STP_UNIT, seg.t0.y),
        0,
        ustrip(STP_UNIT, seg.t1.x),
        ustrip(STP_UNIT, seg.t1.y),
        0
    ]
    return k.addSpline( # C2 B-spline that goes through pts
        pts,
        -1, # just use next tag
        tangents
    )
end

# Offset curves
_add_curve!(endpoints, seg::Paths.OffsetSegment, k, z; kwargs...) =
    _add_offset_curve!(endpoints, seg.seg, seg.offset, k, z; kwargs...)
# Turns with constant offsets are still circular arcs
function _add_offset_curve!(endpoints, seg::Paths.Turn, offset::Coordinate, k, z; kwargs...)
    return _add_curve!(
        endpoints,
        Paths.Turn(
            seg.α,
            seg.r - sign(seg.α) * offset,
            seg.p0 + Point(-sin(seg.α0), cos(seg.α0)) * offset,
            seg.α0
        ),
        k,
        z
    )
end

# Any other offset curve (BSpline or variable offset) will be approximated by a BSpline
function _add_offset_curve!(
    endpoints,
    seg::Paths.Segment,
    offset,
    k,
    z;
    atol=DeviceLayout.onenanometer(typeof(offset))
)
    bspline_approx = bspline_approximation(Paths.offset(seg, offset); atol)
    newstarts = DeviceLayout.p0.(bspline_approx.segments)[2:end]
    newpts = k.add_point.(
        ustrip.(STP_UNIT, getx.(newstarts)),
        ustrip.(STP_UNIT, gety.(newstarts)),
        ustrip(STP_UNIT, z)
    )
    starts = [first(endpoints), newpts...]
    stops = [newpts..., last(endpoints)]
    endp_pairs = [[start, stop] for (start, stop) in zip(starts, stops)]
    return _add_curve!.(endp_pairs, bspline_approx.segments, k, z)
end
