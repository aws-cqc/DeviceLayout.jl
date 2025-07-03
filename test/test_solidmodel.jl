import DeviceLayout.SolidModels.STP_UNIT

@testset "SolidModels" begin
    pa = Path(0nm, 0nm)
    turn!(pa, -90°, 50μm, Paths.SimpleTrace(10μm))
    seg = pa[1].seg
    off_seg = Paths.offset(seg, 5μm)
    @test Paths.arclength(off_seg) ≈ Paths.arclength(seg) + (pi / 2) * 5μm
    @test iszero(Paths.offset(off_seg, -5μm).offset)
    turn!(pa, 90°, 50μm)
    simplify!(pa)
    comp_seg = pa[1].seg
    comp_off_seg = Paths.offset(comp_seg, 5μm)
    bspline!(pa, [Point(3mm, 3mm)], -90°, Paths.TaperTrace(10μm, 30μm))
    b_gen_off_seg = Paths.offset(pa[end].seg, t -> Paths.extent(pa[end].sty, t))

    @testset "BSpline approximations" begin
        # Approximate circular arc
        b = Paths.bspline_approximation(seg)
        @test pathlength(b) ≈ pathlength(seg) atol = 1nm
        ts = (0:0.01:1) * pathlength(b)
        ps = b.(ts)
        err = abs.(Paths.norm.(ps .- Point(0μm, -50μm)) .- 50μm)
        @test maximum(err) < 1nm

        # Approximate compound right+left turns
        b2 = Paths.bspline_approximation(comp_seg)
        @test pathlength(b2) ≈ pathlength(comp_seg) atol = 1nm

        # Approximate offset curves
        b3 = Paths.bspline_approximation(off_seg)
        @test pathlength(b3) ≈ (5μm * pi / 2 + pathlength(seg)) atol = 1nm
        @test sum(Paths.arclength.(Paths.offset.(b.segments, 5μm))) ≈ pathlength(b3) atol =
            1nm
        b4 = Paths.bspline_approximation(comp_off_seg)
        @test pathlength(b4) ≈ pathlength(comp_seg) atol = 1nm
        @test b4(pathlength(b3)) ≈ Point(55μm, -50μm) atol = 0.01nm

        # Reverse offset should get the original curve
        b5 = Paths.bspline_approximation.(Paths.offset.(b4.segments, -5μm))
        for b in b5
            @test all(Paths._approximation_error.(comp_seg.segments, b.segments) .< 1nm)
        end

        # General offset of bspline
        b6 = Paths.bspline_approximation(b_gen_off_seg)
        @test pathlength(b6) ≈ Paths.arclength(b_gen_off_seg) atol = 1nm
    end

    # Integration test
    # Render CS with CPW path and attached rectangle on different layers
    # Map layers to different z values
    # Extrude layers by +/- 10μm
    # Create Boolean union of 2 layers resulting in single volume
    # (Because extruded rectangle connects the two CPW gap extrusions)
    cs = CoordinateSystem("test", nm)
    cs2 = CoordinateSystem("attachment", nm)
    place!(cs2, centered(Rectangle(20μm, 12μm)), :l1)
    pa = Path(-0.5mm, 0nm)
    straight!(pa, 500μm, Paths.SimpleCPW(10μm, 6μm))
    turn!(pa, 180°, 50μm)
    straight!(pa, 500μm)
    attach!(pa, sref(cs2), 20μm)
    turn!(pa, -180°, 50μm)
    straight!(pa, 500μm, Paths.TaperCPW(10μm, 6μm, 2μm, 1μm))
    place!(cs, pa, SemanticMeta(:l2))

    uni1tag = 1000
    postrender_ops = [
        ("ext1", SolidModels.extrude_z!, (:l1, 5μm)),
        (
            "l2",
            SolidModels.union_geom!,
            ("l2", "l2"),
            :remove_tool => true,
            :remove_object => true
        ),
        ("ext2", SolidModels.extrude_z!, (:l2, 50μm)),
        (
            "uni1",
            SolidModels.union_geom!,
            ("ext1", "ext2", 3, 3),
            :tag => uni1tag # Set tag explicitly — works as long as union is one entity,
        )
    ]
    zmap = (m) -> (layer(m) == :l1 ? 5μm : 0μm)

    sm = SolidModel("test"; overwrite=true)
    render!(sm, cs, zmap=zmap, postrender_ops=postrender_ops)
    @test length(SolidModels.entitytags(sm["uni1", 3])) == 5 # Boolean fragments of volume
    @test all(
        isapprox.(
            SolidModels.bounds3d(sm["ext1", 3]),
            ustrip.(STP_UNIT, (-30μm, 94μm, 5μm, -10μm, 106μm, 10μm)),
            atol=1e-6
        )
    )
    # Below will not work without native curves because discretization doesn't have far right point
    @test all(
        isapprox.(
            SolidModels.bounds3d(sm["uni1", 3]),
            ustrip.(STP_UNIT, (-561μm, -11μm, 0μm, 61μm, 211μm, 50μm)),
            atol=1e-6 # If discretized, the right boundary is < 61 (atol ~1e-4)
        )
    )
    # Reduce the noise in the REPL
    SolidModels.gmsh.option.setNumber("General.Verbosity", 0)
    @test_nowarn SolidModels.gmsh.model.mesh.generate(3) # Should run without error

    # Try native kernel
    smg = SolidModel("test", SolidModels.GmshNative(); overwrite=true)
    render!(smg, cs, zmap=zmap, postrender_ops=postrender_ops[[1, 3]]) # skip union operations
    @test all(
        isapprox.(
            SolidModels.bounds3d(smg["ext1", 3]),
            ustrip.(STP_UNIT, (-30μm, 94μm, 5μm, -10μm, 106μm, 10μm)),
            atol=1e-6
        )
    )

    # Try BSpline approximations
    cs = CoordinateSystem("test", nm)
    pa = Path(-0.5mm, 0nm)
    straight!(pa, 500μm, Paths.SimpleCPW(10μm, 6μm))
    turn!(pa, 180°, 50μm, Paths.TaperCPW(10μm, 6μm, 2μm, 1μm))
    bspline!(
        pa,
        [Point(-0.5mm, 0.2mm), Point(-0.5mm, 0.0mm)],
        0,
        Paths.TaperCPW(2μm, 1μm, 10μm, 6μm)
    )
    place!(cs, pa, SemanticMeta(:l1))
    sm = SolidModel("test"; overwrite=true)
    zmap = (m) -> (layer(m) == :l1 ? 25μm : 0μm)
    render!(sm, cs, zmap=zmap)
    x0, y0, z0, x1, y1, z1 = SolidModels.bounds3d(sm["l1", 2])
    # Compare 3D model bounds with discretized version from cs
    x0d, y0d = bounds(cs).ll.x, bounds(cs).ll.y
    x1d, y1d = bounds(cs).ur.x, bounds(cs).ur.y
    # Why only accurate to within 1um? Shouldn't it be ~1nm?
    # bbox is approximate (and not tight even when exact geometry makes it easy)
    # but it may be that the approximation isn't so good near sharper turns
    @test all(
        isapprox.([x0, y0, x1, y1], ustrip.(STP_UNIT, [x0d, y0d, x1d, y1d]), atol=1.0)
    )
    n_bnd = length(SolidModels.get_boundary(sm["l1", 2]))
    # Try BSpline approximation with fewer points
    sm = SolidModel("test"; overwrite=true)
    render!(sm, cs, zmap=zmap, atol=100.0nm)
    @test length(SolidModels.get_boundary(sm["l1", 2])) < n_bnd

    # Try rounded polygon
    cs = CoordinateSystem("test", nm)
    rc = Polygons.Rounded(0.5μm)(simple_cross(2μm, 7μm))
    sm = SolidModel("test"; overwrite=true)
    place!(cs, rc, :test)
    render!(sm, cs)
    curves = SolidModels.to_primitives(sm, rc).exterior.curves
    @test all(getproperty.(curves, :α)[1:3:end] .== -90°)
    @test all(getproperty.(curves, :α)[2:3:end] .== 90°)

    cs = CoordinateSystem("test", nm)
    sc = simple_cross(2μm, 7μm)
    pcorner = points(sc)
    xmin = minimum(getindex.(pcorner, 1))
    xmax = maximum(getindex.(pcorner, 1))
    ymin = minimum(getindex.(pcorner, 2))
    ymax = maximum(getindex.(pcorner, 2))
    # Find the coordinates of all points which have at least one coordinate at one of these limits
    pp = filter(c -> c[1] ≈ xmin || c[1] ≈ xmax || c[2] ≈ ymin || c[2] ≈ ymax, pcorner)
    rs = RelativeRounded(0.25; inverse_selection=true, p0=pp)
    rsc = rs(union2d([sc]))
    prim = SolidModels.to_primitives(sm, rsc)

    sty_points = points(prim[1])
    @test all(x ∈ sty_points for x ∈ pp) # Excluded points should be there
    @test all(x ∉ sty_points for x ∈ setdiff(points(sc), pp)) # All non-excluded shouldn't be

    sm = SolidModel("test"; overwrite=true)
    place!(cs, rsc, :test)
    @test_nowarn render!(sm, cs)

    # Other Path primitives (trace and CPWOpenTermination)
    cs = CoordinateSystem("test", nm)
    pa = Path(0nm, 0nm)
    straight!(pa, 100μm, Paths.SimpleTrace(10.0μm))
    straight!(pa, 100μm, Paths.TaperTrace(10μm, 5μm))
    straight!(pa, 10μm, Paths.SimpleCPW(5μm, 2μm))
    terminate!(pa; rounding=2.5μm)

    place!(cs, pa, SemanticMeta(:test))
    sm = SolidModel("test"; overwrite=true)
    render!(sm, cs)
    x0, y0, z0, x1, y1, z1 = SolidModels.bounds3d(sm["test", 2])
    # Compare 3D model bounds with cs bounds
    x0d, y0d = bounds(cs).ll.x, bounds(cs).ll.y
    x1d, y1d = bounds(cs).ur.x, bounds(cs).ur.y
    @test all(
        isapprox.([x0, y0, x1, y1], ustrip.(STP_UNIT, [x0d, y0d, x1d, y1d]), atol=1e-6)
    )

    # Termination on curve is still drawn with circular arcs
    cs = CoordinateSystem("test", nm)
    pa = Path(0nm, 0nm)
    turn!(pa, 90°, 10μm, Paths.SimpleCPW(5μm, 2μm))
    terminate!(pa; rounding=2.5μm)
    place!(cs, pa, SemanticMeta(:test))
    sm = SolidModel("test"; overwrite=true)
    render!(sm, cs)
    @test length(SolidModels.gmsh.model.occ.getEntities(0)) < 20 # would be >100 points if discretized

    # Compound segment/style
    cs = CoordinateSystem("test", nm)
    pa = Path(0nm, 0nm)
    straight!(pa, 100μm, Paths.SimpleTrace(10.0μm))
    straight!(pa, 100μm, Paths.TaperTrace(10μm, 5μm))
    straight!(pa, 10μm, Paths.SimpleCPW(5μm, 2μm))
    simplify!(pa)

    place!(cs, pa, SemanticMeta(:test))
    sm = SolidModel("test"; overwrite=true)
    render!(sm, cs)
    x0, y0, z0, x1, y1, z1 = SolidModels.bounds3d(sm["test", 2])
    # Compare 3D model bounds with cs bounds
    x0d, y0d = bounds(cs).ll.x, bounds(cs).ll.y
    x1d, y1d = bounds(cs).ur.x, bounds(cs).ur.y
    @test all(
        isapprox.([x0, y0, x1, y1], ustrip.(STP_UNIT, [x0d, y0d, x1d, y1d]), atol=1e-6)
    )
    sm["test_bdy"] = SolidModels.get_boundary(sm["test", 2])
    sm["test_bdy_xmin"] =
        SolidModels.get_boundary(sm["test", 2]; direction="X", position="min")
    sm["test_bdy_xmax"] =
        SolidModels.get_boundary(sm["test", 2]; direction="X", position="max")
    sm["test_bdy_ymin"] =
        SolidModels.get_boundary(sm["test", 2]; direction="Y", position="min")
    sm["test_bdy_ymax"] =
        SolidModels.get_boundary(sm["test", 2]; direction="Y", position="max")
    sm["test_bdy_zmin"] =
        SolidModels.get_boundary(sm["test", 2]; direction="Z", position="min")
    sm["test_bdy_zmax"] =
        SolidModels.get_boundary(sm["test", 2]; direction="Z", position="max")

    @test isempty(
        @test_logs (
            :info,
            "get_boundary(sm, test, 3): (test, 3) is not a physical group, thus has no boundary."
        ) SolidModels.get_boundary(sm, "test", 3)
    )
    @test isempty(
        @test_logs (
            :info,
            "get_boundary(sm, Physical Group test of dimension 2 with 4 entities): direction a is not all, X, Y, or Z, thus has no boundary."
        ) SolidModels.get_boundary(sm["test", 2]; direction="a", position="min")
    )
    @test isempty(
        @test_logs (
            :info,
            "get_boundary(sm, Physical Group test of dimension 2 with 4 entities): position no is not all, min, or max, thus has no boundary."
        ) SolidModels.get_boundary(sm["test", 2]; direction="X", position="no")
    )

    SolidModels.remove_group!(sm, "test", 2; recursive=false)
    @test !SolidModels.hasgroup(sm, "test", 2)
    @test !isempty(SolidModels.dimtags(sm["test_bdy", 1]))
    @test !isempty(SolidModels.dimtags(sm["test_bdy_xmin", 1]))
    @test !isempty(SolidModels.dimtags(sm["test_bdy_xmax", 1]))
    @test !isempty(SolidModels.dimtags(sm["test_bdy_ymin", 1]))
    @test !isempty(SolidModels.dimtags(sm["test_bdy_ymax", 1]))
    @test !isempty(SolidModels.dimtags(sm["test_bdy_zmin", 1]))
    @test !isempty(SolidModels.dimtags(sm["test_bdy_zmax", 1]))

    @test SolidModels.dimtags(get(sm, "foo", 2, sm["test_bdy", 1])) ==
          SolidModels.dimtags(sm["test_bdy", 1])
    @test isempty(
        @test_logs (
            :info,
            "remove_group!(sm, foo, 3; recursive=true, remove_entities=false): (foo, 3) is not a physical group."
        ) SolidModels.remove_group!(sm, "foo", 3)
    )
    @test isempty(
        @test_logs (
            :error,
            "union_geom!(sm, foo, bar, 2, 2): (foo, 2) and (bar, 2) are not physical groups."
        ) SolidModels.union_geom!(sm, "foo", "bar")
    )
    @test isempty(
        @test_logs (
            :error,
            "intersect_geom!(sm, foo, bar, 2, 2): (foo, 2) is not a physical group."
        ) SolidModels.intersect_geom!(sm, "foo", "bar")
    )
    @test isempty(
        @test_logs (
            :error,
            "difference_geom!(sm, foo, bar, 2, 2): (foo, 2) is not a physical group."
        ) SolidModels.difference_geom!(sm, "foo", "bar")
    )
    @test isempty(
        @test_logs (
            :error,
            "fragment_geom!(sm, foo, bar, 2, 2): (foo, 2) and (bar, 2) are not physical groups."
        ) SolidModels.fragment_geom!(sm, "foo", "bar")
    )
    @test isempty(
        @test_logs (
            :info,
            "extrude_z!(sm, foo, 3 μm, 2): (foo, 2) is not a physical group."
        ) SolidModels.extrude_z!(sm, "foo", 3μm)
    )
    @test isempty(
        @test_logs (
            :error,
            "translate!(sm, foo, 3 μm, 2 μm, 1 μm, 2; copy=true): (foo, 2) is not a physical group."
        ) SolidModels.translate!(sm, "foo", 3μm, 2μm, 1μm)
    )
    @test isempty(
        @test_logs (
            :error,
            "revolve!(sm, foo, 2, (3 μm, 2 μm, 1 μm, 3 μm, 2 μm, 1 μm, 5.0)): (foo, 2) is not a physical group."
        ) SolidModels.revolve!(sm, "foo", 2, 3μm, 2μm, 1μm, 3μm, 2μm, 1μm, 5.0)
    )

    @test !isempty(
        @test_logs (
            :info,
            "union_geom!(sm, test_bdy, bar, 1, 2): (bar, 2) is not a physical group, using only (test_bdy, 1)."
        ) SolidModels.union_geom!(sm, "test_bdy", "bar", 1, 2, remove_tool=true)
    )
    @test SolidModels.hasgroup(sm, "test_bdy", 1)
    @test (@test_logs (
        :info,
        "fragment_geom!(sm, test_bdy, bar, 1, 2): (bar, 2) is not a physical group, using only (test_bdy, 1)."
    ) SolidModels.fragment_geom!(sm, "test_bdy", "bar", 1, 2, remove_tool=true)) ==
          SolidModels.fragment_geom!(sm, "test_bdy", "test_bdy", 1, 1)
    @test SolidModels.hasgroup(sm, "test_bdy", 1)
    @test (@test_logs (
        :info,
        "difference_geom!(sm, test_bdy, bar, 1, 2): (bar, 2) is not a physical group, using only (test_bdy, 1)."
    ) SolidModels.difference_geom!(sm, "test_bdy", "bar", 1, 2, remove_tool=true)) ==
          SolidModels.dimtags(sm["test_bdy", 1])
    @test SolidModels.hasgroup(sm, "test_bdy", 1)

    @test !isempty(
        @test_logs (
            :info,
            "union_geom!(sm, bar, test_bdy, 2, 1): (bar, 2) is not a physical group, using only (test_bdy, 1)."
        ) SolidModels.union_geom!(sm, "bar", "test_bdy", 2, 1, remove_object=true)
    )
    @test SolidModels.hasgroup(sm, "test_bdy", 1)

    @test (@test_logs (
        :info,
        "fragment_geom!(sm, bar, test_bdy, 2, 1): (bar, 2) is not a physical group, using only (test_bdy, 1)."
    ) SolidModels.fragment_geom!(sm, "bar", "test_bdy", 2, 1, remove_object=true)) ==
          SolidModels.fragment_geom!(sm, "test_bdy", "test_bdy", 1, 1)
    @test SolidModels.hasgroup(sm, "test_bdy", 1)

    # Simple keyhole polygon - one square from another
    r1 = difference2d(centered(Rectangle(4μm, 4μm)), centered(Rectangle(3μm, 3μm)))
    r2 = difference2d(centered(Rectangle(2μm, 2μm)), centered(Rectangle(1μm, 1μm)))
    u = difference2d(r1, r2)
    cs = CoordinateSystem("test", nm)
    place!(cs, u, SemanticMeta(:test))
    sm = SolidModel("test"; overwrite=true)
    @test_nowarn render!(sm, cs)

    # Compound keyhole polygons - lattice of squares
    r1 = centered(Rectangle(12μm, 12μm))
    r2 = centered(Rectangle(4μm, 4μm))
    r3 = centered(Rectangle(2μm, 2μm))
    r4 = centered(Rectangle(1μm, 1μm))
    δ = 3μm

    cc = [r2 + Point(+δ, +δ); r2 + Point(-δ, +δ); r2 + Point(+δ, -δ); r2 + Point(-δ, -δ)]
    u = difference2d(r1, cc)

    ss = difference2d(r3, r4)
    cc2 = [ss + Point(+δ, +δ); ss + Point(-δ, +δ); ss + Point(+δ, -δ); ss + Point(-δ, -δ)]
    u = union2d(u, cc2)
    cs = CoordinateSystem("test", nm)

    place!(cs, u, SemanticMeta(:test))
    sm = SolidModel("test"; overwrite=true)
    @test_nowarn render!(sm, cs)
    @test SolidModels.hasgroup(sm, "test", 2)

    @test length(SolidModels.gmsh.model.get_entities(0)) == 12 * 4 + 4
    @test length(SolidModels.gmsh.model.get_entities(1)) == 12 * 4 + 4
    @test length(SolidModels.gmsh.model.get_entities(2)) == 5
    @test length(SolidModels.gmsh.model.get_entities(3)) == 0

    cs = CoordinateSystem("test", nm)

    prim = SolidModels.to_primitives(sm, u)
    @test length(SolidModels.to_primitives(sm, u)) == 5
    @test length(SolidModels.to_primitives(sm, Polygons.Rounded(0.25μm)(u))) == 5

    place!(cs, Polygons.Rounded(0.25μm)(u), SemanticMeta(:test))
    sm = SolidModel("test"; overwrite=true)
    @test_nowarn render!(sm, cs)
    @test SolidModels.hasgroup(sm, "test", 2)

    # Each corner has start, end and center.
    @test length(SolidModels.gmsh.model.get_entities(0)) == (12 * 4 + 4) * 3
    # Each corner gets added as another edge.
    @test length(SolidModels.gmsh.model.get_entities(1)) == (12 * 4 + 4) * 2
    @test length(SolidModels.gmsh.model.get_entities(2)) == 5
    @test length(SolidModels.gmsh.model.get_entities(3)) == 0

    cs = CoordinateSystem("test", nm)
    place!(cs, Polygons.Rounded(0.25μm, p0=points(r1)[[1, 3]])(u), SemanticMeta(:test))
    sm = SolidModel("test"; overwrite=true)
    @test_nowarn render!(sm, cs)
    @test SolidModels.hasgroup(sm, "test", 2)

    # Half of all corners are rounded.
    @test length(SolidModels.gmsh.model.get_entities(0)) == 2 * (12 * 4 + 4)
    # Each rounded corner adds an edge.
    @test length(SolidModels.gmsh.model.get_entities(1)) == 3 * (12 * 4 + 4) / 2
    @test length(SolidModels.gmsh.model.get_entities(2)) == 5
    @test length(SolidModels.gmsh.model.get_entities(3)) == 0

    ## Duplicated points
    rr1 = Polygons.Rounded(6μm)(r1) # half side length -> duplicates side midpoint
    rr2 = Polygons.Rounded(0μm)(r2) # zero rounding radius -> duplicates corners
    # Same shapes but in a clipped polygon
    r_cl = difference2d(r1, r2)
    d = StyleDict()
    d[r_cl[1, 1]] = Polygons.Rounded(6μm)
    d[r_cl[1, 1]] = Polygons.Rounded(0μm)
    rr_cl = styled(r_cl, d)
    # Polygon with explicit duplicate points at start and end
    p_dup = Polygon(
        Point(0μm, 0μm),
        Point(1μm, 0μm),
        Point(1μm, 1μm),
        Point(0μm, 1μm),
        Point(0μm, 0μm)
    )
    # Try them all
    cs = CoordinateSystem("test", nm)
    place!(cs, rr1, :test)
    place!(cs, rr2, :test)
    sm = SolidModel("test"; overwrite=true)
    @test_nowarn render!(sm, cs)
    @test_nowarn SolidModels.gmsh.model.mesh.generate(2)

    cs = CoordinateSystem("test", nm)
    place!(cs, rr_cl + Point(20μm, 0μm), :test)
    sm = SolidModel("test"; overwrite=true)
    @test_nowarn render!(sm, cs)
    @test_nowarn SolidModels.gmsh.model.mesh.generate(2)

    cs = CoordinateSystem("test", nm)
    place!(cs, p_dup - Point(20μm, 0μm), :test)
    place!(cs, p_dup - Point(21μm, 0μm), :test) # Add adjoining copy while we're here
    sm = SolidModel("test"; overwrite=true)
    @test_nowarn render!(sm, cs)
    @test_nowarn SolidModels.gmsh.model.mesh.generate(2)
    ##

    # Ellipse
    e = Ellipse(2 .* Point(2.0μm, 1.0μm), (2.0μm, 1.0μm), 45°)
    cs = CoordinateSystem("test", nm)
    place!(cs, e, SemanticMeta(:test))
    sm = SolidModel("test"; overwrite=true)
    render!(sm, cs)

    # CurvilinearPolygon
    # A basic, noncurved polygon
    pp = [Point(0.0μm, 0.0μm), Point(1.0μm, 0.0μm), Point(0.0μm, 1.0μm)]
    cp = CurvilinearPolygon(pp)
    cs = CoordinateSystem("abc", nm)
    place!(cs, cp, SemanticMeta(:test))

    # Add a turn instead of the hypotenuse
    cp = CurvilinearPolygon(pp, [Paths.Turn(90°, 1.0μm, α0=90°, p0=pp[2])], [2])
    place!(cs, cp, SemanticMeta(:test))
    sm = SolidModel("test"; overwrite=true)
    @test_nowarn render!(sm, cs)
    prim1 = SolidModels.to_primitives(sm, cp)
    prim2 = SolidModels.to_primitives(
        sm,
        styled(Rectangle(1.0μm, 1.0μm), Rounded(1.0μm, p0=[Point(1.0μm, 1.0μm)]))
    )
    # Manually check the fields given Turn is mutable.
    function test_turn(x, y, op)
        return op(x.p0, y.p0) && op(x.α0, y.α0) && op(x.α, y.α) && op(x.r, y.r)
    end
    @test test_turn(prim1.exterior.curves[1], prim1.exterior.curves[1], isequal)
    @test length(prim1.exterior.curves) == length(prim2.exterior.curves)
    @test typeof(prim1) == typeof(prim2)

    # Apply a rotation
    t = RotationPi(0.5)
    place!(cs, t(cp), SemanticMeta(:test))
    sm = SolidModel("test"; overwrite=true)
    @test_nowarn render!(sm, cs)

    # Example definition of a Pac-man shape for testing
    function Pacman(ϕ, radius)
        dy = radius * sin(ϕ)
        p = [
            Point(radius * cos(ϕ), -dy),
            Point(zero(radius), zero(radius)),
            Point(radius * cos(ϕ), dy)
        ]
        c = Paths.Turn(2 * (π - ϕ), radius, p0=p[end], α0=ϕ + π / 2)
        return CurvilinearPolygon(p, [c], [3])
    end

    # Render pacman, translated pacman, and a pacman with a rounded mouth
    cs = CoordinateSystem("abc", nm)
    cp = Pacman(π / 6, 1.0μm)
    place!(cs, cp, SemanticMeta(:test))
    cp2 = Translation(Point(5μm * cos(π / 6), 0.0μm))(cp)
    place!(cs, cp2, SemanticMeta(:test))
    sty = RelativeRounded(0.25)
    place!(
        cs,
        Translation(Point(5μm * cos(π / 6), 0.0μm))(styled(cp2, sty)),
        SemanticMeta(:test)
    )
    sm = SolidModel("test"; overwrite=true)
    @test_nowarn render!(sm, cs)

    cps = styled(cp, sty)
    pri = SolidModels.to_primitives(sm, cps)
    @test points(cp)[2] ≈ Point(0.0μm, 0.0μm)
    @test points(pri.exterior)[2] ≉ Point(0.0μm, 0.0μm) # the sharp point is removed

    # Recursively rounded style
    pp =
        [Point(0.0μm, 0.0μm), Point(1.0μm, 0.0μm), Point(1.0μm, 1.0μm), Point(0.0μm, 1.0μm)]
    p = Polygon(pp)
    sty = [
        RelativeRounded(0.05, p0=[pp[1]]),
        RelativeRounded(0.125, p0=[pp[2]]),
        RelativeRounded(0.25, p0=[pp[3]]),
        RelativeRounded(0.5, p0=[pp[4]])
    ]
    psty = styled(styled(styled(styled(p, sty[1]), sty[2]), sty[3]), sty[4])
    pri = SolidModels.to_primitives(sm, psty)

    @test length(pri.exterior.p) == 8 # all corners became 2 points
    @test length(pri.exterior.curves) == 4 # each corner has a curve
    δx = Point(1.0μm, 0.0μm)
    δy = Point(0.0μm, 1.0μm)
    # The rounding length point compounds based on the sequence of application.
    @test pri.exterior.p[1] ≈ pp[1] + sty[1].rel_r * δy
    @test pri.exterior.p[2] ≈ pp[1] + sty[1].rel_r * δx
    @test pri.exterior.p[3] ≈ pp[2] - sty[2].rel_r * (1 - sty[1].rel_r) * δx
    @test pri.exterior.p[4] ≈ pp[2] + sty[2].rel_r * (1 - sty[1].rel_r) * δy
    @test pri.exterior.p[5] ≈
          pp[3] - sty[3].rel_r * (1 - sty[2].rel_r * (1 - sty[1].rel_r)) * δy
    @test pri.exterior.p[6] ≈
          pp[3] - sty[3].rel_r * (1 - sty[2].rel_r * (1 - sty[1].rel_r)) * δx
    @test pri.exterior.p[7] ≈
          pp[4] +
          sty[4].rel_r * (1 - sty[3].rel_r * (1 - sty[2].rel_r * (1 - sty[1].rel_r))) * δx
    @test pri.exterior.p[8] ≈
          pp[4] -
          sty[4].rel_r * (1 - sty[3].rel_r * (1 - sty[2].rel_r * (1 - sty[1].rel_r))) * δy

    # Recursive rounding of a ClippedPolygon -- "lollipop sign"
    r = Rectangle(10.0μm, 10.0μm)
    s = Align.below(Rectangle(2.0μm, 5.0μm), r, centered=true)
    cc = union2d(r, s)
    cs = CoordinateSystem("abc", nm)
    place!(cs, cc, SemanticMeta(:test))
    place!(cs, Rounded(1.0μm)(cc), SemanticMeta(:test))
    sty1 = Rounded(2.0μm, p0=points(r))
    sty2 = Rounded(0.5μm, p0=points(s))
    cs = CoordinateSystem("abc", nm)
    place!(cs, styled(styled(cc, sty1), sty2), SemanticMeta(:test))
    @test_nowarn render!(SolidModel("test"; overwrite=true), cs)

    prim = SolidModels.to_primitives(sm, styled(styled(cc, sty1), sty2))
    @test length(prim) == 1
    prim = prim[1]
    @test length(prim.exterior.p) == 16
    @test length(prim.exterior.curve_start_idx) == 8

    δx = Point(2.0μm, 0.0μm)
    δy = Point(0.0μm, 2.0μm)
    pr = points(r)
    shifted_pr = [
        pr[1] + δy,
        pr[1] + δx,
        pr[2] - δx,
        pr[2] + δy,
        pr[3] - δy,
        pr[3] - δx,
        pr[4] + δx,
        pr[4] - δy
    ]
    for pp in shifted_pr
        @test count(Ref(pp) .≈ prim.exterior.p) == 1 # each shifted point is found once.
    end
    δx = Point(0.5μm, 0.0μm)
    δy = Point(0.0μm, 0.5μm)
    ps = points(s)
    shifted_ps = [
        ps[1] + δy,
        ps[1] + δy,
        ps[2] - δx,
        ps[2] + δy,
        ps[3] - δy,
        ps[3] + δx,
        ps[4] - δx,
        ps[4] - δy
    ]
    for pp in shifted_ps
        @test count(Ref(pp) .≈ prim.exterior.p) == 1 # each shifted point is found once.
    end

    # StyleDict
    c = Translation(Point(2.0μm, 2.0μm))(Rectangle(6.0μm, 6.0μm))
    cc = difference2d(cc, c)
    sty = StyleDict()
    sty[1] = sty2 # small rounding of stick in lollipop
    sty[1, 1] = Rounded(1.5μm)
    cs = CoordinateSystem("test", nm)
    place!(cs, styled(styled(cc, sty), sty1), SemanticMeta(:test))
    sm = SolidModel("test"; overwrite=true)

    prim = SolidModels.to_primitives(sm, styled(styled(cc, sty), sty1))
    @test length(prim) == 1
    prim = prim[1]
    @test length(prim.holes) == 1
    # Repeat test, the exterior should match the nested without a style dict
    for pp in shifted_pr
        @test count(Ref(pp) .≈ prim.exterior.p) == 1 # each shifted point is found once.
    end
    for pp in shifted_ps
        @test count(Ref(pp) .≈ prim.exterior.p) == 1 # each shifted point is found once.
    end

    # The interior hole should have 1.5μm rounding
    δx = Point(1.5μm, 0.0μm)
    δy = Point(0.0μm, 1.5μm)
    pc = points(c)
    shifted_pc = [
        pc[1] + δy,
        pc[1] + δx,
        pc[2] - δx,
        pc[2] + δy,
        pc[3] - δy,
        pc[3] - δx,
        pc[4] + δx,
        pc[4] - δy
    ]
    for pp in shifted_pc
        @test count(Ref(pp) .≈ prim.holes[1].p) == 1 # each shifted point is found once.
    end

    @test_nowarn render!(sm, cs)

    @test_nowarn SolidModels.to_primitives(
        sm,
        styled(styled(styled(cc, sty), sty1), MeshSized(0.25μm))
    )
    cs = CoordinateSystem("test", nm)
    place!(
        cs,
        styled(styled(styled(cc, sty), sty1), MeshSized(0.25μm)),
        SemanticMeta(:test)
    )
    sm = SolidModel("test"; overwrite=true)
    @test_nowarn render!(sm, cs)
    @test SolidModels.meshsize(styled(styled(styled(cc, sty), sty1), MeshSized(0.25μm))) ==
          Unitful.ustrip(STP_UNIT, 0.25μm)

    # Convert a SimpleTrace to a CurvilinearRegion
    pa = Path(Point(0nm, 0nm), α0=0.0)
    straight!(pa, 0μm, Paths.SimpleTrace(10.0μm))
    straight!(pa, 100μm, Paths.SimpleTrace(10.0μm))
    turn!(pa, π, 50μm, Paths.SimpleTrace(10.0μm))
    cr = pathtopolys(pa)
    cs = CoordinateSystem("abc", nm)
    place!(cs, cr[1], SemanticMeta(:test))
    place!(cs, cr[2], SemanticMeta(:test))
    @test length(cr) == 2 # The zero length path is erased
    sm = SolidModel("test"; overwrite=true)
    @test_nowarn render!(sm, cs)

    # A 2π rotation should do nothing
    t = RotationPi(2)
    crt = t.(cr)

    cs = CoordinateSystem("abc", nm)
    place!(cs, crt[1], SemanticMeta(:test))
    @test cr[1] == crt[1]
    @test all(cr[2].p .== crt[2].p)
    @test all(
        test_turn.((x -> x.seg).(cr[2].curves), (x -> x.seg).(crt[2].curves), isequal)
    )
    place!(cs, crt[1], SemanticMeta(:test))
    place!(cs, crt[2], SemanticMeta(:test))
    sm = SolidModel("test"; overwrite=true)
    @test_nowarn render!(sm, cs)

    # Meshsizing
    r = Rectangle(2μm, 3μm)
    rs = meshsized_entity(r, 1μm, 1.1)
    @test SolidModels.meshsize(r) == 0.0
    @test SolidModels.meshsize(rs) == Unitful.ustrip(STP_UNIT, 1μm)
    @test SolidModels.meshgrading(r) == -1.0
    @test SolidModels.meshgrading(rs) == 1.1

    # mesh grading of zero defaults to the default keyword of 1.0
    rs = meshsized_entity(r, 1μm)
    @test SolidModels.meshsize(rs) == Unitful.ustrip(STP_UNIT, 1μm)
    @test SolidModels.meshgrading(r) == -1.0
    @test SolidModels.meshgrading(rs) == -1.0

    # Composition of styles
    rr = Polygons.Rounded(r, 0.5μm)
    rrs = meshsized_entity(rr, 1μm, 1.2)
    @test SolidModels.meshsize(rr) == 0.0
    @test SolidModels.meshsize(rrs) == Unitful.ustrip(STP_UNIT, 1μm)
    @test SolidModels.meshgrading(rr) == -1.0
    @test SolidModels.meshgrading(rrs) == 1.2

    # Sizing will only capture outermost sizing.
    rs = meshsized_entity(r, 1μm, 1.1)
    rsr = Polygons.Rounded(rs, 1μm)
    @test SolidModels.meshsize(rsr) == Unitful.ustrip(STP_UNIT, 1μm)
    @test SolidModels.meshgrading(rsr) == 1.1

    # Optional sizing field.
    sty = OptionalStyle(MeshSized(1μm, 0.8), :refine, false_style=MeshSized(0.5μm, 0.6))
    rs = styled(r, sty)
    @test SolidModels.meshsize(rs, refine=true) == Unitful.ustrip(STP_UNIT, 1μm)
    @test SolidModels.meshgrading(rs, refine=true) == 0.8
    @test SolidModels.meshsize(rs, refine=false) == Unitful.ustrip(STP_UNIT, 0.5μm)
    @test SolidModels.meshgrading(rs, refine=false) == 0.6

    # Optional sizing field of already styled component.
    rr = Polygons.Rounded(rs, 1μm)
    rrs = styled(rr, sty)
    @test SolidModels.meshsize(rrs, refine=true) == Unitful.ustrip(STP_UNIT, 1μm)
    @test SolidModels.meshgrading(rrs, refine=true) == 0.8
    @test SolidModels.meshsize(rrs, refine=false) == Unitful.ustrip(STP_UNIT, 0.5μm)
    @test SolidModels.meshgrading(rrs, refine=false) == 0.6

    # Composite optional style - no sizing if rounded, else refined or non-refined.
    rr = OptionalStyle(Polygons.Rounded(0.5μm), :round, false_style=sty)(r)
    @test SolidModels.meshsize(rr, refine=true, round=false) ==
          Unitful.ustrip(STP_UNIT, 1μm)
    @test SolidModels.meshgrading(rr, refine=true, round=false) == 0.8
    @test SolidModels.meshsize(rr, refine=false, round=false) ==
          Unitful.ustrip(STP_UNIT, 0.5μm)
    @test SolidModels.meshgrading(rr, refine=false, round=false) == 0.6
    @test SolidModels.meshsize(rr, refine=true, round=true) == 0.0
    @test SolidModels.meshgrading(rr, refine=true, round=true) == -1.0
    @test SolidModels.meshsize(rr, refine=false, round=true) == 0.0
    @test SolidModels.meshgrading(rr, refine=false, round=true) == -1.0

    # Styled ClippedPolygon
    d = difference2d(centered(Rectangle(4μm, 4μm)), centered(Rectangle(3μm, 3μm)))
    ds = OptionalStyle(Polygons.Rounded(0.5μm), :round, false_style=sty, default=false)(d)
    @test SolidModels.meshsize(ds, refine=true, round=false) ==
          Unitful.ustrip(STP_UNIT, 1μm)
    @test SolidModels.meshgrading(ds, refine=true, round=false) == 0.8
    @test SolidModels.meshsize(ds, refine=false, round=false) ==
          Unitful.ustrip(STP_UNIT, 0.5μm)
    @test SolidModels.meshgrading(ds, refine=false, round=false) == 0.6
    @test SolidModels.meshsize(ds, refine=true, round=true) == 0.0
    @test SolidModels.meshgrading(ds, refine=true, round=true) == -1.0
    @test SolidModels.meshsize(ds, refine=false, round=true) == 0.0
    @test SolidModels.meshgrading(ds, refine=false, round=true) == -1.0

    # Styled Ellipse
    e = Ellipse(2 .* Point(2.0μm, 1.0μm), (2.0μm, 1.0μm), 45°)
    sty = OptionalStyle(MeshSized(0.5μm, 0.8), :refine, false_style=MeshSized(1.0μm, 0.6))
    es = styled(e, sty)
    @test SolidModels.to_primitives(sm, es) == es.ent
    @test SolidModels.meshsize(es, refine=true) == Unitful.ustrip(STP_UNIT, 0.5μm)
    @test SolidModels.meshgrading(es, refine=true) == 0.8
    @test SolidModels.meshsize(es, refine=false) == Unitful.ustrip(STP_UNIT, 1.0μm)
    @test SolidModels.meshgrading(es, refine=false) == 0.6

    @test isempty(SolidModels.to_primitives(sm, styled(e, DeviceLayout.NoRender())))
    sty = OptionalStyle(
        DeviceLayout.NoRender(),
        :simulation,
        false_style=DeviceLayout.Plain()
    )
    @test isempty(SolidModels.to_primitives(sm, styled(e, sty); simulation=true))
    @test SolidModels.to_primitives(sm, styled(e, sty); simulation=false) == e

    # Apply a Rounding style specified by target points
    sty = Polygons.Rounded(1.0μm, p0=[Point(1.0μm, 1.0μm), Point(-1.0μm, -1.0μm)])
    r = centered(Rectangle(2.0μm, 2.0μm))
    rs = styled(r, sty)
    cs = CoordinateSystem("test", nm)
    sm = SolidModel("test"; overwrite=true)
    @test_nowarn place!(cs, rs, SemanticMeta(:test))
    @test_nowarn render!(sm, cs)

    # Reference transform should transform p0 too
    r = to_polygons(Rectangle(2μm, 1μm))
    cs_local = CoordinateSystem("test", nm)
    sty = Rounded(0.25μm, p0=points(r))
    place!(cs_local, styled(r, sty), SemanticMeta(:test))
    cs = CoordinateSystem("outer", nm)
    addref!(cs, sref(cs_local, angle=π / 2))
    sm = SolidModel("test"; overwrite=true)
    @test_nowarn render!(sm, cs)

    # Reference transform should transform p0 too
    r = to_polygons(Rectangle(2μm, 1μm))
    cs_local = CoordinateSystem("test", nm)
    sty = RelativeRounded(0.25, p0=points(r)[[1, 2]])
    place!(cs_local, styled(r, sty), SemanticMeta(:test))
    cs = CoordinateSystem("outer", nm)
    addref!(cs, sref(cs_local, angle=π / 2))
    sm = SolidModel("test"; overwrite=true)
    @test_nowarn render!(sm, cs)

    # Path sizing
    pa = Path(0nm, 0nm)
    straight!(pa, 100μm, Paths.SimpleTrace(10μm))
    @test SolidModels.meshsize(pa.nodes[1]) == Unitful.ustrip(STP_UNIT, 20μm)
    @test SolidModels.meshgrading(pa.nodes[1]) == -1.0
    pa = Path(0nm, 0nm)
    straight!(pa, 100μm, Paths.TaperTrace(10μm, 5μm))
    @test SolidModels.meshsize(pa.nodes[1]) == Unitful.ustrip(STP_UNIT, 20.0μm)
    @test SolidModels.meshgrading(pa.nodes[1]) == -1.0
    pa = Path(0nm, 0nm)
    straight!(pa, 100μm, Paths.SimpleCPW(5μm, 2μm))
    @test SolidModels.meshsize(pa.nodes[1]) == Unitful.ustrip(STP_UNIT, 10μm)
    @test SolidModels.meshgrading(pa.nodes[1]) == -1.0
    pa = Path(0nm, 0nm)
    straight!(pa, 100μm, Paths.TaperCPW(10μm, 5μm, 5μm, 2μm))
    @test SolidModels.meshsize(pa.nodes[1]) == Unitful.ustrip(STP_UNIT, 20.0μm)
    @test SolidModels.meshgrading(pa.nodes[1]) == -1.0

    pa = Path(0nm, 0nm)
    straight!(pa, 100μm, Paths.SimpleTrace(10μm))
    straight!(pa, 100μm, Paths.TaperTrace(10μm, 5μm))
    straight!(pa, 100μm, Paths.SimpleCPW(5μm, 2μm))
    straight!(pa, 100μm, Paths.TaperCPW(5μm, 2μm, 10μm, 2μm))
    simplify!(pa)
    @test SolidModels.meshsize(pa.nodes[1]) == Unitful.ustrip(STP_UNIT, 20.0μm)
    @test SolidModels.meshgrading(pa.nodes[1]) == -1.0

    function test_sm()
        sm = SolidModel("test"; overwrite=true)
        SolidModels.gmsh.option.setNumber("General.Verbosity", 0)
        return sm
    end

    r = Rectangle(1μm, 1μm)
    cs = CoordinateSystem("test", nm)
    place!(cs, r, SemanticMeta(:test))
    sm = test_sm()
    render!(sm, cs)
    @test length(SolidModels.gmsh.model.get_entities(0)) == 4
    @test length(SolidModels.gmsh.model.get_entities(1)) == 4
    @test length(SolidModels.gmsh.model.get_entities(2)) == 1
    @test length(SolidModels.gmsh.model.get_entities(3)) == 0

    # Adding sizing does not change the primitive
    r_sty = Polygons.Rounded(0.25μm)
    m_sty = MeshSized(0.25μm)
    for e ∈
        [styled(r, r_sty), styled(styled(r, r_sty), m_sty), styled(styled(r, m_sty), r_sty)]
        cs = CoordinateSystem("test", nm)
        sm = test_sm()
        place!(cs, e, SemanticMeta(:test))
        render!(sm, cs)
        # 8 vertices, 4 radius origins
        @test length(SolidModels.gmsh.model.get_entities(0)) == 12
        @test length(SolidModels.gmsh.model.get_entities(1)) == 8
        @test length(SolidModels.gmsh.model.get_entities(2)) == 1
        @test length(SolidModels.gmsh.model.get_entities(3)) == 0
    end

    # Placing an optional rounded style at the bottom of a style tree is valid.
    r_sty =
        OptionalStyle(Polygons.Rounded(0.25μm), :rounded, false_style=DeviceLayout.Plain())
    e = styled(styled(r, r_sty), m_sty)
    for rounded ∈ (false, true)
        cs = CoordinateSystem("test", nm)
        sm = test_sm()
        place!(cs, e, SemanticMeta(:test))
        render!(sm, cs, rounded=rounded)
        @test length(SolidModels.gmsh.model.get_entities(0)) == (rounded ? 12 : 4)
        @test length(SolidModels.gmsh.model.get_entities(1)) == (rounded ? 8 : 4)
        @test length(SolidModels.gmsh.model.get_entities(2)) == 1
        @test length(SolidModels.gmsh.model.get_entities(3)) == 0
    end

    r_sty = Polygons.Rounded(0.25μm)
    m_sty = OptionalStyle(MeshSized(0.25μm), :meshed)
    e = styled(styled(r, m_sty), r_sty)
    for meshed ∈ (false, true)
        cs = CoordinateSystem("test", nm)
        sm = test_sm()
        place!(cs, e, SemanticMeta(:test))
        render!(sm, cs, meshed=meshed)
        @test length(SolidModels.gmsh.model.get_entities(0)) == 12
        @test length(SolidModels.gmsh.model.get_entities(1)) == 8
        @test length(SolidModels.gmsh.model.get_entities(2)) == 1
        @test length(SolidModels.gmsh.model.get_entities(3)) == 0
    end

    # TODO: support for nested optional styles
    c = difference2d(centered(Rectangle(2μm, 2μm)), centered(Rectangle(1μm, 1μm)))
    cs = CoordinateSystem("test", nm)
    sm = SolidModel("test"; overwrite=true)
    place!(cs, c, SemanticMeta(:test))
    render!(sm, cs)
    @test length(SolidModels.gmsh.model.get_entities(0)) == 8
    @test length(SolidModels.gmsh.model.get_entities(1)) == 8
    @test length(SolidModels.gmsh.model.get_entities(2)) == 1
    @test length(SolidModels.gmsh.model.get_entities(3)) == 0

    # Adding sizing does not change the primitive
    for e ∈
        [styled(c, r_sty), styled(styled(c, r_sty), m_sty), styled(styled(c, m_sty), r_sty)]
        cs = CoordinateSystem("test", nm)
        sm = test_sm()
        place!(cs, e, SemanticMeta(:test))
        render!(sm, cs)
        # 16 vertices, 8 radius origins
        @test length(SolidModels.gmsh.model.get_entities(0)) == 24
        @test length(SolidModels.gmsh.model.get_entities(1)) == 16
        @test length(SolidModels.gmsh.model.get_entities(2)) == 1
        @test length(SolidModels.gmsh.model.get_entities(3)) == 0
    end

    # Placing an optional style at the bottom is valid.
    r_sty =
        OptionalStyle(Polygons.Rounded(0.25μm), :rounded, false_style=DeviceLayout.Plain())
    m_sty = MeshSized(0.25μm)
    e = styled(styled(c, r_sty), m_sty)
    for rounded ∈ (false, true)
        cs = CoordinateSystem("test", nm)
        sm = test_sm()
        place!(cs, e, SemanticMeta(:test))
        render!(sm, cs, rounded=rounded)
        @test length(SolidModels.gmsh.model.get_entities(0)) == (rounded ? 24 : 8)
        @test length(SolidModels.gmsh.model.get_entities(1)) == (rounded ? 16 : 8)
        @test length(SolidModels.gmsh.model.get_entities(2)) == 1
        @test length(SolidModels.gmsh.model.get_entities(3)) == 0
    end

    # RelativeRounded works with L shape
    r_sty = OptionalStyle(
        Polygons.RelativeRounded(0.25),
        :rounded,
        false_style=DeviceLayout.Plain()
    )
    poly = Polygon(
        Point.([(0μm, 0μm), (2μm, 0μm), (2μm, 1μm), (1μm, 1μm), (1μm, 2μm), (0μm, 2μm)])
    )
    e = styled(poly, r_sty)
    for rounded ∈ (false, true)
        cs = CoordinateSystem("test", nm)
        sm = test_sm()
        place!(cs, e, SemanticMeta(:test))
        render!(sm, cs, rounded=rounded)
        @test length(SolidModels.gmsh.model.get_entities(0)) == (rounded ? 3 * 6 : 6)
        @test length(SolidModels.gmsh.model.get_entities(1)) == (rounded ? 2 * 6 : 6)
        @test length(SolidModels.gmsh.model.get_entities(2)) == 1
        @test length(SolidModels.gmsh.model.get_entities(3)) == 0
    end

    # RelativeRounded works with L shaped ClippedPolygon
    poly = difference2d(Rectangle(2μm, 2μm), Rectangle(1μm, 1μm))
    e = styled(poly, r_sty)
    for rounded ∈ (false, true)
        cs = CoordinateSystem("test", nm)
        sm = test_sm()
        place!(cs, e, SemanticMeta(:test))
        render!(sm, cs, rounded=rounded)
        @test length(SolidModels.gmsh.model.get_entities(0)) == (rounded ? 3 * 6 : 6)
        @test length(SolidModels.gmsh.model.get_entities(1)) == (rounded ? 2 * 6 : 6)
        @test length(SolidModels.gmsh.model.get_entities(2)) == 1
        @test length(SolidModels.gmsh.model.get_entities(3)) == 0
    end

    # RelativeRounded works with holey ClippedPolygon
    e = styled(c, r_sty)
    for rounded ∈ (false, true)
        cs = CoordinateSystem("test", nm)
        sm = test_sm()
        place!(cs, e, SemanticMeta(:test))
        render!(sm, cs, rounded=rounded)
        @test length(SolidModels.gmsh.model.get_entities(0)) == (rounded ? 24 : 8)
        @test length(SolidModels.gmsh.model.get_entities(1)) == (rounded ? 16 : 8)
        @test length(SolidModels.gmsh.model.get_entities(2)) == 1
        @test length(SolidModels.gmsh.model.get_entities(3)) == 0
    end

    # Point coincident with rounded ClippedPolygon
    r1 = Rectangle(2μm, 2μm)
    r2 = Rectangle(1μm, 1μm) + Point(0.5μm, 0.5μm)
    cs = CoordinateSystem("test", nm)
    sty = StyleDict()
    sty[1] = Rounded(1μm; p0=[Point(0.0μm, 0.0μm)], inverse_selection=true)
    sty[1, 1] = Rounded(0.5μm; p0=[Point(0.5μm, 0.5μm)], inverse_selection=true)
    place!(cs, sty(difference2d(r1, r2)), :test)
    place!(cs, Rectangle(0.5μm, 0.5μm), :test)
    sm = test_sm()
    render!(sm, cs) # runs without error

    # Use get_boundary and set_periodic!
    cs = CoordinateSystem("test", nm)
    place!(cs, centered(Rectangle(500μm, 100μm)), :l1)
    postrender_ops = [("ext", SolidModels.extrude_z!, (:l1, 20μm))]
    sm = test_sm()
    zmap = (m) -> (0μm)
    render!(sm, cs, zmap=zmap, postrender_ops=postrender_ops)
    sm["Xmin"] = SolidModels.get_boundary(sm["ext", 3]; direction="X", position="min")
    sm["Xmax"] = SolidModels.get_boundary(sm["ext", 3]; direction="X", position="max")
    sm["Ymax"] = SolidModels.get_boundary(sm["ext", 3]; direction="Y", position="max")
    @test isempty(
        @test_logs (
            :info,
            "set_periodic!(sm, Xmin, Xmax, 1, 1) only supports d1 = d2 = 2."
        ) SolidModels.set_periodic!(sm, "Xmin", "Xmax", 1, 1)
    )
    @test isempty(
        @test_logs (
            :info,
            "set_periodic! only supports distinct parallel axis-aligned surfaces."
        ) SolidModels.set_periodic!(sm, "Xmin", "Ymax")
    )
    periodic_tags = SolidModels.set_periodic!(sm["Xmin", 2], sm["Xmax", 2])
    @test !isempty(periodic_tags)

    # check_overlap
    cs = CoordinateSystem("test", nm)
    r1 = Rectangle(2μm, 2μm)
    r2 = translate(r1, Point(1μm, 0μm))
    r3 = translate(r1, Point(2μm, 0μm))
    place!(cs, r1, SemanticMeta(Symbol("r1")))
    place!(cs, r2, SemanticMeta(Symbol("r2")))
    sm = test_sm()
    render!(sm, cs)
    @test @test_logs (:warn, "Overlap of SolidModel groups r1 and r2 of dimension 2.") SolidModels.check_overlap(
        sm
    ) == [(
        "r1",
        "r2",
        2
    )]

    cs = CoordinateSystem("test", nm)
    place!(cs, r1, SemanticMeta(Symbol("r1")))
    place!(cs, r3, SemanticMeta(Symbol("r3")))
    sm = test_sm()
    render!(sm, cs)
    @test isempty(SolidModels.check_overlap(sm))

    cs = CoordinateSystem("test", nm)
    place!(cs, r1, SemanticMeta(Symbol("r1")))
    place!(cs, r2, SemanticMeta(Symbol("r2")))
    postrender_ops = [(
        "r2",
        SolidModels.difference_geom!,
        ("r2", "r2", 2, 2),
        :remove_object => true,
        :remove_tool => true
    )]
    sm = test_sm()
    render!(sm, cs; postrender_ops=postrender_ops)
    @test isempty(SolidModels.check_overlap(sm))

    # TODO: Composing OptionalStyle

    # Explicitly MeshSized Path.
    # TODO

    @testset "BooleanOperations" begin
        # Helper to create a cs with 3x3 tiles. Basis for boolean operations
        function tiled_cs(duplicate=false)
            cs = CoordinateSystem("test", nm)
            for i ∈ 0:2
                for j ∈ 0:2
                    ll = Point(i * 1μm, j * μm)
                    r = Rectangle(ll, ll + Point(1μm, 1μm))
                    place!(cs, r, SemanticMeta(Symbol("tile$i$j")))
                    duplicate && place!(cs, r, SemanticMeta(Symbol("tile$i$j")))
                end
            end
            return cs
        end

        tiles = [
            "tile00",
            "tile01",
            "tile02",
            "tile10",
            "tile11",
            "tile12",
            "tile20",
            "tile21",
            "tile22"
        ]

        bad_tiles = union(tiles, ["foo"])

        sm = SolidModel("test", overwrite=true)
        render!(
            sm,
            tiled_cs();
            postrender_ops=[(
                "tile",
                SolidModels.union_geom!,
                (bad_tiles, 2),
                :remove_object => true,
                :remove_tool => true
            )]
        )
        @test length(SolidModels.gmsh.model.get_entities(0)) == 4
        @test length(SolidModels.gmsh.model.get_entities(1)) == 4
        @test length(SolidModels.gmsh.model.get_entities(2)) == 1
        @test length(SolidModels.gmsh.model.get_entities(3)) == 0
        @test SolidModels.hasgroup(sm, "tile", 2)
        @test !any(SolidModels.hasgroup.(sm, tiles, 2))

        sm = SolidModel("test", overwrite=true)
        render!(
            sm,
            tiled_cs();
            postrender_ops=[(
                "tile",
                SolidModels.union_geom!,
                (bad_tiles[1:4], bad_tiles[5:end], 2, 2),
                :remove_object => true,
                :remove_tool => true
            )]
        )
        @test length(SolidModels.gmsh.model.get_entities(0)) == 4
        @test length(SolidModels.gmsh.model.get_entities(1)) == 4
        @test length(SolidModels.gmsh.model.get_entities(2)) == 1
        @test length(SolidModels.gmsh.model.get_entities(3)) == 0
        @test SolidModels.hasgroup(sm, "tile", 2)
        @test !any(SolidModels.hasgroup.(sm, tiles, 2))

        sm = SolidModel("test", overwrite=true)
        render!(
            sm,
            tiled_cs();
            postrender_ops=[
                (
                    "diff",
                    SolidModels.difference_geom!,
                    (bad_tiles, ["tile11", "tile21", "tile12", "bar"], 2, 2),
                    :remove_object => true,
                    :remove_tool => true
                ),
                ("diff", SolidModels.union_geom!, ("diff", 2))
            ]
        )
        @test length(SolidModels.gmsh.model.get_entities(0)) == 10
        @test length(SolidModels.gmsh.model.get_entities(1)) == 10
        @test length(SolidModels.gmsh.model.get_entities(2)) == 2
        @test length(SolidModels.gmsh.model.get_entities(3)) == 0
        @test SolidModels.hasgroup(sm, "diff", 2)
        @test !any(SolidModels.hasgroup.(sm, tiles, 2))

        sm = SolidModel("test", overwrite=true)
        render!(
            sm,
            tiled_cs();
            postrender_ops=[
                (
                    "int",
                    SolidModels.intersect_geom!,
                    (
                        [
                            "tile00",
                            "tile01",
                            "tile10",
                            "tile02",
                            "tile12",
                            "tile11",
                            "tile21",
                            "tile20",
                            "foo"
                        ],
                        [
                            "tile22",
                            "tile21",
                            "tile12",
                            "tile02",
                            "tile12",
                            "tile11",
                            "tile21",
                            "tile20",
                            "bar"
                        ],
                        2,
                        2
                    ),
                    :remove_object => true,
                    :remove_tool => true
                ),
                ("int", SolidModels.union_geom!, ("int", 2))
            ]
        )
        @test length(SolidModels.gmsh.model.get_entities(0)) == 10
        @test length(SolidModels.gmsh.model.get_entities(1)) == 10
        @test length(SolidModels.gmsh.model.get_entities(2)) == 1
        @test length(SolidModels.gmsh.model.get_entities(3)) == 0
        @test SolidModels.hasgroup(sm, "int", 2)
        @test !any(SolidModels.hasgroup.(sm, tiles, 2))

        sm = SolidModel("test", overwrite=true)
        render!(
            sm,
            tiled_cs(true);
            postrender_ops=[(
                "frag",
                SolidModels.fragment_geom!,
                (bad_tiles, 2),
                :remove_object => true
            )]
        )
        @test length(SolidModels.gmsh.model.get_entities(0)) == 16
        @test length(SolidModels.gmsh.model.get_entities(1)) == 2 * 4 * 3
        @test length(SolidModels.gmsh.model.get_entities(2)) == 9
        @test length(SolidModels.gmsh.model.get_entities(3)) == 0
        @test SolidModels.hasgroup(sm, "frag", 2)
        @test !any(SolidModels.hasgroup.(sm, tiles, 2))

        sm = SolidModel("test", overwrite=true)
        render!(sm, tiled_cs())

        @test (@test_logs (
            :info,
            "union_geom!(sm, [\"tile00\", \"foo\"], [\"bar\"], 2, 2): invalid arguments ([\"foo\"], 2)"
        ) (
            :info,
            "union_geom!(sm, [\"tile00\", \"foo\"], [\"bar\"], 2, 2): invalid arguments ([\"bar\"], 2)"
        ) SolidModels.union_geom!(sm, ["tile00", "foo"], ["bar"])) == [(2, 1)]

        @test (@test_logs (
            :info,
            "difference_geom!(sm, [\"tile00\", \"foo\"], [\"bar\"], 2, 2): invalid arguments ([\"foo\"], 2)"
        ) (
            :info,
            "difference_geom!(sm, [\"tile00\", \"foo\"], [\"bar\"], 2, 2): invalid arguments ([\"bar\"], 2)"
        ) SolidModels.difference_geom!(sm, ["tile00", "foo"], ["bar"])) == [(2, 1)]

        @test (@test_logs (
            :info,
            "difference_geom!(sm, [\"foo\"], [\"tile00\", \"bar\"], 2, 2): invalid arguments ([\"foo\"], 2)"
        ) (
            :info,
            "difference_geom!(sm, [\"foo\"], [\"tile00\", \"bar\"], 2, 2): invalid arguments ([\"bar\"], 2)"
        ) (
            :error,
            "difference_geom!(sm, [\"foo\"], [\"tile00\", \"bar\"], 2, 2): insufficient valid arguments"
        ) SolidModels.difference_geom!(sm, ["foo"], ["tile00", "bar"])) == []

        @test (@test_logs (
            :info,
            "intersect_geom!(sm, [\"foo\"], [\"tile00\", \"bar\"], 2, 2): invalid arguments ([\"foo\"], 2)"
        ) (
            :info,
            "intersect_geom!(sm, [\"foo\"], [\"tile00\", \"bar\"], 2, 2): invalid arguments ([\"bar\"], 2)"
        ) (
            :error,
            "intersect_geom!(sm, [\"foo\"], [\"tile00\", \"bar\"], 2, 2): insufficient valid arguments"
        ) SolidModels.intersect_geom!(sm, ["foo"], ["tile00", "bar"])) == []

        @test (@test_logs (
            :info,
            "intersect_geom!(sm, [\"tile00\", \"foo\"], [\"tile01\", \"bar\"], 2, 2): invalid arguments ([\"foo\"], 2)"
        ) (
            :info,
            "intersect_geom!(sm, [\"tile00\", \"foo\"], [\"tile01\", \"bar\"], 2, 2): invalid arguments ([\"bar\"], 2)"
        ) SolidModels.intersect_geom!(sm, ["tile00", "foo"], ["tile01", "bar"])) == []

        @test (@test_logs (
            :info,
            "fragment_geom!(sm, [\"tile00\", \"foo\"], [\"tile01\", \"bar\"], 2, 2): invalid arguments ([\"foo\"], 2)"
        ) (
            :info,
            "fragment_geom!(sm, [\"tile00\", \"foo\"], [\"tile01\", \"bar\"], 2, 2): invalid arguments ([\"bar\"], 2)"
        ) SolidModels.fragment_geom!(sm, ["tile00", "foo"], ["tile01", "bar"])) ==
              [(2, 1), (2, 2)]
    end
end
