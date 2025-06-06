"""
    ExampleStarIsland <: Component

Example transmon capacitor with five capacitive couplers.

The transmon island is a five-pointed star with truncated tips. Five wedge-shaped capacitive
coupling pads fill the gaps between star arms.

# Parameters

Note that when this component is created within an `ExampleStarTransmon`,
these defaults are overridden.

  - `name = "island"`: Name of component
  - `island_outer_radius = 135μm`: Radius of island at the tips of the star
  - `island_inner_radius = [80, 80, 80, 80, 80]μm`: Radii of island between the tips of stars,
    clockwise from 12 o'clock (smaller radius produces a larger coupler pad at that location)
  - `island_ground_gap = 15μm`: Gap between island (tips of star) and ground
  - `island_coupler_gap = 15μm`: Gap between island and couplers
  - `star_tip_width = 50μm`: Width of star tips
  - `coupler_style = Paths.CPW(10μm, 10μm)`: `Path` style for couplers
  - `rounding = 5μm`: Rounding applied to ground plane geometry

# Hooks

  - `coupler_i`, for `i` from `1` to `5`: Interface point for coupler, clockwise from 12 o'clock,
    inward direction pointing back towards island
  - `junction`: Edge of star tip `1` that connects to junction or SQUID, inward direction pointing down
  - `origin`: Center of star, with inward direction pointing right
  - `xy`: Edge of ground plane opposite star tip `5`, inward direction pointing right
  - `z`: Edge of ground plane opposite star tip `5`, inward direction pointing down
"""
@compdef struct ExampleStarIsland <: Component
    name = "island"
    # Defaults for constructing the island directly
    # (ExampleStarTransmon has its own defaults for these, used to construct its island)
    island_outer_radius = 135μm
    island_inner_radius = [80, 80, 80, 80, 80]μm
    island_ground_gap = 15μm
    island_coupler_gap = 15μm
    star_tip_width = 50μm
    coupler_style = Paths.CPW(10μm, 10μm)
    rounding = 5μm
end

function SchematicDrivenLayout._geometry!(cs::CoordinateSystem, isl::ExampleStarIsland)
    (;
        island_outer_radius,
        island_inner_radius,
        island_ground_gap,
        island_coupler_gap,
        star_tip_width,
        coupler_style,
        rounding
    ) = isl
    ground_radius = island_outer_radius + island_ground_gap
    θ_outer = range(π / 2, step=2π / 5, length=5)
    θ_inner = θ_outer .+ π / 5
    ## Draw the inner star
    # 2 * r * sin(dθ) = star_tip_width
    dθ_tip = asin(star_tip_width / (2 * island_outer_radius))
    island_pts = vcat(
        [ # Points should be CCW
            Rotation(
                θ
            ).([
                island_outer_radius * Point(1, sin(-dθ_tip)),
                island_outer_radius * Point(1, sin(+dθ_tip)),
                r * Point(cos(π / 5), sin(π / 5))
            ]) for (θ, r) in zip(θ_outer, reverse(island_inner_radius))
        ]...
    )
    island = Polygon(island_pts)
    positive_polys = [island] # We'll accumlate all the positive metal shapes here
    ## Draw the outer triangular coupling pads
    dθ_coupler_pad =
        π / 5 - asin((star_tip_width / 2 + island_coupler_gap) / (island_outer_radius))
    dθ_pad = [-dθ_coupler_pad, 0.0, dθ_coupler_pad, 0.0]
    for (θ, r) in zip(θ_inner, reverse(island_inner_radius))
        r_pad = [
            island_outer_radius,
            island_outer_radius,
            island_outer_radius,
            r + island_coupler_gap
        ]
        pad = Polygon(r_pad .* Point.(cos.(θ .+ dθ_pad), sin.(θ .+ dθ_pad)))
        push!(positive_polys, pad)
    end

    ## Draw the outer "circle"
    dθ_coupler_trace = asin((coupler_style.trace / 2) / ground_radius)
    dθ_coupler_extent = asin((coupler_style.trace / 2 + coupler_style.gap) / ground_radius)
    pts_facing_star_tip = [ # Use points at fixed x so island-ground distance is exact
        ground_radius * Point(1, sin(-dθ_tip)),
        ground_radius * Point(1, sin(dθ_tip))
    ]
    pts_coupler_interface =
        Rotation(
            π / 5
        ).([ # Use constant x to get flat interface for path out
            ground_radius * Point(1, sin(-dθ_coupler_extent)),
            ground_radius * Point(1, sin(-dθ_coupler_trace)),
            ground_radius * Point(1, sin(dθ_coupler_trace)),
            ground_radius * Point(1, sin(dθ_coupler_extent))
        ])
    outer_pts = vcat([Rotation(θ).([
        pts_facing_star_tip
        pts_coupler_interface
    ]) for θ in θ_outer]...)
    outer = Polygon(outer_pts)
    interface_pts = vcat([Rotation(θ).(pts_coupler_interface) for θ in θ_outer]...)

    ## Draw the coupler lead rectangles
    lead = Rectangle(coupler_style.trace, island_ground_gap + 5μm)
    lead = Align.flushbottom(lead, outer, centered=true)
    append!(positive_polys, [Rotation(θ - π / 2)(lead) for θ in θ_outer])

    cutout = difference2d(outer, positive_polys)
    roundsty = StyleDict() # Different styles for inner and outer contours
    roundsty[1] = Rounded(
        rounding; # Outer contour: Round coupler pads and outer circumference
        p0=interface_pts, # Don't round these points so coupler interface is flat
        inverse_selection=true
    )
    roundsty[1, 1] = Rounded(rounding) # Inner contour: round everything

    rounded_cutout = roundsty(cutout)

    return place!(cs, MeshSized(rounded_cutout, critical_dimension(isl)), METAL_NEGATIVE)
end

function critical_dimension(isl::ExampleStarIsland)
    return min(
        isl.star_tip_width - 2 * isl.rounding,
        isl.coupler_style.trace,
        isl.coupler_style.gap,
        isl.island_ground_gap,
        isl.island_coupler_gap
    )
end

function SchematicDrivenLayout.hooks(isl::ExampleStarIsland)
    (; island_outer_radius, island_ground_gap) = isl
    h = PointHook(island_outer_radius + island_ground_gap, 0μm, -180°)
    θ = (π / 2 - π / 5):(-2π / 5):(-3π / 2 + π / 5) # clockwise starting with 12 o'clock
    return (;
        coupler=rotate.(Ref(h), θ),
        junction=PointHook(zero(island_outer_radius), island_outer_radius, -90°),
        origin=PointHook(0mm, 0mm, 0°),
        xy=PointHook(Rotation(π / 2 + 2π / 5)(h.p), 0°),
        z=HandedPointHook(rotate(h, π / 2))
    )
end

# Define custom exclusion zone/footprint
function DeviceLayout.halo(
    isl::ExampleStarIsland,
    outer_delta,
    inner_delta=nothing;
    kwargs...
)
    c = to_polygons(footprint(isl))
    temp_cs = CoordinateSystem{coordinatetype(isl)}(uniquename(name(isl)))
    place!(temp_cs, c, first(geometry(isl).element_metadata))
    return halo(temp_cs, outer_delta, inner_delta; kwargs...)
end

function DeviceLayout.footprint(isl::ExampleStarIsland)
    return Circle(isl.island_outer_radius + isl.island_ground_gap)
end
