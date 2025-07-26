using DeviceLayout, .SchematicDrivenLayout, .PreferredUnits
using FileIO

g = SchematicGraph("test")

cs = CoordinateSystem("basic")
place!(cs, centered(Rectangle(0.100mm, 0.100mm)), :obstacle)
hooks = (;
    port1=PointHook(0.05mm, -0.0mm, 180°),
    port2=PointHook(-0.05mm, 0.0mm, 0°),
    north=PointHook(0mm, 0.5mm, -90°),
    south=PointHook(0mm, -0.5mm, 90°),
    west=PointHook(-0.5mm, 0mm, 0°),
    east=PointHook(0.5mm, 0mm, 180°)
)
comp = BasicComponent(cs, hooks)
n1 = add_node!(g, comp)
n2 = fuse!(g, n1 => :north, comp => :south)
n3 = fuse!(g, n1 => :south, comp => :north)
n4 = fuse!(g, n1 => :east, comp => :west)
n5 = fuse!(g, n1 => :west, comp => :east)

rule = Paths.AStarRouting(
    Paths.StraightAnd90(min_bend_radius=50μm),
    centered(Rectangle(5e6nm, 5e6nm)),
    0.25mm,
    make_halo(0.05mm)
)
route!(g, rule, n5 => :port2, n1 => :port1, Paths.CPW(10μm, 6μm), SemanticMeta(:route))
route!(g, rule, n1 => :port2, n3 => :port2, Paths.CPW(10μm, 6μm), SemanticMeta(:route))
route!(g, rule, n5 => :port1, n4 => :port2, Paths.CPW(10μm, 6μm), SemanticMeta(:route))
route!(g, rule, n2 => :port1, n4 => :port1, Paths.CPW(10μm, 6μm), SemanticMeta(:route))
route!(g, rule, n3 => :port1, n2 => :port2, Paths.CPW(10μm, 6μm), SemanticMeta(:route))

@time sch = plan(g; log_dir=nothing, strict=:no)

c = Cell("test")
render!(c, sch.coordinate_system; map_meta=_ -> GDSMeta())
save("test.gds", flatten(c; name="flatten"))
