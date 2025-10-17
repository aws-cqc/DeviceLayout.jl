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
        @test all(Paths.style.(elements(halopath)) .== Paths.style.(flathalo))
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
    end
end
