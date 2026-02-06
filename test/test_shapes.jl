@testitem "Rounding" setup = [CommonTestSetup] begin
    using Random, LinearAlgebra
    rng = MersenneTwister(1337)
    c = Cell("main", nm)
    poly = Polygon(Point(0, 0)μm, Point(1, 0)μm, Point(1, 1)μm)
    render!(c, Polygons.Rounded(0.1μm)(poly); atol=20nm)
    @test length(points((elements(c)[1]))) == 9

    cs = CoordinateSystem("abc", nm)
    render!(cs, Polygons.Rounded(0.1μm)(poly), GDSMeta(0))
    c = Cell(cs, nm; atol=20nm)
    @test length(points((elements(c)[1]))) == 9

    # check that polygons aren't rounded if min_angle is set
    poly = Polygons._round_poly(circle_polygon(10μm, 5°), 0.5μm, min_angle=10 / 180 * π)
    @test length(points(poly)) == 72

    @test Polygons._round_poly(Rectangle(10.0, 10.0), 1.0) isa Polygon

    # check that for `_round_poly`, points corresponding to those not included in
    # `corner_indices` will be present in the returned polygon by construction, regardless
    # of rounding radius. Needed for `terminate!` to behave as expected.
    poly = Polygon(
        Point(0, 2.0)μm,
        Point(0, 1)μm,
        Point(1, 1)μm,
        Point(1, 0)μm,
        Point(2, 0)μm,
        Point(2, 2)μm
    )
    for r in (0.5μm, 1.0μm, 2.0μm)
        rpoly = Polygons._round_poly(poly, r; corner_indices=[3])
        @test Point(0, 1.0)μm in points(rpoly)
        @test Point(1.0, 0)μm in points(rpoly)
    end

    # Rounding a clipped polygon equivalent to clipping rounded polygons.
    r1 = centered(Rectangle(2μm, 2μm))
    r2 = centered(Rectangle(1μm, 1μm))

    # A clipped polygon, where the round has been discretized on each clip.
    rd1 = Polygons._round_poly(difference2d(r1, r2), 0.25μm)
    r1 = Polygons._round_poly(r1, 0.25μm)
    r2 = Polygons._round_poly(r2, 0.25μm)

    rd2 = difference2d(r1, r2)
    @test isapprox(rd1, rd2, atol=0.1nm)

    # Rounding with style
    r1 = centered(Rectangle(2μm, 2μm))
    r2 = centered(Rectangle(1μm, 1μm))
    rd3 = Polygons.Rounded(0.25μm)(difference2d(r1, r2))
    @test all(isapprox.(to_polygons(rd1), to_polygons(rd3), atol=0.1nm))

    # rendering a styled ClippedPolygon should give no warnings
    cs = CoordinateSystem("test", nm)
    place!(cs, rd3, GDSMeta())
    @test_nowarn render!(Cell("test", nm), cs)

    # Rounding of subset of vertices with style
    rs1 = Polygons.Rounded(0.25μm, p0=points(r1)[[1, 3]])(r1)
    rs2 = Polygons.Rounded(0.25μm, p0=points(r2)[[1, 3]])(r2)

    # Clipping subrounded style
    rd1 = Polygons._round_poly(difference2d(r1, r2), 0.25μm, corner_indices=[1, 3])
    rd2 = Polygons.Rounded(0.25μm, p0=points(r1)[[1, 3]])(difference2d(r1, r2))
    @test all(isapprox.(to_polygons(rd1), to_polygons(rd2), atol=0.1nm))

    # StyleDict to apply different style at each level.
    r1 = centered(Rectangle(2μm, 2μm))
    r2 = centered(Rectangle(1μm, 1μm))
    rd1 = difference2d(r1, r2)
    bk = deepcopy(rd1) # check no mutation

    # rendering with a plain style d should change nothing
    d = StyleDict()
    plain_render = to_polygons(rd1, d)
    @test all(isapprox.(plain_render, to_polygons(rd1), atol=0.1nm))

    # rendering with NoRender should give nothing
    d = StyleDict(DeviceLayout.NoRender())
    no_render = to_polygons(rd1, d)
    @test isempty(no_render)

    # rendering with a StyleDict of Rounded equivalent to same on all nodes.
    d = StyleDict(Polygons.Rounded(0.25μm))
    all_rounded_render = to_polygons(rd1, d)
    rdr = Polygons.Rounded(0.25μm)(rd1)
    @test all(isapprox.(all_rounded_render, to_polygons(rdr), atol=0.1nm))
    @test bk == rd1 # does not mutate rd1

    # Repeat call
    all_rounded_render = to_polygons(rd1, d)
    @test all(isapprox.(all_rounded_render, to_polygons(rdr), atol=0.1nm))
    @test bk == rd1 # does not mutate rd1

    # Apply a rounding to only the negative
    d = StyleDict()
    d[rd1[1, 1]] = Polygons.Rounded(0.25μm)

    cs = CoordinateSystem("test", nm)
    place!.(cs, to_polygons(rd1, d), GDSMeta())
    @test_nowarn render!(Cell("test", nm), cs)

    @test to_polygons(rd1, d) != plain_render
    @test to_polygons(rd1, d) != all_rounded_render

    rds = DeviceLayout.styled(rd1, d)
    @test to_polygons(rds) != plain_render
    @test to_polygons(rds) != all_rounded_render
    @test to_polygons(rd1, d) == to_polygons(rds)

    cs = CoordinateSystem("test", nm)
    place!(cs, rds, GDSMeta())
    @test_nowarn render!(Cell("test", μm), cs)

    cs = CoordinateSystem("test", μm)
    place!(cs, rds, GDSMeta())
    @test_nowarn render!(Cell("test", nm), cs)

    cs = CoordinateSystem("test", nm)
    place!.(cs, to_polygons(rds), GDSMeta())
    @test_nowarn render!(Cell("test", nm), cs)

    # Different accessors and setters for StyleDict
    d2 = StyleDict()
    d2[1, 1] = Polygons.Rounded(0.25μm)
    rds2 = DeviceLayout.styled(rd1, d2)
    @test to_polygons(rds) == to_polygons(rds2)

    d2 = StyleDict()
    d2[[1, 1]] = Polygons.Rounded(0.25μm)
    rds2 = DeviceLayout.styled(rd1, d2)
    @test to_polygons(rds) == to_polygons(rds2)

    @test d2[1] == DeviceLayout.Plain()
    @test d2[[1]] == DeviceLayout.Plain()
    @test radius(d2[1, 1]) == radius(Polygons.Rounded(0.25μm))
    @test d2[1, 1].min_side_len == Polygons.Rounded(0.25μm).min_side_len
    @test d2[1, 1].min_angle == Polygons.Rounded(0.25μm).min_angle
    @test d2[1, 1].p0 == Polygons.Rounded(0.25μm).p0

    @test radius(d2[[1, 1]]) == radius(Polygons.Rounded(0.25μm))
    @test d2[[1, 1]].min_side_len == Polygons.Rounded(0.25μm).min_side_len
    @test d2[[1, 1]].min_angle == Polygons.Rounded(0.25μm).min_angle
    @test d2[[1, 1]].p0 == Polygons.Rounded(0.25μm).p0

    # Apply a Rounding style specified by target points
    sty = Polygons.Rounded(2.0μm, p0=[Point(1.0μm, 1.0μm), Point(-1.0μm, -1.0μm)])
    r = centered(Rectangle(2.0μm, 2.0μm))
    rs = styled(r, sty)
    cs = CoordinateSystem("test", nm)
    c = Cell("test", nm)
    @test_nowarn place!(cs, rs, GDSMeta())
    @test_nowarn render!(c, cs)

    @test Point(1.0μm, 1.0μm) ∉ points(to_polygons(rs))
    @test Point(-1.0μm, -1.0μm) ∉ points(to_polygons(rs))
    @test Point(1.0μm, -1.0μm) ∈ points(to_polygons(rs))
    @test Point(-1.0μm, 1.0μm) ∈ points(to_polygons(rs))

    # Applying a reflection about x = 0 transforms `p0`.
    yref = DeviceLayout.Reflection(π / 2)
    rsref = yref(rs)
    cs = CoordinateSystem("test", nm)
    c = Cell("test", nm)
    @test_nowarn place!(cs, rsref, GDSMeta())
    @test_nowarn render!(c, cs)

    @test Point(1.0μm, 1.0μm) ∈ points(to_polygons(rsref))
    @test Point(-1.0μm, -1.0μm) ∈ points(to_polygons(rsref))
    @test Point(1.0μm, -1.0μm) ∉ points(to_polygons(rsref))
    @test Point(-1.0μm, 1.0μm) ∉ points(to_polygons(rsref))

    # inverse selection reverses the effect
    sty = Polygons.Rounded(
        2.0μm,
        p0=[Point(1.0μm, 1.0μm), Point(-1.0μm, -1.0μm)],
        inverse_selection=true
    )
    rs = styled(r, sty)
    cs = CoordinateSystem("test", nm)
    c = Cell("test", nm)
    @test_nowarn place!(cs, rs, GDSMeta())
    @test_nowarn render!(c, cs)

    @test Point(1.0μm, 1.0μm) ∈ points(to_polygons(rs))
    @test Point(-1.0μm, -1.0μm) ∈ points(to_polygons(rs))
    @test Point(1.0μm, -1.0μm) ∉ points(to_polygons(rs))
    @test Point(-1.0μm, 1.0μm) ∉ points(to_polygons(rs))

    # Applying a reflection about x = 0 transforms `p0`.
    yref = DeviceLayout.Reflection(π / 2)
    rsref = yref(rs)
    cs = CoordinateSystem("test", nm)
    c = Cell("test", nm)
    @test_nowarn place!(cs, rsref, GDSMeta())
    @test_nowarn render!(c, cs)

    @test Point(1.0μm, 1.0μm) ∉ points(to_polygons(rsref))
    @test Point(-1.0μm, -1.0μm) ∉ points(to_polygons(rsref))
    @test Point(1.0μm, -1.0μm) ∈ points(to_polygons(rsref))
    @test Point(-1.0μm, 1.0μm) ∈ points(to_polygons(rsref))

    r = Rectangle(2μm, 1μm)
    cs_local = CoordinateSystem("test", μm)
    sty = Rounded(0.25μm, p0=points(r))
    place!(cs_local, styled(r, sty), GDSMeta())
    cs = CoordinateSystem("outer", nm)
    addref!(cs, sref(cs_local, angle=π / 2))

    # flattening must transform p0 too
    @test all(cs.refs[1].structure.elements[1].sty.p0 .≈ points(r))
    fc = DeviceLayout.flatten(cs)
    @test all(sort(fc.elements[1].sty.p0) .≈ sort(points(fc.elements[1].ent)))

    # mixing rendering units works, and directly on polygons works
    r = to_polygons(Rectangle(2μm, 1μm))
    cs_local = CoordinateSystem("test", nm)
    sty = Rounded(0.25μm, p0=points(r))
    place!(cs_local, styled(r, sty), GDSMeta())
    cs = CoordinateSystem("outer", nm)
    addref!(cs, sref(cs_local, angle=π / 2))

    # flattening must transform p0 too
    @test all(cs.refs[1].structure.elements[1].sty.p0 .≈ points(r))
    fc = flatten(cs)
    @test all(fc.elements[1].sty.p0 .≈ points(fc.elements[1].ent))

    sty = RelativeRounded(0.25)
    poly = Polygon(
        Point(0.0μm, 0.0μm),
        Point(1.0μm, 0.0μm),
        Point(2.0μm, 2.0μm),
        Point(0.0μm, 4.0μm)
    )

    cs = CoordinateSystem("test", nm)
    @test_nowarn place!(cs, styled(poly, sty), GDSMeta())
    c = Cell("test", nm)
    @test_nowarn render!(c, cs)

    poly = difference2d(Rectangle(2.0μm, 2.0μm), Rectangle(1.0μm, 1.0μm))
    e = styled(poly, sty)
    pp = points(to_polygons(e)[1])
    @test Point(0.0μm, 0.0μm) ∉ pp
    @test Point(2.0μm, 0.0μm) ∉ pp
    @test Point(2.0μm, 1.0μm) ∉ pp
    @test Point(1.0μm, 1.0μm) ∉ pp
    @test Point(1.0μm, 2.0μm) ∉ pp
    @test Point(0.0μm, 2.0μm) ∉ pp

    cs = CoordinateSystem("test", nm)
    @test_nowarn place!(cs, e, GDSMeta())
    c = Cell("test", nm)
    @test_nowarn render!(c, cs)

    poly =
        difference2d(centered(Rectangle(4.0μm, 4.0μm)), centered(Rectangle(2.0μm, 2.0μm)))

    sty = StyleDict()
    sty[1] = RelativeRounded(0.5, p0=[Point(2.0μm, 2.0μm), Point(-2.0μm, -2.0μm)])
    sty[1, 1] = RelativeRounded(0.5, p0=[Point(2.0μm, -2.0μm), Point(-2.0μm, 2.0μm)])
    e = styled(poly, sty)
    # correct end points removed
    pp = points(to_polygons(e)[1])
    @test Point(2.0μm, 2.0μm) ∉ pp
    @test Point(2.0μm, -2.0μm) ∈ pp
    @test Point(-2.0μm, -2.0μm) ∉ pp
    @test Point(-2.0μm, 2.0μm) ∈ pp

    @test Point(1.0μm, 1.0μm) ∈ pp
    @test Point(1.0μm, -1.0μm) ∉ pp
    @test Point(-1.0μm, -1.0μm) ∈ pp
    @test Point(-1.0μm, 1.0μm) ∉ pp

    # rounding start points are all present
    @test Point(2.0μm, 0.0μm) ∈ pp
    @test Point(1.0μm, 0.0μm) ∈ pp
    @test Point(-2.0μm, 0.0μm) ∈ pp
    @test Point(-1.0μm, 0.0μm) ∈ pp

    @test Point(0.0μm, 2.0μm) ∈ pp
    @test Point(0.0μm, 1.0μm) ∈ pp
    @test Point(0.0μm, -2.0μm) ∈ pp
    @test Point(0.0μm, -1.0μm) ∈ pp

    cs = CoordinateSystem("test", nm)
    @test_nowarn place!(cs, e, GDSMeta())
    c = Cell("test", nm)
    @test_nowarn render!(c, cs)

    er = Rotation(90°)(e)
    pp = points(Rotation(-90°)(to_polygons(er)[1]))
    # Should be equivalent to original (although keyhole will be different)
    # correct end points removed
    @test Point(2.0μm, 2.0μm) ∉ pp
    @test Point(2.0μm, -2.0μm) ∈ pp
    @test Point(-2.0μm, -2.0μm) ∉ pp
    @test Point(-2.0μm, 2.0μm) ∈ pp

    @test Point(1.0μm, 1.0μm) ∈ pp
    @test Point(1.0μm, -1.0μm) ∉ pp
    @test Point(-1.0μm, -1.0μm) ∈ pp
    @test Point(-1.0μm, 1.0μm) ∉ pp

    # rounding start points are all present
    @test Point(2.0μm, 0.0μm) ∈ pp
    @test Point(1.0μm, 0.0μm) ∈ pp
    @test Point(-2.0μm, 0.0μm) ∈ pp
    @test Point(-1.0μm, 0.0μm) ∈ pp

    @test Point(0.0μm, 2.0μm) ∈ pp
    @test Point(0.0μm, 1.0μm) ∈ pp
    @test Point(0.0μm, -2.0μm) ∈ pp
    @test Point(0.0μm, -1.0μm) ∈ pp

    # DeviceLayout#24 Rounding occasionally fails when radius equals min_side_len
    r = Rectangle(1.0μm, 1.0μm)
    rr = Polygons._round_poly(r, 500.0nm; corner_indices=[2, 4])
    rrr = Polygons._round_poly(rr, 500.0nm; corner_indices=[1]) # Round point at (0,0)
    @test !iszero(points(rrr)[1]) # first point would be (0,0) if rounding failed

    # DeviceLayout#115 Applying Rounded to ClippedPolygon
    r1 = centered(Rectangle(2.0μm, 2.0μm))
    r2 = centered(Rectangle(4.0μm, 4.0μm))
    p0 = [Point(1.0μm, 1.0μm)] # should be only point on outer poly
    sty = Rounded(1.0μm; p0)

    # Removes top right
    pp = points(to_polygons(styled(r1, sty)))
    @test Point(1.0μm, 1.0μm) ∉ pp
    @test Point(-1.0μm, 1.0μm) ∈ pp
    @test Point(-1.0μm, -1.0μm) ∈ pp
    @test Point(1.0μm, -1.0μm) ∈ pp

    # Removes top right
    pp = points(to_polygons(styled(r2, sty)))
    @test Point(2.0μm, 2.0μm) ∉ pp
    @test Point(-2.0μm, 2.0μm) ∈ pp
    @test Point(-2.0μm, -2.0μm) ∈ pp
    @test Point(2.0μm, -2.0μm) ∈ pp

    cc = difference2d(r2, r1)
    csty = styled(cc, sty)
    pp = points(to_polygons(csty)[1])
    @test length(pp) > 11 # There are some rounded points
    @test Point(1.0μm, 1.0μm) ∉ pp # rounded
    @test Point(-1.0μm, 1.0μm) ∈ pp
    @test Point(-1.0μm, -1.0μm) ∈ pp
    @test Point(1.0μm, -1.0μm) ∈ pp

    @test Point(2.0μm, 2.0μm) ∉ pp # rounded
    @test Point(-2.0μm, 2.0μm) ∈ pp
    @test Point(-2.0μm, -2.0μm) ∈ pp
    @test Point(2.0μm, -2.0μm) ∈ pp

    # Rounded style with tight tolerance
    sty = Rounded(1.0μm; p0, selection_tolerance=1nm)

    # Removes top right
    pp = points(to_polygons(styled(r1, sty)))
    @test Point(1.0μm, 1.0μm) ∉ pp # rounded
    @test Point(-1.0μm, 1.0μm) ∈ pp
    @test Point(-1.0μm, -1.0μm) ∈ pp
    @test Point(1.0μm, -1.0μm) ∈ pp

    # Removes top right
    pp = points(to_polygons(styled(r2, sty)))
    @test Point(2.0μm, 2.0μm) ∈ pp
    @test Point(-2.0μm, 2.0μm) ∈ pp
    @test Point(-2.0μm, -2.0μm) ∈ pp
    @test Point(2.0μm, -2.0μm) ∈ pp

    cc = difference2d(r2, r1)
    csty = styled(cc, sty)
    pp = points(to_polygons(csty)[1])
    @test length(pp) > 11 # There are some rounded points
    @test Point(1.0μm, 1.0μm) ∉ pp # rounded
    @test Point(-1.0μm, 1.0μm) ∈ pp
    @test Point(-1.0μm, -1.0μm) ∈ pp
    @test Point(1.0μm, -1.0μm) ∈ pp

    @test Point(2.0μm, 2.0μm) ∈ pp # not rounded
    @test Point(-2.0μm, 2.0μm) ∈ pp
    @test Point(-2.0μm, -2.0μm) ∈ pp
    @test Point(2.0μm, -2.0μm) ∈ pp

    cs = CoordinateSystem("abc", nm)
    @test_nowarn place!(cs, csty, GDSMeta())
    c = Cell("main", nm)
    @test_nowarn render!(c, cs)

    # Use float input polygon coordinatetype -- don't promote with rounded type
    r_int = Rectangle(2μm2μm, 2μm2μm)
    r_float = Rectangle(2.0μm2μm, 2.0μm2μm)
    rnd = Rounded(0.5μm2nm)
    @test coordinatetype(to_polygons(rnd(r_int))) == typeof(1.02μm2μm)
    @test coordinatetype(to_polygons(rnd(r_float))) == typeof(1.02μm2μm)
end

@testitem "Curvilinear" setup = [CommonTestSetup] begin
    # A basic, noncurved polygon
    pp = [Point(0.0μm, 0.0μm), Point(1.0μm, 0.0μm), Point(0.0μm, 1.0μm)]
    cp = CurvilinearPolygon(pp)
    cs = CoordinateSystem("abc", nm)
    @test_nowarn place!(cs, cp, GDSMeta())
    c = Cell("main", nm)
    @test_nowarn render!(c, cs)
    @test all(points(cp) .== pp)

    # A π/2 rotation to test transformation
    t = RotationPi(0.5)

    # Add a turn instead of the hypotenuse
    cp = CurvilinearPolygon(pp, [Paths.Turn(90°, 1.0μm, α0=90°, p0=pp[2])], [2])
    cs = CoordinateSystem("abc", nm)
    @test_nowarn place!(cs, cp, GDSMeta())
    c = Cell("main", nm)
    @test_nowarn render!(c, cs)
    pgen = points(to_polygons(cp))
    cpt = t(cp)
    ptgen = points(to_polygons(cpt))

    # Reverse parameterized turn
    cp = CurvilinearPolygon(pp, [Paths.Turn(-90°, 1.0μm, α0=0°, p0=pp[3])], [-2])
    cs = CoordinateSystem("abc", nm)
    @test_nowarn place!(cs, cp, GDSMeta())
    c = Cell("main", nm)
    @test_nowarn render!(c, cs)

    # Reverse parameterized and forward parameterized should produce same number of points
    @test length(points(to_polygons(cp))) == length(pgen)
    @test length(points(to_polygons(t(cp)))) == length(ptgen)

    cs = CoordinateSystem("abc", nm)
    @test_nowarn place!(cs, cpt, GDSMeta())
    c = Cell("main", nm)
    @test_nowarn render!(c, cs)

    # Clipping the transformed inverse and forward should give negligible difference.
    # Adaptive discretization may produce thin slivers rather than exactly empty.
    diff_poly = difference2d(to_polygons(cpt), to_polygons(t(cp)))
    @test perimeter(diff_poly) < 0.1μm

    # Convert a SimpleTrace to a CurvilinearRegion
    pa = Path(0nm, 0nm)
    straight!(pa, 100μm, Paths.SimpleTrace(10.0μm))
    turn!(pa, π, 50μm, Paths.SimpleTrace(10.0μm))
    cr = pathtopolys.(pa)
    cs = CoordinateSystem("abc", nm)
    place!(cs, cr[1], GDSMeta())
    place!(cs, cr[2], GDSMeta())
    c = Cell("main", nm)
    @test_nowarn render!(c, cs)

    # Tolerance-based discretization: coarser atol should produce fewer points than finer
    cp = CurvilinearPolygon(pp, [Paths.Turn(90°, 1.0μm, α0=90°, p0=pp[2])], [2])
    coarse = to_polygons(cp; atol=2.0nm)
    fine = to_polygons(cp; atol=0.1nm)
    @test length(points(coarse)) < length(points(fine))
end

@testitem "Ellipses" setup = [CommonTestSetup] begin
    import LinearAlgebra: norm
    e = Ellipse(2 .* Point(2.0μm, 1.0μm), (2.0μm, 1.0μm), 0°)

    em = magnify(e, 2)
    @test isapprox(ustrip(norm(em.radii .- 2 .* e.radii)), 0.0, atol=1e-14)
    @test isapprox(ustrip(norm(em.angle .- e.angle)), 0.0, atol=1e-14)
    @test isapprox(ustrip(norm(em.center .- 2 .* e.center)), 0.0, atol=1e-14)

    et = translate(e, Point(1.0μm, 2.0μm))
    @test isapprox(ustrip(norm(et.radii .- e.radii)), 0.0, atol=1e-14)
    @test isapprox(ustrip(norm(et.angle .- e.angle)), 0.0, atol=1e-14)
    @test isapprox(
        ustrip(norm(et.center .- (e.center .+ Point(1.0μm, 2.0μm)))),
        0.0,
        atol=1e-14
    )
    et = transform(e, ScaledIsometry(Translation(Point(1.0μm, 2.0μm))))
    @test isapprox(ustrip(norm(et.radii .- e.radii)), 0.0, atol=1e-14)
    @test isapprox(ustrip(norm(et.angle .- e.angle)), 0.0, atol=1e-14)
    @test isapprox(
        ustrip(norm(et.center .- (e.center .+ Point(1.0μm, 2.0μm)))),
        0.0,
        atol=1e-14
    )
    @test et == Translation(Point(1.0μm, 2.0μm))(e)

    er = rotate(e, 45°)
    @test isapprox(ustrip(norm(er.radii .- e.radii)), 0.0, atol=1e-14)
    @test isapprox(ustrip(norm(er.angle .- e.angle)), 45.0, atol=1e-14)
    @test isapprox(ustrip(norm(er.center .- (Rotation(45°)(e.center)))), 0.0, atol=1e-14)
    er = transform(e, ScaledIsometry(Rotation(45°)))
    @test isapprox(ustrip(norm(er.radii .- e.radii)), 0.0, atol=1e-14)
    @test isapprox(ustrip(norm(er.angle .- e.angle)), 45.0, atol=1e-14)
    @test isapprox(ustrip(norm(er.center .- (Rotation(45°)(e.center)))), 0.0, atol=1e-14)
    @test er == Rotation(45°)(e)

    ex = reflect_across_xaxis(e)
    Refl = Reflection(0)
    @test isapprox(ustrip(norm(ex.radii .- e.radii)), 0.0, atol=1e-14)
    @test isapprox(
        ustrip(norm(ex.angle .- rotated_direction(e.angle, Refl))),
        0.0,
        atol=1e-14
    )
    @test isapprox(ustrip(norm(ex.center .- Refl(e.center))), 0.0, atol=1e-14)

    ex = transform(e, ScaledIsometry(Refl))
    @test isapprox(ustrip(norm(ex.radii .- e.radii)), 0.0, atol=1e-14)
    @test isapprox(
        ustrip(norm(ex.angle .- rotated_direction(e.angle, Refl))),
        0.0,
        atol=1e-14
    )
    @test isapprox(ustrip(norm(ex.center .- Refl(e.center))), 0.0, atol=1e-14)
    @test ex == Refl(e)

    er = reflect_across_line(e, Point(1.0μm, 2.0μm))
    Refl = Reflection(Point(1.0μm, 2.0μm))
    @test isapprox(ustrip(norm(er.radii .- e.radii)), 0.0, atol=1e-14)
    @test isapprox(
        ustrip(norm(er.angle .- rotated_direction(e.angle, Refl))),
        0.0,
        atol=1e-14
    )
    @test isapprox(ustrip(norm(er.center .- Refl(e.center))), 0.0, atol=1e-14)

    er = transform(e, ScaledIsometry(Refl))
    @test isapprox(ustrip(norm(er.radii .- e.radii)), 0.0, atol=1e-14)
    @test isapprox(
        ustrip(norm(er.angle .- rotated_direction(e.angle, Refl))),
        0.0,
        atol=1e-14
    )
    @test isapprox(ustrip(norm(er.center .- Refl(e.center))), 0.0, atol=1e-14)
    @test er == Refl(e)

    er = reflect_across_line(e, Point(0.0μm, 0.0μm), Point(1.0μm, 2.0μm))
    @test isapprox(ustrip(norm(er.radii .- e.radii)), 0.0, atol=1e-14)
    @test isapprox(
        ustrip(norm(er.angle .- rotated_direction(e.angle, Refl))),
        0.0,
        atol=1e-14
    )
    @test isapprox(ustrip(norm(er.center .- Refl(e.center))), 0.0, atol=1e-14)

    shear = Transformations.LinearMap(Transformations.@SMatrix [2 0; 0 1])
    @test !Transformations.preserves_angles(shear)
    es = shear(e) # Simple case with aligned axes
    @test es.angle == 0.0°
    @test es.center == shear(e.center)
    @test isapprox(ustrip(norm(es.radii .- [4.0μm, 1.0μm])), 0.0, atol=1e-14)

    cs = CoordinateSystem("test", nm)
    c = Cell("test", nm)
    @test_nowarn place!(cs, e, GDSMeta())
    @test_nowarn render!(c, cs)

    @test_nowarn place!(cs, ex, GDSMeta())
    @test_nowarn render!(c, cs)

    @test_nowarn place!(cs, er, GDSMeta())
    @test_nowarn render!(c, cs)

    # Test tolerance-based discretization (new default)
    e_default = to_polygons(e)  # Should use atol by default
    e_delta_style = to_polygons(e; Δθ=5°)  # Δθ-based approach

    # The new tolerance-based approach should produce more points than 5° steps
    @test length(points(e_default)) > length(points(e_delta_style))

    # Test that atol parameter works
    e_coarse = to_polygons(e; atol=0.1μm)  # Very coarse tolerance
    e_fine = to_polygons(e; atol=1.0nm)    # Very fine tolerance

    # Coarse tolerance should produce fewer points than fine tolerance
    @test length(points(e_coarse)) < length(points(e_fine))

    # If tolerance is too high the discretization will get too scared to update dt from 1%
    # It's OK if an improvement to the discretization algorithm renders this test obsolete
    # But currently that's the correct thing to do
    e_too_coarse = to_polygons(e; atol=1.0μm)
    @test length(points(e_too_coarse)) > length(points(e_coarse))

    # Test backward compatibility - Δθ should still work when explicitly provided
    e_10deg = to_polygons(e; Δθ=10°)
    e_5deg = to_polygons(e; Δθ=5°)

    # 10° steps should produce fewer points than 5° steps
    @test length(points(e_10deg)) < length(points(e_5deg))

    # Test that both atol and Δθ can be provided (Δθ should take precedence for backward compatibility)
    e_mixed = to_polygons(e; atol=1.0nm, Δθ=10°)
    @test length(points(e_mixed)) == length(points(e_10deg))

    # Test with circles (special case of ellipse)
    circ = Circle(Point(0.0μm, 0.0μm), 1.0μm)
    circ_default = to_polygons(circ)
    circ_delta = to_polygons(circ; Δθ=5.12°) # default atol gives ~5.12° spacing on this circle
    circ_delta_coarse = to_polygons(circ; Δθ=10°)

    # Delta method also takes away last point if it's closer than Δθ to the end, so n1=n2+1
    @test length(points(circ_default)) == length(points(circ_delta)) + 1
    @test length(points(circ_default)) > length(points(circ_delta_coarse))
    # Discretization should be very similar to circular_arc
    @test length(points(circ_default)) == length(circular_arc(2pi, 1.0μm, 1.0nm)) - 1 # last pt duplicated

    # Make sure error is as small as tolerance says
    e_fine = to_polygons(e; atol=0.1nm)
    poly = to_polygons(difference2d(e_fine, e_default))[1]
    @test is_sliver(poly; atol=1nm) # on average better than 1nm (area/perimeter)

    # Last two points are not too close together
    poly = points(to_polygons(e, atol=60nm))
    @test norm(poly[1] - poly[end]) > norm(poly[end] - poly[end - 1]) / 2

    # circle is deprecated
    @test_logs (:warn, r"deprecated") circle(10.0)
end

@testitem "circular_arc equal angles" setup = [CommonTestSetup] begin
    # When θ1 = θ2, circular_arc should return a single point, not nothing.
    θ = convert(Float64, π)
    arc = circular_arc([θ, θ], 1.0μm, 1.0nm)
    @test !isnothing(arc)
    @test length(arc) == 1
end

@testitem "Sweeping" setup = [CommonTestSetup] begin
    poly = Polygon(Point(0.0, 0.0), Point(1, 0), Point(1, 1), Point(2, 1), Point(0, 3))
    p2 = sweep_poly(poly, Point(0, -1))
    @test length(points(to_polygons(p2)[1])) == 6
end

@testitem "Compound shapes" setup = [CommonTestSetup] begin
    hu = hatching_unit(1, 1) # runs without error
    @test Polygons.orientation(radial_cut(10, pi / 4, 5)) == 1
    @test Polygons.orientation(radial_stub(10, pi / 4, 5, 20)) == 1
    @test Polygons.orientation(simple_ell(1, 5)) == 1

    @testset "Checkerboard" begin
        c = Cell{Float64}("main")
        checkerboard!(c, 20.0, 2, false)
        @test length(c.refs) == 2
        flatten!(c)
        @test points(c.elements[1]) ≈
              [p(0.0, 0.0), p(20.0, 0.0), p(20.0, 20.0), p(0.0, 20.0)]
        @test points(c.elements[2]) ≈
              [p(20.0, 20.0), p(40.0, 20.0), p(40.0, 40.0), p(20.0, 40.0)]

        c = Cell("main", nm)
        checkerboard!(c, 20μm, 2, true)
        @test length(c.refs) == 2
        flatten!(c)
        @test points(c.elements[1]) ≈ [
            p(0.0nm, 20000.0nm),
            p(20000.0nm, 20000.0nm),
            p(20000.0nm, 40000.0nm),
            p(0.0nm, 40000.0nm)
        ]
        @test points(c.elements[2]) ≈ [
            p(20000.0nm, 0.0nm),
            p(40000.0nm, 0.0nm),
            p(40000.0nm, 20000.0nm),
            p(20000.0nm, 20000.0nm)
        ]
    end

    @testset "Grating" begin
        c = Cell("main", nm)
        grating!(c, 100nm, 100nm, 20μm)
        flatten!(c)
        @test length(c.elements) == 100
        @test points(c.elements[1]) ≈ [
            p(0.0nm, 0.0nm),
            p(100.0nm, 0.0nm),
            p(100.0nm, 20000.0nm),
            p(0.0nm, 20000.0nm)
        ]
    end

    @testset "IDC" begin
        c = Cell("main", nm)
        interdigit!(c, 1μm, 10μm, 1μm, 1μm, 2, true)
        flatten!(c)
        @test length(c.elements) == 3
        @test points(c.elements[1]) ≈ [
            p(0.0nm, 0.0nm),
            p(10000.0nm, 0.0nm),
            p(10000.0nm, 1000.0nm),
            p(0.0nm, 1000.0nm)
        ]
        @test points(c.elements[2]) ≈ [
            p(0.0nm, 4000.0nm),
            p(10000.0nm, 4000.0nm),
            p(10000.0nm, 5000.0nm),
            p(0.0nm, 5000.0nm)
        ]
        @test points(c.elements[3]) ≈ [
            p(1000.0nm, 2000.0nm),
            p(11000.0nm, 2000.0nm),
            p(11000.0nm, 3000.0nm),
            p(1000.0nm, 3000.0nm)
        ]
    end

    @testset "PolyText" begin
        using Random, LinearAlgebra
        rng = MersenneTwister(1337)
        # bounding box tests for tall font with random pixel size and spacing (no units)
        c = Cell{Float64}("main")
        (r1, r2) = (rand(rng), rand(rng))
        pixelsize = r1 * convert(Float64, π)
        pixelspacing = max(pixelsize, r2 * convert(Float64, exp(1)))
        sty = DotMatrix(; pixelsize, pixelspacing)

        polytext!(c, "█", sty)
        @test height(bounds(c)) ≈ pixelsize + pixelspacing * 9
        @test width(bounds(c)) ≈ pixelsize + pixelspacing * 4
        @test length(c.elements) == 0
        @test length(c.refs) == 1
        flatten!(c)
        @test length(c.elements) == (pixelsize >= pixelspacing ? 1 : 50)
        @test length(c.refs) == 0

        # bounding box tests for scripted fonts and random pixel size + spacing
        c = Cell("main", nm)
        (r1, r2) = (rand(rng), rand(rng))
        pixelsize = r1 * convert(Float64, π)μm
        pixelspacing = max(pixelsize, r2 * convert(Float64, exp(1))μm)
        sty = DotMatrix(; pixelsize, pixelspacing)

        polytext!(c, "█_█", sty; scripting=true)
        @test height(bounds(c)) ≈ pixelsize + pixelspacing * 9 + 11 * pixelspacing * 0.3
        @test width(bounds(c)) ≈ pixelsize + pixelspacing * 10
        @test length(c.elements) == 0
        @test length(c.refs) == 2
        flatten!(c)
        @test length(c.elements) == (pixelsize >= pixelspacing ? 2 : 100)
        @test length(c.refs) == 0

        c = Cell("main", nm)
        (r1, r2) = (rand(rng), rand(rng))
        pixelsize = r1 * convert(Float64, π)μm
        pixelspacing = max(pixelsize, r2 * convert(Float64, exp(1))μm)
        sty = DotMatrix(; pixelsize, pixelspacing)

        polytext!(c, "█^{██}", sty; scripting=true)
        @test height(bounds(c)) ≈ pixelsize + pixelspacing * 9 + 11 * pixelspacing * 0.3
        @test width(bounds(c)) ≈ pixelsize + pixelspacing * 16
        @test length(c.elements) == 0
        @test length(c.refs) == 3
        flatten!(c)
        @test length(c.elements) == (pixelsize >= pixelspacing ? 3 : 150)
        @test length(c.refs) == 0

        # bounding box tests for short font with random pixel size and spacing
        c = Cell("main", nm)
        (r1, r2) = (rand(rng), rand(rng))
        pixelsize = r1 * convert(Float64, π)μm
        pixelspacing = max(pixelsize, r2 * convert(Float64, exp(1))μm)
        sty = DotMatrix(; pixelsize, pixelspacing)

        polytext!(c, "a", sty)
        @test height(bounds(c)) ≈ pixelsize + pixelspacing * 4
        @test width(bounds(c)) ≈ pixelsize + pixelspacing * 4
        flatten!(c)
        @test length(c.elements) == (pixelsize >= pixelspacing ? 1 : 17)

        # bounding box tests with linelimit with random pixel size and spacing
        c = Cell("main", nm)
        (r1, r2) = (rand(rng), rand(rng))
        pixelsize = r1 * convert(Float64, π)μm
        pixelspacing = max(pixelsize, r2 * convert(Float64, exp(1))μm)
        linelimit = rand(rng, 25:35) # random line limit
        a_string = string('a')^rand(rng, (linelimit + 1):(linelimit * 10)) # random string length
        sty = DotMatrix(; pixelsize, pixelspacing)

        polytext!(c, a_string, sty; linelimit)
        @test height(bounds(c)) ≈
              pixelsize +
              pixelspacing * 4 +
              (ceil(length(a_string) / linelimit) - 1) * pixelspacing * 11
        @test width(bounds(c)) ≈
              pixelsize + linelimit * (pixelspacing * 5) + (linelimit - 2) * pixelspacing
        path = joinpath(tdir, "characters.gds")
        @test characters_demo(path) == 60138 # bytes written
        rm(path; force=true)
        path = joinpath(tdir, "referenced_characters.gds")
        @test referenced_characters_demo(path, verbose_override=true) == 2460
        rm(path; force=true)
        path = joinpath(tdir, "scripted.gds")
        @test scripted_demo(path) == 8682
        rm(path; force=true)

        # testing other polytext, polytext! methods. Just looking for failure
        bigpixel1 = CoordinateSystem(uniquename("pixel"), nm)
        bigpixel2 = CoordinateSystem(uniquename("pixel"), nm)

        render!(bigpixel1, Polygons.Rounded(6µm)(Rectangle(26µm, 26µm)), GDSMeta(1, 2))
        render!(bigpixel2, Polygons.Rounded(6µm)(Rectangle(26µm, 26µm)), GDSMeta(1, 2))

        dict = Dict('█' => bigpixel1, '■' => bigpixel2)
        sty1 = DotMatrix(dict, 26μm, 28μm, 6μm, GDSMeta(1, 2))

        c = Cell(bigpixel1, nm)
        newmap = Dict{Char, typeof(c)}()
        for (k, v) in dict
            newmap[k] = typeof(c)(v)
        end
        sty2 = DotMatrix(newmap, 26μm, 28μm, 6μm, GDSMeta(1, 2))

        @test polytext("a", sty1) isa CoordinateSystem
        @test polytext("a", sty2) isa Cell
        @test polytext!(Cell("test", nm), "a", sty1) isa Cell
        @test polytext!(CoordinateSystem("test", nm), "a", sty1) isa CoordinateSystem
        @test polytext!(CoordinateSystem("test", nm), "a", sty2) isa CoordinateSystem

        # just test that contiguous rounding method works
        cs = CoordinateSystem("abc", nm)
        polytext!(cs, "AaBbCcDdEe", DotMatrix(; pixelsize=20μm, rounding=6μm))

        # test that other fonts works
        cs = polytext("AaBbCcDdEe", PolyTextSansMono(20.0μm, GDSMeta(0)))
        flatten(Cell(cs, nm))

        # test that no errors thrown with integer arg
        polytext("AaBbCcDdEe", PolyTextSansMono(20μm, GDSMeta(0)))

        # issue #42, make sure it works with both Cell and CoordinateSystem
        let fmark = Cell("fmark_1", nm)
            polytext!(
                fmark,
                "F",
                DotMatrix(rounding=0.002mm, pixelsize=40μm, meta=GDSMeta(0, 0))
            )
        end
        let fmark = CoordinateSystem("fmark_1", nm)
            polytext!(
                fmark,
                "F",
                DotMatrix(rounding=0.002mm, pixelsize=40μm, meta=GDSMeta(0, 0))
            )
        end
    end
end
