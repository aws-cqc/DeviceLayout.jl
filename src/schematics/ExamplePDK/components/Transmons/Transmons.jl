"""
    module Transmons

An `ExamplePDK` component module containing simple transmons and associated elements like
static couplers and control lines.

`ExamplePDK` is intended for demonstrations, tutorials, and tests. While we aim to
demonstrate best practices for Julia code and DeviceLayout.jl usage, these components are not
optimized for device performance. Most importantly: **Breaking changes to `ExamplePDK` may
occur within major versions.** In other words, don't depend on `ExamplePDK` in your own PDK
or for real devices!
"""
module Transmons

using DeviceLayout, DeviceLayout.SchematicDrivenLayout, DeviceLayout.PreferredUnits
using .SchematicDrivenLayout.ExamplePDK, .ExamplePDK.LayerVocabulary

import Unitful: uconvert, NoUnits

import .ExamplePDK: add_bridges!
import .ExamplePDK.SimpleJunctions: ExampleSimpleSQUID, ExampleSimpleJunction
export ExampleStarTransmon, ExampleRectangleTransmon

include("star_island.jl")
include("control_lines.jl")

"""
    ExampleStarTransmon <: CompositeComponent

Example transmon component with five capacitive couplers and control lines.

The transmon island is a five-pointed star ⋆ with truncated tips.
A Josephson junction subcomponent connects the top of the star (in the default orientation)
to ground. Five wedge-shaped capacitive coupling pads fill the gaps between star arms. Four
of them extend in the cardinal directions to half of the `lattice_spacing` from the island's
center, while the other extends at an angle to couple to a readout resonator. XY and Z
control line terminations are also included.

This component is intended for use in demonstrations.

# Parameters

  - `name = "transmon"`: Name of component
  - `island_outer_radius = 135μm`: Radius of island at the tips of the star
  - `island_inner_radius = [80, 80, 80, 80, 80]μm`: Radii of island between the tips of stars,
    clockwise from 12 o'clock  (smaller radius produces a larger coupler pad at that location;
    index `5` is the coupler to the readout resonator)
  - `island_ground_gap = 15μm`: Gap between island (tips of star) and ground
  - `island_coupler_gap = 15μm`: Gap between island and couplers
  - `star_tip_width = 50μm`: Width of star tips
  - `rounding = 5μm`: Rounding applied to ground plane geometry
  - `jj_template = ExampleSimpleSQUID()`: Template to generate JJ or SQUID,
    where `name` and `h_ground_island` will be overridden
  - `lattice_spacing = 1.65mm`: Spacing between transmons (determines coupler length)
  - `right_handed = true`: If `false`, is reflected when attached to right-handed transmons
  - `coupler_style = Paths.CPW(10μm, 10μm)`: `Path` style for couplers
  - `resonator_style = Paths.CPW(10μm, 10μm)`: `Path` style for readout resonator (coupler index `5`
    includes a taper from `coupler_style` to `resonator_style`)
  - `grounded_couplers = Int[]`: List of grounded coupler indices (1 to 5, clockwise from 12 o'clock)
  - `coupler_bridge = nothing`: `CoordinateSystem` holding a bridge to place over couplers
  - `feedline_style = Paths.CPW(10μm, 6μm)`: XY/Z control feedline style (before taper)
  - `xy_length = 100μm`: Straight length of XY line before termination
  - `xy_style = Paths.CPW(3.3μm, 2μm)`: XY control line style after taper (near the qubit)
  - `xy_distance = 50μm`: Distance from XY termination to ground plane edge near qubit
  - `z_length = 100μm`: Straight length of Z line before termination
  - `z_style = Paths.CPW(3.3μm, 2μm)`: Style of the Z line after taper (near the qubit)
  - `z_cut_offset = 0μm`: Offset of z cut relative to SQUID axis of symmetry
  - `z_cut_length = 16μm`: Length of cut defining a return current path shared by the SQUID loop
  - `z_distance = 2μm`: Distance from edge of ground plane cut to qubit
  - `control_bridge = nothing`: `CoordinateSystem` holding a bridge to place over control lines

# Hooks

  - `origin`: Center of transmon island, with inward direction pointing right
  - `readout`: Readout coupler
  - `coupler_{N,E,S,W}`: North/South/East/West (in transmon coordinate system)
  - `xy`: End of XY line to be connected to control feedline
  - `z`: End of Z line to be connected to control feedline

# Subcomponents

 1. `island::ExampleStarIsland`
 2. `junction::typeof(jj_template)`
 3. `readout_coupler::Path`
 4. `coupler_1::Path` (N in transmon coordinate system)
 5. `coupler_2::Path` (E)
 6. `coupler_3::Path` (S)
 7. `coupler_4::Path` (W)
 8. `xy::ExampleXYTermination`
 9. `z::ExampleZTermination`
"""
@compdef struct ExampleStarTransmon <: CompositeComponent
    name = "transmon"
    island_outer_radius = 135μm
    island_inner_radius = [80, 80, 80, 80, 80]μm
    island_ground_gap = 15μm
    island_coupler_gap = 15μm
    star_tip_width = 50μm
    rounding = 5μm
    jj_template = ExampleSimpleSQUID()
    lattice_spacing = 1.65mm
    right_handed = true
    coupler_style = Paths.CPW(10μm, 10μm)
    resonator_style = Paths.CPW(10μm, 10μm)
    grounded_couplers = Int[]
    coupler_bridge = nothing
    feedline_style = Paths.CPW(10μm, 6μm)
    xy_length = 100μm
    xy_style = Paths.CPW(3.3μm, 2μm)
    xy_distance = 50μm
    z_length = 100μm
    z_style = Paths.CPW(3.3μm, 2μm)
    z_cut_offset = 0μm
    z_cut_length = 16μm
    z_distance = 2μm
    control_bridge = nothing
end

function SchematicDrivenLayout._build_subcomponents(tr::ExampleStarTransmon)
    island_params = filter_parameters(ExampleStarIsland, tr)
    @component island = ExampleStarIsland(; island_params...)
    @component junction = tr.jj_template begin
        h_ground_island = tr.island_ground_gap
    end
    # Coupler subcomponents are Paths
    couplers = coupler_paths(tr, island)
    readout_coupler = Path(nm; name="readout_coupler", metadata=METAL_NEGATIVE)
    straight!(readout_coupler, 50μm, Paths.TaperCPW(tr.coupler_style, tr.resonator_style))
    !isnothing(tr.coupler_bridge) && attach!(readout_coupler, sref(tr.coupler_bridge), 25μm)
    turn!(readout_coupler, π / 4 - π / 5, 50μm, tr.resonator_style)
    @component xy = ExampleXYTermination(; filter_parameters(ExampleXYTermination, tr)...) begin
        bridge = tr.control_bridge
    end
    @component z = ExampleZTermination(; filter_parameters(ExampleZTermination, tr)...) begin
        bridge = tr.control_bridge
    end
    return (island, junction, readout_coupler, couplers..., xy, z)
end

function SchematicDrivenLayout._graph!(
    g::SchematicGraph,
    comp::ExampleStarTransmon,
    subcomps::NamedTuple
)
    island_node = add_node!(g, subcomps.island)
    fuse!(g, island_node => :junction, subcomps.junction => :island)
    fuse!(g, island_node => :coupler_5, subcomps.readout_coupler => :p0)
    for idx = 1:4
        coupler_sym = Symbol("coupler_$idx")
        path = getproperty(subcomps, coupler_sym)
        # For simplicity we always make all the paths, but empty them if not used
        idx in comp.grounded_couplers && empty!(path)
        fuse!(g, island_node => coupler_sym, path => :p0)
    end
    fuse!(g, island_node => :xy, subcomps.xy => :qubit)
    return fuse!(g, island_node => :z, subcomps.z => :qubit)
end

function SchematicDrivenLayout.map_hooks(tr::ExampleStarTransmon)
    ###### Dictionary mapping (graph node index => subcomp hook name) => MyComp hook name
    path_hook = tr.right_handed ? :p1 : :p1_lh
    return Dict(
        (1 => :origin) => :origin,
        (3 => :p1) => :readout,
        (4 => path_hook) => :coupler_N,
        (5 => path_hook) => :coupler_E,
        (6 => path_hook) => :coupler_S,
        (7 => path_hook) => :coupler_W,
        (8 => :line) => :xy,
        (9 => :line) => :z
    )
end
###

function coupler_paths(tr::ExampleStarTransmon, isl::ExampleStarIsland)
    (; coupler_style, lattice_spacing) = tr
    h0s = hooks(isl).coupler[1:4] # Starting hooks for paths (clockwise from 12 o'clock)
    h_N = PointHook(0μm, lattice_spacing / 2, -90°)
    h1s = [h_N, RotationPi(-1 // 2)(h_N), RotationPi()(h_N), RotationPi(1 // 2)(h_N)]
    paths = typeof(Path(nm))[]
    for (idx, h_start, h_end) in zip(eachindex(h0s), h0s, h1s)
        α_start = out_direction(h_start)
        α_end = out_direction(h_end)
        path = path_out(h_start)
        path.name = "coupler_$idx"
        path.metadata = METAL_NEGATIVE
        straight!(path, 50μm, coupler_style)
        add_bridges!(path, tr.coupler_bridge)
        # Turn to get correct orientation
        α = rem(α_end - α_start, 360°, RoundNearest)
        !(iszero(α)) && turn!(path, α, 50μm)
        # Snake to get to correct position
        # If unreachable, reduce above straight length and/or decrease assumed_coupler_extent
        route!(path, h_end.p, α_end, Paths.StraightAnd45(min_bend_radius=50μm))
        push!(paths, path)
    end
    return paths
end

"""
    struct ExampleRectangleTransmon <: CompositeComponent
    ExampleRectangleTransmon(base_parameters::NamedTuple=default_parameters(ExampleRectangleTransmon);
        kwargs...)

Transmon component with a rectangular island acting as a shunt capacitor across a junction or SQUID.

# Parameters

  - `name = "island"`: Name of component
  - `jj_template = ExampleSimpleJunction()`: Template to generate JJ or SQUID,
    where `name` and `h_ground_island` will be overridden
  - `cap_width = 24μm`: The width of the rectangular island
  - `cap_length = 520μm`: The length of the rectangular island
  - `cap_gap = 30μm`: The gap surrounding the rectangular island, except the side with the junction/SQUID
  - `junction_gap = 12μm`: The gap on the side of the island where the junction/SQUID will go
  - `junction_pos = :bottom`: Location to place junction/SQUID (options `:top` or `:bottom`)
  - `island_rounding = 0µm`: Optional rounding radius to apply to the island; if zero, no
    rounding is applied to the island

# Hooks

  - `readout`: The center edge of the ground plane on the opposite side of the island from the SQUID.
  - `xy`: The left side of the capacitor gap.
  - `z`: The center edge of the ground plane in the SQUID loop.

# Subcomponents

 1. `island::ExampleRectangleIsland`
 2. `junction::typeof(jj_template)`
"""
@compdef struct ExampleRectangleTransmon <: CompositeComponent
    name = "tr"
    jj_template = ExampleSimpleJunction()
    cap_width = 24μm
    cap_length = 520μm
    cap_gap = 30μm
    junction_gap = 12.0μm
    junction_pos = :bottom
    island_rounding = 0µm
end

island(tr::ExampleRectangleTransmon) = component(tr[1])

function SchematicDrivenLayout._build_subcomponents(tr::ExampleRectangleTransmon)
    island_params = filter_parameters(ExampleRectangleIsland, tr)
    @component island = ExampleRectangleIsland(; island_params...)

    @component junction = tr.jj_template begin
        h_ground_island = tr.junction_gap
    end

    return (island, junction)
end

function SchematicDrivenLayout._graph!(
    g::SchematicGraph,
    comp::ExampleRectangleTransmon,
    subcomps::NamedTuple
)
    island_node = add_node!(g, subcomps.island)
    return fuse!(g, island_node => :junction, subcomps.junction => :island)
end

function SchematicDrivenLayout.map_hooks(::Type{ExampleRectangleTransmon})
    return Dict((1 => :readout) => :readout, (1 => :xy) => :xy, (1 => :z) => :z)
end

check_rotation(::ExampleRectangleTransmon) = true
allowed_rotation_angles(::ExampleRectangleTransmon) = [0]

"""
    ExampleRectangleIsland <: Component

Example transmon capacitor consisting of a rectangle.

The transmon island is a rectangle with surrounding gap and optional rounding.

# Parameters

Note that when this component is created within an `ExampleRectangleTransmon`, these defaults are
overwritten.

  - `name = "island"`: Name of component
  - `cap_width = 24μm`: The width of the rectangular island
  - `cap_length = 520μm`: The length of the rectangular island
  - `cap_gap = 30μm`: The gap surrounding the rectangular island, except the side with the junction/SQUID
  - `junction_gap = 12μm`: The gap on the side of the island where the junction/SQUID will go
  - `junction_pos = :bottom`: Location to place junction/SQUID (options `:top` or `:bottom`)
  - `island_rounding = 0µm`: Optional rounding radius to apply to the island; if zero, no
    rounding is applied to the island

# Hooks

  - `junction`: Attachment point where junction leads meet the island
  - `readout`: Claw attachment point for the readout resonator, opposite the `junction_pos`.
  - `xy`: Attachment point for the XY line (left side, midpoint of island)
  - `z`: Attachment point for the Z line
"""
@compdef struct ExampleRectangleIsland <: Component
    name = "island"
    cap_width = 24μm
    cap_length = 520μm
    cap_gap = 30μm
    junction_gap = 12μm
    junction_pos = :bottom
    island_rounding = 0µm
end

function SchematicDrivenLayout.hooks(r::ExampleRectangleIsland)
    (; junction_gap, junction_pos, cap_width, cap_length, cap_gap) = r

    cutout_height = junction_gap + cap_length + cap_gap
    sgn = junction_pos == :bottom ? 1 : -1
    junction = PointHook(Point(0μm, sgn * junction_gap), sgn * 90°) # junction lead meets island
    readout = PointHook(Point(0μm, sgn * cutout_height), sgn * -90°) # top of cap gap
    xy = PointHook(
        Point(-cap_gap - cap_width / 2, sgn * cutout_height / 3), # left side of capacitor gap
        0°
    )
    z = PointHook(Point(0μm, 0μm), sgn * 90°) # Center of ground edge of SQUID

    return (; junction, readout, xy, z)
end

function SchematicDrivenLayout._geometry!(cs::CoordinateSystem, r::ExampleRectangleIsland)
    (; junction_gap, junction_pos, cap_width, cap_length, cap_gap, island_rounding) = r
    sgn = junction_pos == :bottom ? 1 : -1
    r1 = Rectangle(
        Point(-cap_width / 2, sgn * junction_gap),
        Point(cap_width / 2, sgn * (junction_gap + cap_length))
    )
    r2 = Rectangle(
        Point(-cap_width / 2 - cap_gap, zero(cap_gap)),
        Point(cap_width / 2 + cap_gap, sgn * (junction_gap + cap_length + cap_gap))
    )
    diff = Rounded(island_rounding)(difference2d(r2, r1))

    return render!(cs, meshsized_entity(diff, 2 * min(cap_width, cap_gap)), METAL_NEGATIVE)
end

end # module
