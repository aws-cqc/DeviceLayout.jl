function to_polygons(f, len, s::Paths.Strands; kwargs...)
    bnds = (zero(len), len)

    p = Polygon{typeof(len)}[]
    g =
        (t, sgn1, idx, sgn2) -> begin
            d = Paths.direction(f, t) + sgn1 * 90.0°       # turn left (+) or right (-) of path
            offset = Paths.offset(s, t) + Paths.width(s, t) / 2
            strand_offset = idx * (Paths.spacing(s, t) + Paths.width(s, t))
            return f(t) +
                   (sgn2 * Paths.width(s, t) / 2 + offset + strand_offset) *
                   Point(cos(d), sin(d))
        end
    for i = 0:(Paths.num(s) - 1)
        ppgrid = adapted_grid(t -> Paths.direction(r -> g(r, 1, i, 1), t), bnds; kwargs...)
        pmgrid = adapted_grid(t -> Paths.direction(r -> g(r, 1, i, -1), t), bnds; kwargs...)
        mmgrid =
            adapted_grid(t -> Paths.direction(r -> g(r, -1, i, -1), t), bnds; kwargs...)
        mpgrid = adapted_grid(t -> Paths.direction(r -> g(r, -1, i, 1), t), bnds; kwargs...)

        ppts = [g.(pmgrid, 1, i, -1); @view (g.(ppgrid, 1, i, 1))[end:-1:1]]
        mpts = [g.(mpgrid, -1, i, 1); @view (g.(mmgrid, -1, i, -1))[end:-1:1]]

        push!(p, Polygon(uniquepoints(ppts)))
        push!(p, Polygon(uniquepoints(mpts)))
    end
    return p
end

function to_polygons(
    f::Paths.BSpline{T},
    s::Paths.Strands;
    atol=DeviceLayout.onenanometer(T),
    rtol=nothing,
    kwargs...
) where {T}
    arclength(t) = Paths.t_to_arclength(f, t)
    κ(t) = _bspline_curvature(f.r, t)
    g =
        (t, sgn1, idx, sgn2) -> begin
            tng = Paths.Interpolations.gradient(f.r, t)[1]
            perp = sgn1 * Point(-tng.y, tng.x)
            tt = arclength(t)
            offset = Paths.offset(s, tt) + Paths.width(s, tt) / 2
            strand_offset = idx * (Paths.spacing(s, tt) + Paths.width(s, tt))
            return f.r(t) +
                   perp * (
                (sgn2 * Paths.width(s, tt) / 2 + offset + strand_offset) / norm(perp)
            )
        end

    p = Polygon{T}[]
    for i = 0:(Paths.num(s) - 1)
        ppts = [
            discretize_curve(r -> g(r, 1, i, -1), κ, atol; rtol, t_scale=pathlength(f))
            @view discretize_curve(
                r -> g(r, 1, i, 1),
                κ,
                atol;
                rtol,
                t_scale=pathlength(f)
            )[end:-1:1]
        ]
        mpts = [
            discretize_curve(r -> g(r, -1, i, 1), κ, atol; rtol, t_scale=pathlength(f))
            @view discretize_curve(
                r -> g(r, -1, i, -1),
                κ,
                atol;
                rtol,
                t_scale=pathlength(f)
            )[end:-1:1]
        ]

        push!(p, Polygon(uniquepoints(ppts)))
        push!(p, Polygon(uniquepoints(mpts)))
    end
    return p
end

function to_polygons(
    seg::Paths.Turn{T},
    s::Paths.Strands;
    atol=DeviceLayout.onenanometer(T),
    rtol=nothing,
    kwargs...
) where {T}
    grid = discretization_grid(seg, atol; rtol=rtol) * pathlength(seg)
    g =
        (t, sgn1, idx, sgn2) -> begin
            d = Paths.direction(seg, t) + sgn1 * 90.0°
            offset = Paths.offset(s, t) + Paths.width(s, t) / 2
            strand_offset = idx * (Paths.spacing(s, t) + Paths.width(s, t))
            return seg(t) +
                   (sgn2 * Paths.width(s, t) / 2 + offset + strand_offset) *
                   Point(cos(d), sin(d))
        end

    p = Polygon{T}[]
    for i = 0:(Paths.num(s) - 1)
        ppts = [g.(grid, 1, i, -1); @view (g.(grid, 1, i, 1))[end:-1:1]]
        mpts = [g.(grid, -1, i, 1); @view (g.(grid, -1, i, -1))[end:-1:1]]

        push!(p, Polygon(uniquepoints(ppts)))
        push!(p, Polygon(uniquepoints(mpts)))
    end
    return p
end

function to_polygons(
    seg::Paths.OffsetSegment{T},
    s::Paths.Strands;
    atol=DeviceLayout.onenanometer(T),
    rtol=nothing,
    kwargs...
) where {T}
    return _to_polygons_via_bspline(seg, s; atol, rtol, kwargs...)
end

function to_polygons(
    segment::Paths.Straight{T},
    s::Paths.SimpleStrands;
    kwargs...
) where {T}
    dir = direction(segment, zero(T))
    dp = dir + 90.0°

    tangents = [
        Point(cos(dp), sin(dp)),
        Point(cos(dp), sin(dp)),
        Point(cos(dp), sin(dp)),
        Point(cos(dp), sin(dp))
    ]

    p = Polygon{T}[]
    for i = 0:(Paths.num(s) - 1)
        i_offset = i * (Paths.width(s) + Paths.spacing(s))
        o = Paths.offset(s) + i_offset
        ow = o + Paths.width(s)

        ext = Paths.extent(s, zero(T))

        extents_p = [o, o, ow, ow]
        extents_m = [ow, ow, o, o]

        a, b = segment(zero(T)), segment(pathlength(segment))
        origins = [a, b, b, a]

        push!(p, Polygon(origins .+ extents_p .* tangents))
        push!(p, Polygon(origins .- extents_m .* tangents))
    end
    return p
end
