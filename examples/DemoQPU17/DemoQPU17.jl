module DemoQPU17
# Using a module to let us cleanly include file in test script without worrying about namespaces

using DeviceLayout, .SchematicDrivenLayout, DeviceLayout.PreferredUnits
using FileIO

import .SchematicDrivenLayout.ExamplePDK
import .SchematicDrivenLayout.ExamplePDK: L1_TARGET, add_bridges!
using .ExamplePDK.LayerVocabulary,
    .ExamplePDK.ChipTemplates,
    .ExamplePDK.Transmons,
    .ExamplePDK.ReadoutResonators,
    .ExamplePDK.ClawCapacitors

import Unitful: uconvert

include("params.jl")
include("routing.jl")
include("visualization.jl")

function assemble_schematic_graph!(g, p)
    ##### Define components
    # Parameter naming convention (see params.jl):
    # ALL_CAPS: Fixed/derived/floorplanning parameter
    # lower_case: Tuning parameter
    (; # unpack named tuple of device parameters
        FEEDLINE_STYLE,
        FEEDLINE_BRIDGE,
        CONTROL_BRIDGE,
        RESONATOR_BRIDGE,
        COUPLER_BRIDGE
    ) = p.device

    ### Transmons
    (; # unpack named tuple of transmon parameters
        ACTIVE_SITES,
        MIRRORED_LR,
        MIRRORED_UD,
        GROUNDED_COUPLERS,
        island_inner_radius,
        coupler_style,
        resonator_style,
        control_style
    ) = p.transmons
    # Use `@component` macro to create a 5x5 array of components
    # where the `i`th qubit (in column-major order) is named "q_$i"
    @component q[1:5, 1:5] = ExampleStarTransmon begin
        # Broadcast assignment (.=) so each qubit gets corresponding value from 5x5 parameter matrix
        right_handed .= (MIRRORED_LR .⊻ MIRRORED_UD)
        grounded_couplers .= GROUNDED_COUPLERS
        island_inner_radius .= island_inner_radius
        # Assignment not broadcasted so that all qubits get the same parameter
        coupler_style = coupler_style
        coupler_bridge = COUPLER_BRIDGE
        resonator_style = resonator_style
        xy_style = control_style
        z_style = control_style
        control_bridge = CONTROL_BRIDGE
    end
    ### Readout
    @component readout[1:5, 1:5] = ExampleFilteredHairpinReadout begin
        filter_total_effective_length .= p.readout.RO_EFFECTIVE_LENGTH
        readout_total_effective_length .= p.readout.RO_EFFECTIVE_LENGTH
        resonator_style = resonator_style
        resonator_bridge = RESONATOR_BRIDGE
        feedline_style = FEEDLINE_STYLE
        feedline_tap_style = FEEDLINE_STYLE
        feedline_bridge = FEEDLINE_BRIDGE
    end
    # Manually set a few exceptions for floorplanning convenience
    readout[3, 1] = readout[3, 1](; extra_filter_l1=400μm)
    readout[2, 5] = readout[2, 5](; extra_filter_l1=700μm)
    readout[3, 3] = readout[3, 3](;
        extra_filter_l1=550μm,
        tap_position=0.45mm,
        extra_filter_l2=710μm,
        extra_filter_θ1=45°,
        extra_filter_θ2=-45°,
        straight_length=1.0mm
    )
    readout[4, 1] = readout[4, 1](; extra_filter_l1=700μm)

    ##### Assemble schematic
    ### Chip and launchers
    chip = add_node!(g, ExampleChip())
    launchers = example_launcher.(p.routing.LINE_SPECIFICATIONS)
    port_nodes = similar(p.routing.LINE_SPECIFICATIONS, ComponentNode) # Vector to hold launcher nodes
    for (idx, launcher) in enumerate(launchers)
        isnothing(launcher) && continue
        port_nodes[idx] = # Fuse hook named port_$idx on chip to hook p0 on launcher
            fuse!(g, chip => Symbol("port_$idx"), launcher => :p0)
    end

    ### Qubits
    q_nodes = similar(ACTIVE_SITES, Any) # Array to hold qubit nodes
    q_nodes[ACTIVE_SITES] .= add_node!.(g, q[ACTIVE_SITES])
    for (I, site_active) in pairs(IndexCartesian(), ACTIVE_SITES[1:4, 1:4])
        !site_active && continue
        row, col = Tuple(I)
        if ACTIVE_SITES[row + 1, col] # Neighbor in next row (below)
            h1 = MIRRORED_UD[I] ? :coupler_N : :coupler_S
            h2 = MIRRORED_UD[row + 1, col] ? :coupler_S : :coupler_N
            fuse!(g, q_nodes[I] => h1, q_nodes[row + 1, col] => h2)
        end
        if ACTIVE_SITES[row, col + 1] # Neighbor in next column (to the right)
            h1 = MIRRORED_LR[I] ? :coupler_W : :coupler_E
            h2 = MIRRORED_LR[row, col + 1] ? :coupler_E : :coupler_W
            fuse!(g, q_nodes[I] => h1, q_nodes[row, col + 1] => h2)
        end
    end
    fuse!(g, chip => :origin, q_nodes[3, 3] => :origin) # Center the lattice at chip origin

    ### Readout resonators
    readout_nodes = similar(q_nodes) # Array to hold readout nodes
    for (I, site_active) in pairs(IndexCartesian(), ACTIVE_SITES)
        !site_active && continue
        readout_nodes[I] = fuse!(g, q_nodes[I] => :readout, readout[I] => :qubit)
    end

    ### Routing
    route_nodes = add_routes!(g, port_nodes, q_nodes, readout_nodes, p)
    ### Return nodes organized as a NamedTuple for later convenience
    return (; chip, port_nodes, q_nodes, readout_nodes, route_nodes)
end

function qpu17_demo(; savegds=true, dir=pwd())
    #### Reset name counter for consistency within a Julia session
    reset_uniquename!()
    p = qpu_params()
    (; XSTY, FEEDLINE_BRIDGE, GROUND_HOLE_RADIUS, GROUND_HOLE_SPACING) = p.device
    #### Assemble schematic graph
    g = SchematicGraph("qpu17_demo")
    @time "Assembling schematic graph" nodes = assemble_schematic_graph!(g, p)

    #### Floorplanning (place and route)
    @time "Floorplanning" schematic = plan(g; log_dir=dir) # Place components and define routes
    @time "Schematic design rule checking" check!(schematic) # Make sure schematic follows any relevant rules
    # Optional: Readout line length calculations
    # calculate_readout_lengths(nodes.readout_nodes, nodes.route_nodes.readout, p)

    #### Crossovers
    # Automatically generate crossovers wherever Paths/Routes intersect
    # This includes Paths that are subcomponents of CompositeComponents
    # So e.g. the center transmon's Purcell filter has a crossover with a coupler
    # This checks all segment pairs for intersections, which can be slow in large devices
    # If you know which nodes cross, you can feed only those to `crossovers!` to save time
    @time "Generating crossovers" SchematicDrivenLayout.crossovers!(schematic, XSTY)
    add_bridges!(schematic, FEEDLINE_BRIDGE) # Add bridges to paths
    # Note: Crossover and bridge geometry and placement are not optimized for microwave
    # properties or for manufacturing. Like the rest of the design, they are chosen to be
    # simple for demonstration purposes.

    #### Autofill with ground plane holes
    hole_cs = CoordinateSystem("gnd_hole") # Coordinate system for a single hole
    place!(hole_cs, not_simulated(Circle(GROUND_HOLE_RADIUS)), METAL_NEGATIVE)
    bnds = bounds(schematic, find_components(ExampleChip, schematic)...) # bounds of the chip node
    exclusion = make_halo(50μm; ignore_layers=[CHIP_AREA]) # function to create exclusion area
    x_grid = (lowerleft(bnds).x + 600μm):GROUND_HOLE_SPACING:(upperright(bnds).x - 600μm) # raster x-coordinates
    y_grid = (lowerleft(bnds).y + 600μm):GROUND_HOLE_SPACING:(upperright(bnds).y - 600μm) # raster y-coordinates
    @time "Ground-plane hole fill" autofill!(schematic, hole_cs, x_grid, y_grid, exclusion)

    #### Render results to Cell for GDS export
    # Equivalent one-liner to the below: artwork = Cell(schematic, L1_TARGET)
    artwork = Cell("qpu17_demo") # "artwork" = "pattern used for fabrication"
    @time "Rendering to polygons" render!(artwork, schematic, L1_TARGET)
    # Flatten to avoid 1nm gaps from rounded Cell origins + non-Manhattan rotations when saving to GDS format
    # But don't flatten references with more than 100 copies, we'd end up with 10k hole polygons
    @time "Flattening cells" flatten!(artwork, max_copy=100)
    savegds && @time "Saving GDS" save(joinpath(dir, "qpu17_demo.gds"), artwork)

    return schematic, artwork
end

end # module
