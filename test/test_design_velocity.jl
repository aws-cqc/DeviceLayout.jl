@testsnippet DesignVelocitySetup begin
    const SM = DeviceLayout.SolidModels
    # A fixed rectangular cutout containing a pad whose position and width are parameters.
    function pad_in_cutout(p)
        cs = CoordinateSystem("pad_in_cutout", nm)
        render!(cs, centered(Rectangle(600μm, 400μm)), SemanticMeta(:cutout))
        render!(
            cs,
            Rectangle(Point(p.x0, -75μm), Point(p.x0 + p.w, 75μm)),
            SemanticMeta(:pad)
        )
        return cs
    end
    const PAD_P0 = (x0=20.0μm, w=240.0μm)
end

@testitem "Design velocities of polygons" setup = [CommonTestSetup, DesignVelocitySetup] begin
    dv = SM.design_velocities(pad_in_cutout, PAD_P0; zlimits=(-150μm, 150μm))
    @test keys(dv) == (:x0, :w)
    @test SM.parameter_unit(dv.x0) == SM.STP_UNIT
    # Inside the pad, a translation is rigid and a width change is linear in x: P1 harmonic
    # interpolation reproduces both exactly.
    for (x, y) in ((100.0, 0.0), (21.0, 70.0), (259.0, -74.0), (140.0, 10.0))
        @test dv.x0(x, y, 0.0) ≈ [1, 0, 0] atol = 1e-9
        @test dv.w(x, y, 0.0) ≈ [(x - 20) / 240, 0, 0] atol = 1e-9
    end
    # Zero on and outside the fixed cutout, and beyond the profile.
    @test iszero(dv.x0(300.0, 0.0, 0.0))
    @test iszero(dv.x0(0.0, 200.0, 0.0))
    @test iszero(dv.x0(350.0, 0.0, 0.0))
    @test iszero(dv.x0(100.0, 0.0, -150.0))
    @test iszero(dv.x0(100.0, 0.0, 200.0))
    # The profile is linear between the plane and zlimits, and V stays in-plane.
    @test dv.x0(100.0, 0.0, 75.0) ≈ [0.5, 0, 0] atol = 1e-9
    @test dv.x0(100.0, 0.0, -30.0) ≈ [0.8, 0, 0] atol = 1e-9
    # Unitful points, and a matrix of points.
    @test dv.w(140μm, 10μm, 0μm) ≈ dv.w(140.0, 10.0, 0.0)
    X = [100.0 140.0 350.0; 0.0 10.0 0.0; 0.0 75.0 0.0]
    @test dv.w(X) ≈ hcat(dv.w(100.0, 0.0, 0.0), dv.w(140.0, 10.0, 75.0), zeros(3))

    # Combined displacement Σ δp V, with parameter changes in any length unit.
    d = SM.design_displacement(dv, (x0=1μm, w=2000nm))
    @test d(140.0, 10.0, 0.0) ≈ dv.x0(140.0, 10.0, 0.0) + 2 * dv.w(140.0, 10.0, 0.0)
    @test_throws ArgumentError SM.design_displacement(dv, (x0=1.0,))
    @test_throws ArgumentError SM.design_displacement(dv, (y=1μm,))

    # Unitless coordinates (μm) give the same field.
    function unitless(p)
        cs = CoordinateSystem{Float64}("unitless")
        render!(cs, centered(Rectangle(600.0, 400.0)), SemanticMeta(:cutout))
        render!(
            cs,
            Rectangle(Point(p.x0, -75.0), Point(p.x0 + p.w, 75.0)),
            SemanticMeta(:pad)
        )
        return cs
    end
    du = SM.design_velocities(unitless, (x0=20.0, w=240.0); zlimits=(-150, 150))
    @test SM.parameter_unit(du.w) == Unitful.NoUnits
    @test du.w(140.0, 10.0, 0.0) ≈ [0.5, 0, 0] atol = 1e-9

    # Entities that `map_meta` skips do not constrain the field: without the cutout, the
    # field around the pad decays to the window boundary instead.
    dskip = SM.design_velocities(
        pad_in_cutout,
        PAD_P0;
        parameters=(:x0,),
        map_meta=m -> layer(m) == :cutout ? nothing : layername(m),
        zlimits=(-150μm, 150μm)
    )
    @test 0 < dskip.x0(300.0, 0.0, 0.0)[1] < 1 # where the skipped cutout's edge is
    @test iszero(dskip.x0(400.0, 0.0, 0.0)) # outside the default window
end

@testitem "Design velocities of overlapping and touching geometry" setup =
    [CommonTestSetup, DesignVelocitySetup] begin
    # A rectangle moving diagonally across a fixed one: where their edges cross, the
    # crossing slides along the fixed edge.
    function crossing(p)
        cs = CoordinateSystem("crossing", nm)
        render!(cs, centered(Rectangle(600μm, 400μm)), SemanticMeta(:box))
        render!(cs, Rectangle(Point(-100μm, -50μm), Point(0μm, 50μm)), SemanticMeta(:a))
        render!(
            cs,
            Rectangle(Point(-50μm + p.s, -20μm + p.s), Point(50μm + p.s, 20μm + p.s)),
            SemanticMeta(:b)
        )
        return cs
    end
    dv = SM.design_velocities(crossing, (s=0.0μm,); zlimits=(-10μm, 10μm))
    @test dv.s(0.0, 20.0, 0.0) ≈ [0, 1, 0] atol = 1e-9
    @test dv.s(0.0, -20.0, 0.0) ≈ [0, 1, 0] atol = 1e-9
    # The fixed edge between the crossings slides tangentially, and stays fixed beyond.
    @test dv.s(0.0, 0.0, 0.0) ≈ [0, 1, 0] atol = 1e-9
    @test dv.s(0.0, 40.0, 0.0) ≈ [0, 1 / 3, 0] atol = 1e-9
    @test dv.s(-50.0, 50.0, 0.0) ≈ [0, 0, 0] atol = 1e-9
    @test dv.s(50.0, 0.0, 0.0) ≈ [1, 1, 0] atol = 1e-9

    # A pad that touches the cutout's edge and slides along it.
    function sliding(p)
        cs = CoordinateSystem("sliding", nm)
        render!(cs, centered(Rectangle(600μm, 400μm)), SemanticMeta(:cutout))
        render!(
            cs,
            Rectangle(Point(p.x0, 100μm), Point(p.x0 + 50μm, 200μm)),
            SemanticMeta(:pad)
        )
        return cs
    end
    dv = SM.design_velocities(sliding, (x0=0.0μm,); zlimits=(-10μm, 10μm))
    @test dv.x0(0.0, 200.0, 0.0) ≈ [1, 0, 0] atol = 1e-9
    @test dv.x0(25.0, 200.0, 0.0) ≈ [1, 0, 0] atol = 1e-9
    @test iszero(dv.x0(100.0, 200.0, 0.0))
    @test iszero(dv.x0(-100.0, 200.0, 0.0))

    # Coincident entities on several layers, and a clipped polygon with a hole, which is
    # rendered as its contours rather than the keyholed polygon of `to_polygons`.
    function clipped(p)
        cs = CoordinateSystem("clipped", nm)
        area = centered(Rectangle(600μm, 400μm))
        render!(cs, area, SemanticMeta(:area_a))
        render!(cs, area, SemanticMeta(:area_b))
        ring = difference2d(
            centered(Rectangle(200μm + p.r, 200μm + p.r)),
            centered(Rectangle(100μm, 100μm))
        )
        render!(cs, ring, SemanticMeta(:ring))
        return cs
    end
    dv = SM.design_velocities(clipped, (r=0.0μm,); zlimits=(-10μm, 10μm))
    @test dv.r(100.0, 0.0, 0.0) ≈ [0.5, 0, 0] atol = 1e-9
    @test dv.r(100.0, 100.0, 0.0) ≈ [0.5, 0.5, 0] atol = 1e-9
    @test iszero(dv.r(50.0, 0.0, 0.0)) # the fixed hole
    @test iszero(dv.r(0.0, 0.0, 0.0))
end

@testitem "Design velocities of curves" setup = [CommonTestSetup, DesignVelocitySetup] begin
    # A B-spline trace, which `x0` translates and `y1` reshapes.
    function trace(p)
        cs = CoordinateSystem("trace", nm)
        pa = Path(Point(p.x0, 0μm); α0=0°)
        bspline!(
            pa,
            [Point(p.x0 + 100μm, p.y1), Point(p.x0 + 200μm, 0μm)],
            0°,
            Paths.Trace(10μm)
        )
        place!(cs, pa, SemanticMeta(:metal))
        return cs
    end
    p0 = (x0=0.0μm, y1=50.0μm)
    dv = SM.design_velocities(trace, p0; parameters=(:x0,), zlimits=(-100μm, 100μm))
    @test dv.x0(0.0, 5.0, 0.0) ≈ [1, 0, 0] atol = 1e-5
    @test_throws r"may only move rigidly" SM.design_velocities(
        trace,
        p0;
        parameters=(:y1,),
        zlimits=(-100μm, 100μm)
    )
    # The edges of a tapered turn are not arcs.
    function taper(p)
        cs = CoordinateSystem("taper", nm)
        pa = Path(Point(0μm, 0μm); α0=0°)
        turn!(pa, 90°, 100μm, Paths.TaperTrace(10μm, p.w))
        place!(cs, pa, SemanticMeta(:metal))
        return cs
    end
    @test_throws r"may only move rigidly" SM.design_velocities(
        taper,
        (w=4.0μm,);
        zlimits=(-100μm, 100μm)
    )
    # Arcs: the corner radius of a rounded pad. The midpoint of a corner's arc moves by
    # 1/√2 - 1 in x and y.
    function rounded(p)
        cs = CoordinateSystem("rounded", nm)
        render!(cs, centered(Rectangle(600μm, 400μm)), SemanticMeta(:cutout))
        place!(cs, Rounded(p.r)(centered(Rectangle(200μm, 150μm))), SemanticMeta(:pad))
        return cs
    end
    dr = SM.design_velocities(rounded, (r=20.0μm,); zlimits=(-100μm, 100μm))
    mid = (80 + 20 / √2, 55 + 20 / √2)
    @test dr.r(mid..., 0.0) ≈ [1 / √2 - 1, 1 / √2 - 1, 0] atol = 1e-3
end

@testitem "Design velocity errors" setup = [CommonTestSetup, DesignVelocitySetup] begin
    # A pad that detaches from the edge it touches changes the layout's topology.
    function detaching(p)
        cs = CoordinateSystem("detaching", nm)
        render!(cs, centered(Rectangle(600μm, 400μm)), SemanticMeta(:cutout))
        render!(
            cs,
            Rectangle(Point(0μm, 100μm + p.y), Point(50μm, 200μm + p.y)),
            SemanticMeta(:pad)
        )
        return cs
    end
    @test_throws r"leaves the edge it lies on" SM.design_velocities(
        detaching,
        (y=0.0μm,);
        zlimits=(-10μm, 10μm)
    )
    # A window that leaves out moving geometry, and one that cuts through a moving edge.
    @test_throws r"does not contain the moving geometry" SM.design_velocities(
        pad_in_cutout,
        PAD_P0;
        zlimits=(-150μm, 150μm),
        window=Rectangle(Point(-300μm, -200μm), Point(100μm, 200μm))
    )
    # A moving vertex inside the window whose edges reach fixed vertices outside it.
    function lead(p)
        cs = CoordinateSystem("lead", nm)
        render!(
            cs,
            Polygon([Point(p.x, 0μm), Point(500μm, -50μm), Point(500μm, 50μm)]),
            SemanticMeta(:lead)
        )
        return cs
    end
    @test_throws r"window cuts a moving edge" SM.design_velocities(
        lead,
        (x=0.0μm,);
        zlimits=(-10μm, 10μm),
        window=centered(Rectangle(400μm, 400μm))
    )
    # A change in the number of entities.
    function appearing(p)
        cs = CoordinateSystem("appearing", nm)
        render!(cs, centered(Rectangle(600μm, 400μm)), SemanticMeta(:cutout))
        p.w > 100μm && render!(cs, centered(Rectangle(p.w, 50μm)), SemanticMeta(:pad))
        return cs
    end
    @test_throws r"number of rendered entities changed" SM.design_velocities(
        appearing,
        (w=100.0μm,);
        zlimits=(-10μm, 10μm)
    )
    # A parameter that moves geometry in z, here through a layer height that depends on it.
    height = Ref(0.0μm)
    lifted(p) = (height[] = p.z; pad_in_cutout(PAD_P0))
    @test_throws r"z or thickness" SM.design_velocities(
        lifted,
        (z=0.0μm,);
        zmap=m -> layer(m) == :pad ? height[] : 0μm,
        zlimits=(-10μm, 10μm)
    )
    # Nothing bounds the profile without zlimits.
    @test_throws r"pass `zlimits`" SM.design_velocities(pad_in_cutout, PAD_P0)
    # Parameters must be continuous, known, and have a step if they are not lengths.
    @test_throws ArgumentError SM.design_velocities(pad_in_cutout, PAD_P0; parameters=(:h,))
    @test_throws r"integer" SM.design_velocities(
        p -> pad_in_cutout(PAD_P0),
        (n=3,);
        zlimits=(-10μm, 10μm)
    )
    @test_throws r"give its finite-difference step" SM.design_velocities(
        p -> pad_in_cutout(PAD_P0),
        (θ=10°,);
        zlimits=(-10μm, 10μm)
    )
    # A parameter that moves nothing gives a warning and a zero velocity.
    dv = @test_logs (:warn, r"does not move any rendered geometry") SM.design_velocities(
        (p -> pad_in_cutout(merge(PAD_P0, (x0=p.x0,)))),
        (x0=20.0μm, unused=1.0μm);
        zlimits=(-10μm, 10μm)
    )
    @test isempty(dv.unused.planes)
    @test iszero(dv.unused(100.0, 0.0, 0.0))
    @test dv.x0(100.0, 0.0, 0.0) ≈ [1, 0, 0] atol = 1e-9
end

@testitem "Design velocities from a SolidModelTarget" setup = [CommonTestSetup] begin
    using .SchematicDrivenLayout
    import .SchematicDrivenLayout.ExamplePDK
    import .SchematicDrivenLayout.ExamplePDK: LayerVocabulary
    const SM = DeviceLayout.SolidModels
    # A pair of pads in a ground-plane cutout on the ExamplePDK single-chip target.
    function qubit(p)
        g = SchematicGraph("qubit")
        floorplan = plan(g)
        cs = floorplan.coordinate_system
        render!(cs, centered(Rectangle(600μm, 400μm)), LayerVocabulary.METAL_NEGATIVE)
        for s in (-1, 1)
            render!(
                cs,
                centered(
                    Rectangle(p.width, 150μm),
                    on_pt=Point(s * (p.gap + p.width) / 2, 0μm)
                ),
                LayerVocabulary.METAL_POSITIVE
            )
        end
        area = centered(Rectangle(2mm, 2mm))
        render!(cs, area, LayerVocabulary.SIMULATED_AREA)
        render!(cs, area, LayerVocabulary.WRITEABLE_AREA)
        render!(cs, area, LayerVocabulary.CHIP_AREA)
        check!(floorplan)
        return floorplan
    end
    target = ExamplePDK.singlechip_solidmodel_target()
    p0 = (gap=40.0μm, width=240.0μm)
    dv = SM.design_velocities(qubit, p0, target)
    # The pads move apart by half the change in the gap, and their centers by half the
    # change in their width.
    @test dv.gap(140.0, 0.0, 0.0) ≈ [0.5, 0, 0] atol = 1e-9
    @test dv.gap(-140.0, 0.0, 0.0) ≈ [-0.5, 0, 0] atol = 1e-9
    @test dv.width(140.0, 0.0, 0.0) ≈ [0.5, 0, 0] atol = 1e-9
    @test iszero(dv.gap(400.0, 0.0, 0.0))
    # The profile ends at the substrate's bottom and the simulation box's top.
    pf = only(dv.gap.planes)
    @test pf.slab == (0.0, 0.0)
    @test pf.support == (-525.0, 1000.0)
    @test dv.gap(140.0, 0.0, -262.5) ≈ [0.25, 0, 0] atol = 1e-9
    # zlimits within the technology's planes take precedence.
    dz =
        SM.design_velocities(qubit, p0, target; parameters=(:gap,), zlimits=(-150μm, 150μm))
    @test only(dz.gap.planes).support == (-150.0, 150.0)
end

@testitem "Mesh morphing" setup = [CommonTestSetup, QuietGmshSetup, DesignVelocitySetup] begin
    import .SolidModels.gmsh
    # Mesh a box containing the pad, morph it in every supported Gmsh format, and read it
    # back with Gmsh.
    sm = SolidModel("morph_test"; overwrite=true)
    cs = pad_in_cutout(PAD_P0)
    zmap(m) = 0μm
    render!(
        sm,
        cs;
        zmap=zmap,
        postrender_ops=[
            ("above", SM.extrude_z!, ("cutout", 100μm)),
            ("below", SM.extrude_z!, ("cutout", -100μm)),
            ("domain", SM.union_geom!, ("above", "below", 3, 3))
        ]
    )
    dv = SM.design_velocities(pad_in_cutout, PAD_P0; zlimits=(-100μm, 100μm))
    δp = (x0=2μm, w=-5μm)
    # Global Gmsh settings changed below, restored at the end.
    order0 = SM.get_gmsh_number("Mesh.ElementOrder")
    optimize0 = SM.get_gmsh_number("Mesh.HighOrderOptimize")
    binary0 = SM.get_gmsh_number("Mesh.Binary")
    version0 = SM.get_gmsh_number("Mesh.MshFileVersion")
    d = SM.design_displacement(dv, δp)
    for order in (1, 2)
        SM.mesh_order(order)
        gmsh.model.mesh.clear()
        gmsh.model.mesh.generate(3)
        for (ext, version) in (("msh2", 2.2), ("msh", 4.1)), binary in (0, 1)
            SM.set_gmsh_option("Mesh.Binary", binary)
            SM.set_gmsh_option("Mesh.MshFileVersion", version)
            src = joinpath(tdir, "morph_o$(order)_$(binary).$ext")
            dst = joinpath(tdir, "morph_o$(order)_$(binary)_morphed.$ext")
            save(src, sm)
            q = SM.morph_mesh(src, dst, dv, δp)
            @test gmsh.model.get_current() == "morph_test"
            @test q.num_inverted == 0
            @test q.num_elements > 0
            @test 0.5 < q.min_jacobian_ratio <= 1 <= q.max_jacobian_ratio < 2
            binary == 1 && @test filesize(dst) == filesize(src)
            groups() = [
                (d, t, gmsh.model.get_physical_name(d, t)) for
                (d, t) in gmsh.model.get_physical_groups()
            ]
            a = SM._with_mesh(m -> (m, groups()), src, version)
            b = SM._with_mesh(m -> (m, groups()), dst, version)
            @test a[2] == b[2]
            version > 3 && @test a[1].tags == b[1].tags
            X0, X1 = a[1].nodes, SM._corresponding_nodes(a[1], b[1], src, dst)
            @test X1 ≈ X0 .+ d(X0) atol = 1e-12
            @test q.max_displacement ≈ maximum(sqrt.(sum(abs2, X1 .- X0, dims=1)))
            # Nodes on the pad's edges end up on the edges of the pad of the new design.
            x0, w = 20.0, 240.0
            x1, w1 = x0 + 2.0, w - 5.0
            on(a, b) = abs(a - b) < 1e-9
            for j in axes(X0, 2)
                on(X0[3, j], 0) || continue
                if (on(X0[1, j], x0) || on(X0[1, j], x0 + w)) && abs(X0[2, j]) <= 75
                    @test on(X1[1, j], on(X0[1, j], x0) ? x1 : x1 + w1)
                elseif on(abs(X0[2, j]), 75) && x0 <= X0[1, j] <= x0 + w
                    @test on(abs(X1[2, j]), 75) && x1 - 1e-9 <= X1[1, j] <= x1 + w1 + 1e-9
                end
            end
        end
    end
    SM.mesh_order(order0, optimize0)
    SM.set_gmsh_option("Mesh.Binary", binary0)
    SM.set_gmsh_option("Mesh.MshFileVersion", version0)

    # A displacement that inverts elements is rejected, and nothing is written.
    src = joinpath(tdir, "morph_o2_1.msh2")
    bad = joinpath(tdir, "inverted.msh2")
    @test_throws r"inverts" SM.morph_mesh(src, bad, X -> -2 .* X)
    @test !isfile(bad)
    q = SM.morph_mesh(src, bad, X -> -2 .* X; check=false)
    @test q.num_inverted == q.num_elements
    # The quality of a sequence of morphs, relative to the first mesh.
    step = joinpath(tdir, "step.msh2")
    SM.morph_mesh(src, step, d)
    SM.morph_mesh(step, joinpath(tdir, "step2.msh2"), d)
    q2 = SM.morph_quality(src, joinpath(tdir, "step2.msh2"))
    @test q2.max_displacement ≈ 2 * SM.morph_quality(src, step).max_displacement rtol = 0.05
    @test_throws r"does not have the elements" SM.morph_quality(
        src,
        joinpath(tdir, "morph_o1_1.msh2")
    )
    # The file's unit scales the displacement: a mesh in mm moves by d / 1000.
    q1 = SM.morph_mesh(src, joinpath(tdir, "mm.msh2"), X -> ones(size(X)); unit=mm)
    @test q1.max_displacement ≈ sqrt(3) / 1000
end

@testsnippet MshSetup begin
    # A unit hexahedron, and the text of an MSH 2.2 file with nodes (3 × N) and elements
    # (lines of type, tags and nodes).
    const HEX = [0 1 1 0 0 1 1 0; 0 0 1 1 0 0 1 1; 0 0 0 0 1 1 1 1]
    msh(nodes, elements) = """
    \$MeshFormat
    2.2 0 8
    \$EndMeshFormat
    \$Nodes
    $(size(nodes, 2))
    $(join(("$j $(nodes[1, j]) $(nodes[2, j]) $(nodes[3, j])" for j in axes(nodes, 2)), "\n"))
    \$EndNodes
    \$Elements
    $(length(elements))
    $(join(("$e $(elements[e])" for e in eachindex(elements)), "\n"))
    \$EndElements
    """
end

@testitem "Morph quality of hexahedra, prisms and pyramids" setup =
    [CommonTestSetup, QuietGmshSetup, MshSetup] begin
    const SM = DeviceLayout.SolidModels
    # A unit hexahedron, prism and pyramid, side by side.
    prism = [0 1 0 0 1 0; 0 0 1 0 0 1; 0 0 0 1 1 1] .+ [2, 0, 0]
    pyramid = [0 1 1 0 0; 0 0 1 1 0; 0 0 0 0 1] .+ [4, 0, 0]
    X = hcat(HEX, prism, pyramid)
    src = joinpath(tdir, "mixed.msh2")
    write(
        src,
        msh(
            X,
            [
                "5 2 1 1 $(join(1:8, ' '))",
                "6 2 1 1 $(join(9:14, ' '))",
                "7 2 1 1 $(join(15:19, ' '))"
            ]
        )
    )
    # A shear preserves the Jacobian determinant everywhere.
    q = SM.morph_mesh(
        src,
        joinpath(tdir, "mixed_sheared.msh2"),
        Y -> [0.5 .* Y[3:3, :]; zeros(2, size(Y, 2))]
    )
    @test q.num_elements == 3
    @test q.num_inverted == 0
    @test q.min_jacobian_ratio ≈ 1
    @test q.max_jacobian_ratio ≈ 1
    @test q.max_strain ≈ 0.5
    # A reflection inverts every element.
    @test_throws r"inverts 3 of 3" SM.morph_mesh(
        src,
        joinpath(tdir, "x.msh2"),
        Y -> [zeros(2, size(Y, 2)); -2 .* Y[3:3, :]]
    )
    # Moving one corner of the hexahedron through the opposite face inverts the element at
    # that corner, although its volume stays positive.
    corner(Y) = (D = zeros(size(Y)); D[3, 7] = -1.5; D)
    q = SM.morph_mesh(src, joinpath(tdir, "x.msh2"), corner; check=false)
    @test q.num_inverted == 1
    @test q.min_jacobian_ratio < 0
    # A scaling of one hexahedron, through a sequence of two morphs.
    src = joinpath(tdir, "hex.msh2")
    write(src, msh(HEX, ["5 2 1 1 $(join(1:8, ' '))"]))
    q = SM.morph_mesh(src, joinpath(tdir, "hex_morphed.msh2"), Y -> 0.1 .* Y)
    @test q.num_elements == 1
    @test q.min_jacobian_ratio ≈ 1.1^3
    SM.morph_mesh(
        joinpath(tdir, "hex_morphed.msh2"),
        joinpath(tdir, "hex_2.msh2"),
        Y -> 0.1 .* Y
    )
    @test SM.morph_quality(src, joinpath(tdir, "hex_2.msh2")).max_jacobian_ratio ≈ 1.21^3
end

@testitem "Morphing physical groups and file formats" setup =
    [CommonTestSetup, QuietGmshSetup, MshSetup] begin
    const SM = DeviceLayout.SolidModels
    # MSH 2.2 repeats an element for each physical group it is in; a morph keeps it so.
    quad = "3 2 2 7 $(join(1:4, ' '))"
    src = joinpath(tdir, "groups.msh2")
    write(
        src,
        msh(HEX, ["5 2 1 1 $(join(1:8, ' '))", quad, replace(quad, "2 2 7" => "2 3 7")])
    )
    dst = joinpath(tdir, "groups_morphed.msh2")
    SM.morph_mesh(src, dst, Y -> 0.1 .* Y)
    SM.morph_mesh(dst, dst, Y -> 0.1 .* Y)
    count_elements(f) =
        parse(Int, first(split(split(read(f, String), "\$Elements\n")[2], '\n')))
    @test count_elements(dst) == 3
    # Elements outside physical groups cannot be kept in MSH 2.2.
    write(src, msh(HEX, ["5 2 1 1 $(join(1:8, ' '))", "3 2 0 7 $(join(1:4, ' '))"]))
    @test_throws r"outside physical groups" SM.morph_mesh(src, dst, Y -> 0.1 .* Y)
    # The destination keeps the source's format, which its extension must not change.
    @test_throws r"use the extension .msh or .msh2" SM.morph_mesh(
        src,
        joinpath(tdir, "x.msh4"),
        Y -> zeros(size(Y))
    )
    # Only Gmsh MSH 2.2 and 4.1 files.
    write(joinpath(tdir, "not_a_mesh.mesh"), "MFEM mesh v1.0\n")
    @test_throws r"Unsupported mesh format" SM.morph_mesh(
        joinpath(tdir, "not_a_mesh.mesh"),
        joinpath(tdir, "x.mesh"),
        Y -> zeros(size(Y))
    )
end
