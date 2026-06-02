# Helper functions for routing
function add_routes!(g, port_nodes, q_nodes, readout_nodes, p)
    # Add control first so readout crosses over control in `crossovers!`
    xy, z = add_control!(g, port_nodes, q_nodes, p)
    readout = add_readout!(g, port_nodes, readout_nodes, p)
    return (; xy, z, readout)
end

function add_control!(g, port_nodes, q_nodes, p)
    (; S90_TIGHT, CONTROL_ROUTE_RULE, LINE_SPECIFICATIONS) = p.routing
    # Make containers to hold the route nodes for each group, for later convenience
    xy_nodes = ComponentNode[]
    z_nodes = ComponentNode[]
    for (idx, linespec) in enumerate(LINE_SPECIFICATIONS)
        # Check for `nothing` first so we can unpack safely
        (isnothing(linespec) || contains(linespec[1], "RO")) && continue
        role, target, wp = linespec # Unpack tuple
        if role == "XY"
            rule = target == (3, 3) ? S90_TIGHT : CONTROL_ROUTE_RULE
            node = route!(
                g,
                rule,
                port_nodes[idx] => :p1,
                q_nodes[target...] => :xy,
                p.device.FEEDLINE_STYLE,
                METAL_NEGATIVE;
                name=uniquename("r_xy_$idx"),
                waypoints=wp,
                global_waypoints=true
            )
            push!(xy_nodes, node)
        elseif role == "Z"
            node = route!(
                g,
                CONTROL_ROUTE_RULE,
                port_nodes[idx] => :p1,
                q_nodes[target...] => :z,
                p.device.FEEDLINE_STYLE,
                METAL_NEGATIVE;
                name=uniquename("r_z_$idx"),
                waypoints=wp,
                global_waypoints=true
            )
            push!(z_nodes, node)
        end
    end
    return xy_nodes, z_nodes
end

function add_readout!(g, port_nodes, readout_nodes, p)
    (;
        S45_LOOSE,
        READOUT_ROUTE_RULE,
        LINE_SPECIFICATIONS,
        READOUT_GROUPS,
        RO_WAYPOINTS,
        RO_MEANDER_PARAMS
    ) = p.routing
    # Make a container to hold the readout route nodes for each group, for later convenience
    readout_route_nodes = [ComponentNode[] for _ = 1:length(READOUT_GROUPS)]
    for (idx, linespec) in enumerate(LINE_SPECIFICATIONS)
        # Continue until we find RO_IN
        isnothing(linespec) && continue # Check for `nothing` first so we can unpack safely
        role, group, _ = linespec # Unpack tuple
        role != "RO_IN" && continue
        readout_sites = READOUT_GROUPS[group] # List of (row, col) sites on this readout line
        prev = fuse!(g, port_nodes[idx] => :p1, p.device.RO_INPUT_CAPACITOR => :p0) # Input capacitor
        rule = S45_LOOSE # First leg is always StraightAnd45 with arbitrary bend radius
        for (idx_in_group, site) in enumerate(readout_sites)
            next = readout_nodes[site...]
            node = route!(
                g,
                rule,
                prev => :p1,
                next => :p0,
                p.device.FEEDLINE_STYLE,
                METAL_NEGATIVE;
                name=uniquename("r_ro_$group"),
                waypoints=meander_waypoints(
                    RO_WAYPOINTS[group][idx_in_group],
                    RO_MEANDER_PARAMS[group][idx_in_group]
                ),
                global_waypoints=true
            )
            push!(readout_route_nodes[group], node)
            prev = next
            rule = READOUT_ROUTE_RULE
        end

        out = findfirst(rg -> rg == ("RO_OUT", group, []), LINE_SPECIFICATIONS)
        node = route!(
            g,
            S45_LOOSE,
            prev => :p1,
            port_nodes[out] => :p1,
            p.device.FEEDLINE_STYLE,
            METAL_NEGATIVE;
            name=uniquename("r_ro_$group"),
            waypoints=RO_WAYPOINTS[group][end],
            global_waypoints=true
        )
        push!(readout_route_nodes[group], node)
    end
    return readout_route_nodes
end

# Utility for calculating meander lengths to meet halfwave condition for voltage antinode
# Must `plan` beforehand so that routes have been determined
function calculate_readout_lengths(readout_nodes, readout_route_nodes, p)
    # For each group, trace through the readout line
    for (group, route_nodes) in pairs(readout_route_nodes)
        println("Group $group:")
        sites = p.routing.READOUT_GROUPS[group]
        pathlength_from_input = 0.0nm
        for (route_node, site) in zip(route_nodes[1:(end - 1)], sites)
            readout_node = readout_nodes[site...]
            # Calculate pathlength from input at site
            pathlength_from_input +=
                pathlength(SchematicDrivenLayout.path(component(route_node)))
            # Readout component contains feedline length; resonator is coupled halfway
            pathlength_from_input += readout_node.feedline_length / 2
            println("Length at $(site): $(uconvert(mm, pathlength_from_input))")
            # Calculate remaining length to filter halfwavelength. The readout components are
            # parameterized by physical length; add back the ~1mm device-level effective-length
            # allowance (bends, bridges, coupling) to approximate the effective half-wavelength.
            filter_halfwavelength = 2 * (readout_node.filter_total_length + 1.0mm)
            remainder = rem(pathlength_from_input, filter_halfwavelength)
            next_halfwave = filter_halfwavelength - remainder
            println(
                "Length to next halfwave: $(uconvert(mm, next_halfwave)) (-$(uconvert(mm, remainder)))"
            )
            # Add the other half of feedline length inside the readout component
            pathlength_from_input += readout_node.feedline_length / 2
        end
    end
end

# Utility for adding meanders to readout routes by setting waypoints
function meander_waypoints(orig_wp, meander_spec; after_idx=1, bend_radius=50μm)
    isempty(meander_spec) && return orig_wp
    (; addlength, dir, dx, dy) = meander_spec
    dx > zero(dx) || error("Meander `dx` (allowed forward distance) should be positive")
    # Calculate number of periods and straight lengths required
    # Warning: Ignores effective length delta from bends
    max_period_length = 2 * (abs(dy) - 2 * bend_radius + π * bend_radius)
    dx_period = 4 * bend_radius
    num_periods = ceil((addlength + dx_period) / max_period_length)
    replaced_length = dx_period * num_periods
    (dx >= replaced_length) ||
        error("Not enough room to add $addlength: $num_periods periods required")
    straight_length =
        (((addlength + replaced_length) / num_periods) - 2 * pi * bend_radius) / 2
    # Calculate waypoints per period
    period_wp = [
        Point(bend_radius, straight_length / 2 + bend_radius),
        Point(2 * bend_radius, straight_length + 2 * bend_radius),
        Point(3 * bend_radius, straight_length / 2 + bend_radius),
        Point(4 * bend_radius, zero(bend_radius))
    ]
    dy < zero(dy) && (period_wp = XReflection().(period_wp))
    # Make waypoints for each period
    relative_wp = vcat(
        [period_wp .+ (i - 1) * Point(dx_period, zero(dx_period)) for i = 1:num_periods]...
    )
    # Convert to path coordinates
    new_wp = Translation(orig_wp[after_idx]).(Rotation(dir).(relative_wp))
    # Return original waypoints with `new_wp...` after `after_idx`
    all_wp = copy(orig_wp)
    splice!(all_wp, (after_idx + 1):after_idx, new_wp)
    return all_wp
end
