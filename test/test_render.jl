@testitem "Rendering unit tests" setup = [CommonTestSetup] begin
    # Observe aliasing with rand_factor = 0.
    # Choosing large grid_step yields the minimum possible number of grid points (5).
    f = t -> (2.0μm + 1.0μm * cos(2π * t / (50μm)))
    grid = DeviceLayout.adapted_grid(
        f,
        (0μm, 100μm),
        grid_step=1mm,
        rand_factor=0.0,
        max_change=1nm
    )
    @test grid == [0.0μm, 25μm, 50μm, 75μm, 100μm]
end

@testitem "Styles" setup = [CommonTestSetup] begin
    @testset "NoRender" begin
        c = Cell{Float64}("main")
        pa = Path(NoUnits, α0=24.31°)
        straight!(pa, 21.2345, Paths.NoRender())
        render!(c, pa)
        @test isempty(c.elements)

        # === Issue 83 === #
        c = Cell("main", nm2μm)
        pth = DeviceLayout.Path(DeviceLayout.Point(0μm, 350μm); α0=π / 2)
        straight!(pth, 350μm - 100μm, Paths.Trace(4μm))
        straight!(pth, 2 * 100μm, Paths.NoRender()) # bounds on cs works fine without this line
        cs = CoordinateSystem("main", nm2μm)
        place!(cs, pth, :metal)
        render!(c, cs, map_meta=(_) -> GDSMeta())
        @test bounds(cs) == bounds(c)
        @test isproper(bounds(cs))

        cs = CoordinateSystem("test", nm)
        place!(
            cs,
            DeviceLayout.styled(Rectangle(1μm, 1μm), DeviceLayout.NoRender()),
            :metal
        )
        @test isempty(elements(halo(cs, 10μm)))
    end

    @testset "Decorations" begin
        csub = Cell("sub", nm)
        render!(csub, centered(Rectangle(10nm, 10nm)), GDSMeta())
        cref = sref(csub, Point(0.0μm, 0.0μm))

        c = Cell("main", nm)
        pa = Path(μm)
        straight!(pa, 20.0μm, Paths.NoRender())
        turn!(pa, π / 2, 20.0μm)
        straight!(pa, 20.0μm)
        simplify!(pa)
        attach!(pa, cref, range(0μm, stop=pathlength(pa), length=3))
        render!(c, pa)
        @test_logs (:warn, r"Ignoring attachments") render!.(c, pa, GDSMeta())
        @test transformation(pa["sub", 2]) ≈ transformation(refs(pa)[2])

        @test isempty(c.elements)
        @test length(c.refs) == 3

        flatten!(c)

        @test isempty(c.refs)
        @test length(c.elements) == 3
        @test points(c.elements[3]) == Point{typeof(1.0nm)}[
            p(-5.0nm, -5.0nm),
            p(5.0nm, -5.0nm),
            p(5.0nm, 5.0nm),
            p(-5.0nm, 5.0nm)
        ]
        @test points(c.elements[2]) == Point{typeof(1.0nm)}[
            p(34142.13562373095nm, 5850.793308457185nm),
            p(34149.206691542815nm, 5857.864376269051nm),
            p(34142.13562373095nm, 5864.935444080917nm),
            p(34135.06455591909nm, 5857.864376269051nm)
        ]
        @test points(c.elements[1]) == Point{typeof(1.0nm)}[
            p(40005.0nm, 39995.0nm),
            p(40005.0nm, 40005.0nm),
            p(39995.0nm, 40005.0nm),
            p(39995.0nm, 39995.0nm)
        ]

        cref = sref(csub, Point(0.0μm, 10.0μm))
        c = Cell("main", nm)
        setstyle!(pa[1], Paths.Trace(1μm))
        attach!(pa, cref, range(0μm, stop=pathlength(pa), length=3), location=-1)
        render!(c, pa)

        @test length(c.elements) == 3
        @test length(c.refs) == 3
        empty!(c.elements)
        empty!(c.element_metadata)
        flatten!(c)

        @test length(c.elements) == 3
        @test isempty(c.refs)
        @test points(c.elements[3]) == Point{typeof(1.0nm)}[
            p(-5nm, 10495.0nm),
            p(5nm, 10495.0nm),
            p(5nm, 10505.0nm),
            p(-5nm, 10505.0nm)
        ]
        @test points(c.elements[2]) == Point{typeof(1.0nm)}[
            p(26717.5144212722nm, 13275.414510915933nm),
            p(26724.585489084067nm, 13282.485578727797nm),
            p(26717.5144212722nm, 13289.556646539662nm),
            p(26710.443353460334nm, 13282.485578727797nm)
        ]
        @test c.elements[1] == Polygon(
            Point{typeof(1.0nm)}[
                p(29505.0nm, 39995.0nm),
                p(29505.0nm, 40005.0nm),
                p(29495.0nm, 40005.0nm),
                p(29495.0nm, 39995.0nm)
            ]
        )

        # Splitting at attachment point doesn't duplicate ref
        @test length(refs(split(pa[1], pathlength(pa[1]) / 2))) == 3

        # === Issue 13 ===
        c2 = Cell("c2", nm)
        render!(c2, Rectangle(1μm, 1μm), GDSMeta(1))
        c2ref = CellReference(c2, Point(0μm, 0μm))

        c = Cell("c", nm)
        ro = Path(μm, α0=180°)
        straight!(ro, 10μm, Paths.Trace(0.5μm))
        attach!(ro, c2ref, pathlength(ro))
        render!(c, ro)
        @test transformation(ro, c2ref) == ScaledIsometry(p1(ro), α1(ro))
        @test_logs (:warn, r"Ignoring attachments") render!.(c, ro)
        # === End Issue 13 ===

        # === Issue 51 ===
        c = Cell("c", nm)
        cs = CoordinateSystem("cs", nm)
        cs2 = CoordinateSystem("cs2", nm)
        render!(cs2, Rectangle(1μm, 1μm), SemanticMeta(:test))
        pa = Path(μm, α0=0°)
        straight!(pa, 10μm, Paths.Trace(0.5μm))
        attach!(pa, DeviceLayout.sref(cs2), pathlength(pa))
        render!(cs, pa, GDSMeta(0))
        render!(c, cs, map_meta=(meta) -> meta == GDSMeta(0) ? nothing : GDSMeta(1))
        @test length(c.elements) == 0
        @test length(flatten(c).elements) == 1
        @test flatten(c).element_metadata[1] == GDSMeta(1)
        # === End Issue 51 ===
    end

    @testset "Straight, SimpleTrace" begin
        c = Cell{Float64}("main")
        pa = Path(NoUnits, α0=12°)
        straight!(pa, 20.0, Paths.Trace(1.0))
        render!(c, pa)
        @test points(c.elements[1]) == Point{Float64}[
            p(0.10395584540887967, -0.48907380036690284),
            p(19.666907860084994, 3.6691600159882842),
            p(19.458996169267234, 4.64730761672209),
            p(-0.10395584540887967, 0.48907380036690284)
        ]

        c = Cell("main", pm)
        pa = Path(μm, α0=12°)
        straight!(pa, 20000nm, Paths.Trace(1.0μm))
        render!(c, pa)
        @test points(c.elements[1]) == Point{typeof(1.0pm)}[
            p(103955.84540887967pm, -489073.80036690284pm),
            p(1.9666907860084992e7pm, 3.6691600159882843e6pm),
            p(1.9458996169267233e7pm, 4.64730761672209e6pm),
            p(-103955.84540887967pm, 489073.80036690284pm)
        ]
    end

    @testset "Corner, SimpleTraceCorner" begin
        c = Cell{Float64}("main")
        pa = Path{Float64}()
        straight!(pa, 20.0, Paths.Trace(1))
        @test_throws ErrorException corner!(pa, π / 2)
        corner!(pa, π / 2, Paths.SimpleTraceCorner())
        straight!(pa, 20.0)
        render!(c, pa)

        @test length(c.elements) == 3
        @test points(c.elements[2]) ==
              Point{Float64}[p(19.5, 0.5), p(19.5, -0.5), p(20.5, -0.5), p(20.5, 0.5)]

        c = Cell("main", μm)
        pa = Path(μm)
        straight!(pa, 20.0μm, Paths.Trace(1.0μm))
        corner!(pa, π / 2, Paths.SimpleTraceCorner())
        straight!(pa, 20.0μm)
        render!(c, pa)

        @test length(c.elements) == 3
        @test points(c.elements[2]) == Point{typeof(1.0μm)}[
            p(19.5μm, 0.5μm),
            p(19.5μm, -0.5μm),
            p(20.5μm, -0.5μm),
            p(20.5μm, 0.5μm)
        ]
        @test reverse(Paths.SimpleTraceCorner(), 0) == Paths.SimpleTraceCorner()
    end

    @testset "Straight, GeneralTrace" begin
        c = Cell{Float64}("main")
        pa = Path{Float64}()
        straight!(pa, 20.0, Paths.Trace(x -> 2.0 * x))
        render!(c, pa)
        revsty = reverse(pa[1]).sty
        @test Paths.width(revsty, 0) == Paths.trace(pa[1].sty, 20)
        @test Paths.trace(pa[1].sty, 20) == Paths.trace(pa[1].sty)(20)
        @test Paths.extent(revsty)(20) == 0.5 * Paths.width(pa[1].sty)(0)
    end

    @testset "Straight, SimpleCPW" begin
        c = Cell{Float64}("main")
        pa = Path(NoUnits, α0=12°)
        straight!(pa, 20.0, Paths.CPW(5.0, 3.0))
        render!(c, pa)
        @test points(c.elements[1]) == Point{Float64}[
            p(-0.5197792270443984, 2.4453690018345142),
            p(19.043172787631715, 6.603602818189701),
            p(18.419437715178436, 9.538045620391118),
            p(-1.1435142994976764, 5.379811804035931)
        ]
        @test points(c.elements[2]) == Point{Float64}[
            p(1.1435142994976764, -5.379811804035931),
            p(20.70646631417379, -1.2215779876807442),
            p(20.082731241720513, 1.7128648145206729),
            p(0.5197792270443984, -2.4453690018345142)
        ]
        revsty = reverse(pa[1]).sty
        @test Paths.trace(revsty, 0) == Paths.trace(pa[1].sty, 20)
        @test Paths.trace(revsty, 20) == Paths.trace(pa[1].sty, 0)

        c = Cell("main", pm2μm)
        pa = Path(μm2μm, α0=12°)
        straight!(pa, 20000nm2μm, Paths.CPW(5.0μm2μm, 3000nm2μm))
        render!(c, pa)
        @test points(c.elements[1]) ==
              Point{typeof(1.0pm2μm)}[
            p(-0.5197792270443984pm2μm, 2.4453690018345142pm2μm),
            p(19.043172787631715pm2μm, 6.603602818189701pm2μm),
            p(18.419437715178436pm2μm, 9.538045620391118pm2μm),
            p(-1.1435142994976764pm2μm, 5.379811804035931pm2μm)
        ] * 10^6
        @test points(c.elements[2]) ==
              Point{typeof(1.0pm2μm)}[
            p(1.1435142994976764pm2μm, -5.379811804035931pm2μm),
            p(20.70646631417379pm2μm, -1.2215779876807442pm2μm),
            p(20.082731241720513pm2μm, 1.7128648145206729pm2μm),
            p(0.5197792270443984pm2μm, -2.4453690018345142pm2μm)
        ] * 10^6
    end

    @testset "Straight, GeneralCPW" begin
        c = Cell{Float64}("main")
        pa = Path(NoUnits, α0=12°)
        straight!(pa, 20.0, Paths.CPW(x -> 2 * x, x -> 3 * x))
        revsty = reverse(pa[1]).sty
        @test Paths.trace(revsty, 0) == Paths.trace(pa[1].sty, 20)
        @test Paths.trace(revsty, 20) == Paths.trace(pa[1].sty, 0)
        @test Paths.extent(revsty)(5) ==
              Paths.gap(pa[1].sty)(15) + Paths.trace(pa[1].sty)(15) / 2
    end

    @testset "Turn, SimpleTrace" begin
        c = Cell{Float64}("main")
        pa = Path{Float64}()
        turn!(pa, π / 2, 5.0, Paths.Trace(1))
        render!(c, pa)

        c = Cell("main", nm)
        pa = Path(μm)
        turn!(pa, π / 2, 20.0μm, Paths.Trace(1μm))
        render!(c, pa)

        c = Cell("main", nm)
        pa = Path(μm)
        turn!(pa, π, 16000µm, Paths.Trace(10µm))
        render!(c, pa)
        @test all(length.([cp.p for cp in c.elements]) .<= DeviceLayout.GDS_POLYGON_MAX)

        # Curve tolerance: exact edge is close to midpoint of polygon edge
        c = Cell{Float64}("main")
        pa = Path{Float64}()
        turn!(pa, 5°, 50.0, Paths.Trace(1))
        render!(c, pa)
        poly_edge_midpoint = sum(points(c.elements[1])[1:2]) / 2
        seg_exact = pa[1].seg(pathlength_nearest(pa[1].seg, poly_edge_midpoint))
        poly_extent = sqrt(sum(abs.(seg_exact - poly_edge_midpoint) .^ 2))
        @test abs(poly_extent - 0.5) < 0.001 # 1nm tolerance
    end

    # @testset "Turn, GeneralTrace" begin
    #
    # end

    @testset "Turn, SimpleCPW" begin
        # We are testing three things here:
        # 1. that Path can have different unit than turn radius (Devices.jl#16)
        # 2+3. that polygons are oriented properly for the two `to_polygons` methods this hits
        c = Cell("temp", nm)
        pa = Path(nm)
        straight!(pa, 100μm, Paths.CPW(10μm, 5μm))
        turn!(pa, -π, 20μm)
        render!(c, pa, GDSMeta(0))
        @test all(isequal(1), Polygons.orientation.(c.elements))

        # Test low-res rendering: verify geometric correctness rather than exact points,
        # since curvature-based discretization produces different vertex placement than the
        # old analytic arc formula (both are correct within atol).
        c = Cell{Float64}("main")
        pa = Path{Float64}()
        turn!(pa, π / 2, 50.0, Paths.CPW(10.0, 6.0))
        render!(c, pa, atol=2.0)
        # Turn center is at (0, 50) with radii: outer gap from r=55 to r=61, inner gap from r=39 to r=45
        center = p(0.0, 50.0)
        is_on_radius(r, rs, atol) = any(r0 -> isapprox(r, r0; atol=atol), rs)
        # Element 1: outer gap polygon (radii 55 and 61)
        pts1 = points(c.elements[1])
        @test Polygons.orientation(c.elements[1]) == 1
        @test pts1[1] ≈ p(0.0, -11.0) atol = 1e-10
        @test pts1[end] ≈ p(0.0, -5.0) atol = 1e-10
        for pt in pts1
            r = norm(pt - center)
            @test is_on_radius(r, (55.0, 61.0), 1e-10)
        end
        # Element 2: inner gap polygon (radii 39 and 45)
        pts2 = points(c.elements[2])
        @test Polygons.orientation(c.elements[2]) == 1
        @test pts2[1] ≈ p(0.0, 5.0) atol = 1e-10
        @test pts2[end] ≈ p(0.0, 11.0) atol = 1e-10
        for pt in pts2
            r = norm(pt - center)
            @test is_on_radius(r, (39.0, 45.0), 1e-10)
        end

        # Same test with units
        c = Cell("main", DeviceLayout.PreferMicrons.nm)
        pa = Path(μm)
        turn!(pa, π / 2, 50.0μm, Paths.CPW(10.0μm, 6.0μm))
        render!(c, pa, atol=2.0μm)
        center_nm = p(0.0nm, 50000.0nm)
        pts1 = points(c.elements[1])
        @test Polygons.orientation(c.elements[1]) == 1
        @test pts1[1] ≈ p(0.0nm, -11000.0nm) atol = 0.001nm
        @test pts1[end] ≈ p(0.0nm, -5000.0nm) atol = 0.001nm
        for pt in pts1
            r = norm(pt - center_nm)
            @test is_on_radius(r, (55000.0nm, 61000.0nm), 0.001nm)
        end
        pts2 = points(c.elements[2])
        @test Polygons.orientation(c.elements[2]) == 1
        @test pts2[1] ≈ p(0.0nm, 5000.0nm) atol = 0.001nm
        @test pts2[end] ≈ p(0.0nm, 11000.0nm) atol = 0.001nm
        for pt in pts2
            r = norm(pt - center_nm)
            @test is_on_radius(r, (39000.0nm, 45000.0nm), 0.001nm)
        end

        pa = Path(μm2μm)
        turn!(pa, π / 2, 50.0μm, Paths.CPW(10.0μm, 6.0μm))

        pa2 = split(pa[1], 50.0μm * 30°)
        let s1 = style(pa2[1]), s2 = style(pa2[2])
            @test Paths.trace(s1, 0μm) == 10.0μm
            @test Paths.trace(s1, 50.0μm * 30°) == 10.0μm
            @test Paths.trace(s2, 0μm) == 10.0μm
            @test Paths.trace(s2, 50.0μm * 60°) == 10.0μm
            @test Paths.gap(s1, 0μm) == 6.0μm
            @test Paths.gap(s1, 50.0μm * 30°) == 6.0μm
            @test Paths.gap(s2, 0μm) == 6.0μm
            @test Paths.gap(s2, 50.0μm * 60°) == 6.0μm
        end
        let s1 = segment(pa2[1]), s2 = segment(pa2[2])
            @test p0(s1) == Point(0, 0)μm
            @test p1(s1) == p0(s2) ≈ Point(50.0 * sin(30°), 50 * (1 - cos(30°)))μm
            @test p1(s2) ≈ Point(50, 50)μm
        end
    end

    @testset "Straight, TaperTrace" begin
        c = Cell("main", nm)
        pa = Path(μm)
        straight!(pa, 50.0μm, Paths.TaperTrace(10.0μm, 6.0μm))
        render!(c, pa)
        @test points(c.elements[1]) ≈ Point{typeof(1.0nm)}[
            p(0.0nm, -5000.0nm),
            p(50000.0nm, -3000.0nm),
            p(50000.0nm, 3000.0nm),
            p(0.0nm, 5000.0nm)
        ]

        # length not yet specified
        @test_throws "length" split(Paths.TaperTrace(10.0μm, 6.0μm), 10μm)

        pa2 = split(pa[1], 10μm)
        let s1 = style(pa2[1]), s2 = style(pa2[2])
            @test Paths.width(s1, 0μm) ≈ 10.0μm
            @test Paths.trace(s1, 5μm) == Paths.trace(s1)(5μm)
            @test Paths.extent(s1, 5μm) == Paths.extent(s1)(5μm)
            @test Paths.width(s1, 10μm) ≈ 9.2μm
            @test s1.length == 10μm
            @test Paths.width(s2, 0μm) ≈ 9.2μm
            @test Paths.width(s2, 40μm) ≈ 6.0μm
            @test s2.length == 40μm
        end
        let s1 = segment(pa2[1]), s2 = segment(pa2[2])
            @test p0(s1) == Point(0, 0)μm
            @test p1(s1) == p0(s2) == Point(10, 0)μm
            @test p1(s2) == Point(50, 0)μm
        end
    end

    @testset "Straight, TaperCPW" begin
        c = Cell("main", nm)
        pa = Path(μm)
        straight!(pa, 50.0μm, Paths.TaperCPW(10.0μm, 6.0μm, 8.0μm, 2.0μm))
        render!(c, pa)
        @test points(c.elements[1]) ≈ Point{typeof(1.0nm)}[
            p(0.0nm, 5000.0nm),
            p(50000.0nm, 4000.0nm),
            p(50000.0nm, 6000.0nm),
            p(0.0nm, 11000.0nm)
        ]
        @test points(c.elements[2]) ≈ Point{typeof(1.0nm)}[
            p(0.0nm, -11000.0nm),
            p(50000.0nm, -6000.0nm),
            p(50000.0nm, -4000.0nm),
            p(0.0nm, -5000.0nm)
        ]
        revsty = reverse(pa[1]).sty
        @test Paths.trace(revsty, 0.0μm) == Paths.trace(pa[1].sty, 50.0μm)
        @test Paths.trace(revsty, 50.0μm) == Paths.trace(pa[1].sty, 0.0μm)

        @test_throws "length" split(Paths.TaperCPW(10.0μm, 6.0μm, 8.0μm, 2.0μm), 10μm)

        pa2 = split(pa[1], 10μm)
        let s1 = style(pa2[1]), s2 = style(pa2[2])
            @test Paths.trace(s1, 0μm) ≈ 10.0μm
            @test Paths.trace(s1, 10μm) ≈ 9.6μm
            @test Paths.gap(s1, 0μm) ≈ 6.0μm
            @test Paths.gap(s1, 10μm) ≈ 5.2μm
            @test Paths.trace(s1, 5μm) == Paths.trace(s1)(5μm)
            @test Paths.extent(s1, 5μm) == Paths.extent(s1)(5μm)
            @test Paths.gap(s1, 5μm) == Paths.gap(s1)(5μm)
            @test s1.length == 10μm
            @test Paths.trace(s2, 0μm) ≈ 9.6μm
            @test Paths.trace(s2, 40μm) ≈ 8.0μm
            @test Paths.gap(s2, 0μm) ≈ 5.2μm
            @test Paths.gap(s2, 40μm) ≈ 2.0μm
            @test s2.length == 40μm
        end
    end

    @testset "Turn, TaperTrace" begin
        c = Cell("test", nm)
        pa = Path(μm)
        turn!(pa, π / 2, 20μm, Paths.TaperTrace(10μm, 20μm))
        render!(c, pa, GDSMeta(0))
        @test Paths.trace(pa[1].sty, 0μm) == 10μm

        @test (elements(c)[1]).p[1] ≈ p(0.0nm, -5000.0nm)
        @test (elements(c)[1]).p[end] ≈ p(0.0nm, 5000.0nm)
    end

    @testset "Turn, TaperCPW" begin
        c = Cell("test", nm)
        pa = Path(μm)
        turn!(pa, π / 2, 20μm, Paths.TaperCPW(10μm, 6μm, 20μm, 10μm))
        render!(c, pa, GDSMeta(0))

        # tests are confirming CCW orientation of the rendered polygons
        # pathtopolys returns [minus, plus] order (outer gap first for CCW turn)
        @test (elements(c)[1]).p[1] ≈ p(0.0nm, -11000.0nm) atol = 1.0nm
        @test (elements(c)[1]).p[end] ≈ p(0.0nm, -5000.0nm) atol = 1.0nm
        @test (elements(c)[2]).p[1] ≈ p(0.0nm, 5000.0nm) atol = 1.0nm
        @test (elements(c)[2]).p[end] ≈ p(0.0nm, 11000.0nm) atol = 1.0nm
    end

    @testset "Straight, Strands" begin
        c = Cell("test", nm)
        pa = Path(μm)
        straight!(pa, 20μm, Paths.Strands(10μm, 2μm, 2μm, 2))
        render!(c, pa, GDSMeta(0))

        # tests are confirming CCW orientation of the rendered polygons
        for i = 1:length(elements(c))
            pts = (elements(c)[i]).p
            @test pts[1].y < pts[end].y
        end
        # verify extent
        @test height(bounds(c)) ≈ 2 * Paths.extent(pa[1].sty)
        @test contains(summary(pa[1].sty), "2 strands")
        @test reverse(pa[1].sty, 10μm) == pa[1].sty
        @test Paths.translate(pa[1].sty, 10μm) == pa[1].sty
    end

    @testset "Turn, Strands" begin
        c = Cell("test", nm)
        pa = Path(μm)
        turn!(pa, π / 2, 20μm, Paths.Strands(10μm, 2μm, 2μm, 2))
        render!(c, pa, GDSMeta(0))

        # tests are confirming CCW orientation of the rendered polygons
        for i = 1:length(elements(c))
            pts = (elements(c)[i]).p
            @test pts[1].y < pts[end].y
        end
    end

    @testset "BSpline, SimpleCPW" begin
        c = Cell("test", nm)
        pa = Path(μm)
        bspline!(pa, [Point(1mm, 0.5mm)], 90°, Paths.CPW(10μm, 6μm))
        render!(c, pa, GDSMeta(0))

        # tests are confirming CCW orientation of the rendered polygons
        for i = 1:length(elements(c))
            pts = (elements(c)[i]).p
            @test pts[1].y < pts[end].y
        end
    end

    @testset "BSpline, TaperCPW" begin
        c = Cell("test", nm)
        pa = Path(μm)
        bspline!(pa, [Point(1mm, 0.5mm)], 90°, Paths.TaperCPW(10μm, 6μm, 20μm, 10μm))
        render!(c, pa, GDSMeta(0))

        # tests are confirming CCW orientation of the rendered polygons
        for i = 1:length(elements(c))
            pts = (elements(c)[i]).p
            @test pts[1].y < pts[end].y
        end
    end

    @testset "BSpline, TaperTrace" begin
        c = Cell("test", nm)
        pa = Path(μm)
        bspline!(pa, [Point(1mm, 0.5mm)], 90°, Paths.TaperTrace(10μm, 20μm))
        render!(c, pa, GDSMeta(0))

        # tests are confirming CCW orientation of the rendered polygons
        for i = 1:length(elements(c))
            pts = (elements(c)[i]).p
            @test pts[1].y < pts[end].y
        end
    end

    @testset "CompoundSegment" begin
        # CompoundSegment, CompoundStyle should render as if the path wasn't simplified,
        # provided that's possible. This is done for rendering and filesize efficiency.
        c = Cell{Float64}("main")
        pa = Path{Float64}()
        straight!(pa, 20.0, Paths.Trace(1))
        straight!(pa, 30.0)
        simplify!(pa)
        render!(c, pa)
        @test points(c.elements[1]) ≈ [p(0, -0.5), p(20, -0.5), p(20, 0.5), p(0, 0.5)]
        @test points(c.elements[2]) ≈ [p(20, -0.5), p(50, -0.5), p(50, 0.5), p(20, 0.5)]

        # OTOH, if we swap out the style, fall back to rendering using the CompoundSegment's
        # path function. In this case it should be the same
        c = Cell{Float64}("main")
        setstyle!(pa[1], Paths.Trace(1.0))
        render!(c, pa, grid_step=50.0)
        @test points(c.elements[1]) ≈ [p(0, -0.5), p(20, -0.5), p(20, 0.5), p(0, 0.5)]

        # Mismatched tags must use the CompoundStyle grid, not the original segment boundary.
        c = Cell{Float64}("main")
        pa3 = Path{Float64}()
        straight!(pa3, 20.0, Paths.Trace(1))
        straight!(pa3, 30.0, Paths.Trace(2))
        simplify!(pa3)
        swapped = Paths.CompoundStyle(
            Paths.Style[Paths.Trace(1.0), Paths.Trace(2.0)],
            [0.0, 25.0, 50.0],
            gensym()
        )
        setstyle!(pa3[1], swapped)
        render!(c, pa3, grid_step=50.0)
        # The first style spans 0..25 from the style grid; zipping would stop at 20.
        # The curvilinear path still emits leaves at the underlying segment boundary.
        style1 = filter(e -> extrema(gety.(points(e))) == (-0.5, 0.5), c.elements)
        style2 = filter(e -> extrema(gety.(points(e))) == (-1.0, 1.0), c.elements)
        @test length(style1) == 2
        @test length(style2) == 1

        style1_pts = vcat(points.(style1)...)
        @test extrema(getx.(style1_pts)) == (0.0, 25.0)
        @test extrema(gety.(style1_pts)) == (-0.5, 0.5)
        style2_pts = vcat(points.(style2)...)
        @test extrema(getx.(style2_pts)) == (25.0, 50.0)
        @test extrema(gety.(style2_pts)) == (-1.0, 1.0)

        # Test behavior if we swap out the segment
        c = Cell("main", nm)
        pa = Path(μm)
        straight!(pa, 20μm, Paths.Trace(10μm))
        straight!(pa, 20μm, Paths.Trace(15μm))
        straight!(pa, 20μm, Paths.Trace(20μm))
        simplify!(pa)
        @test Paths.nextstyle(pa) == Paths.Trace(20μm)
        revsty = reverse(pa[1]).sty
        @test Paths.trace(revsty, 55μm) == Paths.trace(pa[1].sty, 5μm)
        @test Paths.trace(revsty)(5μm) == Paths.trace(pa[1].sty)(55μm)
        @test Paths.extent(revsty)(5μm) == 0.5 * Paths.width(pa[1].sty)(55μm)

        pa2 = split(pa[1], 20μm)
        @test length(pa2) == 2
        @test length(segment(pa2[1]).segments) == 1
        @test p1(segment(pa2[1])) == p0(segment(pa2[2])) == Point(20, 0)μm
        @test p1(segment(pa2[2])) == Point(60, 0)μm
        @test length(segment(pa2[2]).segments) == 2

        pa2 = split(pa[1], 30μm)
        @test length(pa2) == 2
        @test length(segment(pa2[1]).segments) == 2
        @test p1(segment(pa2[1])) == p0(segment(pa2[2])) == Point(30, 0)μm
        @test p1(segment(pa2[2])) == Point(60, 0)μm
        @test length(segment(pa2[2]).segments) == 2

        setsegment!(pa[1], Paths.Straight(120.0μm, p(0.0μm, 0.0μm), 0.0))
        render!(c, pa, GDSMeta())
        @test lowerleft(bounds(c.elements[1])) ≈ Point(0μm, -5μm)
        @test upperright(bounds(c.elements[1])) ≈ Point(20μm, 5μm)
        @test lowerleft(bounds(c.elements[2])) ≈ Point(20μm, -7.5μm)
        @test upperright(bounds(c.elements[2])) ≈ Point(40μm, 7.5μm)
        @test lowerleft(bounds(c.elements[3])) ≈ Point(40μm, -10μm)
        @test upperright(bounds(c.elements[3])) ≈ Point(120μm, 10μm)

        # Split-then-render should preserve a curved compound node with a translated style grid.
        pa_curved = Path(0.0μm, 0.0μm)
        turn!(pa_curved, 90°, 50μm, Paths.Trace(10μm))
        turn!(pa_curved, -90°, 50μm, Paths.Trace(6μm))
        simplify!(pa_curved)
        c_ref = Cell("ref", nm)
        render!(c_ref, pa_curved, GDSMeta())
        L = pathlength(pa_curved[1].seg)
        pa_split = split(pa_curved[1], 0.6L) # 0.6L lands inside the second turn
        # The second piece is exactly the negative-grid, tag-mismatched case under test.
        @test segment(pa_split[2]).tag != style(pa_split[2]).tag
        @test first(style(pa_split[2]).grid) < zero(L)
        c_split = Cell("split", nm)
        render!(c_split, pa_split, GDSMeta())
        @test lowerleft(bounds(c_split)) ≈ lowerleft(bounds(c_ref)) atol = 1nm
        @test upperright(bounds(c_split)) ≈ upperright(bounds(c_ref)) atol = 1nm
    end

    @testset "Auto Taper" begin
        # Generate a path with different permutations of styles and
        # test rendering of auto taper style Taper()
        p1 = Path(μm)
        straight!(p1, 10μm, Paths.Trace(2.0μm))
        # element 2, test taper between traces
        straight!(p1, 10μm, Paths.Taper())
        straight!(p1, 10μm, Paths.Trace(4.0μm))
        # element 4, test taper between simple trace and hard-code taper trace
        straight!(p1, 10μm, Paths.Taper())
        straight!(p1, 10μm, Paths.TaperTrace(2.0μm, 1.0μm))
        # element 6, test taper between hard-code trace and general trace
        straight!(p1, 10μm, Paths.Taper())
        turn!(p1, -π / 2, 10μm, Paths.TaperTrace(2.0μm, 1.0μm))
        turn!(p1, -π / 2, 10μm, Paths.Taper())
        straight!(p1, 10μm, Paths.Trace(2.0μm))
        # elements 10, 11, test taper between trace and cpw
        straight!(p1, 10μm, Paths.Taper())
        straight!(p1, 10μm, Paths.CPW(2.0μm, 1.0μm))
        # elements 14, 15, test taper between CPW and CPW
        straight!(p1, 10μm, Paths.Taper())
        straight!(p1, 10μm, Paths.CPW(4.0μm, 2.0μm))
        # elements 18, 19, test taper between CPW and trace
        straight!(p1, 15μm, Paths.Taper())
        straight!(p1, 10μm, Paths.Trace(2.0μm))

        c = Cell("pathonly", nm)
        render!(c, p1, GDSMeta(0))

        @test points(c.elements[2]) == Point{typeof(1.0nm)}[
            p(10000.0nm, -1000.0nm),
            p(20000.0nm, -2000.0nm),
            p(20000.0nm, 2000.0nm),
            p(10000.0nm, 1000.0nm)
        ]
        @test points(c.elements[4]) == Point{typeof(1.0nm)}[
            p(30000.0nm, -2000.0nm),
            p(40000.0nm, -1000.0nm),
            p(40000.0nm, 1000.0nm),
            p(30000.0nm, 2000.0nm)
        ]
        @test points(c.elements[6]) == Point{typeof(1.0nm)}[
            p(50000.0nm, -500.0nm),
            p(60000.0nm, -1000.0nm),
            p(60000.0nm, 1000.0nm),
            p(50000.0nm, 500.0nm)
        ]
        @test points(c.elements[10]) == Point{typeof(1.0nm)}[
            p(50000.0nm, -20000.0nm),
            p(40000.0nm, -21000.0nm),
            p(40000.0nm, -22000.0nm),
            p(50000.0nm, -21000.0nm)
        ]
        @test points(c.elements[11]) == Point{typeof(1.0nm)}[
            p(50000.0nm, -19000.0nm),
            p(40000.0nm, -18000.0nm),
            p(40000.0nm, -19000.0nm),
            p(50000.0nm, -20000.0nm)
        ]
        @test points(c.elements[14]) ≈ Point{typeof(1.0nm)}[
            p(30000.0nm, -21000.0nm),
            p(20000.0nm, -22000.0nm),
            p(20000.0nm, -24000.0nm),
            p(30000.0nm, -22000.0nm)
        ]
        @test points(c.elements[15]) ≈ Point{typeof(1.0nm)}[
            p(30000.0nm, -18000.0nm),
            p(20000.0nm, -16000.0nm),
            p(20000.0nm, -18000.0nm),
            p(30000.0nm, -19000.0nm)
        ]
        @test points(c.elements[18]) ≈ Point{typeof(1.0nm)}[
            p(10000.0nm, -22000.0nm),
            p(-5000.0nm, -20000.0nm),
            p(-5000.0nm, -21000.0nm),
            p(10000.0nm, -24000.0nm)
        ]
        @test points(c.elements[19]) ≈ Point{typeof(1.0nm)}[
            p(10000.0nm, -16000.0nm),
            p(-5000.0nm, -19000.0nm),
            p(-5000.0nm, -20000.0nm),
            p(10000.0nm, -18000.0nm)
        ]

        # Test Auto-taper compatibility with compound segments
        p1 = Path(nm)
        straight!(p1, 100nm, Paths.Trace(10nm))
        straight!(p1, 100nm, Paths.Trace(10nm))
        simplify!(p1, 1:2)
        straight!(p1, 100nm, Paths.Taper())
        straight!(p1, 100nm, Paths.Trace(20nm))
        straight!(p1, 100nm, Paths.Trace(20nm))
        simplify!(p1, 3:4)

        c = Cell("pathonly", nm)
        render!(c, p1, GDSMeta(0))
        @test points(c.elements[3]) ≈ Point{typeof(1.0nm)}[
            p(200.0nm, -5.0nm),
            p(300.0nm, -10.0nm),
            p(300.0nm, 10.0nm),
            p(200.0nm, 5.0nm)
        ]

        # Auto-taper handled by `simplify`
        p2 = Path()
        straight!(p2, 100nm, Paths.Trace(10nm))
        straight!(p2, 100nm, Paths.Taper())
        straight!(p2, 100nm, Paths.Trace(20nm))
        node = simplify(p2, 2:3)
        @test node.sty.styles[1] isa Paths.TaperTrace
        @test p2[2].sty isa Paths.Taper # unchanged
        @test reverse(Paths.Taper(), 0) == Paths.Taper()
        @test contains(summary(Paths.Taper()), "linear taper")
    end

    @testset "Terminations" begin
        # Test geometry output for open terminations
        for s in (
                Paths.CPW(10μm, 6μm),
                Paths.CPW(t -> (10μm - t * 6μm / 200μm), t -> (6μm + t * μm / 200μm))
            ),
            rounding in (0.0μm, 2μm),
            initial in (true, false)

            pa = Path(p(0.0μm, 0.0μm); α0=10°)
            straight!(pa, 200μm, s)
            terminate!(pa; rounding=rounding, initial=initial)
            c = Cell("test", nm)
            render!(c, pa)

            # Test Layout.jl#68
            els = initial ? reverse(elements(c)) : elements(c)
            pts_approx(el) = [round.(pt, digits=9) for pt in ustrip.(nm, points(el))]
            # First and second element should be CPW polygons
            straight_points = Set(reduce(vcat, pts_approx.(els[1:2])))

            # Third element will be the terminating polygon
            termination_points = Set(pts_approx(els[3]))
            # Test that there are four points in common with CPW polygons and terminating polygon
            @test length(intersect(straight_points, termination_points)) == 4

            # Test terminating polygon has correct orientation
            @test Polygons.orientation(elements(c)[3]) == 1
        end

        # Test geometry output for short terminations
        for s in (
                Paths.CPW(10μm, 6μm),
                Paths.CPW(t -> (10μm - t * 6μm / 200μm), t -> (6μm + t * μm / 200μm))
            ),
            initial in (true, false)

            pa = Path(p(0.0μm, 0.0μm); α0=10°)
            straight!(pa, 200μm, s)
            terminate!(pa; rounding=2.0μm, gap=0.0μm, initial=initial)
            c = Cell("test", nm)
            render!(c, pa)

            # Test Layout.jl#68
            els = initial ? reverse(elements(c)) : elements(c)
            # Normalize tiny floating-point differences before intersecting shared corners.
            pts_approx(el) = [round.(pt, digits=9) for pt in ustrip.(nm, points(el))]
            straight_points = Set(reduce(vcat, pts_approx.(els[1:2])))

            # Third and fourth elements will be the terminating polygons
            termination_top_points = Set(pts_approx(els[3]))
            termination_bottom_points = Set(pts_approx(els[4]))

            # Each terminating polygon shares two corners with the CPW polygons
            @test length(intersect(straight_points, termination_top_points)) == 2
            @test length(intersect(straight_points, termination_bottom_points)) == 2
            @test length(intersect(termination_top_points, termination_bottom_points)) == 0

            # Test terminating polygon has correct orientation
            @test Polygons.orientation(els[3]) == 1
            @test Polygons.orientation(els[4]) == 1
        end

        pa = Path(p(0.0μm, 0.0μm); α0=10°)
        straight!(pa, 200μm, Paths.CPW(10μm, 6μm))
        terminate!(pa; rounding=0.0μm, gap=0.0μm)
        @test length(pa) == 1
        @test style(pa[end]) isa Paths.CPW

        # Test we cannot use too large a rounding radius given previous trace width
        # for open termination
        pa = Path(p(0.0μm, 0.0μm); α0=10°)
        straight!(pa, 10μm, Paths.CPW(10μm, 6μm))
        @test_throws ArgumentError terminate!(pa; rounding=5.1μm)
        terminate!(pa; rounding=5.0μm)

        # Test we cannot use too large a rounding radius given previous gap width
        # for short termination
        pa = Path(p(0.0μm, 0.0μm); α0=10°)
        straight!(pa, 10μm, Paths.CPW(10μm, 6μm))
        @test_throws ArgumentError terminate!(pa; gap=0.0μm, rounding=3.1μm)
        terminate!(pa; gap=0.0μm, rounding=3.0μm)
        @test Paths.extent(pa[end].sty) == Paths.extent(Paths.CPW(10μm, 6μm))

        # Test we cannot use too large a rounding radius given previous segment path length
        # for open termination
        pa = Path(p(0.0μm, 0.0μm); α0=10°)
        straight!(pa, 1μm, Paths.CPW(10μm, 6μm))
        @test_throws ArgumentError terminate!(pa; rounding=2.0μm)

        # for short termination
        pa = Path(p(0.0μm, 0.0μm); α0=10°)
        straight!(pa, 1μm, Paths.CPW(10μm, 6μm))
        @test_throws ArgumentError terminate!(pa; gap=0.0μm, rounding=2.0μm)

        # Trace terminations
        pa = Path(p(0.0μm, 0.0μm); α0=10°)
        straight!(pa, 200μm, Paths.Trace(10μm))
        terminate!(pa; rounding=2.0μm)
        terminate!(pa; rounding=2.0μm, initial=true)
        c = Cell("test", nm)
        render!(c, pa)
        @test Paths.extent(pa[end].sty) == Paths.width(pa[end].sty) / 2

        # Issue: Unit conversion + float approximation — runs without error
        pa = Path(nm)
        straight!(pa, 100μm, Paths.CPW(10μm, 6μm))
        attach!(pa, sref(c), 50μm) # +Test that attachment doesn't lead to terminationlength error
        terminate!(pa, gap=0μm, rounding=1μm)
        c = Cell("test", nm)
        render!(c, pa, GDSMeta())

        # Termination with rounding on curve
        # open
        pa = Path(nm)
        turn!(pa, 90°, 100μm, Paths.CPW(10μm, 6μm))
        terminate!(pa, rounding=3μm)
        terminate!(pa, rounding=3μm, initial=true)
        @test iszero(α0(pa))
        @test p0(pa) == Point(-6, 0)μm
        @test α1(pa) ≈ 90°
        @test p1(pa) ≈ Point(100, 106)μm
        @test reverse(pa[1]).sty == pa[end].sty
        c = Cell("test", nm)
        render!(c, pa, GDSMeta())
        @test bounds(c).ll.y < -11μm # Drawn as though straight, extends at slight angle
        # short
        pa = Path(nm)
        turn!(pa, pi / 2, 100μm, Paths.CPW(10μm, 6μm))
        terminate!(pa, gap=0μm, rounding=3μm)
        terminate!(pa, gap=0μm, rounding=3μm, initial=true)
        @test iszero(α0(pa))
        @test p0(pa) == Point(0, 0)μm
        @test α1(pa) ≈ 90°
        @test p1(pa) ≈ Point(100, 100)μm
        @test reverse(pa[1]).sty == pa[end].sty
        c = Cell("test", nm)
        render!(c, pa, GDSMeta())

        # Same with trace
        pa = Path(nm)
        turn!(pa, pi / 2, 100μm, Paths.Trace(10μm))
        terminate!(pa, rounding=5μm)
        terminate!(pa, rounding=5μm, initial=true)
        @test iszero(α0(pa))
        @test p0(pa) == Point(0, 0)μm
        @test α1(pa) ≈ 90°
        @test p1(pa) ≈ Point(100, 100)μm
        @test reverse(pa[1]).sty == pa[end].sty
        c = Cell("test", nm)
        render!(c, pa, GDSMeta())
    end

    @testset "Overlays" begin
        # Integration tests
        cs = CoordinateSystem("attachment", nm)
        place!(cs, centered(Rectangle(10μm, 30μm)), GDSMeta(1))

        path = Path(nm)
        path.metadata = GDSMeta()
        # Attach then overlay, Straight, CPW
        straight!(path, 100μm, Paths.CPW(10μm, 6μm))
        attach!(path, sref(cs), 10μm)
        Paths.overlay!(path, halo(path[end].sty, 2μm), GDSMeta(2)) # Adds halo of attachment too
        # Overlay then attach, Turn, TaperCPW
        turn!(path, 90°, 100μm, Paths.TaperCPW(10μm, 6μm, 2μm, 2μm))
        Paths.overlay!(path, halo(path[end].sty, 2μm), GDSMeta(2))
        attach!(path, sref(cs), 10μm)
        # Multiple overlays, BSpline, TaperCPW
        bspline!(path, [Point(1000μm, 1000μm)], 90°, Paths.TaperCPW(2μm, 2μm, 10μm, 6μm))
        Paths.overlay!(path, halo(path[end].sty, 2μm), GDSMeta(2))
        Paths.overlay!(path, halo(path[end].sty, 4μm), GDSMeta(3)) # includes halo of overlay by reference
        # Overlay and attach after simplifying
        simplify!(path)
        attach!(path, sref(cs), pathlength(path) - 200μm, location=1)
        Paths.overlay!(path, Paths.TaperCPW(50μm, 10μm, 22μm, 10μm), GDSMeta(4))

        c = Cell("test", nm)
        render!(c, ScaledIsometry(Point(10μm, 10μm), 45°, true)(path), GDSMeta())
        @test length(c.elements) == 6 # 6 CPW segments in base path
        @test length(c.refs) == 7 # 4 overlays, 3 attachments

        # Reverse
        rev_path = Path(reverse(reverse.(path.nodes)); metadata=GDSMeta())
        @test all(is_sliver.(to_polygons(xor2d(path => GDSMeta(), rev_path => GDSMeta()))))
        @test all(
            is_sliver.(to_polygons(xor2d(path => GDSMeta(2), rev_path => GDSMeta(2))))
        )
        @test all(
            is_sliver.(to_polygons(xor2d(path => GDSMeta(3), rev_path => GDSMeta(3))))
        )
        @test all(
            is_sliver.(to_polygons(xor2d(path => GDSMeta(4), rev_path => GDSMeta(4))))
        )

        # Halos
        hp = halo(path, 2μm; only_layers=[GDSMeta(1), GDSMeta(3)])
        # Note: because entire path is excluded, does not ignore attachment on first GDSMeta(2) overlay
        c = Cell("halo", nm)
        render!(c, hp)
        flatten!(c)
        @test length(c.elements) == 5 # 3 rectangles + 1 double halo rectangle + one overlay + 0 terminations
        # Overlay halos currently don't get terminations, normally a final segment gets 1
        # Not ideal but they don't track neighbors in this implementation
        hp = halo(path, 2μm)
        c = Cell("halo", nm)
        render!(c, hp)
        flatten!(c)
        @test length(c.elements) == 17 # 4 rectangles + 11 traces + 2 terminations
        @test count(c.element_metadata .== GDSMeta(0)) == 5 # original path + terminations
        @test count(c.element_metadata .== GDSMeta(1)) == 4 # rectangles
        @test count(c.element_metadata .== GDSMeta(2)) == 4 # 3 overlays + halo overlay reference
        @test count(c.element_metadata .== GDSMeta(3)) == 1 # 1 overlay
        @test count(c.element_metadata .== GDSMeta(4)) == 3 # final overlay
    end

    @testset "OffsetSegments" begin
        pa = Path(μm; α0=90°)
        straight!(pa, 10μm, Paths.Trace(2.0μm))
        pa1 = Path(
            [Paths.Node(Paths.offset(pa[1].seg, 5000nm), pa[1].sty)],
            metadata=GDSMeta()
        )
        @test p0(pa1) == Point(-5.0, 0.0)μm
        c_dec = Cell("decoration", nm)
        render!(c_dec, Rectangle(2μm, 2μm), GDSMeta(1))
        attach!(pa1, sref(c_dec), 5μm)
        cs1 = CoordinateSystem("test", nm)
        pathref = sref(pa1, Point(5μm, 5μm), rot=pi / 2, xrefl=true)
        addref!(cs1, pathref)
        flatten!(cs1)
        c1 = Cell(cs1)
        c_path = Cell("pathonly", nm)
        render!(c_path, pa1, GDSMeta())
        @test bounds(c1) ≈ bounds(transformation(pathref)(c_path)) atol = 1e-6nm
        # GeneralOffset
        pa2 = Path(
            [Paths.Node(Paths.offset(pa[1].seg, x -> 2μm + x), pa[1].sty)],
            metadata=GDSMeta()
        )
        @test p0(pa2) == Point(-2.0, 0.0)μm
        attach!(pa2, sref(c_dec), 10μm, location=-1)
        cs2 = CoordinateSystem("test", nm)
        pathref = sref(pa2, Point(5μm, 5μm), rot=pi / 2, xrefl=true)
        addref!(cs2, pa2, Point(5μm, 5μm), rot=pi / 2, xrefl=true)
        flatten!(cs2)
        c2 = Cell(cs2)
        c_path = Cell("pathonly", nm)
        render!(c_path, pa2, GDSMeta())
        @test bounds(c2) ≈ bounds(transformation(pathref)(c_path)) atol = 1e-6nm
    end

    @testset "to_polygons(seg, sty) direct render methods" begin
        # Explicit to_polygons(seg, sty) calls should preserve legacy direct-call behavior
        # while routing through Paths.Node rendering.
        as_polygons(p::Polygon) = (p,)
        as_polygons(ps) = ps
        function test_direct_polygons(output, expected_count)
            polys = as_polygons(output)
            @test length(polys) == expected_count
            @test all(poly -> length(points(poly)) >= 4, polys)
            @test all(poly -> isproper(bounds(poly)), polys)
            @test all(poly -> !iszero(Polygons.area(poly)), polys)
        end

        straight = let pa = Path(μm)
            straight!(pa, 20μm, Paths.Trace(2μm))
            pa[1].seg
        end

        sstr = Paths.Strands(10μm, 2μm, 2μm, 2)
        test_direct_polygons(
            to_polygons(Paths.offset(straight, 5μm), sstr),
            2 * Paths.num(sstr)
        )

        test_direct_polygons(
            to_polygons(Paths.offset(straight, 5μm), Paths.CPW(10μm, 6μm)),
            2
        )

        test_direct_polygons(to_polygons(straight, sstr), 2 * Paths.num(sstr))

        gstr = Paths.Strands(x -> 10μm, 2μm, 2μm, 2)
        test_direct_polygons(to_polygons(straight, gstr), 2 * Paths.num(gstr))

        comp, compsty = let pa = Path(μm)
            straight!(pa, 10μm, Paths.CPW(10μm, 6μm))
            straight!(pa, 10μm, Paths.CPW(10μm, 6μm))
            simplify!(pa)            # -> a CompoundSegment + CompoundStyle (matching tags)
            pa[1].seg, pa[1].sty
        end

        @test comp.tag == compsty.tag
        test_direct_polygons(to_polygons(comp, compsty), 4)   # 2 CPW gaps x 2 subsegments

        # Mismatched tags should use the generic CompoundStyle grid fallback.
        mismatched_compsty = let pa = Path(μm)
            straight!(pa, 10μm, Paths.CPW(10μm, 6μm))
            straight!(pa, 10μm, Paths.CPW(10μm, 6μm))
            simplify!(pa)
            pa[1].sty
        end
        @test comp.tag != mismatched_compsty.tag
        test_direct_polygons(to_polygons(comp, mismatched_compsty), 4)

        psty =
            Paths.PeriodicStyle([Paths.CPW(10μm, 6μm), Paths.CPW(8μm, 4μm)], [10μm, 10μm])
        test_direct_polygons(to_polygons(comp, psty), 4)

        # Build compounds whose lengths match each termination's `_termlength`. The short and
        # trace cases use nonzero rounding so the output has area to validate.
        compof(tl) =
            let pa = Path(μm)
                straight!(pa, tl / 2, Paths.CPW(10μm, 6μm))
                straight!(pa, tl / 2, Paths.CPW(10μm, 6μm))
                simplify!(pa)
                pa[1].seg
            end
        openterm = Paths.CPWOpenTermination(10μm, 6μm, 6μm, 0μm, false)
        shortterm = Paths.CPWShortTermination(10μm, 6μm, 0μm, 2μm, false)
        traceterm = Paths.TraceTermination(10μm, 2μm, false)
        test_direct_polygons(to_polygons(compof(Paths._termlength(openterm)), openterm), 1)
        test_direct_polygons(
            to_polygons(compof(Paths._termlength(shortterm)), shortterm),
            2
        )
        test_direct_polygons(
            to_polygons(compof(Paths._termlength(traceterm)), traceterm),
            1
        )
        trseg = let pa = Path(μm)
            straight!(pa, Paths._termlength(traceterm), Paths.Trace(10μm))
            pa[1].seg
        end
        test_direct_polygons(to_polygons(trseg, traceterm), 1)

        tt = Paths._withlength!(Paths.TaperTrace(10μm, 2μm), 20μm)
        tc = Paths._withlength!(Paths.TaperCPW(10μm, 6μm, 2μm, 1μm), 20μm)
        test_direct_polygons(to_polygons(Paths.Node(straight, tt)), 1)  # TaperTrace -> one Polygon
        test_direct_polygons(to_polygons(Paths.Node(straight, tc)), 2)  # TaperCPW -> two gap polygons
    end

    @testset "ClippedPolygons" begin
        r1 = centered(Rectangle(12μm, 12μm))
        r2 = centered(Rectangle(4μm, 4μm))
        r3 = centered(Rectangle(2μm, 2μm))
        r4 = centered(Rectangle(1μm, 1μm))
        δ = 3μm

        cc =
            [r2 + Point(+δ, +δ); r2 + Point(-δ, +δ); r2 + Point(+δ, -δ); r2 + Point(-δ, -δ)]
        ss = difference2d(r3, r4)
        cc2 =
            [ss + Point(+δ, +δ); ss + Point(-δ, +δ); ss + Point(+δ, -δ); ss + Point(-δ, -δ)]

        c = Cell("test", nm)
        cs = CoordinateSystem("test", nm)
        u = difference2d(r1, cc)
        place!(cs, u, GDSMeta())
        @test_nowarn render!(c, cs)

        c = Cell("test", nm)
        cs = CoordinateSystem("test", nm)
        u = union2d(u, cc2)
        place!(cs, u, GDSMeta())
        @test_nowarn render!(c, cs)

        c = Cell("test", nm)
        cs = CoordinateSystem("test", nm)
        u = difference2d(r1, cc2)
        place!(cs, u, GDSMeta())
        @test_nowarn render!(c, cs)

        @test u[1] == u.tree.children[1]
        @test u[1, 1] == u.tree.children[1].children[1]
        @test u[1, 1, 1] == u.tree.children[1].children[1].children[1]
        # Footprint uses outer contour when there's only one
        dr1 = difference2d(r2, r4)
        @test Polygons.circularapprox(
            rotate(footprint(dr1), 45°).p,
            rotate(r2, 45°).p,
            atol=1e-9μm
        )
        # Halo uses original ClippedPolygon, hole in the center
        # Offset preserves holes as interior cuts in keyhole polygons [issue #11 fix]
        h = halo(dr1, 0.1μm)
        @test length(h) == 1  # single keyhole polygon (hole encoded as interior cut)
        @test length(h[1].p) > 4  # more vertices than a simple rectangle = hole present
        @test footprint(union2d(r1, r1 + Point(40, 0)μm)) isa Rectangle # multipolygon => use bounds
        @test halo(union2d(r3), 1μm, -0.5μm) == dr1 # ClippedPolygon halo with inner delta

        @test Polygons.area(to_polygons(difference2d(r3, r4))[1]) ==
              Polygons.area(to_polygons(r3)) - Polygons.area(to_polygons(r4))
        @test is_sliver(to_polygons(difference2d(r3, r3 + Point(5, 5)nm))[1]; atol=10nm)
        @test (!).(is_sliver(to_polygons(difference2d(r3, r3 + Point(5, 5)nm))[1])) # default 1nm
    end
end

@testitem "Metadata mapping" setup = [CommonTestSetup] begin
    # Preserves GDSMeta
    @test DeviceLayout.default_meta_map(GDSMeta(10, 2)) == GDSMeta(10, 2)

    meta1 = SemanticMeta(:metal)
    gds1 = DeviceLayout.default_meta_map(meta1)
    @test gds1 isa GDSMeta
    @test 0 <= gdslayer(gds1) <= 255
    @test datatype(gds1) == 0  # index=1 → datatype=0
    @test datatype(DeviceLayout.default_meta_map(SemanticMeta(meta1, index=2))) == 1
    @test DeviceLayout.default_meta_map(SemanticMeta(meta1, level=2)) != gds1
    # Test repeatability
    @test DeviceLayout.default_meta_map(meta1) == DeviceLayout.default_meta_map(meta1)
    # Test different layers get different GDS layers (though collisions are possible)
    meta2 = SemanticMeta(:base)
    gds2 = DeviceLayout.default_meta_map(meta2)
    @test gds1 != gds2

    # Rendering with default map_meta
    cs = CoordinateSystem("test", nm)
    place!(cs, Rectangle(10nm, 10nm), SemanticMeta(:metal))
    place!(cs, Rectangle(20nm, 20nm), SemanticMeta(:base))
    place!(cs, Rectangle(30nm, 30nm), SemanticMeta(:base))

    c = Cell("test", nm)

    # Should work without explicit map_meta and produce warning
    @test_logs (:warn, r"Automatically converting") match_mode = :any render!(c, cs)

    @test length(c.elements) == 3
    @test c.element_metadata[1] != c.element_metadata[2]
    @test c.element_metadata[2] == c.element_metadata[3]
end

@testitem "Path metadata preservation (#160)" setup = [CommonTestSetup] begin
    @testset "User-set GDSMeta is preserved" begin
        c = Cell("meta_test", nm)
        pa = Path(nm)
        straight!(pa, 100nm, Paths.Trace(10nm))
        pa.metadata = GDSMeta(5, 3)
        render!(c, pa)
        @test pa.metadata == GDSMeta(5, 3)
        @test all(m -> m == GDSMeta(5, 3), c.element_metadata)
    end

    @testset "UNDEF_META defaults to GDSMeta(0,0)" begin
        c = Cell("undef_test", nm)
        pa = Path(nm)
        straight!(pa, 100nm, Paths.Trace(10nm))
        render!(c, pa)
        @test pa.metadata == GDSMeta(0, 0)
        @test all(m -> m == GDSMeta(0, 0), c.element_metadata)
    end

    @testset "Explicit metadata argument overrides" begin
        c = Cell("explicit_test", nm)
        pa = Path(nm)
        straight!(pa, 100nm, Paths.Trace(10nm))
        pa.metadata = GDSMeta(5, 3)
        render!(c, pa, GDSMeta(7, 1))
        @test pa.metadata == GDSMeta(7, 1)
        @test all(m -> m == GDSMeta(7, 1), c.element_metadata)
    end
end

@testitem "Rounding on StyledEntity" setup = [CommonTestSetup] begin
    # Line-arc rounding should still happen
    rnd1 = Rounded(1mm, p0=[Point(0, 0)mm, Point(5, 0)mm], selection_tolerance=1nm)
    rnd2 = Rounded(0.1mm)
    rect = Rectangle(1.0mm, 1.0mm)
    poly = to_polygons(rect) + Point(5mm, 0mm)
    clipped_poly = union2d(rect, poly) # multiple disjoint shapes
    res_rect = to_polygons(rnd2(rnd1(DeviceLayout.Plain(rect))))
    res_poly = to_polygons(rnd2(rnd1(DeviceLayout.Plain(poly))))
    res_clipped_poly = to_polygons(rnd2(rnd1(DeviceLayout.Plain(clipped_poly))))
    @test minimum(getx.(points(res_rect))) > 0mm # Bottom line-arc corner was rounded
    @test minimum(getx.(points(res_poly))) > 0mm # Bottom line-arc corner was rounded
    @test res_poly ≈ res_rect + Point(5mm, 0mm)
    @test isempty(to_polygons(xor2d(res_clipped_poly, [res_rect, res_poly])))
end
