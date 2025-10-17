@testitem "Texts" setup = [CommonTestSetup] begin
    @testset "Load and save" begin
        c1 = load(joinpath(dirname(@__FILE__), "texts.gds"))["noname"]
        dir = mktempdir()
        fname = joinpath(dir, "texts2.gds")
        save(fname, c1)
        c2 = load(fname)["noname"]
        for c in (c1, c2)
            @test length(c.texts) == 9

            # test contents of texts
            idx = sortperm(c.texts, by=t -> t.origin.x)
            sort!(c.texts, by=t -> t.origin.x)
            idx2 = sortperm(c.texts, by=t -> t.origin.y, lt=Base.isgreater)
            sort!(c.texts, by=t -> t.origin.y, lt=Base.isgreater)
            @test mapreduce(x -> x.text, *, c.texts) == "abcdefghijklmnopqrstuvwxyz"

            # layer, datatype work
            @test c.text_metadata[idx][idx2][1] == GDSMeta(1, 2)

            # alignment works as intended
            @test all(c.texts[i].yalign == DeviceLayout.Align.TopEdge() for i = 1:3)
            @test all(c.texts[i].yalign == DeviceLayout.Align.YCenter() for i = 4:6)
            @test all(c.texts[i].yalign == DeviceLayout.Align.BottomEdge() for i = 7:9)
            @test all(c.texts[i].xalign == DeviceLayout.Align.LeftEdge() for i in (1, 4, 7))
            @test all(c.texts[i].xalign == DeviceLayout.Align.XCenter() for i in (2, 5, 8))
            @test all(
                c.texts[i].xalign == DeviceLayout.Align.RightEdge() for i in (3, 6, 9)
            )

            # width, scale
            @test c.texts[1].width == 10nm
            @test !(c.texts[1].can_scale)

            # origin
            @test c.texts[5].origin == Point(50.0, -50.0)nm

            # rot, mag, xrefl
            @test c.texts[5].rot == 20.0°
            @test c.texts[5].mag ≈ 0.02
            @test c.texts[9].xrefl
        end
    end

    @testset "text!" begin
        c = Cell("abc", nm)
        text!(
            c,
            "hello",
            Point(10, 10)μm,
            GDSMeta(1, 0);
            width=20μm,
            xalign=Align.LeftEdge(),
            yalign=Align.TopEdge()
        )

        tt = Texts.Text("abc", Point(5, 10)μm)
        text!(c, tt, GDSMeta(2, 3))
        c2 = Cell("parent", nm)

        addref!(c2, c, inv(transformation(tt)))
        c3 = flatten(c2; metadata_filter=DeviceLayout.layer_inclusion([GDSMeta(2, 3)], []))
        @test length(c3.texts) == 1

        flatten!(c2)
        @test c2.texts[2] == tt - Point(5, 10)μm

        cs = CoordinateSystem("parent2", nm)
        addref!(cs, c; rot=180°)
        flatten!(cs; metadata_filter=DeviceLayout.layer_inclusion([], [GDSMeta(2, 3)]))
        @test length(cs.elements) == 1
        @test cs.elements[1] ≈ RotationPi()(c.texts[1])
        @test RotationPi()(c).texts[1] ≈ cs.elements[1]

        text!(c, "def", GDSMeta(4, 5))
    end
end
