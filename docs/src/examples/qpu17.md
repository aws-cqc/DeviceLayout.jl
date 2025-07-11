# Quantum processor with 17 transmons

In this example, we demonstrate the layout of a 17-transmon quantum processor (QPU). We roughly follow well-documented layouts published by the Quantum Device Lab at ETH Zurich—for example, in their 2022 *Nature* paper ["Realizing repeated quantum error correction in a distance-three surface code"](https://www.nature.com/articles/s41586-022-04566-8) (by Sebastian Krinner and coauthors) or the more recent ["Realizing Lattice Surgery on Two Distance-Three Repetition Codes with Superconducting Qubits"](https://arxiv.org/pdf/2501.04612) (2025, by Ilya Besedin, Michael Kerschbaum, and coauthors).

The full code for this example can be found [in `examples/DemoQPU17` in the DeviceLayout.jl repository](https://github.com/aws-cqc/DeviceLayout.jl/tree/main/examples/DemoQPU17). Components and process technology are drawn from the [ExamplePDK](examplepdk.md).

## Overview

To run the example, we `include` [the file `DemoQPU17.jl`](https://github.com/aws-cqc/DeviceLayout.jl/blob/main/examples/DemoQPU17/DemoQPU17.jl) from the example's folder. This defines a module containing all the necessary parameters and methods to generate the device. Then we run the `qpu17_demo()` method to produce the device schematic and artwork.

```@example 1
using DeviceLayout, FileIO
include("../../../examples/DemoQPU17/DemoQPU17.jl")
@time "Total" schematic, artwork = DemoQPU17.qpu17_demo(savegds=false)
@time "Saving" save("qpu17.png", flatten(artwork), width=12 * 72, height=12 * 72);
nothing # hide
```

```@raw html
<img src="../qpu17.png"/>
```

Note that the timings above are around 95% compilation. If we wanted to tweak some parameters and then run the script again in the same Julia session, then it would take around 5% as long:

```@example 1
@time "Total" schematic, artwork = DemoQPU17.qpu17_demo(savegds=false)
@time "Saving" save("qpu17.png", flatten(artwork), width=12 * 72, height=12 * 72);
nothing # hide
```

The example includes a utility to turn the schematic into a "false color" drawing where each component's footprint is drawn in a layer corresponding to that component's role:

```@example 1
falsecolor = DemoQPU17.false_color_layout!(schematic) # modify and render to Cell
save("qpu17_falsecolor.png", flatten(falsecolor), width=12 * 72, height=12 * 72);
nothing # hide
```

```@raw html
<img src="../qpu17_falsecolor.png"/>
```

We see the 17 transmons in red, the couplers between them in purple, and the readout resonators and filters in green. The XY control, Z control, and readout lines are blue, gold, and pink, respectively.

The schematic-driven workflow used to generate this layout consists of the following steps:

 1. [Define the component types](#Defining-component-types) that will appear in the device—resonators, transmons, and so on.
 2. [Choose sets of parameters](#Defining-parameters) for the component instances that will appear in your device.
 3. [Construct a `SchematicGraph`](#Assembling-the-schematic-graph) by adding component instances (nodes) and specifying connections between them (edges), including special "route" components that define wires to be automatically routed after other components are placed.
 4. [Construct a `Schematic`](#Floorplanning) from the `SchematicGraph` by running an automated floorplanning routine that positions and orients components in a 2D layout.
 5. [Check](#Schematic-rule-checking) that the schematic follows high-level design rules—for example, that all Josephson junctions have the correct orientation for your fabrication process.
 6. [Make any desired changes](#Finishing-touches) to the schematic, like creating crossovers between intersecting wires or filling the empty areas of the ground plane with holes for flux trapping.
 7. [Render](#Rendering) the schematic, generating 2D geometry for each component for output in a format like GDSII.

Schematic-driven layout allows the designer to work with a high-level description of the device independent of the detailed geometry. The component definitions specify what geometry to draw and, together with the automated floorplanning routine, ensure that they line up correctly with other components’ geometry. Designers can edit components without needing to manually track and correct far-reaching changes through the entire device, and they can easily reuse components in different schematics.

Let's take a closer look at each step with excerpts from the code. See the `examples/DemoQPU17` folder in the DeviceLayout.jl repository for the full code that was run above.

## Defining component types

For this example, we use predefined component types from DeviceLayout.jl’s [ExamplePDK module](examplepdk.md). These components are intended for tests and demonstrations, and are not necessarily optimized for device performance or experimentally validated.

Each component type has methods defining their parameterized geometry and "hooks"—special points where they connect to other components with a certain orientation. For this device, the most important components are transmons with fixed capacitive couplers ([`ExampleStarTransmon`](examplepdk.md#Transmons)) and readout resonators with Purcell filters ([`ExampleFilteredHairpinReadout`](examplepdk.md#ReadoutResonators)). These are both "composite" components, meaning that they're defined in terms of a `SchematicGraph` themselves, with subcomponents like the transmon island and individual resonators.

## Defining parameters

We set device parameters [in `DemoQPU17/params.jl`](https://github.com/aws-cqc/DeviceLayout.jl/blob/main/examples/DemoQPU17/params.jl) as named tuples returned by `qpu_params()`. These include component parameters, general device constants, and routing parameters. For transmons and readout resonators, we create parameter arrays with the same 5x5 shape as our qubit lattice, often using broadcasting (the `.` operator) to derive one array from another.

!!! warning
    
    These parameters are placeholders used to demonstrate layout of a full device. They are not chosen to target particular device properties.

```julia
##### Define parameters and constants for QPU, components, and routing
# ALL_CAPS: Fixed/derived/floorplanning parameter
# lower_case: Tuning parameter

### Transmons
# Lattice
ACTIVE_SITES = Bool[ # Where are there transmons?
    0 1 1 0 0 # not using the whole 5x5 grid
    0 1 1 1 1
    1 1 1 1 1
    1 1 1 1 0
    0 0 1 1 0
]
ROW = repeat(1:5, outer=(1, 5))
COL = transpose(ROW)
# Which transmons are facing different ways?
MIRRORED_LR = similar(ACTIVE_SITES)
MIRRORED_UD = similar(ACTIVE_SITES)
@. MIRRORED_LR = (COL > 3) || (COL == 3 && ROW < 3)
@. MIRRORED_UD = (ROW > 3) || (ROW == 3 && COL > 3)

# Which couplers are active?
GROUNDED_COUPLERS = map(eachindex(IndexCartesian(), ACTIVE_SITES)) do I
    row, col = Tuple(I)
    gc = Int[] # Will hold indices of grounded couplers (1-4)
    # Ground north coupler if we're in the first row or the site above us is empty
    gnd_north = (row == 1 || !ACTIVE_SITES[row - 1, col])
    gnd_south = (row == 5 || !ACTIVE_SITES[row + 1, col])
    gnd_west = (col == 1 || !ACTIVE_SITES[row, col - 1])
    gnd_east = (col == 5 || !ACTIVE_SITES[row, col + 1])
    # If the transmon is mirrored, switch east/west or north/south as appropriate
    MIRRORED_LR[row, col] && ((gnd_west, gnd_east) = (gnd_east, gnd_west))
    MIRRORED_UD[row, col] && ((gnd_north, gnd_south) = (gnd_south, gnd_north))
    # Fill up the list of grounded couplers
    gnd_north && push!(gc, 1)
    gnd_east && push!(gc, 2)
    gnd_south && push!(gc, 3)
    gnd_west && push!(gc, 4)
    return gc
end

# Transmon additional geometry parameters
DATA_QUBIT = iseven.(ROW .+ COL) # Data vs ancilla role in surface code
data_inner_radius = [80μm, 80μm, 80μm, 80μm, 20μm] # Big readout coupler for data
ancilla_inner_radius = [80μm, 80μm, 80μm, 80μm, 80μm]
island_inner_radius = ifelse.(DATA_QUBIT, Ref(data_inner_radius), Ref(ancilla_inner_radius))

coupler_style = Paths.CPW(10μm, 10μm)
resonator_style = Paths.CPW(10μm, 10μm)
control_style = Paths.CPW(3.3μm, 2μm)

transmons = (; # named tuple with variable names as keys
    ACTIVE_SITES,
    ROW,
    COL,
    MIRRORED_LR,
    MIRRORED_UD,
    GROUNDED_COUPLERS,
    DATA_QUBIT,
    data_inner_radius,
    ancilla_inner_radius,
    island_inner_radius,
    coupler_style,
    resonator_style,
    control_style
)

### Readout resonators
EFFECTIVE_INDEX = 2.5
ro_freq_GHz = [
    0.0 7.0 7.3 0.0 0.0
    0.0 7.4 7.1 7.5 6.9
    7.2 7.6 6.8 7.6 7.4
    6.9 7.3 7.5 7.2 0.0
    0.0 0.0 7.1 7.0 0.0
]
RO_EFFECTIVE_LENGTH = (299792458 ./ (4 * EFFECTIVE_INDEX * ro_freq_GHz))nm
readout = (; # named tuple with variable names as keys
    EFFECTIVE_INDEX,
    ro_freq_GHz,
    RO_EFFECTIVE_LENGTH
)

### Other device constants
FEEDLINE_STYLE = Paths.CPW(10μm, 6μm) # Used for both readout and control lines
FEEDLINE_BRIDGE = ExamplePDK.bridge_geometry(FEEDLINE_STYLE)
CONTROL_BRIDGE = ExamplePDK.bridge_geometry(control_style)
RESONATOR_BRIDGE = ExamplePDK.bridge_geometry(resonator_style)
COUPLER_BRIDGE = ExamplePDK.bridge_geometry(coupler_style)
GROUND_HOLE_SPACING = 100μm
GROUND_HOLE_RADIUS = 5μm
RO_INPUT_CAPACITOR = ExampleSeriesClawCapacitor(input_length=700μm)
# Crossover style (simple scaffolded bridge, not optimized for microwave properties)
XSTY = Intersect.AirBridge(
    crossing_gap=5μm,
    foot_gap=3μm,
    foot_length=10μm,
    extent_gap=3μm,
    scaffold_gap=3μm,
    scaffold_meta=LayerVocabulary.BRIDGE_BASE,
    air_bridge_meta=LayerVocabulary.BRIDGE
)
device = (; # named tuple with variable names as keys
    FEEDLINE_STYLE,
    FEEDLINE_BRIDGE,
    CONTROL_BRIDGE,
    RESONATOR_BRIDGE,
    COUPLER_BRIDGE,
    GROUND_HOLE_RADIUS,
    GROUND_HOLE_SPACING,
    RO_INPUT_CAPACITOR,
    XSTY
)
```

We also define routing parameters; we'll omit their definitions here because we'll discuss them in more detail below:

```julia
# params.jl
routing = (; # named tuple with variable names as keys
    S45_LOOSE,
    S90_TIGHT,
    CONTROL_ROUTE_RULE,
    READOUT_ROUTE_RULE,
    LINE_SPECIFICATIONS,
    READOUT_GROUPS,
    RO_WAYPOINTS,
    RO_MEANDER_PARAMS
)
```

Finally, the `qpu_params` method returns a nested `NamedTuple` containing our parameters:

```julia
# params.jl
# Return nested NamedTuple of parameters organized by type
return (; transmons, readout, device, routing)
```

## Assembling the schematic graph

Next, we define an abstract representation of our device as a graph ([`SchematicGraph`](@ref SchematicDrivenLayout.SchematicGraph)), with nodes representing instances of components and edges representing connections between them. This is done in the `assemble_schematic_graph!` method in the script.

```julia
p = qpu_params()
g = SchematicGraph("qpu17_demo")
@time "Assembling schematic graph" nodes = assemble_schematic_graph!(g, p)
```

This method also returns the nodes we created, organized by component type. We could always retrieve them from the graph `g`, but this is a bit more convenient if we want to do something with them later.

### Defining components

Here's how we define our main components, in `assemble_schematic_graph!`. The `@component` macro conveniently lets us define arrays of components based on our parameter arrays from above:

```julia
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
```

### Connecting components

Next, we add components to the graph and connect them using [`add_node!`](@ref SchematicDrivenLayout.add_node!) and [`fuse!`](@ref SchematicDrivenLayout.fuse!):

```julia
# Continuing `assemble_schematic_graph!`
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
@. readout_nodes[ACTIVE_SITES] =
    fuse!(g, q_nodes[ACTIVE_SITES] => :readout, readout[ACTIVE_SITES] => :qubit)
```

### Defining routes

We complete the schematic graph by defining routes:

```julia
# ... continuing `assemble_schematic_graph!`
### Routing
route_nodes = add_routes!(g, port_nodes, q_nodes, readout_nodes, p)
### Return nodes organized as a NamedTuple for later convenience
return (; chip, port_nodes, q_nodes, readout_nodes, route_nodes)
```

[Routes](../schematicdriven/schematics.md#Routing) in DeviceLayout.jl are flexible elements used to create paths without having to know ahead of time exactly what the path looks like. We use the following rules for routing:

```julia
# params.jl
## Route rules
S45_LOOSE = Paths.StraightAnd45(min_bend_radius=50μm)  # No max radius, use all available space
S90_TIGHT = Paths.StraightAnd90(min_bend_radius=50μm, max_bend_radius=50μm)
CONTROL_ROUTE_RULE = S45_LOOSE
READOUT_ROUTE_RULE = S90_TIGHT
```

#### Control lines

We define the ports as well as waypoints for control routing in the `LINE_SPECIFICATIONS` parameter:

```julia
# params.jl
## Control and readout line specs in order of port number
LINE_SPECIFICATIONS = [# Manual port assignment, we'll just list them out
    # ("type of line", (row, col), [routing waypoints]),
    # Clockwise from the top edge, NW corner
    ("Z", (2, 2), [Point(-3600, 3800)]μm),
    ("XY", (1, 2), [Point(-4100, 4900)]μm),
    ("RO_OUT", 1, []), # RO routing waypoints are handled separately
    ("Z", (1, 2), []),
    ("Z", (3, 3), [Point(-1200, 5000), Point(-900, 2500), Point(-800, 1200)]μm),
    nothing, # Unused port
    ("Z", (1, 3), []),
    ("RO_OUT", 2, []),
    ("XY", (1, 3), [Point(2400, 4900)]μm),
    ("Z", (2, 3), [Point(2250, 4400)]μm),
    ("XY", (2, 3), [Point(2900, 3700)]μm),
    ("Z", (2, 4), []),
    # NE corner
    ("XY", (2, 4), []),
    ("Z", (2, 5), []),
    ("RO_IN", 2, []),
    ("XY", (2, 5), []),
    nothing,
    nothing,
    ("XY", (3, 5), []),
    ("RO_IN", 3, []),
    ("Z", (3, 5), [Point(5000, -1800)]μm),
    ("XY", (3, 4), [Point(4600, -2300)]μm),
    ("Z", (3, 4), [Point(4600, -3000)]μm),
    ("XY", (4, 4), [Point(3300, -2100)]μm),
    # SE corner
    ("Z", (4, 4), [Point(4100, -4200)]μm),
    ("XY", (5, 4), [Point(4100, -4600)]μm),
    ("RO_OUT", 3, []),
    ("Z", (5, 4), []),
    nothing,
    nothing,
    ("Z", (5, 3), []),
    ("RO_OUT", 4, []),
    ("XY", (5, 3), [Point(-2400, -4600)]μm),
    ("Z", (4, 3), []),
    ("XY", (4, 3), [Point(-3300, -4100)]μm),
    ("Z", (4, 2), []),
    # SW corner
    ("XY", (4, 2), []),
    ("Z", (4, 1), []),
    ("RO_IN", 4, []),
    ("XY", (4, 1), []),
    nothing,
    ("XY", (3, 3), [Point(-1000, -200)]μm),
    ("XY", (3, 1), []),
    ("RO_IN", 1, []),
    ("Z", (3, 1), [Point(-5300, 2100)]μm),
    ("XY", (3, 2), [Point(-5150, 2250), Point(-4175, 1375)]μm),
    ("Z", (3, 2), [Point(-3375, 1800)]μm),
    ("XY", (2, 2), [Point(-2560, 1900)]μm)
]
```

The control lines use `StraightAnd45` routing with no maximum bend radius. Each route will be allowed to make a single 45-degree turn before each waypoint and up to two turns before its endpoint.

Creating the routes then looks like this, [in `routing.jl`](https://github.com/aws-cqc/DeviceLayout.jl/blob/main/examples/DemoQPU17/routing.jl), where we [`route!`](@ref route!(::SchematicDrivenLayout.SchematicGraph, ::Paths.RouteRule, ::Pair{SchematicDrivenLayout.ComponentNode, Symbol}, ::Pair{SchematicDrivenLayout.ComponentNode, Symbol}, ::Any, ::Any)) from each control port to the appropriate hook on the qubit at its target site, passing through any waypoints provided:

```julia
# routing.jl
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
```

#### Readout lines

Next, we define the readout routes. There are four readout lines, and we specify the sites on each line in the parameter `READOUT_GROUPS`:

```julia
# params.jl
READOUT_GROUPS = [ # Which sites are on which line?
    [(3, 1), (3, 2), (3, 3), (2, 2), (1, 2)], # readout line 1
    [(2, 5), (2, 4), (2, 3), (1, 3)], # readout line 2
    [(3, 5), (3, 4), (4, 4), (5, 4)], # readout line 3
    [(4, 1), (4, 2), (4, 3), (5, 3)] # readout line 4
]
```

We use global routing waypoints in `RO_WAYPOINTS` to control the overall path of each leg:

```julia
# params.jl
RO_WAYPOINTS = [
    [ # Group 1
        [], # RO_IN_1 to (3, 1)
        [Point(-4900, 2300)]μm, # (3, 1) to (3, 2)
        [Point(-3100, 1700)]μm, # (3, 2) to (3, 3)
        [Point(-3220, 2400)]μm, # (3, 3) to (2, 2)
        [], # (2, 2) to (1, 2)
        [] # (1, 2) to RO_OUT_1
    ],
    # Group 2
    [[], [Point(5000, 4300)]μm, [Point(3050, 4050)]μm, [Point(1900, 3800)]μm, []],
    # Group 3
    [[], [Point(4800, -2300)]μm, [Point(3600, -2700)]μm, [Point(3600, -4400)]μm, []],
    # Group 4
    [[], [Point(-5000, -4300)]μm, [Point(-3050, -4050)]μm, [Point(-1900, -4500)]μm, []]
]
```

We also use a utility function defined for this script (`meander_waypoints`) to add meanders to different sections of the readout line, based on a specification that defines the additional length required and the space available for meandering, stored in `RO_MEANDER_PARAMS`:

```julia
# params.jl
RO_MEANDER_PARAMS = [
    [ # Group 1
        (;),
        (; addlength=4.57mm, dir=-45°, dx=1000μm, dy=520μm), # (3, 1) to (3, 2)
        (;), # (3, 2) to (3, 3)
        (; addlength=3.8mm, dir=135°, dx=1000μm, dy=400μm), # (3, 3) to (2, 2)
        (;) # (2, 2) to (1, 2)
    ],
    # Group 2
    [
        (;),
        (; addlength=4.0mm, dir=-135°, dx=1300μm, dy=-500μm),
        (;),
        (; addlength=4.0mm, dir=45°, dx=1000μm, dy=-400μm)
    ],
    # Group 3
    [(;), (; addlength=3.0mm, dir=135°, dx=1000μm, dy=-400μm), (;), (;)],
    # Group 4
    [
        (;),
        (; addlength=5.15mm, dir=45°, dx=1400μm, dy=-500μm),
        (; addlength=4.8mm, dir=45°, dx=1000μm, dy=-500μm),
        (;)
    ]
]
```

The code that creates the routes then looks like this:

```julia
# routing.jl
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
```

## Floorplanning

So far, we just have an abstract representation of the device as a graph, with nodes representing instances of components and edges representing connections between them. There's no spatial information about the position and orientation of components, and the routes we defined have yet to be resolved into concrete paths.

Placement is taken care of with [`plan`](@ref SchematicDrivenLayout.plan), which produces a [`Schematic`](@ref SchematicDrivenLayout.Schematic) containing both the schematic graph and spatial information:

```julia
#### Floorplanning (place and route)
@time "Floorplanning" schematic = plan(g) # Place components and define routes
```

The first node we added to the graph (`chip`) will be placed at the origin of `schematic`'s coordinate system. `plan` then traverses the graph, placing each node relative to already-placed nodes they are connected to. It's worth noting that our schematic graph has cycles, because we used `fuse!` earlier between every pair of coupled qubits, adding each corresponding edge in the schematic graph. This is fine because the cycles are consistent (it doesn't matter what order `plan` traverses the edges in a cycle); otherwise, `plan` would throw an error.

This also gives our routes starting and ending points and directions, allowing us to resolve them into concrete paths according to the rules and waypoints provided above. For example, we can now calculate the lengths of the readout lines. In this case, we've added meanders to make sure each filter resonator is coupled to a point within a couple millimeters of a voltage antinode for a standing wave at that site's frequency:

```julia
calculate_readout_lengths(nodes.readout_nodes, nodes.route_nodes.readout, p)
```

```
Group 1:
Length at (3, 1): 0.6297279533454594 mm
Length to next halfwave: 7.697840324432319 mm (-0.6297279533454594 mm)
Length at (3, 2): 7.590259963940551 mm
Length to next halfwave: 0.29901524658576395 mm (-7.590259963940551 mm)
Length at (3, 3): 9.16670034525075 mm
Length to next halfwave: 8.468150125337488 mm (-0.3492751099566314 mm)
Length at (2, 2): 15.60581099960854 mm
Length to next halfwave: 0.5991867301211897 mm (-7.503312134743675 mm)
Length at (1, 2): 17.896343010203637 mm
Length to next halfwave: 7.800153389796365 mm (-0.7653454102036357 mm)
Group 2:
Length at (2, 5): 0.3682037711044196 mm
Length to next halfwave: 8.321432692663695 mm (-0.3682037711044196 mm)
Length at (2, 4): 7.058735781699508 mm
Length to next halfwave: 0.9357297649671584 mm (-7.058735781699508 mm)
Length at (2, 3): 9.349267792294606 mm
Length to next halfwave: 7.540448151367366 mm (-0.9044098204636201 mm)
Length at (1, 3): 15.639799802889703 mm
Length to next halfwave: 0.7871841971102953 mm (-7.4263078028897045 mm)
Group 3:
Length at (3, 5): 0.6615492126596462 mm
Length to next halfwave: 7.440949652205219 mm (-0.6615492126596462 mm)
Length at (3, 4): 5.9520812232547335 mm
Length to next halfwave: 1.9371939872715818 mm (-5.9520812232547335 mm)
Length at (4, 4): 8.242613233849829 mm
Length to next halfwave: 0.08495504392794799 mm (-8.242613233849829 mm)
Length at (5, 4): 10.533145244444926 mm
Length to next halfwave: 6.597852355555074 mm (-1.9676464444449264 mm)
Group 4:
Length at (4, 1): 0.36820377110442065 mm
Length to next halfwave: 8.321432692663695 mm (-0.36820377110442065 mm)
Length at (4, 2): 8.208735781699511 mm
Length to next halfwave: 0.0047562183004887775 mm (-8.208735781699511 mm)
Length at (4, 3): 15.299267792294614 mm
Length to next halfwave: 0.6896633010387179 mm (-7.304802245627949 mm)
Length at (5, 3): 17.58979980288971 mm
Length to next halfwave: 7.744774112603247 mm (-0.7000838592277392 mm)
```

## Schematic design rule checking

Before going further, we run `check!` to make sure the schematic follows any desired rules. Here, we only use the default `rotations_valid` rule, which checks that any components that must be oriented in certain ways are oriented correctly. You can define other rules as part of your PDK and use the `rules` keyword argument in `check!` to run those checks.

```julia
@time "Schematic design rule checking" check!(schematic) # Make sure schematic follows any relevant rules
```

In this case, the only components to check are the [`ExampleSimpleSQUID`](examplepdk.md#SimpleJunctions) subcomponents of our transmons, which must be oriented so that junction leads run north to south. This is enabled by defining `check_rotation` and `allowed_rotation_angles` methods for that component.

## Finishing touches

### Crossovers

Our routing has control lines that intersect with readout lines. One way to handle a route crossing would be to define a crossover component, place it at fixed location on the chip, then route your lines to the crossover. We also have control lines that intersect transmon couplers, as well as a readout resonator that crosses a coupler. This is a little trickier but could be handled in a similar way.

Instead, we'll use DeviceLayout.jl's [automatic crossover generation](../schematicdriven/schematics.md#Automatic-crossover-generation) to make these paths hop over one another without having to know in advance exactly where the crossings occur. Any `Path` or `RouteComponent` that intersects another—including those nested within composite components, like transmon coupler paths or resonator sections—can be used with this functionality.

We use the simple built-in [`AirBridge` crossover style](../paths.md#Intersections), with parameters set in `params.jl`:

```julia
# params.jl
# Crossover style (simple scaffolded bridge, not optimized for microwave properties)
XSTY = Intersect.AirBridge(
    crossing_gap=5μm,
    foot_gap=3μm,
    foot_length=10μm,
    extent_gap=3μm,
    scaffold_gap=3μm,
    scaffold_meta=LayerVocabulary.BRIDGE_BASE,
    air_bridge_meta=LayerVocabulary.BRIDGE
)
```

We then call `crossovers!`:

```julia
@time "Generating crossovers" SchematicDrivenLayout.crossovers!(schematic, XSTY)
```

This call checks all segment pairs for intersections, which can be slow in large devices. If you know which component nodes cross, you can feed only those to `crossovers!` to save time. (That can also  give you finer-grained control over which lines hop over which—by default, routes hop over explicit paths, and components added to the schematic graph later will cross over those added earlier.)

### Air bridges

We often want to place bridges over coplanar waveguides to connect the ground planes on either side of the signal trace. In this case, we use a simple utility function defined in `ExamplePDK` to place a bridge in the center of every `Path` segment.

```@docs
SchematicDrivenLayout.ExamplePDK.add_bridges!
```

### Ground-plane hole autofill

Many quantum devices fill the ground plane with small holes to reduce loss associated with magnetic vortices. We make a coordinate system holding a single hole, generate an exclusion zone around components using [`halo`](@ref), and use [`autofill!`](@ref) to place holes on grid points outside the exclusion zone.

```julia
#### Autofill with ground plane holes
hole_cs = CoordinateSystem("gnd_hole") # Coordinate system for a single hole
place!(hole_cs, not_simulated(Circle(GROUND_HOLE_RADIUS)), METAL_NEGATIVE)
bnds = bounds(schematic, find_components(ExampleChip, schematic)...) # bounds of the chip node
exclusion = make_halo(50μm; ignore_layers=[CHIP_AREA, WRITEABLE_AREA]) # function to create exclusion area
x_grid = (lowerleft(bnds).x + 600μm):GROUND_HOLE_SPACING:(upperright(bnds).x - 600μm) # raster x-coordinates
y_grid = (lowerleft(bnds).y + 600μm):GROUND_HOLE_SPACING:(upperright(bnds).y - 600μm) # raster y-coordinates
@time "Ground-plane hole fill" autofill!(schematic, hole_cs, x_grid, y_grid, exclusion)
```

## Rendering

We now have the final device in a "DeviceLayout.jl-native" representation, but we need to output a GDSII file. To do this, we `render!` the `schematic` to a [`Cell`](../coordinate_systems.md#Cells), which draws all shapes as `Polygon`s and maps our named layers (`SemanticMeta`) to GDS layer and datatype (`GDSMeta`). The rendering settings (including the layer mapping) are provided by `DemoQPU17.L1_TARGET`.

```julia
#### Render results to Cell for GDS export
# Equivalent one-liner to the below: artwork = Cell(schematic, L1_TARGET)
artwork = Cell("qpu17_demo") # "artwork" = "pattern used for fabrication"
@time "Rendering to polygons" render!(artwork, schematic, L1_TARGET)
```

Because our design includes some components rotated at 45 degree angles, we have to flatten the `Cell` before saving to avoid 1nm gaps in the result. To keep the file from getting too big, we specify `max_copy=100`. That is, any `Cell` that gets referenced more than 100 times (including the `Cell` containing the ground-plane hole and those containing bridges) will not have its contents copied to the top level that many times, but instead remains stored as a `Cell` with repeated references.

```julia
# Flatten to avoid 1nm gaps from rounded Cell origins + non-Manhattan rotations
# But don't flatten references with more than 100 copies, we'd end up with 10k hole polygons
@time "Flattening cells" flatten!(artwork, max_copy=100)
savegds && @time "Saving" save("qpu17_demo.gds", artwork)
```

And now we're done!

### Aside: Rendering flipchip devices

The "L1" in our `L1_TARGET` holding the rendering settings stands for "Level 1", referring to the usual chip surface in a single-chip device. If this were a flipchip device, we could render each level separately:

```julia
l1_artwork = Cell("demo_L1_artwork")
l2_overlay = Cell("demo_L2_overlay")
l2_artwork = Cell("demo_L2_artwork")

render!(l1_artwork, schematic, L1_TARGET)
render!(l2_overlay, schematic, L2_TARGET)
# L2 needs to be mirrored to get the artwork for fabrication
addref!(l2_artwork, l2_overlay, xrefl=true)
```

We can also render the assembly for visualization. We could just write `assembly = Cell("assembly"); addref!(assembly, l1_artwork); addref!(assembly, l2_overlay)`, but we'd end up with duplicate `Cell` names—for each `Cell` in the hierarchy, there's now a version with L1 polygons and one with L2 polygons—which the GDSII format doesn't like. Also, if the L1 and L2 chips share a technology, then the GDS won't distinguish levels—the same semantic layers on either chip will be mapped to the same GDS layers. Instead, we'll want to render everything again with the assembly target from the example PDK, which automatically adds `300` to the layer number of L2 polygons:

```julia
assembly = Cell(schematic, ASSEMBLY_TARGET)
```

This duplicates some work if we already rendered L1 and L2 separately, but it's fast enough that we don't really care.

### Another aside: Debugging

Sometimes a schematic's connectivity makes `plan` infeasible, a component's geometry contains an error, or a route turns out to be infeasible given the waypoints and routing rule you provided. Error messages and stack traces will tell you exactly what failed, but are often too granular to easily make sense of without a visual aid.

To help with debugging, you can run `plan` and `render!` with the keyword `strict=:no`. This logs the error, skips the problematic component, and continues on planning or rendering, so that you can inspect the partial result to see what failed.
