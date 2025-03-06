"""
    struct ProcessTechnology
        layer_record::NamedTuple
        parameters::NamedTuple
    end

Specifies process-specific parameters and mapping of semantic layers (e.g., to GDS layers).

The interface for process parameters includes the functions [`layer_thickness`](@ref),
[`layer_height`](@ref), [`chip_thicknesses`](@ref), and [`flipchip_gaps`](@ref), which use
the following `parameters` entries if they are defined:

  - `thickness`: A `NamedTuple` associating layer `Symbol`s with a thickness or list of
    thicknesses indexed by level.
  - `height`: A `NamedTuple` associating layer `Symbol`s with "height" or list of heights indexed by level.
    Height is the distance of a layer from the substrate surface at a given level, measured away from the substrate.
  - `chip_thicknesses`: A `Vector` of thicknesses of chips from bottom to top, used for
    calculating the z coordinate of the surface for each level.
  - `flipchip_gaps`: A `Vector` of gaps between chips in a flipchip stack, used with `chip_thicknesses`
    for calculating the z coordinate of the surface for each level.

Note that other tools often have their own related concepts of
a "Technology", but these may not directly correspond to our `ProcessTechnology`.
"""
struct ProcessTechnology
    layer_record::NamedTuple
    parameters::NamedTuple
end
layer_record(tech::ProcessTechnology) = tech.layer_record
parameters(tech::ProcessTechnology) = tech.parameters
Base.merge(t1::ProcessTechnology, t2::ProcessTechnology) = ProcessTechnology(
    merge(t1.layer_record, t2.layer_record),
    merge_recursive(t1.parameters, t2.parameters)
)

"""
    layer_thickness(tech::ProcessTechnology, m::DeviceLayout.Meta)

The thickness of `m` in `tech.parameters.thickness` (0μm if not specified).
"""
function layer_thickness(tech::ProcessTechnology, m::DeviceLayout.Meta)
    lt = get(parameters(tech), :thickness, (;))
    t = get(lt, layer(m), 0μm)
    if !isempty(size(t)) # If t is a list
        # If t has an entry for level(m), return that
        level(m) in eachindex(t) && return t[level(m)]
        return 0μm
    end
    return t
end

"""
    layer_height(tech::ProcessTechnology, m::DeviceLayout.Meta)

The height of `m` in `tech.parameters.height` (0μm if not specified).

Height is measured outward from the substrate surface corresponding to `level(m)`.
"""
function layer_height(tech::ProcessTechnology, m::DeviceLayout.Meta)
    lh = get(parameters(tech), :height, (;))
    h = get(lh, layer(m), 0μm)
    if !isempty(size(h)) # If h is a list
        # If h has an entry for level(m), return that
        level(m) in eachindex(h) && return h[level(m)]
        return 0μm
    end
    return h
end

"""
    chip_thicknesses(tech::ProcessTechnology)

A `Vector` of thicknesses of chips (default [525μm, 525μm]).
"""
chip_thicknesses(tech::ProcessTechnology) =
    get(tech.parameters, :chip_thicknesses, [525μm, 525μm])

"""
    flipchip_gaps(tech::ProcessTechnology)

A `Vector` of flipchip gaps (default [5μm]).
"""
flipchip_gaps(tech::ProcessTechnology) = get(tech.parameters, :flipchip_gaps, [5μm])

"""
    level_z(l::Integer; t_chips=[525μm, 525μm], t_gaps=[5μm])

Return the z position corresponding to level `l`.

Uses the flip-chip level convention (see [facing](@ref SchematicDrivenLayout.facing), [backing](@ref SchematicDrivenLayout.backing)).

# Keywords

  - `t_chips`: A list of chip thicknesses from bottom to top
  - `t_gaps`: A list of gap thicknesses between substrates

`t_gaps` should start at the same index as `t_chips` and have length `length(t_chips) - 1`.
Level 1 is at `z = 0`.
"""
function level_z(l::Integer; t_chips=[525μm, 525μm], t_gaps=[5μm])
    chip_idx = Int(floor(l / 2)) + 1
    # Add up stacks above 1, subtract stacks below 1
    z_chip =
        sum(t_chips[(2):chip_idx]) + sum(t_gaps[1:(chip_idx - 1)]) -
        (sum(t_chips[(chip_idx + 1):1]) + sum(t_gaps[chip_idx:0]))
    if iseven(l)
        return z_chip - t_chips[chip_idx] # even is bottom of substrate
    end
    return z_chip
end

"""
    layer_z(tech::ProcessTechnology, m::DeviceLayout.Meta)

The z position corresponding to metadata `m`.

Uses `chip_thicknesses(tech)` and `flipchip_gaps(tech)` to determine the z coordinate
corresponding to `level(m)`, then adds or subtracts `layer_height(tech, m)` for odd or even
`level(m)`, respectively. (That is, the layer height is measured outward from the substrate
surface using the flipchip level convention.)
"""
function layer_z(tech::ProcessTechnology, m::DeviceLayout.Meta)
    z = level_z(level(m); t_chips=chip_thicknesses(tech), t_gaps=flipchip_gaps(tech))
    sgn = isodd(level(m)) ? 1 : -1

    dz = layer_height(tech, m)

    return z + sgn * dz
end
