@testset "Periodic Path styles" setup = [CommonTestSetup] begin
    import .Paths: PeriodicStyle, Trace, CPW

    pa = Path(0nm, 0nm)
    sty1 = Paths.CPW(10μm, 6μm)
    sty2 = Paths.Trace(2μm)

    psty = PeriodicStyle([sty1, sty2], [20μm, 10μm], 5μm)
    with_period = PeriodicStyle([sty1, sty2], 30μm; weights=[2, 1], l0=5μm)
    @test with_period.lengths == psty.lengths
    @test psty(0μm) === (sty1, 5.0μm)
    @test psty(18μm) === (sty2, 3.0μm)
    @test psty(37μm) === (sty1, 12.0μm)
    @test psty(46μm) === (sty2, 1.0μm)
    @test Paths.extent(psty, 0μm) == 11μm
    @test Paths.width(psty, 18μm) == 2μm
    
    # Various combinations work
    # Nested
    psty_nested = PeriodicStyle([sty1, psty, sty2], 50μm; weights=[1, 3, 1])
    @test psty_nested(15μm) === (psty, 5.0μm)
    @test Paths.gap(psty_nested, 65μm) == 6.0μm
    @test Paths.trace(psty_nested, 75μm) == 2.0μm

    # General, Taper, NoRender, Termination
    pa = Path(0nm, 0nm)
    straight!(pa, 4μm, Paths.CPW(x -> 10μm, x -> 6μm))
    turn!(pa, 90°, 10μm/(pi/4), Paths.TaperCPW(10μm, 6μm, 2μm, 1μm))
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
    @test psty_complex.lengths ≈ [9μm, 1μm, 19.5μm, 0.5μm, 10μm, 10μm, 10μm, 10μm]
    pa2 = Path(0nm, 0nm)
    straight!(pa2, 9*70μm + 64μm, psty_complex) # Stop just before attachment in last segment
    straight!(pa2, 2μm)
    c = Cell("test")
    render!(c, pa2, GDSMeta(1)) # Runs without error
    @test length(c.refs) == 10 # Attachment appears in second segment
    @test length(c.elements) == 101 # 10 * (1 + 2 + 2 + 2 + 0 + 1 + 1 + 1) + 1
    # Note: Attachment will be duplicated if it's at the exact end and start of a segment!
    @test split(pa2[1], 100μm)[2].sty.l0 == 100μm
end

