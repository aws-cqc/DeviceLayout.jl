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
        sty;
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
    @test hook_style(hooks(rc).p0) == Paths.Trace(10μm)
    @test hook_style(hooks(rc).p1) == Paths.Trace(1μm)
    @test in_direction(hooks(rc).p1) % 360° == 180°
    # terminate! on RouteComponent doesn't work, because RC hook position is determined last
    @test_throws ArgumentError terminate!(g, rn => :p1; rounding=0.1μm)
end
