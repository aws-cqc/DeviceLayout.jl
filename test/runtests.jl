using TestItemRunner

@testsnippet CommonTestSetup begin
    using Test
    using Preferences
    using DeviceLayout, LinearAlgebra, Unitful, FileIO, Logging
    import Unitful: s, °, DimensionError
    import Clipper
    import ForwardDiff

    const pm2μm = DeviceLayout.PreferMicrons.pm
    const nm2μm = DeviceLayout.PreferMicrons.nm
    const μm2μm = DeviceLayout.PreferMicrons.μm
    const mm2μm = DeviceLayout.PreferMicrons.mm
    const cm2μm = DeviceLayout.PreferMicrons.cm
    const m2μm = DeviceLayout.PreferMicrons.m

    const nm2nm = DeviceLayout.PreferNanometers.nm
    const μm2nm = DeviceLayout.PreferNanometers.μm
    const cm2nm = DeviceLayout.PreferNanometers.cm
    const m2nm = DeviceLayout.PreferNanometers.m

    import Unitful: pm, nm, μm, mm, cm, m

    p(x, y) = Point(x, y)

    """
        is_sliver(p::Polygon{T}; atol=DeviceLayout.onenanometer(T))

    Return `true` if `2 * area(p) / perimeter(p) < atol`, and `false` otherwise.

    In other words, if `p` has an "average width" less than `atol`, it is counted as a sliver.
    """
    function is_sliver(p::Polygon{T}; atol=DeviceLayout.onenanometer(T)) where {T}
        return 2 * Polygons.area(p) / Polygons.perimeter(p) < atol
    end

    const tdir = mktempdir()

    # G1 continuity check: verify no angle jump exceeds the discretization step
    function check_g1_continuity(poly_pts, dθ_max)
        n = length(poly_pts)
        for i in eachindex(poly_pts)
            e1 = poly_pts[i] - poly_pts[mod1(i - 1, n)]
            e2 = poly_pts[mod1(i + 1, n)] - poly_pts[i]
            if norm(e1) > 0.01nm && norm(e2) > 0.01nm
                cos_a =
                    clamp((e1.x * e2.x + e1.y * e2.y) / (norm(e1) * norm(e2)), -1.0, 1.0)
                @test acos(cos_a) < 1.1 * dθ_max
            end
        end
    end

    using DeviceLayout.Curvilinear: edge_type_at_vertex, rounded_corner_segment_line_arc

    """
        check_line_arc_fillets(cp, pts, fillet_r; atol_length=1.0nm, atol_angle=1e-6)

    Assert that `rounded_corner_segment_line_arc` produces a geometrically valid fillet at
    every line-arc corner of CurvilinearPolygon `cp` (vertex list `pts`, requested radius
    `fillet_r`). These are self-sufficient property checks against analytic ground truth —
    the arc's center/radius and tangency — rather than a comparison to another
    implementation.

    `atol_length` is the positional tolerance (matches `Polygons._round_atol` for `Length`
    coordinates); `atol_angle` is the tangent-direction tolerance in radians.
    """
    function check_line_arc_fillets(cp, pts, fillet_r; atol_length=1.0nm, atol_angle=1e-6)
        n_pts = length(pts)
        n_filleted = 0
        for i = 1:n_pts
            edge = edge_type_at_vertex(cp, i)
            is_line_arc = (edge.incoming == :straight) != (edge.outgoing == :straight)
            !is_line_arc && continue

            arc_is_outgoing = edge.outgoing != :straight
            arc_curve = arc_is_outgoing ? edge.outgoing : edge.incoming
            p_corner = pts[i]
            p_line = arc_is_outgoing ? pts[mod1(i - 1, n_pts)] : pts[mod1(i + 1, n_pts)]

            seg = rounded_corner_segment_line_arc(
                p_line,
                p_corner,
                arc_curve,
                arc_is_outgoing,
                fillet_r
            )

            # The solver returns `nothing` for corners it declines (edge too short, already
            # tangent, degenerate geometry). With no reference impl we can't predict which,
            # so assert geometry only where a fillet exists; the counter (checked > 0 below)
            # guards against the loop silently testing nothing.
            isnothing(seg) && continue
            n_filleted += 1

            @test seg.fillet isa Paths.Turn

            O = Paths.curvaturecenter(arc_curve)   # center of the original arc
            arc_r = abs(arc_curve.r)

            # (1) T_arc lies on the original arc (not implied by (6): those distances don't force collinearity).
            @test isapprox(norm(seg.T_arc - O), arc_r, atol=atol_length)

            # (2) T_line lies on the straight edge from p_line to p_corner: T_line's perpendicular
            #     distance to the line through p_line and p_corner is ~0. Built from the unit
            #     edge vector to keep units consistent (avoids a cross-product's length^2 type).
            v_line = (p_corner - p_line) / norm(p_corner - p_line)
            w = seg.T_line - p_line
            perp = w - (w.x * v_line.x + w.y * v_line.y) * v_line
            @test isapprox(norm(perp), zero(atol_length), atol=atol_length)

            # (3) Fillet Turn endpoints equal the tangent points (orientation-dependent):
            #     outgoing arc → polygon runs line→fillet→arc, so p0=T_line, p1=T_arc.
            p0_f = Paths.p0(seg.fillet)
            p1_f = Paths.p1(seg.fillet)
            if arc_is_outgoing # line → fillet → arc
                @test isapprox(p0_f, seg.T_line, atol=atol_length)
                @test isapprox(p1_f, seg.T_arc, atol=atol_length)
            else # arc → fillet → line
                @test isapprox(p0_f, seg.T_arc, atol=atol_length)
                @test isapprox(p1_f, seg.T_line, atol=atol_length)
            end

            # (4) G1 tangency: the fillet meets the line and the arc tangentially (no corner).
            #     Tangent of a Turn is a unit-bearing degree angle → compare with isapprox_angle;
            #     a tangent is a line (mod π), so accept a match to either the angle or angle + π.
            p0_α = Paths.α0(seg.fillet)
            p1_α = Paths.α1(seg.fillet)
            T_line_α = atan(v_line.y, v_line.x)
            T_arc_α =
                Paths.direction(arc_curve, Paths.pathlength_nearest(arc_curve, seg.T_arc))
            if arc_is_outgoing # line → fillet → arc
                @test isapprox_angle(p0_α, T_line_α, atol=atol_angle) ||
                      isapprox_angle(p0_α, T_line_α + π, atol=atol_angle)
                @test isapprox_angle(p1_α, T_arc_α, atol=atol_angle) ||
                      isapprox_angle(p1_α, T_arc_α + π, atol=atol_angle)
            else # arc → fillet → line
                @test isapprox_angle(p0_α, T_arc_α, atol=atol_angle) ||
                      isapprox_angle(p0_α, T_arc_α + π, atol=atol_angle)
                @test isapprox_angle(p1_α, T_line_α, atol=atol_angle) ||
                      isapprox_angle(p1_α, T_line_α + π, atol=atol_angle)
            end

            # (5) Fillet radius equals the requested radius.
            @test seg.fillet.r ≈ fillet_r

            # (6) Fillet center is fillet_r from both tangent points, and arc_r ± fillet_r from
            #     the arc center (external vs internal tangency — the solver produces one).
            C_f = Paths.curvaturecenter(seg.fillet)
            @test isapprox(norm(C_f - seg.T_line), fillet_r, atol=atol_length)
            @test isapprox(norm(C_f - seg.T_arc), fillet_r, atol=atol_length)
            d_centers = norm(C_f - O)
            @test isapprox(d_centers, arc_r + fillet_r, atol=atol_length) ||
                  isapprox(d_centers, abs(arc_r - fillet_r), atol=atol_length)

            # (7) Sweep sanity: sampled points along the fillet all lie on its own circle.
            L_f = Paths.pathlength(seg.fillet)
            n_samples = 9
            for t in range(zero(L_f), L_f, length=n_samples)
                @test isapprox(norm(seg.fillet(t) - C_f), fillet_r, atol=atol_length)
            end
        end
        @test n_filleted > 0
    end
end

@run_package_tests filter =
    ti -> (isempty(ARGS) || any(arg -> occursin(arg, ti.name), ARGS))
