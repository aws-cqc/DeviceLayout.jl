"""
Channel autorouter examples demonstrating various routing scenarios.

Each `example_*` function returns `(cell::Cell, router::ChannelRouter)`.
`run_all_examples()` runs all examples and optionally saves GDS/PNG output.
"""
module ChannelAutorouter

using DeviceLayout, .PreferredUnits, .SchematicDrivenLayout
using FileIO

import .Paths:
    ChannelRouter, RouteChannel, AutoChannelRouting, autoroute!, visualize_router_state

# ── Helpers ──────────────────────────────────────────────────────────────────

"""
Horizontal channel at height `y`, from `x0` to `x1`.
"""
function hchannel(x0, x1, y; width=2.0)
    pa = Path(Float64(x0), Float64(y))
    straight!(pa, Float64(x1 - x0), Paths.Trace(Float64(width)))
    return pa
end

"""
Vertical channel at `x`, from `y0` to `y1`.
"""
function vchannel(x, y0, y1; width=2.0)
    pa = Path(Float64(x), Float64(y0), α0=90°)
    straight!(pa, Float64(y1 - y0), Paths.Trace(Float64(width)))
    return pa
end

"""
Diagonal channel from `(x0,y0)` at angle `α` for length `len`.
"""
function dchannel(x0, y0, α, len; width=2.0)
    pa = Path(Float64(x0), Float64(y0), α0=α)
    straight!(pa, Float64(len), Paths.Trace(Float64(width)))
    return pa
end

"""
B-spline channel from `(x0,y0)` to `(x1, y1)` at angle `α` at endpoints.
"""
function bchannel(x0, y0, α, x1, y1; width=2.0)
    pa = Path(Float64(x0), Float64(y0), α0=α)
    bspline!(
        pa,
        [Point(x1, y1)],
        α,
        Paths.Trace(Float64(width)),
        auto_speed=true,
        auto_curvature=true,
        endpoints_speed=1,
        endpoints_curvature=0
    )
    return pa
end

# Pin convenience: PointHook with in_direction pointing INWARD (away from routing)
# Left pin (route goes right):   lpin(x, y) → in_direction = 180°
# Right pin (route goes left):   rpin(x, y) → in_direction = 0°
# Bottom pin (route goes up):    bpin(x, y) → in_direction = 270°
# Top pin (route goes down):     tpin(x, y) → in_direction = 90°
lpin(x, y) = PointHook(Point(Float64(x), Float64(y)), 180°)
rpin(x, y) = PointHook(Point(Float64(x), Float64(y)), 0°)
bpin(x, y) = PointHook(Point(Float64(x), Float64(y)), 270°)
tpin(x, y) = PointHook(Point(Float64(x), Float64(y)), 90°)

const R = Paths.StraightAnd90(0.1)
const WW = 0.05
const MARGIN = 0.1
# Autoroute can produce epsilon overlap between end of one segment and start of another
# Filter prepared_intersections to only inter-path crossings (different path indices)
function inter_path_intersections(paths)
    return filter(Intersect.prepared_intersections(paths)) do ixn
        ixn[1][1] != ixn[2][1]
    end
end

# ── Example 1: Simple ────────────────────────────────────────────────────────
# 1 horizontal channel, 2 pins, 1 net.
# Pins offset vertically so their rays cross the channel perpendicularly.
#
#    p1 (below)    p2 (above)
#       ↑            ↓
#  ═══════════════════════  h1 (y=0)

function example_simple()
    channels = [hchannel(0, 10, 0)]
    hooks = [
        bpin(2, -0.5),   # pin 1: below channel, ray goes up
        tpin(8, 0.5)    # pin 2: above channel, ray goes down
    ]
    nets = [(1, 2)]

    ar = ChannelRouter(nets, hooks, RouteChannel.(channels))
    autoroute!(ar, R, MARGIN)
    c = visualize_router_state(ar; wire_width=WW)

    @assert length(ar.net_wires) == 1
    @assert length(ar.net_wires[1]) > 0 "Net should be routed"
    @assert length(ar.channel_tracks[1]) == 1 "Should use exactly 1 track"
    return c, ar
end

# ── Example 2: Parallel ──────────────────────────────────────────────────────
# H/V grid, 3 nets routed left→right at matching heights. No crossings.
#
#  p1 → ║══════════════║ ← p4    h_bot (y=0)
#       ║              ║
#  p2 → ║══════════════║ ← p5    h_mid (y=4)
#       ║              ║
#  p3 → ║══════════════║ ← p6    h_top (y=8)
#     v_left         v_right

function example_parallel()
    channels = [
        vchannel(0, -1, 9),      # v_left
        vchannel(10, -1, 9),     # v_right
        hchannel(-1, 11, 0),     # h_bot
        hchannel(-1, 11, 4),     # h_mid
        hchannel(-1, 11, 8)     # h_top
    ]
    hooks = [
        lpin(-0.5, 0),   # p1: left, at h_bot level
        lpin(-0.5, 4),   # p2: left, at h_mid level
        lpin(-0.5, 8),   # p3: left, at h_top level
        rpin(10.5, 0),   # p4: right, at h_bot level
        rpin(10.5, 4),   # p5: right, at h_mid level
        rpin(10.5, 8)   # p6: right, at h_top level
    ]
    nets = [(1, 4), (2, 5), (3, 6)]

    ar = ChannelRouter(nets, hooks, RouteChannel.(channels))
    routes = autoroute!(ar, R, MARGIN)
    paths = Path.(routes, Ref(Paths.Trace(WW)))
    c = visualize_router_state(ar; wire_width=WW)
    @assert isempty(inter_path_intersections(paths)) "No crossings"
    @assert all(length.(ar.net_wires) .> 0) "All nets should be routed"
    return c, ar
end

# ── Example 3: Crossing ──────────────────────────────────────────────────────
# 2 horizontal channels + 1 vertical channel. 2 nets cross in the shared
# vertical channel, forcing multiple tracks.
#
#  p3 ←  ═══════╪═══  → p4    h_top (y=6)
#               ║
#  p1 ←  ═══════╪═══  → p2    h_bot (y=0)
#             v_mid (x=5)

function example_crossing()
    channels = [
        vchannel(5, -1, 7),     # v_mid
        hchannel(-1, 9, 0),     # h_bot
        hchannel(-1, 9, 6)     # h_top
    ]
    hooks = [
        bpin(2, -0.5),   # p1: below h_bot, left side
        bpin(8, -0.5),   # p2: below h_bot, right side
        tpin(2, 6.5),    # p3: above h_top, left side
        tpin(8, 6.5)    # p4: above h_top, right side
    ]
    # Crossed: bottom-left↔top-right, bottom-right↔top-left
    nets = [(1, 4), (2, 3)]

    ar = ChannelRouter(nets, hooks, RouteChannel.(channels))
    routes = autoroute!(ar, R, MARGIN)
    paths = Path.(routes, Ref(Paths.Trace(WW)))
    c = visualize_router_state(ar; wire_width=WW)

    @assert all(length.(ar.net_wires) .> 0) "All nets should be routed"
    # Both nets traverse v_mid, so it needs ≥2 tracks
    @assert length(ar.channel_tracks[1]) >= 2 "Crossing nets need multiple tracks in shared channel"
    # Due to assignment order, only one horizontal channel has two tracks
    @assert length(ar.channel_tracks[2]) + length(ar.channel_tracks[3]) == 3 "Crossing nets need multiple horizontal tracks only when they overlap due to vertical assignment"
    @assert length(inter_path_intersections(paths)) == 1 "Exactly one crossing"
    return c, ar
end

# ── Example 4: Fan-in/fan-out ─────────────────────────────────────────────────
# Left and right pins spread out, must fan in/out asymmetrically to horizontal channel
# 2 vertical + 1 horizontal channels.
#
#            v_left                    v_right
#  p4 → (-0.5, 6)  ║                    ║  (10.5, 9) ← p8
#  p3 → (-0.5, 5)  ║════════════════════║  (10.5, 6) ← p7   h_mid (y=7)
#  p2 → (-0.5, 4)  ║                    ║  (10.5, 3) ← p6
#  p1 → (-0.5, 3)  ║                    ║  (10.5, 0) ← p5
function example_fanin_fanout()
    channels = [
        vchannel(0, -2, 11),     # v_left
        hchannel(-2, 12, 7),     # h_mid
        vchannel(10, -2, 11)    # v_right
    ]
    # Left pins clustered at y=3,4,5,6 — all cross v_left
    # Right pins spread at y=0,3,6,9 — all cross v_right
    hooks = [
        lpin(-1, 3),   # p1
        lpin(-1, 4),   # p2
        lpin(-1, 5),   # p3
        lpin(-1, 6),   # p4
        rpin(11, 0),   # p5
        rpin(11, 3),   # p6
        rpin(11, 6),   # p7
        rpin(11, 9)   # p8
    ]
    nets = [(1, 5), (2, 6), (3, 7), (4, 8)]

    ar = ChannelRouter(nets, hooks, RouteChannel.(channels))
    routes = autoroute!(ar, R, MARGIN)
    c = visualize_router_state(ar; wire_width=WW)

    @assert all(length.(ar.net_wires) .> 0) "All nets should be routed"
    paths = Path.(routes, Ref(Paths.Trace(WW)))
    @assert isempty(inter_path_intersections(paths)) "No crossings"
    @assert length(ar.channel_tracks[3]) == 3 "Last vertical channel only needs 3 tracks"
    return c, ar
end

# ── Example 5: Multichannel fan-out ──────────────────────────────────────────
# Left pins clustered (simulating component outputs), right pins spread out.
# 2 vertical + 4 horizontal channels.
#
#            v_left                    v_right
#  p4 → (-0.5, 6)  ║════════════════════║  (10.5, 9) ← p8   h4 (y=9)
#  p3 → (-0.5, 5)  ║════════════════════║  (10.5, 6) ← p7   h3 (y=6)
#  p2 → (-0.5, 4)  ║════════════════════║  (10.5, 3) ← p6   h2 (y=3)
#  p1 → (-0.5, 3)  ║════════════════════║  (10.5, 0) ← p5   h1 (y=0)
function example_multichannel_fanout()
    channels = [
        vchannel(0, -2, 11),     # v_left
        hchannel(-2, 12, 1.5),     # h_1
        hchannel(-2, 12, 3.5),     # h_2
        hchannel(-2, 12, 5.5),     # h_3
        hchannel(-2, 12, 7.5),     # h_4
        vchannel(10, -2, 11)    # v_right
    ]
    # Left pins clustered at y=3,4,5,6 — all cross v_left
    # Right pins spread at y=0,3,6,9 — all cross v_right
    hooks = [
        lpin(-1, 3),   # p1
        lpin(-1, 4),   # p2
        lpin(-1, 5),   # p3
        lpin(-1, 6),   # p4
        rpin(11, 0),   # p5
        rpin(11, 3),   # p6
        rpin(11, 6),   # p7
        rpin(11, 9)   # p8
    ]
    nets = [(1, 5), (2, 6), (3, 7), (4, 8)]

    ar = ChannelRouter(nets, hooks, RouteChannel.(channels))
    routes = autoroute!(ar, R, MARGIN)
    paths = Path.(routes, Ref(Paths.Trace(WW)))
    c = visualize_router_state(ar; wire_width=WW)

    @assert all(length.(ar.net_wires) .> 0) "All nets should be routed"
    @assert all(length.(ar.channel_tracks[2:5]) .== 1) "Each net should use its nearest horizontal channel"
    @assert isempty(inter_path_intersections(paths)) "No crossings"
    return c, ar
end

# ── Example 6: Grid ──────────────────────────────────────────────────────────
# 4×4 H/V grid. 3 nets connecting pins on different edges, requiring
# multi-channel paths through the grid.
#
#            v1   v2   v3   v4
#             |    |    |    |
#   p5 →  ════╪════╪════╪════╪════  ← p6    h4 (y=9)
#             |    |    |    |
#         ════╪════╪════╪════╪════          h3 (y=6)
#             |    |    |    |
#   p1 →  ════╪════╪════╪════╪════          h2 (y=3)
#             |    |    |    |
#         ════╪════╪════╪════╪════          h1 (y=0)
#             |    |    |    |
#            p3                p4
#           (bottom)        (bottom)

function example_grid()
    channels = [
        # Vertical channels (indices 1-4)
        vchannel(0, -2, 11),
        vchannel(3, -2, 11),
        vchannel(6, -2, 11),
        vchannel(9, -2, 11),
        # Horizontal channels (indices 5-8)
        hchannel(-2, 11, 0),
        hchannel(-2, 11, 3),
        hchannel(-2, 11, 6),
        hchannel(-2, 11, 9)
    ]
    hooks = [
        lpin(-0.5, 3),    # p1: left edge, at h2 level → adj to v1
        rpin(9.5, 6),     # p2: right edge, at h3 level → adj to v4
        bpin(1.5, -0.5),  # p3: bottom edge → adj to h1
        bpin(7.5, -0.5),  # p4: bottom edge → adj to h1
        lpin(-0.5, 9),    # p5: left edge, at h4 level → adj to v1
        rpin(9.5, 0)     # p6: right edge, at h1 level → adj to v4
    ]
    nets = [
        (1, 2),  # left(y=3) → right(y=6): diagonal traverse
        (3, 5),  # bottom(x=1.5) → left(y=9): corner path
        (4, 6)  # bottom(x=7.5) → right(y=0): short path
    ]

    ar = ChannelRouter(nets, hooks, RouteChannel.(channels))
    autoroute!(ar, R, MARGIN)
    c = visualize_router_state(ar; wire_width=WW)

    @assert all(length.(ar.net_wires) .> 0) "All nets should be routed"
    # At least one net should traverse 3+ wire segments (multi-hop path)
    max_segs = maximum(length.(ar.net_wires))
    @assert max_segs >= 2 "Grid routing should produce multi-segment paths"
    return c, ar
end

# ── Example 7: Angled ────────────────────────────────────────────────────────
# Non-Manhattan channels: two 45° diagonals crossing a horizontal channel.
# Demonstrates that the router handles arbitrary path geometry.
#
#           ╲     ╱
#            ╲   ╱
#             ╲ ╱
#              ╳
#  ═══════════╱═╲═══════════  h1 (y=3)
#            ╱   ╲
#           d1    d2

function example_angled()
    channels = [
        dchannel(-1, 0, 45°, 10 * sqrt(2); width=2.0),   # d1: NE from (-1,0)
        hchannel(-2, 12, 3; width=2.0),                # h1 (y=3)
        dchannel(-1, 10, -45°, 10 * sqrt(2); width=2.0) # d2: SE from (-1,10)
    ]
    # Pins offset so rays cross diagonal
    hooks = [
        bpin(0, -2),     # p1: below d1, left side
        bpin(8, -2),     # p2: below d2, right side
        rpin(12, 1),     # p4: above d2, right side
        lpin(-2, 1)     # p3: below d1, left side
    ]
    # Net 1 goes left→right via h1 and diagonals
    # Net 2 goes right→left via h1 and diagonals
    nets = [(1, 2), (3, 4)]

    ar = ChannelRouter(nets, hooks, RouteChannel.(channels))
    routes = autoroute!(ar, Paths.StraightAnd45(0.1), MARGIN)
    c = visualize_router_state(ar; wire_width=WW)

    @assert all(length.(ar.net_wires) .> 0) "All nets should be routed"
    @assert all(length.(ar.channel_tracks) .== 2) "Each channel needs two tracks"
    paths = Path.(routes, Ref(Paths.Trace(WW)))
    @assert isempty(inter_path_intersections(paths)) "No crossings"
    return c, ar
end

# ── Example 8: Dense ─────────────────────────────────────────────────────────
# 6 nets sharing just 2 horizontal + 2 vertical channels.
# Forces multiple tracks per channel.
#
#  p1-p6 on left    p7-p12 on right
#    →  ║════════════════║  ←
#       ║    h1 (y=0)    ║
#       ║════════════════║
#       ║    h2 (y=5)    ║
#    →  ║════════════════║  ←
#     v_left           v_right

function example_dense()
    channels = [
        vchannel(0, -2, 7),      # v_left  (idx 1)
        hchannel(-2, 10, -1),     # h1      (idx 3)
        hchannel(-2, 10, 6),     # h2      (idx 4)
        vchannel(8, -2, 7)      # v_right (idx 2)
    ]
    # 6 left pins, tightly spaced, all crossing v_left
    # 6 right pins, same y-positions, all crossing v_right
    ys = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0]
    hooks = [
        [lpin(-1, y) for y in ys]...,   # p1-p6
        [rpin(9, y) for y in ys]...    # p7-p12
    ]
    nets = [(i, i + 6) for i = 1:6]

    ar = ChannelRouter(nets, hooks, RouteChannel.(channels))
    routes = autoroute!(ar, R, MARGIN)
    paths = Path.(routes, Ref(Paths.Trace(WW)))
    c = visualize_router_state(ar; wire_width=WW)

    @assert all(length.(ar.net_wires) .> 0) "All nets should be routed"
    @assert all(length.(ar.channel_tracks) .== 3) "Requires 3 tracks on each channel"
    @assert isempty(inter_path_intersections(paths)) "No crossings"
    return c, ar
end

# ── Example 9: B-spline channels ─────────────────────────────────────────────
# Curved channels using B-spline geometry. Same fan-in/fan-out topology as
# example 4 but with non-straight channels and BSplineRouting transitions.

function example_bspline()
    channels = [
        bchannel(0, -2, 30°, 1, 12),     # v_left
        bchannel(-1, 2, -30°, 12, 9),    # h_mid
        bchannel(10, -2, 30°, 11, 12)   # v_right
    ]
    # Left pins clustered at y=3,4,5,6 — all cross v_left
    # Right pins spread at y=0,3,6,9 — all cross v_right
    hooks = [
        lpin(-3, 3),   # p1
        lpin(-3, 4),   # p2
        lpin(-3, 5),   # p3
        lpin(-3, 6),   # p4
        rpin(14, 0),   # p5
        rpin(14, 3),   # p6
        rpin(14, 6),   # p7
        rpin(14, 9)   # p8
    ]
    nets = [(1, 5), (2, 6), (3, 7), (4, 8)]

    ar = Paths.ChannelRouter(nets, hooks, RouteChannel.(channels))
    transition_rule = Paths.BSplineRouting(
        auto_speed=true,
        auto_curvature=true,
        endpoints_speed=1,
        endpoints_curvature=0
    )

    routes = autoroute!(ar, transition_rule, 1.0)
    c = visualize_router_state(ar, wire_width=WW)
    @assert all(length.(ar.net_wires) .> 0) "All nets should be routed"
    paths = Path.(routes, Ref(Paths.Trace(WW)))
    @assert isempty(inter_path_intersections(paths)) "No crossings"
    @assert length(ar.channel_tracks[3]) == 3 "Last vertical channel only needs 3 tracks"
    return c, ar
end

# ── Example 10: 40-net fan-out ───────────────────────────────────────────────
# 40 nets fan out through a single wide channel from inner to outer pin rows.

function example_fanout40()
    lx_outer = ly_outer = 10e6nm
    lx_inner = ly_inner = 5e6nm

    fanout_space_bottom =
        Path(Point(-lx_outer / 2, -(ly_inner / 2 + (ly_outer - ly_inner) / 4)))
    straight!(fanout_space_bottom, lx_outer, Paths.Trace(0.8 * (ly_outer - ly_inner) / 4))

    n_nets = 40
    x0s = range(-lx_outer / 2, stop=lx_outer / 2, length=n_nets + 2)[2:(end - 1)]
    x1s = range(-lx_inner / 2, stop=lx_inner / 2, length=n_nets + 2)[2:(end - 1)]
    p0s = [PointHook(x, -ly_outer / 2, -90°) for x in x0s]
    p1s = [PointHook(x, -ly_inner / 2, 90°) for x in x1s]
    mynets = [(i, i + n_nets) for i = 1:n_nets]
    ar = ChannelRouter(mynets, vcat(p0s, p1s), [RouteChannel(fanout_space_bottom)])
    routes = Paths.autoroute!(ar, Paths.StraightAnd90(10μm), 10μm)
    c = Paths.visualize_router_state(ar, wire_width=1μm)
    @assert all(length.(ar.net_wires) .> 0) "All nets should be routed"
    paths = Path.(routes, Ref(Paths.Trace(WW)))
    @assert isempty(inter_path_intersections(paths)) "No crossings"
    @assert length(ar.channel_tracks[1]) <= 20 "Left and right halves share tracks"
    return c, ar
end

# ── Example 11: Schematic interface ───────────────────────────────────────────
# Same as `example_crossing` but using the schematic interface to set up the routing problem.

function example_crossing_schematic()
    channels = RouteChannel.([
        vchannel(5mm, -1mm, 7mm, width=2.0mm),     # v_mid
        hchannel(-1mm, 9mm, 0mm, width=2.0mm),     # h_bot
        hchannel(-1mm, 9mm, 6mm, width=2.0mm)     # h_top
    ])

    hooks = [
        bpin(2mm, -0.5mm),   # p1: below h_bot, left side
        bpin(8mm, -0.5mm),   # p2: below h_bot, right side
        tpin(2mm, 6.5mm),    # p3: above h_top, left side
        tpin(8mm, 6.5mm)    # p4: above h_top, right side
    ]
    # Crossed: bottom-left↔top-right, bottom-right↔top-left
    nets = [(1, 4), (2, 3)]
    # Set up schematic
    g = SchematicGraph("example")
    # Start/end components
    comps = [Spacer(; p1=h.p) for h in hooks]
    comp_nodes = add_node!.(g, comps)
    ar = ChannelRouter(channels)
    rule = AutoChannelRouting(ar, Paths.StraightAnd90(MARGIN*1mm), MARGIN*1mm)
    r1 = route!(g, rule, comp_nodes[1]=>:p1_south, comp_nodes[4]=>:p1_north, Paths.Trace(WW*1mm), GDSMeta())
    r2 = route!(g, rule, comp_nodes[2]=>:p1_south, comp_nodes[3]=>:p1_north, Paths.Trace(WW*1mm), GDSMeta())

    sch = plan(g)
    paths = [SchematicDrivenLayout.path(r1), SchematicDrivenLayout.path(r2)]
    c = Cell(sch.coordinate_system)
    # c = visualize_router_state(ar; wire_width=WW)

    @assert all(length.(ar.net_wires) .> 0) "All nets should be routed"
    # Both nets traverse v_mid, so it needs ≥2 tracks
    @assert length(ar.channel_tracks[1]) >= 2 "Crossing nets need multiple tracks in shared channel"
    # Due to assignment order, only one horizontal channel has two tracks
    @assert length(ar.channel_tracks[2]) + length(ar.channel_tracks[3]) == 3 "Crossing nets need multiple horizontal tracks only when they overlap due to vertical assignment"
    @assert length(inter_path_intersections(paths)) == 1 "Exactly one crossing"
    return c, ar
end

# ── Assembly ─────────────────────────────────────────────────────────────────

const ALL_EXAMPLES = [
    "simple" => example_simple,
    "parallel" => example_parallel,
    "crossing" => example_crossing,
    "fanin_fanout" => example_fanin_fanout,
    "multichannel_fanout" => example_multichannel_fanout,
    "grid" => example_grid,
    "angled" => example_angled,
    "dense" => example_dense,
    "bspline" => example_bspline,
    "fanout40" => example_fanout40,
    "crossing_schematic" => example_crossing_schematic,
]

function run_all_examples(; save_gds=true, save_png=true, dir=@__DIR__)
    results = Pair{String, Tuple{Cell, ChannelRouter}}[]
    for (name, fn) in ALL_EXAMPLES
        @info "Running $name..."
        push!(results, name => fn())
    end
    if save_gds
        for (name, (c, _)) in results
            save(joinpath(dir, "autoroute_$(name).gds"), c; spec_warnings=false)
        end
        @info "Saved $(length(results)) GDS files"
    end
    if save_png
        for (name, (c, _)) in results
            save(joinpath(dir, "autoroute_$(name).png"), c; spec_warnings=false)
        end
        @info "Saved $(length(results)) PNG files"
    end
    return results
end

end # module
