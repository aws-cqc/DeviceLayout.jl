# Tutorial: Your First Layout

In this tutorial, you'll learn the fundamentals of DeviceLayout.jl by creating a [Vernier scale](https://en.wikipedia.org/wiki/Vernier_scale) for measuring alignment between two layers.

## What You'll Learn

- Creating and manipulating basic geometry entities
- Understanding cells and rendering
- Aligning geometry entities
- Working with references
- Using polygon Boolean operations
- Using CoordinateSystems and semantic metadata
- Exporting geometry to GDSII

## Prerequisites

- [Getting started](./getting_started.md): Installing Julia and setting up your development environment

## Setup

You'll work interactively in the Julia REPL. If using VS Code, you can use the built-in REPL from the
Julia extension with `Alt+J Alt+O` (or `Option+J Option+O` on Mac), which will display graphical
previews of geometry in a separate tab when a `Cell` or `CoordinateSystem` is returned by REPL execution.
Otherwise, you can save any `Cell` to GDSII and view it in KLayout or another program.

Create a directory for this tutorial project and start the Julia REPL with `julia`. Type `]` to enter the REPL mode for the package manager. The name
of the current environment appears in parentheses at the left of the prompt. This will be the default
environment for your Julia version (e.g., `(@v1.12) pkg>`).
Activate the environment for the current
directory with `pkg> activate .`.

Check to see whether DeviceLayout and FileIO are present in the
environment with `pkg> status`. If you are using a new project directory, this will show that no packages are installed. In that case, run `pkg> add DeviceLayout FileIO`. Leave the Pkg REPL mode by pressing backspace with an empty prompt.

Finally, load DeviceLayout.jl:

```@example first_layout
using DeviceLayout
using DeviceLayout.PreferredUnits # for mm, μm, nm, etc
using FileIO                      # for `save`
```

## Step 1: Creating a scale mark

DeviceLayout.jl provides several primitive shapes (`GeometryEntity`). Let's create a [`Rectangle`](@ref) for one mark on a Vernier scale:

```@example first_layout
mark = Rectangle(5μm, 15μm) # lower left corner at (0, 0)
```

You can enter `μ` by typing `\mu` and pressing `Tab`.

We'd like this to be centered on the Y axis, so we'll move it to the left a bit:

```@example first_layout
mark = mark - Point(2.5μm, 0μm) # now centered on y axis
```

To create actual layout data, shapes need to be associated with layers.
To do this, we can create a [`Cell`](@ref), a coordinate system corresponding to a GDSII cell, and [`render!`](@ref) our shape to the cell in our desired layer, represented as `GDSMeta(layer, datatype)`.

```@example first_layout
mark_cell = Cell("single_mark")
render!(mark_cell, mark, GDSMeta(0, 0)) # layer 0, datatype 0
```

If you're using VS Code the Julia extension's built-in REPL, this should display a rectangle in a new tab.
This is not a live preview of your `Cell`, but a new graphical preview is generated whenever the `Cell` is
returned by REPL execution, as by running `julia> mark_cell`.

Otherwise, you can view your layout by saving to GDSII and opening it in a standalone viewer like KLayout.

```@example first_layout
save("single_mark.gds", mark_cell)
```

Note that shapes rendered to a `Cell` are converted into [`Polygon`](@ref)s:

```@example first_layout
elements(mark_cell)
```

## Step 2: Creating an array of marks

We can create an array of marks for one of the scale's rulers by rendering several rectangles to a `Cell`.

```@example first_layout
mark_pitch = 10μm
ruler_range = -5:5
ruler_cell = Cell("single_ruler")
for i in ruler_range
    render!(ruler_cell, mark + i*Point(mark_pitch, 0μm), GDSMeta(0, 0))
end
ruler_cell
```

However, arrays of identical structures can be more efficiently represented as an `ArrayReference`,
using [`aref`](@ref) to create the reference and [`addref!`](@ref) to place it in a cell:

```@example first_layout
ruler_cell = Cell("single_ruler") # New empty cell
addref!(ruler_cell, aref(mark_cell, ruler_range * mark_pitch, (0:0)μm))
ruler_cell
```

We'll extend the center mark for visual clarity when reading the scale. We can use a reference
to position an extra mark rectangle above the center mark, this time with [`sref`](@ref) (for
"structure" or "single" reference):

```@example first_layout
# Use `addref!` with just the referenced cell and where to place its origin
addref!(ruler_cell, sref(mark_cell, Point(zero(mark_pitch), height(mark))))
# Or slightly more concise: addref!(ruler_cell, mark_cell, Point(...))
ruler_cell
```

Alternatively, we could `render!` another mark rectangle, using [`Align.above`](@ref) to
position it appropriately:

```@example first_layout
render!(ruler_cell, Align.above(mark, ruler_cell; centered=true), GDSMeta(0, 0))
```

The `Align` methods are `above`, `below`, `leftof`, `rightof`, `flushtop`, `flushbottom`,
`flushright`, and `flushleft`. These position a copy of a geometry entity relative to another
so that their bounding boxes are aligned as specified, using keyword options for `offset`
from the aligned position and `centered` positioning in the other dimension.

## Step 3: Creating a Vernier scale

The Vernier scale has two rulers in different layers. The distance from one mark to the next is
different between rulers, so you can measure the offset of one layer from the other by finding
the pair of marks that align. For example, if the difference in pitch is 100nm, and the
third pair of marks from the center are aligned, then the layers are offset by 300nm.

Since we want to draw a second ruler as above with a different pitch and layer, we'll create a
function to draw a ruler with given parameters:

```@example first_layout
function ruler!(ruler_cell, mark_rect, mark_pitch, ruler_range, metadata)
    mark_cell = Cell(uniquename("mark")) # Avoid creating Cells with duplicate names
    render!(mark_cell, mark_rect, metadata)
    addref!(ruler_cell, aref(mark_cell, ruler_range * mark_pitch, (0:0)μm))
    # Extend center mark (assuming range is symmetric and includes zero!)
    render!(ruler_cell, Align.above(mark_rect, ruler_cell; centered=true), metadata)
    return ruler_cell
end

ruler_1 = Cell("ruler_1")
ruler_2 = Cell("ruler_2")
ruler!(ruler_1, mark, mark_pitch, ruler_range, GDSMeta()) # default GDSMeta is 0/0
ruler!(ruler_2, mark, mark_pitch - 100nm, ruler_range, GDSMeta(1)) # 1/0
```

Then to create our Vernier scale, we can place references to both of these in another `Cell`:

```@example first_layout
vernier = Cell("vernier")
addref!(vernier, ruler_1)
addref!(vernier, ruler_2; xrefl=true) # Reflect ruler 2 across x axis
vernier
```

## Step 4: Handle negative layers

What if our process uses negative patterns, where material is removed where you have polygons?
With the pattern above, one layer could cover up the other. We'll add an option where the
ruler marks are holes in a larger area of a negative layer (based on the [`bounds`](@ref) of
the original ruler), using [`difference2d`](@ref) to subtract polygons from each other:

```@example first_layout
function ruler!(ruler_cell, mark_rect, mark_pitch, ruler_range, metadata; negative=false)
    mark_cell = Cell(uniquename("mark")) # Avoid creating Cells with duplicate names
    if !negative
        render!(mark_cell, mark_rect, metadata)
        addref!(ruler_cell, aref(mark_cell, ruler_range * mark_pitch, (0:0)μm))
        # Extend center mark (assuming range is symmetric and includes zero!)
        render!(ruler_cell, Align.above(mark_rect, ruler_cell; centered=true), metadata)
    else
        # Create temporary cell with geometry to subtract
        temp_cell = Cell("temp")
        ruler!(temp_cell, mark_rect, mark_pitch, ruler_range, metadata) # positive
        # Create cutout
        bnds = bounds(temp_cell)
        # `offset`: push out all edges by `2*mark_pitch`
        cutout = offset(centered(Rectangle(width(bnds), 2*height(bnds))), 2*mark_pitch)
        # Create negative pattern
        neg_ruler = difference2d(cutout, temp_cell => metadata)
        render!(ruler_cell, neg_ruler, metadata)
    end
    return ruler_cell
end

ruler_1 = Cell("ruler_1")
ruler_2 = Cell("ruler_2")
ruler!(ruler_1, mark, mark_pitch, ruler_range, GDSMeta())
ruler!(ruler_2, mark, mark_pitch - 100nm, ruler_range, GDSMeta(1), negative=true)

vernier = Cell("vernier")
addref!(vernier, ruler_1)
addref!(vernier, ruler_2; xrefl=true) # Reflect ruler 2 across x axis
vernier
```

Besides `difference2d`, we also have `union2d`, `intersect2d`, and `xor2d`. These only
work on polygons. For convenience, they can take any kind of geometry or vector of
geometries as arguments, but these will be converted to polygons first. They can also
take pairs like `temp_cell => metadata` above, which selects all polygons in `temp_cell` in
the layer `metadata`.

## Step 5: Using CoordinateSystems

So far, we've done everything with `Cell`s. These correspond to cells in the GDSII format,
and can only store `Polygon`s with integer layer/datatype (`GDSMeta`) and
references to other `Cell`s.

It's often better to work with "native" DeviceLayout geometry and metadata, and
only render to a `Cell` when you're ready to save to GDS. This preserves information
about the type of geometry entities, like `Rectangle` or `Ellipse` rather than `Polygon`, which
can make certain computations easier. Backends other than GDS may also be able to take
advantage of that information; for example, the `SolidModel` backend has exact representations
of curves and ellipses, and can use geometry information to control mesh sizing.

Moreover, we can use named layers ([`SemanticMeta`](@ref) rather than `GDSMeta`). This helps make geometry "portable" across process technologies. For example, you may have a `:metal` layer, but you might have a process flow for aluminum where the tool expects layer 1 and an alternative process for niobium where the tool expects layer 2. This mapping can be deferred until you render to a `Cell` rather than hardcoded into the geometry.

The native equivalent of `Cell`
is [`CoordinateSystem`](@ref), which can store any `DeviceLayout.GeometryEntity` with any
kind of metadata, as well as references to any
`DeviceLayout.GeometryStructure` (including `Cell`, `CoordinateSystem`, `Path`,
and `Component`).
When we `render!` to a `CoordinateSystem`, we simply place the entity as it is, rather
than transform it into a backend-specific "primitive" entity. (In fact, `place!` is a synonym
for `render!` that only works with `CoordinateSystem`s.)

Our `ruler!` function would already work if we passed a `CoordinateSystem` as `ruler_cell`,
but the internal `Cell` containing a single mark would still be holding a polygon. So we just change `Cell` to `CoordinateSystem`:

```@example first_layout
function ruler!(ruler_cs, mark_rect, mark_pitch, ruler_range, metadata; negative=false)
    mark_cs = CoordinateSystem(uniquename("mark")) # Avoid duplicate names
    if !negative
        render!(mark_cs, mark_rect, metadata)
        addref!(ruler_cs, aref(mark_cs, ruler_range * mark_pitch, (0:0)μm))
        # Extend center mark (assuming range is symmetric and includes zero!)
        render!(ruler_cs, Align.above(mark_rect, ruler_cs; centered=true), metadata)
    else
        # Create temporary cell with geometry to subtract
        temp_cs = CoordinateSystem("temp")
        ruler!(temp_cs, mark_rect, mark_pitch, ruler_range, metadata) # positive
        # Create cutout
        bnds = bounds(temp_cs)
        # `offset`: push out all edges by `2*mark_pitch`
        cutout = offset(centered(Rectangle(width(bnds), 2*height(bnds))), 2*mark_pitch)
        # Create negative pattern
        neg_ruler = difference2d(cutout, temp_cs => metadata)
        render!(ruler_cs, neg_ruler, metadata)
    end
    return ruler_cs
end
```

Now we can use this method with `SemanticMeta`:

```@example first_layout
METAL_1 = SemanticMeta(:metal_1) # layer names are Julia `Symbol`s
METAL_2 = SemanticMeta(:metal_2)
ruler_1 = CoordinateSystem("ruler_1")
ruler_2 = CoordinateSystem("ruler_2")
ruler!(ruler_1, mark, mark_pitch, ruler_range, METAL_1)
ruler!(ruler_2, mark, mark_pitch - 100nm, ruler_range, METAL_2, negative=true)
vernier = CoordinateSystem("vernier")
addref!(vernier, ruler_1)
addref!(vernier, ruler_2; xrefl=true) # Reflect ruler 2 across x axis
vernier
```

We can [`flatten`](@ref) the result, creating a copy with the same geometry
without any references, where all geometry entities are elements of the top level
coordinate system:

```@example first_layout
elements(flatten(vernier))
```

We find that they're all `Rectangle`s, plus one `ClippedPolygon` created by `difference2d`,
rather than the `Polygon`s we would get from working directly with `Cell`s.

Before we move on, let's add a second, rotated copy to measure alignment in two dimensions,
using `addref!` with an additional argument for the position of the referenced cell's origin
and a `rot` keyword argument for rotation:

```@example first_layout
vernier_xy = CoordinateSystem("vernier_xy")
addref!(vernier_xy, vernier)
addref!(vernier_xy, vernier, Point(width(bounds(vernier)), width(bounds(vernier))); rot=90°)
vernier_xy
```

You can enter `°` by typing `\degree` and pressing `Tab`.

To export to GDS, we need to provide a way to map named layers to GDSMeta. (If this is not
provided, layers will be mapped arbitrarily with a warning, but this is
meant as a convenience for quick visualization and should not be relied on.)

```@example first_layout
layer_record = Dict(:metal_1 => GDSMeta(), :metal_2 => GDSMeta(1))
map_layer(m) = layer_record[layer(m)]
vernier_cell = Cell(vernier_xy; map_meta=map_layer)
save("vernier.gds", vernier_cell)
```

## Summary

In this tutorial, you learned about:

- **Entities**: Basic geometric shapes like `Rectangle` and `Polygon`
- **GDSMeta**: Layer information for GDSII output
- **Cells**: Containers that hold polygons with GDSMeta and references to other cells
- **render!**: The function that converts entities into cell elements
- **References**: Arrayed, rotated, mirrored, and translated references to cells
- **Alignment**: Translating entities to align and center bounding boxes
- **Boolean operations**: `union2d`, `difference2d`, `intersect2d`, `xor2d`
- **CoordinateSystems**: Containers for DeviceLayout-native geometry representation
- **SemanticMeta**: Named layers that can be mapped to GDSMeta when rendering to a cell
- **GDS export**: Rendering from CoordinateSystems to Cells saved as `.gds` files

## Next Steps

Continue to [Working with Paths](working_with_paths.md) to learn about creating coplanar waveguides and more complex path-based structures.
