@testitem "GeometryEntity" setup = [CommonTestSetup] begin
    # Plus shape entity to test methods
    struct OriginPlus{S} <: GeometryEntity{S}
        h::S
        w::S
        function OriginPlus(h, w)
            (h, w) = promote(h, w)
            return new{typeof(h)}(h, w)
        end
    end
    DeviceLayout.to_polygons(p::OriginPlus; kwargs...) =
        to_polygons(union2d(centered(Rectangle(p.w, p.h)), centered(Rectangle(p.h, p.w))))[1]
    DeviceLayout.halo(p::OriginPlus, delta, inner_delta=nothing) =
        OriginPlus(p.h + 2 * delta, p.w + 2 * delta)

    function DeviceLayout.transform(p::OriginPlus, f::Transformation)
        preserves_angles(f) && return transform(p, ScaledIsometry(f))
        return f(to_polygons(p))
    end

    function DeviceLayout.transform(p::OriginPlus, f::ScaledIsometry)
        if isapprox_cardinal(rotation(f), atol=1e-12, rtol=1e-6)
            if isnothing(origin(f)) || iszero(origin(f))
                if isapprox_cardinal(rotation(f) / 2, atol=1e-12, rtol=1e-6)
                    return OriginPlus(p.h * mag(f), p.w * mag(f))
                end
                return OriginPlus(p.w * mag(f), p.h * mag(f))
            end
        end
        return f(to_polygons(p))
    end
    Base.:(==)(a::OriginPlus, b::OriginPlus) = (a.h == b.h) && (a.w == b.w)
    Base.isapprox(a::OriginPlus, b::OriginPlus; kwargs...) =
        isapprox(a.h, b.h, kwargs...) && isapprox(a.w, b.w, kwargs...)

    plus = OriginPlus(5, 2)
    @test rotate(plus, 90°) == OriginPlus(2, 5)
    @test rotate90(plus, 2) == plus
    @test reflect_across_xaxis(plus) == plus
    @test rotate(rotate(plus, 45°), 45°) ≈ rotate(to_polygons(plus), 90°)
    @test (Rotation(45°) ∘ Rotation(45°))(plus) ≈ OriginPlus(2, 5)
    @test translate(plus, Point(10, 0)) == to_polygons(plus) + Point(10, 0)
    @test length(points(to_polygons(plus))) == 12
    @test bounds(plus) == centered(Rectangle(5, 5))
    @test bounds(2 * plus) == 2 * bounds(plus)
    aplus = [plus, plus - Point(10, 0)]
    @test footprint(aplus) == Rectangle(Point(-12.5, -2.5), Point(2.5, 2.5))
    @test halo(plus, 1) == OriginPlus(7, 4)
    @test length(halo(aplus, 1)) == 2 # separate halos

    @testset "ArrayEntity" begin
        r = Rectangle(Point(5, 5), Point(10, 10))
        a = DeviceLayout.ArrayEntity(GeometryEntity{Int}[plus, r])
        c = Cell{Float64}("ex")
        render!(c, a)
        @test length(elements(c)) == length(a)
        ah = halo(a, 2)
        @test ah[1] isa OriginPlus{Int}
        @test ah[end] isa Polygon{Int}
        @test footprint(a) == bounds(plus, r)
        @test (Point(1, 1) + a) isa DeviceLayout.ArrayEntity
        @test offset(plus, 2)[1] == to_polygons(ah[1])
    end

    @testset "EntityStyle" begin
        pr = Polygons.Rounded(plus, 0.1)
        @test DeviceLayout.unstyled(pr) == plus
        @test DeviceLayout.unstyled_type(pr) == typeof(plus)
        poly = to_polygons(pr)
        ### Issue #85
        @test to_polygons(translate(pr, Point(1, 1))) ≈ translate(poly, Point(1, 1))
        ###
        a = DeviceLayout.ArrayEntity([plus, plus])
        pa = Polygons.Rounded(0.1)(a)
        @test all(to_polygons(pa) .== poly)

        opt_plus = optional_entity(plus, :opt_ent; default=false)
        opt_round_plus = OptionalStyle(plus, Polygons.Rounded(0.1), :opt_round)
        c = Cell{Float64}("styles")
        render!(c, opt_plus)
        @test length(elements(c)) == 0
        render!(c, opt_plus; opt_ent=true)
        @test length(elements(c)) == 1
        render!(c, opt_round_plus)
        @test last(elements(c)) == to_polygons(pr)
        render!(c, opt_round_plus; opt_round=false)
        @test last(elements(c)) == to_polygons(plus)
        render!(c, ToTolerance(opt_round_plus, 0.01))
        @test length(points(last(elements(c)))) < length(points(to_polygons(pr)))
        @test length(points(last(elements(c)))) > length(points(to_polygons(plus)))
        @test halo(opt_round_plus, 2) == halo(plus, 2) # forwarded to underlying ent
        @test footprint(opt_round_plus) == footprint(plus)
        # Other interface functions use default style; NoRender -> zero bounds
        @test isempty(halo(opt_plus, 2))
        @test !isproper(footprint(opt_plus))
        @test !isproper(bounds(opt_plus))
    end

    @testset "Path Nodes" begin
        # Create a halo of a path
        pa = Path(0nm, 0nm)
        straight!(pa, 100μm, Paths.SimpleCPW(10μm, 6μm))
        turn!(pa, pi / 2, 50μm)
        straight!(pa, 100μm, Paths.TaperCPW(10μm, 6μm, 2μm, 1μm))
        halopath = halo(pa, 2μm)

        # Try the same but flatten first
        cs = CoordinateSystem("test", nm)
        place!(cs, pa, SemanticMeta(:test))
        flatten!(cs)
        @test Paths.style(elements(cs)[3]).length == 100μm # Make sure taper got reconciled
        flathalo = halo(elements(cs), 2μm)
        @test eltype(flathalo) <: Paths.Node
        @test all(
            Paths.width.(Paths.style.(elements(halopath)), 0nm) .≈
            Paths.width.(Paths.style.(flathalo), 0nm)
        )
        @test Paths.style(flathalo[4]).length == 100μm

        # Issue: Corner transformation
        pa = Path(μm)
        straight!(pa, 20.0μm, Paths.Trace(1.0μm))
        corner!(pa, π / 2, Paths.SimpleTraceCorner())
        straight!(pa, 20.0μm)
        pa2 = XReflection()(pa)
        @test p1(pa2) == XReflection()(p1(pa))
    end

    @testset "Path halo" begin

        # create a path and decorate it with some bumps
        pth = Path(Point(100μm, 100μm); α0=π / 2)
        straight!(pth, 800μm, Paths.Trace(20μm))
        rr = centered(Rectangle(10μm, 10μm))
        cs_rr = CoordinateSystem(uniquename("test"), nm)
        place!(cs_rr, rr, SemanticMeta(:bump))
        attach!(pth, sref(cs_rr), (0μm):(50μm):(800μm))
        cs = CoordinateSystem(uniquename("pth"), nm)
        place!(cs, pth, SemanticMeta(:base_negative))

        # create halo of the path, testing if decorations are getting halos
        cs_halo1 = halo(cs, 15μm; only_layers=[:base_negative, :bump])
        cs_halo2 = halo(cs, 15μm; only_layers=[:bump])
        cs_halo3 = halo(cs, 15μm; ignore_layers=[:base_negative])
        cs_halo4 = halo(cs, 15μm; ignore_layers=[:bump])

        @test bounds(cs_halo1) ≈ Rectangle(Point(75μm, 80μm), Point(125μm, 920μm))
        @test bounds(cs_halo2) ≈ Rectangle(Point(80μm, 80μm), Point(120μm, 920μm))
        @test bounds(cs_halo3) ≈ Rectangle(Point(80μm, 80μm), Point(120μm, 920μm))
        @test bounds(cs_halo4) ≈ Rectangle(Point(75μm, 85μm), Point(125μm, 915μm))

        # TaperTrace halo
        pth = Path()
        straight!(pth, 10μm, Paths.TaperTrace(10μm, 20μm))
        @test halo(pth[1].sty, 20μm, 10μm) ==
              Paths.TaperCPW{typeof(1.0μm)}(30μm, 10μm, 40μm, 10μm, 10μm)
    end
end

@testitem "WithDirection" setup = [CommonTestSetup] begin
    ## Construction
    @test WithDirection().direction == 0°
    # Numeric argument converts to degrees
    @test WithDirection(pi / 4).direction ≈ 45°
    ## Transformation
    sty = WithDirection(90°)
    @test transform(sty, Rotation(90°)).direction == 180°
    @test transform(sty, Rotation(270°)).direction % 360° == 0°
    @test isapprox_angle(transform(sty, XReflection()).direction, 270°)
    @test transform(WithDirection(), XReflection()).direction == 0°
    @test transform(WithDirection(), ScaledIsometry(nothing, 90°, true, 1.0)).direction ==
          90°
    @test isapprox_angle(
        transform(sty, ScaledIsometry(nothing, 90°, true, 1.0)).direction,
        0°
    )
    @test transform(sty, Transformations.IdentityTransformation()).direction == 90°
    ## Rendering
    rect = Rectangle(2μm, 3μm)
    @test to_polygons(sty(rect)) == to_polygons(rect)
    ## Direction extraction
    opt = optional_entity(rect, :foo; default=true)
    msz = meshsized_entity(opt, 0.5μm)
    wd_outer = WithDirection(90°)(msz)
    wd_inner = WithDirection(45°)(rect)
    msz2 = meshsized_entity(wd_inner, 0.5μm)
    opt2 = optional_entity(msz2, :foo; default=true)
    @test SchematicDrivenLayout._extract_direction(wd_outer) == 90°
    @test SchematicDrivenLayout._extract_direction(wd_inner) == 45°
    @test SchematicDrivenLayout._extract_direction(opt2) == 45°
    @test SchematicDrivenLayout._extract_direction(opt) === nothing
    @test SchematicDrivenLayout._extract_direction(rect) === nothing
    # If multiple WithDirection layers exist, outer wins (expected behavior, not a contract)
    double = WithDirection(0°)(WithDirection(90°)(rect))
    @test SchematicDrivenLayout._extract_direction(double) == 0°
    ## _direction_string
    using DeviceLayout.SchematicDrivenLayout: _direction_string
    @test _direction_string(0°) == "+X"
    @test _direction_string(90°) == "+Y"
    @test _direction_string(180°) == "-X"
    @test _direction_string(270°) == "-Y"

    # Normalization: 360° → +X, -90° → -Y, 450° → +Y
    @test _direction_string(360°) == "+X"
    @test _direction_string(-90°) == "-Y"
    @test _direction_string(450°) == "+Y"

    # Off-axis: "[dx, dy, 0.0]" format
    s45 = _direction_string(45°)
    @test startswith(s45, "[")
    @test occursin("0.707107", s45)
    @test endswith(s45, ", 0.0]")

    # Within atol tolerance → still +X
    @test _direction_string(0.0005°) == "+X"
    @test _direction_string(-0.0005°) == "+X"
    @test _direction_string(359.9995°) == "+X"

    @testset "port_directions" setup = [CommonTestSetup] begin
        using DeviceLayout.SchematicDrivenLayout
        # Place three rectangles directly on the schematic's top-level coordsys.
        # Two of them carry WithDirection; one is bare.
        g = SchematicGraph("test-g")
        sch = plan(g)
        rect1 = centered(Rectangle(1μm, 1μm))
        rect2 = centered(Rectangle(1μm, 1μm))
        rect3 = centered(Rectangle(1μm, 1μm))
        place!(sch, WithDirection(0°)(rect1), SemanticMeta(:myport))
        place!(sch, WithDirection(90°)(rect2), SemanticMeta(:myport))
        place!(sch, rect3, SemanticMeta(:myport))  # bare, no direction
        # Needs to be indexed first
        @test_throws "Repeated index" port_directions(sch, :myport)

        SchematicDrivenLayout.index_layer!(sch, :myport)
        dirs = port_directions(sch, :myport)
        # Indexed entities 1 and 2 have directions; entity 3 is bare so no entry.
        @test length(dirs) == 2
        @test dirs[1] == "+X"
        @test dirs[2] == "+Y"
        @test !haskey(dirs, 3)

        g = SchematicGraph("test-g-empty")
        sch = plan(g)
        rect = centered(Rectangle(1μm, 1μm))
        place!(sch, rect, SemanticMeta(:bareport))  # no WithDirection
        SchematicDrivenLayout.index_layer!(sch, :bareport)
        dirs = port_directions(sch, :bareport)
        @test isempty(dirs)
        # Entities with explicit index=0 (e.g. inner component entities after a
        # Phase-2 `index_layer!` flatten-and-clear pass) must be skipped by
        # port_directions.
        g = SchematicGraph("test-g-zeroidx")
        sch = plan(g)
        rect = centered(Rectangle(1μm, 1μm))
        place!(sch, WithDirection(0°)(rect), SemanticMeta(:zly, index=0))
        dirs = port_directions(sch, :zly)
        @test isempty(dirs)
    end
end
