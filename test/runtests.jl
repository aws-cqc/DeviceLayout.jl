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
end

@run_package_tests
