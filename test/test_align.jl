@testitem "Alignment" setup = [CommonTestSetup] begin
    r1 = Rectangle(1, 1)
    r2 = Rectangle(Point(-1, -1), Point(2, 3))
    p1 = Polygon(Point(0, -3), Point(2, -1), Point(-1, 3))
    p2 = Polygon(Point(1, 1.5), Point(2, 5), Point(0, 5))

    @test Align.aligned_to(r1, r2, Align.LeftEdge(), Align.RightEdge()) ==
          Rectangle(Point(2, 0), Point(3, 1))
    @test Align.aligned_to(r1, r2, Align.TopEdge(), Align.YCenter()) == r1
    @test Align.aligned_to(
        r1,
        p1,
        (Align.XCenter(), Align.BottomEdge()),
        (Align.LeftEdge(), Align.TopEdge()),
        offset=Point(1, -1)
    ) == Rectangle(Point(-0.5, 2.0), Point(0.5, 3.0))

    @test Align.leftof(p1, r2, centered=true) ==
          Polygon(Point(-3, -2), Point(-1, 0), Point(-4, 4))
    @test Align.rightof(r2, p1) == Rectangle(Point(2, -1), Point(5, 3))
    @test Align.above(r1, r2, centered=true, offset=1.5) ==
          Rectangle(Point(0.0, 4.5), Point(1.0, 5.5))
    @test Align.below(p1, p2) == p1 + Point(0, -1.5)
    @test Align.flushleft(p2, p1) == Polygon(Point(0, 1.5), Point(1, 5), Point(-1, 5))
    @test Align.flushright(r1, r2, centered=true) == Rectangle(Point(1, 0.5), Point(2, 1.5))
    @test Align.flushtop(p2, r1) == Polygon(Point(1, -2.5), Point(2, 1), Point(0, 1))
    @test Align.flushbottom(r1, p2, offset=-1, centered=true) ==
          Rectangle(Point(0.5, 0.5), Point(1.5, 1.5))

    @test Align.centered_on(p2, r2) ==
          Polygon(Point(0.5, -0.75), Point(1.5, 2.75), Point(-0.5, 2.75))
    @test Align.centered_on(r1, p1) == Rectangle(Point(0, -0.5), Point(1, 0.5))

    @test_throws MethodError Align.aligned_to(r1, r2, Align.LeftEdge(), Align.BottomEdge())

    # with units
    r_nm = Rectangle(1000nm, 1000nm)
    r2_um = Rectangle(Point(-1μm, -1μm), Point(2μm, 3μm))
    p_um = Polygon(Point(0μm, -3μm), Point(2μm, -1μm), Point(-1μm, 3μm))
    p2_um = Polygon(Point(1μm, 1.5μm), Point(2μm, 5μm), Point(0μm, 5μm))
    @test Align.aligned_to(
        r_nm,
        p_um,
        (Align.XCenter(), Align.BottomEdge()),
        (Align.LeftEdge(), Align.TopEdge()),
        offset=Point(1μm, -1μm)
    ) ≈ Rectangle(Point(-0.5μm, 2.0μm), Point(0.5μm, 3.0μm))
    @test Align.above(r_nm, r2_um, centered=true, offset=1.5μm) ≈
          Rectangle(Point(0μm, 4.5μm), Point(1.0μm, 5.5μm))
    @test Align.centered_on(p2_um, r2_um) ≈
          Polygon(Point(0.5μm, -0.75μm), Point(1.5μm, 2.75μm), Point(-0.5μm, 2.75μm))
end
