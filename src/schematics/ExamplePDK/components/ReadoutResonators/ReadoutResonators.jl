"""
    module ReadoutResonators

An `ExamplePDK` component module containing resonators for transmon readout.

`ExamplePDK` is intended for demonstrations, tutorials, and tests. While we aim to
demonstrate best practices for Julia code and DeviceLayout.jl usage, these components are not
optimized for device performance. Most importantly: **Breaking changes to `ExamplePDK` may
occur within major versions.** In other words, don't depend on `ExamplePDK` in your own PDK
or for real devices!
"""
module ReadoutResonators

using DeviceLayout, DeviceLayout.SchematicDrivenLayout, DeviceLayout.PreferredUnits
using .SchematicDrivenLayout.ExamplePDK, .ExamplePDK.LayerVocabulary

import .ExamplePDK: add_bridges!, tap!
import .ExamplePDK.ClawCapacitors: ExampleShuntClawCapacitor

export ExampleTappedHairpin, ExampleFilteredHairpinReadout, ExampleClawedMeanderReadout

include("tapped_hairpin.jl")
include("clawed_meander.jl")

"""
    ExampleFilteredHairpinReadout <: CompositeComponent

A pair of hairpin meanders to be used together with a transmon for Purcell-filtered readout.

This component is intended for use in demonstrations with `ExampleStarTransmon`.

# Subcomponents

 1. `claw`, an [`ExampleShuntClawCapacitor`](@ref SchematicDrivenLayout.ExamplePDK.ClawCapacitors.ExampleShuntClawCapacitor)
 2. `efp` ("extra filter path"), a `Path` inserted between the claw and Purcell hairpin
 3. `purcell`, an [`ExampleTappedHairpin`](@ref) used for the Purcell filter
 4. `readout`, an [`ExampleTappedHairpin`](@ref) used for the readout resonator

# Parameters

`ExampleFilteredHairpinReadout` mostly passes parameters directly to subcomponents.

  - `name = "readout"`: Name of component

  - Feedline, tap, and claw capacitor (see [`ExampleShuntClawCapacitor`](@ref SchematicDrivenLayout.ExamplePDK.ClawCapacitors.ExampleShuntClawCapacitor))

      + `feedline_length = 300μm`
      + `feedline_style = Paths.CPW(10μm, 6μm)`
      + `feedline_tap_length = 20μm`
      + `feedline_tap_style = Paths.CPW(10μm, 6μm)`
      + `feedline_bridge = nothing`
      + `inner_cap_width = 20μm`
      + `inner_cap_length = 200μm`
      + `claw_inner_gap = 5μm`
      + `claw_trace = 10μm`
      + `claw_outer_gap = 20μm`
      + `rounding = 2μm`
  - Extra claw-to-filter path

      + `extra_filter_length_1 = 300μm`: Initial straight length
      + `extra_filter_angle_1 = 0°`: Bend angle following initial straight
      + `extra_filter_length_2 = 0μm`: Straight length following first bend
      + `extra_filter_angle_2 = 0°`: Second bend following second straight
  - Resonators (see [`ExampleTappedHairpin`](@ref))

      + `resonator_style = Paths.CPW(10μm, 10μm)`
      + `bend_radius = 50μm`
      + `straight_length = 1.5mm # Long straight segment`
      + `filter_total_length = 3mm`: Target physical path length of the Purcell filter hairpin
        (the extra claw-to-filter path length is subtracted from this when building the filter)
      + `readout_total_length = 3mm`: Target physical path length of the readout hairpin
      + `readout_initial_snake = Point(600μm, 200μm)`
  - Parameters for tap and coupling capacitor between resonators

      + `tap_position = 0.77mm`: Position of tap along initial straight segment
      + `tap_side = -1`: Side of hairpin for tap (+1 for right-hand side starting from qubit)
      + `hairpin_tap_depth = 35μm`: Distance from center of hairpin CPW to end of coupling capacitor
      + `hairpin_tap_style = Paths.CPW(5μm, 25μm)`: Style of hairpin tap path
      + `tap_cap_taper_length = 5μm`: Length of taper from `tap_style` to `tap_cap_style`
      + `tap_cap_length = 10μm`: Length of capacitive pad after taper
      + `tap_cap_style = Paths.CPW(25μm, 15μm)`: Width and gap-width of coupling capacitor as a CPW style
      + `tap_cap_termination_gap = 5μm`: Gap between coupling capacitor metal and ground in the direction of coupling
      + `resonator_filter_coupling_gap = 15μm`: Edge-edge gap between filter and readout tap capacitor terminations (should be > 2*termination gap)

# Hooks

    - `p0`: Input of the readout feedline
    - `p1`: Output of the readout feedline    # Feedline and tap
    - `qubit`: End of the readout hairpin that connects galvanically to a capacitive pad in a qubit component
"""
@compdef struct ExampleFilteredHairpinReadout <: CompositeComponent
    name = "readout"
    # Feedline and tap
    feedline_length = 300μm
    feedline_style = Paths.CPW(10μm, 6μm)
    feedline_tap_length = 20μm
    feedline_tap_style = Paths.CPW(10μm, 6μm)
    feedline_bridge = nothing
    # Claw capacitor
    inner_cap_width = 20μm
    inner_cap_length = 200μm
    claw_inner_gap = 5μm
    claw_trace = 10μm
    claw_outer_gap = 20μm
    rounding = 2μm
    # Extra claw-to-filter path
    extra_filter_length_1 = 300μm
    extra_filter_angle_1 = 0°
    extra_filter_length_2 = 0μm
    extra_filter_angle_2 = 0°
    # Resonators
    resonator_style = Paths.CPW(10μm, 10μm)
    bend_radius = 50μm
    straight_length = 1.5mm # Long straight segment
    resonator_bridge = nothing
    # Filter-specific parameters
    filter_total_length = 3mm
    # Resonator-specific parameters
    readout_total_length = 3mm
    readout_initial_snake = Point(600μm, 200μm)
    # Parameters for tap and coupling capacitor between resonators
    tap_position = 0.77mm
    tap_side = -1 # +1 for right hand side starting from open end
    hairpin_tap_depth = 35μm
    hairpin_tap_style = Paths.CPW(5μm, 25μm)
    tap_cap_taper_length = 5μm
    tap_cap_length = 10μm
    tap_cap_style = Paths.CPW(25μm, 15μm)
    tap_cap_termination_gap = 5μm
    resonator_filter_coupling_gap = 15μm # should be > 2*termination gap
end

function SchematicDrivenLayout._build_subcomponents(fr::ExampleFilteredHairpinReadout)
    ### Claw
    claw_params = filter_parameters(ExampleShuntClawCapacitor, fr) # Params shared by claw
    @component claw = ExampleShuntClawCapacitor(; claw_params...) begin
        # Params with different names in `fr` and `claw`
        input_length = fr.feedline_tap_length
        input_style = fr.feedline_tap_style
        output_style = fr.resonator_style
        bridge = fr.feedline_bridge
    end

    ### Extra filter path
    efp = Path(; name="efp", metadata=METAL_NEGATIVE)
    !iszero(fr.extra_filter_length_1) &&
        straight!(efp, fr.extra_filter_length_1, fr.resonator_style)
    !iszero(fr.extra_filter_angle_1) &&
        turn!(efp, fr.extra_filter_angle_1, fr.bend_radius, fr.resonator_style)
    !iszero(fr.extra_filter_length_2) &&
        straight!(efp, fr.extra_filter_length_2, fr.resonator_style)
    !iszero(fr.extra_filter_angle_2) &&
        turn!(efp, fr.extra_filter_angle_2, fr.bend_radius, fr.resonator_style)
    add_bridges!(efp, fr.resonator_bridge)
    extra_path_length = pathlength(efp) # Counts toward the filter's total physical length

    ### Hairpins
    hairpin_params = filter_parameters(ExampleTappedHairpin, fr) # Params shared by hairpin
    @component purcell = ExampleTappedHairpin(; hairpin_params...) begin
        # Params with different names / reparameterization (resonator_style, bend_radius,
        # straight_length, tap_position, tap_side are forwarded by name via hairpin_params)
        # The extra claw-to-filter path is part of the filter's length, so subtract it from
        # the target so the filter meander makes up the remainder.
        total_length = fr.filter_total_length - extra_path_length
        tap_style = fr.hairpin_tap_style # Would have same name but claw also has tap_style
        tap_depth = fr.hairpin_tap_depth
        tap_cap_coupling_distance = fr.resonator_filter_coupling_gap / 2
        bridge = fr.resonator_bridge
    end

    @component readout = ExampleTappedHairpin(; hairpin_params...) begin
        # Params with different names / reparameterization
        total_length = fr.readout_total_length
        tap_style = fr.hairpin_tap_style
        tap_depth = fr.hairpin_tap_depth
        tap_cap_coupling_distance = fr.resonator_filter_coupling_gap / 2
        initial_snake = fr.readout_initial_snake
        bridge = fr.resonator_bridge
    end

    return (claw, efp, purcell, readout)
end

function SchematicDrivenLayout._graph!(
    g::SchematicGraph,
    comp::ExampleFilteredHairpinReadout,
    subcomps::NamedTuple
)
    claw_node = add_node!(g, subcomps.claw)
    extra_node = fuse!(g, claw_node => :p2, subcomps.efp => :p0)
    filter_node = fuse!(g, extra_node => :p1, subcomps.purcell => :p0)
    return fuse!(g, filter_node => :tap, subcomps.readout => :tap)
end

# Graph node indices, in the order subcomponents are returned by `_build_subcomponents`
# (and added in `_graph!`). Centralizing the index↔subcomponent mapping keeps `map_hooks`
# from hardcoding bare integers that must track the build order by hand.
const _FILTERED_HAIRPIN_NODES = (claw=1, efp=2, purcell=3, readout=4)

function SchematicDrivenLayout.map_hooks(tr::ExampleFilteredHairpinReadout)
    ###### Dictionary mapping (graph node index => subcomp hook name) => MyComp hook name
    n = _FILTERED_HAIRPIN_NODES
    return Dict(
        (n.claw => :p0) => :p0,
        (n.claw => :p1) => :p1,
        (n.readout => :p0) => :qubit
    )
end
###

end # module
