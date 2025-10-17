@testitem "CoordinateSystems" setup = [CommonTestSetup] begin
    # Setup nested cell refs
    c = CoordinateSystem{Float64}("main")
    c2 = CoordinateSystem{Float64}("c2")
    c3 = CoordinateSystem{Float64}("c3")
    c2ref = CoordinateSystemReference(c2, Point(-10.0, 0.0); mag=1.0, rot=180°)
    c3ref = CoordinateSystemReference(c3, Point(10.0, 0.0); mag=2.0, rot=90°)
    c3ref2 = CoordinateSystemReference(c3, Point(0.0, 5.0); mag=2.0, rot=45°)
    c3ref3 = CoordinateSystemReference(c3, Point(0.0, -5.0); mag=0.5, rot=0°)

    @test c2ref.structure === c2

    r = Rectangle(5, 10)
    render!(c3, r, GDSMeta())
    push!(c.refs, c2ref)
    @test bounds(c) == Rectangle(0.0, 0.0)
    push!(c2.refs, c3ref)
    push!(c2.refs, c3ref2)
    push!(c.refs, c3ref3)
    @test c3.elements[1] == Rectangle(5.0, 10.0)

    cell = Cell(c)
    @test cell.refs[2].structure.refs[1].structure.elements[1] == Polygon{Float64}(r)

    # Index order is not actually guaranteed
    @test cell.refs[2].structure.refs[1].structure === cell.refs[1].structure
    @test cell.refs[2].structure.refs[2].structure === cell.refs[1].structure

    # Test coordinate system transformations
    tr = transformation(c, c3ref)
    @test tr(Point(1, 1)) ≈ Point(-18.0, -2.0)
    @test c["c2"]["c3"] == c3ref
    c′ = c + Point(10.0, 10.0)
    c2ref′ = c2ref + Point(10.0, 10.0)

    @test bounds(Cell(flatten(c))) == bounds(flatten(Cell(c)))

    @test_throws DimensionError CoordinateSystemReference(
        CoordinateSystem{typeof(1.0nm)}("junk"),
        Point(0, 0)
    )
    cs_nm = CoordinateSystem("withunits", nm)
    poly = Polygon(Point(1μm, 1μm), Point(1μm, 0μm), Point(0μm, 1μm))
    render!(cs_nm, Rectangle(20nm, 40nm), GDSMeta())
    render!(cs_nm, Rectangle(20.0μm, 40μm), GDSMeta())
    render!(cs_nm, poly, GDSMeta())
    r2 = Rectangle(20.0nm, 40.0nm)
    poly2 = Polygon(Point(1.0nm, 1.0nm), Point(1nm, 0nm), Point(0nm, 1nm))
    render!(cs_nm, r2, GDSMeta())
    @test cs_nm.elements[end] === r2
    render!(cs_nm, poly2, GDSMeta())
    @test cs_nm.elements[end] === poly2

    # No unnecessary copying/conversion
    pa = Path(Point(20nm, 40nm))
    straight!(pa, 100nm, Paths.SimpleCPW(10μm, 6μm))
    render!(cs_nm, pa, GDSMeta())
    @test pa === cs_nm.refs[end].structure

    # Path with different ContextUnits
    pa = Path(Point(20μm, 40μm))
    straight!(pa, 100μm, Paths.SimpleCPW(10μm, 6μm))
    bspline!(pa, [Point(100μm, 100μm)], 180°)
    straight!(pa, 100μm)
    render!(cs_nm, pa, GDSMeta())
    pa_r = cs_nm.refs[end].structure
    @test pa.p0 == convert(typeof(pa.p0), pa_r.p0)
    @test pa.α0 == pa_r.α0
    @test laststyle(pa) == laststyle(pa_r)
    for (n, n_r) in zip(pa.nodes, pa_r.nodes)
        @test n.seg(50μm) ≈ n_r.seg(50000nm)
    end

    # Other constructors
    cs2 = CoordinateSystem("name_el", elements(cs_nm), element_metadata(cs_nm))
    @test elements(cs2) === elements(cs_nm)
    cs2 = CoordinateSystem(
        "name_el_refs",
        elements(cs_nm),
        element_metadata(cs_nm),
        refs(cs_nm)
    )
    @test refs(cs2) === refs(cs_nm)
    sref2 = CoordinateSystemReference(cs2, rot=90°)
    @test CoordinateSystems.origin(sref2) isa Point{typeof(1.0nm)}

    @testset "Metadata" begin
        cs_meta = CoordinateSystem("meta", nm)
        render!(cs_meta, Rectangle(20.0μm, 40μm), GDSMeta(1, 0))
        @test Cell(cs_meta, nm).element_metadata[1] == GDSMeta(1, 0)
        ##### Metadata: SemanticMeta
        layer_record = (; base=GDSMeta(1, 0))
        # Render rectangle to CS base layer with rounding and tolerance attributes
        opt_tol = OptionalStyle(ToTolerance(0.1μm), :optional_tolerance, default=false)
        render!(
            cs_meta,
            opt_tol(
                OptionalStyle(Polygons.Rounded(1μm), :optional_rounding)(
                    Rectangle(40μm, 20.0μm)
                )
            ),
            SemanticMeta(:base)
        )
        # Turn into Cell using layer_record only (ignore styles)
        c = Cell(
            cs_meta,
            nm;
            map_meta=(meta) ->
                (haskey(layer_record, layer(meta)) ? layer_record[layer(meta)] : meta),
            optional_rounding=false
        )
        @test c.element_metadata[2] == layer_record.base
        @test length(c.elements[2].p) == 4 # Just a rectangle

        # Turn into a Cell using rounding default
        c = Cell(
            cs_meta,
            nm;
            map_meta=(meta) ->
                (haskey(layer_record, layer(meta)) ? layer_record[layer(meta)] : meta)
        )
        num_points = length(c.elements[2].p)
        @test num_points > 4 # More points due to rounding

        # Use tolerance from style
        c = Cell(
            cs_meta,
            nm;
            map_meta=(meta) ->
                (haskey(layer_record, layer(meta)) ? layer_record[layer(meta)] : meta),
            optional_tolerance=true
        )
        @test length(c.elements[2].p) > 4 # More points than a rectangle
        @test length(c.elements[2].p) < num_points # High tolerance reduces num_points

        # kwargs are passed on to attachments
        cs = CoordinateSystem("cs", nm)
        att_cs = CoordinateSystem("att", nm)
        render!(
            att_cs,
            opt_tol(Polygons.Rounded(Rectangle(2.0μm, 3.1μm), 1μm)),
            SemanticMeta(:base)
        )
        p_att = Path(0nm, 0nm)
        straight!(p_att, 100μm, Paths.NoRender())
        attach!(p_att, sref(att_cs), 50μm)
        render!(cs, p_att, SemanticMeta(:base))
        c = Cell(
            cs,
            nm;
            map_meta=(meta) ->
                (haskey(layer_record, layer(meta)) ? layer_record[layer(meta)] : meta),
            optional_tolerance=true
        )
        @test c.refs[1].structure.refs[1].structure.element_metadata[1] == layer_record.base
        @test length(c.refs[1].structure.refs[1].structure.elements[1].p) > 4
        @test length(c.refs[1].structure.refs[1].structure.elements[1].p) < num_points

        meta = SemanticMeta(:test, level=2)
        meta2 = SemanticMeta(meta, index=2)
        @test level(GDSMeta()) == 1
        @test layerindex(meta2) == 2
        @test level(meta) == 2
        @test layer(GDSMeta(1, 2)) == :GDS1_2
        @test layer(SemanticMeta(GDSMeta(1, 2))) == :GDS1_2

        @test layer_inclusion([], meta2).([meta, GDSMeta(), meta2]) == [true, true, false]
        @test layer_inclusion(:test, meta2).([meta, GDSMeta(), meta2]) ==
              [true, false, false]
    end

    @testset "CS Decorations" begin # Modified from Styles>Decorations
        csub = CoordinateSystem("sub", nm)
        render!(csub, centered(Rectangle(10nm, 10nm)), GDSMeta())
        cref = CoordinateSystemReference(csub, Point(0.0μm, 0.0μm))

        # Check conversion does not copy coordinate system
        cref_nm = convert(StructureReference{typeof(1.0nm)}, cref)
        @test typeof(cref_nm) != typeof(cref)
        @test coordsys(cref_nm) === coordsys(cref)

        c = Cell("main", nm)
        pa = Path(μm)
        straight!(pa, 20.0μm, Paths.NoRender())
        turn!(pa, π / 2, 20.0μm)
        straight!(pa, 20.0μm)
        simplify!(pa)
        attach!(pa, cref, range(0μm, stop=pathlength(pa), length=3))
        render!(c, pa)

        @test isempty(c.elements)
        @test length(c.refs) == 3

        flatten!(c)

        @test length(c.refs) == 0
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

        cref = CoordinateSystemReference(csub, Point(0.0μm, 10.0μm))
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
        @test points(c.elements[1]) == Point{typeof(1.0nm)}[
            p(29505.0nm, 39995.0nm),
            p(29505.0nm, 40005.0nm),
            p(29495.0nm, 40005.0nm),
            p(29495.0nm, 39995.0nm)
        ]

        c2 = CoordinateSystem("c2", nm)
        render!(c2, Rectangle(1μm, 1μm), GDSMeta(1))
        c2ref = CoordinateSystemReference(c2, Point(0μm, 0μm))

        c = Cell("c", nm)
        ro = Path(μm, α0=180°)
        straight!(ro, 10μm, Paths.Trace(0.5μm))
        attach!(ro, c2ref, pathlength(ro))
        render!(c, ro)

        # Cell(c::CoordinateSystem) at bottom level is memoized
        dup_cs = CoordinateSystem("top", nm)
        att_cs = CoordinateSystem("att", nm)
        push!(dup_cs.refs, DeviceLayout.sref(att_cs))
        p_dup = Path(0nm, 0nm)
        straight!(p_dup, 100μm, Paths.NoRender())
        attach!(p_dup, DeviceLayout.sref(att_cs), 50μm)
        render!(dup_cs, p_dup, GDSMeta(0))
        @test dup_cs.refs[1].structure === refs(dup_cs.refs[2].structure)[1].structure
        dup = Cell(dup_cs, nm)
        @test dup.refs[2].structure === dup.refs[1].structure.refs[1].structure
    end

    @testset "CoordinateSystemArray" begin
        cs = CoordinateSystem("top", nm2μm)
        cs_rect = CoordinateSystem("rect", nm2μm)
        render!(cs_rect, centered(Rectangle(10μm, 4μm)), GDSMeta())
        addref!(cs, ArrayReference(cs_rect, (-50:10.0:50)μm, (-20:20.0:40)μm))
        c = Cell(cs)
        c2 = Cell("carr", nm2μm)
        addref!(c2, aref(Cell(cs_rect), (-50:10.0:50)μm, (-20:20.0:40)μm))
        flatten!(c2)
        @test bounds(c) == Rectangle(Point(-55μm, -22μm), Point(55μm, 42μm))
        @test bounds(flatten(c)) == Rectangle(Point(-55μm, -22μm), Point(55μm, 42μm))
        flatten!(cs)
        @test bounds(cs) == bounds(c)
        @test bounds(cs) == bounds(c2)
        @test_throws DimensionError CoordinateSystemArray(cs_rect, Point(0, 0))
        cs2 = CoordinateSystem("temp", nm2μm)
        addarr!(cs2, cs_rect, dcol=Point(10μm, 0μm), ncol=5)
        # Conversion does not copy structure
        aref_nm = convert(ArrayReference{typeof(1.0nm)}, cs2.refs[1])
        @test structure(aref_nm) === cs_rect
        @test structure(copy(aref_nm)) === cs_rect

        c3 = flatten(Cell(cs2))
        @test bounds(c3) == Rectangle(50μm, 4μm) - Point(5μm, 2μm)
        rot = Rotation(90°)
        cs3 = CoordinateSystem(
            "rotarr",
            GeometryEntity{typeof(1.0nm2μm)}[],
            DeviceLayout.Meta[],
            [rot(refs(cs2)[end])]
        )
        @test bounds(flatten(Cell(cs3))).ll ≈ Point(-2μm, -5μm) rtol = 1e-9
        @test bounds(flatten(Cell(cs3))).ur ≈ Point(2μm, 45μm) rtol = 1e-9
        cs4 = CoordinateSystem(
            "transarr",
            GeometryEntity{typeof(1.0nm2μm)}[],
            DeviceLayout.Meta[],
            [Translation(5μm, 2μm)(refs(cs2)[end])]
        )
        @test bounds(flatten(Cell(cs4))) == Rectangle(50μm, 4μm)
        # Array reference AffineMap
        cs5 = CoordinateSystem(
            "transarr",
            GeometryEntity{typeof(1.0nm2μm)}[],
            DeviceLayout.Meta[],
            [(XReflection() ∘ Translation(5μm, 2μm))(refs(cs2)[end])]
        )
        @test bounds(flatten(Cell(cs5))) == XReflection()(Rectangle(50μm, 4μm))
    end

    @testset "Flattening" begin
        c = Cell{Float64}("test")
        render!(c, Polygon(Point.([(0, 0), (1, 0), (1, 1), (0, 1)])), GDSMeta())
        c2 = Cell{Float64}("outer")
        push!(c2.refs, sref(c, xrefl=true))
        c3 = flatten(c2)
        @test Polygons.orientation((elements(c))[1]) == 1
        @test Polygons.orientation((elements(c3))[1]) == 1

        cs = CoordinateSystem{Float64}("top")
        cs2 = CoordinateSystem{Float64}("attach")
        cs3 = CoordinateSystem{Float64}("bottom")
        ref = sref(cs3; rot=90°)
        ref2 = sref(cs2; rot=-45°, mag=2)
        addref!(cs2, ref)
        render!(cs3, Rectangle(4, 2), GDSMeta())
        pa = Path(Point(0.0, 0.0), α0=90°)
        straight!(pa, 100, Paths.Trace(2.0))
        attach!(pa, ref2, 50; location=-1)
        render!(cs, pa, GDSMeta())
        a = transformation(cs, ref)
        @test origin(a) ≈ Point(-1.0, 50.0)
        @test rotation(a) == 135°
        @test mag(a) == 2
        cflat = flatten(cs)
        @test elements(cflat)[2] == a(Rectangle(4, 2))
        @test footprint(cs) == footprint(Cell(cflat))
        addref!(cs, ref)
        @test transformation(cs, cs.refs[1], ref2, ref) == a
        @test footprint(ref) == Rectangle(lowerleft(ref), upperright(ref))

        # Issue #75
        pa = Path(Point(2, 1), α0=45°)
        turn!(pa, 45°, 20, Paths.Trace(2))
        straight!(pa, 100, Paths.Trace(2))
        c = CoordinateSystem{Float64}("poly")
        render!(c, difference2d(Rectangle(2, 3), Rectangle(1, 2)), GDSMeta())
        attach!(pa, sref(c, Point(1, 2), rot=10°), 100, location=-1)
        Paths.simplify!(pa)
        c2 = CoordinateSystem{Float64}("path")
        render!(c2, pa, GDSMeta())
        c3 = flatten(c2)
        c4 = CoordinateSystem{Float64}("reflref")
        addref!(c4, sref(c2, rot=45°, xrefl=true))
        c5 = flatten(c4)
        poly_2 = vcat(to_polygons.(elements(c5))...)
        poly_3 = vcat(to_polygons.((Rotation(45°) ∘ XReflection()).(elements(c3)))...)

        @test all(poly_2 .≈ poly_3)
    end

    @testset "Mapping metadata" begin
        cs_att = CoordinateSystem("attachment", nm)
        place!(cs_att, Rectangle(20μm, 10μm), GDSMeta(1))
        cs = CoordinateSystem("main", nm)
        place!(cs, Rectangle(10μm, 20μm), GDSMeta(2))
        pa = Path(0μm, 0μm)
        straight!(pa, 100μm, Paths.SimpleTrace(10.0μm))
        turn!(pa, 90°, 50μm)
        attach!(pa, sref(cs_att), 10μm)
        place!(cs, pa, GDSMeta(3))
        map_metadata!(cs, m -> GDSMeta(gdslayer(m) + 1))
        @test element_metadata(cs)[1] == GDSMeta(3)
        @test all(element_metadata(pa) .== GDSMeta(4))
        @test element_metadata(cs_att)[1] == GDSMeta(2)

        cs2 = map_metadata(cs, m -> GDSMeta(gdslayer(m) * 2))
        @test all(element_metadata(pa) .== GDSMeta(4))
        new_pa = structure(refs(cs2)[1])
        @test all(element_metadata(new_pa) .== GDSMeta(8))
        @test element_metadata(structure(refs(new_pa)[1]))[1] == GDSMeta(4)
    end
end
