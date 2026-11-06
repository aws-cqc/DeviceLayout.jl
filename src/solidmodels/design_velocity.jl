######## Design velocities
#
# A design velocity is the derivative of the position of every point of a rendered solid
# model with respect to one layout parameter. It is built from the 2D layout alone, before
# any meshing, so that it can be evaluated at the nodes of any mesh of the model:
#
#   - geometry preparation (design_geometry.jl): the boundary loops that the layout renders;
#   - boundary derivatives (design_derivatives.jl): the velocities of their vertices;
#   - the in-plane field (design_field.jl): a harmonic interpolation of the vertex
#     velocities on a constrained triangulation of a window around the moving geometry;
#   - the design velocity (this file): the in-plane field of each moving plane, extended
#     into 3D by an extrusion profile in z.

import Unitful
import DeviceLayout: Rectangle, lowerleft, upperright

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
be given otherwise. The differences are exact for vertices that are affine in the
parameters, and second order in the step otherwise, provided that each vertex is the same
point of the geometry at `p0 ± steps[k]`. Arcs are sampled uniformly in angle, so this holds
while their number of vertices is unchanged. Other curves, such as B-splines, are sampled
adaptively, so they may only move rigidly.

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
boundary loops or vertices, or whether features touch), when it changes the shape of a curve
other than a line or an arc, when the window does not contain all moving geometry, when a
parameter changes the z or thickness of an entity, or when nothing bounds the profile in z.
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
    prepare(p) = _layout_entities(f(p), map_meta, zmap, thickness; kwargs...)
    base, velocities, units = _boundary_velocities(prepare, p0, names, steps)
    return _design_velocities(
        names,
        units,
        base,
        velocities;
        window,
        margin,
        zlimits,
        triangle_size,
        min_angle
    )
end

# The design velocities of the parameters `names` that extend the vertex velocities of the
# geometry `base`: the in-plane field of each moving plane, and its extrusion profile.
function _design_velocities(
    names,
    units,
    base,
    velocities;
    window,
    margin,
    zlimits,
    triangle_size,
    min_angle
)
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
