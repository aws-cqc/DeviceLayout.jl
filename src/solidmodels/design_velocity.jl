######## Design velocities
#
# A design velocity is the derivative of the position of every point of a rendered solid
# model with respect to one layout parameter. It is built from the 2D layout alone, before
# any meshing, so that it can be evaluated at the nodes of any mesh of the model: the vertex
# velocities of the layout come from central differences of the layout at p ± h, an in-plane
# field interpolates them harmonically on a constrained triangulation of a window around the
# moving geometry, and an extrusion profile in z extends the in-plane field into 3D.

import DelaunayTriangulation
import LinearAlgebra
import SparseArrays
import Random
import Unitful
import Unitful: NoUnits
import Clipper
import DeviceLayout: Rectangle, onenanometer, clip, orientation, lowerleft, upperright
import DeviceLayout.Polygons: _all_contours

# Coordinates closer than this (in STP_UNIT) are the same point. This is far below layout
# tolerances (`onenanometer`) and far above Float64 resolution at chip scale.
const VELOCITY_MERGE_ATOL = 1e-6

# A triangulation of the window of one plane: points, triangles and a point locator. Shared
# by the design velocities of all parameters built together.
struct _PlaneMesh
    window::NTuple{4, Float64} # (xmin, xmax, ymin, ymax)
    points::Matrix{Float64} # 2 × n
    triangles::Matrix{Int32} # 3 × nt
    cell_size::NTuple{2, Float64}
    cell_counts::NTuple{2, Int}
    cell_offsets::Vector{Int32} # CSR offsets into `cell_triangles`
    cell_triangles::Vector{Int32}
end

# The in-plane field of one parameter on one plane, and its extrusion profile: 1 for z in
# `slab`, linear to 0 at `support`, 0 beyond.
struct _PlaneField
    mesh::_PlaneMesh
    slab::NTuple{2, Float64}
    support::NTuple{2, Float64}
    values::Matrix{Float64} # 2 × n nodal values
end

"""
    struct DesignVelocity

The design velocity of a layout parameter `p`: the field ``V(x, y, z) = ∂X/∂p`` that gives
the rate at which each point ``X`` of the rendered solid model moves as `p` changes.
Construct with [`SolidModels.design_velocities`](@ref).

A `DesignVelocity` `dv` is callable:

  - `dv(x, y, z)` returns ``V`` at one point as an `SVector{3, Float64}`.
  - `dv(X)` returns a `3 × N` matrix of ``V`` at the columns of a `3 × N` matrix `X`.

Coordinates are in `SolidModels.STP_UNIT` (μm), the units of meshes exported by
`SolidModel`, unless they are `Unitful` lengths. ``V`` is dimensionless for a length
parameter and in `STP_UNIT` per `SolidModels.parameter_unit(dv)` otherwise.

``V`` is the harmonic interpolation, in the plane of the moving geometry, of the velocities
of all rendered edges in a rectangular window around it, times an extrusion profile in z. It
is zero on fixed edges, on the window boundary, outside the window and beyond the profile's
support. It has no z component, so planar interfaces stay planar.
"""
struct DesignVelocity
    parameter::Symbol
    unit::Unitful.Units
    planes::Vector{_PlaneField}
end

"""
    parameter_unit(dv::DesignVelocity)

The unit of the parameter that `dv` differentiates with respect to: `STP_UNIT` for a length
parameter, so that `dv` is dimensionless, the unit of the parameter otherwise, or
`Unitful.NoUnits` for a unitless parameter.
"""
parameter_unit(dv::DesignVelocity) = dv.unit

"""
    struct DesignDisplacement

A displacement field ``Σᵢ δpᵢ Vᵢ`` combining the design velocities ``Vᵢ`` of several
parameters, constructed with [`SolidModels.design_displacement`](@ref). Callable like a
[`SolidModels.DesignVelocity`](@ref); the result is a displacement in `STP_UNIT`.
"""
struct DesignDisplacement
    planes::Vector{_PlaneField}
end

function Base.show(io::IO, dv::DesignVelocity)
    return print(
        io,
        "DesignVelocity(:",
        dv.parameter,
        ", ",
        length(dv.planes),
        length(dv.planes) == 1 ? " plane)" : " planes)"
    )
end

######## Evaluation

(dv::DesignVelocity)(x, y, z) = _evaluate(dv.planes, x, y, z)
(dv::DesignVelocity)(X::AbstractMatrix) = _evaluate(dv.planes, X)
(d::DesignDisplacement)(x, y, z) = _evaluate(d.planes, x, y, z)
(d::DesignDisplacement)(X::AbstractMatrix) = _evaluate(d.planes, X)

function _evaluate(planes, x, y, z)
    return _evaluate_point(planes, _stp_float(x), _stp_float(y), _stp_float(z))
end

function _evaluate(planes, X::AbstractMatrix)
    size(X, 1) == 3 || throw(ArgumentError("expected a 3 × N matrix of points"))
    out = zeros(3, size(X, 2))
    for j in axes(X, 2)
        v = _evaluate_point(
            planes,
            _stp_float(X[1, j]),
            _stp_float(X[2, j]),
            _stp_float(X[3, j])
        )
        out[1, j] = v[1]
        out[2, j] = v[2]
    end
    return out
end

function _evaluate_point(planes, x::Float64, y::Float64, z::Float64)
    vx, vy = 0.0, 0.0
    for pf in planes
        ψ = _profile(pf, z)
        iszero(ψ) && continue
        t, λ = _locate(pf.mesh, x, y)
        iszero(t) && continue
        tri = view(pf.mesh.triangles, :, t)
        for k = 1:3
            vx += ψ * λ[k] * pf.values[1, tri[k]]
            vy += ψ * λ[k] * pf.values[2, tri[k]]
        end
    end
    return SVector(vx, vy, 0.0)
end

function _profile(pf::_PlaneField, z::Float64)
    (a, b), (lo, hi) = pf.slab, pf.support
    a <= z <= b && return 1.0
    lo < z < a && return (z - lo) / (a - lo)
    b < z < hi && return (hi - z) / (hi - b)
    return 0.0
end

# Return the index of the triangle containing (x, y) and the barycentric coordinates there,
# or 0 outside the window.
function _locate(m::_PlaneMesh, x::Float64, y::Float64)
    xmin, xmax, ymin, ymax = m.window
    λ0 = SVector(0.0, 0.0, 0.0)
    (xmin <= x <= xmax && ymin <= y <= ymax) || return 0, λ0
    i = clamp(floor(Int, (x - xmin) / m.cell_size[1]) + 1, 1, m.cell_counts[1])
    j = clamp(floor(Int, (y - ymin) / m.cell_size[2]) + 1, 1, m.cell_counts[2])
    c = (j - 1) * m.cell_counts[1] + i
    best, bestλ, bestmin = 0, λ0, -Inf
    for k = m.cell_offsets[c]:(m.cell_offsets[c + 1] - 1)
        t = m.cell_triangles[k]
        λ = _barycentric(m, t, x, y)
        μ = minimum(λ)
        μ >= -1e-12 && return Int(t), λ
        if μ > bestmin
            best, bestλ, bestmin = Int(t), λ, μ
        end
    end
    # Only reached on round-off at the window boundary, where the field vanishes.
    return best, bestλ
end

function _barycentric(m::_PlaneMesh, t, x, y)
    a, b, c = m.triangles[1, t], m.triangles[2, t], m.triangles[3, t]
    ax, ay = m.points[1, a], m.points[2, a]
    bx, by = m.points[1, b], m.points[2, b]
    cx, cy = m.points[1, c], m.points[2, c]
    d = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay)
    λb = ((x - ax) * (cy - ay) - (cx - ax) * (y - ay)) / d
    λc = ((bx - ax) * (y - ay) - (x - ax) * (by - ay)) / d
    return SVector(1 - λb - λc, λb, λc)
end

"""
    design_displacement(velocities, δp::NamedTuple)

The displacement field ``Σᵢ δpᵢ Vᵢ`` for parameter changes `δp`, where `velocities` is the
`NamedTuple` of [`SolidModels.DesignVelocity`](@ref) returned by
[`SolidModels.design_velocities`](@ref) (or any collection with the keys of `δp`).

Each `δp[k]` has the units of the parameter, or none for a unitless parameter. Returns a
[`SolidModels.DesignDisplacement`](@ref).
"""
function design_displacement(velocities, δp::NamedTuple)
    # Fields on the same triangulation (from one `design_velocities` call) are summed.
    combined = IdDict{_PlaneMesh, _PlaneField}()
    order = _PlaneMesh[]
    for (k, δ) in pairs(δp)
        haskey(velocities, k) ||
            throw(ArgumentError("no design velocity for parameter :$k"))
        dv = velocities[k]
        w = _parameter_float(δ, dv.unit, k)
        for pf in dv.planes
            if haskey(combined, pf.mesh)
                old = combined[pf.mesh]
                (old.slab == pf.slab && old.support == pf.support) ||
                    error("design velocities on the same plane have different profiles")
                combined[pf.mesh] =
                    _PlaneField(pf.mesh, pf.slab, pf.support, old.values .+ w .* pf.values)
            else
                combined[pf.mesh] =
                    _PlaneField(pf.mesh, pf.slab, pf.support, w .* pf.values)
                push!(order, pf.mesh)
            end
        end
    end
    return DesignDisplacement([combined[m] for m in order])
end

_parameter_float(δ::Real, ::typeof(NoUnits), _) = Float64(δ)
function _parameter_float(δ, u, k)
    try
        return Float64(ustrip(u, δ))
    catch e
        e isa Unitful.DimensionError || rethrow()
        throw(ArgumentError("parameter change for :$k must have units of $u, got $δ"))
    end
end

######## Construction

"""
    design_velocities(f, p0::NamedTuple;
        parameters=keys(p0),
        steps=(;),
        map_meta=layer,
        zmap=(_) -> 0.0,
        thickness=(_) -> 0.0,
        window=nothing,
        margin=nothing,
        zlimits=(-Inf, Inf),
        triangle_size=nothing,
        min_angle=25°,
        kwargs...)

Return a `NamedTuple` mapping each name in `parameters` to its
[`SolidModels.DesignVelocity`](@ref), the derivative of the rendered solid model's geometry
with respect to that parameter at `p0`.

`f(p::NamedTuple)` builds the 2D geometry (an `AbstractCoordinateSystem`) that would be
rendered to a `SolidModel` for parameters `p`. It is called at `p0` and at `p0` with each
parameter changed by `± steps[k]`, so it must be deterministic. A parameter's step defaults
to 1 nm for a length parameter (or `0.001` for a unitless one, interpreted as μm) and must
be given otherwise. The layout's vertices are typically affine in the parameters, so that
the differences are exact for any step that does not change the layout's topology.

`map_meta`, `zmap` and `kwargs` have the same meaning as in
[`render!(::SolidModel, ::CoordinateSystem)`](@ref): entities whose metadata `map_meta` maps
to `nothing` are skipped, `zmap(m)` is the z coordinate of entities with metadata `m`, and
`kwargs` are passed to `to_polygons` (for example `simulation=true` to include
simulation-only geometry). `thickness(m)` is the signed distance by which entities with
metadata `m` are extruded in z (zero for sheets).

The velocity of every vertex of the rendered geometry is computed by central differences.
Every rendered edge in a window around the moving geometry constrains an in-plane field,
which interpolates the edge velocities harmonically and vanishes on the window boundary.
The field is extended in z by a profile that is 1 across the moving entities (and their
extrusion) and decreases linearly to 0 at the nearest other plane of rendered geometry above
and below, or at `zlimits` if nearer.

# Keywords

  - `parameters`: The parameter names to differentiate with respect to.
  - `steps`: A `NamedTuple` of finite-difference steps by parameter name.
  - `window`: A `Rectangle` outside which the velocities vanish. It must contain all the
    moving geometry. By default, the bounding box of all moving edges, expanded by `margin`
    on each side.
  - `margin`: The default window's margin around the moving edges; by default half the
    larger side of their bounding box.
  - `zlimits`: The lowest and highest z at which the velocities may be nonzero, for example
    the faces of a substructuring region whose boundary must not move.
  - `triangle_size`: The largest triangle size of the in-plane triangulation (default: the
    larger side of the window over 40).
  - `min_angle`: The minimum angle of the in-plane triangulation.

The construction fails, rather than return a velocity that is not the derivative of the
rendered geometry, when a step changes the topology of the layout (the number of entities,
boundary loops or vertices, or whether features touch), when the window does not contain all
moving geometry, when a parameter changes the z or thickness of an entity, or when nothing
bounds the profile in z.
"""
function design_velocities(
    f,
    p0::NamedTuple;
    parameters=keys(p0),
    steps=NamedTuple(),
    map_meta=layer,
    zmap=(_) -> 0.0,
    thickness=(_) -> 0.0,
    window=nothing,
    margin=nothing,
    zlimits=(-Inf, Inf),
    triangle_size=nothing,
    min_angle=25°,
    kwargs...
)
    names = Tuple(Symbol(k) for k in parameters)
    isempty(names) && throw(ArgumentError("no parameters to differentiate with respect to"))
    for k in names
        haskey(p0, k) || throw(ArgumentError("parameter :$k is not in p0"))
    end
    snapshot(p) = _layout_entities(f(p), map_meta, zmap, thickness; kwargs...)
    base = snapshot(p0)
    isempty(base) && error("the layout has no rendered entities")
    velocities = Vector{Vector{Vector{Matrix{Float64}}}}(undef, length(names))
    units = Vector{Unitful.Units}(undef, length(names))
    for (j, k) in enumerate(names)
        h = _parameter_step(p0[k], get(steps, k, nothing), k)
        units[j] = _velocity_unit(p0[k])
        hfloat = _parameter_float(h, units[j], k)
        plus = snapshot(merge(p0, NamedTuple{(k,)}((p0[k] + h,))))
        minus = snapshot(merge(p0, NamedTuple{(k,)}((p0[k] - h,))))
        velocities[j] = _vertex_velocities(base, plus, minus, hfloat, k)
    end
    for (j, k) in enumerate(names)
        _snap_velocities!(velocities[j]) ||
            @warn "Parameter :$k does not move any rendered geometry; its design velocity is zero."
    end
    win = _velocity_window(base, velocities, window, margin)
    zlo, zhi = _stp_float(zlimits[1]), _stp_float(zlimits[2])
    zlo < zhi || throw(ArgumentError("zlimits must be increasing, got $zlimits"))
    planes = _moving_planes(base, velocities)
    fields = [_PlaneField[] for _ in names]
    for plane in planes
        slab, support = _plane_profile(base, velocities, plane, win, zlo, zhi)
        mesh, values =
            _plane_velocity(base, velocities, plane, win, triangle_size, min_angle)
        for j in eachindex(names)
            any(!iszero, values[j]) || continue
            push!(fields[j], _PlaneField(mesh, slab, support, values[j]))
        end
    end
    return NamedTuple{names}(
        Tuple(DesignVelocity(names[j], units[j], fields[j]) for j in eachindex(names))
    )
end

# The step of a parameter, in the units of the parameter.
_parameter_step(p, h, _) = h
_parameter_step(p::Length, ::Nothing, _) = onenanometer(p)
_parameter_step(p::AbstractFloat, ::Nothing, _) = onenanometer(p)
function _parameter_step(p, ::Nothing, k)
    p isa Integer && throw(
        ArgumentError(
            "parameter :$k is an integer; design velocities need a continuous parameter"
        )
    )
    throw(
        ArgumentError(
            "parameter :$k is not a length; give its finite-difference step in `steps`"
        )
    )
end

# Velocities of length parameters are dimensionless, with steps converted to STP_UNIT.
_velocity_unit(::Length) = STP_UNIT
_velocity_unit(::Real) = NoUnits
_velocity_unit(p) = unit(p)

struct _LayoutEntity
    index::Int # position in the flattened coordinate system
    meta::Meta
    z::Float64
    thickness::Float64
    loops::Vector{Matrix{Float64}} # 2 × n vertices of each boundary loop, in STP_UNIT
end

function _layout_entities(cs, map_meta, zmap, thickness; kwargs...)
    cs isa AbstractCoordinateSystem || throw(
        ArgumentError(
            "the layout function must return an AbstractCoordinateSystem, got $(typeof(cs))"
        )
    )
    flat = flatten(cs)
    entities = _LayoutEntity[]
    for (i, (e, m)) in enumerate(zip(elements(flat), element_metadata(flat)))
        isnothing(map_meta(m)) && continue
        loops = _boundary_loops(e; kwargs...)
        isempty(loops) && continue
        push!(
            entities,
            _LayoutEntity(i, m, _stp_float(zmap(m)), _stp_float(thickness(m)), loops)
        )
    end
    return entities
end

# The boundary loops of an entity as rendered to a solid model: the contours of a clipped
# polygon (not the keyholed polygons of `to_polygons`), or the vertex loops of its polygons.
_boundary_loops(e::ClippedPolygon; kwargs...) = _contour_loops(e)
_boundary_loops(
    e::StyledEntity{T, <:ClippedPolygon, <:Union{Plain, MeshSized}};
    kwargs...
) where {T} = _contour_loops(e.ent)
function _boundary_loops(e::GeometryEntity; kwargs...)
    polys = to_polygons(e; kwargs...)
    loops = Matrix{Float64}[]
    for p in (polys isa AbstractArray ? polys : [polys])
        if p isa ClippedPolygon
            append!(loops, _contour_loops(p))
        elseif _is_self_touching(points(p))
            # A keyholed polygon: its cuts are not edges of the rendered geometry.
            append!(
                loops,
                _contour_loops(
                    clip(
                        Clipper.ClipTypeUnion,
                        [p],
                        typeof(p)[];
                        pfs=Clipper.PolyFillTypeNonZero,
                        pfc=Clipper.PolyFillTypeNonZero
                    )
                )
            )
        else
            loop = _stp_loop(points(p))
            size(loop, 2) >= 3 && push!(loops, loop)
        end
    end
    return loops
end

_contour_loops(p::ClippedPolygon) =
    [l for l in (_stp_loop(c) for c in _all_contours(p.tree)) if size(l, 2) >= 3]

function _is_self_touching(pts)
    seen = Set{eltype(pts)}()
    for q in pts
        q in seen && return true
        push!(seen, q)
    end
    return false
end

# Vertices in STP_UNIT, without consecutive duplicates or a repeated first vertex.
function _stp_loop(pts)
    xs, ys = Float64[], Float64[]
    for q in pts
        x, y = _stp_float(getx(q)), _stp_float(gety(q))
        !isempty(xs) && xs[end] == x && ys[end] == y && continue
        push!(xs, x)
        push!(ys, y)
    end
    if length(xs) > 1 && xs[1] == xs[end] && ys[1] == ys[end]
        pop!(xs)
        pop!(ys)
    end
    return permutedims(hcat(xs, ys))
end

function _topology_error(k, msg)
    return error(
        "Cannot compute the design velocity of :$k: $msg between the layouts at p0 ± step. " *
        "The parameter must change the geometry continuously; a smaller step may help if " *
        "the change is due to discretization."
    )
end

function _vertex_velocities(base, plus, minus, h, k)
    (length(plus) == length(base) && length(minus) == length(base)) ||
        _topology_error(k, "the number of rendered entities changed")
    velocities = Vector{Vector{Matrix{Float64}}}(undef, length(base))
    for (i, b) in enumerate(base)
        bp, bm = plus[i], minus[i]
        (
            bp.index == b.index &&
            bm.index == b.index &&
            bp.meta == b.meta &&
            bm.meta == b.meta
        ) || _topology_error(k, "the sequence of rendered entities changed")
        (
            bp.z == b.z &&
            bm.z == b.z &&
            bp.thickness == b.thickness &&
            bm.thickness == b.thickness
        ) || error(
            "Cannot compute the design velocity of :$k: it changes the z or thickness " *
            "of entities on layer $(layer(b.meta)), and only in-plane design velocities are supported"
        )
        lp = _align_loops(b.loops, bp.loops)
        lm = _align_loops(b.loops, bm.loops)
        (isnothing(lp) || isnothing(lm)) && _topology_error(
            k,
            "the boundary of an entity on layer $(layer(b.meta)) changed its number of loops or vertices"
        )
        velocities[i] = [(lp[l] .- lm[l]) ./ (2h) for l in eachindex(b.loops)]
    end
    return velocities
end

# Reorder the loops of `other` and their vertices to match `base`, or return nothing.
function _align_loops(base, other)
    length(base) == length(other) || return nothing
    used = falses(length(other))
    aligned = Vector{Matrix{Float64}}(undef, length(base))
    for (i, a) in enumerate(base)
        ca = _centroid(a)
        best, bestd = 0, Inf
        for (j, b) in enumerate(other)
            (used[j] || size(b, 2) != size(a, 2)) && continue
            d = sum(abs2, _centroid(b) - ca)
            d < bestd && ((best, bestd) = (j, d))
        end
        best == 0 && return nothing
        b = _align_vertices(a, other[best])
        isnothing(b) && return nothing
        used[best] = true
        aligned[i] = b
    end
    return aligned
end

_centroid(a) = SVector(sum(view(a, 1, :)), sum(view(a, 2, :))) / size(a, 2)

# The cyclic order (and direction) of the columns of `b` that matches `a`, when it is
# unambiguous: every vertex moves less than a quarter of the shortest edge of `a`.
function _align_vertices(a, b)
    n = size(a, 2)
    emin = minimum(
        hypot(a[1, mod1(i + 1, n)] - a[1, i], a[2, mod1(i + 1, n)] - a[2, i]) for i = 1:n
    )
    j0 = argmin([hypot(b[1, j] - a[1, 1], b[2, j] - a[2, 1]) for j = 1:n])
    best, bestd = nothing, Inf
    for dir in (1, -1)
        idx = [mod1(j0 + dir * (i - 1), n) for i = 1:n]
        d = maximum(hypot(b[1, idx[i]] - a[1, i], b[2, idx[i]] - a[2, i]) for i = 1:n)
        d < bestd && ((best, bestd) = (idx, d))
    end
    bestd < emin / 4 || return nothing
    return b[:, best]
end

# Set velocities below round-off of the layout's coordinates to exactly zero, so that fixed
# geometry is exactly fixed. Return whether anything moves.
function _snap_velocities!(vel)
    vmax = 0.0
    for loops in vel, v in loops, j in axes(v, 2)
        vmax = max(vmax, hypot(v[1, j], v[2, j]))
    end
    iszero(vmax) && return false
    tol = 1e-6 * vmax
    for loops in vel, v in loops, j in axes(v, 2)
        hypot(v[1, j], v[2, j]) < tol && (v[:, j] .= 0.0)
    end
    return true
end

_moves(vel, i, l, k) = any(v -> !iszero(v[i][l][1, k]) || !iszero(v[i][l][2, k]), vel)

function _velocity_window(base, vel, window, margin)
    if !isnothing(window)
        window isa Rectangle ||
            throw(ArgumentError("window must be a Rectangle, got $(typeof(window))"))
        ll, ur = lowerleft(window), upperright(window)
        win = (_stp_float(ll.x), _stp_float(ur.x), _stp_float(ll.y), _stp_float(ur.y))
        # The field vanishes outside the window, which must contain every moving vertex.
        for (i, e) in enumerate(base), (l, loop) in enumerate(e.loops), k in axes(loop, 2)
            _moves(vel, i, l, k) || continue
            x, y = loop[1, k], loop[2, k]
            (win[1] < x < win[2] && win[3] < y < win[4]) || error(
                "The design velocity window does not contain the moving geometry of layer $(layer(e.meta)) at ($x, $y) μm; enlarge the window"
            )
        end
        return win
    end
    xmin, xmax, ymin, ymax = Inf, -Inf, Inf, -Inf
    for (i, e) in enumerate(base), (l, loop) in enumerate(e.loops)
        n = size(loop, 2)
        for k = 1:n
            # An edge with a moving endpoint moves, so all of it belongs in the window.
            (
                _moves(vel, i, l, k) ||
                _moves(vel, i, l, mod1(k + 1, n)) ||
                _moves(vel, i, l, mod1(k - 1, n))
            ) || continue
            xmin, xmax = min(xmin, loop[1, k]), max(xmax, loop[1, k])
            ymin, ymax = min(ymin, loop[2, k]), max(ymax, loop[2, k])
        end
    end
    isfinite(xmin) || error("no rendered geometry moves; cannot choose a window")
    m = isnothing(margin) ? max(xmax - xmin, ymax - ymin) / 2 : _stp_float(margin)
    m > 0 || throw(ArgumentError("the window margin must be positive"))
    return (xmin - m, xmax + m, ymin - m, ymax + m)
end

function _bbox_overlaps(loops, win)
    xmin, xmax, ymin, ymax = win
    for loop in loops
        (
            maximum(view(loop, 1, :)) < xmin ||
            minimum(view(loop, 1, :)) > xmax ||
            maximum(view(loop, 2, :)) < ymin ||
            minimum(view(loop, 2, :)) > ymax
        ) && continue
        return true
    end
    return false
end

_entity_moves(vel, i) = any(any(!iszero, l) for v in vel for l in v[i])

# The planes (z values) of entities with moving vertices.
function _moving_planes(base, vel)
    planes = Float64[]
    for (i, e) in enumerate(base)
        _entity_moves(vel, i) || continue
        any(z -> abs(z - e.z) <= VELOCITY_MERGE_ATOL, planes) || push!(planes, e.z)
    end
    return sort!(planes)
end

_onplane(e::_LayoutEntity, z) = abs(e.z - z) <= VELOCITY_MERGE_ATOL

function _plane_profile(base, vel, z, win, zlo, zhi)
    # The profile is 1 across the extrusions of the moving entities on the plane.
    a, b = z, z
    moving = Symbol[]
    for (i, e) in enumerate(base)
        (_onplane(e, z) && _entity_moves(vel, i)) || continue
        a, b = min(a, e.z + e.thickness), max(b, e.z + e.thickness)
        layer(e.meta) in moving || push!(moving, layer(e.meta))
    end
    below, above = zlo, zhi
    for e in base
        _bbox_overlaps(e.loops, win) || continue
        for w in (e.z, e.z + e.thickness)
            if w < a - VELOCITY_MERGE_ATOL
                below = max(below, w)
            elseif w > b + VELOCITY_MERGE_ATOL
                above = min(above, w)
            elseif !_onplane(e, z) && a + VELOCITY_MERGE_ATOL < w < b - VELOCITY_MERGE_ATOL
                error(
                    "Rendered geometry on layer $(layer(e.meta)) at z = $w lies within the " *
                    "extrusion from z = $a to $b of moving geometry on layers $(join(moving, ", ")); " *
                    "only sheets and extrusions that contain no other geometry can move"
                )
            end
        end
    end
    (zlo <= a && b <= zhi) ||
        error("The moving geometry at z = $z is outside zlimits = ($zlo, $zhi)")
    (isfinite(below) && isfinite(above)) || error(
        "No rendered geometry bounds the design velocity of the plane z = $z " *
        (isfinite(below) ? "above" : "below") *
        "; pass `zlimits`."
    )
    return (a, b), (below, above)
end

######## In-plane field

# A planar arrangement of the rendered edges in the window: merged vertices with velocities
# (2 rows per parameter), and segments that cross or touch only at shared vertices.
struct _Arrangement
    window::NTuple{4, Float64}
    points::Vector{SVector{2, Float64}}
    velocities::Vector{Vector{Float64}}
    segments::Vector{NTuple{2, Int}}
    cell::Float64
    lookup::Dict{NTuple{2, Int}, Vector{Int}}
end

function _Arrangement(window, cell)
    return _Arrangement(
        window,
        SVector{2, Float64}[],
        Vector{Float64}[],
        NTuple{2, Int}[],
        cell,
        Dict{NTuple{2, Int}, Vector{Int}}()
    )
end

_cellkey(arr, p) = (floor(Int, p[1] / arr.cell), floor(Int, p[2] / arr.cell))

function _velocity_tol(v)
    return 1e-6 * max(1.0, maximum(abs, v; init=0.0))
end

# Add a point (merging with an existing one) and return its index.
function _add_point!(arr::_Arrangement, p::SVector{2, Float64}, v::Vector{Float64})
    kx, ky = _cellkey(arr, p)
    for dx = -1:1, dy = -1:1
        for i in get(arr.lookup, (kx + dx, ky + dy), Int[])
            if hypot(arr.points[i][1] - p[1], arr.points[i][2] - p[2]) <=
               VELOCITY_MERGE_ATOL
                maximum(abs, arr.velocities[i] .- v) <= _velocity_tol(v) || error(
                    "Rendered features that touch at $(Tuple(p)) μm move apart; the parameter changes the layout's topology"
                )
                return i
            end
        end
    end
    push!(arr.points, p)
    push!(arr.velocities, v)
    push!(get!(arr.lookup, (kx, ky), Int[]), length(arr.points))
    return length(arr.points)
end

# Clip a segment to the window (Liang–Barsky) and return the parameter interval, or nothing.
function _clip_segment(win, a, b)
    xmin, xmax, ymin, ymax = win
    t0, t1 = 0.0, 1.0
    d = b - a
    for (p, q) in (
        (-d[1], a[1] - xmin),
        (d[1], xmax - a[1]),
        (-d[2], a[2] - ymin),
        (d[2], ymax - a[2])
    )
        if iszero(p)
            q < 0 && return nothing
        else
            r = q / p
            if p < 0
                t0 = max(t0, r)
            else
                t1 = min(t1, r)
            end
        end
    end
    return t0 < t1 ? (t0, t1) : nothing
end

function _on_window_boundary(win, p)
    xmin, xmax, ymin, ymax = win
    tol = VELOCITY_MERGE_ATOL
    return abs(p[1] - xmin) <= tol ||
           abs(p[1] - xmax) <= tol ||
           abs(p[2] - ymin) <= tol ||
           abs(p[2] - ymax) <= tol
end

function _arrangement(base, vel, z, win)
    xmin, xmax, ymin, ymax = win
    arr = _Arrangement(win, max(xmax - xmin, ymax - ymin) / 1e4)
    np = length(vel)
    vertex_velocity(i, l, k) = vcat((v[i][l][:, k] for v in vel)...)
    for (i, e) in enumerate(base)
        (_onplane(e, z) && _bbox_overlaps(e.loops, win)) || continue
        for (l, loop) in enumerate(e.loops)
            n = size(loop, 2)
            for k = 1:n
                k2 = mod1(k + 1, n)
                a, b = SVector(loop[1, k], loop[2, k]), SVector(loop[1, k2], loop[2, k2])
                t = _clip_segment(win, a, b)
                isnothing(t) && continue
                va, vb = vertex_velocity(i, l, k), vertex_velocity(i, l, k2)
                ends = map(t) do s
                    p, v = a + s * (b - a), (1 - s) .* va .+ s .* vb
                    _on_window_boundary(win, p) &&
                        maximum(abs, v) > _velocity_tol(v) &&
                        error(
                            "The design velocity window cuts a moving edge of layer $(layer(e.meta)) at $(Tuple(p)) μm; enlarge the window"
                        )
                    return _add_point!(arr, p, v)
                end
                ends[1] != ends[2] && push!(arr.segments, minmax(ends...))
            end
        end
    end
    unique!(arr.segments)
    _split_segments!(arr, np)
    return arr
end

# A uniform grid over the window listing the segments whose bounding box overlaps each cell.
struct _SegmentGrid
    origin::NTuple{2, Float64}
    cell::NTuple{2, Float64}
    cells::Dict{NTuple{2, Int}, Vector{Int}}
end

function _SegmentGrid(arr::_Arrangement)
    xmin, xmax, ymin, ymax = arr.window
    nc = max(1, round(Int, sqrt(length(arr.segments))))
    grid = _SegmentGrid(
        (xmin, ymin),
        ((xmax - xmin) / nc, (ymax - ymin) / nc),
        Dict{NTuple{2, Int}, Vector{Int}}()
    )
    for (s, (i, j)) in enumerate(arr.segments)
        p, q = arr.points[i], arr.points[j]
        (i0, j0), (i1, j1) = _cellindex(grid, min.(p, q)), _cellindex(grid, max.(p, q))
        for cx = i0:i1, cy = j0:j1
            push!(get!(grid.cells, (cx, cy), Int[]), s)
        end
    end
    return grid
end

_cellindex(g::_SegmentGrid, p) = (
    floor(Int, (p[1] - g.origin[1]) / g.cell[1]),
    floor(Int, (p[2] - g.origin[2]) / g.cell[2])
)

# Split the segments at their crossings and at vertices that lie on them, so that segments
# meet only at shared endpoints, and give each crossing the velocity it moves with.
function _split_segments!(arr::_Arrangement, np)
    segs = arr.segments
    splits = [Tuple{Float64, Int}[] for _ in segs]
    grid = _SegmentGrid(arr)
    tested = Set{NTuple{2, Int}}()
    for candidates in values(grid.cells), s1 in candidates, s2 in candidates
        s1 < s2 || continue
        (s1, s2) in tested && continue
        push!(tested, (s1, s2))
        _intersect_segments!(arr, splits, s1, s2, np)
    end
    newsegs = NTuple{2, Int}[]
    for (s, (i, j)) in enumerate(segs)
        chain = vcat([(0.0, i)], sort!(splits[s]), [(1.0, j)])
        for k = 1:(length(chain) - 1)
            a, b = chain[k][2], chain[k + 1][2]
            a != b && push!(newsegs, minmax(a, b))
        end
    end
    empty!(segs)
    return append!(segs, unique!(newsegs))
end

_cross(a, b) = a[1] * b[2] - a[2] * b[1]

function _intersect_segments!(arr, splits, s1, s2, np)
    (a, b), (c, d) = arr.segments[s1], arr.segments[s2]
    A, B, C, D = arr.points[a], arr.points[b], arr.points[c], arr.points[d]
    # Endpoints of one segment on the interior of the other: T-junctions and collinear
    # overlaps. The vertex keeps its velocity, which must keep it on the other segment.
    touching = false
    for (s, (p, q), P, Q, e, E) in (
        (s2, (c, d), C, D, a, A),
        (s2, (c, d), C, D, b, B),
        (s1, (a, b), A, B, c, C),
        (s1, (a, b), A, B, d, D)
    )
        e in (p, q) && continue
        t = _on_segment(E, P, Q)
        isnothing(t) && continue
        vint = (1 - t) .* arr.velocities[p] .+ t .* arr.velocities[q]
        n = SVector(-(Q - P)[2], (Q - P)[1]) / hypot((Q - P)...)
        for k = 1:np
            δ = arr.velocities[e][(2k - 1):(2k)] .- vint[(2k - 1):(2k)]
            abs(n[1] * δ[1] + n[2] * δ[2]) <= _velocity_tol(arr.velocities[e]) || error(
                "A rendered vertex at $(Tuple(E)) μm leaves the edge it lies on; the parameter changes the layout's topology"
            )
        end
        push!(splits[s], (t, e))
        touching = true
    end
    # Proper crossings, of segments that do not already touch: a vertex within the merge
    # tolerance of the other segment is a T-junction, not a crossing.
    (touching || length(intersect((a, b), (c, d))) > 0) && return
    o1 = orientation(Point(A...), Point(B...), Point(C...))
    o2 = orientation(Point(A...), Point(B...), Point(D...))
    o3 = orientation(Point(C...), Point(D...), Point(A...))
    o4 = orientation(Point(C...), Point(D...), Point(B...))
    (o1 * o2 < 0 && o3 * o4 < 0) || return
    r, u = B - A, D - C
    den = _cross(r, u)
    s = _cross(C - A, u) / den
    t = _cross(C - A, r) / den
    X = A + s * r
    v = zeros(2np)
    for k = 1:np
        idx = (2k - 1):(2k)
        dA, dB = arr.velocities[a][idx], arr.velocities[b][idx]
        dC, dD = arr.velocities[c][idx], arr.velocities[d][idx]
        # Differentiate A + s (B - A) = C + t (D - C) with respect to the parameter.
        rhs = dC .+ t .* (dD .- dC) .- dA .- s .* (dB .- dA)
        ds = _cross(rhs, u) / den
        v[idx] .= dA .+ ds .* r .+ s .* (dB .- dA)
    end
    x = _add_point!(arr, X, v)
    push!(splits[s1], (s, x))
    push!(splits[s2], (t, x))
    return
end

# The parameter of `E` on the interior of segment PQ, or nothing.
function _on_segment(E, P, Q)
    d = Q - P
    L2 = d[1]^2 + d[2]^2
    t = ((E - P)[1] * d[1] + (E - P)[2] * d[2]) / L2
    (0 < t < 1) || return nothing
    abs(_cross(E - P, d)) / sqrt(L2) <= VELOCITY_MERGE_ATOL || return nothing
    return t
end

function _plane_velocity(base, vel, z, win, triangle_size, min_angle)
    np = length(vel)
    arr = _arrangement(base, vel, z, win)
    xmin, xmax, ymin, ymax = win
    # The window boundary, counterclockwise, through every arrangement point on it.
    zero2 = zeros(2np)
    for p in ((xmin, ymin), (xmax, ymin), (xmax, ymax), (xmin, ymax))
        _add_point!(arr, SVector(p...), zero2)
    end
    along_boundary(p) =
        abs(p[2] - ymin) <= VELOCITY_MERGE_ATOL ? (p[1] - xmin) :
        abs(p[1] - xmax) <= VELOCITY_MERGE_ATOL ? (xmax - xmin) + (p[2] - ymin) :
        abs(p[2] - ymax) <= VELOCITY_MERGE_ATOL ?
        2(xmax - xmin) + (ymax - ymin) - (p[1] - xmin) :
        2(xmax - xmin) + 2(ymax - ymin) - (p[2] - ymin)
    onboundary =
        [i for i in eachindex(arr.points) if _on_window_boundary(win, arr.points[i])]
    sort!(onboundary, by=i -> along_boundary(arr.points[i]))
    boundary_nodes = vcat(onboundary, onboundary[1])
    isboundary = falses(length(arr.points))
    isboundary[onboundary] .= true
    interior = Set(
        (i, j) for (i, j) in arr.segments if !(
            isboundary[i] && isboundary[j] && _same_side(win, arr.points[i], arr.points[j])
        )
    )
    rng = Random.Xoshiro(20250101)
    tri = DelaunayTriangulation.triangulate(
        [(p[1], p[2]) for p in arr.points];
        boundary_nodes=boundary_nodes,
        segments=interior,
        rng=rng
    )
    h =
        isnothing(triangle_size) ? max(xmax - xmin, ymax - ymin) / 40 :
        _stp_float(triangle_size)
    DelaunayTriangulation.refine!(
        tri;
        min_angle=_degrees(min_angle),
        max_area=sqrt(3) / 4 * h^2,
        rng=rng
    )
    return _harmonic_fields(tri, arr, np)
end

_degrees(θ::Real) = Float64(θ)
_degrees(θ) = Float64(ustrip(°, θ))

_same_side(win, p, q) = any(
    abs(p[c] - w) <= VELOCITY_MERGE_ATOL && abs(q[c] - w) <= VELOCITY_MERGE_ATOL for
    (c, w) in ((1, win[1]), (1, win[2]), (2, win[3]), (2, win[4]))
)

# Harmonic interpolation of the arrangement's velocities on the refined triangulation: the
# velocities at points on constrained edges and the window boundary, P1 harmonic elsewhere.
function _harmonic_fields(tri, arr::_Arrangement, np)
    DT = DelaunayTriangulation
    n = DT.num_points(tri)
    n0 = length(arr.points)
    pts = zeros(2, n)
    for i = 1:n
        p = DT.get_point(tri, i)
        pts[1, i], pts[2, i] = p[1], p[2]
    end
    values = zeros(2np, n)
    dirichlet = falses(n)
    for i = 1:n0
        values[:, i] .= arr.velocities[i]
        dirichlet[i] = true
    end
    # Steiner points on the window boundary, where the field vanishes.
    for i = (n0 + 1):n
        dirichlet[i] = _on_window_boundary(arr.window, SVector(pts[1, i], pts[2, i]))
    end
    # Steiner points that refinement put on constrained edges take the edge's velocity.
    onsegment = Set{Int}()
    for (i, j) in DT.get_interior_segments(tri)
        i > n0 && push!(onsegment, i)
        j > n0 && push!(onsegment, j)
    end
    _interpolate_on_segments!(values, dirichlet, pts, onsegment, arr)
    triangles = Int32[]
    for T in DT.each_solid_triangle(tri)
        i, j, k = DT.triangle_vertices(T)
        append!(triangles, (i, j, k))
    end
    triangles = reshape(triangles, 3, :)
    used = falses(n)
    used[vec(triangles)] .= true
    dirichlet .|= .!used
    _solve_harmonic!(values, dirichlet, pts, triangles)
    mesh = _plane_mesh(arr.window, pts, triangles)
    return mesh, [values[(2k - 1):(2k), :] for k = 1:np]
end

function _interpolate_on_segments!(values, dirichlet, pts, onsegment, arr)
    isempty(onsegment) && return
    grid = _SegmentGrid(arr)
    for i in onsegment
        p = SVector(pts[1, i], pts[2, i])
        found = false
        for s in get(grid.cells, _cellindex(grid, p), Int[])
            a, b = arr.segments[s]
            t = _on_segment(p, arr.points[a], arr.points[b])
            isnothing(t) && continue
            values[:, i] .= (1 - t) .* arr.velocities[a] .+ t .* arr.velocities[b]
            dirichlet[i] = true
            found = true
            break
        end
        found || error("internal error: a refinement point is not on any constrained edge")
    end
end

function _solve_harmonic!(values, dirichlet, pts, triangles)
    n = size(pts, 2)
    I, J, K = Int[], Int[], Float64[]
    for t in axes(triangles, 2)
        v = view(triangles, :, t)
        x = SVector(pts[1, v[1]], pts[1, v[2]], pts[1, v[3]])
        y = SVector(pts[2, v[1]], pts[2, v[2]], pts[2, v[3]])
        area2 = (x[2] - x[1]) * (y[3] - y[1]) - (x[3] - x[1]) * (y[2] - y[1])
        # Gradients of the barycentric coordinates, times twice the area.
        gx = SVector(y[2] - y[3], y[3] - y[1], y[1] - y[2])
        gy = SVector(x[3] - x[2], x[1] - x[3], x[2] - x[1])
        for a = 1:3, b = 1:3
            push!(I, v[a])
            push!(J, v[b])
            push!(K, (gx[a] * gx[b] + gy[a] * gy[b]) / (2 * abs(area2)))
        end
    end
    A = SparseArrays.sparse(I, J, K, n, n)
    free = findall(.!dirichlet)
    isempty(free) && return values
    fixed = findall(dirichlet)
    Aff = A[free, free]
    rhs = -(A[free, fixed] * permutedims(values[:, fixed]))
    for c in axes(rhs, 2)
        values[c, free] .= _conjugate_gradient(Aff, rhs[:, c])
    end
    return values
end

# Jacobi-preconditioned conjugate gradients for the symmetric positive definite P1
# Laplacian. Iterative, in Julia, so that design velocities do not load a sparse direct
# solver library (whose OpenMP runtime can conflict with the one Gmsh is linked with).
function _conjugate_gradient(A, b; rtol=1e-13)
    x = zeros(length(b))
    nb = LinearAlgebra.norm(b)
    iszero(nb) && return x
    d = LinearAlgebra.diag(A)
    r = copy(b)
    z = r ./ d
    p = copy(z)
    rz = LinearAlgebra.dot(r, z)
    Ap = similar(b)
    for _ = 1:(10 * length(b))
        LinearAlgebra.mul!(Ap, A, p)
        α = rz / LinearAlgebra.dot(p, Ap)
        x .+= α .* p
        r .-= α .* Ap
        LinearAlgebra.norm(r) <= rtol * nb && return x
        z .= r ./ d
        rz, rzold = LinearAlgebra.dot(r, z), rz
        p .= z .+ (rz / rzold) .* p
    end
    return error("internal error: the in-plane harmonic interpolation did not converge")
end

function _plane_mesh(window, pts, triangles)
    xmin, xmax, ymin, ymax = window
    nt = size(triangles, 2)
    nc = max(1, round(Int, sqrt(nt / 2)))
    nx = max(1, round(Int, nc * sqrt((xmax - xmin) / (ymax - ymin))))
    ny = max(1, round(Int, nt / 2 / nx))
    cw, ch = (xmax - xmin) / nx, (ymax - ymin) / ny
    lists = [Int32[] for _ = 1:(nx * ny)]
    for t = 1:nt
        v = view(triangles, :, t)
        x0, x1 = extrema(pts[1, v])
        y0, y1 = extrema(pts[2, v])
        i0 = clamp(floor(Int, (x0 - xmin) / cw) + 1, 1, nx)
        i1 = clamp(floor(Int, (x1 - xmin) / cw) + 1, 1, nx)
        j0 = clamp(floor(Int, (y0 - ymin) / ch) + 1, 1, ny)
        j1 = clamp(floor(Int, (y1 - ymin) / ch) + 1, 1, ny)
        for j = j0:j1, i = i0:i1
            push!(lists[(j - 1) * nx + i], t)
        end
    end
    offsets = Int32[1]
    for l in lists
        push!(offsets, offsets[end] + length(l))
    end
    return _PlaneMesh(
        window,
        pts,
        triangles,
        (cw, ch),
        (nx, ny),
        offsets,
        reduce(vcat, lists; init=Int32[])
    )
end
