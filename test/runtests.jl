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
        check_line_arc_fillets(
            cp,
            pts,
            fillet_r;
            atol_length=1.0nm,
            atol_angle=1e-6
        )

    Assert that `rounded_corner_segment_line_arc` produces valid fillets at line-arc
    corners. Every detected line-arc corner must fillet.
    """
    function check_line_arc_fillets(
        cp,
        pts,
        fillet_r;
        atol_length=1.0nm,
        atol_angle=1e-6
    )
        n_pts = length(pts)
        n_line_arc = 0
        n_filleted = 0
        for i = 1:n_pts
            edge = edge_type_at_vertex(cp, i)
            is_line_arc = (edge.incoming == :straight) != (edge.outgoing == :straight)
            !is_line_arc && continue
            n_line_arc += 1

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

            isnothing(seg) && continue
            n_filleted += 1

            @test seg.fillet isa Paths.Turn

            O = Paths.curvaturecenter(arc_curve)   # center of the original arc
            arc_r = abs(arc_curve.r)

            @test isapprox(norm(seg.T_arc - O), arc_r, atol=atol_length)

            v_line = (p_corner - p_line) / norm(p_corner - p_line)
            w = seg.T_line - p_line
            perp = w - (w.x * v_line.x + w.y * v_line.y) * v_line
            @test isapprox(norm(perp), zero(atol_length), atol=atol_length)

            p0_f = Paths.p0(seg.fillet)
            p1_f = Paths.p1(seg.fillet)
            if arc_is_outgoing # line → fillet → arc
                @test isapprox(p0_f, seg.T_line, atol=atol_length)
                @test isapprox(p1_f, seg.T_arc, atol=atol_length)
            else # arc → fillet → line
                @test isapprox(p0_f, seg.T_arc, atol=atol_length)
                @test isapprox(p1_f, seg.T_line, atol=atol_length)
            end

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

            @test seg.fillet.r ≈ fillet_r

            C_f = Paths.curvaturecenter(seg.fillet)
            @test isapprox(norm(C_f - seg.T_line), fillet_r, atol=atol_length)
            @test isapprox(norm(C_f - seg.T_arc), fillet_r, atol=atol_length)
            d_centers = norm(C_f - O)
            @test isapprox(d_centers, arc_r + fillet_r, atol=atol_length) ||
                  isapprox(d_centers, abs(arc_r - fillet_r), atol=atol_length)

            L_f = Paths.pathlength(seg.fillet)
            n_samples = 9
            for t in range(zero(L_f), L_f, length=n_samples)
                @test isapprox(norm(seg.fillet(t) - C_f), fillet_r, atol=atol_length)
            end
        end

        @test n_filleted == n_line_arc
    end
end

@run_package_tests filter =
    ti -> (isempty(ARGS) || any(arg -> occursin(arg, ti.name), ARGS))
