
function _optimize_bspline!(b::BSpline)
    scale0 = Point(cos(α0(b)), sin(α0(b))) * norm(b.p[2] - b.p[1])
    scale1 = Point(cos(α1(b)), sin(α1(b))) * norm(b.p[end] - b.p[end - 1])
    if _symmetric_optimization(b)
        errfunc_sym(p) = _int_κ2(b, p[1], scale0, scale1)
        p = Optim.minimizer(optimize(errfunc_sym, [1.0]))
        b.t0 = p[1] * scale0
        b.t1 = p[1] * scale1
    else
        errfunc_asym(p) = _int_κ2(b, p[1], p[2], scale0, scale1)
        p = Optim.minimizer(optimize(errfunc_asym, [1.0, 1.0]))
        b.t0 = p[1] * scale0
        b.t1 = p[2] * scale1
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

# Integrated square of curvature derivative (scale free)
function _int_κ2(b::BSpline{T}, t0, t1, scale0::Point{T}, scale1::Point{T}) where {T}
    t0 <= zero(t0) || t1 <= zero(t1) && return Inf
    b.t0 = t0 * scale0
    b.t1 = t1 * scale1
    _update_interpolation!(b)
    return _int_κ2(b)
end

# Symmetric version
function _int_κ2(b::BSpline{T}, t0, scale0::Point{T}, scale1::Point{T}) where {T}
    t0 <= zero(t0) && return Inf
    b.t0 = t0 * scale0
    b.t1 = t0 * scale1
    _update_interpolation!(b)
    return _int_κ2(b)
end

function _int_κ2(b::BSpline{T}) where {T}
    G = StaticArrays.@MVector [zero(Point{T})]
    H = StaticArrays.@MVector [zero(Point{T})]
    return uconvert(
        NoUnits,
        quadgk(t -> _curvature_arclength!(b, G, H, t)^2, 0.0, 1.0, rtol=1e-3)[1]
    )
end
