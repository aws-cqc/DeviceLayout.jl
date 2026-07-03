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

function to_polygons(f::Paths.Straight{T}, s::Paths.SimpleCPW; kwargs...) where {T}
    g = cpw_points(f, s)

    t = StaticArrays.@SVector [zero(T), pathlength(f)]
    ppts = [g.(t, 1, -1); @view g.(t, 1, 1)[end:-1:1]]
    mpts = [g.(t, -1, 1); @view g.(t, -1, -1)[end:-1:1]]

    return [Polygon(ppts), Polygon(mpts)]
end
