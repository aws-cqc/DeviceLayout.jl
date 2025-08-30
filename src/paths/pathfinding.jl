import Graphs: a_star, grid, weights, add_edge!
import DeviceLayout: Rectangle, Polygon

abstract type PathfindingRule{T <: RouteRule} <: RouteRule end

struct AStarRouting{T, U <: Coordinate} <: PathfindingRule{T}
    leg_rule::T
    domain::Rectangle{U}
    grid_step::U
    exclusion_fn::Function
    exclusion::Vector{Polygon{U}}
    excluded

    function AStarRouting(l, d::Rectangle{U}, s, f::Function) where {U}
        return new{typeof(l), U}(l, d, s, f, Polygon{U}[], [])
    end
end

leg_rule(pr::PathfindingRule) = pr.leg_rule

function _route_leg!(
    p::Path,
    next::Point,
    nextdir,
    rule::PathfindingRule,
    sty::Paths.Style=Paths.contstyle1(p)
)
    # Just use underlying rule
    return _route_leg!(p, next, nextdir, leg_rule(rule), sty)
end

function reconcile!(
    path::Path,
    endpoint::Point,
    end_direction,
    rule::AStarRouting,
    waypoints,
    waydirs;
    initialize_waydirs=false
)
    # Calculate and insert waypoints
    # Construct grid graph
    bbox = bounds(rule.domain)
    grid_x = range(bbox.ll.x, step=rule.grid_step, stop=bbox.ur.x)
    grid_y = range(bbox.ll.y, step=rule.grid_step, stop=bbox.ur.y)
    in_poly = DeviceLayout.gridpoints_in_polygon(rule.exclusion, grid_x, grid_y)
    nx = length(grid_x)
    ny = length(grid_y)
    grid_graph = grid((nx, ny))

    # Functions to convert from real space/cartesian indices to graph indices
    v_to_ix_iy(v::Int) = Tuple(CartesianIndices((1:nx, 1:ny))[v])
    ix_iy_to_v(ix::Int, iy::Int) = LinearIndices((1:nx, 1:ny))[ix, iy]
    v_to_xy(v::Int) = Point(grid_x[v_to_ix_iy(v)[1]], grid_y[v_to_ix_iy(v)[2]])
    xy_to_v(p::Point) = ix_iy_to_v(
        findfirst(xi -> xi + rule.grid_step / 2 > p.x, grid_x),
        findfirst(yi -> yi + rule.grid_step / 2 > p.y, grid_y)
    )

    # Set up pathfinding
    start_v = xy_to_v(p0(path))
    end_v = xy_to_v(endpoint)
    source = xy_to_v(p0(path) + # pathfinding starts with grid box index in front of start
                     rule.grid_step * Point(cos(α0(path)), sin(α0(path))))
    target = xy_to_v(endpoint - # pathfinding ends with grid box index in front of end
            rule.grid_step * Point(cos(end_direction), sin(end_direction)))
    heuristic(v) = uconvert(NoUnits, norm(endpoint - v_to_xy(v)) / rule.grid_step)

    w = Matrix{Float64}(weights(grid_graph))
    ## Add diagonals
    # for v1 = 1:(nx*ny)
    #     for v2 = (v1+1):(nx*ny)
    #         ix1, iy1 = v_to_ix_iy(v1)
    #         ix2, iy2 = v_to_ix_iy(v2)
    #         if abs(ix1 - ix2) == 1 && abs(iy1 - iy2) == 1
    #             add_edge!(grid_graph, v1, v2)
    #             w[v1, v2] = w[v2, v1] = sqrt(2)
    #         end
    #     end
    # end

    ## Set edges to excluded grid cells to infinite weight
    ## (deleting vertices would renumber them)
    in_poly[start_v] = true
    in_poly[end_v] = true
    for (v, excluded) in enumerate(in_poly)
        !excluded && continue
        w[v, :] .= Inf
        w[:, v] .= Inf
    end

    # Find shortest path
    ## Not deterministic!
    edges = a_star(grid_graph, source, target, w, heuristic)
    # Create waypoints
    ## Whenever we change direction, add a waypoint
    edge_direction(v1, v2) = (v_to_ix_iy(v2) .- v_to_ix_iy(v1))
    current_direction = edge_direction(start_v, source)
    for e in edges
        direction = edge_direction(e.src, e.dst)
        if direction != current_direction
            push!(waypoints, (v_to_xy(e.src) + v_to_xy(e.dst)) / 2)
            push!(waydirs, atan(direction[2], direction[1]))
            current_direction = direction
        end
    end
    final_direction = edge_direction(target, end_v)
    if current_direction == final_direction
        pop!(waypoints) # Don't need the last one
        pop!(waydirs)
    end
end

function _update_rule!(sch, node, rule::RouteRule) end

function _update_rule!(sch, node, rule::PathfindingRule)
    for planned_node in keys(sch.ref_dict) # Only components already planned
        (planned_node in rule.excluded) && continue
        append!(
            rule.exclusion,
            reduce(
                vcat,
                DeviceLayout.to_polygons.(
                    transformation(
                        sch,
                        planned_node
                    ).(flatten(rule.exclusion_fn(planned_node.component)).elements)
                ),
                init=Polygon{coordinatetype(sch)}[]
            )
        )
        push!(rule.excluded, planned_node)
    end
end
