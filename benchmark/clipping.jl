SUITE["clipping"] = BenchmarkGroup()
SUITE["clipping"]["difference2d"] = BenchmarkGroup()

# Differences using various pregenerated square arrays
for name in [
    :difference2d_100_square,
    :difference2d_961_square,
    :difference2d_3600_square,
    :difference2d_10000_square,
    :difference2d_19881_square
]
    @eval str = string($(QuoteNode(name)))
    @eval $name = load(joinpath(dirname(@__FILE__), "data", str * ".gds"))["main"]
    @eval b = elements($name)
    @eval c = element_metadata($name)
    @eval a = splice!(b, findall(m -> m == GDSMeta(0, 0), c))

    names = split(str, "_")
    n1 = names[1]
    n2 = join(names[2:end], "_")
    SUITE["clipping"][n1][n2] = @benchmarkable difference2d($(a), $(b))
end

difference2d_8000_skew =
    load(joinpath(dirname(@__FILE__), "data", "difference2d_8000_skew.gds"))["main"]
b = elements(difference2d_8000_skew)
c = element_metadata(difference2d_8000_skew)
a = splice!(b, findall(m -> m == GDSMeta(0, 0), c))

SUITE["clipping"]["difference2d"]["8000_skew"] = @benchmarkable difference2d($(a), $(b))

# Offset a hexagon then take the difference across some overlapping copies
function offset_difference()
    c = Cell{Float64}("test")
    poly = circle_polygon(1.5, 60°)
    render!(c, poly)
    ref = aref(c, Point(-3.0, 5.0), nc=4, deltacol=Point(2.0, 0.0))
    els = [poly; elements(flatten(ref))]
    off = offset(els, 0.2)
    boo = difference2d(off, els)
    return render!(c, boo, GDSMeta(1)) # Render to force interiorcuts
end

SUITE["clipping"]["difference2d_offset"] = @benchmarkable offset_difference()
