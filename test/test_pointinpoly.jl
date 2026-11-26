@testitem "Gridpoints in polygon" setup = [CommonTestSetup] begin
    import Random
    r1 = Rectangle(2μm, 2μm)
    r2 = r1 + Point(3μm, 0μm)
    r3 = r1 + Point(0μm, 3μm)
    r4 = r1 + Point(3μm, 3μm)

    r0 = Rectangle(1μm, 1μm)

    # Corners and edges
    poly = [r1, r2, r3, r4]
    inpoly = Polygons.gridpoints_in_polygon(poly, 1μm, 1μm)
    @test count(inpoly) == 36

    # Overlapping polygons
    poly = [r1, r1, r4, r4]
    inpoly = Polygons.gridpoints_in_polygon(poly, 1μm, 1μm)
    @test count(inpoly) == 18

    poly = [r1, r1 + Point(0.5, 0.5)μm, r4, r4 + Point(0.5, 0.5)μm]
    inpoly = Polygons.gridpoints_in_polygon(poly, 1μm, 1μm)
    @test count(inpoly) == 18

    # Bounding box
    poly = [r1, r4]
    rb = Rectangle(Point(1μm, 1μm), Point(5μm, 5μm))
    inpoly = Polygons.gridpoints_in_polygon(poly, 1μm, 1μm, b=rb)
    @test count(inpoly) == 13

    rb = Rectangle(Point(1μm, 1μm), Point(4μm, 4μm))
    inpoly = Polygons.gridpoints_in_polygon(poly, 1μm, 1μm, b=rb)
    @test count(inpoly) == 8

    rb = Rectangle(Point(-1μm, -1μm), Point(5μm, 5μm))
    inpoly = Polygons.gridpoints_in_polygon(poly, 1μm, 1μm, b=rb)
    @test count(inpoly) == 18

    # Origin
    rb = Rectangle(Point(-1μm, -1μm), Point(4μm, 5μm))
    inpoly = Polygons.gridpoints_in_polygon(poly, 1μm, 1μm, b=rb)
    @test count(inpoly) == 15

    inpoly = Polygons.gridpoints_in_polygon(poly, 1μm, 1μm, b=rb + (rb.ur - rb.ll))
    @test count(inpoly) == 2

    inpoly = Polygons.gridpoints_in_polygon(poly, 1μm, 1μm, b=rb + 2 * (rb.ur - rb.ll))
    @test count(inpoly) == 0

    # Units
    rb = Rectangle(Point(-1μm, -1μm), Point(6μm, 6μm))
    inpoly = Polygons.gridpoints_in_polygon(poly, 1000nm, 1000nm, b=rb)
    @test count(inpoly) == 18

    inpoly = Polygons.gridpoints_in_polygon(poly, 0.001mm, 0.001mm, b=rb)
    @test count(inpoly) == 18

    inpoly = Polygons.gridpoints_in_polygon(poly, 0.5μm, 0.5μm, b=rb)
    @test count(inpoly) == 50

    # Cutouts
    poly =
        [difference2d(r1, r0 + Point(0.5, 0.5)μm), difference2d(r2, r0 + Point(3.5, 0.5)μm)]
    inpoly = Polygons.gridpoints_in_polygon(poly, 1μm, 1μm)
    @test count(inpoly) == 16

    r_05 = Rectangle(0.5μm, 0.5μm)
    poly = [
        difference2d(r1, r_05 + Point(1.0, 1.0)μm),
        difference2d(r2, r_05 + Point(4.0, 1.0)μm)
    ]
    inpoly = Polygons.gridpoints_in_polygon(poly, 1μm, 1μm)
    @test count(inpoly) == 18

    # Edge case
    cr = Cell("rect", nm)
    r = centered(Rectangle(20μm, 40μm))
    render!(cr, r, GDSMeta(1, 0))
    r2 = Align.flushtop(Rectangle(10μm, 30μm), r, centered=true)
    u = difference2d(r, r2)
    rotate90 = Rotation(90°)
    render!(cr, Align.rightof(rotate90(u), r), GDSMeta(2))

    dx = 7.8μm
    dy = 7.8μm
    b = bounds(cr)
    grid_x = (Int(ceil(b.ll.x / dx)):Int(floor(b.ur.x / dx))) * dx
    grid_y = (Int(ceil(b.ll.y / dy)):Int(floor(b.ur.y / dy))) * dy
    poly = cr.elements
    in_poly = gridpoints_in_polygon(poly, dx, dy)
    @test count((!).(in_poly)) == 14
    @test all(in_poly .== gridpoints_in_polygon(poly, dx, dy))

    # On-edge grid point with floating-point round-off in the edge crossing.
    # The slanted edge (0, 0)->(0.2μm, 0.4μm) has slope 1/2 and passes exactly
    # through the grid point (0.1μm, 0.2μm). The crossing x = 0.2*(0.2/0.4) is
    # evaluated as 0.10000000000000002, just above 0.1μm, so `searchsortedfirst`
    # returns the next grid point. The on-edge point must still be counted as
    # inside, which requires checking both grid points bracketing the crossing.
    tri =
        Polygon(Point(0.0, 0.0)μm, Point(0.2, 0.4)μm, Point(0.6, 0.4)μm, Point(0.6, 0.0)μm)
    @test Polygons.gridpoints_in_polygon([tri], [0.1]μm, [0.2]μm)[1, 1]

    # Vertices at y = -0.0 behave like those at y = 0.0 on the grid row y = 0.0
    apex(y0) = Polygon(Point(0.0, y0), Point(2.0, 2.0), Point(-2.0, 2.0))
    square(y0) = Polygon(Point(0.0, y0), Point(2.0, y0), Point(2.0, 2.0), Point(0.0, 2.0))
    for shape in (apex, square)
        @test Polygons.gridpoints_in_polygon([shape(-0.0)], -1.0:2.0, [0.0, 1.0]) ==
              Polygons.gridpoints_in_polygon([shape(0.0)], -1.0:2.0, [0.0, 1.0])
    end

    # A grid too large for one block of rows, unsorted, against a direct winding count.
    # Polygons overlap, one is clockwise, and every grid point is over 1e-4 from an edge.
    winding(p, pts) =
        sum(eachindex(pts)) do i
            a, b = pts[i], pts[mod1(i + 1, length(pts))]
            (a.y <= p.y) == (b.y <= p.y) && return 0
            side = (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y)
            return b.y > a.y ? Int(side > 0) : -Int(side < 0)
        end
    star(c, r1, r2) =
        Polygon([c + (isodd(k) ? r1 : r2) * Point(cospi(k / 7), sinpi(k / 7)) for k = 0:13])
    poly = [
        star(Point(-149.91, 20.7), 330.1, 120.9),
        star(Point(170.99, -40.2), 280.3, 90.4),
        Polygon(reverse(points(star(Point(30.59, 10.1), 140.7, 60.3))))
    ]
    grid_x, grid_y = reverse(-400:400), reverse(-350:350)
    expected = [
        sum(p -> winding(Point(x, y), points(p)), poly) != 0 for x = -400:400, y = -350:350
    ]
    @test count(expected) > 0
    @test Polygons.gridpoints_in_polygon(poly, grid_x, grid_y) == expected
    # Smaller blocks and the spawning path. Tasks on one thread don't run concurrently.
    @test Polygons._gridpoints_in_polygon(poly, grid_x, grid_y, 3) == expected
    # Many small blocks on a narrow grid, so neighboring blocks share words of the result.
    # Can fail only with two or more threads.
    tall_x, tall_y = range(-400, 400, length=7), range(-350, 350, length=20001)
    one_task = Polygons._gridpoints_in_polygon(poly, tall_x, tall_y, 1)
    @test all(
        _ -> Polygons._gridpoints_in_polygon(poly, tall_x, tall_y, 64) == one_task,
        1:50
    )

    sq = [Polygon(Point(0.0, 0.0), Point(2.0, 0.0), Point(2.0, 2.0), Point(0.0, 2.0))]
    # Rows are compared with edges in the grid's float type, so the grid point at 2^53 + 4,
    # above the top edge at 2^53 + 3, counts as inside: both round to 2^53 + 4.
    tall = [Polygon(Point(0, 0), Point(10, 0), Point(10, 2^53 + 3), Point(0, 2^53 + 3))]
    @test Polygons.gridpoints_in_polygon(tall, [5], [2^53 + 4])[1, 1]
    # Empty grids
    @test Polygons.gridpoints_in_polygon(sq, Float64[], [1.0]) == falses(0, 1)
    @test Polygons.gridpoints_in_polygon(sq, [1.0], Float64[]) == falses(1, 0)
    # An empty grid with an abstract element type, next to a concretely typed one
    @test Polygons.gridpoints_in_polygon(sq, [], [1.0]) == falses(0, 1)
    @test Polygons.gridpoints_in_polygon(sq, [1.0], Union{}[]) == falses(1, 0)
    sq_μm = [
        Polygon(Point(0.0, 0.0)μm, Point(2.0, 0.0)μm, Point(2.0, 2.0)μm, Point(0.0, 2.0)μm)
    ]
    @test Polygons.gridpoints_in_polygon(sq_μm, Quantity{Float64, Unitful.𝐋}[], [1.0μm]) ==
          falses(0, 1)
    # Grid values in mixed units that compare equal but are out of order once converted to
    # the polygons' unit: each row still gets its own value's result
    apex_y = prevfloat(1.0)μm
    tip = [Polygon(Point(0.0μm, apex_y), Point(-1.0μm, 2.0μm), Point(1.0μm, 2.0μm))]
    flat = [Polygon(Point(-1.0μm, apex_y), Point(1.0μm, apex_y), Point(0.5μm, apex_y))]
    mixed_y = Quantity{Float64, Unitful.𝐋}[1.0μm, 999.9999999999999nm]
    @test Polygons.gridpoints_in_polygon(tip, [0.0μm], mixed_y) == [true false]
    @test Polygons.gridpoints_in_polygon(flat, [0.0μm], mixed_y) == [false true]
    # The same with `grid_x` out of order too: its rows stay in the order of `sort(grid_x)`
    tri = [Polygon(Point(1.0μm, 1.0μm), Point(0.0μm, -1.0μm), Point(0.0μm, 0.0μm))]
    mixed_x = Quantity{Float64, Unitful.𝐋}[-0.0nm, -5.0e-324μm]
    mixed_y3 = Quantity{Float64, Unitful.𝐋}[-0.0nm, 0.5000000000000001μm, 500.0nm]
    @test Polygons.gridpoints_in_polygon(tri, mixed_x, mixed_y3) == falses(2, 3)
    # Duplicated rows on a horizontal edge
    @test Polygons.gridpoints_in_polygon(sq, [1.0], [0.0, 0.0, 1.0]) == trues(1, 3)
    # An empty clip result, alone and with another polygon
    r = Rectangle(2μm, 2μm)
    grid = [0.5, 1.0, 3.0]μm
    @test Polygons.gridpoints_in_polygon([difference2d(r, r)], grid, grid) == falses(3, 3)
    @test Polygons.gridpoints_in_polygon([difference2d(r, r), union2d(r)], grid, grid) ==
          Polygons.gridpoints_in_polygon([r], grid, grid)

    # The per-row rule, as a linear scan over all edges
    function row_rule(polys, xs, ys)
        xs, ys = sort(xs), sort(ys)
        in_poly = falses(length(xs), length(ys))
        for (iy, y) in enumerate(ys)
            winding = zeros(Int, length(xs) + 1)
            for pts in points.(polys), i in eachindex(pts)
                p0, p1 = pts[i], pts[mod1(i + 1, length(pts))]
                min(p0.y, p1.y) <= y <= max(p0.y, p1.y) || continue
                if p0.y == p1.y
                    lo = searchsortedfirst(xs, min(p0.x, p1.x))
                    in_poly[lo:searchsortedlast(xs, max(p0.x, p1.x)), iy] .= true
                    continue
                end
                min(p0.y, p1.y) == y && continue
                x = p0.x + (p1.x - p0.x) * (y - p0.y) / (p1.y - p0.y)
                k = searchsortedfirst(xs, x)
                for j in (k - 1, k)
                    1 <= j <= length(xs) && isapprox(x, xs[j]) && (in_poly[j, iy] = true)
                end
                winding[1:(k - 1)] .+= Int(sign(p1.y - p0.y))
            end
            in_poly[:, iy] .|= winding[1:length(xs)] .!= 0
        end
        return in_poly
    end
    # Points on edges and vertices, horizontal edges, `±0.0` and duplicated grid values,
    # with the default tasks and with 3 tasks (one-row blocks here)
    rng = Random.MersenneTwister(1)
    lattice = [-1.0, -0.0, 0.0, 1 / 3, 0.5, 1.0, 2.0]
    for _ = 1:500
        polys = [
            Polygon([
                Point(rand(rng, lattice), rand(rng, lattice)) for _ = 1:rand(rng, 3:6)
            ]) for _ = 1:rand(rng, 1:3)
        ]
        xs = rand(rng, lattice, rand(rng, 1:8))
        ys = rand(rng, lattice, rand(rng, 1:8))
        rule = row_rule(polys, xs, ys)
        @test Polygons.gridpoints_in_polygon(polys, xs, ys) == rule
        @test Polygons._gridpoints_in_polygon(polys, xs, ys, 3) == rule
    end
end

@testitem "Autofill" setup = [CommonTestSetup] begin
    cs = CoordinateSystem("autofill", nm)

    # Add Path with attachments
    pa = Path(0μm, -100μm)
    turn!(pa, π, 100μm, Paths.SimpleCPW(10μm, 6μm))

    cs3 = CoordinateSystem("attachment", nm)
    render!(cs3, centered(Rectangle(2μm, 50μm)), GDSMeta())
    attach!(pa, sref(cs3), (0μm):(20μm):pathlength(pa))

    render!(cs, pa, SemanticMeta(:base_negative))

    # NoRender segment should have no effect
    pa2 = Path(-100μm, 0μm)
    straight!(pa2, 100μm, Paths.NoRender())
    render!(cs, pa2, SemanticMeta(:base_negative))

    # Add coordinate system reference
    cs2 = CoordinateSystem("internal", nm)
    render!(cs2, Rectangle(10μm, 10μm), SemanticMeta(:base_negative))
    addref!(cs, cs2)

    # Test autofill
    filler = CoordinateSystem("filler", nm)
    render!(filler, centered(Rectangle(2μm, 2μm)), SemanticMeta(:fill))

    grid_x = (-16:8:120)μm
    grid_y = (-120:8:120)μm
    origins = autofill!(cs, filler, grid_x, grid_y, 5μm)
    @test length(origins) == 314
    pathref = filter(x -> !(x isa CoordinateSystemReference), refs(cs))[1]
    @test length(unique(structure.(refs(structure(pathref))))) == 1

    c1 = Cell("ex", nm)
    c2 = Cell("ref", nm)
    render!(c1, pa, GDSMeta(1))
    render!(c2, cs2, map_meta=(_) -> GDSMeta(1))
    filler = Cell(filler, map_meta=(_) -> GDSMeta(2))
    addref!(c1, c2)
    origins_cell = autofill!(c1, filler, grid_x, grid_y, 5μm)
    @test all(origins_cell .== origins)

    # Autofill a second time with different parameters
    grid_x2 = (-16:4:120)μm
    grid_y2 = (-120:4:120)μm
    filler2 = CoordinateSystem("filler2", nm)
    render!(filler2, centered(Rectangle(1μm, 1μm)), SemanticMeta(:fill))
    hfunc = make_halo(1μm)
    origins_2 = autofill!(cs, filler2, grid_x2, grid_y2, hfunc)
    # The count is 1226 or 1227 depending on a boundary tie-break: grid point (112μm, 0)
    # lies on the outer rim of the turn's halo, which is a discretized curve. Whether
    # that point lands exactly on a halo edge (counted as inside) or just off it (filled)
    # depends on sub-nm vertex placement, so the fill count is not uniquely determined.
    @test length(origins_2) in (1226, 1227)

    addref!(cs, cs3)
    h = halo(cs, 1μm)
    pathref = filter(x -> !(x isa CoordinateSystemReference), refs(h))[1]

    # memoization should reuse halo cs
    @test length(unique(structure.(refs(structure(pathref))))) == 1
    @test only(unique(structure.(refs(structure(pathref))))) === structure(refs(h)[end])
end
