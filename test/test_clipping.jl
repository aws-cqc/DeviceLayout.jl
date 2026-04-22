@testitem "Polygon clipping" setup = [CommonTestSetup] begin
    import DeviceLayout.Polygons: circularapprox, circularequality
    @testset "> Clipping individuals w/o units" begin
        # Rectangle{Int}, Rectangle{Int} clipping
        r1 = Rectangle(2, 2)
        r2 = Rectangle(1, 2)
        @test to_polygons(clip(Clipper.ClipTypeDifference, r1, r2))[1] ==
              Polygon(Point{Int}[(2, 2), (1, 2), (1, 0), (2, 0)])
        @test to_polygons(difference2d(r1, r2))[1] ==
              Polygon(Point{Int}[(2, 2), (1, 2), (1, 0), (2, 0)])
        @test typeof(clip(Clipper.ClipTypeDifference, r1, r2)) == ClippedPolygon{Int}
        @test typeof(to_polygons(clip(Clipper.ClipTypeDifference, r1, r2))) ==
              Vector{Polygon{Int}}

        # Rectangle{Int}, Polygon{Int} clipping
        p2 = Polygon(Point{Int}[(0, 0), (1, 0), (1, 2), (0, 2)])
        @test to_polygons(clip(Clipper.ClipTypeDifference, r1, p2))[1] ==
              Polygon(Point{Int}[(2, 2), (1, 2), (1, 0), (2, 0)])
        @test typeof(clip(Clipper.ClipTypeDifference, r1, p2)) == ClippedPolygon{Int}
        @test typeof(to_polygons(clip(Clipper.ClipTypeDifference, r1, p2))) ==
              Vector{Polygon{Int}}

        # Polygon{Int}, Polygon{Int} clipping
        p1 = Polygon(Point{Int}[(0, 0), (2, 0), (2, 2), (0, 2)])
        @test to_polygons(clip(Clipper.ClipTypeDifference, p1, p2))[1] ==
              Polygon(Point{Int}[(2, 2), (1, 2), (1, 0), (2, 0)])
        @test typeof(clip(Clipper.ClipTypeDifference, p1, p2)) == ClippedPolygon{Int}
        @test typeof(to_polygons(clip(Clipper.ClipTypeDifference, p1, p2))) ==
              Vector{Polygon{Int}}

        # Rectangle{Float64}, Rectangle{Float64} clipping
        r1 = Rectangle(2.0, 2.0)
        r2 = Rectangle(1.0, 2.0)
        @test to_polygons(clip(Clipper.ClipTypeDifference, r1, r2))[1] ==
              Polygon(Point{Float64}[(2.0, 2.0), (1.0, 2.0), (1.0, 0.0), (2.0, 0.0)])
        @test typeof(clip(Clipper.ClipTypeDifference, r1, r2)) == ClippedPolygon{Float64}
        @test typeof(to_polygons(clip(Clipper.ClipTypeDifference, r1, r2))) ==
              Vector{Polygon{Float64}}

        # Rectangle{Float64}, Polygon{Float64} clipping
        p2 = Polygon(Point{Float64}[(0, 0), (1, 0), (1, 2), (0, 2)])
        @test to_polygons(clip(Clipper.ClipTypeDifference, r1, p2))[1] ==
              Polygon(Point{Float64}[(2, 2), (1, 2), (1, 0), (2, 0)])
        @test typeof(clip(Clipper.ClipTypeDifference, r1, p2)) == ClippedPolygon{Float64}
        @test typeof(to_polygons(clip(Clipper.ClipTypeDifference, r1, p2))) ==
              Vector{Polygon{Float64}}

        # Polygon{Float64}, Polygon{Float64} clipping
        p1 = Polygon(Point{Float64}[(0, 0), (2, 0), (2, 2), (0, 2)])
        @test to_polygons(clip(Clipper.ClipTypeDifference, p1, p2))[1] ==
              Polygon(Point{Float64}[(2, 2), (1, 2), (1, 0), (2, 0)])
        @test typeof(clip(Clipper.ClipTypeDifference, p1, p2)) == ClippedPolygon{Float64}
        @test typeof(to_polygons(clip(Clipper.ClipTypeDifference, p1, p2))) ==
              Vector{Polygon{Float64}}

        # Test a case where the AbstractPolygon subtypes and numeric types are mixed
        # Rectangle{Int}, Polygon{Float64} clipping
        r2 = Rectangle(1, 2)
        @test to_polygons(clip(Clipper.ClipTypeDifference, p1, r2))[1] ==
              Polygon(Point{Float64}[(2, 2), (1, 2), (1, 0), (2, 0)])
        @test typeof(clip(Clipper.ClipTypeDifference, p1, r2)) == ClippedPolygon{Float64}
        @test typeof(to_polygons(clip(Clipper.ClipTypeDifference, p1, r2))) ==
              Vector{Polygon{Float64}}

        let
            # Issue 37
            square_pts = Point.([(-1, -1), (-1, 1), (1, 1), (1, -1)])
            small_square = Polygon(square_pts)
            big_square = Polygon(2 .* square_pts)
            mask = first(
                to_polygons(
                    clip(
                        Clipper.ClipTypeDifference,
                        big_square,
                        small_square,
                        pfs=Clipper.PolyFillTypeEvenOdd,
                        pfc=Clipper.PolyFillTypeEvenOdd
                    )
                )
            )
            c = Cell{Float64}("test")
            render!(c, mask)
            canvas = Polygon(5 .* square_pts)
            x = to_polygons(
                clip(
                    Clipper.ClipTypeDifference,
                    canvas,
                    mask,
                    pfs=Clipper.PolyFillTypeEvenOdd,
                    pfc=Clipper.PolyFillTypeEvenOdd
                )
            )
            c2 = Cell{Float64}("squares")
            for z in x
                render!(c2, z, GDSMeta(0))
            end

            @test length(elements(c2)) == 2

            # Issue 37
            square_pts = Point.([(-1, -1), (-1, 1), (1, 1), (1, -1)])
            small_square = Polygon(square_pts)
            big_square = Polygon(2 .* square_pts)
            mask = clip(
                Clipper.ClipTypeDifference,
                big_square,
                small_square,
                pfs=Clipper.PolyFillTypeEvenOdd,
                pfc=Clipper.PolyFillTypeEvenOdd
            )
            c = Cell{Float64}("test")
            render!(c, mask)
            canvas = Polygon(5 .* square_pts)
            x = clip(
                Clipper.ClipTypeDifference,
                canvas,
                mask,
                pfs=Clipper.PolyFillTypeEvenOdd,
                pfc=Clipper.PolyFillTypeEvenOdd
            )
            c2 = Cell{Float64}("squares")
            render!(c2, x, GDSMeta(0))

            @test length(elements(c2)) == 2
        end

        # Unions
        @test to_polygons(
            clip(Clipper.ClipTypeUnion, Rectangle(2, 2), Rectangle(2, 2) + Point(1, 1))
        )[1] == Polygon(
            Point{Int}[(2, 1), (3, 1), (3, 3), (1, 3), (1, 2), (0, 2), (0, 0), (2, 0)]
        )
        @test to_polygons(union2d(Rectangle(2, 2), Rectangle(2, 2) + Point(1, 1)))[1] ==
              Polygon(
            Point{Int}[(2, 1), (3, 1), (3, 3), (1, 3), (1, 2), (0, 2), (0, 0), (2, 0)]
        )
        @test to_polygons(
            union2d([Rectangle(2, 2), Rectangle(10, 10)], Rectangle(2, 2) + Point(1, 1))
        )[1] == Polygon(Point{Int}[(10, 10), (0, 10), (0, 0), (10, 0)])
        @test to_polygons(union2d([Rectangle(2, 2), Rectangle(10, 10)]))[1] ==
              Polygon(Point{Int}[(10, 10), (0, 10), (0, 0), (10, 0)])
        @test to_polygons(
            union2d(Rectangle(2, 2) + Point(1, 1), [Rectangle(2, 2), Rectangle(10, 10)])
        )[1] == Polygon(Point{Int}[(10, 10), (0, 10), (0, 0), (10, 0)])

        # XOR
        r1 = Rectangle(2.0, 2.0)
        r2 = Rectangle(2.0, 2.0) + Point(1.0, 1.0)
        @test xor2d(r1, r2) == union2d(difference2d(r2, r1), difference2d(r1, r2))
    end

    @testset "> ClippedPolygon operations w/o units" begin
        # Int
        r1 = Rectangle(3, 1) # (0,0) -> (3,1)
        r2 = Rectangle(1, 1) + Point(1, 0) # (1,0) -> (2,1)

        u = union2d(r1, r2)
        @test typeof(u) == ClippedPolygon{Int}
        up = to_polygons(u)
        @test length(up) == 1
        @test up[1] == Polygon(Point{Int}[(0, 0), (3, 0), (3, 1), (0, 1)])

        d = difference2d(r1, r2)
        @test typeof(d) == ClippedPolygon{Int}
        dp = to_polygons(d)
        @test length(dp) == 2
        @test dp[1] == Polygon(Point{Int}[(3, 1), (2, 1), (2, 0), (3, 0)])
        @test dp[2] == Polygon(Point{Int}[(0, 1), (0, 0), (1, 0), (1, 1)])

        i = intersect2d(r1, r2)
        @test typeof(i) == ClippedPolygon{Int}
        ip = to_polygons(i)
        @test length(ip) == 1
        @test ip[1] == Polygon(Point{Int}[(2, 1), (1, 1), (1, 0), (2, 0)])

        # Float64
        r1 = Rectangle(3.0, 1.0) # (0,0) -> (3,1)
        r2 = Rectangle(1.0, 1.0) + Point(1.0, 0.0) # (1,0) -> (2,1)

        u = union2d(r1, r2)
        @test typeof(u) == ClippedPolygon{Float64}
        up = to_polygons(u)
        @test length(up) == 1
        @test up[1] == Polygon(Point{Int}[(0.0, 0.0), (3, 0.0), (3.0, 1.0), (0.0, 1.0)])

        d = difference2d(r1, r2)
        @test typeof(d) == ClippedPolygon{Float64}
        dp = to_polygons(d)
        @test length(dp) == 2
        @test dp[1] == Polygon(Point{Int}[(3.0, 1.0), (2.0, 1.0), (2.0, 0.0), (3.0, 0.0)])
        @test dp[2] == Polygon(Point{Int}[(0.0, 1.0), (0.0, 0.0), (1.0, 0.0), (1.0, 1.0)])

        i = intersect2d(r1, r2)
        @test typeof(i) == ClippedPolygon{Float64}
        ip = to_polygons(i)
        @test length(ip) == 1
        @test ip[1] == Polygon(Point{Int}[(2.0, 1.0), (1.0, 1.0), (1.0, 0.0), (2.0, 0.0)])

        c = circle_polygon(1, 30°)
        f = θ -> Point(cosd(θ), sind(θ))
        ptrue = f.(0:30:330)
        @test circularapprox(points(c), ptrue)
        u = union2d(c, c)
        @test circularapprox(u.tree.children[1].contour, ptrue)
        u = union2d(u, c)
        @test circularapprox(u.tree.children[1].contour, ptrue)
    end

    @testset "> Clipping individuals w/ units" begin
        for T in (typeof(1μm), typeof(1.0μm))
            # Rectangle{T}, Rectangle{T} clipping
            r1 = Rectangle(T(2), T(2))
            r2 = Rectangle(T(1), T(2))
            @test to_polygons(clip(Clipper.ClipTypeDifference, r1, r2))[1] ==
                  Polygon(Point{T}[(T(2), T(2)), (T(1), T(2)), (T(1), T(0)), (T(2), T(0))])
            @test to_polygons(difference2d(r1, r2))[1] ==
                  Polygon(Point{T}[(T(2), T(2)), (T(1), T(2)), (T(1), T(0)), (T(2), T(0))])
            @test typeof(clip(Clipper.ClipTypeDifference, r1, r2)) == ClippedPolygon{T}
            @test typeof(to_polygons(clip(Clipper.ClipTypeDifference, r1, r2))) ==
                  Vector{Polygon{T}}

            # Rectangle{T}, Polygon{T} clipping
            p2 = Polygon(Point{T}[(T(0), T(0)), (T(1), T(0)), (T(1), T(2)), (T(0), T(2))])
            @test to_polygons(clip(Clipper.ClipTypeDifference, r1, p2))[1] ==
                  Polygon(Point{T}[(T(2), T(2)), (T(1), T(2)), (T(1), T(0)), (T(2), T(0))])
            @test typeof(clip(Clipper.ClipTypeDifference, r1, p2)) == ClippedPolygon{T}
            @test typeof(to_polygons(clip(Clipper.ClipTypeDifference, r1, p2))) ==
                  Vector{Polygon{T}}

            # Polygon{T}, Polygon{T} clipping
            p1 = Polygon(Point{T}[(T(0), T(0)), (T(2), T(0)), (T(2), T(2)), (T(0), T(2))])
            @test to_polygons(clip(Clipper.ClipTypeDifference, p1, p2))[1] ==
                  Polygon(Point{T}[(T(2), T(2)), (T(1), T(2)), (T(1), T(0)), (T(2), T(0))])
            @test typeof(clip(Clipper.ClipTypeDifference, p1, p2)) == ClippedPolygon{T}
            @test typeof(to_polygons(clip(Clipper.ClipTypeDifference, p1, p2))) ==
                  Vector{Polygon{T}}
        end

        # Mixing integer and floating point Unitful
        T1 = typeof(1μm)
        T2 = typeof(1.0μm)
        r1 = Rectangle(T1(2), T1(2))
        r2 = Rectangle(T2(1), T2(2))
        T = promote_type(T1, T2)
        @test to_polygons(clip(Clipper.ClipTypeDifference, r1, r2))[1] ==
              Polygon(Point{T}[(T(2), T(2)), (T(1), T(2)), (T(1), T(0)), (T(2), T(0))])
        @test to_polygons(difference2d(r1, r2))[1] ==
              Polygon(Point{T}[(T(2), T(2)), (T(1), T(2)), (T(1), T(0)), (T(2), T(0))])
        @test typeof(clip(Clipper.ClipTypeDifference, r1, r2)) == ClippedPolygon{T}
        @test typeof(to_polygons(clip(Clipper.ClipTypeDifference, r1, r2))) ==
              Vector{Polygon{T}}

        # Rectangle{T}, Polygon{T} clipping
        p2 = Polygon(points(r2))
        @test to_polygons(clip(Clipper.ClipTypeDifference, r1, p2))[1] ==
              Polygon(Point{T}[(T(2), T(2)), (T(1), T(2)), (T(1), T(0)), (T(2), T(0))])
        @test typeof(clip(Clipper.ClipTypeDifference, r1, p2)) == ClippedPolygon{T}
        @test typeof(to_polygons(clip(Clipper.ClipTypeDifference, r1, p2))) ==
              Vector{Polygon{T}}

        # Polygon{T}, Polygon{T} clipping
        p1 = Polygon(points(r1))
        @test to_polygons(clip(Clipper.ClipTypeDifference, p1, p2))[1] ==
              Polygon(Point{T}[(T(2), T(2)), (T(1), T(2)), (T(1), T(0)), (T(2), T(0))])
        @test typeof(clip(Clipper.ClipTypeDifference, p1, p2)) == ClippedPolygon{T}
        @test typeof(to_polygons(clip(Clipper.ClipTypeDifference, p1, p2))) ==
              Vector{Polygon{T}}
    end

    @testset "> ClippedPolygon operations w units" begin
        # Int
        r1 = Rectangle(3μm, 1μm) # (0,0) -> (3,1)
        r2 = Rectangle(1μm, 1μm) + Point(1μm, 0μm) # (1,0) -> (2,1)

        T = typeof(1μm)

        u = union2d(r1, r2)
        @test typeof(u) == ClippedPolygon{T}
        up = to_polygons(u)
        @test length(up) == 1
        @test up[1] == Polygon(Point{T}[(0μm, 0μm), (3μm, 0μm), (3μm, 1μm), (0μm, 1μm)])

        d = difference2d(r1, r2)
        @test typeof(d) == ClippedPolygon{T}
        dp = to_polygons(d)
        @test length(dp) == 2
        @test dp[1] == Polygon(Point{T}[(3μm, 1μm), (2μm, 1μm), (2μm, 0μm), (3μm, 0μm)])
        @test dp[2] == Polygon(Point{T}[(0μm, 1μm), (0μm, 0μm), (1μm, 0μm), (1μm, 1μm)])

        i = intersect2d(r1, r2)
        @test typeof(i) == ClippedPolygon{T}
        ip = to_polygons(i)
        @test length(ip) == 1
        @test ip[1] == Polygon(Point{T}[(2μm, 1μm), (1μm, 1μm), (1μm, 0μm), (2μm, 0μm)])

        # Float64
        r1 = Rectangle(3.0μm, 1.0μm) # (0,0) -> (3,1)
        r2 = Rectangle(1.0μm, 1.0μm) + Point(1.0μm, 0.0μm) # (1,0) -> (2,1)

        T = typeof(1.0μm)

        u = union2d(r1, r2)
        @test typeof(u) == ClippedPolygon{T}
        up = to_polygons(u)
        @test length(up) == 1
        @test up[1] == Polygon(
            Point{T}[(0.0μm, 0.0μm), (3.0μm, 0.0μm), (3.0μm, 1.0μm), (0.0μm, 1.0μm)]
        )

        d = difference2d(r1, r2)
        @test typeof(d) == ClippedPolygon{T}
        dp = to_polygons(d)
        @test length(dp) == 2
        @test dp[1] == Polygon(
            Point{T}[(3.0μm, 1.0μm), (2.0μm, 1.0μm), (2.0μm, 0.0μm), (3.0μm, 0.0μm)]
        )
        @test dp[2] == Polygon(
            Point{T}[(0.0μm, 1.0μm), (0.0μm, 0.0μm), (1.0μm, 0.0μm), (1.0μm, 1.0μm)]
        )

        i = intersect2d(r1, r2)
        @test typeof(i) == ClippedPolygon{T}
        ip = to_polygons(i)
        @test length(ip) == 1
        @test ip[1] == Polygon(
            Point{T}[(2.0μm, 1.0μm), (1.0μm, 1.0μm), (1.0μm, 0.0μm), (2.0μm, 0.0μm)]
        )

        c = circle_polygon(1.0μm, 30°)
        f = θ -> Point(T(cosd(θ)), T(sind(θ)))
        ptrue = f.(0:30:330)
        @test circularapprox(points(c), ptrue)
        u = union2d(c, c)
        @test circularapprox(u.tree.children[1].contour, ptrue)
        u = union2d(u, c)
        @test circularapprox(u.tree.children[1].contour, ptrue)
    end

    @testset "> Clipping equivalent ClippedPolygons" begin
        for T in (Int64, Float64, typeof(1μm), typeof(1.0μm))
            r1 = Rectangle(T(2), T(2))
            r2 = Rectangle(T(1), T(2))
            u = union2d(r1, r2) # == r1

            @test u == union2d(r1, [r2])
            @test u == union2d([r1], r2)
            @test u == union2d([r1], [r2])
            @test u == union2d([r1, r1], [r2, r2])
            @test u == union2d([r1, r1])
            @test u == union2d([r1, r2], [u])
            @test u == union2d([u], [r1, r2])
            @test u == union2d([r1, r2], u)
            @test u == union2d(u, [r1, r2])
            @test u == union2d([r1], u)
            @test u == union2d(u, [r1])
            @test u == union2d(r1, u)
            @test u == union2d(u, r1)
            @test u == union2d([u, u])
            @test u == union2d(u, u)
            @test u == union2d(u, [u])
            @test u == union2d([u], u)
            @test u == union2d([r1, u])
            @test u == union2d([u], r1)
            @test u == union2d(r1, [u])

            c = circle_polygon(1, 1°)
            u = union2d(c, c)
            @test u == union2d(c, [c])
            @test u == union2d([c], c)
            @test u == union2d([c], [c])
            @test u == union2d([c, c], [c, c])
            @test u == union2d([c, c])
            @test u == union2d([c, c], [u])
            @test u == union2d([u], [c, c])
            @test u == union2d([c, c], u)
            @test u == union2d(u, [c, c])
            @test u == union2d([c], u)
            @test u == union2d(u, [c])
            @test u == union2d(c, u)
            @test u == union2d(u, c)
            @test u == union2d([u, u])
            @test u == union2d(u, u)
            @test u == union2d(u, [u])
            @test u == union2d([u], u)
            @test u == union2d([u], [u])
            @test u == union2d([c, u])

            i = intersect2d(r1, r2) # == r2
            @test i == intersect2d(r1, [r2])
            @test i == intersect2d([r1], r2)
            @test i == intersect2d([r1], [r2])
            @test i == intersect2d([r1, r1], [r2, r2])
            @test i == intersect2d([r1, r2], [i])
            @test i == intersect2d([i], [r1, r2])
            @test i == intersect2d([r1], i)
            @test i == intersect2d(i, [r1])
            @test i == intersect2d(r1, i)
            @test i == intersect2d(i, r1)
            @test i == intersect2d(i, i)
            @test i == intersect2d(i, [i])
            @test i == intersect2d([i], i)

            d1 = difference2d(r1, r2) # == r2ᶜ ∩ r1
            d2 = difference2d(r1, r2 + Point(T(1), T(0)))

            @test length(intersect2d(d1, d2).tree.children) == 0
            @test d1 == difference2d(r1, [r2])
            @test d1 == difference2d([r1], r2)
            @test d1 == difference2d(d1, d2)
            @test d1 == difference2d([d1], d2)
            @test d1 == difference2d(d1, [d2])
            @test d1 == difference2d([d1], [d2])
            @test d2 == difference2d(d2, d1)
            @test d2 == difference2d(d2, [d1])
            @test d2 == difference2d([d2], d1)
            @test d2 == difference2d([d2], [d1])
        end

        r1 = Rectangle(2, 2)
        r2 = Rectangle(1.0, 2.0)
        u = union2d(r1, r2) # == r1
        @test u == union2d(u, r2)
        @test u == union2d(u, r1)
        @test u == union2d(r2, u)
        @test u == union2d(r1, u)
        @test u == clip(Clipper.ClipTypeUnion, r1, u)
        @test u == clip(Clipper.ClipTypeUnion, u, r1)
    end

    @testset "> Clipping arrays w/o units" begin
        r1 = Rectangle(2, 2)
        s = [r1, r1 + Point(0, 4), r1 + Point(0, 8)]
        c = [Rectangle(1, 10)]
        r = to_polygons(clip(Clipper.ClipTypeDifference, s, c))
        @test Polygon(Point{Int}[(2, 2), (1, 2), (1, 0), (2, 0)]) in r
        @test Polygon(Point{Int}[(2, 6), (1, 6), (1, 4), (2, 4)]) in r
        @test Polygon(Point{Int}[(2, 10), (1, 10), (1, 8), (2, 8)]) in r
        @test length(r) == 3
    end

    @testset "> Clipping with float arithmetic pitfalls" begin
        r1 = centered(Rectangle(50.0, 50.0))
        r1 = Polygon(
            Point(-6.82393350849692, -12.323933508496919),
            Point(3.32393350849692, -12.323933508496919),
            Point(3.32393350849692, 16.52393350849692),
            Point(-6.82393350849692, 16.52393350849692)
        )
        r2 = Rectangle(Point(-2.6, 4.1), Point(1.6, 4.25))
        # Bug (fixed) depends on y coordinate of lowerleft of inner polygon
        # which is used for calculating interior cuts for polygons with holes.
        # Due to imprecise float representations of integers larger than maxintfloat,
        # calculating the intersection point between two lines to find the interior
        # cut entrance could produce a point not on one of those lines.
        p3 = to_polygons(clip(Clipper.ClipTypeDifference, r1, r2))
        @test length(p3[1].p) == 11 # quadrilateral (rectangle) with rectangular keyhole

        # Issue #53
        for CASE = 3:7
            if CASE == 3 # works
                inner = Rectangle(10μm, 10μm)
                outer = circle_polygon(50μm, 1°)
            elseif CASE == 4 # works
                inner = Rectangle(10μm, 10μm) |> Translation(0μm, 10μm)
                outer = circle_polygon(50μm, 1°)
            elseif CASE == 5 # DOESN'T work
                inner = Rectangle(10μm, 10μm) |> Translation(10μm, 0μm)
                outer = circle_polygon(50μm, 1°)
            elseif CASE == 6 # works
                inner = Rectangle(10μm, 10μm) |> Translation(10μm, 0μm)
                outer = circle_polygon(50μm, 60°)
            elseif CASE == 7 # DOESN'T work
                inner = Rectangle(10μm, 10μm) |> Translation(10μm, 0μm)
                outer = circle_polygon(50μm, 45°)
            end
            diff = to_polygons(difference2d(outer, inner))
            @test length(diff[1].p) > length(outer.p)
        end

        rout = circle_polygon(100μm, π / 50)
        rin = centered(Rectangle(10μm, 10μm))
        pcb_outline = to_polygons(difference2d(rout, rin))[1]
        @test length(pcb_outline.p) > length(rout.p)
    end

    @testset "> Clipping with diagonal cut bug" begin
        r1 = Rectangle(4, 4)
        r2 = Rectangle(0.4, 0.4) + Point(1, 1)
        p1 = to_polygons(clip(Clipper.ClipTypeDifference, r1, r2))[1]
        p2s = to_polygons(clip(Clipper.ClipTypeDifference, offset(p1, 0.1), [p1]))

        correctcut = false
        # Don't assume polygons or points are in any particular order, test them all
        # We want to see a vertical cut from the lowerleft corner of inner hole
        for poly in p2s
            for i = 1:(length(poly.p) - 1)
                if abs.(poly.p[i] - poly.p[i + 1]) == Point(0, 0.1)
                    correctcut = true
                end
            end
        end
        @test correctcut
    end

    @testset "> Orientation" begin
        # Floating point coordinates must be clipperized to get the right answer
        pp = Point.([(185.0, -100.0), (300.0, -215.0), (300.0, -185.0), (215.0, -100.0)])
        @test Polygons.orientation(Polygon(pp)) == 1
    end

    @testset "> Mixed argument types" begin
        p1 = Rectangle(1mm, 1mm)
        p2 = centered(Rectangle(1µm, 1µm))
        # Clipped polygons with mixed units
        p1_clip = union2d(p1)
        p2_clip = union2d(p2)
        @test union2d([p1_clip, p2_clip]) == union2d([p1, p2])
        # add in a GeometryStructure
        cs = CoordinateSystem("test")
        place!(cs, p2, :test)
        @test coordinatetype(cs => :test) == coordinatetype(cs)
        @test union2d(cs => :test) == p2_clip
        @test union2d([p1, cs => :test]) == union2d([p1, p2])
        @test union2d(p1, cs => :test) == union2d([p1, p2])
        @test union2d(p1, [cs => :test]) == union2d([p1, p2])
    end

    @testset "Polygon methods" begin
        r1 = Rectangle(1, 1)
        empty_poly = difference2d(r1, r1)
        @test iszero(perimeter(empty_poly))
        multi_poly = union2d(r1, r1 + Point(3, 0))
        @test perimeter(multi_poly) == 8
    end
end

@testitem "Polygon offsetting" setup = [CommonTestSetup] begin
    @testset "Offsetting individuals w/o units" begin
        # Int rectangle, Int delta
        r = Rectangle(1, 1)
        o = offset(r, 1)
        @test length(o) == 1
        @test all(points(o[1]) .=== [p(2, 2), p(-1, 2), p(-1, -1), p(2, -1)])
        @test_throws DimensionError offset(r, 1μm)

        # Int rectangle, Float64 delta
        r = Rectangle(1, 1)
        o = offset(r, 0.5)
        @test length(o) == 1
        @test all(
            points(o[1]) .=== [p(1.5, 1.5), p(-0.5, 1.5), p(-0.5, -0.5), p(1.5, -0.5)]
        )
        @test_throws DimensionError offset(r, 0.5μm)

        # Int rectangle, Rational{Int} delta
        r = Rectangle(1, 1)
        o = offset(r, 1 // 2)
        @test length(o) == 1
        @test all(
            points(o[1]) .=== [
                p(3 // 2, 3 // 2),
                p(-1 // 2, 3 // 2),
                p(-1 // 2, -1 // 2),
                p(3 // 2, -1 // 2)
            ]
        )
        @test_throws DimensionError offset(r, 1μm // 2)

        # Float64 rectangle, Int delta
        r = Rectangle(1.0, 1.0)
        o = offset(r, 1)
        @test length(o) == 1
        @test all(
            points(o[1]) .=== [p(2.0, 2.0), p(-1.0, 2.0), p(-1.0, -1.0), p(2.0, -1.0)]
        )
        @test_throws DimensionError offset(r, 1μm)

        # Float64 rectangle, Float64 delta
        r = Rectangle(1.0, 1.0)
        o = offset(r, 0.5)
        @test length(o) == 1
        @test all(
            points(o[1]) .=== [p(1.5, 1.5), p(-0.5, 1.5), p(-0.5, -0.5), p(1.5, -0.5)]
        )
        @test_throws DimensionError offset(r, 0.5μm)

        # Float64 rectangle, Rational{Int} delta
        r = Rectangle(1.0, 1.0)
        o = offset(r, 1 // 2)
        @test length(o) == 1
        @test all(
            points(o[1]) .=== [p(1.5, 1.5), p(-0.5, 1.5), p(-0.5, -0.5), p(1.5, -0.5)]
        )
        @test_throws DimensionError offset(r, 1μm // 2)

        # Rational{Int} rectangle, Int delta
        r = Rectangle(1 // 1, 1 // 1)
        o = offset(r, 1)
        @test length(o) == 1
        @test all(
            points(o[1]) .=== [
                p(2 // 1, 2 // 1),
                p(-1 // 1, 2 // 1),
                p(-1 // 1, -1 // 1),
                p(2 // 1, -1 // 1)
            ]
        )
        @test_throws DimensionError offset(r, 1μm)

        # Rational{Int} rectangle, Float64 delta
        r = Rectangle(1 // 1, 1 // 1)
        o = offset(r, 0.5)
        @test length(o) == 1
        @test all(
            points(o[1]) .=== [p(1.5, 1.5), p(-0.5, 1.5), p(-0.5, -0.5), p(1.5, -0.5)]
        )
        @test_throws DimensionError offset(r, 0.5μm)

        # Rational{Int} rectangle, Rational{Int} delta
        r = Rectangle(1 // 1, 1 // 1)
        o = offset(r, 1 // 2)
        @test length(o) == 1
        @test all(
            points(o[1]) .=== [
                p(3 // 2, 3 // 2),
                p(-1 // 2, 3 // 2),
                p(-1 // 2, -1 // 2),
                p(3 // 2, -1 // 2)
            ]
        )
        @test_throws DimensionError offset(r, 0.5μm)
    end

    @testset "> Offsetting individuals w/ units" begin
        # Int*μm rectangle, Int-based delta
        r = Rectangle(1μm2μm, 1μm2μm)
        o = offset(r, 1μm)
        @test length(o) == 1
        @test all(
            points(o[1]) .=== [
                p(2μm2μm, 2μm2μm),
                p(-1μm2μm, 2μm2μm),
                p(-1μm2μm, -1μm2μm),
                p(2μm2μm, -1μm2μm)
            ]
        )
        o = offset(r, 5000nm)
        @test length(o) == 1
        @test all(
            points(o[1]) .=== [
                p(6μm2μm // 1, 6μm2μm // 1),
                p(-5μm2μm // 1, 6μm2μm // 1),
                p(-5μm2μm // 1, -5μm2μm // 1),
                p(6μm2μm // 1, -5μm2μm // 1)
            ]
        )
        @test_throws DimensionError offset(r, 1)

        # Int*μm rectangle, Float64-based delta
        r = Rectangle(1μm2μm, 1μm2μm)
        o = offset(r, 0.5μm)
        @test length(o) == 1
        @test all(
            points(o[1]) .=== [
                p(1.5μm2μm, 1.5μm2μm),
                p(-0.5μm2μm, 1.5μm2μm),
                p(-0.5μm2μm, -0.5μm2μm),
                p(1.5μm2μm, -0.5μm2μm)
            ]
        )
        o = offset(r, 500.0nm)
        @test length(o) == 1
        @test all(
            points(o[1]) .=== [
                p(1.5μm2μm, 1.5μm2μm),
                p(-0.5μm2μm, 1.5μm2μm),
                p(-0.5μm2μm, -0.5μm2μm),
                p(1.5μm2μm, -0.5μm2μm)
            ]
        )
        @test_throws DimensionError offset(r, 0.5)

        # Int*μm rectangle, Rational{Int}-based delta
        r = Rectangle(1μm2μm, 1μm2μm)
        o = offset(r, 1μm // 1)
        @test length(o) == 1
        @test all(
            points(o[1]) .=== [
                p(2μm2μm // 1, 2μm2μm // 1),
                p(-1μm2μm // 1, 2μm2μm // 1),
                p(-1μm2μm // 1, -1μm2μm // 1),
                p(2μm2μm // 1, -1μm2μm // 1)
            ]
        )
        o = offset(r, 500nm // 1)
        @test length(o) == 1
        @test all(
            points(o[1]) .=== [
                p(3μm2μm // 2, 3μm2μm // 2),
                p(-1μm2μm // 2, 3μm2μm // 2),
                p(-1μm2μm // 2, -1μm2μm // 2),
                p(3μm2μm // 2, -1μm2μm // 2)
            ]
        )
        @test_throws DimensionError offset(r, 1 // 2)

        # Float64*μm rectangle, Int-based delta
        r = Rectangle(1.0μm2μm, 1.0μm2μm)
        o = offset(r, 1μm)
        @test length(o) == 1
        @test all(
            points(o[1]) .=== [
                p(2.0μm2μm, 2.0μm2μm),
                p(-1.0μm2μm, 2.0μm2μm),
                p(-1.0μm2μm, -1.0μm2μm),
                p(2.0μm2μm, -1.0μm2μm)
            ]
        )
        o = offset(r, 5000nm)
        @test length(o) == 1
        @test all(
            points(o[1]) .=== [
                p(6.0μm2μm, 6.0μm2μm),
                p(-5.0μm2μm, 6.0μm2μm),
                p(-5.0μm2μm, -5.0μm2μm),
                p(6.0μm2μm, -5.0μm2μm)
            ]
        )
        @test_throws DimensionError offset(r, 1)

        # Float64*μm rectangle, Float64-based delta
        r = Rectangle(1.0μm2μm, 1.0μm2μm)
        o = offset(r, 0.5μm)
        @test length(o) == 1
        @test all(
            points(o[1]) .=== [
                p(1.5μm2μm, 1.5μm2μm),
                p(-0.5μm2μm, 1.5μm2μm),
                p(-0.5μm2μm, -0.5μm2μm),
                p(1.5μm2μm, -0.5μm2μm)
            ]
        )
        o = offset(r, 500.0nm)
        @test length(o) == 1
        @test all(
            points(o[1]) .=== [
                p(1.5μm2μm, 1.5μm2μm),
                p(-0.5μm2μm, 1.5μm2μm),
                p(-0.5μm2μm, -0.5μm2μm),
                p(1.5μm2μm, -0.5μm2μm)
            ]
        )
        @test_throws DimensionError offset(r, 0.5)

        # Float64*μm rectangle, Rational{Int}-based delta
        r = Rectangle(1.0μm2μm, 1.0μm2μm)
        o = offset(r, 1μm // 2)
        @test length(o) == 1
        @test all(
            points(o[1]) .=== [
                p(1.5μm2μm, 1.5μm2μm),
                p(-0.5μm2μm, 1.5μm2μm),
                p(-0.5μm2μm, -0.5μm2μm),
                p(1.5μm2μm, -0.5μm2μm)
            ]
        )
        o = offset(r, 500nm // 1)
        @test length(o) == 1
        @test all(
            points(o[1]) .=== [
                p(1.5μm2μm, 1.5μm2μm),
                p(-0.5μm2μm, 1.5μm2μm),
                p(-0.5μm2μm, -0.5μm2μm),
                p(1.5μm2μm, -0.5μm2μm)
            ]
        )
        @test_throws DimensionError offset(r, 1 // 2)
    end

    @testset "> Some less trivial cases" begin
        # Colliding rectangles
        rs = [Rectangle(1μm2μm, 1μm2μm), Rectangle(1μm2μm, 1μm2μm) + Point(1μm2μm, 1μm2μm)]
        o = offset(rs, 500nm)
        @test length(o) == 1
        @test all(
            points(o[1]) .=== [
                p(3μm2μm // 2, 1μm2μm // 2),
                p(5μm2μm // 2, 1μm2μm // 2),
                p(5μm2μm // 2, 5μm2μm // 2),
                p(1μm2μm // 2, 5μm2μm // 2),
                p(1μm2μm // 2, 3μm2μm // 2),
                p(-1μm2μm // 2, 3μm2μm // 2),
                p(-1μm2μm // 2, -1μm2μm // 2),
                p(3μm2μm // 2, -1μm2μm // 2)
            ]
        )
        @test_throws DimensionError offset(rs, 500)

        # Disjoint rectangles
        rs = [Rectangle(1μm, 1μm), Rectangle(1μm, 1μm) + Point(2μm, 0μm)]
        @test length(offset(rs, 100nm)) == 2

        # A glancing blow merges the two rectangles
        @test length(offset(rs, 500nm)) == 1
    end

    @testset "Clipping integration tests" begin
        # Layout.jl issue 21
        # make sure no empty polygons are returned
        isbad(p::ClippedPolygon) = isempty(p.tree.children) && isempty(p.tree.contour)
        isbad(p::Polygon) = isempty(points(p))
        r1 = centered(Rectangle(100, 100))
        r2 = Rectangle(5, 5)
        poly = difference2d(r1, [r2, r2 + Point(0, 10)])
        poly2 = offset(poly, 1)
        poly3 = difference2d(poly2, poly)
        @test isempty(filter(isbad, poly2)) && !isbad(poly3) && !isbad(poly)

        # Mixed `GeometryEntity`, arbitrary `GeometryStructure`, etc
        r0 = Rectangle(100μm, 100μm) - Point(0, 50)μm
        pa = Path(nm)
        straight!(pa, 50μm, Paths.CPW(5μm, 5μm))
        turn!(pa, 90°, 20μm)
        straight!(pa, 50μm)
        poly = to_polygons(difference2d(r0, pa))
        @test length(poly) == 3

        cs = CoordinateSystem("attach", nm)
        place!(cs, Circle(3μm), :test)
        simplify!(pa)
        attach!(pa, sref(cs), (0μm):(10μm):pathlength(pa))
        poly = to_polygons(intersect2d(r0, pa => :test))
        @test length(poly) == 12
    end

    @testset "Offset preserves holes (#11)" begin
        # Create a ring shape: outer square with inner hole
        outer = Rectangle(100nm, 100nm)
        inner = Rectangle(60nm, 60nm) + Point(20nm, 20nm)
        ring = difference2d(outer, inner)

        # Offset outward — should produce a single polygon (with interior cut
        # encoding the hole), not two separate flat polygons.
        # Without the fix, Clipper returns 2 separate Polygons (one for the
        # expanded outer contour, one for the shrunk inner hole contour) because
        # _offset loses hole topology.  With the fix, mixed-orientation contours
        # are recombined via union2d and flattened with interior cuts.
        result = offset(ring, 5nm)
        @test length(result) == 1  # single ring polygon with interior cut

        # The result should be larger than the original outer rectangle
        # (offset expands outward by 5nm on each side)
        b = bounds(result[1])
        @test width(b) > 100nm
        @test height(b) > 100nm

        # Also test with unitless integers (same bug path)
        outer_i = Rectangle(100, 100)
        inner_i = Rectangle(60, 60) + Point(20, 20)
        ring_i = difference2d(outer_i, inner_i)
        result_i = offset(ring_i, 5)
        @test length(result_i) == 1
    end
end

@testitem "Clipping CurvilinearPolygon" setup = [CommonTestSetup] begin

    # Reversing curve index formula tests
    f = (i, N) -> mod1(i + 1, N) - N - 1 # circ inc by 1 then reverse then negate

    ii = collect(1:8)
    ci = collect(1:2:8)
    tci = [-7, -5, -3, -1]
    @test all(f.(ci, length(ii)) .== tci)

    ci = collect(2:2:8)
    tci = [-6, -4, -2, -8]
    @test all(f.(ci, length(ii)) .== tci)

    ii = collect(1:6)
    ci = collect(2:2:6)
    tci = [-4, -2, -6]
    @test all(f.(ci, length(ii)) .== tci)

    ci = collect(1:2:6)
    tci = [-5, -3, -1]
    @test all(f.(ci, length(ii)) .== tci)

    # Rounded square
    pp =
        Point.([
            (1.0μm, 0.0μm),
            (2.0μm, 0.0μm),
            (3.0μm, 1.0μm),
            (3.0μm, 2.0μm),
            (2.0μm, 3.0μm),
            (1.0μm, 3.0μm),
            (0.0μm, 2.0μm),
            (0.0μm, 1.0μm)
        ])
    pp .+ Point(0.0μm, 1.0μm)
    curve_start_idx = collect(2:2:8)
    curves = [
        Paths.Turn(90°, 1.0μm, p0=pp[2], α0=0.0),
        Paths.Turn(90°, 1.0μm, p0=pp[4], α0=π / 2),
        Paths.Turn(90°, 1.0μm, p0=pp[6], α0=π),
        Paths.Turn(90°, 1.0μm, p0=pp[8], α0=3π / 2)
    ]
    cp = CurvilinearPolygon(pp, curves, curve_start_idx)

    rcp = XReflection()(cp)
    cs = CoordinateSystem("test", nm)
    place!(cs, cp, GDSMeta())
    place!(cs, rcp, GDSMeta())
    @test_nowarn render!(Cell("main", nm), cs)

    rcp += Point(0.0μm, 3.0μm)
    δ = difference2d(to_polygons(cp), to_polygons(rcp))
    cs = CoordinateSystem("test", nm)
    place!(cs, δ, GDSMeta())
    @test_nowarn render!(Cell("main", nm), cs)

    # Shift ordering of points by 1
    circshift!(pp, -1)
    curve_start_idx = collect(1:2:8)
    cp = CurvilinearPolygon(pp, curves, curve_start_idx)

    rcp = XReflection()(cp)
    cs = CoordinateSystem("test", nm)
    place!(cs, cp, GDSMeta())
    place!(cs, rcp, GDSMeta())
    @test_nowarn render!(Cell("main", nm), cs)

    # Test to check ordering of segments matters,
    pp =
        Point.([
            (0.0μm, 0.0μm),
            (4.0μm, 0.0μm),
            (4.0μm, 1.5μm),
            (3.5μm, 2.0μm),
            (2.5μm, 2.0μm),
            (2.0μm, 2.5μm),
            (2.0μm, 4.0μm),
            (0.0μm, 4.0μm)
        ])
    curves = [
        Paths.Turn(90°, 0.5μm, p0=pp[3], α0=π / 2),
        Paths.Turn(-90°, 0.5μm, p0=pp[5], α0=π)
    ]
    curve_start_idx = [3, 5]
    cp = CurvilinearPolygon(pp, curves, curve_start_idx)
    cp += Point(0.0μm, 1.0μm)
    rcp = XReflection()(cp)
    @test_nowarn to_polygons(rcp)

    # Ensure the curve_start_idx are sorted absolutely
    @test issorted(abs.(rcp.curve_start_idx))

    cs = CoordinateSystem("test", nm)
    place!(cs, cp, GDSMeta())
    place!(cs, rcp, GDSMeta())
    @test_nowarn render!(Cell("main", nm), cs)

    # A rounded L shape
    pp =
        Point.([
            (2.00μm, 0.75μm),
            (1.75μm, 1.00μm),
            (1.25μm, 1.00μm),
            (1.00μm, 1.25μm),
            (1.00μm, 1.75μm),
            (0.75μm, 2.00μm),
            (0.25μm, 2.00μm),
            (0.00μm, 1.75μm),
            (0.00μm, 0.50μm),
            (0.50μm, 0.00μm),
            (1.75μm, 0.00μm),
            (2.00μm, 0.25μm)
        ])
    curves = [
        Paths.Turn(90°, 0.25μm, p0=pp[1], α0=π / 2),
        Paths.Turn(-90°, 0.25μm, p0=pp[3], α0=π),
        Paths.Turn(90°, 0.25μm, p0=pp[5], α0=π / 2),
        Paths.Turn(90°, 0.25μm, p0=pp[7], α0=π),
        Paths.Turn(90°, 0.5μm, p0=pp[9], α0=-π / 2),
        Paths.Turn(90°, 0.25μm, p0=pp[11], α0=0.0)
    ]
    curve_start_idx = collect(1:2:11)
    cp = CurvilinearPolygon(pp, curves, curve_start_idx)
    rcp = XReflection()(cp)
    @test_nowarn to_polygons(rcp)

    cs = CoordinateSystem("test", nm)
    place!(cs, cp, GDSMeta())
    place!(cs, rcp, GDSMeta())
    @test_nowarn render!(Cell("main", nm), cs)

    # points are reversed and transformed
    @test all((x -> x.x).(cp.p) .== (x -> x.x).(reverse(rcp.p)))
    @test all((x -> x.y).(cp.p) .== (x -> -x.y).(reverse(rcp.p)))

    # Ensure the curve_start_idx are sorted absolutely
    @test issorted(abs.(rcp.curve_start_idx))
end

@testitem "Hole sorting" setup = [CommonTestSetup] begin
    # Issue #175
    import .Polygons: area
    @testset "Hole sorting" begin
        c1 = rotate(centered(Rectangle(0.5mm, 0.5mm)), 45°) - Point(0mm, 0.5mm)
        c2 = c1 + Point(0mm, 1mm)
        c3 = convert(Polygon, centered(Rectangle(3mm, 3mm)))
        cp = difference2d(c3, [c1, c2])

        c = Cell("test175_mre", mm)
        render!(c, cp, GDSMeta())
        # No regression
        original_area = abs(area(c3)) - abs(area(c1)) - abs(area(c2))
        rendered_area = sum(abs(area(el)) for el in c.elements)
        @test rendered_area ≈ original_area
        # Without fix, positive offset will add too much area because it expands the bad cut
        off = to_polygons(union2d(offset(elements(c), 0.05mm)))
        @test area(only(off)) ≈ (3.1mm)^2 - 2 * (0.4mm)^2
    end

    @testset "Nested holes" begin
        # As with MRE but one hole has holes
        c1 = rotate(centered(Rectangle(0.5mm, 0.5mm)), 45°) - Point(0mm, 0.5mm)
        c2 = c1 + Point(0mm, 1mm)
        c3 = convert(Polygon, centered(Rectangle(3mm, 3mm)))
        c4 = rotate(centered(Rectangle(0.25mm, 0.25mm)), 45°) - Point(0mm, 0.5mm)
        cp = difference2d(c3, [c1, c2])
        cp = difference2d(c3, [difference2d(c1, c4), c2])

        c = Cell("test175_mre", mm)
        render!(c, cp, GDSMeta())

        # no regression: 
        original_area = abs(area(c3)) - abs(area(c1)) - abs(area(c2)) + abs(area(c4))
        rendered_area = sum(abs(area(el)) for el in c.elements)
        @test rendered_area ≈ original_area
        # Check offset area as test for bad cuts
        off = to_polygons(union2d(offset(elements(c), 0.05mm)))
        @test length(off) == 2
        @test area(off[1]) ≈ (0.35mm)^2
        @test area(off[2]) ≈ (3.1mm)^2 - 2 * (0.4mm)^2
    end
end

@testitem "Layerwise clipping" setup = [CommonTestSetup] begin
    c1 = CoordinateSystem("test1")
    c2 = CoordinateSystem("test2")
    r1 = Rectangle(10μm, 10μm)
    r2 = r1 + Point(5μm, 5μm)
    overlap = intersect2d(r1, r2)
    x = xor2d(r1, r2)
    d1 = difference2d(r1, r2)
    d2 = difference2d(r2, r1)
    uni = union2d(r1, r2)
    lyr_a = SemanticMeta(:a)
    lyr_b = SemanticMeta(:b)
    place!(c1, r1, lyr_a)
    place!(c1, r2, lyr_b)
    place!(c2, r1, lyr_b)
    place!(c2, r2, lyr_a)

    @test isempty(to_polygons(xor2d_layerwise(c1, c1)[lyr_a][1]))
    @test isempty(to_polygons(xor2d_layerwise(c1, c1)[lyr_b][1]))
    @test xor2d_layerwise(c1, c2)[lyr_a][1] == x
    @test xor2d_layerwise(c1, c2)[lyr_b][1] == x
    @test difference2d_layerwise(c1, c2)[lyr_a][1] == d1
    @test difference2d_layerwise(c1, c2)[lyr_b][1] == d2
    @test union2d_layerwise(c1, c2)[lyr_a][1] == uni
    @test intersect2d_layerwise(c1, c2)[lyr_b][1] == overlap

    # Findbox
    @test DeviceLayout.findbox(r1, [r1, r2]) == [1]
    @test DeviceLayout.findbox(r1, [r1, r2]; intersects=true) == [1, 2]
    @test DeviceLayout.findbox(r1, [c1]) == []
    @test DeviceLayout.findbox(r1, [r1, c1], intersects=true) == [1, 2]

    # Tiling
    ca_1 = CoordinateSystem("array1")
    ca_2 = CoordinateSystem("array2")
    addref!(ca_1, aref(c1, 100μm * (-1:1), 100μm * (-1:1)))
    addref!(ca_2, aref(c2, 100μm * (-1:1), 100μm * (-1:1)))
    xa = xor2d_layerwise(ca_1, ca_2)
    xa_tiled = xor2d_layerwise(ca_1, ca_2, tile_size=99μm2nm)
    @test length(xa_tiled[lyr_a]) == 3 * 3
    @test length(xa_tiled[lyr_b]) == 3 * 3
    @test length(vcat(to_polygons.(xa_tiled[lyr_a])...)) == 3 * 3 * 2
    @test isempty(to_polygons(xor2d(vcat(xa_tiled[lyr_a]...), xa[lyr_a])))

    # Tiling with entities on edges
    xa_tiled_edges = xor2d_layerwise(ca_1, ca_2, tile_size=106μm2nm)
    @test length(xa_tiled_edges[lyr_a]) == 3 * 3
    @test length(xa_tiled_edges[lyr_b]) == 3 * 3
    all_polys = vcat(to_polygons.(xa_tiled_edges[lyr_a])...)
    # EvenOdd union to remove regions where polygons overlap
    all_no_overlap = clip(
        Polygons.Clipper.ClipTypeUnion,
        all_polys,
        Polygon{typeof(1.0nm)}[],
        pfs=Polygons.Clipper.PolyFillTypeEvenOdd,
        pfc=Polygons.Clipper.PolyFillTypeEvenOdd
    )
    @test length(all_polys) > 3 * 3 * 2 # Some polygons were split
    @test isempty(to_polygons(xor2d(all_polys, xa[lyr_a]))) # Split polygons are still correct
    @test length(to_polygons(all_no_overlap)) == 3 * 3 * 2 # Split polygons are not overlapping
    @test isempty(to_polygons(xor2d(all_no_overlap, xa[lyr_a]))) # Split polygons add up correctly

    # Tiling with empty layers
    uae = union2d_layerwise(ca_1, CoordinateSystem("empty"))
    uae_tiled = union2d_layerwise(ca_1, CoordinateSystem("empty"), tile_size=99μm2nm)
    @test length(vcat(to_polygons.(uae_tiled[lyr_a])...)) == 3 * 3
    @test isempty(to_polygons(xor2d(vcat(uae_tiled[lyr_a]...), ca_1 => lyr_a)))
    uae_tiled = union2d_layerwise(CoordinateSystem("empty"), ca_1, tile_size=99μm2nm)
    @test length(vcat(to_polygons.(uae_tiled[lyr_a])...)) == 3 * 3
    @test isempty(to_polygons(xor2d(vcat(uae_tiled[lyr_a]...), ca_1 => lyr_a)))

    # Auto tile size
    ca_3 = CoordinateSystem("array1")
    ca_4 = CoordinateSystem("array2")
    addref!(ca_3, aref(c1, 100μm * (-10:10), 100μm * (-10:10)))
    addref!(ca_4, aref(c2, 100μm * (-10:10), 100μm * (-10:10)))
    xa_auto_tiled = xor2d_layerwise(ca_3, ca_4, tiled=true)
    @test all(length.(values(xa_auto_tiled)) .== 9) # 9 tiles for about 900 entities

    # Auto tile size is decent for large n
    for n in [12000, 20000, 33000]
        w, l, n = (10mm, 4mm, n)
        l_tile = Polygons._auto_tile_size(Rectangle(w, l), n)
        num_tiles = ceil(w / l_tile) * ceil(l / l_tile)
        @test abs(100 - n / num_tiles) <= 10
    end
    # Works for sub-single-tile
    w, l, n = (400μm, 400μm, 40)
    l_tile = Polygons._auto_tile_size(Rectangle(w, l), n)
    num_tiles = ceil(w / l_tile) * ceil(l / l_tile)
    @test num_tiles == 1
end
