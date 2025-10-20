# Crossing vertical and horizontal paths
paths_vert = [Path(i * 0.1mm, (-1)^(i + 1) * (1mm), α0=(-1)^i * π / 2) for i = -5:5]
paths_horiz = [Path((-1)^(i) * (1mm), i * 0.1mm, α0=(-1)^i * π / 2 + π / 2) for i = -5:5]

sty = Paths.SimpleCPW(10μm, 6μm)
straight!.(paths_vert, 2mm, Ref(sty))
straight!.(paths_horiz, 2mm, Ref(sty))
all_paths = vcat(paths_vert, paths_horiz)

SUITE["intersection"] = BenchmarkGroup()
SUITE["intersection"]["straight_lines"] =
    @benchmarkable Intersect.prepared_intersections($all_paths)
