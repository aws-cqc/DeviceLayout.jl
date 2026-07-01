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

    # Direct 2-arg call for the generic Segment/PeriodicStyle method.
    seg = Paths.Straight{typeof(1.0μm)}(50μm, Point(0.0μm, 0.0μm), 0.0)
    periodic_polys = to_polygons(seg, psty)
    @test !isempty(periodic_polys)
    @test all(p -> p isa Polygon, periodic_polys)
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
    turn!(pa, 90°, 20μm)
    bspline!(pa, [Point(1, 1)mm], 90°)
    simplify!(pa)
    Paths.setstyle!(pa[1], psty)
    c = Cell("test")
    render!(c, pa, GDSMeta()) # runs without error

    cs = CoordinateSystem("test")
    place!(cs, pa)
    sm = SolidModel("test", overwrite=true)
    render!(sm, cs) # runs without error

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
    attach!(pa, sref(cs), 5μm, location=1)
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
    # Reverse
    rev_path = Path(reverse(reverse.(pa2.nodes)); metadata=GDSMeta(1))
    @test isempty(to_polygons(xor2d(pa2 => GDSMeta(), rev_path => GDSMeta())))
    @test isempty(to_polygons(xor2d(pa2 => GDSMeta(1), rev_path => GDSMeta(1))))

    cs = CoordinateSystem("test")
    place!(cs, pa2)
    sm = SolidModel("test", overwrite=true)
    render!(sm, cs) # runs without error

    # Overlays and decorations
    # Overlay inside periodic
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
    # Periodic inside overlay
    pa5 = Path()
    straight!(pa5, 10μm, Trace(2.0μm))
    psty_inner = PeriodicStyle(pa5)
    overlay!(pa5, psty_inner, GDSMeta())
    straight!(pa5, 5μm)
    @test pa5[end].sty.overlay[1].l0 == 10μm
end

@testitem "Rounded trace tapers" setup = [CommonTestSetup] begin
    # Basic usage: single-side taper, quintic S-curve
    pa = Path()
    straight!(pa, 10μm, Paths.Trace(1μm))
    turn!(pa, 90°, 10μm / (pi / 2), Paths.Trace(5μm))
    straight!(pa, 10μm, Paths.Trace(3μm))
    Paths.round_trace_transitions!(pa)

    @test length(pa) == 5 # 3 original + 1 extra node per transition
    @test pathlength(pa) ≈ 30μm
    @test pathlength(pa[1]) < 10μm # split before transition
    @test pathlength(pa[end]) == 10μm
    # Quintic S-curve: lags linear at 25%, matches at 50%, leads at 75%
    L2 = pathlength(pa[2].seg)
    @test Paths.width(pa[2].sty, 0.0μm) ≈ 1μm
    @test Paths.width(pa[2].sty, 0.25 * L2) < 3μm
    @test Paths.width(pa[2].sty, 0.5 * L2) ≈ 3μm
    @test Paths.width(pa[2].sty, 0.75 * L2) > 3μm
    @test Paths.width(pa[2].sty, L2) ≈ 5μm atol = 2nm
    # Width continuity at boundary
    @test Paths.width(pa[2].sty, L2) ≈ Paths.width(pa[3].sty, 0μm) atol = 2nm

    cs = CoordinateSystem("test")
    place!(cs, pa)
    sm = SolidModel("test", overwrite=true)
    render!(sm, cs) # runs without error

    # Add tapers after
    pa = Path()
    straight!(pa, 10μm, Paths.Trace(1μm))
    turn!(pa, 90°, 10μm / (pi / 2), Paths.Trace(5μm))
    straight!(pa, 10μm, Paths.Trace(3μm))
    Paths.round_trace_transitions!(pa, side=:after)
    @test length(pa) == 5 # 3 original + 1 extra node per transition
    @test pathlength(pa) ≈ 30μm
    @test pathlength(pa[1]) == 10μm
    @test pathlength(pa[end]) < 10μm

    # Invalid α_max
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
    Paths.round_trace_transitions!(pa; radius=3μm)
    @test length(pa) == 5
    @test pathlength(pa) ≈ 30μm

    # Segment too short for taper
    pa = Path()
    straight!(pa, 10μm, Paths.Trace(1μm))
    straight!(pa, 10μm, Paths.Trace(27μm))
    @test_logs (:warn, r"taper length") Paths.round_trace_transitions!(pa; radius=10μm)

    # Rounding of TaperTrace
    pa = Path()
    straight!(pa, 10μm, Paths.Trace(1μm))
    turn!(pa, 90°, 10μm / (pi / 2), Paths.TaperTrace(1μm, 3μm))
    straight!(pa, 10μm)
    @test pa[end].sty == Paths.Trace(3μm)
    straight!(pa, 1μm, Paths.Taper())
    straight!(pa, 9μm, Paths.Trace(30μm))

    w025 = Paths.width(pa[2].sty, 0.25 * pathlength(pa[2].seg))
    w05 = Paths.width(pa[2].sty, 0.5 * pathlength(pa[2].seg))
    w075 = Paths.width(pa[2].sty, 0.75 * pathlength(pa[2].seg))
    Paths.round_trace_transitions!(pa)
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
    @test_throws "Cannot terminate" terminate!(pa; rounding=2μm, gap=0μm)
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

    # Terminated path continues as NoRender
    straight!(pa, 10μm)
    @test pa[end].sty isa Paths.NoRenderContinuous

    # Terminate periodic
    pa3 = Path(0nm, 0nm)
    tapersty = Paths.TaperCPW(10μm, 6μm, 2μm, 1μm)
    @test Paths.nextstyle(tapersty) == Paths.CPW(2.0μm, 1.0μm)
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

    # Terminate with custom open gap
    pa6 = Path()
    straight!(pa6, 10μm, Paths.CPW(10μm, 6μm))
    terminate!(pa6; gap=10μm) # Normally would be 6um open gap
    @test bounds(pa6) == Rectangle(Point(0μm, -11μm), Point(20μm, 11μm))

    # Terminate with margin
    pa7 = Path()
    straight!(pa7, 10μm, Paths.CPW(10μm, 6μm))
    terminate!(pa7; gap=10μm, margin=2μm) # Normally would be 6um open gap
    @test bounds(pa7) == Rectangle(Point(0μm, -11μm), Point(18μm, 11μm))
    terminate!(pa7; initial=true, gap=0μm, margin=2μm)
    @test bounds(pa7) == Rectangle(Point(2μm, -11μm), Point(18μm, 11μm))
    ## Doesn't change endpoints relative to what they would have been with no margin
    @test p0(pa7) == Point(0, 0)μm
    @test p1(pa7) == Point(20, 0)μm
    ## Same thing with Trace (overlay on same path)
    overlay!(pa7, Paths.Trace(22μm), GDSMeta(1), i=1)
    overlay!(pa7, Paths.Trace(22μm), GDSMeta(1), i=2)
    overlay!(pa7, Paths.Trace(22μm), GDSMeta(1), i=3)
    terminate!(pa7; margin=1μm, overlay_index=1)
    @test bounds(pa7) == Rectangle(Point(0μm, -11μm), Point(19μm, 11μm))
    terminate!(pa7; initial=true, gap=0μm, margin=1μm, overlay_index=1)
    @test bounds(pa7) == Rectangle(Point(1μm, -11μm), Point(19μm, 11μm))
end
