# ParameterSet

A `ParameterSet` is a mutable parameter source for data-driven design. It holds a nested dictionary of parameters — typically loaded from a YAML file — and provides dot-access syntax for reading and writing values.

Every `ParameterSet` contains two required top-level namespaces:
- **`global`** — parameters shared across the design (e.g., version, process node)
- **`components`** — per-component parameter trees

## Tutorial: Using External Parameters

This tutorial shows how to drive a design from a `ParameterSet` instead of
hardcoding parameter values. We start with simple components, then move to
composite components.

### Setup

```julia
using DeviceLayout, .PreferredUnits
using DeviceLayout.SchematicDrivenLayout
```

### Creating a ParameterSet

The simplest way is to build one programmatically:

```julia
ps = ParameterSet()

# Set global metadata
ps.global.version = 1
ps.global.process_node = "fab_v3"

# Define component parameters using Pair syntax
ps.components.capacitor = ("finger_length" => 150)
ps.components.capacitor.finger_width = 5
ps.components.capacitor.finger_gap = 3
ps.components.capacitor.finger_count = 6

ps.components.junction = ("w_jj" => 1)
ps.components.junction.h_jj = 1
```

If you have the `YAML` package installed, you can load directly from a file:

```yaml
# design_params.yaml
global:
  version: 1
  process_node: fab_v3

components:
  capacitor:
    finger_length: 150
    finger_width: 5
    finger_gap: 3
    finger_count: 6
  junction:
    w_jj: 1
    h_jj: 1
```

```julia
using YAML  # activates the ParameterSetYAMLExt extension
ps = ParameterSet("design_params.yaml")
```

### Reading Parameters

Use dot syntax to navigate the hierarchy:

```julia
ps.global.version              # => 1
ps.components.capacitor        # => ParameterSet scoped to capacitor subtree
ps.components.capacitor.finger_length  # => 150
```

Or use `resolve` with a dot-separated address:

```julia
resolve(ps, "components.capacitor.finger_length")  # => 150
resolve(ps, "components.capacitor")                 # => scoped ParameterSet
```

Extract all leaf parameters at a level as a `NamedTuple`:

```julia
leaf_params(ps.components.capacitor)
# => (finger_length = 150, finger_width = 5, finger_gap = 3, finger_count = 6)
```

### Simple Components with ParameterSet

Suppose you have a component defined with `@compdef`:

```julia
@compdef struct MyCapacitor <: Component
    name = "capacitor"
    finger_length = 100μm
    finger_width = 5μm
    finger_gap = 3μm
    finger_count::Int = 4
end
```

You can instantiate it from the `ParameterSet` using `create_component`:

```julia
cap = create_component(MyCapacitor, ps, "components.capacitor")
```

This resolves `"components.capacitor"` in the parameter set, extracts leaf
parameters, and passes them as keyword arguments to the `MyCapacitor`
constructor. Parameters not present in the `ParameterSet` keep their defaults.

Consumed parameters are tracked in `ps.accessed`, which is useful for auditing
which parameters were actually used:

```julia
ps.accessed
# => Set(["components.capacitor.finger_length", "components.capacitor.finger_width", ...])
```

### Attaching ParameterSet to a SchematicGraph

Pass the `ParameterSet` when creating a `SchematicGraph` so that all components
in the graph can access it:

```julia
g = SchematicGraph("my_design", ps)

# The parameter set is accessible from the graph
g.parameter_set.components.capacitor.finger_length  # => 150
```

A full example with simple components:

```julia
# Load parameters
ps = ParameterSet()
ps.components.cap1 = ("finger_length" => 150)
ps.components.cap1.finger_count = 6
ps.components.cap2 = ("finger_length" => 200)
ps.components.cap2.finger_count = 8

# Create graph with parameter set
g = SchematicGraph("two_caps", ps)

# Create components from parameter set
@component cap1 = create_component(MyCapacitor, ps, "components.cap1")
@component cap2 = create_component(MyCapacitor, ps, "components.cap2")

# Build schematic
cap1_node = add_node!(g, cap1)
cap2_node = fuse!(g, cap1_node => :p1, cap2 => :p0)

sch = plan(g; log_dir=nothing)
```

### Composite Components with ParameterSet

For composite components, the `ParameterSet` propagates through the graph
hierarchy. When you attach a `ParameterSet` to a top-level `SchematicGraph`, it
is available inside `_build_subcomponents` via the graph.

Consider a composite transmon with island and junction subcomponents:

```julia
@compdef struct SimpleTransmon <: CompositeComponent
    name = "transmon"
    cap_width = 24μm
    cap_length = 520μm
    cap_gap = 30μm
    junction_gap = 12μm
    w_jj = 1μm
    h_jj = 1μm
end
```

Define the parameter set with nested component trees — including subcomponent
parameters under the transmon namespace:

```julia
ps = ParameterSet()

# Top-level transmon parameters
ps.components.transmon = ("cap_width" => 24)
ps.components.transmon.cap_length = 520
ps.components.transmon.cap_gap = 30
ps.components.transmon.junction_gap = 12

# Subcomponent parameters nested under transmon
ps.components.transmon.island = ("cap_width" => 24)
ps.components.transmon.island.cap_length = 520
ps.components.transmon.island.cap_gap = 30
ps.components.transmon.island.junction_gap = 12

ps.components.transmon.junction = ("w_jj" => 1)
ps.components.transmon.junction.h_jj = 1
ps.components.transmon.junction.h_ground_island = 12
```

Inside `_build_subcomponents`, use the graph's `parameter_set` to create
subcomponents from their respective parameter subtrees:

```julia
function SchematicDrivenLayout._build_subcomponents(tr::SimpleTransmon)
    ps = parameter_set(tr._graph)

    if !isnothing(ps)
        # Create subcomponents from parameter set subtrees
        @component island = create_component(
            ExampleRectangleIsland, ps, "components.transmon.island"
        )
        @component junction = create_component(
            ExampleSimpleJunction, ps, "components.transmon.junction"
        )
    else
        # Fallback to direct parameter forwarding
        @component island = ExampleRectangleIsland(
            cap_width=tr.cap_width, cap_length=tr.cap_length,
            cap_gap=tr.cap_gap, junction_gap=tr.junction_gap,
        )
        @component junction = ExampleSimpleJunction(
            w_jj=tr.w_jj, h_jj=tr.h_jj,
            h_ground_island=tr.junction_gap,
        )
    end

    return (island, junction)
end
```

When a `ParameterSet` is attached, each subcomponent is instantiated from its
own subtree (`"components.transmon.island"`, `"components.transmon.junction"`).
The fallback path preserves backward compatibility for cases where no
`ParameterSet` is provided.

Create the top-level graph and the composite component:

```julia
g = SchematicGraph("chip", ps)

transmon = create_component(SimpleTransmon, ps, "components.transmon")
transmon_node = add_node!(g, transmon)
```

The `ParameterSet` is preserved when graphs are copied — for example, inside
`BasicCompositeComponent` or during `_flatten` operations. This means
subcomponents at any depth can access the same parameter set.

### Access Tracking

The `accessed` field tracks which leaf parameters were read, enabling auditing
of unused or missing parameters:

```julia
ps = ParameterSet()
ps.components.qubit = ("cap_width" => 300)
ps.components.qubit.cap_gap = 20

# Nothing accessed yet
isempty(ps.accessed)  # => true

# Read a parameter
ps.components.qubit.cap_width  # => 300
"cap_width" in ps.accessed     # => true

# Tracking is shared across scoped views
sub = ps.components.qubit
sub.cap_gap                    # => 20
"cap_gap" in ps.accessed       # => true
```

## API Reference

```@docs
DeviceLayout.ParameterSet
DeviceLayout.resolve
DeviceLayout.leaf_params
```
