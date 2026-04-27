@testitem "Autorouter internals" setup = [CommonTestSetup] begin
    import DeviceLayout.Paths: ChannelRouter, RouteChannel, autoroute!
    # ── Helpers (shared with autoroute_examples.jl) ──────────────────────────────

    hchannel(x0, x1, y; width=2.0) =
        let pa = Path(Float64(x0), Float64(y))
            straight!(pa, Float64(x1 - x0), Paths.Trace(Float64(width)))
            pa
        end
    vchannel(x, y0, y1; width=2.0) =
        let pa = Path(Float64(x), Float64(y0), α0=90°)
            straight!(pa, Float64(y1 - y0), Paths.Trace(Float64(width)))
            pa
        end

    lpin(x, y) = PointHook(Point(Float64(x), Float64(y)), 180°)
    rpin(x, y) = PointHook(Point(Float64(x), Float64(y)), 0°)
    bpin(x, y) = PointHook(Point(Float64(x), Float64(y)), 270°)
    tpin(x, y) = PointHook(Point(Float64(x), Float64(y)), 90°)

    """
    Build a ChannelRouter and run channel assignment only (no track assignment).
    """
    function _route_channels(channels, hooks, nets)
        ar = ChannelRouter(nets, hooks, RouteChannel.(channels))
        Paths.assign_channels!(ar)
        return ar
    end

    # ── is_avoidable ─────────────────────────────────────────────────────────────
    # Pure function: is_avoidable(low1, high1, low2, high2, lt1, ht1, lt2, ht2)
    # Determines if a crossing between two overlapping segments can be resolved
    # by choosing track order, based on the tendency (±1) at each endpoint.

    @testset "is_avoidable" begin
        # Segments: [0,6] and [3,9], high1 < high2 → order = [1,2,1,2]
        # All same tendency (all +1): not avoidable
        @test Paths.is_avoidable(0, 6, 3, 9, 1, 1, 1, 1) == false

        # Alternating: seg1 enters up, exits down; seg2 enters down, exits up
        # Tendencies: low1=+1, high1=-1, low2=-1, high2=+1
        @test Paths.is_avoidable(0, 6, 3, 9, 1, -1, -1, 1) == false

        # Seg1 both up, seg2 both down
        @test Paths.is_avoidable(0, 6, 3, 9, 1, 1, -1, -1) == true

        # Contained case: high2 <= high1 → order = [1,2,2,1]
        # All same tendency: avoidable
        @test Paths.is_avoidable(0, 9, 3, 6, 1, 1, 1, 1) == true
        # Contained, opposite
        @test Paths.is_avoidable(0, 9, 3, 6, -1, -1, -1, -1) == true

        # Shared endpoint (low1 == low2): assumed avoidable depending on neighbor
        @test Paths.is_avoidable(0, 6, 0, 9, 1, -1, -1, -1) == true
        @test Paths.is_avoidable(0, 6, 0, 9, -1, 1, -1, 1) == true
        # Crossing is still not avoidable if the entry/exit points make an X
        @test Paths.is_avoidable(0, 6, 0, 9, 1, -1, -1, 1) == false
        @test Paths.is_avoidable(0, 6, 0, 9, -1, 1, 1, -1) == false

        # Shared endpoint (high1 == high2): assumed avoidable
        @test Paths.is_avoidable(0, 9, 3, 9, 1, -1, 1, 1) == true
    end

    # ── segments_overlap: boundary case with tendency ────────────────────────────
    # The knock-knee relaxation (strict < instead of <=) should NOT apply when
    # segments at a shared endpoint face the same direction.

    @testset "segments_overlap boundary" begin
        # Crossing setup: 2H + 1V, two nets that cross in the vertical channel.
        # v_mid assigned first so its track offsets propagate.
        channels = [
            vchannel(5, -1, 7),     # idx 1: v_mid
            hchannel(-1, 9, 0),     # idx 2: h_bot
            hchannel(-1, 9, 6)     # idx 3: h_top
        ]
        hooks = [
            bpin(2, -0.5),   # p1: below h_bot, left
            bpin(8, -0.5),   # p2: below h_bot, right
            tpin(2, 6.5),    # p3: above h_top, left
            tpin(8, 6.5)    # p4: above h_top, right
        ]
        # Crossing: bottom-left↔top-right, bottom-right↔top-left
        ar = _route_channels(channels, hooks, [(1, 4), (2, 3)])

        # In h_bot (channel 2): two segments touching at the v_mid intersection (x=5)
        segs_hbot = ar.channel_segments[2]
        @test length(segs_hbot) == 2
        # These segments touch at x=5 with same tendency (both enter v_mid going up)
        # → should be treated as overlapping (can't knock-knee)
        @test Paths.segments_overlap(ar, segs_hbot[1], segs_hbot[2]) == true

        # In v_mid (channel 1): two segments fully overlapping (both span h_bot→h_top)
        segs_vmid = ar.channel_segments[1]
        @test length(segs_vmid) == 2
        @test Paths.segments_overlap(ar, segs_vmid[1], segs_vmid[2]) == true
    end

    @testset "segments_overlap knock-knee" begin
        # Parallel setup: two nets through a shared channel, NOT crossing.
        # They should NOT overlap since knock-knee is possible
        # (touching at boundary with opposite tendencies)
        channels = [
            vchannel(5, -1, 10),     # idx 1: v_mid
            hchannel(-1, 9, 0),     # idx 2: h_bot
            hchannel(-1, 9, 6),     # idx 3: h_mid
            hchannel(-1, 9, 9)     # idx 3: h_top
        ]
        hooks = [
            bpin(2, -0.5),   # p1
            tpin(8, 6.5),    # p2
            bpin(2, 4),      # p3
            tpin(8, 9.5)    # p4
        ]
        # Parallel: bottom-left↔top-left, bottom-right↔top-right
        ar = _route_channels(channels, hooks, [(1, 2), (3, 4)])

        # In v_mid: both nets traverse it but one starts where the other ends
        # And they come from opposite sides at that point
        # Knock-knee relaxation says they don't overlap
        segs_vmid = ar.channel_segments[1]
        @test length(segs_vmid) == 2
        @test Paths.segments_overlap(ar, segs_vmid[1], segs_vmid[2]) == false
    end

    # ── Track assignment results ─────────────────────────────────────────────────
    # Verify that track counts match expectations after full routing.

    @testset "track assignment: crossing" begin
        channels = [vchannel(5, -1, 7), hchannel(-1, 9, 0), hchannel(-1, 9, 6)]
        hooks = [bpin(2, -0.5), bpin(8, -0.5), tpin(2, 6.5), tpin(8, 6.5)]
        ar = ChannelRouter([(1, 4), (2, 3)], hooks, RouteChannel.(channels))
        autoroute!(ar, Paths.StraightAnd90(0.1), 0.1)

        # v_mid gets 2 tracks (full overlap)
        @test length(ar.channel_tracks[1]) == 2
        # One horizontal channel gets 2 tracks (post-crossing overlap detected),
        # the other gets 1 (pre-crossing, touching but not overlapping)
        h_tracks = length(ar.channel_tracks[2]) + length(ar.channel_tracks[3])
        @test h_tracks == 3
    end

    @testset "track assignment: parallel" begin
        channels = [
            vchannel(0, -1, 9),
            vchannel(10, -1, 9),
            hchannel(-1, 11, 0),
            hchannel(-1, 11, 4),
            hchannel(-1, 11, 8)
        ]
        hooks = [
            lpin(-0.5, 0),
            lpin(-0.5, 4),
            lpin(-0.5, 8),
            rpin(10.5, 0),
            rpin(10.5, 4),
            rpin(10.5, 8)
        ]
        ar = ChannelRouter([(1, 4), (2, 5), (3, 6)], hooks, RouteChannel.(channels))
        autoroute!(ar, Paths.StraightAnd90(0.1), 0.1)

        @test all(length.(ar.net_wires) .> 0)
        # No channel should need more than 1 track (non-crossing parallel routes)
        @test all(length.(ar.channel_tracks) .<= 1)
    end

    # ── routing_summary ──────────────────────────────────────────────────────
    @testset "routing_summary" begin
        channels = [vchannel(5, -1, 7), hchannel(-1, 9, 0), hchannel(-1, 9, 6)]
        hooks = [bpin(2, -0.5), bpin(8, -0.5), tpin(2, 6.5), tpin(8, 6.5)]
        ar = ChannelRouter([(1, 4), (2, 3)], hooks, RouteChannel.(channels))
        autoroute!(ar, Paths.StraightAnd90(0.1), 0.1)

        output = sprint(Paths.routing_summary, ar)
        @test occursin("Net 1:", output)
        @test occursin("Net 2:", output)
        @test !occursin("UNASSIGNED", output)
    end

    # ── validate_routes ──────────────────────────────────────────────────────
    @testset "validate_routes" begin
        channels = [vchannel(5, -1, 7), hchannel(-1, 9, 0), hchannel(-1, 9, 6)]
        hooks = [bpin(2, -0.5), bpin(8, -0.5), tpin(2, 6.5), tpin(8, 6.5)]
        ar = ChannelRouter([(1, 4), (2, 3)], hooks, RouteChannel.(channels))
        autoroute!(ar, Paths.StraightAnd90(0.1), 0.1)

        ok = Paths.validate_routes(ar, Paths.Trace(0.05))
        @test ok isa BitVector
        @test length(ok) == 2
        @test all(ok)
    end

    # ── verbose autoroute! ───────────────────────────────────────────────────
    @testset "verbose autoroute!" begin
        channels = [hchannel(0, 10, 0)]
        hooks = [bpin(2, -0.5), tpin(8, 0.5)]
        ar = ChannelRouter([(1, 2)], hooks, RouteChannel.(channels))

        # verbose=true should not error and should produce log output
        routes = autoroute!(ar, Paths.StraightAnd90(0.1), 0.1; verbose=true)
        @test length(routes) == 1
        @test all(length.(ar.net_wires) .> 0)
    end

    # ── reroute_nets! ────────────────────────────────────────────────────────
    @testset "reroute_nets!" begin
        channels = [vchannel(5, -1, 7), hchannel(-1, 9, 0), hchannel(-1, 9, 6)]
        hooks = [bpin(2, -0.5), bpin(8, -0.5), tpin(2, 6.5), tpin(8, 6.5)]
        ar = ChannelRouter([(1, 4), (2, 3)], hooks, RouteChannel.(channels))
        autoroute!(ar, Paths.StraightAnd90(0.1), 0.1)

        # Record original track assignments
        orig_tracks_net1 = [Paths.segment_track(ar, ws) for ws in Paths.net_wire(ar, 1)]
        @test all(!isnothing, orig_tracks_net1)

        # Reroute net 1 with a fixed channel path
        affected = Paths.reroute_nets!(ar, [1]; fixed_paths=Dict(1 => [2, 1, 3]))
        @test 1 in affected
        @test 2 in affected  # net 2 shares all channels with net 1

        # Net 1 should still be routed
        @test length(Paths.net_wire(ar, 1)) > 0
        # Track assignments should still be valid
        new_tracks_net1 = [Paths.segment_track(ar, ws) for ws in Paths.net_wire(ar, 1)]
        @test all(!isnothing, new_tracks_net1)
    end

    # ── best_matching! bipartite shape ───────────────────────────────────────
    @testset "best_matching! bipartite shape" begin
        import Graphs: SimpleGraph, SimpleDiGraph, add_edge!

        # 4 vertices, L={1,2}, R={3,4}, edges (1,3), (1,4), (2,3).
        # True max bipartite matching has 2 R→L pairs (e.g. 3→2, 4→1).
        g = SimpleGraph(4)
        add_edge!(g, 1, 3)
        add_edge!(g, 1, 4)
        add_edge!(g, 2, 3)
        # Empty VCG preserves all merging edges (no ancestor constraints).
        vcg = SimpleDiGraph(4)

        m = Paths.best_matching!(g, vcg, Set([1, 2]), Set([3, 4]))
        @test length(m) == 2
        @test all(k in (3, 4) for k in keys(m))
        @test all(v in (1, 2) for v in values(m))
        @test length(unique(values(m))) == 2  # no duplicate L targets
    end
end
