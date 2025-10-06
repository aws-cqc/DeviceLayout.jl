using TestItemRunner

@testsnippet CommonTestSetup begin
    using Test
    using Preferences
    using DeviceLayout, Unitful, FileIO, Logging
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
end

@run_package_tests

include("test_channels.jl")
