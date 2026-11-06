# [Design Velocities and Mesh Morphing](@id concept-design-velocities)

Simulation-driven design adjusts a component's parameters until the simulated device meets
its targets, for example a qubit's frequency or a coupler's capacitance. Each change to the
parameters normally means rendering, meshing and simulating again. Two tools in
[`SolidModels`](@ref api-solidmodels) make that loop cheaper and its derivatives reliable:

  - A **design velocity** is the derivative of the rendered geometry with respect to one
    layout parameter: a field ``V(x, y, z) = ∂X/∂p`` giving the rate at which each point
    ``X`` of the solid model moves as the parameter ``p`` changes. It is built from the 2D
    layout before any meshing, so it can be evaluated at the nodes of any mesh of the model,
    including meshes that a solver has refined or partitioned.
  - A **mesh morph** moves the nodes of an existing mesh file by a displacement
    ``Σᵢ δpᵢ Vᵢ``, without re-meshing. The mesh's topology, and with it the solver's
    discretization, stays the same between designs.

Together they give smooth, accurate finite differences of simulated quantities with respect
to layout parameters, with no noise from re-meshing. They also give exact derivatives from
solvers that compute shape sensitivities: a solver that reports the gradient ``gₖ`` of a
quantity ``J`` with respect to the positions ``xₖ`` of its mesh nodes gives
``dJ/dp = Σₖ gₖ ⋅ V(xₖ)``. The design velocity carries the layout's design intent to the
solver's mesh, and the solver needs no knowledge of the layout.

Design velocities are geometry: they know nothing about the physics of the simulation. A
parameter is a geometry control knob, as everywhere in DeviceLayout.jl.

## Building design velocities

[`SolidModels.design_velocities`](@ref) takes a function that builds the layout from a
`NamedTuple` of parameters, and the parameters at which to differentiate. With a
[`SchematicDrivenLayout.SolidModelTarget`](@ref), the function returns a planned and checked
`Schematic`, and the target supplies the layer mapping, z positions and extrusions, exactly
as for `render!(sm, sch, target)`:

```julia
using DeviceLayout, DeviceLayout.SchematicDrivenLayout, DeviceLayout.PreferredUnits
import .SchematicDrivenLayout.ExamplePDK: LayerVocabulary, singlechip_solidmodel_target

# A pair of pads in a ground-plane cutout, with the pads' gap and width as parameters.
function qubit(p)
    g = SchematicGraph("qubit")
    floorplan = plan(g)
    cs = floorplan.coordinate_system
    render!(cs, centered(Rectangle(600μm, 400μm)), LayerVocabulary.METAL_NEGATIVE)
    for s in (-1, 1)
        center = Point(s * (p.gap + p.width) / 2, 0μm)
        pad = centered(Rectangle(p.width, 150μm); on_pt=center)
        render!(cs, pad, LayerVocabulary.METAL_POSITIVE)
    end
    area = centered(Rectangle(2mm, 2mm))
    render!(cs, area, LayerVocabulary.SIMULATED_AREA)
    render!(cs, area, LayerVocabulary.WRITEABLE_AREA)
    render!(cs, area, LayerVocabulary.CHIP_AREA)
    check!(floorplan)
    return floorplan
end

target = singlechip_solidmodel_target()
dv = SolidModels.design_velocities(qubit, (gap=40μm, width=240μm), target)
dv.gap(140, 0, 0) # ≈ [0.5, 0, 0]: the right pad moves by half the change in the gap
```

For a plain coordinate system, pass `map_meta`, `zmap` and `thickness` instead of a target,
as for [`render!(::SolidModel, ::CoordinateSystem)`](@ref).

The construction has three steps:

 1. **Vertex velocities.** The layout is built at `p0` and at `p0 ± h` for each parameter,
    and the velocity of every vertex of the rendered geometry is the central difference of
    its position. Layout vertices are usually affine in the parameters, so the differences
    are exact. Curves are discretized as by `to_polygons`, which suffices when a parameter
    moves a curve without changing its discretization (for example, a translation).
 2. **In-plane field.** All rendered edges in a rectangular window around the moving
    geometry form a planar arrangement, like the fragmentation of the solid model: edges
    are split where they cross or touch, and each crossing moves with the derivative of
    the crossing point. A constrained triangulation of the window interpolates the edge
    velocities harmonically. The field is zero on fixed edges and on the window boundary.
 3. **Extrusion profile.** The in-plane field is extended in z by a profile that is 1 across
    the moving geometry (and its extrusion, if any) and decreases linearly to 0 at the
    nearest other plane of rendered geometry above and below, for example the bottom of the
    substrate and the top of the simulation box. `zlimits` bounds it further.

The result is continuous, moves every rendered edge with its exact velocity, and keeps
planar interfaces planar. It is zero wherever the geometry is fixed: on fixed edges,
outside the window, and beyond the profile.

## When construction fails

Rather than return a field that is not the derivative of the rendered geometry,
`design_velocities` throws an error when:

  - a step changes the layout's topology: the number of entities, boundary loops or
    vertices, or whether features touch;
  - a moving edge crosses the window boundary;
  - a parameter changes the z or thickness of an entity (only in-plane velocities are
    supported);
  - other rendered geometry lies inside a moving extrusion;
  - nothing bounds the profile in z, in which case `zlimits` must be given.

A parameter that moves nothing gives a warning and a zero velocity.

Geometry created by postrendering operations, such as the decks of air bridges, is not part
of the 2D layout, so design velocities do not account for it. Keep such geometry away from
moving edges, or bound the profile below it with `zlimits`.

## Morphing a mesh

[`SolidModels.morph_mesh`](@ref) writes a copy of a mesh file with its nodes moved:

```julia
quality = SolidModels.morph_mesh("design.msh2", "design_morphed.msh2", dv, (gap=1μm,))
```

Gmsh reads the mesh, an MSH 2.2 or 4.1 file of any order, and writes it back in the same
format with only the nodes moved; MSH 2.2 files have their nodes and elements renumbered. The returned
[`SolidModels.MorphQuality`](@ref) reports the change in element quality at the corners of
every element. An inverted element is an error. A small minimum Jacobian ratio (below about
0.3) or a large strain (above about 0.3) means the morph has degraded the mesh, and the
design should be re-meshed.

Morphing keeps the mesh's topology, so the boundary of a mesh region stays where it is if
the design velocity vanishes there. This allows, for example, a region of a substructured
model to be redesigned without recomputing the rest. Use a `window` and `zlimits` that keep
the velocity zero on the region's boundary.

## See also

  - [Solid Models](@ref concept-solidmodels) for the 2D-to-3D pipeline
  - [API Reference: Design velocities and mesh morphing](@ref api-design-velocities)
