
function _optimize_bspline!(b::BSpline)
    scale0 = norm(b.p[2] - b.p[1])
    scale1 = norm(b.p[end] - b.p[end - 1])
    if _symmetric_optimization(b)
        errfunc_sym(p) = _int_dκdt_2(b, p[1], scale0)
        p = Optim.minimizer(optimize(errfunc_sym, [1.0]))
        b.t0 = p[1] * (b.t0 / norm(b.t0)) * scale0
        b.t1 = p[1] * (b.t1 / norm(b.t1)) * scale0
    else
        errfunc_asym(p) = _int_dκdt_2(b, p[1], p[2], scale0, scale1)
        p = Optim.minimizer(optimize(errfunc_asym, [1.0, 1.0]))
        b.t0 = p[1] * (b.t0 / norm(b.t0)) * scale0
        b.t1 = p[2] * (b.t1 / norm(b.t1)) * scale1
    end
    return _update_interpolation!(b)
end

# True iff endpoints_speed should be assumed to be equal for optimization
# I.e., tangent directions, endpoints, and waypoints have mirror or 180° symmetry
function _symmetric_optimization(b::BSpline{T}) where {T}
    center = (b.p0 + b.p1) / 2
    # 180 rotation?
    if α0(b) ≈ α1(b)
        return isapprox(
            reverse(RotationPi(; around_pt=center).(b.p)),
            b.p,
            atol=1e-3 * DeviceLayout.onenanometer(T)
        )
    end

    # Reflection?
    mirror_axis = Point(-(b.p1 - b.p0).y, (b.p1 - b.p0).x)
    refl = Reflection(mirror_axis; through_pt=center)
    return isapprox_angle(α1(b), -rotated_direction(α0(b), refl)) &&
           isapprox(reverse(refl.(b.p)), b.p, atol=1e-3 * DeviceLayout.onenanometer(T))
end

# Third derivative of Cubic BSpline (piecewise constant)
d3_weights(::Interpolations.Cubic, _) = (-1, 3, -3, 1)
function d3r_dt3!(J, r, t)
    n_rescale = (length(r.itp.coefs) - 2) - 1
    wis = Interpolations.weightedindexes(
        (d3_weights,),
        Interpolations.itpinfo(r)...,
        (t * n_rescale + 1,)
    )
    return J[1] = Interpolations.symmatrix(
        map(inds -> Interpolations.InterpGetindex(r)[inds...], wis)
    )[1]
end

# Derivative of curvature with respect to pathlength
# As a function of BSpline parameter
function dκdt_scaled!(
    b::BSpline{T},
    t::Float64,
    G::AbstractArray{Point{T}},
    H::AbstractArray{Point{T}},
    J::AbstractArray{Point{T}}
) where {T}
    Paths.Interpolations.gradient!(G, b.r, t)
    Paths.Interpolations.hessian!(H, b.r, t)
    d3r_dt3!(J, b.r, t)
    g = G[1]
    h = H[1]
    j = J[1]

    dκdt = ( # d/dt ((g.x*h.y - g.y*h.x) / ||g||^3)
        (g.x * j.y - g.y * j.x) / norm(g)^3 +
        -3 * (g.x * h.y - g.y * h.x) * (g.x * h.x + g.y * h.y) / norm(g)^5
    )
    # Return so that (dκ/dt)^2 will be normalized by speed
    # So we can integrate over t and retain scale independence
    return dκdt / sqrt(norm(g))
end

# Integrated square of curvature derivative (scale free)
function _int_dκdt_2(b::BSpline{T}, t0, t1, scale0::T, scale1::T) where {T}
    b.t0 = t0 * (b.t0 / norm(b.t0)) * scale0
    b.t1 = t1 * (b.t1 / norm(b.t1)) * scale1
    _update_interpolation!(b)
    return _int_dκdt_2(b, sqrt(scale0 * scale1))
end
# Symmetric version
function _int_dκdt_2(b::BSpline{T}, t0, scale0::T) where {T}
    b.t0 = t0 * (b.t0 / norm(b.t0)) * scale0
    b.t1 = t0 * (b.t1 / norm(b.t1)) * scale0
    _update_interpolation!(b)
    return _int_dκdt_2(b, scale0)
end

function _int_dκdt_2(b::BSpline{T}, scale::T) where {T}
    G = StaticArrays.@MVector [zero(Point{T})]
    H = StaticArrays.@MVector [zero(Point{T})]
    J = StaticArrays.@MVector [zero(Point{T})]

    return uconvert(
        NoUnits,
        quadgk(t -> scale^3 * (dκdt_scaled!(b, t, G, H, J))^2, 0.0, 1.0, rtol=1e-3)[1]
    )
end
