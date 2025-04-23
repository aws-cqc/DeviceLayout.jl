@testset "Gridpoints in polygon" begin
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
end

@testset "Autofill" begin
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
    @test length(origins_2) == 1226

    addref!(cs, cs3)
    h = halo(cs, 1μm)
    pathref = filter(x -> !(x isa CoordinateSystemReference), refs(h))[1]

    # memoization should reuse halo cs
    @test length(unique(structure.(refs(structure(pathref))))) == 1
    @test only(unique(structure.(refs(structure(pathref))))) === structure(refs(h)[end])
end
