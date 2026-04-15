# ParameterSet

A `ParameterSet` is a mutable parameter source for data-driven design. It holds a nested dictionary of parameters - typically loaded from a YAML file - and provides dot-access syntax for reading and writing values.

Every `ParameterSet` contains two required top-level namespaces:
- **`global`** - parameters shared across the design (e.g., version, process node)
- **`components`** - per-component parameter trees

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

# Define component parameters with units
ps.components.capacitor.finger_length = 150μm
ps.components.capacitor.finger_width = 5μm
ps.components.capacitor.finger_gap = 3μm
ps.components.capacitor.finger_count = 6

ps.components.junction.w_jj = 1μm
ps.components.junction.h_jj = 1μm
```

If you have the `YAML` package installed, you can load directly from a file:

```yaml
# design_params.yaml
global:
  version: 1
  process_node: fab_v3

components:
  capacitor:
    finger_length: 150μm
    finger_width: 5μm
    finger_gap: 3μm
    finger_count: 6
  junction:
    w_jj: 1μm
    h_jj: 1μm
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
ps.components.capacitor.finger_length  # => 150μm
```

Or use `resolve` with a dot-separated address:

```julia
resolve(ps, "components.capacitor.finger_length")  # => 150μm
resolve(ps, "components.capacitor")                 # => scoped ParameterSet
```

Extract all leaf parameters at a level as a `NamedTuple`:

```julia
leaf_params(ps.components.capacitor)
# => (finger_length = 150μm, finger_width = 5μm, finger_gap = 3μm, finger_count = 6)
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
g.parameter_set.components.capacitor.finger_length  # => 150μm
```

A full example with simple components:

```julia
# Load parameters
ps = ParameterSet()
ps.components.cap1.finger_length = 150μm
ps.components.cap1.finger_count = 6
ps.components.cap2.finger_length = 200μm
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

With a `ParameterSet`, subcomponent parameters live in the parameter set
rather than in the composite struct. The composite only declares parameters
that are shared across multiple subcomponents:

```julia
@compdef struct SimpleTransmon <: CompositeComponent
    name = "transmon"
    junction_gap = 12μm  # shared: controls both island gap and junction height
end
```

Define the parameter set with a namespace per subcomponent. Note that
`junction_gap` only appears on the composite - it will be forwarded to
subcomponents in `_build_subcomponents`:

```julia
ps = ParameterSet()

ps.components.transmon.junction_gap = 12μm

ps.components.transmon.island.cap_width = 24μm
ps.components.transmon.island.cap_length = 520μm
ps.components.transmon.island.cap_gap = 30μm

ps.components.transmon.junction.w_jj = 1μm
ps.components.transmon.junction.h_jj = 1μm
```

Inside `_build_subcomponents`, use `parameter_set(g)` to access the graph's
`ParameterSet`, then `create_component` to instantiate each subcomponent from
its subtree. The shared `junction_gap` is read from the composite instance and
forwarded to both subcomponents under their respective parameter names:

```julia
function SchematicDrivenLayout._build_subcomponents(tr::SimpleTransmon)
    ps = parameter_set(tr._graph)

    @component island = create_component(
        ExampleRectangleIsland, ps, "components.transmon.island"
    )
    # Forward shared parameter from parameter set to island
    island = set_parameters(island; junction_gap=ps.components.transmon.junction_gap)

    @component junction = create_component(
        ExampleSimpleJunction, ps, "components.transmon.junction"
    )
    # Forward shared parameter under the subcomponent's own name
    junction = set_parameters(junction; h_ground_island=ps.components.transmon.junction_gap)

    return (island, junction)
end
```

`create_component(T, ps, address)` resolves the address, extracts leaf
parameters via `leaf_params`, and passes them as keyword arguments to the
component constructor. Parameters not in the `ParameterSet` keep their defaults.

Create the top-level graph and composite component:

```julia
g = SchematicGraph("chip", ps)

transmon = create_component(SimpleTransmon, ps, "components.transmon")
transmon_node = add_node!(g, transmon)
```

The `ParameterSet` is preserved when graphs are copied - for example, inside
`BasicCompositeComponent` or during `_flatten` operations. This means
subcomponents at any depth can access the same parameter set.

### Access Tracking

The `accessed` field tracks which leaf parameters were read, enabling auditing
of unused or missing parameters:

```julia
ps = ParameterSet()
ps.components.qubit.cap_width = 300μm
ps.components.qubit.cap_gap = 20μm

# Nothing accessed yet
isempty(ps.accessed)  # => true

# Read a parameter
ps.components.qubit.cap_width  # => 300μm
"cap_width" in ps.accessed     # => true

# Tracking is shared across scoped views
sub = ps.components.qubit
sub.cap_gap                    # => 20μm
"cap_gap" in ps.accessed       # => true
```

## API Reference

```@docs
DeviceLayout.ParameterSet
DeviceLayout.resolve
DeviceLayout.leaf_params
```
