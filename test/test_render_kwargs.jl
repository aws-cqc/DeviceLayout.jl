# Each unknown keyword warns once until the warnings are reset, so each item resets them first
# and every assertion within an item uses a keyword name of its own.

@testitem "render kwargs: unknown keywords warn" setup = [CommonTestSetup] begin
    using DeviceLayout.SchematicDrivenLayout: ProcessTechnology, ArtworkTarget
    DeviceLayout.reset_render_kwarg_warnings!()

    is_unknown(k) =
        log -> log.level == Logging.Warn && occursin("keyword argument `$k`", log.message)

    cs = CoordinateSystem("kwargs_cs", nm)
    place!(cs, Rectangle(1μm, 1μm), GDSMeta(1, 0))
    pa = Path(nm)
    straight!(pa, 1μm, Paths.Trace(1μm))
    place!(cs, pa, GDSMeta())

    # Structure entry; the entity and path entries reached from it don't repeat the warning
    logs, _ = Test.collect_test_logs() do
        return render!(Cell("c", nm), cs; atoll=1.0nm)
    end
    @test count(is_unknown(:atoll), logs) == 1

    # Once per keyword: repeats are silent, but a different keyword still warns
    logs, _ = Test.collect_test_logs() do
        for _ = 1:5
            render!(Cell("c", nm), cs; atoll=1.0nm)
        end
        return render!(Cell("c", nm), cs; atoll=1.0nm, tol=1.0nm)
    end
    @test count(is_unknown(:atoll), logs) == 0
    @test count(is_unknown(:tol), logs) == 1

    # Through a target
    target = ArtworkTarget(ProcessTechnology((; base=GDSMeta(1, 0)), (;)))
    logs, _ = Test.collect_test_logs() do
        return render!(Cell("c", nm), cs, target; target_typo=1.0nm)
    end
    @test count(is_unknown(:target_typo), logs) == 1

    # `Cell(cs)`, even with no entity to check
    logs, _ = Test.collect_test_logs() do
        return Cell(CoordinateSystem("kwargs_empty", nm); cell_typo=1.0nm)
    end
    @test count(is_unknown(:cell_typo), logs) == 1

    # Entity and path entries called directly
    logs, _ = Test.collect_test_logs() do
        render!(Cell("c", nm), Rectangle(1μm, 1μm), GDSMeta(); entity_typo=1.0nm)
        return render!(Cell("c", nm), pa, GDSMeta(); path_typo=1.0nm)
    end
    @test count(is_unknown(:entity_typo), logs) == 1
    @test count(is_unknown(:path_typo), logs) == 1
end

@testitem "render kwargs: schematic log" setup = [CommonTestSetup] begin
    using DeviceLayout.SchematicDrivenLayout
    DeviceLayout.reset_render_kwarg_warnings!()

    dir = mktempdir()
    target = ArtworkTarget(ProcessTechnology((; base=GDSMeta(1, 0)), (;)))
    # A second schematic with the same typo warns again, in its own log
    for name in ("kwargs_sch", "kwargs_sch_2")
        logs, _ = Test.collect_test_logs() do
            sch = plan(SchematicGraph(name); log_dir=dir)
            for i = 1:50
                place!(sch.coordinate_system, Rectangle(1μm, 1μm) + Point(2i, 0)μm, :base)
            end
            check!(sch)
            # `strict=:warn` sees the warning, which reaches the log file once, not per entity
            @test_throws ErrorException render!(
                Cell("c", nm),
                sch,
                target;
                schematic_typo=1.0nm,
                strict=:warn
            )
        end
        @test count("`schematic_typo`", read(joinpath(dir, "$name.log"), String)) == 1
        @test count(log -> occursin("`schematic_typo`", log.message), logs) == 1
    end
end

@testitem "render kwargs: SolidModel" setup = [CommonTestSetup, QuietGmshSetup] begin
    using DeviceLayout.SchematicDrivenLayout
    import DeviceLayout.SolidModelsExperimental
    DeviceLayout.reset_render_kwarg_warnings!()

    is_unknown(k) =
        log -> log.level == Logging.Warn && occursin("keyword argument `$k`", log.message)

    cs = CoordinateSystem("kwargs_sm_cs", nm)
    place!(cs, Rectangle(1μm, 1μm), SemanticMeta(:base))
    logs, _ = Test.collect_test_logs() do
        render!(SolidModel("kwargs_sm"; overwrite=true), cs; zmapp=identity)
        SolidModels.render_conformal!(
            SolidModel("kwargs_conformal"; overwrite=true),
            cs;
            conformal_typo=1
        )
        return SolidModels.populate_size_fields!(cs; size_typo=1)
    end
    @test count(is_unknown(:zmapp), logs) == 1
    @test count(is_unknown(:conformal_typo), logs) == 1
    @test count(is_unknown(:size_typo), logs) == 1
    @test any(log -> startswith(log.message, "`populate_size_fields!` does not"), logs)

    # In the target's rendering options, through a schematic
    dir = mktempdir()
    tech = ProcessTechnology((;), (; height=(; base=0μm), thickness=(; base=1μm)))
    logs, _ = Test.collect_test_logs() do
        sch = plan(SchematicGraph("kwargs_sm_sch"); log_dir=dir)
        for i = 1:20
            place!(sch.coordinate_system, Rectangle(1μm, 1μm) + Point(2i, 0)μm, :base)
        end
        check!(sch)
        return render!(
            SolidModel("kwargs_sm_sch"; overwrite=true),
            sch,
            SolidModelTarget(tech; target_sm_typo=1);
            strict=:no
        )
    end
    @test count("`target_sm_typo`", read(joinpath(dir, "kwargs_sm_sch.log"), String)) == 1
    @test count(is_unknown(:target_sm_typo), logs) == 1

    # Each conformal schematic render warns in its own log, and not about the target's
    # options that `render!` declares
    for name in ("kwargs_conformal_sch", "kwargs_conformal_sch_2")
        conformal_logs, _ = Test.collect_test_logs() do
            sch = plan(SchematicGraph(name); log_dir=dir)
            place!(sch.coordinate_system, Rectangle(1μm, 1μm), :base)
            check!(sch)
            @test_throws ErrorException SolidModels.render_conformal!(
                SolidModel(name; overwrite=true),
                sch,
                SolidModelTarget(tech; skip_unused_layers=true, auto_union=true);
                conformal_sch_typo=1,
                strict=:warn
            )
        end
        @test count("`conformal_sch_typo`", read(joinpath(dir, "$name.log"), String)) == 1
        @test count(log -> log.level == Logging.Warn, conformal_logs) == 1
    end

    # Same for the experimental schematic render, which also opens its own log
    exp_target = SolidModelsExperimental.SolidModelTarget(
        SolidModelsExperimental.SourceStack(
            :metal => SolidModelsExperimental.SourceLayer(
                SolidModelsExperimental.METAL;
                level=1,
                offset=0.0,
                thickness=0.0
            );
            levels=(1 => 0.0,)
        )
    )
    for name in ("kwargs_exp_sch", "kwargs_exp_sch_2")
        exp_logs, _ = Test.collect_test_logs() do
            cs = CoordinateSystem{Float64}("$(name)_cs")
            place!(cs, Rectangle(10.0, 10.0), SolidModelsExperimental.LayerRef(:metal))
            sg = SchematicGraph(name)
            add_node!(sg, BasicComponent(cs); base_id="q1")
            sch = check!(plan(sg; log_dir=dir))
            @test_throws ErrorException render!(
                SolidModel(name; overwrite=true),
                sch,
                exp_target;
                select_terminals=false, # the fixture has no Ground locator
                exp_sch_typo=1,
                strict=:warn
            )
        end
        @test count("`exp_sch_typo`", read(joinpath(dir, "$name.log"), String)) == 1
        @test count(log -> log.level >= Logging.Warn, exp_logs) == 1
    end
end

@testitem "render kwargs: known keywords don't warn" setup =
    [CommonTestSetup, QuietGmshSetup] begin
    using DeviceLayout.SchematicDrivenLayout
    DeviceLayout.reset_render_kwarg_warnings!()

    cs = CoordinateSystem("known_cs", nm)
    place!(cs, Rectangle(1μm, 1μm), GDSMeta(1, 0))
    place!(cs, Circle(1μm), GDSMeta(1, 0))
    sm_cs = CoordinateSystem("known_sm_cs", nm)
    place!(sm_cs, Circle(1μm), SemanticMeta(:base))
    target = ArtworkTarget(ProcessTechnology((; base=GDSMeta(1, 0)), (;)))
    tech = ProcessTechnology((;), (; height=(; base=0μm), thickness=(; base=1μm)))

    @test_logs min_level = Logging.Warn begin
        render!(Cell("c", nm), cs; atol=0.5nm, rtol=1e-3, map_meta=identity)
        render!(Cell("c", nm), cs; Δθ=5°)
        render!(Cell("c", nm), cs; simulation=true, artwork=false, solidmodel=false)
        render!(Cell("c", nm), cs, target) # Target sets `simulation` and `artwork`
        render!(
            SolidModel("known_sm"; overwrite=true),
            sm_cs;
            zmap=(_) -> 0nm,
            auto_union=true,
            curvature_sizing=false,
            Δθ=10°
        )
        sch = plan(SchematicGraph("known_sch"); log_dir=nothing)
        place!(sch.coordinate_system, Circle(1μm), :base)
        check!(sch)
        render!(
            SolidModel("known_sch"; overwrite=true),
            sch,
            SolidModelTarget(tech; skip_unused_layers=true);
            component_fragment=:global,
            post_fragment_ops=[]
        )
    end
end

@testitem "render kwargs: registration" setup = [CommonTestSetup] begin
    DeviceLayout.reset_render_kwarg_warnings!()
    cs = CoordinateSystem("reg_cs", nm)
    place!(cs, Rectangle(1μm, 1μm), GDSMeta(1, 0))

    # OptionalStyle registers its flag
    place!(cs, optional_entity(Rectangle(1μm, 1μm), :kwargs_test_flag), GDSMeta(1, 0))
    @test_logs min_level = Logging.Warn render!(Cell("c", nm), cs; kwargs_test_flag=true)

    # Manual registration, of a name that is new each time this item runs
    manual = Symbol(:kwargs_test_manual_, gensym())
    logs, _ = Test.collect_test_logs() do
        return render!(Cell("c", nm), cs; manual => true)
    end
    @test count(log -> occursin("keyword argument `$manual`", log.message), logs) == 1
    DeviceLayout.register_render_kwarg!(manual)
    @test_logs min_level = Logging.Warn render!(Cell("c", nm), cs; manual => true)
end
