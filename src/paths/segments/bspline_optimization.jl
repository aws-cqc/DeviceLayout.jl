
function _optimize_bspline!(b::BSpline; endpoints_curvature=nothing)
    scale0 = Point(cos(α0(b)), sin(α0(b))) * norm(b.p[2] - b.p[1])
    scale1 = Point(cos(α1(b)), sin(α1(b))) * norm(b.p[end] - b.p[end - 1])
    if _symmetric_optimization(b)
        errfunc_sym(p) = _int_dκ2(b, p[1], scale0, scale1; endpoints_curvature)
        p = Optim.minimizer(optimize(errfunc_sym, [1.0]))
        b.t0 = p[1] * scale0
        b.t1 = p[1] * scale1
    else
        errfunc_asym(p) = _int_dκ2(b, p[1], p[2], scale0, scale1; endpoints_curvature)
        p = Optim.minimizer(optimize(errfunc_asym, [1.0, 1.0]))
        b.t0 = p[1] * scale0
        b.t1 = p[2] * scale1
    end
    _set_endpoints_curvature!(b, endpoints_curvature)
    return _update_interpolation!(b)
end

function _set_endpoints_curvature!(::BSpline, ::Nothing; add_points=false) end
function _set_endpoints_curvature!(b::BSpline, κ0κ1; add_points=false)
    return _set_endpoints_curvature!(b, κ0κ1[1], κ0κ1[2]; add_points)
end

function _set_endpoints_curvature!(
    b::BSpline{T},
    κ0::Union{Float64, DeviceLayout.InverseLength}=0.0 / oneunit(T),
    κ1=κ0;
    add_points=false
) where {T}
    # Set waypoints after the start and before the end to fix curvature
    # Usually, interpolation coefficients c are solutions to Ac = b0
    # For tangent boundary condition, b0 = [t0, p..., t1]
    # And A is tridiagonal (1/6, 2/3, 16) except for first and last row
    # which are [-1/2, 0, 1/2, ...] and [..., -1/2, 0, 1/2] for tangent constraints
    # We'll add two rows so that p_2 and p_{n-1} are unknowns
    # Giving enough degrees of freedom to also constrain curvature
    # Then update both A and b0 to give the following equations:
    # 1/6 * c1 + 2/3 * c2 + 1/6 * c3 - p_2 = 0 (i.e. move p_2 to LHS)
    # c1 - 2 * c2 + c3 = h0 (where h is the second derivative)
    # And similarly for p_{n-1}
    # Then solve A * c = b0 for c, so that our new p_2 is c[n-1] and p_{n-1} is c[n]
    if add_points # Add extra waypoints rather than adjust existing ones
        insert!(b.p, 2, b.p[1])
        insert!(b.p, length(b.p), b.p[end])
        # Rescale gradient BC
        b.t0 = b.t0 * (length(b.p) - 3) / (length(b.p) - 1)
        b.t1 = b.t1 * (length(b.p) - 3) / (length(b.p) - 1)
    end
    # If there are only 4 points the formula is simple to write out
    if length(b.p) == 4 && iszero(κ0) && iszero(κ1)
        b.p .= [
            b.p[1],
            5 / 6 * b.p[1] + 2 / 3 * b.t0 + 1 / 6 * b.p[end] - b.t1 / 6,
            5 / 6 * b.p[end] - 2 / 3 * b.t1 + 1 / 6 * b.p[1] + b.t0 / 6,
            b.p[end]
        ]
        return
    end
    # Define LHS matrix
    n = length(b.p) + 4
    dl = fill(1 / 6, n - 1)
    d = fill(2 / 3, n)
    du = fill(1 / 6, n - 1)
    A = Array(Tridiagonal(dl, d, du))
    A[1, 1:3] .= [-1 / 2, 0, 1 / 2] # -c1/2 + c3/2 = g0
    A[3, n - 1] = -1 # c1/6 + 2c2/3 + c3/6 - p_2 = 0
    A[n - 4, n] = -1 # ... -p_{n-1} = 0
    A[n - 2, (n - 4):(n - 1)] .= [-1 / 2, 0, 1 / 2, 0] # g1, need to erase another tridiagonal too
    A[n - 1, :] .= 0 # erase tridiagonal for κ0
    A[n - 1, 1:3] .= [1, -2, 1] # c1 - 2c2 + c3 = h0
    A[n, :] .= 0 # κ1
    A[n, (n - 4):(n - 2)] .= [1, -2, 1] # κ1
    zer = zero(Point{T})
    # Set curvature with zero acceleration
    h0 = Point{T}(-b.t0.y * κ0 * norm(b.t0), b.t0.x * κ0 * norm(b.t0))
    h1 = Point{T}(-b.t1.y * κ1 * norm(b.t1), b.t1.x * κ1 * norm(b.t1))
    # RHS
    b0 = [b.t0, b.p[1], zer, b.p[3:(end - 2)]..., zer, b.p[end], b.t1, h0, h1]
    # Solve
    cx = A \ ustrip.(unit(T), getx.(b0))
    cy = A \ ustrip.(unit(T), gety.(b0))
    # Update points
    b.p[2] = oneunit(T) * Point(cx[n - 1], cy[n - 1])
    b.p[end - 1] = oneunit(T) * Point(cx[n], cy[n])
    # The rest of c already defines the interpolation
    # But we'll just use the usual constructor after this
    # when _update_interpolation! is called
    return
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
function _int_dκ2(
    b::BSpline{T},
    t0,
    t1,
    scale0::Point{T},
    scale1::Point{T};
    endpoints_curvature=nothing
) where {T}
    t0 <= zero(t0) || t1 <= zero(t1) && return Inf
    b.t0 = t0 * scale0
    b.t1 = t1 * scale1
    _set_endpoints_curvature!(b, endpoints_curvature)
    _update_interpolation!(b)
    return _int_dκ2(b, sqrt(norm(scale0) * norm(scale1)))
end

# Symmetric version
function _int_dκ2(
    b::BSpline{T},
    t0,
    scale0::Point{T},
    scale1::Point{T};
    endpoints_curvature=nothing
) where {T}
    t0 <= zero(t0) && return Inf
    b.t0 = t0 * scale0
    b.t1 = t0 * scale1
    _set_endpoints_curvature!(b, endpoints_curvature)
    _update_interpolation!(b)
    return _int_dκ2(b, sqrt(norm(scale0) * norm(scale1)))
end

function _int_dκ2(b::BSpline{T}, scale) where {T}
    G = StaticArrays.@MVector [zero(Point{T})]
    H = StaticArrays.@MVector [zero(Point{T})]
    J = StaticArrays.@MVector [zero(Point{T})]

    return uconvert(
        NoUnits,
        quadgk(t -> scale^3 * (dκdt_scaled!(b, t, G, H, J))^2, 0.0, 1.0, rtol=1e-3)[1]
    )
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
