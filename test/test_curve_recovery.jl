@testitem "Curve recovery — preserved vertices survive Clipper" setup = [CommonTestSetup] begin
    using DeviceLayout: Point, Polygon, union2d
    snap(p) = DeviceLayout.Polygons.clipperize(p)

    R = 10.0
    N = 64
    circ = [Point(R * cos(t), R * sin(t)) for t in range(0, 2π, length=N + 1)[1:(end - 1)]]
    poly = Polygon(circ)
    in_int = snap.(circ)

    sq = Polygon([
        Point(1000.0, 1000.0),
        Point(1001.0, 1000.0),
        Point(1001.0, 1001.0),
        Point(1000.0, 1001.0)
    ])
    res = union2d(poly, sq)

    function allcontours(node, acc)
        for c in node.children
            push!(acc, c.contour)
            allcontours(c, acc)
        end
        return acc
    end
    cons = allcontours(res.tree, Vector{Point{Float64}}[])
    circ_con = argmax(length, cons)
    out_set = Set(snap.(circ_con))

    @test all(p -> p in out_set, in_int)
    @test length(circ_con) == N
end

@testitem "Curve recovery — discretize_with_provenance captures arc runs" setup =
    [CommonTestSetup] begin
    using DeviceLayout: Point, CurvilinearPolygon, Paths, Polygon
    using DeviceLayout.Curvilinear: discretize_with_provenance
    # Create a square with one curved edge: (0,0) -> (10,0) -> Turn -> (0,10)
    # Turn from (10,0) with α0=90° (pointing up), radius 10, sweeping 90° ends at (0,10)
    pts = Point{Float64}[(0, 0), (10, 0), (0, 10)]
    turn = Paths.Turn(90.0°, 10.0; p0=Point(10.0, 0.0), α0=90.0°)
    cpoly = CurvilinearPolygon(pts, [turn], [2])
    polys, runs = discretize_with_provenance([cpoly], Float64)
    @test polys isa Vector{<:Polygon}
    @test length(runs) == 1
    @test runs[1].curve.p0 === turn.p0 # Can't just check segment identity bc Julia 1.10 makes a copy in Curvilinear constructor
    @test runs[1].curve.α0 === turn.α0
    @test runs[1].curve.α === turn.α
    @test runs[1].curve.r === turn.r
    @test runs[1].run[1] == DeviceLayout.Polygons.clipperize(Point(10.0, 0.0))
    @test length(runs[1].run) ≥ 3
end

@testitem "Curve recovery — match_run cyclic + bidirectional" setup = [CommonTestSetup] begin
    using DeviceLayout: Point
    M = DeviceLayout.Curvilinear   # match_run is internal (not exported)
    ip(x) = Point{Int64}(x, 0)
    contour = ip.([1, 2, 3, 4, 5, 6])
    @test M.match_run(contour, ip.([2, 3, 4])) == (start=2, reversed=false)
    @test M.match_run(contour, ip.([5, 6, 1])) == (start=5, reversed=false)  # cyclic wrap
    @test M.match_run(contour, ip.([4, 3, 2])) == (start=2, reversed=true)   # reversed
    @test M.match_run(contour, ip.([2, 4, 3])) === nothing                   # no contiguous match
end

@testitem "Curve recovery — substitute_curves recovers one arc" setup = [CommonTestSetup] begin
    using DeviceLayout:
        Point, CurvilinearPolygon, CurvilinearRegion, Paths, union2d, Polygon
    using DeviceLayout.Curvilinear: discretize_with_provenance, substitute_curves
    # A CurvilinearPolygon whose exterior has a single recoverable arc.
    pts = Point{Float64}[(0, 0), (10, 0), (0, 10)]
    turn = Paths.Turn(90.0°, 10.0; p0=Point(10.0, 0.0), α0=90.0°)
    region = CurvilinearRegion(CurvilinearPolygon(pts, [turn], [2]))

    polys, runs = discretize_with_provenance([region], Float64)
    sq = Polygon([
        Point(1e4, 1e4),
        Point(1e4 + 1, 1e4),
        Point(1e4 + 1, 1e4 + 1),
        Point(1e4, 1e4 + 1)
    ])
    clipped = union2d(polys, [sq])              # ClippedPolygon, arc untouched
    report = Tuple[]
    out = substitute_curves(clipped, runs; report=report)
    @test out isa Vector{<:CurvilinearRegion}
    @test sum(length(r.exterior.curves) for r in out) == 1
    @test count(t -> t[1] == :recovered, report) == 1
    @test count(t -> t[1] == :clipped, report) == 0
end

@testitem "Curve recovery — substitute_curves recovers two arcs in order" setup =
    [CommonTestSetup] begin
    using DeviceLayout:
        Point, CurvilinearPolygon, CurvilinearRegion, Paths, union2d, Polygon
    using DeviceLayout.Curvilinear: discretize_with_provenance, substitute_curves
    # A CurvilinearPolygon with two recoverable arcs (two rounded corners) on its exterior.
    # Exercises the multi-curve ordering path: matched runs must be sorted by start index
    # so to_polygons' monotonic cursor doesn't drop/misorder vertices.
    t1 = Paths.Turn(90.0°, 2.0; p0=Point(10.0, 0.0), α0=0.0°)   # (10,0) heading +x → (12,2)
    t2 = Paths.Turn(90.0°, 2.0; p0=Point(12.0, 10.0), α0=90.0°) # (12,10) heading +y → (10,12)
    pts = Point{Float64}[(0, 0), (10, 0), (12, 2), (12, 10), (10, 12), (0, 12)]
    region = CurvilinearRegion(CurvilinearPolygon(pts, [t1, t2], [2, 4]))

    polys, runs = discretize_with_provenance([region], Float64)
    sq = Polygon([
        Point(1e4, 1e4),
        Point(1e4 + 1, 1e4),
        Point(1e4 + 1, 1e4 + 1),
        Point(1e4, 1e4 + 1)
    ])
    clipped = union2d(polys, [sq])
    report = Tuple[]
    out = substitute_curves(clipped, runs; report=report)
    # Clipper may order the disjoint square's region first, so select the curved
    # region by curve count rather than assuming an index.
    curved = out[findfirst(r -> !isempty(r.exterior.curves), out)]
    @test length(curved.exterior.curves) == 2
    # curve_start_idx must be ascending after sorting.
    @test issorted(curved.exterior.curve_start_idx)
    # to_polygons must yield more points than the 6 original vertices (the two curves
    # each contribute discretized interior points), not a degenerate near-empty polygon.
    @test length(DeviceLayout.to_polygons(curved.exterior).p) > 6
    @test count(t -> t[1] == :recovered, report) == 2
    @test count(t -> t[1] == :clipped, report) == 0
end

@testitem "Curve recovery — recover_curves end to end" setup = [CommonTestSetup] begin
    using DeviceLayout: Point, CurvilinearPolygon, CurvilinearRegion, Paths, Polygon
    using DeviceLayout: recover_curves, union2d, union2d_curved, difference2d_curved
    pts = Point{Float64}[(0, 0), (10, 0), (0, 10)]
    turn = Paths.Turn(90.0°, 10.0; p0=Point(10.0, 0.0), α0=90.0°)
    region = CurvilinearRegion(CurvilinearPolygon(pts, [turn], [2]))
    sq = Polygon([
        Point(1e4, 1e4),
        Point(1e4 + 1, 1e4),
        Point(1e4 + 1, 1e4 + 1),
        Point(1e4, 1e4 + 1)
    ])

    a = recover_curves(union2d, region, sq)
    b = union2d_curved(region, sq)
    @test a isa Vector{<:CurvilinearRegion}
    @test b isa Vector{<:CurvilinearRegion}
    @test sum(length(r.exterior.curves) for r in a) == 1
    @test sum(length(r.exterior.curves) for r in b) == 1
    # report kwarg flows through
    report = Tuple[]
    recover_curves(union2d, region, sq; report=report)
    @test count(t -> t[1] == :recovered, report) == 1
end

@testitem "Curve recovery — interface methods" setup = [CommonTestSetup] begin
    using DeviceLayout: Point, CurvilinearPolygon, CurvilinearRegion, Paths, Polygon
    using DeviceLayout: recover_curves, union2d, union2d_curved, difference2d_curved
    pts = Point{Float64}[(0, 0), (10, 0), (0, 10)]
    turn = Paths.Turn(90.0°, 10.0; p0=Point(10.0, 0.0), α0=90.0°)
    region = CurvilinearRegion(CurvilinearPolygon(pts, [turn], [2]))
    sq = Polygon([
        Point(1e4, 1e4),
        Point(1e4 + 1, 1e4),
        Point(1e4 + 1, 1e4 + 1),
        Point(1e4, 1e4 + 1)
    ])
    cs1 = CoordinateSystem{Float64}("test1")
    cs2 = CoordinateSystem{Float64}("test2")
    place!(cs1, region, :curved)
    place!(cs1, sq, :square)
    place!(cs2, sq, :square)
    out = union2d_curved(region, sq)
    a = union2d_curved(cs1)
    b = union2d_curved(region, cs2)
    c = union2d_curved(cs1 => :curved, cs1 => :square)
    d = union2d_curved([sq, cs1 => :curved])
    @test isempty(to_polygons(xor2d(out, a)))
    @test isempty(to_polygons(xor2d(a, b)))
    @test isempty(to_polygons(xor2d(b, c)))
    @test isempty(to_polygons(xor2d(c, d)))
    # Mutli-polygon ClippedPolygon input
    multi_cp = union2d(sq, sq + Point(10, 10))
    @test isempty(to_polygons(xor2d(multi_cp, union2d_curved(multi_cp))))
end

@testitem "Curve recovery — Path round trips" setup = [CommonTestSetup] begin
    using DeviceLayout: Point, CurvilinearPolygon, CurvilinearRegion, Paths, Polygon
    using DeviceLayout: recover_curves, union2d, union2d_curved, difference2d_curved
    # Trace
    pa = Path()
    turn!(pa, 90°, 50μm, Paths.Trace(5μm))
    turn!(pa, 90°, 50μm, Paths.Trace(5μm))
    out = union2d_curved(pa)
    @test length(out) == 1 # Unioned into a single CurvilinearRegion
    curved = out[1]
    @test length(curved.exterior.curves) == 4 # original 4 curves
    @test length(curved.exterior.p) == 6 # original 6 points
    @test isempty(to_polygons(xor2d(curved, pathtopolys(pa))))

    # CPW
    pa = Path()
    turn!(pa, 90°, 50μm, Paths.CPW(5μm, 5μm))
    turn!(pa, 90°, 50μm, Paths.CPW(5μm, 5μm))
    out = union2d_curved(pa)
    @test length(out) == 2
    curved = out[1]
    @test length(curved.exterior.curves) == 4 # original 4 curves
    @test length(curved.exterior.p) == 6 # original 6 points
    @test isempty(to_polygons(xor2d(out, pathtopolys(pa))))

    # Zero-length continuous-style node (as left around attach!/launch!): skipped rather
    # than discretized, so the rest of the path still recovers its curves.
    pa = Path()
    straight!(pa, 0μm, Paths.Trace(5μm))
    turn!(pa, 90°, 50μm)
    out = union2d_curved(pa)
    @test length(out) == 1
    curved = out[1]
    @test length(curved.exterior.curves) == 2
    @test isempty(to_polygons(xor2d(curved, pathtopolys(pa))))

    # Generic curves
    pa = Path()
    turn!(pa, 90°, 50μm, Paths.TaperTrace(5μm, 10μm))
    out = union2d_curved(pa)
    @test length(out) == 1 # Unioned into a single CurvilinearRegion
    curved = out[1]
    @test length(curved.exterior.curves) == 2 # Recognizes offset turn
    @test isempty(to_polygons(xor2d(curved, pathtopolys(pa))))
    # BSpline offset
    pa = Path()
    bspline!(pa, [Point(0μm, 1mm)], 180°, Paths.Trace(10μm))
    out = union2d_curved(pa)
    @test length(out) == 1 # Unioned into a single CurvilinearRegion
    curved = out[1]
    @test length(curved.exterior.curves) == 2
    @test isempty(to_polygons(xor2d(curved, pathtopolys(pa))))
end

@testitem "Curve recovery — Rounded polygon round trips" setup = [CommonTestSetup] begin
    using DeviceLayout: Point, CurvilinearPolygon, CurvilinearRegion, Paths, Polygon
    using DeviceLayout: recover_curves, union2d, union2d_curved, difference2d_curved
    r = centered(Rectangle(10.0μm, 10.0μm))
    rr = Rounded(r, 1μm)
    out = intersect2d_curved(r, rr)
    curved = out[1]
    @test length(curved.exterior.curves) == 4
    @test length(curved.exterior.p) == 8
    @test isempty(to_polygons(xor2d(curved, Curvilinear._normalize_curved_clip_arg(rr))))
    r2 = centered(Rectangle(100μm, 2μm))
    out = union2d_curved(rr, r2)
    curved = out[1]
    @test length(curved.exterior.curves) == 4
    @test length(curved.exterior.p) == 16
    @test isempty(
        to_polygons(xor2d(curved, [r2, Curvilinear._normalize_curved_clip_arg(rr)]))
    )
    out = difference2d_curved(rr, r2)
    @test length(out) == 2
    @test length(out[1].exterior.curves) == 2
    @test length(out[2].exterior.curves) == 2
    @test isempty(
        to_polygons(
            xor2d(out, difference2d(Curvilinear._normalize_curved_clip_arg(rr), r2))
        )
    )
end

@testitem "Curve recovery — single untouched arc, varied radius" setup = [CommonTestSetup] begin
    using DeviceLayout: Point, CurvilinearPolygon, CurvilinearRegion, Paths, Polygon
    using DeviceLayout: recover_curves, union2d, to_polygons
    # An arc-bearing region unioned with a DISJOINT square recovers its arc intact
    # across a range of radii (the integer-grid run survives byte-identical).
    for R in (1.0, 100.0, 1.0μm, 100.0μm, 1.0mm)
        z = zero(R)
        T = typeof(R)
        um = DeviceLayout.onemicron(T)
        turn = Paths.Turn(90.0°, R; p0=Point(R, z), α0=90.0°)  # (R,0) heading +y → (0,R)
        region = CurvilinearRegion(
            CurvilinearPolygon(Point{T}[(z, z), (R, z), (z, R)], [turn], [2])
        )
        sq = Polygon([
            Point(1e4, 1e4)um,
            Point(1e4 + 1, 1e4)um,
            Point(1e4 + 1, 1e4 + 1)um,
            Point(1e4, 1e4 + 1)um
        ])
        report = Tuple[]
        out = recover_curves(union2d, region, sq; report=report)
        @test count(t -> t[1] == :recovered, report) == 1
        @test count(t -> t[1] == :clipped, report) == 0
        curved = out[findfirst(r -> !isempty(r.exterior.curves), out)]
        @test length(curved.exterior.curves) == 1
        @test length(curved.exterior.p) == 3
        @test length(to_polygons(curved.exterior).p) > 0
        @test isempty(to_polygons(xor2d(region, curved)))
    end
end

@testitem "Curve recovery — seam-rotation (union with self)" setup = [CommonTestSetup] begin
    using DeviceLayout: Point, CurvilinearPolygon, CurvilinearRegion, Paths, Polygon
    using DeviceLayout: recover_curves, union2d
    # A rectangle with one rounded corner unioned with a copy of itself. Clipper
    # rotates the start vertex of the output contour so the seam lands on a kink.
    # The cyclic match_run handles it.
    t = Paths.Turn(90.0°, 2.0; p0=Point(18.0, 0.0), α0=0.0°)  # (18,0) heading +x → (20,2)
    region = CurvilinearRegion(
        CurvilinearPolygon(
            Point{Float64}[(0, 0), (18, 0), (20, 2), (20, 10), (0, 10)],
            [t],
            [2]
        )
    )
    report = Tuple[]
    out = recover_curves(union2d, region, region; report=report)
    # The arc survives the union-with-self and is recovered onto the merged contour.
    @test count(t -> t[1] == :recovered, report) ≥ 1
    @test count(t -> t[1] == :clipped, report) == 0
    curved = out[findfirst(r -> !isempty(r.exterior.curves), out)]
    @test length(curved.exterior.curves) == 1
    @test length(curved.exterior.p) == 5
    @test curved.exterior.curves[1] isa Paths.Turn
    @test isempty(to_polygons(xor2d(region, out)))
end

@testitem "Curve recovery — reversed winding (arc on a hole)" setup = [CommonTestSetup] begin
    using DeviceLayout: Point, CurvilinearPolygon, CurvilinearRegion, Paths, Polygon
    using DeviceLayout.Curvilinear: recover_curves, difference2d, discretize_with_provenance
    # Differencing a curved region out of a solid square puts the arc on the
    # resulting hole boundary, whose winding is reversed relative to the input
    # exterior. The reversed branch of match_run must fire to recover it.
    plus = Polygon([Point(0.0, 0), Point(30, 0), Point(30, 30), Point(0, 30)])
    tm = Paths.Turn(90.0°, 2.0; p0=Point(18.0, 10.0), α0=0.0°)  # (18,10) → (20,12)
    minus = CurvilinearRegion(
        CurvilinearPolygon(
            Point{Float64}[(10, 10), (18, 10), (20, 12), (20, 20), (10, 20)],
            [tm],
            [2]
        )
    )
    report = Tuple[]
    out = recover_curves(difference2d, plus, minus; report=report)
    @test count(t -> t[1] == :recovered, report) == 1
    @test count(t -> t[1] == :clipped, report) == 0
    # The recovered curve lands on a hole, not the exterior.
    @test sum(length(r.exterior.curves) for r in out) == 0
    @test sum(sum(length(h.curves) for h in r.holes; init=0) for r in out) == 1

    # Confirm the reversed branch of match_run actually fired on the hole contour.
    R = Float64
    polys_plus, _ = discretize_with_provenance([plus], R)
    polys_minus, runs_m = discretize_with_provenance([minus], R)
    clipped = difference2d(polys_plus, polys_minus)
    # Output is geometrically identical
    @test isempty(to_polygons(xor2d(clipped, out)))
    saw_reversed = Ref(false)
    walk(node) =
        for c in node.children
            snapped = DeviceLayout.Polygons.clipperize.(collect(c.contour))
            for pr in runs_m
                hit = Curvilinear.match_run(snapped, pr.run)
                (hit !== nothing && hit.reversed) && (saw_reversed[] = true)
            end
            walk(c)
        end
    walk(clipped.tree)
    @test saw_reversed[]

    # Now curve recovery with CR with a hole as input
    self_union = union2d_curved(out)
    @test sum(length(r.exterior.curves) for r in self_union) == 0
    @test sum(sum(length(h.curves) for h in r.holes; init=0) for r in self_union) == 1
    @test isempty(to_polygons(xor2d(self_union, out)))
    @test isempty(to_polygons(xor2d(self_union, union2d(out))))

    # Clipper op returns ClippedPolygon with grandchildren
    outer = centered(Rectangle(100.0, 100.0))
    curved_gc = difference2d_curved(outer, out)
    @test length(curved_gc) == 2 # Inner is separate region
    @test sum(length(r.exterior.curves) for r in curved_gc) == 1
    @test sum(sum(length(h.curves) for h in r.holes; init=0) for r in curved_gc) == 0
    @test isempty(to_polygons(xor2d(curved_gc, difference2d(outer, out))))
    @test isempty(to_polygons(xor2d(curved_gc, difference2d(outer, out))))
end

@testitem "Curve recovery — arcs on exterior and a hole" setup = [CommonTestSetup] begin
    using DeviceLayout: Point, CurvilinearPolygon, CurvilinearRegion, Paths, Polygon
    using DeviceLayout: recover_curves, difference2d
    # A region with an arc on its exterior, differenced by a curved region that
    # becomes a hole carrying its own arc. Both arcs must be recovered, one on
    # the exterior contour and one on the hole contour.
    te = Paths.Turn(90.0°, 2.0; p0=Point(28.0, 0.0), α0=0.0°)  # exterior arc (28,0) → (30,2)
    plus = CurvilinearRegion(
        CurvilinearPolygon(
            Point{Float64}[(0, 0), (28, 0), (30, 2), (30, 30), (0, 30)],
            [te],
            [2]
        )
    )
    th = Paths.Turn(90.0°, 2.0; p0=Point(18.0, 10.0), α0=0.0°)  # hole arc (18,10) → (20,12)
    minus = CurvilinearRegion(
        CurvilinearPolygon(
            Point{Float64}[(10, 10), (18, 10), (20, 12), (20, 20), (10, 20)],
            [th],
            [2]
        )
    )
    report = Tuple[]
    out = recover_curves(difference2d, plus, minus; report=report)
    @test count(t -> t[1] == :recovered, report) == 2
    @test count(t -> t[1] == :clipped, report) == 0
    n_ext = sum(length(r.exterior.curves) for r in out)
    n_hole = sum(sum(length(h.curves) for h in r.holes; init=0) for r in out)
    @test n_ext == 1   # one arc on an exterior contour
    @test n_hole == 1  # one arc on a hole contour
    @test isempty(to_polygons(xor2d(difference2d(plus, minus), out)))
end

@testitem "Curve recovery — annulus / collision probe" setup = [CommonTestSetup] begin
    using DeviceLayout: Point, CurvilinearPolygon, CurvilinearRegion, Paths, Polygon
    using DeviceLayout.Curvilinear: recover_curves, union2d, discretize_with_provenance
    # Two arcs of different radii in one geometry. Each must map to its own curve.
    # Different radii produce different integer runs, so no cross-match collision
    # is possible — we assert the runs differ to make that intent explicit.
    t1 = Paths.Turn(90.0°, 2.0; p0=Point(10.0, 0.0), α0=0.0°)   # r=2: (10,0) → (12,2)
    t2 = Paths.Turn(90.0°, 5.0; p0=Point(12.0, 10.0), α0=90.0°) # r=5: (12,10) → (7,15)
    pts = Point{Float64}[(0, 0), (10, 0), (12, 2), (12, 10), (7, 15), (0, 15)]
    region = CurvilinearRegion(CurvilinearPolygon(pts, [t1, t2], [2, 4]))
    sq = Polygon([
        Point(1e4, 1e4),
        Point(1e4 + 1, 1e4),
        Point(1e4 + 1, 1e4 + 1),
        Point(1e4, 1e4 + 1)
    ])
    report = Tuple[]
    out = recover_curves(union2d, region, sq; report=report)
    @test count(t -> t[1] == :recovered, report) == 2
    @test count(t -> t[1] == :clipped, report) == 0
    curved = out[findfirst(r -> !isempty(r.exterior.curves), out)]
    @test length(curved.exterior.curves) == 2
    radii = sort([c.r for c in curved.exterior.curves])
    @test radii == [2.0, 5.0]   # each arc recovered as its own distinct curve
    @test isempty(to_polygons(xor2d(region, curved)))

    # The two provenance runs differ → no cross-match collision is possible.
    _, runs = discretize_with_provenance([region], Float64)
    @test runs[1].run != runs[2].run
end

@testitem "Curve recovery — straight edge cuts an arc (clipped, not recovered)" setup =
    [CommonTestSetup] begin
    using DeviceLayout: Point, CurvilinearPolygon, CurvilinearRegion, Paths, Polygon
    using DeviceLayout: recover_curves, difference2d
    # A straight rectangle that crosses the arc interior. Clipper inserts a new
    # intersection vertex on the arc, breaking its run. Recovery is all-or-nothing,
    # so the cut arc is reported :clipped (not recovered) and falls back to polyline.
    t = Paths.Turn(90.0°, 2.0; p0=Point(18.0, 10.0), α0=0.0°)  # (18,10) → (20,12)
    region = CurvilinearRegion(
        CurvilinearPolygon(
            Point{Float64}[(10, 10), (18, 10), (20, 12), (20, 20), (10, 20)],
            [t],
            [2]
        )
    )
    cutter = Polygon([
        Point(18.5, 10.5),
        Point(25.0, 10.5),
        Point(25.0, 13.0),
        Point(18.5, 13.0)
    ])
    report = Tuple[]
    out = recover_curves(difference2d, region, cutter; report=report)
    @test count(t -> t[1] == :recovered, report) == 0
    @test count(t -> t[1] == :clipped, report) == 1
    @test sum(length(r.exterior.curves) for r in out) == 0  # polyline fallback
end

@testitem "Curve recovery — full circle across the seam" setup = [CommonTestSetup] begin
    using DeviceLayout: Point, CurvilinearPolygon, CurvilinearRegion, Paths, Polygon
    using DeviceLayout: recover_curves, union2d, to_polygons
    # A closed-loop circle built from two half-circle Turns (a single 360° Turn is
    # degenerate — start and end vertices coincide), unioned with a disjoint square.
    # Both half-arcs must be recovered onto the single closed contour.
    R = 10.0
    t1 = Paths.Turn(180.0°, R; p0=Point(R, 0.0), α0=90.0°)    # top half: (R,0) → (-R,0)
    t2 = Paths.Turn(180.0°, R; p0=Point(-R, 0.0), α0=-90.0°)  # bottom half: (-R,0) → (R,0)
    region = CurvilinearRegion(
        CurvilinearPolygon(Point{Float64}[(R, 0), (-R, 0)], [t1, t2], [1, 2])
    )
    sq = Polygon([
        Point(1e4, 1e4),
        Point(1e4 + 1, 1e4),
        Point(1e4 + 1, 1e4 + 1),
        Point(1e4, 1e4 + 1)
    ])
    report = Tuple[]
    out = recover_curves(union2d, region, sq; report=report)
    @test count(t -> t[1] == :recovered, report) == 2
    @test count(t -> t[1] == :clipped, report) == 0
    curved = out[findfirst(r -> !isempty(r.exterior.curves), out)]
    @test length(curved.exterior.p) == 2
    @test length(curved.exterior.curves) == 2
    @test length(to_polygons(curved.exterior).p) > 0
    @test isempty(to_polygons(xor2d(region, curved)))
end

@testitem "Curve recovery — BSpline segment (type-agnostic)" setup = [CommonTestSetup] begin
    using DeviceLayout: Point, CurvilinearPolygon, CurvilinearRegion, Paths, Polygon
    using DeviceLayout: recover_curves, union2d
    # A BSpline-bearing region unioned with a disjoint square. The recovery
    # mechanism is curve-type-agnostic: it must recover the BSpline, not just arcs.
    bpts = Point{Float64}[(10, 0), (13, 3), (16, 2), (18, 6)]
    bs = Paths.BSpline(bpts, Point(1.0, 1.0), Point(1.0, 1.0))
    pts = Point{Float64}[(0, 0), bs.p0, bs.p1, (0, 10)]
    region = CurvilinearRegion(CurvilinearPolygon(pts, [bs], [2]))
    sq = Polygon([
        Point(1e4, 1e4),
        Point(1e4 + 1, 1e4),
        Point(1e4 + 1, 1e4 + 1),
        Point(1e4, 1e4 + 1)
    ])
    report = Tuple[]
    out = recover_curves(union2d, region, sq; report=report)
    @test count(t -> t[1] == :recovered, report) == 1
    @test count(t -> t[1] == :clipped, report) == 0
    curved = out[findfirst(r -> !isempty(r.exterior.curves), out)]
    @test length(curved.exterior.curves) == 1
    @test curved.exterior.curves[1] isa Paths.BSpline
    @test isempty(to_polygons(xor2d(region, curved)))
end

@testitem "Curve recovery — clipped curve not spuriously recovered" setup =
    [CommonTestSetup] begin
    using DeviceLayout: Point, CurvilinearPolygon, CurvilinearRegion, Paths, Polygon
    using DeviceLayout: recover_curves, difference2d
    # Safety property: a destroyed arc must NEVER emit a (wrong) curve. Uses the same
    # cut-arc geometry as the "straight edge cuts an arc" case and asserts zero
    # recovery, a :clipped report, and a polyline (zero-curve) exterior.
    t = Paths.Turn(90.0°, 2.0; p0=Point(18.0, 10.0), α0=0.0°)
    region = CurvilinearRegion(
        CurvilinearPolygon(
            Point{Float64}[(10, 10), (18, 10), (20, 12), (20, 20), (10, 20)],
            [t],
            [2]
        )
    )
    cutter = Polygon([
        Point(18.5, 10.5),
        Point(25.0, 10.5),
        Point(25.0, 13.0),
        Point(18.5, 13.0)
    ])
    report = Tuple[]
    out = recover_curves(difference2d, region, cutter; report=report)
    @test count(t -> t[1] == :recovered, report) == 0
    @test any(t -> t[1] == :clipped, report)
    @test all(isempty(r.exterior.curves) for r in out)
end

@testitem "Curve recovery — curve_start_idx sorted invariant" setup = [CommonTestSetup] begin
    using DeviceLayout: Point, CurvilinearPolygon, Paths, to_polygons, Reflection, °
    using DeviceLayout.Curvilinear: _reverse
    # to_polygons walks curves with a running cursor and slices p[i:csi], which requires
    # curve_start_idx ascending. _reverse and reflective transform both flip a curve that
    # wraps to the last vertex into the unsorted order [4, 2], which either throws an
    # AssertionError or silently duplicates vertices (corrupt geometry). The constructor
    # sorts curves and indices jointly so every producer preserves the invariant.

    # Stadium: straight bottom/top, semicircle caps. The left cap (vertex 4 → vertex 1)
    # is the wrap-around curve that triggers the bug under reversal/reflection.
    pts = Point{Float64}[(0, 0), (10, 0), (10, 10), (0, 10)]
    cap_r = Paths.Turn(180.0°, 5.0; p0=Point(10.0, 0.0), α0=0.0°)    # (10,0) → (10,10)
    cap_l = Paths.Turn(180.0°, 5.0; p0=Point(0.0, 10.0), α0=180.0°)  # (0,10) → (0,0)
    cp = CurvilinearPolygon(copy(pts), [cap_r, cap_l], [2, 4])
    n_fwd = length(to_polygons(cp).p)

    # Constructor reorders curves jointly with indices when given unsorted input.
    unsorted = CurvilinearPolygon(copy(pts), [cap_l, cap_r], [4, 2])
    @test issorted(unsorted.curve_start_idx)
    @test unsorted.curves == cp.curves
    @test to_polygons(unsorted).p == to_polygons(cp).p

    # _reverse produces a wrap-around curve (csi would be [4, 2]) — must stay sorted and
    # round-trip without the extra vertices the corrupt path introduced.
    rev = _reverse(cp)
    @test issorted(rev.curve_start_idx)
    @test length(to_polygons(rev).p) == n_fwd

    # Reflective transform uses the same csi-flip logic and had the identical bug.
    refl = DeviceLayout.transform(cp, Reflection(0.0°))
    @test issorted(refl.curve_start_idx)
    @test length(to_polygons(refl).p) == n_fwd

    # A curve starting at index 1 exercises the other boundary of the csi_rev formula.
    cap_b = Paths.Turn(180.0°, 5.0; p0=Point(0.0, 0.0), α0=-90.0°)  # (0,0) → (10,0)
    cp1 = CurvilinearPolygon(copy(pts), [cap_b], [1])
    n1 = length(to_polygons(cp1).p)
    rev1 = _reverse(cp1)
    @test issorted(rev1.curve_start_idx)
    @test length(to_polygons(rev1).p) == n1
end

@testitem "Curve recovery — styled entity expansion (to_curvilinear)" setup =
    [CommonTestSetup] begin
    using DeviceLayout: Rounded, StyleDict, MeshSized, WithDirection
    using DeviceLayout: union2d, union2d_curved, xor2d, to_polygons
    using DeviceLayout.Curvilinear: to_curvilinear, _normalize_curved_clip_arg

    # A plus-shaped ClippedPolygon: two overlapping rectangles unioned. Rounding it produces
    # 12 fillet arcs. Before the to_curvilinear unification, curve recovery reached only
    # `Rounded` on a bare Polygon/Rectangle, so every case below either silently dropped its
    # arcs (fell through to discretization) or threw a MethodError. All must now recover
    # arcs, and the recovered geometry must match the exact curvilinear expansion.
    r = centered(Rectangle(10.0μm, 10.0μm))
    bar = centered(Rectangle(4.0μm, 20.0μm))
    clip = union2d(r, bar)

    # `Rounded` and `StyleDict{Rounded}` on a ClippedPolygon.
    for sty in (Rounded(1μm), StyleDict(Rounded(1μm)))
        out = union2d_curved(sty(clip))
        @test sum(length(reg.exterior.curves) for reg in out) == 12
        # Recovered arcs match the exact curvilinear expansion (not merely a polygon area).
        ref = to_curvilinear(clip, StyleDict(Rounded(1μm)))
        @test isempty(to_polygons(xor2d(out, ref)))
    end

    # Nested no-op styles must not block the inner Rounded. `Rounded(MeshSized(rect))`
    # previously threw MethodError (styled_loop catch-all → contour(::Polygon)); the reverse
    # nesting silently discretized. Both now recover the four corner fillets.
    for ent in (Rounded(1μm)(MeshSized(1μm)(r)), MeshSized(1μm)(Rounded(1μm)(r)))
        out = union2d_curved(ent)
        @test sum(length(reg.exterior.curves) for reg in out) == 4
        @test isempty(to_polygons(xor2d(out, _normalize_curved_clip_arg(Rounded(1μm)(r)))))
    end

    # WithDirection is also a no-op for geometry: it passes through to the inner Rounded.
    out = union2d_curved(WithDirection(45°)(Rounded(1μm)(r)))
    @test sum(length(reg.exterior.curves) for reg in out) == 4
    @test isempty(to_polygons(xor2d(out, _normalize_curved_clip_arg(Rounded(1μm)(r)))))

    # Geometry-transparent styles on a Path node (e.g. meshsized_entity on a path element)
    # previously fell to the generic to_polygons fallback and silently discretized the arcs.
    pa = Path()
    turn!(pa, 90°, 50μm, Paths.Trace(5μm))
    for node in (MeshSized(1μm)(pa[1]), WithDirection(45°)(pa[1]))
        node_out = union2d_curved(node)
        @test length(node_out) == 1
        @test length(node_out[1].exterior.curves) == 2
        @test isempty(to_polygons(xor2d(node_out, pathtopolys(pa))))
    end
    # A zero-length continuous-style node under a style wrapper expands to nothing,
    # matching the bare-node behavior in _normalize_curved_clip_arg.
    pa0 = Path()
    straight!(pa0, 0μm, Paths.Trace(5μm))
    @test isempty(_normalize_curved_clip_arg(MeshSized(1μm)(pa0[1])))
end

@testitem "Curve recovery — warn once on silent curve loss" setup = [CommonTestSetup] begin
    using DeviceLayout: Ellipse, Rectangle, union2d_curved, MeshSized
    using DeviceLayout.Curvilinear: _curve_loss_warned
    # An Ellipse carries curves but has no curve-recovery method: it is discretized with
    # no provenance, so the loss must be warned (once per entity type, not per entity).
    empty!(_curve_loss_warned)
    ell = Ellipse(Point(0.0μm, 0.0μm), (10.0μm, 5.0μm), 0.0°)
    @test_logs (:warn, r"no curve-recovery method") min_level = Logging.Warn union2d_curved([
        ell,
        centered(Rectangle(4μm, 4μm))
    ])
    # Second Ellipse: already warned, and the entity still discretizes and clips normally.
    out = @test_logs min_level = Logging.Warn union2d_curved(ell)
    @test length(out) == 1
    @test isempty(out[1].exterior.curves)

    # The styled path also warns when the innermost entity carries curves and the style
    # expansion falls back to plain polygons (no to_curvilinear method for the pair).
    empty!(_curve_loss_warned)
    @test_logs (:warn, r"no curve-recovery method") min_level = Logging.Warn union2d_curved(
        MeshSized(1μm)(ell)
    )

    # StyleDict doesn't warn for curve loss
    empty!(_curve_loss_warned)
    @test_logs min_level = Logging.Warn union2d_curved(
        StyleDict(Rounded(1μm))(union2d(ell))
    )
    @test Curvilinear._carries_curves(StyleDict(Rounded(1μm))(union2d(ell)))
    @test !Curvilinear._carries_curves(StyleDict(DeviceLayout.Plain())(union2d(ell)))

    # Curve-free inputs discretize losslessly: never warn.
    empty!(_curve_loss_warned)
    @test_logs min_level = Logging.Warn union2d_curved(centered(Rectangle(4μm, 4μm)))
    @test_logs min_level = Logging.Warn union2d_curved(
        MeshSized(1μm)(centered(Rectangle(4μm, 4μm)))
    )
    @test isempty(_curve_loss_warned)
end

@testitem "Curve recovery — Circle four-arc representation (#251)" setup = [CommonTestSetup] begin
    using DeviceLayout: union2d_curved, difference2d_curved, union2d, xor2d
    using DeviceLayout: Rounded, MeshSized
    using DeviceLayout.Curvilinear:
        CurvilinearPolygon, to_curvilinear, _normalize_curved_clip_arg, _curve_loss_warned

    c = Circle(Point(1.0μm, 2.0μm), 3.0μm)

    # Exact four-arc form: quarter turns meeting at the axis-aligned extreme points.
    cp = CurvilinearPolygon(c)
    @test cp.curve_start_idx == [1, 2, 3, 4]
    @test all(t -> t isa Paths.Turn && t.α == 90.0° && t.r == 3.0μm, cp.curves)
    # Every discretized point lies on the circle to within the default 1 nm tolerance.
    @test all(points(to_polygons(cp))) do pt
        return abs(norm(pt - Point(1.0μm, 2.0μm)) - 3.0μm) < 2nm
    end
    # Unitless coordinates work too.
    @test length(CurvilinearPolygon(Circle(1.0)).curves) == 4

    # Self-union recovers all four arcs exactly, with no curve-loss warning (a Circle has
    # a curve-recovery method; its Ellipse equivalent warns and discretizes).
    empty!(_curve_loss_warned)
    report = []
    out = @test_logs min_level = Logging.Warn union2d_curved([c]; report)
    @test length(out) == 1
    @test length(out[1].exterior.curves) == 4
    @test all(r -> r[1] == :recovered, report)
    @test isempty(to_polygons(xor2d(out, cp)))

    # A clip cutting through two arcs: the untouched arcs recover, the cut ones fall
    # back to polylines and are reported :clipped.
    knife = Rectangle(Point(2.0μm, -2.0μm), Point(5.0μm, 6.0μm))
    report = []
    cut = difference2d_curved(c, knife; report)
    @test length(cut) == 1
    @test length(cut[1].exterior.curves) == 2
    @test count(r -> r[1] == :recovered, report) == 2
    @test count(r -> r[1] == :clipped, report) == 2
    @test isempty(to_polygons(xor2d(cut, difference2d(cp, knife))))

    # Geometry-transparent and no-op styles preserve the arcs: MeshSized passes through,
    # and Rounded is a no-op on a circle (no straight-straight or line-arc corners).
    empty!(_curve_loss_warned)
    for ent in (MeshSized(1μm)(c), Rounded(1μm)(c))
        styled_out = @test_logs min_level = Logging.Warn union2d_curved(ent)
        @test length(styled_out[1].exterior.curves) == 4
        @test isempty(to_polygons(xor2d(styled_out, cp)))
    end
end
