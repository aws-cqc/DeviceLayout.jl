@testitem "StyledHook construction and accessors" setup = [CommonTestSetup] begin
    using DeviceLayout.Paths

    h = PointHook(1mm, 2mm, 45°)
    sty = Paths.CPW(10μm, 6μm)
    sh = StyledHook(h, sty)

    # accessors
    @test hook_style(sh) === sty
    @test hook_style(h) === nothing

    # property forwarding: p and in_direction from inner hook
    @test sh.p === h.p
    @test sh.in_direction === h.in_direction

    # explicit fields
    @test sh.h === h
    @test sh.style === sty

    # propertynames covers both wrapper and inner
    @test :h in propertynames(sh)
    @test :style in propertynames(sh)
    @test :p in propertynames(sh)
    @test :in_direction in propertynames(sh)

    # DeviceLayout.in_direction respects the wrapper
    @test in_direction(sh) === in_direction(h)

    # The documented three type parameters still construct a concrete hook
    H, S = typeof(h), typeof(sty)
    @test isconcretetype(StyledHook{coordinatetype(h), H, S})
    @test StyledHook{coordinatetype(h), H, S}(h, sty) isa
          StyledHook{coordinatetype(h), H, S}
    @test hook_metadata(StyledHook{coordinatetype(h), H, S}(h, sty)) ==
          DeviceLayout.UNDEF_META
end

@testitem "StyledHook transformation preserves style (translation only)" setup =
    [CommonTestSetup] begin
    using DeviceLayout.Paths

    sty = Paths.CPW(10μm, 6μm)
    sh = StyledHook(PointHook(1mm, 2mm, 0°), sty)

    f = Translation(Point(3mm, 0mm))
    sh_x = DeviceLayout.transform(sh, f)

    @test sh_x isa StyledHook
    # Style is untransformed (scalar, not positional)
    @test sh_x.style === sty
    # Inner hook's point shifted
    @test sh_x.h.p == Point(4mm, 2mm)
    # in_direction unchanged under translation
    @test sh_x.in_direction === sh.in_direction
end

@testitem "StyledHook transformation dispatch: 4-way unwrap" setup = [CommonTestSetup] begin
    using DeviceLayout.Paths

    sty = Paths.CPW(10μm, 6μm)
    h_bare = PointHook(0mm, 0mm, 0°)
    h_other_bare = PointHook(5mm, 0mm, 180°)
    sh = StyledHook(h_bare, sty)
    sh_other = StyledHook(h_other_bare, sty)

    # Expected baseline: transformation between bare PointHooks
    f_bare_bare = DeviceLayout.transformation(h_bare, h_other_bare)

    # styled↔styled, styled↔bare, bare↔styled should all unwrap to the same result
    @test DeviceLayout.transformation(sh, sh_other) == f_bare_bare
    @test DeviceLayout.transformation(sh, h_other_bare) == f_bare_bare
    @test DeviceLayout.transformation(h_bare, sh_other) == f_bare_bare
end

@testitem "StyledHook wraps HandedPointHook correctly" setup = [CommonTestSetup] begin
    using DeviceLayout.Paths

    sty = Paths.CPW(10μm, 6μm)
    hph = HandedPointHook(0mm, 0mm, 30°, false)
    sh = StyledHook(hph, sty)

    # Property forwarding: should expose both HandedPointHook fields (h, right_handed)
    # and the inner PointHook fields (p, in_direction) transitively.
    @test sh.style === sty
    @test sh.right_handed === false
    @test sh.in_direction == 30°
    @test sh.p == Point(0mm, 0mm)

    # hook_style still returns the carried style (nested HandedPointHook doesn't matter)
    @test hook_style(sh) === sty
end

@testitem "hook_style: bare hooks return nothing" setup = [CommonTestSetup] begin
    @test hook_style(PointHook(0mm, 0mm, 0°)) === nothing
    @test hook_style(HandedPointHook(0mm, 0mm, 0°)) === nothing
    @test hook_style(HandedPointHook(0mm, 0mm, 0°, false)) === nothing
end

@testitem "Path hook styles" setup = [CommonTestSetup] begin
    using DeviceLayout.Paths
    using DeviceLayout.SchematicDrivenLayout
    # Empty
    pa = Path()
    @test all(hook_style.(values(hooks(pa))) .== Ref(Paths.NoRenderContinuous()))
    # Basic
    sty = Paths.CPW(10μm, 6μm)
    straight!(pa, 10μm, sty)
    @test all(hook_style.(values(hooks(pa))) .== Ref(sty))
    # Decorated
    cs = CoordinateSystem("attachment")
    attach!(pa, sref(cs), 0μm)
    @test all(hook_style.(values(hooks(pa))) .== Ref(sty))
    # Terminated
    terminate!(pa)
    @test hook_style(p0_hook(pa)) == sty
    @test hook_style(p1_hook(pa)) == Paths.NoRenderContinuous()
    terminate!(pa; initial=true)
    @test all(hook_style.(values(hooks(pa))) .== Ref(Paths.NoRenderContinuous()))

    # Virtual segments are skipped
    pa = Path()
    straight!(pa, 20μm, Paths.SimpleNoRender(22μm; virtual=true))
    straight!(pa, 100μm, sty)
    straight!(pa, 20μm, Paths.SimpleNoRender(22μm; virtual=true))
    @test all(hook_style.(values(hooks(pa))) .== Ref(sty))
    pa = Path()
    straight!(pa, 20μm, Paths.SimpleNoRender(22μm; virtual=true))
    @test all(hook_style.(values(hooks(pa))) .== Ref(Paths.NoRenderContinuous()))

    # Varying styles give the cross section at each end
    hook_width(h) = Paths.width(hook_style(h), 0μm)
    pa = Path()
    straight!(pa, 100μm, Paths.Trace(x -> 10μm + x / 10))
    @test hook_width(p0_hook(pa)) ≈ 10μm
    @test hook_width(p1_hook(pa)) ≈ 20μm
    pa = Path()
    straight!(pa, 100μm, Paths.SimpleTrace(10μm))
    straight!(pa, 100μm, Paths.TaperTrace(10μm, 20μm))
    simplify!(pa)
    @test hook_width(p0_hook(pa)) ≈ 10μm
    @test hook_width(p1_hook(pa)) ≈ 20μm

    # Periodic styles: a substyle boundary at an end belongs to the substyle being drawn
    template = Path()
    straight!(template, 0.8mm, Paths.SimpleTrace(10μm))
    straight!(template, 0.8mm, Paths.SimpleTrace(20μm))
    for (len, w1) in ((1mm, 20μm), (0.8mm, 10μm), (1.6mm, 20μm), (0.1mm * 16, 20μm))
        pp = Path()
        straight!(pp, len, Paths.PeriodicStyle(template))
        @test hook_width(p0_hook(pp)) ≈ 10μm
        @test hook_width(p1_hook(pp)) ≈ w1
    end
    # Continued from a previous segment
    pa = Path()
    straight!(pa, 0.5mm, Paths.PeriodicStyle(template))
    straight!(pa, 0.3mm)
    @test hook_width(p1_hook(pa)) ≈ 10μm
    # Inside compound styles from `simplify!`, and under overlays
    for (len1, len2) in ((0.4mm, 0.4mm), (0.5mm, 0.3mm))
        ps = Path()
        straight!(ps, len1, Paths.PeriodicStyle(template))
        straight!(ps, len2)
        simplify!(ps)
        @test hook_width(p0_hook(ps)) ≈ 10μm
        @test hook_width(p1_hook(ps)) ≈ 10μm
    end
    pa = Path()
    straight!(pa, 0.8mm, Paths.PeriodicStyle(template))
    overlay!(pa, Paths.SimpleTrace(5μm), GDSMeta(2))
    @test Paths.width(hook_style(p1_hook(pa)).s, 0μm) ≈ 10μm
    # Virtual substyles of a compound style are skipped
    pa = Path()
    straight!(pa, 20μm, Paths.SimpleNoRender(22μm; virtual=true))
    straight!(pa, 100μm, Paths.Trace(10μm))
    straight!(pa, 20μm, Paths.SimpleNoRender(22μm; virtual=true))
    simplify!(pa)
    @test all(hook_style.(values(hooks(pa))) .== Ref(Paths.Trace(10μm)))

    # Tapers give their stored end values, also when they have zero length
    pa = Path()
    straight!(pa, 30μm, Paths.TaperCPW(10μm, 6μm, 2μm, 1μm))
    @test hook_style(p0_hook(pa)) == Paths.CPW(10.0μm, 6.0μm)
    @test hook_style(p1_hook(pa)) == Paths.CPW(2.0μm, 1.0μm)
    for (taper, sty0, sty1) in (
        (
            Paths.TaperCPW(10μm, 6μm, 2μm, 1μm),
            Paths.CPW(10.0μm, 6.0μm),
            Paths.CPW(2.0μm, 1.0μm)
        ),
        (Paths.TaperTrace(10μm, 20μm), Paths.Trace(10.0μm), Paths.Trace(20.0μm))
    )
        pz = Path()
        straight!(pz, 0μm, taper)
        @test hook_style(p0_hook(pz)) == sty0
        @test hook_style(p1_hook(pz)) == sty1
    end

    # A path that is only a termination has the terminated cross section where it connects
    for xsty in (Paths.CPW(10μm, 6μm), Paths.Trace(10μm))
        pt = Path()
        straight!(pt, 2μm, xsty)
        terminate!(pt; rounding=2μm)
        @test length(pt) == 1
        @test hook_style(p0_hook(pt)) == xsty
        @test hook_style(p1_hook(pt)) == Paths.NoRenderContinuous()
    end

    # Substyles at a periodic boundary get pathlengths of the path's coordinate type
    seen = []
    template = Path(μm)
    straight!(template, 800μm, Paths.Trace(x -> (push!(seen, typeof(x)); 10μm)))
    straight!(template, 800μm, Paths.SimpleTrace(20μm))
    pp = Path(μm)
    straight!(pp, 800μm, Paths.PeriodicStyle(template))
    empty!(seen)
    @test hook_width(p1_hook(pp)) ≈ 10μm
    @test unique(seen) == [typeof(pathlength(pp))]
    # Also for an integer path
    template = Path{Float64}()
    straight!(template, 800.0, Paths.SimpleTrace(10.0))
    straight!(template, 800.0, Paths.SimpleTrace(20.0))
    pp = Path{Int}()
    straight!(pp, 800, Paths.PeriodicStyle(template))
    @test hook_style(p0_hook(pp)) == Paths.Trace(10.0)
end

# --- Graph-level terminate! -----------------------------------------------

@testitem "terminate!(g, node, :hook) with StyledHook opens a CPW" setup = [CommonTestSetup] begin
    using DeviceLayout.Paths
    using DeviceLayout.SchematicDrivenLayout

    sty = Paths.CPW(10μm, 6μm)
    # Build a short CPW path as the base component.
    pa = Path(0mm, 0mm; α0=0°, name="base")
    straight!(pa, 100μm, sty)

    g = SchematicGraph("testgraph")
    base_node = add_node!(g, pa)

    term_node = terminate!(g, base_node, :p1; gap=5μm)
    @test term_node isa ComponentNode
    # Termination component should itself be a Path
    @test component(term_node) isa Path
    @test length(component(term_node)) == 2 # Two nodes
    @test iszero(pathlength(component(term_node)[1].seg)) # Zero-length first node
    @test component(term_node)[end].sty.open_gap == 5μm # Termination gap provided
    @test component(term_node)[end].sty.gap == 6μm # CPW gap
end

@testitem "terminate! with gap=0 is a short" setup = [CommonTestSetup] begin
    using DeviceLayout.Paths
    using DeviceLayout.SchematicDrivenLayout

    sty = Paths.CPW(10μm, 6μm)
    pa = Path(0mm, 0mm; α0=0°, name="base_short")
    straight!(pa, 100μm, sty)

    g = SchematicGraph("g_short")
    nd = add_node!(g, pa)
    term_node = terminate!(g, nd, :p1; style=sty, gap=0μm, rounding=2μm, margin=1μm)
    @test term_node isa ComponentNode
    # With rounding+margin > 0, the termination stub must have an initial
    # straight segment of length backtracking = rounding + margin (3μm here).
    tp = component(term_node)
    @test tp isa Path
    @test pathlength(tp) == 3μm
end

@testitem "terminate! with rounding produces a rounded open" setup = [CommonTestSetup] begin
    using DeviceLayout.Paths
    using DeviceLayout.SchematicDrivenLayout

    sty = Paths.CPW(10μm, 6μm)
    pa = Path(0mm, 0mm; α0=0°, name="base_round")
    straight!(pa, 100μm, sty)

    g = SchematicGraph("g_round")
    nd = add_node!(g, pa)
    term_node = terminate!(g, nd, :p1; style=sty, rounding=3μm)
    @test term_node isa ComponentNode
    @test component(term_node)[end].sty.rounding == 3μm
end

@testitem "terminate!(g, node, :hook) errors on bare hook without explicit style" setup =
    [CommonTestSetup] begin
    using DeviceLayout.Paths
    using DeviceLayout.SchematicDrivenLayout

    sty = Paths.CPW(10μm, 6μm)
    pa = Path(0mm, 0mm; α0=0°, name="base_err")
    straight!(pa, 100μm, sty)

    g = SchematicGraph("g_err")
    nd = add_node!(g, WeatherVane{typeof(1.0nm)}())
    # Hooks are bare PointHooks (no StyledHook wrap); no style= kwarg ⇒ error.
    @test_throws ErrorException terminate!(g, nd, :west)
end

@testitem "terminate! metadata resolution" setup = [CommonTestSetup] begin
    using DeviceLayout.Paths
    using DeviceLayout.SchematicDrivenLayout

    sty = Paths.CPW(10μm, 6μm)
    pa = Path(0mm, 0mm; α0=0°, name="base_meta", metadata=GDSMeta(3))
    straight!(pa, 100μm, sty)

    g = SchematicGraph("g_meta")
    nd = add_node!(g, pa)
    # From the StyledHook
    @test component(terminate!(g, nd => :p1)).metadata == GDSMeta(3)
    # Explicit metadata wins
    @test component(terminate!(g, nd => :p0; metadata=GDSMeta(4))).metadata == GDSMeta(4)
    # Bare hook: explicit metadata, otherwise undefined
    nd = add_node!(g, WeatherVane{typeof(1.0nm)}())
    @test component(terminate!(g, nd => :west; style=sty, metadata=GDSMeta(5))).metadata ==
          GDSMeta(5)
    @test component(terminate!(g, nd => :east; style=sty)).metadata ==
          DeviceLayout.UNDEF_META
end

@testitem "terminate!(g, node => :hook) Pair form works" setup = [CommonTestSetup] begin
    using DeviceLayout.Paths
    using DeviceLayout.SchematicDrivenLayout

    sty = Paths.CPW(10μm, 6μm)
    pa = Path(0mm, 0mm; α0=0°, name="base_pair")
    straight!(pa, 100μm, sty)

    g = SchematicGraph("g_pair")
    nd = add_node!(g, pa)
    term_node = terminate!(g, nd => :p1; style=sty, gap=5μm)
    @test term_node isa ComponentNode
end

@testitem "_build_termination_path: backtracking invariant (rounding+margin)" setup =
    [CommonTestSetup] begin
    using DeviceLayout.Paths

    sty = Paths.CPW(10μm, 6μm)
    h = PointHook(0mm, 0mm, 0°)
    # Use the internal helper directly via fully-qualified access.
    tp = DeviceLayout.SchematicDrivenLayout._build_termination_path(
        h,
        sty,
        GDSMeta();
        rounding=3μm,
        margin=2μm,
        gap=5μm
    )
    @test tp isa Path
    # The stub starts at the hook point with out_direction = 180° (for in_direction=0°).
    @test Paths.p0(tp) == h.p
    # Total path length is backtracking (3+2=5μm) + gap (5μm) = 10μm.
    # After termination: straight(5μm, sty) + terminate!(gap=5μm, rounding+margin
    # backtracking merges last 2 into a single termination-style node of length 5+5=10μm
    # per src/paths/contstyles/termination.jl
    @test Paths.pathlength(tp) ≈ 10μm
end

@testitem "terminate! uses StyledHook's carried style via _resolve_termination_style" setup =
    [CommonTestSetup] begin
    using DeviceLayout.Paths
    using DeviceLayout.SchematicDrivenLayout

    # Directly verify the helper that looks up the hook's carried style.
    sty = Paths.CPW(10μm, 6μm)
    sh = StyledHook(PointHook(0μm, 0μm, 0°), sty)
    h_bare = PointHook(0μm, 0μm, 0°)

    resolve = DeviceLayout.SchematicDrivenLayout._resolve_termination_style

    # Nothing passed, StyledHook → use its style
    @test resolve(sh, nothing, nothing, :dummy) === sty

    # User style=custom_sty always wins, even over a StyledHook
    other_sty = Paths.CPW(20μm, 12μm)
    @test resolve(sh, other_sty, nothing, :dummy) === other_sty

    # Bare hook without user style → error
    @test_throws ErrorException resolve(h_bare, nothing, (id="n1",), :dummy)

    # Bare hook with explicit user style → returns that style
    @test resolve(h_bare, sty, nothing, :dummy) === sty
end

@testitem "terminate! with RouteComponent" setup = [CommonTestSetup] begin
    using DeviceLayout.SchematicDrivenLayout
    g = SchematicGraph("test")
    n1 = add_node!(g, Spacer(1mm, 1mm))
    n2 = fuse!(g, n1 => :p1_east, WeatherVane() => :west)
    rn = route!(
        g,
        Paths.BSplineRouting(),
        n1 => :p0_west,
        n2 => :east,
        Paths.TaperTrace(10μm, 1μm),
        GDSMeta()
    )
    rc = component(rn)
    rc_hooks = @test_logs (:warn, r"has not been planned") hooks(rc)
    @test hook_style(rc_hooks.p0) == Paths.Trace(10μm)
    @test hook_style(rc_hooks.p1) == Paths.Trace(1μm)
    @test in_direction(rc_hooks.p1) % 360° == 180°
    # Once planned, hooks are at the planned endpoints
    sch = plan(g; log_dir=nothing)
    rc_hooks = @test_logs hooks(rc)
    @test rc_hooks.p1.p ≈ hooks(sch, n2).east.p
    # Once built, hook styles are the path's end cross sections
    pa = SchematicDrivenLayout.path(rc)
    @test hook_style(hooks(rc).p1) == hook_style(p1_hook(pa))
    @test hooks(rc).p1 isa StyledHook{<:Any, <:PointHook}
    # A route given with its endpoints needs no planning
    explicit = RouteComponent(
        "explicit",
        Paths.Route(Paths.StraightAnd90(), Point(0μm, 0μm), Point(1mm, 0μm), 0°, 0°),
        false,
        Paths.Trace(10μm),
        GDSMeta()
    )
    @test (@test_logs hooks(explicit)).p1.p == Point(1mm, 0μm)
    # terminate! on RouteComponent doesn't work, because RC hook position is determined last
    @test_throws ArgumentError terminate!(g, rn => :p1; rounding=0.1μm)
end
