# Schematic with chain of spacers rotated at 45 degrees
g = SchematicGraph("test")
lastnode = add_node!(g, Spacer{Float64}(p1=Point(10.0, 10.0)))
for i = 1:100
    global lastnode
    lastnode = fuse!(
        g,
        lastnode => :p1_east,
        Spacer{Float64}(p1=Point(10.0, 10.0)) => :p0_southwest
    )
end

SUITE["schematic"] = BenchmarkGroup()
SUITE["schematic"]["plan"] = @benchmarkable plan($g; log_dir=nothing)
