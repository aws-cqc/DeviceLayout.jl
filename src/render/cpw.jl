import Interpolations: hessian
import ForwardDiff: derivative

"""
    cpw_points(f, s, scaler=identity)

Return an anonymous function of `(t, sgn1, sgn2)` that returns points in the cross-section
of the CPW defined by curve `f` and style `s`. `sgn1` and `sgn2` must be 1 or -1 and
determine which point is returned.

From left to right facing the direction of the curve, you can return the points defining
the cross section as `f(t, 1, 1), f(t, 1, -1), f(t, -1, -1), f(t, -1, 1)`.
"""
function cpw_points(f, s, scaler=identity)
    return (t, sgn1::Int, sgn2::Int) -> begin
        if !(abs2(sgn1) == abs2(sgn2) == 1)
            throw(ArgumentError("sgn1 and sgn2 must be 1 or -1"))
        end
        tng = Paths.ForwardDiff.derivative(f, t)
        perp = sgn1 * Point(-tng.y, tng.x)

        tt = scaler(t)
        offset = (Paths.gap(s, tt) + Paths.trace(s, tt)) / 2
        return f(t) + perp * ((sgn2 * Paths.gap(s, tt) / 2 + offset) / norm(perp))
    end
end

function cpw_points(f::Paths.BSpline{T}, s::Paths.CPW) where {T}
    arclength(t) = Paths.t_to_arclength(f, t)
    return cpw_points(f.r, s, arclength)
end

function to_polygons(f, len, s::Paths.CPW; kwargs...)
    g = cpw_points(f, s)

    bnds = (zero(len), len)
    ppgrid = adapted_grid(t -> Paths.direction(r -> g(r, 1, 1), t), bnds; kwargs...)
    pmgrid = adapted_grid(t -> Paths.direction(r -> g(r, 1, -1), t), bnds; kwargs...)
    mmgrid = adapted_grid(t -> Paths.direction(r -> g(r, -1, -1), t), bnds; kwargs...)
    mpgrid = adapted_grid(t -> Paths.direction(r -> g(r, -1, 1), t), bnds; kwargs...)

    ppts = [g.(pmgrid, 1, -1); @view (g.(ppgrid, 1, 1))[end:-1:1]]
    mpts = [g.(mpgrid, -1, 1); @view (g.(mmgrid, -1, -1))[end:-1:1]]

    return [Polygon(uniquepoints(ppts)), Polygon(uniquepoints(mpts))]
end

function to_polygons(
    seg::Paths.Turn{T},
    s::Paths.CPW;
    atol=DeviceLayout.onenanometer(T),
    rtol=nothing,
    kwargs...
) where {T}
    g = cpw_points(seg, s)
    grid = discretization_grid(seg, atol; rtol=rtol) * pathlength(seg)

    ppts = [g.(grid, 1, -1); @view (g.(grid, 1, 1))[end:-1:1]]
    mpts = [g.(grid, -1, 1); @view (g.(grid, -1, -1))[end:-1:1]]

    return [Polygon(uniquepoints(ppts)), Polygon(uniquepoints(mpts))]
end

function to_polygons(
    seg::Paths.OffsetSegment{T},
    s::Paths.CPW;
    atol=DeviceLayout.onenanometer(T),
    rtol=nothing,
    kwargs...
) where {T}
    return _to_polygons_via_bspline(seg, s; atol, rtol, kwargs...)
end

function to_polygons(f::Paths.Straight{T}, s::Paths.SimpleCPW; kwargs...) where {T}
    g = cpw_points(f, s)

    t = StaticArrays.@SVector [zero(T), pathlength(f)]
    ppts = [g.(t, 1, -1); @view g.(t, 1, 1)[end:-1:1]]
    mpts = [g.(t, -1, 1); @view g.(t, -1, -1)[end:-1:1]]

    return [Polygon(ppts), Polygon(mpts)]
end

function to_polygons(
    f::Paths.Turn{T},
    s::Paths.SimpleCPW;
    atol=DeviceLayout.onenanometer(T),
    rtol=nothing,
    kwargs...
) where {T}
    dir = sign(f.α)
    if !isnothing(rtol)
        atol = max(atol, rtol * (f.r + Paths.extent(s)))
    end
    dθ_max = 2 * sqrt(2 * atol / (f.r + Paths.extent(s))) # r - r cos dθ/2 ≈ tolerance
    pts(sgn1::Int, sgn2::Int) = circular_arc(
        f.α0 - dir * 90°,
        f.α0 + f.α - dir * 90°,
        dθ_max,
        f.r +
        dir * sgn1 * (Paths.trace(s) / 2 + Paths.gap(s) / 2 - sgn2 * Paths.gap(s) / 2),
        Paths.curvaturecenter(f)
    )

    ppts = [pts(1, -1); @view pts(1, 1)[end:-1:1]]
    mpts = [pts(-1, 1); @view pts(-1, -1)[end:-1:1]]

    return [Polygon(ppts), Polygon(mpts)]
end

function to_polygons(
    f::Paths.BSpline{T},
    s::Paths.SimpleCPW;
    atol=DeviceLayout.onenanometer(T),
    rtol=nothing,
    kwargs...
) where {T}
    # since s will ignore arguments passed in, we can use f.r directly. should be faster.
    g = cpw_points(f.r, s)
    κ(t) = _bspline_curvature(f.r, t)

    ppts = [
        discretize_curve(r -> g(r, 1, -1), κ, atol; rtol=rtol, t_scale=pathlength(f))
        @view discretize_curve(r -> g(r, 1, 1), κ, atol; rtol=rtol, t_scale=pathlength(f))[end:-1:1]
    ]
    mpts = [
        discretize_curve(r -> g(r, -1, 1), κ, atol; rtol=rtol, t_scale=pathlength(f))
        @view discretize_curve(
            r -> g(r, -1, -1),
            κ,
            atol;
            rtol=rtol,
            t_scale=pathlength(f)
        )[end:-1:1]
    ]

    return [Polygon(uniquepoints(ppts)), Polygon(uniquepoints(mpts))]
end

function to_polygons(
    f::Paths.BSpline{T},
    s::Paths.CPW;
    atol=DeviceLayout.onenanometer(T),
    rtol=nothing,
    kwargs...
) where {T}
    g = cpw_points(f, s)
    κ(t) = _bspline_curvature(f.r, t)

    # trace/gap vary slowly vs. radius of curvature, so base-spline κ is an
    # acceptable surrogate for the offset curve's curvature.
    ppts = [
        discretize_curve(r -> g(r, 1, -1), κ, atol; rtol=rtol, t_scale=pathlength(f))
        @view discretize_curve(r -> g(r, 1, 1), κ, atol; rtol=rtol, t_scale=pathlength(f))[end:-1:1]
    ]
    mpts = [
        discretize_curve(r -> g(r, -1, 1), κ, atol; rtol=rtol, t_scale=pathlength(f))
        @view discretize_curve(
            r -> g(r, -1, -1),
            κ,
            atol;
            rtol=rtol,
            t_scale=pathlength(f)
        )[end:-1:1]
    ]

    return [Polygon(uniquepoints(ppts)), Polygon(uniquepoints(mpts))]
end
