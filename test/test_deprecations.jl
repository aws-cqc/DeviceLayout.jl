@testitem "Deprecations" setup = [CommonTestSetup, QuietGmshSetup] begin
    # Every deprecation is asserted here, so that the rest of the suite can stay quiet by
    # calling only current spellings. `@test_deprecated` covers `Base.depwarn` sites, which
    # fire under `--depwarn=yes` (as `Pkg.test` runs) and are silent otherwise; deprecations
    # with a new behavior to opt into warn at default visibility and are checked directly.
    using DeviceLayout.SchematicDrivenLayout: filter_parameters
    using DeviceLayout.SchematicDrivenLayout:
        SchematicGraph, add_node!, RouteComponent, Spacer, path
    import DeviceLayout.SchematicDrivenLayout.ExamplePDK
    using DeviceLayout.SchematicDrivenLayout.ExamplePDK.Transmons:
        ExampleRectangleTransmon, ExampleRectangleIsland

    @testset "layers -> gdslayers" begin
        c = Cell("deprecations", nm)
        render!(c, centered(Rectangle(2μm, 2μm)), GDSMeta(3, 1))
        @test (@test_deprecated layers(c)) == gdslayers(c) == [3]
    end

    @testset "non-finite selection_tolerance" begin
        # Default-visible warning: the replacement is a behavior change, not a rename.
        sty =
            @test_logs (:warn, r"Non-finite `selection_tolerance`") match_mode = :any Rounded(
                1μm,
                p0=[Point(1μm, 1μm)]
            )
        @test !isfinite(sty.selection_tolerance)
        @test_nowarn Rounded(1μm, p0=[Point(1μm, 1μm)], selection_tolerance=1nm)
    end

    @testset "ExamplePDK filter_params" begin
        tr = ExampleRectangleTransmon()
        @test (@test_deprecated ExamplePDK.filter_params(ExampleRectangleIsland, tr)) ==
              filter_parameters(ExampleRectangleIsland, tr)
    end

    @testset "circle" begin
        @test_logs (:warn, r"deprecated") match_mode = :any circle(1μm)
    end

    @testset "DXF export" begin
        main = Cell("main", nm)
        render!(main, Rectangle(10μm, 10μm), GDSMeta(0, 0))
        dxf_path = joinpath(tdir, "test.dxf")
        py3 = "python3"
        @test_deprecated save(dxf_path, main, py3)
        rect = [
            (0.0, 0.0, 0.0, 0.0, 0.0),
            (10.0, 0.0, 0.0, 0.0, 0.0),
            (10.0, 10.0, 0.0, 0.0, 0.0),
            (0.0, 10.0, 0.0, 0.0, 0.0)
        ]
        pyscript = joinpath(@__DIR__, "test_ezdxf.py")
        @test eval(Meta.parse(read(`$py3 $pyscript $dxf_path`, String))) == rect
    end

    @testset "GeneralStrands" begin
        straight = let pa = Path(μm)
            straight!(pa, 20μm, Paths.Trace(2μm))
            pa[1].seg
        end
        gstr = @test_deprecated Paths.Strands(x -> 10μm, 2μm, 2μm, 2)
        @test gstr isa Paths.GeneralStrands
        polys = to_polygons(straight, gstr)
        @test length(polys) == 2 * Paths.num(gstr)
        @test all(poly -> !iszero(Polygons.area(poly)), polys)
    end

    @testset "CompoundRouteRule and RouteComponent style vectors" begin
        crule = @test_deprecated Paths.CompoundRouteRule([
            Paths.StraightAnd90(min_bend_radius=20, max_bend_radius=100),
            Paths.BSplineRouting(endpoints_speed=2000),
            Paths.StraightAnd45(min_bend_radius=20, max_bend_radius=100)
        ])
        r5 = Route(
            crule,
            Point(10.0, 20.0),
            Point(50, 90),
            90°,
            135°,
            waypoints=[Point(100, 45), Point(100, 70)],
            waydirs=[0, π]
        )
        sty = Paths.CPW(10.0, 6.0)
        pa = Path(r5, [sty, sty, sty])
        @test p1(pa) ≈ Point(50, 90)
        @test p1(pa.nodes[2].seg) ≈ Point(100, 45)
        @test α1(pa.nodes[2].seg) == 0
        @test p1(pa.nodes[3].seg) ≈ Point(100, 70)
        @test α1(pa.nodes[3].seg) == 180°
        @test α1(pa) == 135°

        rc = @test_deprecated RouteComponent{Float64, typeof(crule)}(
            "crr",
            r5,
            false,
            [sty, sty, sty],
            GDSMeta()
        )
        @test p1(path(rc)) ≈ Point(50, 90)
        @test_nowarn RouteComponent("single", r5, false, sty, GDSMeta())
    end

    @testset "Integer attach! location" begin
        cs = CoordinateSystem("attachment", nm)
        place!(cs, centered(Rectangle(1μm, 1μm)), GDSMeta())
        for (old, new) in ((-1, :left), (0, :center), (1, :right))
            pa_old = Path(nm)
            straight!(pa_old, 10μm, Paths.CPW(2μm, 1μm))
            pa_new = Path(nm)
            straight!(pa_new, 10μm, Paths.CPW(2μm, 1μm))
            @test_deprecated attach!(pa_old, sref(cs), 5μm; location=old)
            attach!(pa_new, sref(cs), 5μm; location=new)
            @test pa_old[end].sty.dirs == pa_new[end].sty.dirs
        end
        # Ranges of `t` take a vector of integer locations
        pa = Path(nm)
        straight!(pa, 10μm, Paths.CPW(2μm, 1μm))
        @test_deprecated attach!(pa, sref(cs), (2μm, 8μm); location=[-1, 1])
        @test pa[end].sty.dirs == [-1, 1]

        # Schematic `attach!` and `RouteComponent` `attach!`
        g = SchematicGraph("attach")
        feed = Path(nm; name="feed")
        straight!(feed, 100μm, Paths.CPW(10μm, 6μm))
        feed_node = add_node!(g, feed)
        @test_deprecated attach!(
            g,
            feed_node,
            Spacer(0μm, 0μm) => :p0_south,
            50μm;
            location=1
        )
        r = Route(Paths.StraightAnd90(10μm), Point(0μm, 0μm), Point(100μm, 0μm), 0°, 0°)
        rc = RouteComponent("rc", r, false, Paths.CPW(2μm, 1μm), GDSMeta())
        @test_deprecated attach!(rc, sref(cs), 5μm; location=-1)
        @test rc.sty[1].dirs == [-1]
        @test_throws ArgumentError attach!(rc, sref(cs), 5μm; location=:up)
    end

    @testset "zero(::Segment)" begin
        seg = Paths.Straight(1.0μm, Point(0.0μm, 0.0μm), 0.0°)
        @test (@test_deprecated zero(seg)) === zero(eltype(seg)) === 0.0μm
        @test (@test_deprecated zero(Paths.Segment{Float64})) === 0.0
        @test (@test_deprecated zero(Paths.ContinuousSegment{Float64})) === 0.0
    end

    @testset "Reference keyword synonyms" begin
        cs = CoordinateSystem("synonyms", nm)
        canonical = sref(cs; xrefl=true, mag=2.0, rot=90°)
        for (xk, mk, rk) in zip(
            (:xreflection, :refl, :reflect, :xreflect, :xmirror, :mirror),
            (:magnification, :magnify, :zoom, :scale, :mag, :mag),
            (:rotation, :rotate, :angle, :rot, :rot, :rot)
        )
            kw = NamedTuple{(xk, mk, rk)}((true, 2.0, 90°))
            @test transformation(@test_deprecated sref(cs; kw...)) ==
                  transformation(canonical)
        end
        canonical_arr = aref(cs; dc=Point(1μm, 0μm), dr=Point(0μm, 2μm), nc=3, nr=4)
        synonym_sets = (
            (:deltacol, :deltarow, :numcols, :numrows),
            (:dcol, :drow, :numcol, :numrow),
            (:vcol, :vrow, :ncols, :nrows),
            (:colv, :rv, :ncol, :nrow),
            (:colvec, :rowvec, :col, :row),
            (:colvector, :rowvector, :nc, :nr),
            (:columnv, :dr, :nc, :nr),
            (:columnvec, :dr, :nc, :nr),
            (:columnvector, :dr, :nc, :nr)
        )
        for keys in synonym_sets
            kw = NamedTuple{keys}((Point(1μm, 0μm), Point(0μm, 2μm), 3, 4))
            arr = @test_deprecated aref(cs; kw...)
            @test (arr.deltacol, arr.deltarow, arr.col, arr.row) == (
                canonical_arr.deltacol,
                canonical_arr.deltarow,
                canonical_arr.col,
                canonical_arr.row
            )
        end
        # The canonical spelling wins over a synonym, without warning
        @test (@test_nowarn sref(cs; rot=90°, angle=0°)).rot == 90°
    end
end
