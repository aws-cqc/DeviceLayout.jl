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
    seg::Paths.Turn{T},
    s::Paths.Trace;
    atol=DeviceLayout.onenanometer(T),
    rtol=nothing,
    kwargs...
) where {T}
    grid = discretization_grid(seg, atol; rtol=rtol) * pathlength(seg)
    g = (t, sgn) -> begin
        d = Paths.direction(seg, t) + sgn * 90.0°
        return seg(t) + Paths.extent(s, t) * Point(cos(d), sin(d))
    end

    pts = [g.(grid, -1); @view (g.(grid, 1))[end:-1:1]]
    return Polygon(uniquepoints(pts))
end

function to_polygons(
    seg::Paths.OffsetSegment{T},
    s::Paths.Trace;
    atol=DeviceLayout.onenanometer(T),
    rtol=nothing,
    kwargs...
) where {T}
    return _to_polygons_via_bspline(seg, s; atol, rtol, kwargs...)
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
    rtol=nothing,
    kwargs...
) where {T}
    dir = sign(f.α)
    if !isnothing(rtol)
        atol = max(atol, rtol * (f.r + Paths.extent(s)))
    end
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
    rtol=nothing,
    kwargs...
) where {T}
    f = b.r

    g = (t, sgn) -> begin
        tng = Paths.Interpolations.gradient(f, t)[1]
        perp = sgn * Point(tng.y, -tng.x)
        return f(t) + perp * (Paths.extent(s) / norm(perp))
    end

    # Use base-spline true curvature as a surrogate for the offset curve's κ
    # (same "hess ≈ ddf ~ ddg" approximation the old code made, just
    # dimensionally correct). Forwards `rtol` to `discretize_curve`.
    κ(t) = _bspline_curvature(f, t)

    ppts = discretize_curve(r -> g(r, 1), κ, atol; rtol=rtol, t_scale=pathlength(b))
    mpts = discretize_curve(r -> g(r, -1), κ, atol; rtol=rtol, t_scale=pathlength(b))

    return Polygon(uniquepoints([ppts; @view mpts[end:-1:1]]))
end

function to_polygons(
    b::Paths.BSpline{T},
    tr::Paths.Trace;
    atol=DeviceLayout.onenanometer(T),
    rtol=nothing,
    kwargs...
) where {T}
    f = b.r
    arclength(t) = Paths.t_to_arclength(b, t)
    # Same base-spline-κ surrogate as the SimpleTrace method above.
    κ(t) = _bspline_curvature(f, t)

    g = (t, sgn) -> begin
        s = arclength(t)
        tng = Paths.Interpolations.gradient(f, t)[1]
        perp = sgn * Point(tng.y, -tng.x)
        return f(t) + perp * (Paths.extent(tr, s) / norm(perp))
    end

    ppts = discretize_curve(r -> g(r, 1), κ, atol; rtol=rtol, t_scale=pathlength(b))
    mpts = discretize_curve(r -> g(r, -1), κ, atol; rtol=rtol, t_scale=pathlength(b))
    return Polygon(uniquepoints([ppts; @view mpts[end:-1:1]]))
end
