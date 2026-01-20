@testitem "Periodic Path styles" setup = [CommonTestSetup] begin
    import .Paths: PeriodicStyle, Trace, CPW

    sty1 = Paths.CPW(10μm, 6μm)
    sty2 = Paths.Trace(2μm)

    psty = PeriodicStyle([sty1, sty2], [20μm, 10μm], 5μm)
    with_period = PeriodicStyle([sty1, sty2]; period=30μm, weights=[2, 1], l0=5μm)
    @test with_period.lengths == psty.lengths
    @test psty(0μm) === (sty1, 5.0μm)
    @test psty(18μm) === (sty2, 3.0μm)
    @test psty(37μm) === (sty1, 12.0μm)
    @test psty(46μm) === (sty2, 1.0μm)
    @test Paths.extent(psty, 0μm) == 11μm
    @test Paths.width(psty, 18μm) == 2μm

    # Unit tests
    @test copy(psty).styles !== psty.styles
    @test contains(Paths.summary(psty), "2 substyles")
    pa = Path()
    straight!(pa, 10μm, psty)
    straight!(pa, 1μm, Paths.SimpleNoRender(10μm, virtual=true))
    @test Paths.nextstyle(pa).l0 == 5μm # Same style, same initial offset periodicity (not continued from end)
    straight!(pa, 15μm) # Exact length to end of substyle
    segs, stys = Paths.resolve_periodic(pa[end].seg, pa[end].sty)
    @test length(segs) == 1

    # Various combinations work
    # Nested
    psty_nested = PeriodicStyle([sty1, psty, sty2]; period=50μm, weights=[1, 3, 1])
    @test psty_nested(15μm) === (psty, 5.0μm)
    @test Paths.gap(psty_nested, 65μm) == 6.0μm
    @test Paths.trace(psty_nested, 75μm) == 2.0μm

    # Over compound segment
    pa = Path(0nm, 0nm)
    straight!(pa, 10μm, Paths.Trace(10μm))
    turn!(pa, 90°, 10μm)
    bspline!(pa, [Point(1, 1)mm], 90°)
    simplify!(pa)
    Paths.setstyle!(pa[1], psty)
    c = Cell("test")
    render!(c, pa, GDSMeta())

    # Compound style
    pa = Path(0nm, 0nm)
    straight!(pa, 1μm, Paths.Trace(1μm))
    straight!(pa, 2μm, Paths.Trace(2μm))
    simplify!(pa)
    straight!(pa, 3μm, Paths.Trace(3μm))
    psty_compound = PeriodicStyle(pa)
    @test psty_compound.lengths ≈ [1.0μm, 2.0μm, 3.0μm]
    @test Paths.trace.(psty_compound.styles) == [1μm, 2μm, 3μm]

    # General, Taper, NoRender, Termination
    pa = Path(0nm, 0nm)
    straight!(pa, 4μm, Paths.CPW(x -> 10μm, x -> 6μm))
    turn!(pa, 90°, 10μm / (pi / 2), Paths.TaperCPW(10μm, 6μm, 2μm, 1μm))
    terminate!(pa; initial=true, rounding=3μm)
    terminate!(pa; rounding=0.5μm, gap=0μm)
    straight!(pa, 10μm, Paths.NoRender())
    straight!(pa, 10μm, Paths.Trace(1μm))
    straight!(pa, 10μm, Paths.Taper())
    straight!(pa, 10μm, Paths.Trace(2μm))
    cs = CoordinateSystem("test", nm)
    place!(cs, Rectangle(10μm, 10μm), GDSMeta())
    attach!(pa, sref(cs), 5μm)
    psty_complex = PeriodicStyle(pa)
    # Note: PeriodicStyle doesn't work with generic taper; same as CompoundStyle issue #13
    # But constructor based on a path handles generic tapers

    # Termination, CPW straight, turn, termination; NoRender, Trace, Taper, Trace
    @test psty_complex.lengths ≈ [9μm, 1μm, 9.5μm, 0.5μm, 10μm, 10μm, 10μm, 10μm]
    pa2 = Path(0nm, 0nm)
    straight!(pa2, 9 * 60μm + 54μm, psty_complex) # Stop just before attachment in last segment
    straight!(pa2, 2μm)
    c = Cell("test")
    render!(c, pa2, GDSMeta(1)) # Runs without error
    @test length(c.refs) == 10 # Attachment appears in second segment
    # Note: Attachment will be duplicated if it's at the exact end and start of a segment!
    @test length(c.elements) == 101 # 10 * (1 + 2 + 2 + 2 + 0 + 1 + 1 + 1) + 1
    @test split(pa2[1], 100μm)[2].sty.l0 == 100μm

    # Overlays and decorations
    pa3 = Path{Float64}()
    straight!(pa3, 10, Trace(2.0))
    overlay!(pa3, CPW(10.0, 10.0), GDSMeta(1))
    cs = CoordinateSystem{Float64}("test")
    place!(cs, Rectangle(10, 10), GDSMeta())
    attach!(pa3, sref(cs), 5)
    overlay_psty = PeriodicStyle(pa3, l0=4)
    @test Paths._isuniform(overlay_psty)
    pa4 = Path{Float64}()
    turn!(pa4, 90°, 102 / (pi / 2), overlay_psty)
    ts, _, _ = Paths._expand_periodic_decorations(pa4[1].seg, pa4[1].sty)
    @test ts == 1.0:10:101
    segs, stys = Paths.resolve_periodic(pa4[1].seg, pa4[1].sty)
    @test length(segs) == 1
    straight!(pa4, 10.0)
    ts, _, _ = Paths._expand_periodic_decorations(pa4[2].seg, pa4[2].sty)
    @test ts ≈ [9.0]
    cf = Cell{Float64}("test")
    render!(cf, pa4, GDSMeta(2))
    @test length(elements(cf)) == 2 # Not broken into segments
    @test length(cf.refs) == 14 # 2 overlays + 12 attachments
end

@testitem "Rounded trace tapers" setup = [CommonTestSetup] begin
    # Basic usage
    pa = Path()
    straight!(pa, 10μm, Paths.Trace(1μm))
    turn!(pa, 90°, 10μm / (pi / 2), Paths.Trace(5μm))
    straight!(pa, 10μm, Paths.Trace(3μm))
    Paths.round_trace_transitions!(pa)

    @test length(pa) == 7
    @test pathlength(pa) ≈ 30μm
    @test Paths.width(pa[2].sty, 0.5 * pathlength(pa[2])) < 3μm
    @test Paths.width(pa[2].sty, pathlength(pa[2])) ≈ 3μm atol = 2nm
    @test Paths.width(pa[3].sty, 0μm) ≈ 3μm atol = 2nm
    @test Paths.width(pa[2].sty, pathlength(pa[2])) ≈ Paths.width(pa[3].sty, 0μm) # floating point tolerance
    @test Paths.width(pa[3].sty, 0.5 * pathlength(pa[3])) > 3μm
    @test Paths.width(pa[5].sty, 0.6 * pathlength(pa[5])) > 4μm
    @test Paths.width(pa[6].sty, 0.6 * pathlength(pa[6])) < 4μm

    cs = CoordinateSystem("test")
    sm = SolidModel("test", overwrite=true)
    render!(sm, cs) # runs without error

    # Sharp corners
    pa = Path()
    straight!(pa, 10μm, Paths.Trace(1μm))
    turn!(pa, 90°, 10μm / (pi / 2), Paths.Trace(5μm))
    straight!(pa, 10μm, Paths.Trace(3μm))
    @test_throws "taper angle" Paths.round_trace_transitions!(pa; α_max=90°)

    # Explicit rounding radius
    pa = Path()
    straight!(pa, 10μm, Paths.Trace(1μm))
    turn!(pa, 90°, 10μm / (pi / 2), Paths.Trace(5μm))
    straight!(pa, 10μm, Paths.Trace(3μm))
    straight!(pa, 10μm, Paths.Trace(27μm)) # too sharp
    @test_warn "discontinuous" Paths.round_trace_transitions!(pa, radius=3μm)
    @test length(pa) == 10 # All transitions rounded, adding 2 nodes each
    @test pathlength(pa) ≈ 40μm
    # Points are shared even with 90 degree taper
    @test count(
        p -> p in points(to_polygons(pa[end - 2])),
        points(to_polygons(pa[end - 1]))
    ) == 2

    # Rounding of TaperTrace
    pa = Path()
    straight!(pa, 10μm, Paths.Trace(1μm))
    turn!(pa, 90°, 10μm / (pi / 2), Paths.TaperTrace(1μm, 3μm))
    straight!(pa, 10μm, Paths.Trace(3μm))
    straight!(pa, 1μm, Paths.Taper())
    straight!(pa, 9μm, Paths.Trace(30μm))

    w025 = Paths.width(pa[2].sty, 0.25 * pathlength(pa[2].seg))
    w05 = Paths.width(pa[2].sty, 0.5 * pathlength(pa[2].seg))
    w075 = Paths.width(pa[2].sty, 0.75 * pathlength(pa[2].seg))
    @test_warn "discontinuous" Paths.round_trace_transitions!(pa)
    @test length(pa) == 5
    @test pathlength(pa) ≈ 40μm
    @test Paths.width(pa[2].sty, 0.25 * pathlength(pa[2].seg)) < w025
    @test Paths.width(pa[2].sty, 0.5 * pathlength(pa[2].seg)) ≈ w05 atol = 1nm
    @test Paths.width(pa[2].sty, 0.75 * pathlength(pa[2].seg)) > w075
end

@testitem "Path terminations" setup = [CommonTestSetup] begin
    pa = Path(0nm, 0nm)
    straight!(pa, 10μm, Paths.CPW(10μm, 6μm))
    terminate!(pa; initial=true, rounding=2μm)
    terminate!(pa; rounding=2μm, gap=0μm)
    # Unit test splitting
    @test Paths.split(pa[1].sty, pathlength(pa[1]) / 2)[1] isa Paths.SimpleNoRender
    @test Paths.split(pa[1].sty, pathlength(pa[1]) / 2)[2] == pa[1].sty
    @test Paths.split(pa[3].sty, pathlength(pa[3]) / 2)[1] == pa[3].sty
    @test Paths.split(pa[3].sty, pathlength(pa[3]) / 2)[2] isa Paths.SimpleNoRender
    # If segment with PeriodicStyle begins or ends in a termination, draw the whole termination
    pa2 = Path(0nm, 0nm)
    straight!(pa2, pathlength(pa) - 2μm, Paths.PeriodicStyle(pa; l0=1μm))
    @test pathlength(pa2) ≈ pathlength(pa) - 2μm
    # Entire termination polygons are still drawn on both sides
    polys = vcat(to_polygons.(pa2)...)
    @test length(polys) == 5
    @test width(bounds(polys)) == pathlength(pa)
    @test lowerleft(bounds(polys)).x ≈ -1μm
    straight!(pa2, 2μm) # End of one termination and beginning of another
    # No polygons added
    @test vcat(to_polygons.(pa2)...) == polys

    # Terminate periodic
    pa3 = Path(0nm, 0nm)
    tapersty = Paths.TaperCPW(10μm, 6μm, 2μm, 1μm)
    straight!(pa3, 15μm, Paths.PeriodicStyle([tapersty], [10μm]))
    sty, l = Paths.terminal_style(pa3, true)
    @test Paths.trace(sty, l) ≈ 10μm
    @test Paths.gap(sty, l) ≈ 6μm
    sty, l = Paths.terminal_style(pa3, false)
    @test Paths.trace(sty, l) ≈ 6μm
    @test Paths.gap(sty, l) ≈ 3.5μm

    terminate!(pa3; initial=true, rounding=2μm)
    terminate!(pa3; rounding=0.5μm, gap=0μm)
    c = Cell("test")
    render!(c, pa3, GDSMeta(3))
    @test length(c.elements) == 7

    # Terminate overlay
    pa4 = Path(0, 0)
    straight!(pa4, 10, Paths.CPW(10, 6))
    overlay!(pa4, Paths.Trace(1), GDSMeta(2))
    overlay!(pa4, Paths.CPW(20, 6), GDSMeta(3))
    terminate!(pa4; rounding=5, initial=true)
    terminate!(pa4; initial=true, rounding=2, gap=0, overlay_index=2)
    terminate!(pa4; rounding=2, overlay_index=2)
    terminate!(pa4; rounding=0.5, overlay_index=1)
    straight!(pa4, 10, Paths.CPW(10, 6))
    overlay!(pa4, Paths.Trace(5), GDSMeta(1))
    terminate!(pa4; rounding=2, gap=0)
    @test_throws "too large for previous segment" terminate!(
        pa4;
        rounding=2.01,
        overlay_index=1
    )
    terminate!(pa4; rounding=1.9, overlay_index=1)
    cf = Cell{Float64}("test")
    render!(cf, pa4, GDSMeta())
    @test length(flatten(cf).elements) == 35
    @test bounds(cf) == Rectangle{Float64}((-6.0, -16.0), (26.0, 16.0))

    pa5 = Path(0, 0)
    turn!(pa5, 90°, 32 * 3 / (pi / 2), Paths.PeriodicStyle(pa4))
    cf = Cell{Float64}("test")
    render!(cf, pa5, GDSMeta())
    @test length(flatten(cf).elements) == 78 # PeriodicStyle actually does some simplification
    terminate!(pa5, initial=true, overlay_index=1, rounding=0.5)
    @test pa5[1].sty.overlay[1] isa Paths.TraceTermination
end
