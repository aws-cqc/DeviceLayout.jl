Route(rule, hook0::PointHook, endpoint::Point, end_direction; kwargs...) =
    Route(rule, path_out(hook0), endpoint, end_direction; kwargs...)

Route(rule, path0::Path, hook1::PointHook; kwargs...) =
    Route(rule, path0, hook1.p, hook1.in_direction; kwargs...)

Route(rule, hook0::PointHook, hook1::PointHook; kwargs...) =
    Route(rule, hook0.p, hook1.p, out_direction(hook0), hook1.in_direction; kwargs...)

"""
    struct RouteComponent{T} <: AbstractComponent{T}
        name::String
        r::Paths.Route{T}
        global_waypoints::Bool
        sty::Paths.Style
        meta::Meta

Wraps a `Route` in a `Component` type for use with schematics.

`name` should be unique. If `global_waypoints` is false, then the waypoints and waydirs are
taken to be relative to the component coordinate system. Otherwise, they will be relative to
the schematic global coordinate system.
"""
mutable struct RouteComponent{T} <: AbstractComponent{T}
    name::String
    r::Paths.Route{T}
    global_waypoints::Bool
    sty::Vector{Paths.Style}
    meta::Meta
    _path::Path{T}
    RouteComponent{T}(n, r, g, s, m) where {T} = new{T}(n, r, g, s, m, Path{T}(n))
end
RouteComponent(
    name::String,
    r::Paths.Route{T},
    gw::Bool,
    sty::Paths.Style,
    meta::Meta
) where {T} = RouteComponent{T}(name, r, gw, [sty], meta)
hooks(rc::RouteComponent) = (p0=PointHook(rc.r.p0, rc.r.α0), p1=PointHook(rc.r.p1, rc.r.α1))

function redecorate!(path::Path, sty::Paths.Style) end
function redecorate!(path::Path, sty::Paths.DecoratedStyle)
    seg_lengths = pathlength.(path)
    seg_start_pos = [sum(seg_lengths[1:(i - 1)]) for i in eachindex(seg_lengths)]
    for (t, dir, ref) in zip(sty.ts, sty.dirs, sty.refs)
        if t < zero(t)
            t = pathlength(path) + t
        end
        idx = findlast(seg_start_pos .<= t)
        attach!(path, ref, t - seg_start_pos[idx], i=idx, location=dir)
    end
end

_undec(sty::Paths.Style) = sty
_undec(sty::Paths.DecoratedStyle) = sty.s # just remove attachments, not overlays
function path(rc::RouteComponent)
    !isempty(rc._path) && return rc._path
    path = rc._path
    r = rc.r
    path.p0 = r.p0
    path.α0 = r.α0
    path.name = rc.name
    path.metadata = rc.meta
    if length(rc.sty) == 1
        route!(
            path,
            r.p1,
            r.α1,
            r.rule,
            _undec(rc.sty[1]);
            waypoints=r.waypoints,
            waydirs=r.waydirs
        )
        redecorate!(path, rc.sty[1]) # apply decorations
    else # Vector of styles for each segment
        route!(
            path,
            r.p1,
            r.α1,
            r.rule,
            _undec.(rc.sty);
            waypoints=r.waypoints,
            waydirs=r.waydirs
        )
        redecorate!.(Ref(path), rc.sty)
    end

    return rc._path
end

function _geometry!(cs::CoordinateSystem, rc::RouteComponent)
    return _geometry!(cs, path(rc))
end

function route!(
    g,
    rule,
    node1::ComponentNode,
    node2::ComponentNode,
    sty,
    meta;
    name="r_$(component(node1).name)_$(component(node2).name)",
    kwargs...
)
    h1, h2 = matching_hooks(component(node1), component(node2))
    return route!(g, rule, node1 => h1, node2 => h2, sty, meta; name=name, kwargs...)
end

route!(
    g,
    rule,
    nodehook1::Pair{ComponentNode, Symbol},
    node2::ComponentNode,
    sty,
    meta;
    name="r_$(component(nodehook1.first).name)_$(component(node2).name)",
    kwargs...
) = route!(
    g,
    rule,
    nodehook1,
    node2 =>
        matching_hook(component(nodehook1.first), nodehook1.second, component(node2)),
    sty,
    meta;
    name=name,
    kwargs...
)

route!(
    g,
    rule,
    node1::ComponentNode,
    nodehook2::Pair{ComponentNode, Symbol},
    sty,
    meta;
    name="r_$(component(node1).name)_$(component(nodehook2.first).name)",
    kwargs...
) = route!(
    g,
    rule,
    node1 =>
        matching_hook(component(nodehook2.first), nodehook2.second, component(node1)),
    nodehook2,
    sty,
    meta;
    name=name,
    kwargs...
)

"""
    route!(g::SchematicGraph, rule::RouteRule,
        nodehook1::Pair{ComponentNode,Symbol}, nodehook2::Pair{ComponentNode,Symbol},
        sty, meta;
        waypoints=[], waydirs=[], global_waypoints=false,
        name=uniquename("r_\$(component(nodehook1.first).name)_\$(component(nodehook2.first).name)"),
        kwargs...)
    route!(g::SchematicGraph, rule::RouteRule, node1::ComponentNode, nodehook2::Pair{ComponentNode,Symbol}, sty, meta; kwargs...)
    route!(g::SchematicGraph, rule::RouteRule, nodehook1::Pair{ComponentNode,Symbol}, node2::ComponentNode, sty, meta; kwargs...)
    route!(g::SchematicGraph, rule::RouteRule, node1::ComponentNode, node2::ComponentNode, sty, meta; kwargs...)

Creates a `RouteComponent` with given style `sty` and metadata `meta`, and fuses it between the specified nodes and hooks in `g`.

Returns the resulting `ComponentNode` in `g`.

Example usage: `route!(g, BSplineRouting(), zline_node=>:feedline, z_launcher_node=>:line, Paths.CPW(10μm, 6μm), GDSMeta(1, 2))`

If one or both hook symbols are not specified, then `matching_hook` or `matching_hooks`
will be used to attempt to automatically find the correct hook or hooks.

The route will have start and endpoints at the origin until a method like `plan!` is called.
`waypoints` and `waydirs` are in component-local coordinates (unless `global_waypoints` is
`true`), and `rule` determines how they will be used.

Additional keyword arguments will become vertex properties for the `RouteComponent`'s node.

`name` should be unique.
"""
function route!(
    g::SchematicGraph,
    rule::RouteRule,
    nodehook1::Pair{ComponentNode, Symbol},
    nodehook2::Pair{ComponentNode, Symbol},
    sty,
    meta;
    waypoints=[],
    waydirs=[],
    global_waypoints=false,
    name=uniquename(
        "r_$(component(nodehook1.first).name)_$(component(nodehook2.first).name)"
    ),
    kwargs...
)
    S = typeof(1.0DeviceLayout.UPREFERRED)
    r = Route(
        rule,
        zero(Point{S}),
        zero(Point{S}),
        0,
        0,
        waypoints=waypoints,
        waydirs=waydirs
    )
    rc = RouteComponent(name, r, global_waypoints, sty, meta)
    # Add node and fuse to nodehook1
    rn = add_node!(g, rc; kwargs...)
    fuse!(g, nodehook1, rn => :p0)
    # fuse to nodehook2
    fuse!(g, nodehook2, rn => :p1)
    _update_with_graph!(rule, rn, g; kwargs...)
    return rn
end

function attach!(
    r::RouteComponent,
    c::CoordSysRef,
    t::Coordinate;
    location::Int=0,
    mark_dirty=true
)
    mark_dirty && empty!(r._path)
    return r.sty[1] = Paths.decorate(r.sty[1], eltype(r.r), t, location, c)
end

function attach!(
    r::RouteComponent,
    c::CoordSysRef,
    t;
    location=zeros(Int, length(t)),
    mark_dirty=true
)
    mark_dirty && empty!(r._path)
    for (ti, li) in zip(t, Iterators.cycle(location))
        attach!(r, c, ti, location=li, mark_dirty=false)
    end
end

# Update rules with information from schematic or graph
# Called from `route!(g::SchematicGraph, rule, ...)` and `plan`, respectively
function _update_with_graph!(rule::RouteRule, route_node, graph; kwargs...) end
function _update_with_plan!(rule::RouteRule, route_node, schematic) end

# SingleChannelRouting
# Set tracks when adding with `route!`
function _update_with_graph!(
    rule::Paths.SingleChannelRouting,
    route_node,
    graph;
    track=Paths.num_tracks(rule) + 1,
    kwargs...
)
    return Paths.set_track!(rule, route_node.component._path, track)
end

# Use global position of channel if it is a component in sch
function _update_with_plan!(rule::Paths.SingleChannelRouting, route_node, sch)
    isdefined(rule, :global_channel) && return
    idx = find_nodes(n -> component(n) === rule.channel, sch.graph)
    isempty(idx) && return # channel is not a component
    length(idx) > 1 && @error """
        Channel $(name(rule.channel)) appears multiple times in schematic. \
        To transform the channel to global coordinates for routing, it must \
        appear exactly once.
        """
    trans = transformation(sch, only(idx))
    global_node = trans(rule.channel.node)
    return rule.global_channel = Paths.RouteChannel(Path([global_node]))
end
