function to_polygons(f, len, s::Paths.Trace; kwargs...)
    bnds = (zero(len), len)

    g = (t, sgn) -> begin
        d = Paths.direction(f, t) + sgn * 90.0°
        return f(t) + Paths.extent(s, t) * Point(cos(d), sin(d))
    end

    pgrid = adapted_grid(t -> Paths.direction(r -> g(r, 1), t), bnds; kwargs...)
    mgrid = adapted_grid(t -> Paths.direction(r -> g(r, -1), t), bnds; kwargs...)

    pts = [g.(mgrid, -1); @view (g.(pgrid, 1))[end:-1:1]]
    return Polygon(uniquepoints(pts))
end

function to_polygons(
    seg::Paths.OffsetSegment{T},
    s::Paths.Trace;
    atol=DeviceLayout.onenanometer(T),
    kwargs...
) where {T}
    bsp = Paths.bspline_approximation(seg; atol)
    return to_polygons(bsp, s; atol, kwargs...)
end

function to_polygons(segment::Paths.Straight{T}, s::Paths.SimpleTrace; kwargs...) where {T}
    dir = direction(segment, zero(T))
    dp, dm = dir + 90.0°, dir - 90.0°

    ext = Paths.extent(s, zero(T))
    tangents = StaticArrays.@SVector [
        ext * Point(cos(dm), sin(dm)),
        ext * Point(cos(dm), sin(dm)),
        ext * Point(cos(dp), sin(dp)),
        ext * Point(cos(dp), sin(dp))
    ]

    a, b = segment(zero(T)), segment(pathlength(segment))
    origins = StaticArrays.@SVector [a, b, b, a]

    return Polygon(origins .+ tangents)
end

function to_polygons(
    f::Paths.Turn{T},
    s::Paths.SimpleTrace;
    atol=DeviceLayout.onenanometer(T),
    kwargs...
) where {T}
    dir = sign(f.α)
    # Use the same θ step for all curves, worst case is outer curve
    dθ_max = 2 * sqrt(2 * atol / (f.r + Paths.extent(s))) # r - r cos dθ/2 ≈ tolerance
    pts(sgn::Int) = circular_arc(
        f.α0 - dir * 90°,
        f.α0 + f.α - dir * 90°,
        dθ_max,
        f.r + dir * sgn * Paths.trace(s) / 2,
        Paths.curvaturecenter(f)
    )

    return Polygon([pts(1); @view pts(-1)[end:-1:1]])
end

function to_polygons(
    b::Paths.BSpline{T},
    s::Paths.SimpleTrace;
    atol=DeviceLayout.onenanometer(T),
    kwargs...
) where {T}
    f = b.r

    g = (t, sgn) -> begin
        tng = Paths.Interpolations.gradient(f, t)[1]
        perp = sgn * Point(tng.y, -tng.x)
        return f(t) + perp * (Paths.extent(s) / norm(perp))
    end

    hess(t) = Paths.Interpolations.hessian(f, t)[1]

    # Assume hess = ddf ~ ddg
    # And d^2 s / dt^2 is small
    ppts = discretize_curve(r -> g(r, 1), hess, atol)
    mpts = discretize_curve(r -> g(r, -1), hess, atol)

    return Polygon(uniquepoints([ppts; @view mpts[end:-1:1]]))
end

function to_polygons(
    b::Paths.BSpline{T},
    tr::Paths.Trace;
    atol=DeviceLayout.onenanometer(T),
    kwargs...
) where {T}
    f = b.r
    arclength(t) = Paths.t_to_arclength(b, t)
    hess(t) = Paths.Interpolations.hessian(f, t)[1]

    g = (t, sgn) -> begin
        s = arclength(t)
        tng = Paths.Interpolations.gradient(f, t)[1]
        perp = sgn * Point(tng.y, -tng.x)
        return f(t) + perp * (Paths.extent(tr, s) / norm(perp))
    end

    # Assume hess = ddf ~ ddg
    # And d^2 s / dt^2 is small
    ppts = discretize_curve(r -> g(r, 1), hess, atol)
    mpts = discretize_curve(r -> g(r, -1), hess, atol)
    return Polygon(uniquepoints([ppts; @view mpts[end:-1:1]]))
end
