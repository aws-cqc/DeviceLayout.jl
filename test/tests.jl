@testset "Points" begin
    @testset "> Point constructors" begin
        @test_throws ErrorException Point(2, 3m2μm)
        @test_throws ErrorException Point(2s, 3s)    # has to be a length
        @test typeof(Point(2, 3)) == Point{Int}
        @test typeof(Point(2, 3.0)) == Point{Float64}
        @test typeof(Point(2.0, 3)) == Point{Float64}
        @test typeof(Point(2m2μm, 3.0m2μm)) == Point{typeof(3.0m2μm)}
        @test typeof(Point(2m2μm, 3cm2μm)) == Point{typeof(2μm2μm)}
        @test typeof(Point(2.0m2μm, 3cm2μm)) == Point{typeof(2.0μm2μm)}
        @test typeof(Point(2m2nm, 3.0m2nm)) == Point{typeof(3.0m2nm)}
        @test typeof(Point(2m2nm, 3cm2nm)) == Point{typeof(2nm2nm)}
        @test typeof(Point(2.0m2nm, 3cm2nm)) == Point{typeof(2.0nm2nm)}
        @test typeof(Point(1.0 / μm2μm, 1.0 / nm2μm)) == Point{typeof(1.0 / μm2μm)}
        @test typeof(Point(1.0 / μm2nm, 1.0 / nm2nm)) == Point{typeof(1.0 / nm2nm)}
        @test typeof(Point(1.0nm / μm, 1.0nm / μm)) == Point{Float64}
        @test typeof(Point(1nm / μm, 1nm / μm)) == Point{Rational{Int}}
    end

    @testset "> Point arithmetic" begin
        @test Point(2, 3) + Point(4, 5) === Point(6, 8)
        @test Point(1, 0) - Point(0, 1) === Point(1, -1)
        @test Point(3, 3) / 3 === Point(1.0, 1.0)
        @test Point(1, 1) * 3 === Point(3, 3)
        @test 3 * Point(1, 1) === Point(3, 3)
        @test Point(2m2μm, 3m2μm) + Point(4m2μm, 5m2μm) === Point(6m2μm, 8m2μm)
        @test Point(2m2μm, 3m2μm) + Point(4cm2μm, 5cm2μm) ===
              Point(2040000μm2μm, 3050000μm2μm)
        @test Point(2.0m2μm, 3m2μm) + Point(4cm2μm, 5cm2μm) ===
              Point(2040000.0μm2μm, 3050000.0μm2μm)
        @test Point(2m2nm, 3m2nm) + Point(4m2nm, 5m2nm) === Point(6m2nm, 8m2nm)
        @test Point(2m2nm, 3m2nm) + Point(4cm2nm, 5cm2nm) ===
              Point(2040000000nm2nm, 3050000000nm2nm)
        @test Point(2.0m2nm, 3m2nm) + Point(4cm2nm, 5cm2nm) ===
              Point(2040000000.0nm2nm, 3050000000.0nm2nm)
        # Robust predicates
        @test DeviceLayout.orientation(Point(0.0, 0.0), Point(1.0, 1.0), Point(2.0, 2.0)) ==
              0.0
        @test DeviceLayout.orientation(
            Point(0.0, 1e-40),
            Point(1.0, 1.0),
            Point(2.0, 2.0)
        ) == 1.0
    end

    @testset "> Point array arithmetic" begin
        @test [Point(1, 2), Point(3, 4)] .+ Point(1, 1) == [Point(2, 3), Point(4, 5)]
        @test Point(1, 1) .+ [Point(1, 2), Point(3, 4)] == [Point(2, 3), Point(4, 5)]
        @test [Point(1, 2), Point(3, 4)] + [Point(1, 1), Point(-1, 2)] ==
              [Point(2, 3), Point(2, 6)]

        @test [Point(1, 2), Point(3, 4)] .- Point(1, 1) == [Point(0, 1), Point(2, 3)]
        @test Point(1, 1) .- [Point(1, 2), Point(2, 3)] == [Point(0, -1), Point(-1, -2)]
        @test [Point(2, 3)] - [Point(1, 3)] == [Point(1, 0)]
        @test_throws DimensionMismatch Point(1, 2) - [Point(1, 0)]
        @test_throws DimensionMismatch [Point(2, 3)] - Point(1, 0)
        @test_throws DimensionMismatch Point(1, 2) + [Point(3, 4)]
        @test_throws DimensionMismatch [Point(1, 2)] + Point(3, 4)

        @test [Point(1, 3)] .* 3 == [Point(3, 9)]
        @test [Point(1, 3)] * 3 == [Point(3, 9)]
        @test 3 .* [Point(1, 3)] == [Point(3, 9)]
        @test 3 * [Point(1, 3)] == [Point(3, 9)]

        @test [Point(1m2μm, 2m2μm)] + [Point(1cm2μm, 2cm2μm)] ==
              [Point(101000000μm2μm // 100, 202000000μm2μm // 100)]
        @test [Point(1m2μm, 2m2μm)] .+ Point(1cm2μm, 2cm2μm) ==
              [Point(101000000μm2μm // 100, 202000000μm2μm // 100)]
        @test [Point(1m2μm, 2m2μm)] - [Point(1cm2μm, 2cm2μm)] ==
              [Point(99000000μm2μm // 100, 198000000μm2μm // 100)]
        @test [Point(1m2μm, 2m2μm)] .- Point(1cm2μm, 2cm2μm) ==
              [Point(99000000μm2μm // 100, 198000000μm2μm // 100)]

        @test [Point(1m2nm, 2m2nm)] + [Point(1cm2nm, 2cm2nm)] ==
              [Point(101000000000nm2nm // 100, 202000000000nm2nm // 100)]
        @test [Point(1m2nm, 2m2nm)] .+ Point(1cm2nm, 2cm2nm) ==
              [Point(101000000000nm2nm // 100, 202000000000nm2nm // 100)]
        @test [Point(1m2nm, 2m2nm)] - [Point(1cm2nm, 2cm2nm)] ==
              [Point(99000000000nm2nm // 100, 198000000000nm2nm // 100)]
        @test [Point(1m2nm, 2m2nm)] .- Point(1cm2nm, 2cm2nm) ==
              [Point(99000000000nm2nm // 100, 198000000000nm2nm // 100)]
    end

    @testset "> Point accessors" begin
        @test getx(Point(1, 2)) == 1
        @test gety(Point(1, 2)) == 2
    end

    @testset "> Point conversion" begin
        @test [Point(1, 3), Point(2, 4)] .* m2μm ==
              [Point(1m2μm, 3m2μm), Point(2m2μm, 4m2μm)]
        @test convert(Point{Float64}, Clipper.IntPoint(1, 2)) == Point(1.0, 2.0)
        @test convert(Point{Int}, Clipper.IntPoint(1, 2)) == Point(1, 2)
    end

    @testset "> Point promotion" begin
        @test promote_type(typeof(Point(1, 2)), typeof(Point(1μm / nm, 1μm / nm))) ==
              Point{Int}
        @test promote_type(typeof(Point(1, 2)), typeof(Point(1μm / nm, 1nm / μm))) ==
              Point{Rational{Int}}
        @test promote_type(
            typeof(Point(1.0nm2μm, 2.0nm2μm)),
            typeof(Point(1.0cm2μm, 1.0cm2μm))
        ) == Point{typeof(1.0μm2μm)}
        @test promote_type(
            typeof(Point(1.0 / nm2μm, 2.0 / nm2μm)),
            typeof(Point(1.0 / cm2μm, 1.0 / cm2μm))
        ) == Point{typeof(1.0 / μm2μm)}
    end
end

@testset "Preferences" begin
    @test DeviceLayout.unit_preference == "PreferNanometers"
    @test_throws ArgumentError DeviceLayout.set_unit_preference!("Nanometers")
    DeviceLayout.set_unit_preference!("PreferMicrons"; local_only=false) # triggers @info, just ignore
    @test DeviceLayout.load_preference(DeviceLayout, "units") == "PreferMicrons"
    DeviceLayout.set_unit_preference!("PreferNanometers") # local_only => will override
    @test DeviceLayout.load_preference(DeviceLayout, "units") == "PreferNanometers"
end

@testset "Polygon basics" begin
    @testset "> Rectangle construction" begin
        # lower-left and upper-right constructor
        r = Rectangle(Point(1, 2), Point(2, 0))
        @test typeof(r) == Rectangle{Int}
        @test r.ll == Point(1, 0)
        @test r.ur == Point(2, 2)

        # with units
        # @test typeof(Rectangle(Point(1m,2cm), Point(3nm,4μm))) ==
        # Rectangle{typeof(1ru//1)} #TODO: uncomment once Julia #18465 is fixed

        # width and height constructor
        @test typeof(Rectangle(1, 2)) == Rectangle{Int}
        @test typeof(Rectangle(1.0, 2)) == Rectangle{Float64}
        @test typeof(Rectangle(1.0m2μm, 2.0μm2μm)) == Rectangle{typeof(1.0 * μm2μm)}
    end

    @testset "> Polygon construction" begin
        @test_throws ErrorException Polygon(Point(1, 2), Point(3, 5), Point(4cm2μm, 7cm2μm))
    end

    @testset "> Rectangle methods" begin
        # width and height
        @test width(Rectangle(1, 2)) === 1
        @test height(Rectangle(1, 2)) === 2
        @test width(Rectangle(1m, 2m)) === 1m
        @test height(Rectangle(1m, 2m)) === 2m

        # propriety
        @test Rectangle(Point(3, 3), Point(0, 0)) == Rectangle(Point(0, 0), Point(3, 3))
        @test isproper(Rectangle(3, 3))
        @test !isproper(Rectangle(0, 0))

        # centering
        @test centered(Rectangle(1, 1)) == Rectangle(Point(-0.5, -0.5), Point(0.5, 0.5))

        # Rectangle equality
        @test Rectangle(1, 2) == Rectangle(1, 2)
        @test Rectangle(1, 2) ≈ Rectangle(1, 2)

        # Rectangle bounds
        @test bounds(Rectangle(1, 2)) == Rectangle(1, 2)
    end

    @testset "> Polygon methods" begin
        pfloat = Polygon(Point(0.0m, 0.0m), Point(1.0m, 0.0m), Point(0.0m, 1.0m))
        # Polygon equality
        @test pfloat == Polygon(Point(0.0m, 0.0m), Point(1.0m, 0.0m), Point(0.0m, 1.0m))
        @test pfloat ≈ Polygon(Point(0.0m, 0.0m), Point(1.0m, 0.0m), Point(0.0m, 1.0m))

        # Bounds
        @test bounds(pfloat) ≈ Rectangle(1m, 1m)

        # Perimeter
        @test perimeter(pfloat) ≈ (2 + sqrt(2))m
        badpoly = Polygon(Point{Float64}[])
        @test perimeter(badpoly) == 0.0
    end
end

@testset "Polygon coordinate transformations" begin
    pfloat = Polygon(Point(0.0m, 0.0m), Point(1.0m, 0.0m), Point(0.0m, 1.0m))
    pint = Polygon(Point(0m, 0m), Point(1m, 0m), Point(0m, 1m))
    rfloat = Rectangle(1.0m, 1.0m)
    rint = Rectangle(1m, 1m)
    pfloatrot = Polygon(Point(0.0m, 0.0m), Point(0.0m, 1.0m), Point(-1.0m, 0.0m))
    pfloattr = Polygon(Point(1.0m, 2.0m), Point(2.0m, 2.0m), Point(1.0m, 3.0m))
    rotDeg = Rotation(90°)
    rotRad = Rotation(π / 2 * rad)
    rotFlt = Rotation(π / 2)
    rotPi2 = RotationPi(1 / 2)
    trU = Translation(1m, 2m)
    @test rotDeg(pfloat) ≈ pfloatrot
    @test rotRad(pfloat) ≈ pfloatrot
    @test rotFlt(pfloat) ≈ pfloatrot
    @test rotDeg(pint) ≈ pfloatrot
    @test rotRad(pint) ≈ pfloatrot
    @test rotFlt(pint) ≈ pfloatrot
    @test rotPi2(pfloat) == pfloatrot
    @test rotPi2(pint) == pfloatrot
    @test trU(pfloat) ≈ pfloattr
    @test trU(pint) ≈ pfloattr
    @test isnothing(origin(rotFlt))
    @test origin(XReflection() ∘ trU) == Point(1m, -2m)
    @test Transformations.preserves_angles(trU)
    @test mag(trU) == 1
    @test mag(Transformations.LinearMap([2 0; 0 2])) == 2
    @test_throws DomainError mag(Transformations.LinearMap([2 1; 1 1]))
    @test Transformations.preserves_angles(rotFlt)
    @test reflect_across_line(rfloat, 90°) == rfloat - Point(1.0m, 0.0m)
    @test reflect_across_line(rfloat, Point(0, 0)m, Point(1, 0)m) ==
          rfloat - Point(0.0m, 1.0m)
    @test rfloat * 2 == Rectangle(4.0m, 4.0m) / 2

    @test rotDeg == ScaledIsometry(rotDeg)
    @test Transformations.rounding_safe(typeof(1nm), rotPi2)
    @test isapprox_cardinal(3π / 2)
    @test isapprox_angle(7π / 2, -90°)
    @test ScaledIsometry(rotDeg)(pint) ≈ pfloatrot
    @test trU ∘ (ScaledIsometry(XReflection()) ∘ ScaledIsometry(rotDeg)) ≈
          trU ∘ XReflection() ∘ rotDeg
    @test Rotation(3pi / 2)(Rectangle(1, 2)) isa Rectangle

    id = Transformations.LinearMap(Transformations.@SMatrix [1 0; 0 1])
    @test id ≈ inv(ScaledIsometry(nothing, 180°, false, -1.0)) # negative mag is pi rotation

    xr1_yr1 =
        Reflection(Point(1, 1)m, Point(0, 1)m) ∘ Reflection(Point(1, 0)m, Point(1, 1)m)
    @test Rotation(π, around_pt=Point(1m, 1m)) ≈ xr1_yr1
    @test RotationPi(1, around_pt=Point(1m, 1m)) ≈ xr1_yr1

    pfloatref = Polygon(Point(0.0m, 1.0m), Point(-1.0m, 0.0m), Point(0.0m, 0.0m))
    pintref = Polygon(Point(0m, 1m), Point(-1m, 0m), Point(0m, 0m))
    @test Reflection(Point(0.0m, 1.0m))(pfloat) ≈ pfloatref
    @test Reflection(Point(0m, 1m))(pint) ≈ pintref
    @test Reflection(Point(0m, 1m)).linear ==
          Reflection(Point(0m, 2m), Point(0m, 4m)).linear

    @test Reflection(Point(0.0m, 1.0m))(pfloat) ≈ pfloatref
    @test Reflection(90°)(pint) ≈ pintref

    tr = ScaledIsometry(Point(1, 2), 90°, true, 2.0)
    io = IOBuffer()
    show(io, tr)
    @test preserves_angles(tr)
    @test contains(String(take!(io)), "XReflection")
    @test id == tr ∘ inv(tr)
    @test tr ∘ inv(tr) == id
    @test tr ∘ Transformations.IdentityTransformation() ==
          Transformations.IdentityTransformation() ∘ tr
    @test origin(Translation(-Point(1, 2)) ∘ tr) == Point(0, 0)

    proj = Transformations.LinearMap(Transformations.@SMatrix [1 0; 0 0])
    @test tr ∘ proj != proj ∘ tr

    @test !xrefl(rotDeg)
    @test !xrefl(trU)
    @test xrefl(rotFlt ∘ XReflection() ∘ rotDeg ∘ trU)
    @test !xrefl(rotFlt ∘ YReflection() ∘ trU ∘ XReflection() ∘ rotDeg)

    tr = convert(ScaledIsometry{Nothing}, ScaledIsometry())
    @test iszero(@allocated tr2 = convert(ScaledIsometry{Nothing}, tr))
    @test convert(ScaledIsometry{Point{Int}}, tr).origin isa Point{Int}
    @test hash(ScaledIsometry()) == hash(ScaledIsometry(Point(0, 0)))

    # Point vector unfolding
    ux = Point(1, 0)
    uy = Point(0, 1)
    # Ints
    pts = [Point(-1, 0), Point(-1, 1)]
    @test unfold(pts, uy) ≈ [Point(-1, 0), Point(-1, 1), Point(1, 1), Point(1, 0)]
    # Floats
    pts = [Point(-1.0, 0.0), Point(-1.0, 1.0)]
    @test unfold(pts, uy) ≈
          [Point(-1.0, 0.0), Point(-1.0, 1.0), Point(1.0, 1.0), Point(1.0, 0.0)]
    # Mixed Ints/Floats
    pts = [Point(-1, 0), Point(-1, 1)]
    @test unfold(pts, Point(0.0, 1.0)) ≈
          [Point(-1.0, 0.0), Point(-1.0, 1.0), Point(1.0, 1.0), Point(1.0, 0.0)]
    # x-axis reflection
    pts = [Point(-1, -1), Point(1, -1)]
    @test unfold(pts, ux) ≈ [Point(-1, -1), Point(1, -1), Point(1, 1), Point(-1, 1)]
    # With units
    pts = [Point(-1μm, 0μm), Point(-1μm, 1μm)]
    @test unfold(pts, uy) ≈
          [Point(-1μm, 0μm), Point(-1μm, 1μm), Point(1μm, 1μm), Point(1μm, 0μm)]
    @test unfold(pts, uy * μm) ≈
          [Point(-1μm, 0μm), Point(-1μm, 1μm), Point(1μm, 1μm), Point(1μm, 0μm)]
    # With angle instead of vector
    @test unfold(pts, 90°) ≈
          [Point(-1μm, 0μm), Point(-1μm, 1μm), Point(1μm, 1μm), Point(1μm, 0μm)]
    # Axis by two points
    @test unfold(pts, Point(0μm, 0μm), Point(0μm, 1μm)) ≈
          [Point(-1μm, 0μm), Point(-1μm, 1μm), Point(1μm, 1μm), Point(1μm, 0μm)]
    # Less trivial case (off-center axis)
    @test unfold(pts, Point(1μm, 0μm), Point(1μm, 1μm)) ≈
          [Point(-1μm, 0μm), Point(-1μm, 1μm), Point(3μm, 1μm), Point(3μm, 0μm)]
end

@testset "Polygon rendering" begin
    @testset "Rectangle rendering" begin
        c3 = Cell{Float64}("c3")
        r = Rectangle(5, 10)
        @test_throws Unitful.DimensionError render!(c3, Rectangle(5m, 10m), GDSMeta())
    end
end

@testset "Intersections" begin
    @test promote(Polygons.Line(p(0, 0), p(1, 1)), Polygons.Line(p(1.0, 0.0), p(2, 0))) ===
          (Polygons.Line(p(0.0, 0.0), p(1.0, 1.0)), Polygons.Line(p(1.0, 0.0), p(2.0, 0.0)))
    @test promote(
        Polygons.Line(p(0, 0)μm2μm, p(1, 1)μm2μm),
        Polygons.Line(p(1.0, 0.0)nm2μm, p(2.0, 0.0)nm2μm)
    ) === (
        Polygons.Line(p(0.0, 0.0)μm2μm, p(1.0, 1.0)μm2μm),
        Polygons.Line(p(0.001, 0.0)μm2μm, p(0.002, 0.0)μm2μm)
    )

    ls = Polygons.LineSegment(Point(0, 0), Point(1.0, 1.0))
    l = Polygons.Line(ls)
    r = Polygons.Ray(Point(0, 0), Point(1.0, 1.0))
    @test Polygons.iscolinear(Point(2, 2), ls)
    @test Polygons.intersects(Point(2, 2), r)
    @test !(Polygons.intersects(Point(2, 2), ls))
    @test !(Polygons.intersects(Point(2, 0), ls))
    @test Polygons.intersects(Point(1, 1), ls)
end

@testset "Cell methods" begin
    # Setup nested cell refs
    c = Cell{Float64}("main")
    c2 = Cell{Float64}("c2")
    c3 = Cell{Float64}("c3")
    c2ref = StructureReference(c2, Point(-10.0, 0.0); mag=1.0, rot=180°)
    c3ref = StructureReference(c3, Point(10.0, 0.0); mag=2.0, rot=90°)

    @test bounds(c3) == Rectangle(0, 0)
    @test !isproper(bounds(c3))
    @test cell(c2ref) === c2
    @test bounds(c2ref) == Rectangle(0, 0) + Point(-10.0, 0.0)

    r = Rectangle(5, 10)
    render!(c3, r, GDSMeta())
    push!(c.refs, c2ref)
    push!(c2.refs, c3ref)
    tr = transformation(c, c3ref)

    # Test cell transformations
    @test tr(Point(1, 1)) ≈ Point(-18.0, -2.0)
    @test c["c2"]["c3"] == c3ref
    c′ = c + Point(10.0, 10.0)
    c2ref′ = c2ref + Point(10.0, 10.0)

    # Test bounds with cell refs
    @test bounds(c3) == r
    @test bounds(c2) == bounds(c3ref)
    @test bounds(c) == bounds(c2ref)
    @test bounds(c′) ≈ (bounds(c) + Point(10.0, 10.0))
    @test bounds(c2ref′) ≈ (bounds(c2ref) + Point(10.0, 10.0))

    # Test `flatten!` when encountering a CellReference
    let c2 = flatten(c; name="flat_ref")
        @test name(c2) == "flat_ref"
        @test bounds(c) == bounds(c2ref)
    end
    let c2 = flatten(c; depth=1)
        @test isempty(elements(c2))
        @test c2.refs[1].rot ≈ 270°
        @test c2.refs[1].origin ≈ Point(-20.0, 0.0)
    end
    @test flatten!(c) === c
    @test bounds(c) == bounds(c2ref)

    # setup reflected CellReference
    c = Cell{Float64}("main")
    c2 = Cell{Float64}("rect")
    render!(c2, Rectangle(5, 5), GDSMeta())
    c2ref = StructureReference(c2, Point(-10.0, 0.0); xrefl=true)
    push!(c.refs, c2ref)
    @test bounds(c) == bounds(c2) + Point(-10.0, -5.0)
    @test flatten!(c) === c
    @test bounds(c) == bounds(c2ref)
    @test bounds(flatten(c2ref)) == bounds(c)

    # More setup
    c = Cell{Float64}("main")
    c2 = Cell{Float64}("rect")
    render!(c2, Rectangle(5, 5), GDSMeta())
    arr = ArrayReference(
        c2,
        Point(0, 0);
        dc=Point(10, 0),
        dr=Point(0, 10),
        ncols=10,
        nrows=10
    )
    @test coordsys(arr) === c2
    push!(c.refs, arr)

    # Test bounds with cell arrays
    @test bounds(c) == Rectangle(95, 95)

    # Test `flatten!` when encountering a CellArray
    let c2 = flatten(c; name="flat_arr")
        @test name(c2) == "flat_arr"
    end
    @test flatten!(c) === c
    @test bounds(c) == Rectangle(95, 95)
    @test bounds(flatten(arr)) == Rectangle(95, 95)

    # TODO Test push! and pop!

    # === Issues 17 and 18 ===
    c = Cell("main", nm)
    c2 = Cell("test", nm)
    render!(c2, Rectangle(1μm, 2μm))
    push!(c.refs, sref(c2))
    flatten!(c) # just don't want it to throw an error
    @test all(
        points((elements(c))[1]) .===
        [p(0.0nm, 0.0nm), p(1000.0nm, 0.0nm), p(1000.0nm, 2000.0nm), p(0.0nm, 2000.0nm)]
    )

    c = Cell("main", nm)
    c2 = Cell("test", μm)
    render!(c2, Rectangle(1μm, 2μm))
    push!(c.refs, sref(c2))
    flatten!(c)
    @test all(
        points((elements(c))[1]) .===
        [p(0.0nm, 0.0nm), p(1000.0nm, 0.0nm), p(1000.0nm, 2000.0nm), p(0.0nm, 2000.0nm)]
    )

    c = Cell("main", nm)
    c2 = Cell{Float64}("test")
    render!(c2, Rectangle(1, 1))
    push!(c.refs, sref(c2))
    @test_throws DimensionError flatten!(c)

    c = Cell("main", nm)
    c2 = Cell("test", nm)
    push!(c.refs, sref(c2))
    flatten!(c)
    @test isempty(elements(c))

    @test (Rectangle(0, 0) + Point(20, 0)).ll == Point(20, 0)

    # non-empty reference with improper bounds still has zero extent
    # just like empty reference
    path = Path(0.0nm, 0.0nm)
    straight!(path, 0nm, Paths.SimpleCPW(2000.0nm, 1000.0nm))
    c = Cell("main", nm)
    c2 = Cell("test", nm)
    render!(c2, path, GDSMeta())
    addref!(c, c2, rot=45°)
    addref!(c, Cell("test2", nm), Point(5000nm, 0nm))
    @test !isproper(bounds(c))

    # === End Issues 17 and 18 ===

    @test_throws DimensionError StructureReference(Cell("junk", nm), Point(0, 0))

    # Bounds has same coordinate type as structure, growing if necessary
    c = Cell{Int}("main")
    c2 = Cell{Int}("test")
    render!(c2, Rectangle(1, 1), GDSMeta())
    addref!(c, c2, Point(0.5, 0.5))
    @test bounds(c) == Rectangle(2, 2)
    c = Cell{typeof(1nm)}("main")
    c2 = Cell{typeof(1nm)}("test")
    render!(c2, Rectangle(1nm, 1nm), GDSMeta())
    addref!(c, c2, Point(0.5, 0.5)nm)
    @test bounds(c) == Rectangle(2nm, 2nm)

    # Alternative constructors
    c1 = Cell("test", nm, pm)
    c2 = Cell("test", Polygon{typeof(1.0nm)}[], GDSMeta[])
    c3 = Cell("test", Polygon{typeof(1.0nm)}[], GDSMeta[], [])
    @test Cells.dbscale(c1, c2, c3) == 1.0pm
end

@testset "Path basics" begin
    @testset "> Path constructors" begin
        @test typeof(Path()) == Path{typeof(1.0nm2nm)}
        @test typeof(Path(0, 0)) == Path{Float64}
        @test typeof(Path(Point(0, 0))) == Path{Float64}
        @test α0(Path()) == 0.0° == 0.0 == 0.0rad

        @test typeof(Path(0.0μm, 0.0μm)) == Path{typeof(1.0μm)}
        @test typeof(Path(0.0μm2μm, 0.0μm2μm)) == Path{typeof(1.0μm2μm)}
        @test typeof(Path(0.0μm2μm, 0.0nm2μm)) == Path{typeof(1.0μm2μm)}
        @test typeof(Path(0.0μm2nm, 0.0μm2nm)) == Path{typeof(1.0μm2nm)}
        @test typeof(Path(0.0μm2nm, 0.0nm2nm)) == Path{typeof(1.0nm2nm)}
        @test typeof(Path(0μm, 0μm)) == Path{typeof(1.0μm)}
        @test typeof(Path(0μm2μm, 0μm2μm)) == Path{typeof(1.0μm2μm)}
        @test typeof(Path(0μm2μm, 0nm2μm)) == Path{typeof(1.0μm2μm)}
        @test typeof(Path(0μm2nm, 0μm2nm)) == Path{typeof(1.0μm2nm)}
        @test typeof(Path(0μm2nm, 0nm2nm)) == Path{typeof(1.0nm2nm)}

        @test typeof(Path(Point(0.0μm, 0.0μm))) == Path{typeof(1.0μm)}
        @test typeof(Path(Point(0.0μm2μm, 0.0μm2μm))) == Path{typeof(1.0μm2μm)}
        @test typeof(Path(Point(0.0μm2μm, 0.0nm2μm))) == Path{typeof(1.0μm2μm)}
        @test typeof(Path(Point(0.0μm2nm, 0.0μm2nm))) == Path{typeof(1.0μm2nm)}
        @test typeof(Path(Point(0.0μm2nm, 0.0nm2nm))) == Path{typeof(1.0nm2nm)}
        @test typeof(Path(Point(0μm, 0μm))) == Path{typeof(1.0μm)}
        @test typeof(Path(Point(0μm2μm, 0μm2μm))) == Path{typeof(1.0μm2μm)}
        @test typeof(Path(Point(0μm2μm, 0nm2μm))) == Path{typeof(1.0μm2μm)}
        @test typeof(Path(Point(0μm2nm, 0μm2nm))) == Path{typeof(1.0μm2nm)}
        @test typeof(Path(Point(0μm2nm, 0nm2nm))) == Path{typeof(1.0nm2nm)}

        @test α0(Path(Point(0.0μm, 0.0μm); α0=90°)) == 90.0° == π * rad / 2 == π / 2
        @test α0(Path(Point(0.0μm, 0.0μm); α0=π / 2)) == 90.0° == π * rad / 2 == π / 2

        @test typeof(Path(μm)) == Path{typeof(1.0μm)}

        @test_throws DimensionError Path(0, 0μm)
        @test_throws DimensionError Path(0nm, 0)
    end

    @testset "> Path segments" begin
        pa = Path{Float64}()
        @test_throws ArgumentError straight!(pa, -10.0, Paths.Trace(10.0)) # Issue 11
        @test_throws Unitful.DimensionError straight!(pa, 10.0μm, Paths.Trace(10.0μm))
        @test pathlength(pa) == 0.0
        straight!(pa, 10, Paths.Trace(10))
        @test pathlength(pa) == 10
        @test pathlength(segment(pa[1])) == 10
        turn!(pa, π / 2, 5.0)
        @test pathlength(pa) == 10 + 5 * π / 2
        @test pathlength(segment(pa[2])) == 5π / 2
        @test ForwardDiff.derivative(segment(pa[1]), 0.0) ≈ Point(1.0, 0.0)
        @test ForwardDiff.derivative(segment(pa[1]), 10.0) ≈ Point(1.0, 0.0)
        @test DeviceLayout.Paths.curvature(segment(pa[1]), 0.0) ≈ Point(0.0, 0.0)
        @test DeviceLayout.Paths.curvature(segment(pa[1]), 10.0) ≈ Point(0.0, 0.0)
        @test ForwardDiff.derivative(segment(pa[2]), 0.0) ≈ Point(1.0, 0.0)
        @test ForwardDiff.derivative(segment(pa[2]), 5π / 2) ≈ Point(0.0, 1.0)
        @test DeviceLayout.Paths.curvature(segment(pa[2]), 0.0) ≈ Point(0.0, 0.2)
        @test DeviceLayout.Paths.curvature(segment(pa[2]), 5π / 2) ≈ Point(-0.2, 0.0)

        pa = Path(μm)
        @test_throws Unitful.DimensionError straight!(pa, 10.0, Paths.Trace(10))
        @test pathlength(pa) == 0.0μm
        straight!(pa, 10μm, Paths.Trace(10.0μm))
        @test pathlength(pa) == 10μm
        @test pathlength(segment(pa[1])) == 10μm
        turn!(pa, π / 2, 5.0μm)
        @test pathlength(pa) == (10 + 5 * π / 2)μm
        @test pathlength(segment(pa[2])) == (5π / 2)μm
        @test ForwardDiff.derivative(segment(pa[1]), 0.0μm) ≈ Point(1.0, 0.0)
        @test ForwardDiff.derivative(segment(pa[1]), 10.0μm) ≈ Point(1.0, 0.0)
        @test DeviceLayout.Paths.curvature(segment(pa[1]), 0.0μm) ≈
              Point(0.0 / μm, 0.0 / μm)
        @test DeviceLayout.Paths.curvature(segment(pa[1]), 10.0μm) ≈
              Point(0.0 / μm, 0.0 / μm)
        @test ForwardDiff.derivative(segment(pa[2]), 0.0μm) ≈ Point(1.0, 0.0)
        @test ForwardDiff.derivative(segment(pa[2]), (5π / 2)μm) ≈ Point(0.0, 1.0)
        @test DeviceLayout.Paths.curvature(segment(pa[2]), 0.0μm) ≈
              Point(0.0 / μm, 0.2 / μm)
        @test DeviceLayout.Paths.curvature(segment(pa[2]), (5π / 2)μm) ≈
              Point(-0.2 / μm, 0.0 / μm)
        @test α0(path_in(p0_hook(pa))) == α0(pa)
        @test mod2pi(α0(path_out(p1_hook(pa)))) == α1(pa)
        pa_nm = convert(Path{typeof(1.0nm)}, pa)
        # setindex!, pop!, push!, insert!...
        n = popfirst!(pa)
        @test p0(n.seg) == p0(pa_nm)
        insert!(pa, 1, n.seg, n.sty)
        n = pop!(pa)
        @test p1(n.seg) ≈ p1(pa_nm)
        push!(pa, n, n)
        @test pathlength(pa) ≈ (10 + 5 * π)μm
        push!(pa, n.seg, n.sty)
        insert!(pa, 3, n, n)
        pushfirst!(pa, n)
        empty!(pa)
        @test size(pa) == (0,)

        # test setsegment!, setstyle! works correctly
        pa = Path(μm, α0=90°)
        straight!(pa, 100μm, Paths.Trace(2μm))
        straight!(pa, 100μm, Paths.Trace(3μm))
        insert!(pa, 2, copy(segment(pa[1])))
        @test pa[2].sty == Paths.Trace(2μm)
        pa[1] = copy(segment(pa[1]))
        pa[1] = Paths.Trace(3μm)
        @test α0(pa) == 90°
        insert!(pa, 1, copy(segment(pa[1])))
        @test style0(pa) == Paths.Trace(3μm)
        # misc
        @test DeviceLayout.parameters(pa).name == pa.name
        @test contains(summary(pa), "$(pa.α0)")
        @test coordinatetype(Path{typeof(1nm)}()) == typeof(1nm)

        # string turn commands
        pa = Path(μm)
        turn!(pa, "lrrl", 25μm, Paths.Trace(10μm))
        @test Paths.p1(pa) == Point(100μm, 0μm)
        @test Paths.α1(pa) == 0
    end

    @testset "> Path transformations" begin
        # Issue #66
        pa = Path(10μm, 0μm)
        turn!(pa, pi / 2, 10μm, Paths.Trace(10μm))
        bspline!(pa, [Point(100μm, 0μm), Point(20μm, -100μm)], -3pi / 4)

        c0 = CoordinateSystem("path", nm)
        render!(c0, pa, GDSMeta())
        c1 = CoordinateSystem("parent", nm)
        ref = sref(c0, Point(0μm, 20μm), rot=pi / 4, xrefl=true)
        push!(c1.refs, ref)
        f = transformation(c1, ref)
        c2 = flatten(c1)

        pa2 = Path(convert(Vector{eltype(pa)}, elements(c2)))
        @test pathlength(pa2) ≈ pathlength(pa)
        @test p1(pa2) ≈ f(p1(pa))
        @test pa2[2].seg.r(0.5) ≈ f(pa[2].seg.r(0.5))
        @test α1(pa2) ≈ rotated_direction(α1(pa), f)

        pa3 = Translation(Point(100nm, 100nm))(pa2)
        @test α0(pa3) == α0(pa2)
        @test α1(pa3) == α1(pa2)
        @test p0(pa3) ≈ p0(pa2) + Point(100, 100)nm
        @test p1(pa3) ≈ p1(pa2) + Point(100, 100)nm

        @test length(elements(flatten(pa, depth=0))) == length(pa)
    end

    @testset "> Path splitting" begin
        # Splitting turns (MR !198)
        pa = Path(0μm, 0μm)
        turn!(pa, π / 2, 10μm, Paths.Trace(10μm))
        turn!(pa, -π / 2, 10μm)
        splice!(pa, 1, split(pa[1], π / 4 * 10μm))
        splice!(pa, 3, split(pa[3], π / 4 * 10μm))

        @test (α1(pa[2].seg) == π / 2) && (α1(pa[1].seg) == α0(pa[2].seg))
        @test (α1(pa[4].seg) == 0) && (α1(pa[3].seg) == α0(pa[4].seg))

        # Splitting bsplines near endpoints (MR !198)
        pa = Path(0μm, 0μm)
        bspline!(pa, [Point(100μm, 0μm)], -π / 2, Paths.Trace(10μm))
        splice!(pa, 1, split(pa[1], 1nm))
        splice!(pa, 2, split(pa[2], pathlength(pa[2]) - 1nm))

        @test isapprox(pathlength(pa[1]), 1nm; atol=1e-3nm)
        @test isapprox(pathlength(pa[3]), 1nm; atol=1e-3nm)
    end

    @testset "> Path-based launchers" begin
        # w/o units
        pa = Path{Float64}()
        sty = launch!(pa, trace1=4.2, gap1=3.8)
        @test isa(sty, Paths.CPW)
        @test length(pa) == 3
        @test Paths.gap(sty) === 3.8
        @test Paths.trace(sty) === 4.2

        # w/ units
        pa = Path(μm)
        sty = launch!(pa)
        @test Paths.gap(sty) === 6.0μm
        @test Paths.trace(sty) === 10.0μm
        straight!(pa, 10μm, sty)
        launch!(pa) # terminate path with launcher

        pa = Path(nm)
        sty = launch!(pa; rounding=0nm)
        @test Paths.gap(sty) === 6000.0nm
        @test Paths.trace(sty) === 10000.0nm
        @test pa[1].sty isa Paths.CPWOpenTermination
        @test bounds(pa).ll ≈ -Point(pa[1].sty.gap, Paths.extent(pa[1].sty))

        pa = Path(μm)
        sty = launch!(pa, trace1=4.2μm, gap1=3801nm)
        @test Paths.gap(sty) === 3.801μm
        @test Paths.trace(sty) === 4.2μm

        # test dimensionerrors
        pa = Path(μm)
        @test_throws DimensionError launch!(pa, trace1=3.0)
    end

    @testset "> Decorated Paths" begin
        # Bumps
        rr = centered(Rectangle(10μm, 10μm))
        cs_rr = CoordinateSystem(uniquename("test"), nm)
        place!(cs_rr, rr, SemanticMeta(:bump))

        # Trace
        pth = Path(Point(100μm, 100μm); α0=π / 2)
        straight!(pth, 800μm, Paths.Trace(20.0μm))
        attach!(pth, sref(cs_rr), (0μm):(50μm):(800μm))
        @test Paths.trace(pth.nodes[1].sty) === 20.0μm
        @test Paths.width(pth.nodes[1].sty) === 20.0μm
        @test Paths.extent(pth.nodes[1].sty) === 10.0μm

        # CPW
        pth = Path(Point(100μm, 100μm); α0=π / 2)
        straight!(pth, 800μm, Paths.SimpleCPW(10.0μm, 6.0μm))
        attach!(pth, sref(cs_rr), (0μm):(50μm):(800μm))
        @test Paths.trace(pth.nodes[1].sty) === 10.0μm
        @test Paths.gap(pth.nodes[1].sty) === 6.0μm
        @test Paths.extent(pth.nodes[1].sty) === 11.0μm
    end

    @testset "> CompoundSegment" begin
        pa = Path{Float64}()
        straight!(pa, 200.0, Paths.Trace(10))
        turn!(pa, π / 4, 50.0)
        straight!(pa, 200.0)
        simplify!(pa)
        f = segment(pa[1])
        @test f(0.0) == p(0.0, 0.0)
        @test f(1.0) == p(1.0, 0.0)
        @test f(-1.0) == p(-1.0, 0.0)
        @test f(200 + 50 * π / 4 + 199) ≈
              p(200 + 50 / sqrt(2) + 199 / sqrt(2), 50 - 50 / sqrt(2) + 199 / sqrt(2))
        @test f(200 + 50 * π / 4 + 200) ≈
              p(200 + 50 / sqrt(2) + 200 / sqrt(2), 50 - 50 / sqrt(2) + 200 / sqrt(2))
        @test f(200 + 50 * π / 4 + 201) ≈
              p(200 + 50 / sqrt(2) + 201 / sqrt(2), 50 - 50 / sqrt(2) + 201 / sqrt(2))
        g = x -> ForwardDiff.derivative(f, x)
        @test g(-1.0) ≈ g(0.0) ≈ g(1.0)
        @test g(200 + 50 * π / 4 + 199) ≈
              g(200 + 50 * π / 4 + 200) ≈
              g(200 + 50 * π / 4 + 201)
    end

    @testset "> Meanders" begin
        pa = Paths.radiator(p(1000, 0), 3000, 2, 100, Paths.Trace(10))
        @test pathlength(pa) ≈ 3000.0
        meander!(pa, p(2000, 0), 5000, 1, 100)
        @test pathlength(pa) ≈ 5000.0
        @test_throws ArgumentError meander!(pa, p(3000, 0), 7000, 2, 100)
        Paths.bellow!(pa, p(4000, 0), 9000, 100)
        @test pathlength(pa) == 9000
    end
end

include("test_render.jl")

@testset "Backends" begin
    @testset "GDS format" begin
        s1 = Cell("sub1", nm)
        render!(s1, Rectangle(10μm, 10μm), GDSMeta(1, 0))
        s2 = Cell("sub2", nm)
        render!(s2, Rectangle(10μm, 10μm), GDSMeta(2, 0))
        main = Cell("main", nm)
        render!(main, Rectangle(10μm, 10μm), GDSMeta(0, 0))
        push!(main.refs, CellReference(s1, p(0.0μm, 20.0μm)))
        push!(
            main.refs,
            CellArray(
                s2,
                p(20.0μm, 0.0μm);
                nrows=2,
                ncols=1,
                dc=p(0.0μm, 0.0μm),
                dr=p(0.0μm, 20.0μm)
            )
        )
        path = joinpath(tdir, "test.gds")
        @test save(path, main) == 454 # bytes written
        cells = load(path)
        @test haskey(cells, "main")
        @test isa(cells["main"], Cell{typeof(1.0 * DeviceLayout.nm)})
        @test length(cells["main"].refs) == 2
        @test length(elements(cells["main"])) == 1
        rm(path, force=true)

        # Warns for duplicate cell names
        dup = Cell("top", nm)
        push!(dup.refs, sref(main))
        push!(dup.refs, sref(Cell("main", nm)))
        @test_logs (:warn, r"Duplicate cell name") save(joinpath(tdir, "dup.gds"), dup)
        # Even if the duplicate is buried in a path attachment
        dup_cs = CoordinateSystem("top", nm)
        push!(dup_cs.refs, sref(CoordinateSystem("dup", nm)))
        p_dup = Path(0nm, 0nm)
        straight!(p_dup, 100μm, Paths.NoRender())
        att_cs = CoordinateSystem("att", nm)
        push!(att_cs.refs, sref(CoordinateSystem("dup", nm)))
        attach!(p_dup, sref(att_cs), 50μm)
        render!(dup_cs, p_dup, GDSMeta(0))
        dup = Cell(dup_cs, nm)
        @test_logs (:warn, r"Duplicate cell name") save(joinpath(tdir, "dup.gds"), dup)
        # Case insensitive
        dup = Cell("top", nm)
        push!(dup.refs, sref(main))
        push!(dup.refs, sref(Cell("Main", nm)))
        @test_logs (:warn, r"Duplicate cell name") save(joinpath(tdir, "dup.gds"), dup)

        # Corrupt file tests: records
        @test_logs (:warn, r"unknown record type 0xffff") load(
            joinpath(dirname(@__FILE__), "unknown_record.gds")
        )
        @test_logs (:warn, r"unimplemented record type 0x2202") load(
            joinpath(dirname(@__FILE__), "unimplemented_record.gds")
        )
        @test_throws CapturedException load(
            joinpath(dirname(@__FILE__), "badbytes_record.gds")
        )
        @test_logs (:warn, r"did not start with a BGNLIB") load(
            joinpath(dirname(@__FILE__), "no_bgnlib.gds")
        )
        @test_logs (:warn, r"end with an ENDLIB") load(
            joinpath(dirname(@__FILE__), "no_endlib.gds")
        )

        # Corrupt file tests: cells
        @test_throws CapturedException load(
            joinpath(dirname(@__FILE__), "badbytes_cell.gds")
        )
        @test_throws CapturedException load(
            joinpath(dirname(@__FILE__), "unknown_cell.gds")
        ) # unknown token in cell (0xffff)
        @test_throws CapturedException load(
            joinpath(dirname(@__FILE__), "unimplemented_cell.gds")
        ) # unimplemented token in cell (0x0c00, TEXT)

        # Corrupt file tests: boundaries
        @test_throws CapturedException load(
            joinpath(dirname(@__FILE__), "badbytes_boundary.gds")
        )
        @test_throws CapturedException load(
            joinpath(dirname(@__FILE__), "unknown_boundary.gds")
        ) # unknown token in boundary (0xffff)

        # Round-trip tests
        let c = Cell("main", nm), c2 = Cell("sub", nm)
            render!(c2, Rectangle(1μm, 1μm), GDSMeta(0))
            c2ref = CellReference(c2, xrefl=true, rot=90°)
            push!(c.refs, c2ref)
            path = joinpath(tdir, "test.gds")
            save(path, c)
            gds = load(path)
            @test gds["main"].refs[1].xrefl == true
            @test gds["main"].refs[1].rot == 90°
            rm(path, force=true)
        end
        let c = Cell{Float64}("main"), c2 = Cell{Float64}("sub")
            render!(c2, Rectangle(1, 1), GDSMeta(0))
            c2ref = CellReference(c2, xrefl=true, rot=90°)
            push!(c.refs, c2ref)
            path = joinpath(tdir, "test.gds")
            save(path, c)
            gds = load(path)
            @test gds["main"].refs[1].xrefl == true
            @test gds["main"].refs[1].rot == 90°
            rm(path, force=true)
        end

        # test we can recognize PROPATTR and PROPVALUE tags (though ignored)
        @test_logs (:info, r"PROPATTR: 0") match_mode = :any load(
            joinpath(@__DIR__, "propattr.gds");
            verbose=true
        )
        @test_logs (:info, r"PROPVALUE: abc") match_mode = :any load(
            joinpath(@__DIR__, "propattr.gds");
            verbose=true
        )
    end

    @testset "DXF format" begin
        main = Cell("main", nm)
        render!(main, Rectangle(10μm, 10μm), GDSMeta(0, 0))
        path = joinpath(tdir, "test.dxf")
        py3 = "python3"
        save(path, main, py3)
        rect = [
            (0.0, 0.0, 0.0, 0.0, 0.0),
            (10.0, 0.0, 0.0, 0.0, 0.0),
            (10.0, 10.0, 0.0, 0.0, 0.0),
            (0.0, 10.0, 0.0, 0.0, 0.0)
        ]
        @test eval(Meta.parse(read(`$py3 test_ezdxf.py $path`, String))) == rect
    end

    @testset "Graphics formats" begin
        s1 = Cell("sub1", nm)
        render!(s1, Rectangle(10μm, 10μm), GDSMeta(1, 0))
        path = joinpath(tdir, "test.svg")
        save(path, s1, width=10cm)
        rm(path, force=true)
        path = joinpath(tdir, "test.eps")
        save(path, s1, height=10cm)
        rm(path, force=true)
        path = joinpath(tdir, "test.pdf")
        save(path, s1, height=72 * 8)
        rm(path, force=true)
        path = joinpath(tdir, "test.png")
        save(path, s1, width=72 * 4)
        rm(path, force=true)
    end
end
