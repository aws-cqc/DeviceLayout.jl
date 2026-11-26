######## Design velocities: boundary derivatives
#
# The velocities of the vertices of the prepared geometry with respect to each parameter,
# by central differences of the geometry at p0 ± h. The in-plane field and the profile
# depend only on these velocities, so other means of differentiation can replace this part.

import Unitful: NoUnits
import DeviceLayout: onenanometer

# The prepared geometry `prepare(p0)`, the velocities of its vertices with respect to each
# parameter in `names`, and the units of the parameters.
function _boundary_velocities(prepare, p0, names, steps)
    base = prepare(p0)
    isempty(base) && error("the layout has no rendered entities")
    velocities = Vector{Vector{Vector{Matrix{Float64}}}}(undef, length(names))
    units = Vector{Unitful.Units}(undef, length(names))
    for (j, k) in enumerate(names)
        h = _parameter_step(p0[k], get(steps, k, nothing), k)
        units[j] = _velocity_unit(p0[k])
        hfloat = _parameter_float(h, units[j], k)
        plus = prepare(merge(p0, NamedTuple{(k,)}((p0[k] + h,))))
        minus = prepare(merge(p0, NamedTuple{(k,)}((p0[k] - h,))))
        velocities[j] = _vertex_velocities(base, plus, minus, hfloat, k)
    end
    for (j, k) in enumerate(names)
        _snap_velocities!(velocities[j]) ||
            @warn "Parameter :$k does not move any rendered geometry; its design velocity is zero."
    end
    return base, velocities, units
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

_parameter_float(δ::Real, ::typeof(NoUnits), _) = Float64(δ)
function _parameter_float(δ, u, k)
    try
        return Float64(ustrip(u, δ))
    catch e
        e isa Unitful.DimensionError || rethrow()
        throw(ArgumentError("parameter change for :$k must have units of $u, got $δ"))
    end
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
        if isnothing(lp) || isnothing(lm)
            b.adaptive && _adaptive_error(k, b)
            _topology_error(
                k,
                "the boundary of an entity on layer $(layer(b.meta)) changed its number of loops or vertices"
            )
        end
        velocities[i] = [(lp[l] .- lm[l]) ./ (2h) for l in eachindex(b.loops)]
        b.adaptive && !_is_rigid(b.loops, velocities[i]) && _adaptive_error(k, b)
    end
    return velocities
end

_adaptive_error(k, b) = error(
    "Cannot compute the design velocity of :$k: it changes the shape of a curve on layer $(layer(b.meta)) that is not a line or an arc. Such curves, like B-splines, are discretized adaptively, so their vertices are not the same points of the curve at p0 ± step, and they may only move rigidly."
)

# Whether the vertex velocities `vel` of the loops `loops` are a rigid motion: a translation
# and a rotation, fitted by least squares about the centroid. The tolerance is far above the
# differences' round-off and far below the residual of a change of shape.
function _is_rigid(loops, vel)
    x, v = reduce(hcat, loops), reduce(hcat, vel)
    dx = x .- sum(x, dims=2) ./ size(x, 2)
    dv = v .- sum(v, dims=2) ./ size(v, 2)
    den = sum(abs2, dx)
    ω = iszero(den) ? 0.0 : sum(dx[1, :] .* dv[2, :] .- dx[2, :] .* dv[1, :]) / den
    residual = dv .- ω .* [-dx[2:2, :]; dx[1:1, :]]
    return maximum(abs, residual; init=0.0) <= 1e-4 * max(1.0, maximum(abs, v; init=0.0))
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
# unambiguous: the largest vertex displacement of the best of the orders near the nearest
# vertex is less than a quarter of that of any other.
function _align_vertices(a, b)
    n = size(a, 2)
    j0 = argmin([hypot(b[1, j] - a[1, 1], b[2, j] - a[2, 1]) for j = 1:n])
    best, bestd, second = nothing, Inf, Inf
    for dir in (1, -1), shift in unique(mod1.(j0 .+ (-2:2), n))
        idx = [mod1(shift + dir * (i - 1), n) for i = 1:n]
        d = maximum(hypot(b[1, idx[i]] - a[1, i], b[2, idx[i]] - a[2, i]) for i = 1:n)
        if d < bestd
            best, bestd, second = idx, d, bestd
        elseif d < second
            second = d
        end
    end
    bestd < second / 4 || return nothing
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
