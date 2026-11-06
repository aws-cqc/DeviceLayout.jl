@testsnippet FencingSetup begin
    # Ground-truth length along the row at distance `o` outside the edge on side `σ`, between
    # posts given as (node index, pathlength within node): polyline length of densely sampled
    # row points, with Richardson extrapolation
    function row_length(pa, o, σ, (i0, t0), (i1, t1); n=200)
        len = zero(t0)
        for i = i0:i1
            node = pa[i]
            seg, sty = Paths.segment(node), Paths.style(node)
            a = i == i0 ? t0 : zero(t0)
            b = i == i1 ? t1 : pathlength(seg)
            a < b || continue
            row(t) =
                seg(t) +
                σ *
                (Paths.extent(sty, t) + o) *
                Point(-sin(Paths.direction(seg, t)), cos(Paths.direction(seg, t)))
            polyline(m) = sum(norm.(diff(row.(range(a, b, length=m + 1)))))
            len += (4 * polyline(2n) - polyline(n)) / 3
        end
        return len
    end

    same_points(a, b) =
        length(a) == length(b) && all(p -> any(q -> isapprox(p, q; atol=1e-6μm), b), a)

    row_spacings(pa, o, σ, posts) = [
        row_length(pa, o, σ, posts[k][1:2], posts[k + 1][1:2]) for k = 1:(length(posts) - 1)
    ]

    function post_cs()
        cs = CoordinateSystem(uniquename("post"), nm)
        render!(cs, Circle(2μm), GDSMeta(1))
        return cs
    end
end

@testitem "Fencing" setup = [CommonTestSetup, FencingSetup] begin
    # Posts for one row over the whole path, as (node index, pathlength in node, point)
    row(pa::Path{T}, o, σ, pitch) where {T} =
        Paths._fence_row(pa, convert(T, o), σ, convert(T, pitch), zero(T), pathlength(pa))

    @testset "Straight" begin
        cs = post_cs()
        pa = Path(μm)
        straight!(pa, 100μm, Paths.CPW(10μm, 6μm))
        pts = fence!(pa, sref(cs), 10μm, 20μm)
        # Rows at 5 + 6 + 10 μm from the centerline, first post at the start
        @test length(pts) == 12
        @test pts[1:6] ≈ [Point(x, 21μm) for x in (0:20:100)μm]
        @test pts[7:12] ≈ [Point(x, -21μm) for x in (0:20:100)μm]
        # Same placement as `attach!` at regular positions on a straight path
        pa2 = Path(μm)
        straight!(pa2, 100μm, Paths.CPW(10μm, 6μm))
        attach!(pa2, sref(cs, Point(0μm, 10μm)), (0:20:100)μm, location=:left)
        attach!(pa2, sref(cs, Point(0μm, -10μm)), (0:20:100)μm, location=:right)
        c1, c2 = Cell("c1", nm), Cell("c2", nm)
        render!(c1, pa, GDSMeta())
        render!(c2, pa2, GDSMeta())
        @test origin.(c1.refs) ≈ origin.(c2.refs)
        @test all(r -> structure(r) === cs, refs(pa))

        # Window
        pa = Path(μm)
        straight!(pa, 100μm, Paths.CPW(10μm, 6μm))
        @test getx.(fence!(pa, sref(cs), 10μm, 20μm; side=:left, margin=15μm)) ≈
              [15, 35, 55, 75]μm
        # Lengths in other units than the path's
        pa = Path(μm)
        straight!(pa, 100μm, Paths.CPW(10μm, 6μm))
        @test fence!(pa, sref(cs), 10000nm, 20000nm; side=:left, margin=15000nm) ≈
              [Point(x, 21μm) for x in (15:20:75)μm]
        pa = Path(μm)
        straight!(pa, 100μm, Paths.CPW(10μm, 6μm))
        @test getx.(fence!(pa, sref(cs), 10μm, 20μm; side=:right, start=30μm, stop=70μm)) ≈
              [30, 50, 70]μm
        # Multiple rows per side
        pa = Path(μm)
        straight!(pa, 100μm, Paths.CPW(10μm, 6μm))
        pts = fence!(pa, sref(cs), [5μm, 15μm], 50μm; side=:left)
        @test gety.(pts) ≈ [16, 16, 16, 26, 26, 26]μm

        # Unitless coordinates
        pa = Path{Float64}()
        straight!(pa, 100.0, Paths.Trace(2.0))
        cs0 = CoordinateSystem{Float64}(uniquename("post"))
        render!(cs0, Rectangle(1.0, 1.0), GDSMeta(1))
        @test fence!(pa, sref(cs0), 4.0, 25.0; side=:right) ≈
              [Point(x, -5.0) for x = 0.0:25.0:100.0]

        @test_throws ArgumentError fence!(pa, sref(cs0), 4.0, 25.0; side=:top)
        @test_throws ArgumentError fence!(pa, sref(cs0), 4.0, -25.0)
        pa = Path{Float64}()
        straight!(pa, 100.0, Paths.Trace(2.0))
        @test_throws r"nonnegative" fence!(pa, sref(cs0), [4.0, -1.0], 25.0)
        @test !(pa[1].sty isa Paths.DecoratedStyle)
    end

    @testset "Change of extent" begin
        cs = post_cs()
        function two_styles()
            p = Path(μm)
            straight!(p, 30μm, Paths.CPW(10μm, 6μm))
            straight!(p, 30μm, Paths.CPW(30μm, 10μm))
            return p
        end
        # The row jumps from 16 μm to 30 μm from the centerline, and the spacing is measured
        # along the row on either side of the jump
        @test fence!(two_styles(), sref(cs), 5μm, 20μm; side=:left) ≈
              [Point(0μm, 16μm), Point(20μm, 16μm), Point(40μm, 30μm), Point(60μm, 30μm)]
        # A window starting where the first node ends starts on the second node's row
        pa = two_styles()
        @test fence!(pa, sref(cs), 5μm, 20μm; side=:left, start=30μm) ≈
              [Point(30μm, 30μm), Point(50μm, 30μm)]
        @test !(pa[1].sty isa Paths.DecoratedStyle)
        # So does a post due where the first node ends, with or without `simplify!`
        function long_styles()
            p = Path(μm)
            straight!(p, 60μm, Paths.CPW(10μm, 6μm))
            straight!(p, 60μm, Paths.CPW(30μm, 10μm))
            return p
        end
        expected =
            [Point(x, y) for (x, y) in zip((0:20:120)μm, [16, 16, 16, 30, 30, 30, 30]μm)]
        for simplified in (false, true)
            pa = long_styles()
            simplified && simplify!(pa)
            @test fence!(pa, sref(cs), 5μm, 20μm; side=:left) ≈ expected
            c = Cell(uniquename("c"), nm)
            render!(c, pa, GDSMeta())
            @test same_points(origin.(c.refs), expected)
        end
        # ... unless only zero-length nodes follow
        pa = Path(μm)
        straight!(pa, 40μm, Paths.CPW(10μm, 6μm))
        straight!(pa, 0μm)
        @test fence!(pa, sref(cs), 5μm, 20μm; side=:left) ≈
              [Point(x, 16μm) for x in (0:20:40)μm]
    end

    @testset "Turns" begin
        cs = post_cs()
        for α in (90°, -90°), σ in (1, -1)
            pa = Path(μm)
            turn!(pa, α, 100μm, Paths.CPW(10μm, 6μm))
            posts = row(pa, 10μm, σ, 20μm)
            # Rows are offset curves with radius r ∓ 21 μm
            ctr = Paths.curvaturecenter(pa[1].seg)
            inner = sign(ustrip(α)) == σ
            @test all(p -> norm(p[3] - ctr) ≈ (inner ? 79μm : 121μm), posts)
            @test row_spacings(pa, 10μm, σ, posts) ≈ fill(20μm, length(posts) - 1)
            @test length(posts) == floor(Int, (inner ? 79 : 121) * π / 2 / 20) + 1
            # Agrees with `fence!` and with where the attachments render
            pts = fence!(pa, sref(cs), 10μm, 20μm; side=(σ > 0 ? :left : :right))
            @test pts ≈ last.(posts)
            c = Cell(uniquename("c"), nm)
            render!(c, pa, GDSMeta())
            @test same_points(origin.(c.refs), pts)
        end
    end

    @testset "Carryover and compound segments" begin
        cs = post_cs()
        pa = Path(μm)
        sty = Paths.CPW(10μm, 6μm)
        straight!(pa, 30μm, sty)
        turn!(pa, 90°, 100μm)
        straight!(pa, 25μm)
        turn!(pa, -120°, 60μm)
        straight!(pa, 40μm)
        for σ in (1, -1)
            posts = row(pa, 10μm, σ, 17μm)
            @test length(unique(first.(posts))) == 5 # Every node has posts
            @test row_spacings(pa, 10μm, σ, posts) ≈ fill(17μm, length(posts) - 1)
        end
        pts = fence!(deepcopy(pa), sref(cs), 10μm, 17μm)
        simplified = deepcopy(pa)
        simplify!(simplified)
        @test only(Paths.nodes(simplified)).seg isa Paths.CompoundSegment
        @test fence!(simplified, sref(cs), 10μm, 17μm) ≈ pts
    end

    @testset "B-splines and tapers" begin
        pa = Path(μm)
        bspline!(
            pa,
            [Point(200μm, 60μm), Point(400μm, 0μm)],
            0°,
            Paths.TaperCPW(10μm, 6μm, 20μm, 10μm);
            endpoints_speed=300μm
        )
        turn!(pa, 90°, 80μm, Paths.TaperCPW(20μm, 10μm, 10μm, 6μm))
        for σ in (1, -1)
            # Rows stay inside the minimum radius of curvature, so there is no warning
            posts = @test_logs min_level = Logging.Warn row(pa, 8μm, σ, 15μm)
            @test isapprox(
                row_spacings(pa, 8μm, σ, posts),
                fill(15μm, length(posts) - 1),
                rtol=1e-6
            )
        end
    end

    @testset "Degenerate rows" begin
        cs = post_cs()
        pa = Path(μm)
        straight!(pa, 50μm, Paths.CPW(10μm, 6μm))
        turn!(pa, 90°, 50μm)
        straight!(pa, 50μm)
        # The left row is 51 μm from the centerline, past the 50 μm turn's center
        pts = @test_logs (:warn, r"center of curvature of node\(s\) \[2\]") fence!(
            pa,
            sref(cs),
            40μm,
            20μm;
            side=:left
        )
        @test !(pa[2].sty isa Paths.DecoratedStyle)
        @test length(pa[1].sty.ts) == 3 && !isempty(pa[3].sty.ts)
        @test length(pts) == length(refs(pa))

        # A row that starts degenerate gets its first post where it begins, on the straight.
        # The row is 56 μm from the centerline, at (-6 μm, 50 μm) where the turn ends.
        for start in (0μm, 60μm)
            pa = Path(μm)
            turn!(pa, 90°, 50μm, Paths.CPW(10μm, 6μm))
            straight!(pa, 50μm)
            pts = @test_logs (:warn, r"center of curvature of node\(s\) \[1\]") fence!(
                pa,
                sref(cs),
                45μm,
                20μm;
                side=:left,
                start
            )
            @test !(pa[1].sty isa Paths.DecoratedStyle)
            @test pts ≈ [Point(-6μm, y) for y in (50:20:90)μm]
        end

        # A post due where a straight ends, before a turn whose row lies past its center,
        # stays on the straight, as after `simplify!`. The left row is 21 μm from the
        # centerline, past the 10 μm turn's center.
        function straight_turn(last_straight, simplified; l=60μm)
            p = Path(μm)
            straight!(p, l, Paths.CPW(10μm, 6μm))
            turn!(p, 90°, 10μm)
            last_straight && straight!(p, 60μm)
            simplified && simplify!(p)
            return p
        end
        left_fence(p; kw...) = @test_logs (:warn, r"center of curvature") fence!(
            p,
            sref(cs),
            10μm,
            20μm;
            side=:left,
            kw...
        )
        on_straight = [Point(x, 21μm) for x in (0:20:60)μm]
        for simplified in (false, true)
            @test left_fence(straight_turn(true, simplified)) ≈
                  [on_straight; [Point(49μm, y) for y in (30:20:70)μm]]
            # Not dropped if nothing follows the turn, or if the window ends inside it
            @test left_fence(straight_turn(false, simplified)) ≈ on_straight
            @test left_fence(straight_turn(true, simplified); stop=65μm) ≈ on_straight
            # A row starting there begins after the turn, exactly, so its last post is at the
            # end of the path
            @test left_fence(straight_turn(true, simplified); start=60μm) ≈
                  [Point(49μm, y) for y in (10:20:70)μm]
            # A post due just past the end of the straight goes after the turn. After
            # `simplify!`, the turn starts too close to the end of the interval integrated
            # for that post to be found unless the integral is split there.
            @test left_fence(straight_turn(true, simplified; l=59.999μm)) ≈ [
                [Point(x, 21μm) for x in (0:20:40)μm]
                [Point(48.999μm, y) for y in (10.001:20:50.001)μm]
            ]
        end
    end

    @testset "Generic tapers" begin
        cs = post_cs()
        pa = Path(μm)
        straight!(pa, 20μm, Paths.CPW(10μm, 6μm))
        straight!(pa, 20μm, Paths.Taper())
        straight!(pa, 20μm, Paths.CPW(20μm, 10μm))
        @test_throws ArgumentError fence!(pa, sref(cs), 10μm, 20μm)
        @test_throws r"Node 2 .* generic `Paths.Taper\(\)`" fence!(pa, sref(cs), 10μm, 20μm)
        @test !any(n -> n.sty isa Paths.DecoratedStyle, Paths.nodes(pa))
    end

    @testset "Corners" begin
        cs = post_cs()
        # Rows on the inside of a corner would overlap the path's metal and each other
        pa = Path(μm)
        straight!(pa, 50μm, Paths.Trace(10μm))
        corner!(pa, 90°, Paths.SimpleTraceCorner())
        straight!(pa, 50μm)
        icorner = findfirst(n -> n.seg isa Paths.Corner, Paths.nodes(pa))
        @test_throws Regex("Node $icorner .* `Paths.Corner`") fence!(
            pa,
            sref(cs),
            5μm,
            13μm;
            side=:left
        )
        @test !any(n -> n.sty isa Paths.DecoratedStyle, Paths.nodes(pa))
    end

    @testset "Offset segments" begin
        cs = post_cs()
        # Offset segments are parameterized by the pathlength of the curve they offset, but
        # rows are still spaced along their own length. A turn offset by 30 μm to its inside
        # is a turn of radius 70 μm.
        pa = Path(μm)
        turn!(pa, 90°, 100μm, Paths.CPW(10μm, 6μm))
        pa[1].seg = Paths.offset(pa[1].seg, 30μm)
        reconcile!(pa)
        pts = fence!(pa, sref(cs), 10μm, 20μm)
        pa2 = Path(μm)
        turn!(pa2, 90°, 70μm, Paths.CPW(10μm, 6μm))
        @test pts ≈ fence!(pa2, sref(cs), 10μm, 20μm)
        c = Cell(uniquename("c"), nm)
        render!(c, pa, GDSMeta())
        @test same_points(origin.(c.refs), pts)

        # Varying offsets. Bending to the right, where `curvatureradius` of the offset
        # segment has the wrong sign; and on a turn, inside compound segments nested by
        # repeated `simplify!`.
        pa = Path(μm)
        straight!(pa, 100μm, Paths.CPW(10μm, 6μm))
        pa[1].seg = Paths.offset(pa[1].seg, t -> -30μm * (t / 100μm)^2)
        pa_turn = Path(μm)
        straight!(pa_turn, 20μm, Paths.CPW(10μm, 6μm))
        turn!(pa_turn, 90°, 100μm)
        pa_turn[2].seg = Paths.offset(pa_turn[2].seg, t -> 10μm + 20μm * t / (50π * μm))
        simplify!(pa_turn)
        simplify!(pa_turn)
        @test only(pa_turn[1].seg.segments) isa Paths.CompoundSegment
        for p in (pa, pa_turn), σ in (1, -1)
            posts = row(p, 10μm, σ, 20μm)
            @test isapprox(
                row_spacings(p, 10μm, σ, posts),
                fill(20μm, length(posts) - 1),
                rtol=1e-6
            )
        end

        # Offsets of B-splines, alone, inside a compound segment, and without units. Their
        # rows need derivatives of the B-spline's curvature.
        function offset_bspline(u, off; straight=false)
            p = Path{typeof(1.0u)}()
            straight && straight!(p, 30u, Paths.CPW(10u, 6u))
            bspline!(
                p,
                [Point(200u, 60u), Point(400u, 0u)],
                0°,
                Paths.CPW(10u, 6u);
                endpoints_speed=300u,
                auto_curvature=true
            )
            straight && simplify!(p)
            p[1].seg = Paths.offset(p[1].seg, off)
            reconcile!(p)
            return p
        end
        pa = offset_bspline(μm, t -> 10μm * sin(t / 50μm))
        pa_compound = offset_bspline(μm, t -> 5μm + 10μm * t / 300μm; straight=true)
        pa_unitless = offset_bspline(1.0, 5.0)
        for (p, u) in ((pa, μm), (pa_compound, μm), (pa_unitless, 1.0)), σ in (1, -1)
            posts = @test_logs min_level = Logging.Warn row(p, 10u, σ, 20u)
            @test isapprox(
                row_spacings(p, 10u, σ, posts),
                fill(20u, length(posts) - 1),
                rtol=1e-6
            )
        end
        pts = fence!(pa, sref(cs), 10μm, 20μm)
        c = Cell(uniquename("c"), nm)
        render!(c, pa, GDSMeta())
        @test same_points(origin.(c.refs), pts)
    end

    @testset "Reversal" begin
        cs = post_cs()
        pa = Path(μm)
        straight!(pa, 30μm, Paths.CPW(10μm, 6μm))
        turn!(pa, 90°, 100μm)
        straight!(pa, 25μm)
        pts = fence!(pa, sref(cs), 10μm, 20μm)
        rev = Path(reverse(Paths.reverse.(Paths.nodes(pa))))
        reconcile!(rev)
        c1, c2 = Cell(uniquename("c"), nm), Cell(uniquename("c"), nm)
        render!(c1, pa, GDSMeta())
        render!(c2, rev, GDSMeta())
        @test same_points(origin.(c1.refs), pts)
        @test same_points(origin.(c2.refs), pts)
        # Attachments are found from the path, as with `attach!`
        ref = pa[1].sty.refs[1]
        @test origin(transformation(pa, ref)) ≈ pts[1]
    end
end
