SUITE["bounds"] = BenchmarkGroup()
SUITE["flatten"] = BenchmarkGroup()

rng = seed!(default_rng(), 111)
# Generate rectangles from random points
num_rects = 1_000
p1s = reinterpret(Point{Int}, rand(Int, 2, num_rects))
p2s = reinterpret(Point{Int}, rand(Int, 2, num_rects))
random_rectangles = [Rectangle(p1, p2) for (p1, p2) in zip(p1s, p2s)]
# Circles around points
random_circles = [circle_polygon(1.0, 10°) for p1 in p1s]

# Cell with same circle coordinate system referenced many times at top level
c_shallow = Cell{Float64}("shallow")
c_circ = Cell{Float64}("circle")
render!(c_circ, circle_polygon(10.0, 10°))
rots = rand(num_rects) * 2π
for (p1, rot) in zip(p1s, rots)
    addref!(c_shallow, c_circ, p1, rot=rot)
end

# Cell with reference to a circle coordinate systems holding a reference to another
# and so on to `num_rects` depth
c_nested = Cell{Float64}("nested")
rots = rand(num_rects) * 2π
nextcell = c_nested
for (p1, rot) in zip(p1s, rots)
    global nextcell
    c = Cell{Float64}(uniquename("nested"))
    addref!(nextcell, c, p1, rot=rot)
    nextcell = c
    render!(nextcell, circle_polygon(10.0, 10°))
end

# Array reference with around 1000 circles
c_arrayed = Cell{Float64}("arrayed")
addarr!(
    c_arrayed,
    c_circ,
    numrows=31,
    numcols=31,
    deltarow=Point(0.0, 10.0),
    deltacol=Point(10.0, 0.0)
)

SUITE["bounds"]["random_rectangles"] = @benchmarkable bounds($random_rectangles)
SUITE["bounds"]["random_circles"] = @benchmarkable bounds($random_circles)
SUITE["bounds"]["shallow_references"] = @benchmarkable bounds($c_shallow)
SUITE["bounds"]["nested_references"] = @benchmarkable bounds($c_nested)

SUITE["flatten"]["shallow_references"] = @benchmarkable flatten($c_shallow)
SUITE["flatten"]["nested_references"] = @benchmarkable flatten($c_nested)
SUITE["flatten"]["array_reference"] = @benchmarkable flatten($c_arrayed)
