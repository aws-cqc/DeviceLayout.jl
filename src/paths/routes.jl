"""
    abstract type RouteRule end

Controls how a `Route` is turned into a `Path`.

A `RouteRule` may contain parameters or be used only for dispatch. It should implement one
of the following two methods:

```
_route!(p::Path, p1::Point, α1, rule::MyRouteRule, sty, waypoints, waydirs)
_route_leg!(p::Path, next::Point, rule::MyRouteRule,
    sty::Paths.Style=Paths.contstyle1(p))
```

It may also implement

```
reconcile!(path::Path, endpoint::Point,
    end_direction, rule::RouteRule, waypoints, waydirs; initialize_waydirs)
```

If only `_route_leg!` is implemented, then a `Path` drawn from `r::Route` with `MyRouteRule`
will first call `reconcile!` to validate constraints and insert waypoints if necessary. (The
default implementation of `reconcile!` does nothing.) The `Path` will then be routed
waypoint-to-waypoint such that the path starts at `r.p0`, passes through each
point in `r.waypoints` in order, and then ends at `r.p1`, ignoring `waydirs`. Alternatively,
`_route!` can be implemented to use `r.waypoints` and/or `r.waydirs` all at once as desired.
"""
abstract type RouteRule end

"""
    Base.@kwdef struct StraightAnd90 <: RouteRule
        min_bend_radius = 200μm
        max_bend_radius = Inf*μm
    end
    StraightAnd90(r) = StraightAnd90(min_bend_radius=r, max_bend_radius=r)

Specifies rules for routing from one point to another using straight segments and 90° bends.

Can be used with no `waydirs` if each waypoint is reachable from the previous with a single
turn and the endpoint is reachable with a single turn or two turns in opposite directions.

If `waydirs` are used, then any waypoint may be reachable with two turns in opposite
directions if that satisfies the corresponding waydirection.
"""
Base.@kwdef struct StraightAnd90 <: RouteRule
    min_bend_radius = 200μm
    max_bend_radius = Inf * μm
end
StraightAnd90(r) = StraightAnd90(min_bend_radius=r, max_bend_radius=r)

"""
    Base.@kwdef struct StraightAnd45 <: RouteRule
        min_bend_radius = 200μm
        max_bend_radius = Inf*μm
    end
    StraightAnd45(r) = StraightAnd45(min_bend_radius=r, max_bend_radius=r)

Specifies rules for routing from one point to another using using straight segments and 45° bends.

Can be used with no `waydirs` if each waypoint is reachable from the previous with a single
turn and the endpoint is reachable with one or two turns.

If `waydirs` are used, then any waypoint may be reachable with two turns if that satisfies
the corresponding waydirection.
"""
Base.@kwdef struct StraightAnd45 <: RouteRule
    min_bend_radius = 200μm
    max_bend_radius = Inf * μm
end
StraightAnd45(r) = StraightAnd45(min_bend_radius=r, max_bend_radius=r)

"""
    Base.@kwdef struct BSplineRouting <: RouteRule
        endpoints_speed = 2500μm
        auto_speed = false
        endpoints_curvature = nothing
        auto_curvature = false
    end

Specifies rules for routing from one point to another using BSplines.

Ignores `waydirs`.
"""
Base.@kwdef struct BSplineRouting <: RouteRule
    endpoints_speed = 2500μm
    auto_speed = false
    endpoints_curvature = nothing
    auto_curvature = false
end

"""
    CompoundRouteRule <: RouteRule
    CompoundRouteRule(rules::Vector{RouteRule}, leg_length::Vector{Int}=ones(length(rules)))

Specifies a sequence of rules for routing from one point to another, where `rules[i]` is used
to route through the next `leg_length[i]` waypoints and/or endpoint.
"""
struct CompoundRouteRule <: RouteRule
    rules::Vector{RouteRule}
    leg_lengths::Vector{Int}
end
CompoundRouteRule(rules::Vector{RouteRule}) = CompoundRouteRule(rules, ones(length(rules)))

"""
    struct Route{T<:RouteRule, S<:Coordinate}
    Route(rule, startpoint::Point{S}, endpoint::Point, start_direction, end_direction; waypoints=Point{S}[], waydirs=[])
    Route(rule, path0::Path, endpoint::Point, end_direction)

A `Route` implicitly defines a `Path` between two points with given start and end directions.

Use `Path(r::Route, sty::Paths.Style)` to create the explicit path.

Contains a `RouteRule` to determine how the `Path` should be drawn.

May contain `waypoints` and `waydirs` that additionally constrain the route. The `RouteRule`
determines how these are handled, by default routing waypoint-to-waypoint such that the path
starts at `p0`, passes through each point in `waypoints` in order, and then ends at `p1`.

If `waydirs` is not `nothing`, it should have the same length as `waypoints`. If `waydirs`
is provided and is not ignored by the `RouteRule` (check the specific rule documentation),
then `waypoints[i]` will be reached with the path pointing along `waydirs[i]`.
"""
mutable struct Route{S <: Coordinate}
    rule::RouteRule
    p0::Point{S}
    p1::Point{S}
    α0::typeof(1.0°)
    α1::typeof(1.0°)
    waypoints::Vector{Point{S}}
    waydirs::Vector{typeof(1.0°)}
end
Route(
    rule,
    startpoint::Point{S},
    endpoint::Point,
    start_direction,
    end_direction;
    waypoints=Point{S}[],
    waydirs=[]
) where {S} = Route{float(S)}(
    rule,
    startpoint,
    endpoint,
    start_direction,
    end_direction,
    waypoints,
    waydirs
)

Route(rule, path0::Path, endpoint::Point, end_direction; kwargs...) =
    Route(rule, p1(path0), endpoint, α1(path0), end_direction; kwargs...)

@inline Base.eltype(::Route{T}) where {T} = T
@inline Base.eltype(::Type{Route{T}}) where {T} = T

"""
    p0(r::Route)

First point of a route, returns `r.p0`.
"""
p0(r) = r.p0
"""
    p1(r::Route)

Last point of a route, returns `r.p1`.
"""
p1(r) = r.p1
"""
    α0(r::Route)

First angle of a route, returns `r.α0`.
"""
α0(r) = r.α0
"""
    α1(r::Route)

Last angle of a route, returns `r.α1`.
"""
α1(r) = r.α1

"""
    reconcile!(path::Path, endpoint::Point, end_direction, rule::RouteRule, waypoints, waydirs;
        initialize_waydirs = false)

Ensure that `path` can be routed to `endpoint` at `end_direction` using `rule, waypoints, waydirs`, or throw an error.

Does nothing for a generic `RouteRule`. Subtypes of `RouteRule` may implement specialized methods
to do their own validation when `route!` is called.

May insert inferred constraints to `waypoints` and `waydirs` to allow the path to be drawn
leg-by-leg. For example, `reconcile!` with `rule::StraightAnd90`, no waypoints, and
`α1(path) == end_direction` will insert a waypoint halfway between `p1(path)` and `endpoint`,
allowing two successive `StraightAnd90` legs with opposite bends.
"""
function reconcile!(
    path::Path,
    endpoint::Point,
    end_direction,
    rule::RouteRule,
    waypoints,
    waydirs;
    initialize_waydirs=false
) end

function reconcile!(
    path::Path,
    endpoint::Point,
    end_direction,
    rule::StraightAnd90,
    waypoints,
    waydirs;
    initialize_waydirs=false
)
    α_bend = 90°
    startpoint = p1(path)
    startdir = α1(path)
    dα = uconvert(°, rem(end_direction - startdir, 360°, RoundNearest))

    isapprox((dα / α_bend), round(dα / α_bend), atol=1e-9) || error(
        "StraightAnd90 routing can only be used with start and end vectors on the same 4-point compass"
    )

    i = 0
    while i < length(waypoints) + 1 # Waypoints may be added
        # otherwise this would be for (i, nextpoint) in enumerate([waypoints..., endpoint])
        i = i + 1
        nextpoint = (i > length(waypoints) ? endpoint : waypoints[i])
        dx = nextpoint.x - startpoint.x
        dy = nextpoint.y - startpoint.y

        # decompose into parallel and perpendicular shifts
        # use sincosd (or sincospi) to make sure (e.g.) cos(pi/2) is exactly 0
        dir_y, dir_x = sincosd(uconvert(°, startdir))
        par = dx * dir_x + dy * dir_y
        perp = -dx * dir_y + dy * dir_x # perp > 0 requires +90° turn

        par >= zero(par) || error(
            "StraightAnd90 routing cannot go backwards from $startpoint to $nextpoint. Try adding intermediate points."
        )

        sgn = isapprox(perp, zero(dx), atol=1e-6 * oneunit(dx)) ? 0 : sign(perp)

        sgn == 0 ||
            (
                (abs(perp) >= rule.min_bend_radius || (abs(perp) ≈ rule.min_bend_radius)) &&
                (par >= rule.min_bend_radius || par ≈ rule.min_bend_radius)
            ) ||
            error(
                "Required bend between $startpoint and $nextpoint is too sharp for single segment of StraightAnd90 routing"
            )

        dα_01 = sgn * α_bend
        nextdir = startdir + dα_01 # direction after next turn
        nextdir_target = (i > length(waydirs) ? end_direction : waydirs[i])
        # If waydirs are uninitialized, we need to assume a single turn (except to endpoint)
        if i <= length(waydirs) && initialize_waydirs
            waydirs[i] = nextdir
            # Otherwise, this is the endpoint or waydirs are initialized
            # If this is a snake, try to insert a waypoint
            # Except if we're also already inline (sgn == 0)
        elseif isapprox_angle(nextdir_target, startdir) && sgn != 0
            # Add an intermediate waypoint to snake to endpoint
            abs(perp) >= 2 * rule.min_bend_radius && par >= 2 * rule.min_bend_radius ||
                error(
                    "Required bend between $startpoint and $((startpoint + nextpoint)/2) is too sharp for single segment of StraightAnd90 routing"
                )
            nextpoint = (startpoint + nextpoint) / 2
            insert!(waypoints, i, nextpoint)
            insert!(waydirs, i, nextdir)
        end

        startpoint = nextpoint
        startdir = nextdir
    end
end

function reconcile!(
    path::Path,
    endpoint::Point,
    end_direction,
    rule::StraightAnd45,
    waypoints,
    waydirs;
    initialize_waydirs=false
)
    α_bend = 45°
    startpoint = p1(path)
    startdir = α1(path)
    dα = uconvert(°, rem(end_direction - startdir, 360°, RoundNearest))

    isapprox((dα / α_bend), round(dα / α_bend), atol=1e-9) || error(
        "StraightAnd45 routing can only be used with start and end vectors on the same 8-point compass"
    )

    i = 0
    while i < length(waypoints) + 1 # Waypoints may be added
        # otherwise this would be for (i, nextpoint) in enumerate([waypoints..., endpoint])
        i = i + 1
        nextpoint = (i > length(waypoints) ? endpoint : waypoints[i])
        dx = nextpoint.x - startpoint.x
        dy = nextpoint.y - startpoint.y

        # decompose into parallel and perpendicular shifts
        # use sincosd (or sincospi) to make sure (e.g.) cos(pi/2) is exactly 0
        dir_y, dir_x = sincosd(uconvert(°, startdir))
        par = dx * dir_x + dy * dir_y
        perp = -dx * dir_y + dy * dir_x # perp > 0 requires +90° turn

        par >= zero(par) || error(
            "StraightAnd45 routing cannot go backwards from $startpoint to $nextpoint. Try adding intermediate points."
        )

        sgn = isapprox(perp, zero(dx), atol=1e-6 * oneunit(dx)) ? 0 : sign(perp)
        dα_01 = sgn * α_bend
        nextdir = startdir + dα_01 # direction after next turn
        nextdir_target = (i > length(waydirs) ? end_direction : waydirs[i])
        # If waydirs are uninitialized, we need to assume a single turn (except to endpoint)
        if i <= length(waydirs) && initialize_waydirs
            waydirs[i] = nextdir
            if sgn != 0 # Check
                bend_r = max(
                    rule.min_bend_radius,
                    min(
                        rule.max_bend_radius,
                        abs(perp) / (1 - cos(α_bend)),
                        (abs(par) - abs(perp)) / tan(α_bend / 2)
                    )
                )
                d = bend_r * tan(α_bend / 2)

                d_diag = sqrt(2) * abs(perp) - d
                d_straight = abs(par) - abs(perp) - d
                d_diag > -1e-9 * oneunit(d) && d_straight > -1e-9 * oneunit(d) ||
                    error("$nextpoint can't be reached from $startpoint with a 45° turn")
            end
            # Otherwise, this is the endpoint or waydirs are initialized
            # If this is a snake, try to insert a waypoint
            # Except if we're also already inline (sgn == 0)
        elseif isapprox_angle(nextdir_target, startdir) && sgn != 0
            # Check if snake is possible
            bend_r = max(
                rule.min_bend_radius,
                min(
                    rule.max_bend_radius,
                    abs(perp / 2) / (1 - cos(α_bend)),
                    (abs(par) - abs(perp)) / 2 / tan(α_bend / 2)
                )
            )
            d = bend_r * tan(α_bend / 2)

            d_diag = sqrt(2) * abs(perp / 2) - d
            d_straight = abs(par / 2) - abs(perp / 2) - d
            d_diag > -1e-9 * oneunit(d) && d_straight > -1e-9 * oneunit(d) ||
                error("Next point can't be reached with a pair of opposite 45° turns")
            # Add an intermediate waypoint to snake to endpoint
            # Pushing to waypoints won't cause confusion because this is the last iteration
            nextpoint = (startpoint + nextpoint) / 2
            insert!(waypoints, i, nextpoint)
            insert!(waydirs, i, nextdir)
        elseif ( # If this is a double turn
            isapprox_angle(nextdir_target, startdir + 90°) ||
            isapprox_angle(nextdir_target, startdir - 90°)
        )
            # Check if double turn is possible
            abs(perp) < rule.min_bend_radius ||
                abs(par) < rule.min_bend_radius &&
                    error("Next point can't be reached with a pair of 45° turns")
            bend_r =
                max(rule.min_bend_radius, min(abs(perp), abs(par), rule.max_bend_radius))

            d = bend_r / sqrt(2)

            p_45 = if abs(par) < abs(perp)
                startpoint + bend_r * Point(cos(nextdir_target), sin(nextdir_target))
            else
                nextpoint - bend_r * Point(cos(startdir), sin(startdir))
            end
            nextpoint = p_45 - sgn * bend_r * Point(-sin(nextdir), cos(nextdir))

            # Add an intermediate waypoint
            insert!(waypoints, i, nextpoint)
            insert!(waydirs, i, nextdir)
        end

        startpoint = nextpoint
        startdir = nextdir
    end
end

"""
    Path(r::Route, sty)

The explicit `Path` defined by `r`, with style `sty`.
"""
function Path(r::Route, sty)
    path = Path(r.p0, α0=r.α0)
    route!(path, r.p1, r.α1, r.rule, sty; waypoints=r.waypoints, waydirs=r.waydirs)
    return path
end

"""
    function route!(path::Path{S}, p_end::Point, α_end, rule::RouteRule, sty=Paths.contstyle1(path);
                    waypoints=Point{S}[], waydirs=Vector{typeof(1.0°)}(undef, length(waypoints)))) where {S}

Extend `path` to `p_end` with arrival angle `α_end` according to `RouteRule`. The default
implementation is

```
reconcile!(path, p_end, α_end, rule, waypoints, waydirs)
_route!(path, p_end, α_end, rule, sty, waypoints, waydirs)
```

followed by checking that the endpoint was successfully reached.
"""
function route!(
    path::Path{S},
    p_end::Point,
    α_end,
    rule::RouteRule,
    sty=Paths.contstyle1(path);
    waypoints=Point{S}[],
    waydirs=nothing,
    atol=1e-9 * DeviceLayout.onemicron(S)
) where {S}
    initialize_waydirs = (isnothing(waydirs) || isempty(waydirs))
    if initialize_waydirs
        waydirs = Vector{typeof(1.0°)}(undef, length(waypoints))
    end
    reconcile!(
        path,
        p_end,
        α_end,
        rule,
        waypoints,
        waydirs,
        initialize_waydirs=initialize_waydirs
    )
    _route!(path, p_end, α_end, rule, sty, waypoints, waydirs)
    isapprox(rem(α1(path) - α_end, 360°, RoundNearest), 0, atol=1e-9) || error("""
                                                          Could not automatically route to destination with the correct arrival angle \
                                                          (got $(α1(path)) instead of $α_end). Try adding or adjusting waypoints.\
                                                          """)
    pts = promote(p1(path), p_end)
    return isapprox(pts...; atol=atol) || error("""
                 Could not automatically route to destination with the correct arrival point \
                 (got $(p1(path)) instead of $p_end). Try adding or adjusting waypoints.\
                 """)
end

"""
    function _route!(path::Path, p_end::Point, α_end, rule::RouteRule, sty, waypoints, waydirs)
        for (wp, wd) in zip(waypoints, waydirs)
            _route_leg!(path, wp, wd, rule, sty)
        end
        _route_leg!(path, p_end, α_end, rule, sty)
    end

Routing for a generic `RouteRule`, falling back to waypoint-to-waypoint routing.
"""
function _route!(path::Path, p_end::Point, α_end, rule::RouteRule, sty, waypoints, waydirs)
    for (wp, wd) in zip(waypoints, waydirs)
        _route_leg!(path, wp, wd, rule, sty)
    end
    return _route_leg!(path, p_end, α_end, rule, sty)
end

function _route!(
    path::Path,
    p_end::Point,
    α_end,
    rule::BSplineRouting,
    sty,
    waypoints,
    waydirs
)
    return bspline!(
        path,
        vcat(waypoints, [p_end]),
        α_end,
        sty,
        endpoints_speed=rule.endpoints_speed,
        auto_speed=rule.auto_speed,
        endpoints_curvature=rule.endpoints_curvature,
        auto_curvature=rule.auto_curvature
    )
end

function route!(
    path::Path{S},
    p1::Point,
    α1,
    crr::CompoundRouteRule,
    sty=fill(Paths.contstyle1(path), length(rules));
    waypoints=Point{S}[],
    waydirs=Vector{typeof(1.0°)}(undef, length(waypoints))
) where {S}
    sum(crr.leg_lengths) == length(waypoints) + 1 ||
        error("CompoundRouteRule leg lengths must match the number of waypoints + endpoint")
    length(waydirs) == length(waypoints) ||
        error("CompoundRouteRule requires a direction for each waypoint")
    leg_start = 1
    for (idx, leg_rule) in enumerate(crr.rules)
        if idx == length(crr.rules)
            route!(
                path,
                p1,
                α1,
                leg_rule,
                sty[idx],
                waypoints=waypoints[leg_start:end],
                waydirs=waydirs[leg_start:end]
            )
        else
            leg_end = leg_start + crr.leg_lengths[idx] - 1
            route!(
                path,
                waypoints[leg_end],
                waydirs[leg_end],
                leg_rule,
                sty[idx],
                waypoints=waypoints[leg_start:(leg_end - 1)],
                waydirs=waydirs[leg_start:(leg_end - 1)]
            )
            leg_start = leg_end + 1
        end
    end
end

function _route_leg!(
    p::Path{S},
    next::Point,
    nextdir,
    rule::StraightAnd90,
    sty::Paths.Style=Paths.contstyle1(p)
) where {S}
    dx = next.x - p1(p).x
    dy = next.y - p1(p).y
    par = dx * cos(α1(p)) + dy * sin(α1(p))
    perp = -dx * sin(α1(p)) + dy * cos(α1(p)) # perp > 0 requires +90° turn

    if isapprox(perp, zero(dx), atol=1e-6 * oneunit(S))
        straight!(p, par, sty)
        return
    end

    bend_r = max(rule.min_bend_radius, min(rule.max_bend_radius, abs(perp), abs(par)))
    l1 = max(abs(par) - bend_r, zero(bend_r))
    l2 = π / 2 * bend_r
    l3 = max(abs(perp) - bend_r, zero(bend_r))

    # Taper styles need to know the total length to split the taper appropriately
    if isa(sty, ContinuousStyle{true})
        sty = typeof(sty)((getfield(sty, i) for i = 1:(nfields(sty) - 1))..., l1 + l2 + l3)
    end

    seg_sty = [
        l1 > zero(l1) ? pin(sty, stop=l1) : sty,
        l3 > zero(l3) ? pin(sty, start=l1, stop=l1 + l2) : pin(sty, start=l1),
        l3 > zero(l3) ? pin(sty, start=l1 + l2) : sty
    ]
    l1 > zero(dx) && straight!(p, l1, seg_sty[1])
    turn!(p, 90° * sign(perp), bend_r, seg_sty[2])
    return l3 > zero(dx) && straight!(p, l3, seg_sty[3])
end

function _route_leg!(
    p::Path{S},
    next::Point,
    nextdir,
    rule::StraightAnd45,
    sty::Paths.Style=Paths.contstyle1(p)
) where {S}
    dx = next.x - p1(p).x
    dy = next.y - p1(p).y

    par = dx * cos(α1(p)) + dy * sin(α1(p))
    perp = -dx * sin(α1(p)) + dy * cos(α1(p)) # perp > 0 requires +45° turn

    if isapprox(perp, zero(dx), atol=1e-6 * oneunit(S))
        straight!(p, par, sty)
        return
    end
    bend_r = max(
        rule.min_bend_radius,
        min(
            rule.max_bend_radius,
            abs(perp) / (1 - cos(45°)),
            (abs(par) - abs(perp)) / tan(45° / 2)
        )
    )
    d = bend_r * tan(22.5°)

    d_diag = max(zero(d), sqrt(2) * abs(perp) - d)
    l_bend = pi / 4 * bend_r
    d_straight = max(zero(d), abs(par) - abs(perp) - d)

    # Taper styles need to know the total length to split the taper appropriately
    if isa(sty, ContinuousStyle{true})
        sty = typeof(sty)(
            (getfield(sty, i) for i = 1:(nfields(sty) - 1))...,
            d_diag + l_bend + d_straight
        )
    end

    seg_sty = [
        d_straight > zero(d_straight) ? pin(sty, stop=d_straight) : sty,
        d_diag > zero(d_diag) ? pin(sty, start=d_straight, stop=d_straight + l_bend) :
        pin(sty, start=d_straight),
        d_diag > zero(d_diag) ? pin(sty, start=d_straight + l_bend) : sty
    ]

    d_straight > zero(dx) && straight!(p, d_straight, seg_sty[1])
    turn!(p, 45° * sign(perp), bend_r, seg_sty[2])
    return d_diag > zero(dx) && straight!(p, d_diag, seg_sty[3])
end
