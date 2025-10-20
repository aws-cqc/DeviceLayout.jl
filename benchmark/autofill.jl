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

SUITE["autofill"] = @benchmarkable coarse_and_fine_autofill()
