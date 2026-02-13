# Component Style Guide

This is a style guide for users creating their own DeviceLayout.jl components.

For basic Julia style, see [the style guide in the Julia manual](https://docs.julialang.org/en/v1/manual/style-guide/). Contributions to Julia projects should conform to local conventions, which are often established by a choice of either [Blue](https://github.com/JuliaDiff/BlueStyle) or [SciML style](https://github.com/SciML/SciMLStyle?tab=readme-ov-file). A good way for projects to short-circuit basic style questions is automatic formatting using [Runic.jl](https://github.com/fredrikekre/Runic.jl) or [JuliaFormatter.jl](https://github.com/domluna/JuliaFormatter.jl/). For example, DeviceLayout.jl generally follows Blue style, with simple conventions enforced via JuliaFormatter using [a `julia-format` job in GitHub CI](https://github.com/aws-cqc/DeviceLayout.jl/blob/main/.github/workflows/CI.yml) together with the script in [`scripts/format.jl`](https://github.com/aws-cqc/DeviceLayout.jl/blob/main/scripts/format.jl).

Many topics below, like parameter naming conventions, are important for creating a predictable codebase that can be understood without reading code or inspecting GDSII files. Other topics, like how to choose parameterization for components, can also have direct benefits in device design. The ExamplePDK is meant to demonstrate good style in this sense, but it does not yet follow all recommendations here.

## Parameter naming

  - **Use descriptive and meaningful names** that clearly communicate a parameter’s purpose and function. Parameters should be self-documenting, allowing developers to understand their role without examining implementation details.
    
      + Good: `claw_trace`
      + Bad: `d2` (not descriptive), `claw_width` (which width?)

  - **Maintain consistency** with local standards. If there is no established style convention for your project or team, maintain consistency in your own contributions throughout your component, project, package, and/or PDK. Once you establish a naming pattern, apply it uniformly to create a predictable and maintainable codebase.
  - **Prioritize readability** over brevity. Choose names that are pronounceable and immediately understandable, even if they’re longer. Autocomplete makes length matter less.
    
      + Good: `island_width`
    
      + Bad: `isl_w`
      + Parameter names (as with variable names in general) should also be long and descriptive enough that they can be uniquely identified in full-text search
        
          * Bad: `p, pa, path`
          * Good: `feedline_path`
          * Use names that are extremely concise only in very narrow scopes, like few-line functions or for loops (e.g. `for i in eachindex(array)`)

### Hierarchical naming

Use hierarchical naming with underscores to group related parameters and establish clear relationships.

  - Parameters should be in `snake_case`

  - Descriptors should be in order of increasing specificity, typically `<feature>_<dimension>`
  - When there is ambiguity, add more feature-specific prefixes
  - Rationale:
    
      + Logical grouping: Parameters are grouped by feature when sorted alphabetically
      + Autocomplete friendly: Typing the feature name shows related parameters
      + Hierarchical clarity: The feature is the primary concept, with dimension as a qualifier

```julia
# Good: Clear hierarchy and relationships
island_outer_radius = 135μm
island_inner_radius = [80, 80, 80, 80, 80]μm
island_ground_gap = 15μm
island_coupler_gap = 15μm

claw_inner_gap = 5μm
claw_outer_gap = 20μm
claw_trace = 10μm

feedline_style = Paths.CPW(10μm, 6μm)
feedline_length = 300μm
feedline_bridge = nothing

# Avoid: Flat naming without clear relationships
outer_radius = 135μm
inner_gap = 5μm
coupler_gap = 15μm
island_gap = 15μm
width = 10μm
```

### Feature naming

Decide what each bit of a component is called and use that name consistently in prefixes and documentation. Names should be descriptive and reflect the physical shape or functional purpose. Some common ones in ExamplePDK:

  - General shapes: `island`, `claw`, `shield`, `star_tip`, `cutout` (shape in a negative layer into which positive shapes are placed)
  - Path shapes: `meander`, `bend`, `taper`, `tap` (path ‘tee’d off of another line), `snake` (two opposite turns in a row)
  - Functional elements: `xy`, `z`, `junction`, `coupler`, `termination`, `feedline` (a signal-carrying path addressing a component)

When naming a feature, ask:

  - Do existing components have a similar feature? If so, what is it called? Unless that name clearly violates style rules, use that.
  - Do existing components use the name I want with a different meaning? If so, choose a different name.
  - Is this name ambiguous, or will someone looking at a drawing understand exactly which feature it refers to?

### Dimensional suffixes in 2D

Use suffixes rather than prefixes to indicate dimension: `feature_width` rather than `width_feature`. Reach for the following common suffixes first:

  - For **rectangular features**, use `_x_length` and `_y_length`
  - For **linear features**, use `_length` (primary/extensible dimension) and `_width` (cross-sectional thickness along length)
  - For **circular features**, use `_radius`
  - For **CPW-like features**, use `_trace` and `_gap` or (especially if you’re actually drawing it as a Path) `feature_style = Paths.CPW(trace, gap)`

In more detail:

  - `_length`:  The primary dimensional extent, as in the longest dimension, the length of a `Path`, the dimension along which the feature would be “extended” from one end, or the dimension along the feature’s “main” axis (e.g., a symmetry axis)

  - `_width`: The dimension perpendicular to `_length`
  - `_x_length` or `_y_length`: For rectangular or non-Path-like features, extent along the x axis or y axis in the reference frame of the component
  - `_radius`: The radius of a curve or circle
  - `_offset`: Linear displacement from a reference position (e.g., centered or aligned)
    
      + `Align.above(feature_polygon, reference; offset=feature_offset))`
      + If offsetting in both dimensions, use a `Point`
  - `_bias`: Distance to grow a positive shape from each edge (e.g., for `offset(feature_polygon, feature_bias)`)
  - `_pitch`: Center-center distance of repeated features (e.g. bridges on a CPW)
  - `_gap`: Edge-edge width of negative space between two features (e.g., width of non-metallized region between edges of metal features)
  - `_spacing`: Edge-edge distance in contexts with more than two features (e.g., spacing between edges of bump bonds)
  - `_trace`: The width of a metal strip
  - `_overlap`: How far something extends into another feature/region
  - `_rounding`: Rounding radius of a corner
    
      + relative or absolute is determined by unitless/unitful; components should use a type annotation to require one or the other
      + Example: `island_rounding::Float64` if the component is designed to use rounding relative to edge length, or `island_rounding::DeviceLayout.Length` for an absolute rounding radius
  - Rotational suffixes:
    
      + `_direction`: Direction of a path or similar feature, counterclockwise from the positive x axis
      + `_angle`: Angular extent
      + `_rotation`: Counterclockwise rotation from a reference direction
  - Avoid:
    
      + `_thickness, _height, _depth` (more appropriate for 3D)
      + `_distance` (ambiguous without additional qualifiers like `_center_center` or `_edge_edge`, but acceptable if offset, pitch, gap, spacing don’t apply)
      + `_extent` with respect to Paths: usually you want trace, gap, and length, but if you do use extent, it must be the distance from center line to outer edge of style; that is, `trace/2` for `Paths.Trace` and `trace/2 + gap` for `Paths.CPW` (corresponds to `Paths.extent()` function)
      + `_extent` in other contexts: Use sparingly to describe dimensions not well captured by the above terms, for example bounding box dimensions of a feature with radial symmetry like the star island (e.g.,  `island_x_extent` feels more natural than `island_x_length`)—but usually that’s not going to be a parameter unless it’s specifically subject to design intent or constraints
      + `_shift` (prefer `_offset` for linear displacement, unless it can be confused with curve or polygon offsetting)
      + `_diameter` (prefer `_radius`)

### Suffixes in 3D

  - `_height`: Height above a substrate surface
  - `_thickness`: Thickness of an extrusion
  - `_depth`: Thickness of a subtracted or downward extrusion (etch/trench depth)
  - `_flipchip_gap`: Distance between substrate surfaces on chips facing each other

### Composite components

  - For parameters passed through to subcomponents:
    
      + If the parameter is inherited by multiple subcomponents, use the same name as in the subcomponents
      + If the parameter is used for one specific subcomponent, add prefix for the subcomponent
      + Use [`SchematicDrivenLayout.filter_parameters`](@ref) to get a collection of either kind of shared parameters

  - If you have a large number of parameters to pass through to a subcomponent, or want to maintain
    flexibility over parameters that are not usually important, use a `templates` NamedTuple parameter
    
      + For each subcomponent, the `templates` NamedTuple contains an instance of the subcomponent type
        (with the subcomponent name as the key) that provides defaults
      + Parameters you’d often want to override or reconcile with other parameters are set at
        the CompositeComponent parameter level

Example of template usage in `_build_subcomponents`:

```julia
@component jj = comp.templates.jj begin
    lead_length = comp.island_ground_gap / 2  # Override specific params
    # Other template parameters are preserved
end
```

Example with both filtering and templates:

```julia
@compdef struct MyCompositeComponent <: CompositeComponent
    templates = (;
        subcomp1=MySubComponent(; name="subcomp1"),
        subcomp2=MySubComponent(; name="subcomp2")
    )
    subcomp1_width = 2mm
    length = 2mm
end

@compdef struct MySubComponent <: Component
    width = 1mm
    length = 2mm
end

function SchematicDrivenLayout._build_subcomponents(cc::MyCompositeComponent)
    # Matching with no prefix: (; length=...)
    shared_params = filter_parameters(MySubComponent, cc)
    # Matching with prefix: (; width=...)
    subcomp1_overrides = filter_parameters(cc.templates.subcomp1, cc)
    @component subcomp1 = cc.templates.subcomp1(; subcomp1_overrides..., shared_params...)
    @component subcomp2 = cc.templates.subcomp2(; shared_params...)
    return (subcomp1, subcomp2)
end
```

### Other special cases

  - Boolean parameters: use past participles or adjectives, e.g. `rounded` instead of `round`, `rounding`, or `is_rounded`
    
      + (although for rounding specifically you would just set `feature_rounding = 0.0` to turn it off, with or without units depending on whether the component uses relative or absolute rounding)

  - Angles:
    
      + Use degrees for the default
      + Positive angles are counterclockwise
  - Arrays/counting:
    
      + Count starting with 1
    
      + Use suffix `_count` for the number of something (not `n_...` or `num_...`)
      + Parameter arrays should be ordered consistently, but the order may depend on context
        
          * **Generic circular arrangement**: Counterclockwise from the x-axis
        
          * **Chip ports**: Conform to your packaging convention based on how the chip is placed in a package (IC packages are usually numbered counterclockwise from left end of bottom edge; `ExamplePDK.ChipTemplates` ports are numbered clockwise from left end of top edge)
          * **Grids**: Matrix with [Row, Column] starting with [1, 1] in the upper left (maps to Julia matrix literal)
          * **Pairs** (input/output, start/end): `input_` and `output_` or similar descriptors even if it’s arbitrary which is which; `_0_` and `_1_` if they correspond to `p0` and `p1` as in the start and end points of a Path; tuple otherwise
            
              - For two or three things that aren’t input/output pairs, you can use an array/tuple or `_1_, _2_, _3_`, but don’t use the latter if you have multiple numbered collections with unrelated counts

## Parameterization

What parameters should you use to describe the component in the first place? The guiding considerations, in order of priority:

  - **Geometric independence**: Each parameter should control a single, distinct geometric property without creating unintended dependencies
    
      + Good: `island_width`, `island_ground_gap`
      + Bad: `island_width`, `transmon_total_width`, deriving `island_ground_gap = (transmon_total_width - island_width)/2`
        * Explanation: `transmon_total_width` now controls the gap, but the gap also appears at the end of the transmon length
      + Good: `total_pathlength`, `feature_position` describing how far along a component's path a feature is placed
      + Bad: `total_pathlength`, `feature_position_pathlength_ratio` specifying the ratio of position to total path length
        * Explanation: Changing the total pathlength changes the position of the feature, which may be physically motivated but will cause headaches (especially if there is a hook on the feature)

  - **Design independence**: “Tuning parameters”—the set of parameters that are varied in practice to obtain target design properties—should each approximately independently affect one design property
    
      + Bad: `coupling_length` and `meander_length` for an inductively-coupled transmission line resonator, such that increasing the coupling length lowers the frequency directly by increasing the total length
    
      + Good: `coupling_length` and `total_length`, such that increasing the coupling length only affects resonator frequency by increasing external loading
      + This can conflict with geometric independence, which takes priority:
        
          * Bad: `coupling_pad_width` and `effective_length` parameter taking into account estimated capacitive loading of coupling pad, so that `coupling_pad_width` changes the total path length in order to leave frequency roughly fixed (this differs from the `total_length` example above because `effective_length` is not a single, distinct geometric property)
          * Good: Separate parameters for transmission line resonator length and coupling pad size, even though both affect resonant frequency
  - **Design intent preservation**: Parameters should reflect engineering requirements rather than arbitrary geometric relationships—they should capture the “why” behind dimensional choices, not just the “what”
    
      + Bad: A meander parameterized by segment lengths and number of turns
    
      + Good: A meander parameterized by total length and available footprint
      + Parameters should still describe geometric properties, not functional properties:
        
          * Bad: Meander `delay` that controls total path length based on wave propagation delay (calculated how?)
          * Good: Meander `total_length` that controls length of path directly
          * Bad: Two degenerate parameters—“total effective length”, which is varied to control the frequency, and “assumed extra effective length” that accounts for bends, bridges, and coupling capacitances—so that you can have a parameter approximately inversely proportional to frequency with as little offset as possible
          * Good: Make target frequency a device-level parameter rather than a component parameter, from which you compute the required path length based on data
  - **Constraint expression**: It should be easy and natural to describe design rules or constraints on parameters
    
      + Bad: Two features overlap if some complex combination of parameters is negative, creating an invalid geometry
    
      + Good: A `feature1_feature2_gap` parameter that must be nonnegative
      + Bad: Drawing the entire geometry to calculate a footprint or distance between hooks that will be constrained in a device
      + Good: A parameter that controls a footprint dimension or hook position directly, eliminating a parameter that doesn’t carry design intent
      + There should also be no ‘holes’ in feasible parameter space; that is, parameterization allows constraints to define a convex region in parameter space where designs are feasible
      + The preceding considerations take priority
        
          * Bad: A meander parameterized by straight segment length and number of turns, even though there is a constraint that the length must be positive
        
          * Good: A meander parameterized by total length and available footprint, with a helper function to compute the straight segment length
            
            ```julia
            # Good: Clear constraint with documented intent
            @compdef struct ExampleMeanderResonator <: Component
                bbox_x_length = 1.25mm # Bounding box width (path enters at origin along x axis)
                bend_radius = 0.05mm   # Bend radius
                # ... other parameters...
            end
            
            # Must be positive
            function _straight_segment_length(res::ExampleMeanderResonator)
                return res.bbox_x_length - 2 * res.bend_radius
            end
            ```

Some specific guidelines:

  - Components are parameterized by geometry, not physical properties—trace and gap, not impedance
    
      + The relationship between geometry and target property is not necessarily fixed—you might change a material, get new data, or improve your simulations
      + If you know a relationship between geometry and target property, use the property as a device-level parameter from which you derive the geometric component parameter based on a documented data source (like Josephson energy to junction width)

  - Geometries should not have any “magic numbers” (literal numeric lengths that appear in geometry code)—these should be made into parameters with descriptive names
  - Don’t be shy about adding parameters, but don’t prematurely create additional control knobs you’re not sure you’ll need—once you can describe your desired geometries without magic numbers, stop
  - Bridges/crossovers/other "decorations": Make a `MyDecoration` component type and use an instance as a parameter, with components across the device with the same decoration using the same instance
    
      + Ensures fabrication requirements are consistently met and updated across the device, and also reduces redundant rendering/memory usage
      + The decoration Component doesn’t have to go in a schematic—it can be attached to a path like any coordinate system
      + The default should be `nothing`, to encourage defining decorations at the device level and sharing them across components
  - Choose parameters so that there are as few parameters that affect hook position as possible
    
      + The hook should be easy to find directly from parameters, without building complex geometry first
      + In particular, “tuning parameters” should not change hook positions
      + If changing one hook position can’t be avoided, consider whether another hook position should change along with it to more easily express a simple “distance between hooks” constraint and to keep the entire floorplan from shifting when the parameter is tuned
  - Avoid “flags” that change how the component is rendered for different purposes like simulation or artwork—use `OptionalStyle` (e.g., with the helper functions `not_simulated`, `only_simulated`, `only_solidmodel`) or metadata together with your [rendering target](./targets.md) to customize behavior
  - Orientation/reference frames
    
      + If components always have a particular global orientation on chip, the local orientation should be the same
      + A Path-like component should otherwise generally have the path starting at the origin facing along the positive x-axis (`α0=0°`)
  - Type annotations are generally optional, except where there is ambiguity about what kind of thing the parameter is
    
      + When annotating a length, use a floating point type like `::typeof(1.0nm)` (or `μm` or `mm` if that’s how you want the unit printed)
      + Rounding: While rounding in DeviceLayout can be either relative (unitless) or absolute (unitful), a given component is likely designed for only one or the other. In that case, use a `::Float64` or a length annotation
  - A parameter should be the appropriate Julia or DeviceLayout.jl type for the kind of thing it is; it is not required to be a single real value, even when it is subject to tuning or optimization
    
      + For a `Path`-based feature, use `feature_style=Paths.CPW(trace, gap)` rather than `feature_trace` and `feature_gap`
    
      + Optimization should use transformed parameters anyway
        
          * Example: In the [single transmon optimization example](../examples/singletransmon.md), we optimize over `x` with `cap_length = (1 / x[1]^2) * 620μm` and `total_length=(1 / x[2]) * 5000μm`, so that frequencies are approximately linear in `x` and both elements are around 1
          * Example: When optimizing `feature1_feature2_offset::Point` with a scale of 1μm, optimize over `x` with `feature1_feature2_offset = Point(x[1], x[2]) * 1μm`

## Component documentation

Documentation and definitions should follow existing templates used by `generate_component_definition` and `generate_component_package`.

At least one kind of diagram showing key features and parameters is required:

  - Annotated ASCII diagram in the docstring
  - Annotated drawing of rendered component in HTML docs

### Docstrings

Docstrings should follow the templates in `Component.jlt` or `CompositeComponent.jlt` in [`DeviceLayout.jl/templates`](https://github.com/aws-cqc/DeviceLayout.jl/blob/main/templates). You can customize these for your PDK by adding modified copies to a `templates/` subfolder of your PDK root folder. These templates are used when a component definition is created with [`SchematicDrivenLayout.generate_component_definition`](@ref) or [`SchematicDrivenLayout.generate_component_package`](@ref).

For a non-composite Component, the docstring looks like this:

```julia
"""
    struct {{{compname}}} <: Component

<One-line description of component.>
<Optional: Longer description of component>

<Optional: Annotated ASCII illustration>

# Parameters

  - `name`: Name of component
  - `<p>`: <Parameter description>
  - ...

# Hooks

  - `<hook1>`: Description
  - ...
"""
@compdef struct {{{compname}}} <: Component
    # ... parameters...
end
```

A CompositeComponent docstring also enumerates its subcomponents with links to their docstrings.

Any ambiguous parameters or hooks should be documented well enough that they can be understood without reading the code or inspecting GDS files. For example, if names of parameters or hooks use `x/y`, `left/right`, compass directions like `north`, or other terms relative to a reference frame, the reference frame or axes need to be clearly documented.

### HTML docs

Docs should start with the template [`Component.mdt` in `DeviceLayout.jl/templates`](https://github.com/aws-cqc/DeviceLayout.jl/blob/main/templates/Component.mdt). You can customize this for your PDK by adding a modified copy to a `templates/` subfolder of your PDK root folder.  This template is automatically used by [`SchematicDrivenLayout.generate_component_package`](@ref).

The template shows all docstrings in the component package, then runs an `@example` block that creates a default component instance (with hooks shown as labeled arrows), saves it to SVG, and displays it. Additional components added to a package should add a similar example.

Additionally, if there is no ASCII drawing in the docstring, add an image of the component manually annotated with parameters and hooks:

  - Use a drawing app (PowerPoint works surprisingly well) to annotate a PNG/SVG of the component geometry with parameters and hooks
  - Put the resulting image in `docs/src/assets/mycomponent_annotated.jpg`
  - Include that file in the `.md` documentation file:

````
```@raw html
<img src="../assets/mycomponent_annotated.jpg"/>
```
````

## Geometry methods

Organize `_geometry!` methods with clear sections and consistent patterns. For example:

```julia
function SchematicDrivenLayout._geometry!(cs::CoordinateSystem, comp::MyComponent)
    # 1. Extract parameters used in this method body (use destructuring for readability)
    (; param1, param2, param3) = comp

    # 2. Create primary geometry
    main_shape = _create_main_geometry(comp)

    # 3. Create secondary features
    cutouts = _create_cutouts(comp)

    # 4. Apply operations (boolean, rounding, etc.)
    final_shape = _apply_operations(main_shape, cutouts)

    # 5. Place geometry with appropriate layers and mesh sizing
    place!(cs, MeshSized(2 * critical_dimension(comp))(final_shape), METAL_NEGATIVE)

    return cs
end
```

  - Extract the parameters you need for a function at the top of that function using destructuring

  - Explicitly assign derived parameters with descriptive names: `param_total = param_1 + param_2 + param3` rather than just using `(param_1 + param_2 + param_3)` in other expressions
    
      + Important derived parameters should be calculated using functions available to package users
  - Extract complex geometry creation into helper functions
    
      + Helper functions should generally be private, start with an underscore, and take the component as input with the appropriate type annotation, e.g. `_paths(comp::MyComponent)`
  - Internal coordinate systems should always use `uniquename` (to ensure different names across instances)
  - Use [bounding-box alignment methods](../transformations.md#Alignment) for alignment rather than manually calculating dimensions
  - Use `OptionalStyle` (e.g., with the helper functions `not_simulated`, `only_simulated`, `only_solidmodel`) or metadata to allow customizable rendering based on your [rendering target](./targets.md)

## Hooks methods

  - Use descriptive names that indicate connection purpose or geometry:
    
      + Hooks should usually be named after the component that gets attached there—a qubit would have a `readout` hook and a readout resonator a `qubit` hook
      + Hooks can also be named after the geometric feature they mark, for example if it’s used more in the sense of geometric alignment than for circuit/schematic connectivity, or if multiple kinds of components can be attached
      + Use `p0` and `p1` for start/end or in/out (consistent with `Paths`)

  - Write angles in degrees
  - Use a leading semicolon when returning a literal NamedTuple to avoid bugs when you have a single hook
    
      + Incorrect: `return (claw = clawhook)` assigns the value `clawhook` to the variable `claw` and returns it
      + Correct: `return (; claw = clawhook)` returns the NamedTuple you want
      + Do this even when you have multiple hooks, for safety against copying the code and deleting all but one
  - Avoid doing heavy computation inside `hooks`—it is a sign that your parameterization needs improvement
  - For components using hooks based on paths, derive hooks from path geometry:
    
    ```julia
    function SchematicDrivenLayout.hooks(comp::MyPathBasedComponent)
        path = _path(comp)  # Reuse path creation logic
    
        # Extend path for hook positioning if needed
        straight!(path, comp.connection_distance, Paths.NoRender())
    
        return hooks(path)  # Use path's natural hooks
    end
    ```

## Component and package creation and versioning

See [the page on Process Design Kits (PDKs)](pdks.md) for general recommendations on creating and organizing a DeviceLayout.jl PDK. For component packages within your PDK:

  - Use [`SchematicDrivenLayout.generate_component_package`](@ref) to generate component packages and documentation based on a template
    
      + Fill out the docstring templates with parameter/hook/subcomponent descriptions
      + Add an ASCII diagram to the docstring if it's simple enough, and if not, create an annotated image for the HTML docs
      + You can also use `generate_component_definition` to create only the definition file, or copy-paste from `DeviceLayout.jl/templates` to do it manually

  - New components can be defined locally in a design project (that is, non-package code for creating a specific device), but should be put in a package if they are reused
    
      + If you're using the component in more than one design project, then put it in a package
      + For example, if a component is being copied from design project to design project, then it should be packaged
  - New components should generally go in separate packages
    
      + Components go in the same package if and only if they should always be versioned together
    
      + Example: Shunt and series interdigital capacitors both go in InterdigitalCapacitors—they have identical dependencies, share most of their code, and no one should ever have a reason to use v1.1 of the series capacitor with v1.2 of the shunt capacitor
      + Example: A parallel plate capacitor would **not** go in the same package as interdigital capacitors
      + Example: A lumped element resonator that combines an interdigital capacitor with some lumped inductor would **not** go in the same package as either interdigital capacitor (or inductor), since it has more dependencies than either alone
        
          * Otherwise, a user of only the interdigital capacitor would have to version their other dependencies to be compatible with the correct version of the lumped inductor
  - `@variant` and `@composite_variant` should be used sparingly in package code
    
      + Prefer to explicitly factor out shared code that is reused between related components
      + `@variant` is more appropriate for conveniently making small, ad-hoc modifications in design projects
      + If your variant combines a base component with other functional structures, consider making a `CompositeComponent` instead
  - Components types and packages, like all types and packages, should be in `CamelCase`
  - Component packages should be named according to the category of physical structure(s) they implement, as specifically as reasonably possible
    
      + Bad: `Readout` containing all your readout resonators and Purcell filters
      + Good: `ClawedMeanderResonators` containing readout resonators and Purcell filters based on CPW meanders with claw-shaped coupling capacitors
  - Component package names should usually be plural
    
      + Examples: `StarTransmons`, `ClawCapacitors`, `ChipTemplates`
      + Rare exceptions: `FlipChipIntegration` (a package with various components that are part of a "system")
  - Component packages can contain multiple components if those components should always be versioned together (e.g., they share code or always form a composite component together)
    
      + Bad: `Capacitors` package containing both interdigital and claw capacitors
      + Good: `InterdigitalCapacitors` and `ClawCapacitors` packages, each containing series and parallel versions with shared helper functions to create the IDC or claw shapes
  - Names should avoid obscure abbreviations, numbers, and subjective descriptions
    
      + Abbreviations that any quantum or electrical engineer should know are acceptable (“CPW”)
      + Bad: `LongSideSp80GapNegative`
      + Good: `ImpedanceMatchedCPWLauncher`
  - Components should not be named greedily—don’t call a component “Qubit,” because the name is too valuable. Examples:
    
      + Bad: `RoundQubit` is a bad name (is it a circle? an ellipse? did you mean concentric?)
      + Bad: `PurcellReadout` is too generic—is it the readout resonator, filter, or both? Is the physical structure a meander, hairpin, hanger, spiral?
      + Better: `MeanderPurcellReadoutResonator` and `MeanderPurcellFilter`
      + Better: Define one component type `BareMeanderResonator` without external coupling elements, then define a `MeanderFilteredReadoutResonator` composite component combining two of those with additional components for coupling
  - If a name has more than three "parts" (component class, shape, and one modifier) then there is likely a problem with the scope of the component
  - Component and PDK packages must follow Semantic Versioning, like any Julia package
    
      + A design should be able to update components within major versions and get a clean XOR with the old version (except for changes that are bugfixes)
        
          * XOR should be clean across the entire design space, not just for particular designs or defaults
    
      + For example, changes to default parameters count as breaking
  - Component and PDK packages must keep a changelog
    
      + For breaking changes, a migration guide with detailed steps for each change that needs to be made when upgrading major version should be included in the documentation
      + The migration guide should also be linked or (if brief) included in the changelog

## Component composition

What do you choose to be a component in the first place? Where do you draw the boundaries between parts of composite components?

As a layout abstraction, `AbstractComponent` is a parameterized geometry with default parameters and special attachment points (hooks). The interface also provides a few other conveniences, like the `default_parameters` function, the ability to use a component instance as a template constructor (e.g., to locally customize defaults), and (if defined with `@compdef`) storing the geometry after it is first computed.

Meanwhile, `AbstractComponent` does not have necessarily satisfy any functional/physical contract—for example, hooks do not have to be electrical "pins" or "ports". However, a component will be used as a schematic-level abstraction, allowing us to assign meaning to its presence in a device and to its connections to other components.

You should not create a `Component` for every unit of reusable parameterized geometry. You should instead create a function that returns a `GeometryEntity` or two or places them in a coordinate system (for examples, see the [shape library](../shapes.md)) when most of the following are true of your parameterized geometry:

  - It has only one or two shapes
  - It can be useful in various layers
  - It has relatively few parameters, most of which have no natural defaults
  - It has no special attachment/alignment points ([bounding-box alignment methods](../transformations.md#Alignment) are sufficient)
  - It has no independent physical meaning

Anything more complicated or meaningful is a candidate for a `Component`.

Choose definitions for components or composite components that help you take advantage of the schematic level of abstraction. For example, you may have different small elements that can be swapped in and out of a larger structure, like junction types in a transmon; in that case, you would organize the transmon as a composite component with an island subcomponent and a choice of junction subcomponents. The [ExamplePDK transmons](../examples/examplepdk.md#Transmons) accomplish this with a template parameter that can be either a single junction or a SQUID component.

As another example, you might want to be able to build simulation models for individual components or small groups of components based on subgraphs of your schematic graph. In that case, at least for components at the top level in a schematic, something like one of the following should be approximately true:

  - It has some independent physical or functional meaning
  - It is a minimal unit for a useful simulation
  - It can be associated with an RF network with ports, which could be cascaded with other components' RF networks based on schematic connections
  - It can be associated with a netlist, such that netlist nodes could be identified and elements (like capacitances and inductances) quantified, and then composed with other components' netlists based on schematic connections

The appropriate conceptual boundaries between components will depend on your device and on your simulation workflow. In analog RF devices, where crosstalk and parasitic couplings significantly complicate component abstraction boundaries, there is not always an obvious or unique correct choice.
