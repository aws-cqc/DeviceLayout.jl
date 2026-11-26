# Autofill around paths, first with coarse grid, then with fine grid
function coarse_and_fine_autofill()
    cs = CoordinateSystem("autofill_bench", nm)
    pa = Path(nm)
    pa.metadata = SemanticMeta(:metal_negative)
    bspline!(pa, [Point(1000μm, 1000μm)], 90°, Paths.SimpleCPW(10μm, 6μm))
    meander!(pa, 6000μm, 500μm, 200μm, -180°)
    bspline!(pa, [Point(4000μm, 0μm)], 0°)
    # Place two copies of paths, one rotated
    addref!(cs, pa)
    addref!(cs, pa, Point(-500μm, 0μm), rot=90°)

    # Autofill grids
    coarse_grid_x = (-3000:250:5000)μm
    coarse_grid_y = (-1000:250:5000)μm
    fine_grid_x = (-3000:25:5000)μm
    fine_grid_y = (-1000:25:5000)μm

    # Coordinate systems holding "dummy" geometry (the thing filling space)
    coarse_dummy = CoordinateSystem("coarse", nm)
    place!(coarse_dummy, centered(Rounded(Rectangle(100μm, 100μm), 50μm)), :metal_negative)
    fine_dummy = CoordinateSystem("fine", nm)
    place!(fine_dummy, centered(Rounded(Rectangle(10μm, 10μm), 5μm)), :metal_negative)

    # Autofill
    autofill!(cs, coarse_dummy, coarse_grid_x, coarse_grid_y, make_halo(150μm))
    autofill!(cs, fine_dummy, fine_grid_x, fine_grid_y, make_halo(50μm))
    return
end

SUITE["autofill"] = BenchmarkGroup()
SUITE["autofill"]["coarse_and_fine"] = @benchmarkable coarse_and_fine_autofill()

# gridpoints_in_polygon microbenchmarks at varying grid densities
using DeviceLayout.Polygons: difference2d

# Polygon with a cutout (exercises both horizontal edge and winding number paths)
const _gip_r1 = Rectangle(200μm, 200μm)
const _gip_r2 = Rectangle(100μm, 100μm) + Point(50μm, 50μm)
const _gip_poly = [difference2d(_gip_r1, _gip_r2)]

const _gip_grids = [
    (
        "33x25",
        collect(range(-10μm, 210μm, length=33)),
        collect(range(-10μm, 210μm, length=25))
    ),
    (
        "321x241",
        collect(range(-10μm, 210μm, length=321)),
        collect(range(-10μm, 210μm, length=241))
    ),
    (
        "3201x2401",
        collect(range(-10μm, 210μm, length=3201)),
        collect(range(-10μm, 210μm, length=2401))
    )
]

SUITE["autofill"]["gridpoints_in_polygon"] = BenchmarkGroup()
for (label, gx, gy) in _gip_grids
    SUITE["autofill"]["gridpoints_in_polygon"][label] =
        @benchmarkable gridpoints_in_polygon($_gip_poly, $gx, $gy)
end

# Many short edges, most crossing no grid row, as in a ground-plane exclusion
const _gip_many_edges = vec([
    Polygon([Point(x + 3μm * cospi(2k / 100), y + 3μm * sinpi(2k / 100)) for k = 0:99])
    for x = (10μm):(20μm):(630μm), y = (10μm):(20μm):(630μm)
])
const _gip_many_grid = collect(range(0μm, 640μm, length=139))
SUITE["autofill"]["gridpoints_in_polygon"]["100k_edges_139x139"] =
    @benchmarkable gridpoints_in_polygon($_gip_many_edges, $_gip_many_grid, $_gip_many_grid)
