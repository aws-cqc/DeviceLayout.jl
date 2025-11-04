SUITE["polygons"] = BenchmarkGroup()
SUITE["polygons"]["circles"] = BenchmarkGroup()
SUITE["polygons"]["rectangles"] = BenchmarkGroup()

# Render and optionally export n rectangles
function rectangles(n; output_dir=nothing)
    c = Cell{Float64}("rectangles")
    for i = 1:n
        render!(c, Rectangle(Point(i, 0.0), Point(i + 1, 1.0)))
    end
    return !isnothing(output_dir) && save(joinpath(output_dir, "$(n)_rectangles.gds"), c)
end

# As above but with units
function rectangles_units(n, unit; output_dir=nothing)
    um = uconvert(unit, DeviceLayout.onemicron(1unit))
    c = Cell{typeof(1.0nm)}("rectangles") # coordinatetype(c) may or may not be same as unit
    for i = 1:n
        render!(c, Rectangle(Point(i * um, 0 * um), Point((i + 1) * um, 1 * um)))
    end
    return !isnothing(output_dir) &&
           save(joinpath(output_dir, "$(n)_rectangles_units.gds"), c)
end

# Render circles using `circle_polygon` to calculate polygon points directly
# (use ~maximum number of points for single GDSII polygon -- other extreme from rectangles)
function circles_direct(n; output_dir=nothing)
    c = Cell{Float64}("circles")
    for i = 1:n
        render!(c, Point(i, 0.0) + circle_polygon(1, 2π / 8000))
    end
    return !isnothing(output_dir) && save(joinpath(output_dir, "$(n)_circles.gds"), c)
end

# As above but with units
function circles_direct_units(n, unit; output_dir=nothing)
    um = uconvert(unit, DeviceLayout.onemicron(1unit))
    c = Cell{typeof(1.0nm)}("circles") # coordinatetype(c) may or may not be same as unit
    for i = 1:n
        render!(c, Point(i * um, 0.0 * um) + circle_polygon(1 * um, 2π / 8000))
    end
    return !isnothing(output_dir) && save(joinpath(output_dir, "$(n)_circles_units.gds"), c)
end

# Render circles using `Circle` entity and `Δθ` keyword option for discretization
function circles_entity_delta(n; output_dir=nothing)
    c = Cell{Float64}("circles")
    for i = 1:n
        render!(c, Circle(Point(i, 0.0), 1.0), Δθ=2π / 8000)
    end
    return !isnothing(output_dir) && save(joinpath(output_dir, "$(n)_circles_delta.gds"), c)
end

# As above but using `atol` for discretization with the same number of points
function circles_entity_atol(n; output_dir=nothing)
    c = Cell{Float64}("circles")
    for i = 1:n
        render!(c, Circle(Point(i, 0.0), 1.0), atol=7.714e-8) # 7999 points
    end
    return !isnothing(output_dir) && save(joinpath(output_dir, "$(n)_circles_atol.gds"), c)
end

dir = mktempdir()
SUITE["polygons"]["rectangles"]["render"] = @benchmarkable rectangles(10_000)
SUITE["polygons"]["rectangles"]["render_gds"] =
    @benchmarkable rectangles(10_000, output_dir=($dir))
SUITE["polygons"]["rectangles"]["render_units"] =
    @benchmarkable rectangles_units(10_000, $nm)
SUITE["polygons"]["rectangles"]["render_units_gds"] =
    @benchmarkable rectangles_units(10_000, $nm, output_dir=($dir))
SUITE["polygons"]["rectangles"]["render_convertunits"] =
    @benchmarkable rectangles_units(10_000, $μm)
SUITE["polygons"]["circles"]["direct"] = @benchmarkable circles_direct(1_000)
SUITE["polygons"]["circles"]["direct_gds"] =
    @benchmarkable circles_direct(1_000, output_dir=($dir))
SUITE["polygons"]["circles"]["direct_units"] =
    @benchmarkable circles_direct_units(1_000, $nm)
SUITE["polygons"]["circles"]["direct_units_gds"] =
    @benchmarkable circles_direct_units(1_000, $nm, output_dir=($dir))
SUITE["polygons"]["circles"]["entity_delta"] = @benchmarkable circles_entity_delta(1_000)
SUITE["polygons"]["circles"]["entity_atol"] = @benchmarkable circles_entity_atol(1_000)
