function qpu_params()
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
    island_inner_radius =
        ifelse.(DATA_QUBIT, Ref(data_inner_radius), Ref(ancilla_inner_radius))

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

    ### Routing
    ## Route rules
    S45_LOOSE = Paths.StraightAnd45(min_bend_radius=50μm)  # No max radius, use all available space
    S90_TIGHT = Paths.StraightAnd90(min_bend_radius=50μm, max_bend_radius=50μm)
    CONTROL_ROUTE_RULE = S45_LOOSE
    READOUT_ROUTE_RULE = S90_TIGHT

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

    ## Readout routing
    READOUT_GROUPS = [ # Which sites are on which line?
        [(3, 1), (3, 2), (3, 3), (2, 2), (1, 2)], # readout line 1
        [(2, 5), (2, 4), (2, 3), (1, 3)], # readout line 2
        [(3, 5), (3, 4), (4, 4), (5, 4)], # readout line 3
        [(4, 1), (4, 2), (4, 3), (5, 3)] # readout line 4
    ]
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

    # Return nested NamedTuple of parameters organized by type
    return (; transmons, readout, device, routing)
end
