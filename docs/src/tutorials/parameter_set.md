# Data-Driven Design with ParameterSet

In [Building a Component](building_a_component.md) and [Composite Components](composite_components.md), component parameters were written directly into Julia code. For larger designs — or designs that need to vary between fabrication runs, simulation sweeps, or process nodes — it's useful to move parameters out of the source and into external configuration. `ParameterSet` is a mutable parameter source that holds a nested dictionary (typically loaded from YAML) and feeds values into your components by address.

In this tutorial, you'll drive a simple component, then a composite transmon, from a `ParameterSet` instead of hardcoded parameters.

## What You'll Learn

- Creating a `ParameterSet` programmatically or from YAML
- Reading values with dot syntax or `resolve`
- Instantiating components from a `ParameterSet`
- Attaching a `ParameterSet` to a `SchematicGraph`
- Forwarding shared parameters into composite subcomponents
- Auditing which parameters were actually consumed

## Prerequisites

- Completed [Building a Component](building_a_component.md) tutorial
- Completed [Composite Components](composite_components.md) tutorial

## Setup

```julia
using DeviceLayout, .PreferredUnits
using DeviceLayout.SchematicDrivenLayout
```

Every `ParameterSet` contains two required top-level namespaces:

- **`global`** — parameters shared across the design (e.g., version, process node)
- **`components`** — per-component parameter trees

## Creating a ParameterSet

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

ps.components.junction.junction_width = 1μm
ps.components.junction.junction_lead_gap = 1μm
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
    junction_width: 1μm
    junction_lead_gap: 1μm
```

```julia
using YAML  # activates the ParameterSetYAMLExt extension
ps = ParameterSet("design_params.yaml")
```

YAML anchors and merge keys are resolved when the file is loaded, so shared
parameter templates can also be authored directly in YAML:

```yaml
templates:
  qubit: &qubit
    cap_width: 24μm
    cap_length: 520μm
    cap_gap: 30μm

components:
  q1:
    <<: *qubit
    cap_length: 600μm
```

Loaded aliases are detached from one another. Mutating `components.q1` does not
mutate `templates.qubit`.

## Programmatic Templates and Merging

A template can live in any `ParameterSet` namespace, including a separate
parameter-library set. Assigning a scoped `ParameterSet` copies its complete
subtree:

```julia
library = ParameterSet()
library.templates.qubit.cap_width = 24μm
library.templates.qubit.cap_length = 520μm
library.templates.qubit.routing.offsets = [0μm, 25μm]

design = ParameterSet()
design.components.q1 = library.templates.qubit
design.components.q1.cap_length = 600μm
```

The copy is independent. Changing `design.components.q1` or one of its nested
arrays does not mutate `library.templates.qubit`.

Use `merge!` to recursively overlay one or more parameter subtrees:

```julia
process = ParameterSet()
process.components.q1.cap_gap = 28μm

local_overrides = ParameterSet()
local_overrides.components.q1.cap_length = 650μm

merge!(
    design.components.q1,
    process.components.q1,
    local_overrides.components.q1,
)
```

Sources are applied from left to right, so later values win. Namespaces are
merged recursively; when a namespace and leaf occupy the same key, the later
value replaces the earlier one. `merge(a, b, ...)` provides the same behavior
without mutating `a` and returns a detached `ParameterSet`.

## Reading Parameters

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

## Simple Components with ParameterSet

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

This resolves `"components.capacitor"` in the parameter set, extracts leaf parameters, and passes them as keyword arguments to the `MyCapacitor` constructor. Parameters not present in the `ParameterSet` keep their defaults.

Consumed parameters are tracked in `ps.accessed`, which is useful for auditing which parameters were actually used:

```julia
ps.accessed
# => Set(["components.capacitor.finger_length", "components.capacitor.finger_width", ...])
```

## Attaching ParameterSet to a SchematicGraph

Pass the `ParameterSet` when creating a `SchematicGraph` so that all components in the graph can access it:

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
cap1 = set_parameters(
    create_component(MyCapacitor, ps, "components.cap1"),
    "cap1",
)
cap2 = set_parameters(
    create_component(MyCapacitor, ps, "components.cap2"),
    "cap2",
)

# Build schematic
cap1_node = add_node!(g, cap1)
cap2_node = fuse!(g, cap1_node => :p1, cap2 => :p0)

sch = plan(g; log_dir=nothing)
```

## Extracting Final Parameters from a Graph

An attached parameter set is the source document and may contain only
overrides. Use `extract_parameter_set` to obtain a detached set containing the
supported final parameters of the component instances in a constructed graph:

```julia
resolved = extract_parameter_set(g)

resolved.components.cap1.finger_length
resolved.components.cap1.finger_gap  # included even when it came from a default
```

Components are addressed by their unique graph node IDs. Dotted IDs become
nested namespaces, and composite subcomponents are nested below their parent:

```julia
resolved.components.module.q1.island.cap_width
```

The graph's attached `global` and other top-level metadata are copied into the
result, while its source `components` namespace is replaced by the final graph
contents. Composite extraction realizes lazy subgraphs. The result has no
source path or access history and shares no mutable parameter data with the
graph or its attached source.

Extraction retains scalar parameter leaves and ordinary one-dimensional Julia
`Array`s. `NamedTuple`s and dictionaries become namespaces. Unsupported custom
values, including `Point`s and component-valued parameters, are omitted.

## Composite Components with ParameterSet

For composite components, the `ParameterSet` propagates through the graph hierarchy. When you attach a `ParameterSet` to a top-level `SchematicGraph`, it is available inside `_build_subcomponents` via the graph.

With a `ParameterSet`, subcomponent parameters live in the parameter set rather than in the composite struct. The composite only declares parameters that are shared across multiple subcomponents:

```julia
@compdef struct SimpleTransmon <: CompositeComponent
    name = "transmon"
    junction_gap = 12μm  # shared: controls both island gap and junction height
end
```

Define the parameter set with a namespace per subcomponent. Note that `junction_gap` only appears on the composite — it will be forwarded to subcomponents in `_build_subcomponents`:

```julia
ps = ParameterSet()

ps.components.transmon.junction_gap = 12μm

ps.components.transmon.island.cap_width = 24μm
ps.components.transmon.island.cap_length = 520μm
ps.components.transmon.island.cap_gap = 30μm

ps.components.transmon.junction.junction_width = 1μm
ps.components.transmon.junction.junction_lead_gap = 1μm
```

Inside `_build_subcomponents`, use `parameter_set(g)` to access the graph's `ParameterSet`, then `create_component` to instantiate each subcomponent from its subtree. The shared `junction_gap` is read from the parameter set and forwarded to both subcomponents under their respective parameter names using `set_parameters` kwargs:

```julia
function SchematicDrivenLayout._build_subcomponents(tr::SimpleTransmon)
    ps = parameter_set(tr._graph)

    island = create_component(ExampleRectangleIsland, ps, "components.transmon.island")
    # Forward shared parameter from under the parent component
    # No need to count its access here because it has been accessed
    # during the CC construction
    island = set_parameters(island; junction_gap=tr.junction_gap)

    junction = create_component(ExampleSimpleJunction, ps, "components.transmon.junction")
    # Forward shared parameter from parameter set to the junction component
    # under a different parameter name. A missing PS lookup would surface as
    # ParameterKeyError at this call site.
    junction = set_parameters(junction; ground_island_length=ps.components.transmon.junction_gap)

    return (island, junction)
end
```

`create_component(T, ps, address)` resolves the address, extracts leaf parameters via `leaf_params`, and passes them as keyword arguments to the component constructor. Parameters not in the `ParameterSet` keep their defaults.

Create the top-level graph and composite component:

```julia
g = SchematicGraph("chip", ps)

transmon = create_component(SimpleTransmon, ps, "components.transmon")
transmon_node = add_node!(g, transmon)
```

The `ParameterSet` is preserved when graphs are copied — for example, inside `BasicCompositeComponent` or during `_flatten` operations. This means subcomponents at any depth can access the same parameter set.

## Templates-Aliasing for Composite Subcomponents

The `create_component(T, ps, address)` pattern above hardcodes the subcomponent type at each call site. A composite can instead declare its subcomponents in a `templates::NamedTuple` field — the type and any designer-chosen defaults live on the composite, and `ParameterSet` values overlay on top of the template:

```julia
@compdef struct SimpleTransmonTemplated <: CompositeComponent
    name = "transmon"
    junction_gap = 12μm
    templates = (
        island = ExampleRectangleIsland(name="island", cap_width=30μm),  # designer default
        junction = ExampleSimpleJunction(name="junction"),
    )
end
```

Use the three-argument form of `set_parameters` inside `_build_subcomponents` to apply the `ParameterSet` at the subcomponent's address on top of the template. Trailing keyword arguments are composite-level overrides that win over the `ParameterSet`:

```julia
function SchematicDrivenLayout._build_subcomponents(tr::SimpleTransmonTemplated)
    ps = parameter_set(tr._graph)

    island = set_parameters(
        tr.templates.island, ps, "components.$(name(tr)).island";
        junction_gap=tr.junction_gap,
    )

    junction = set_parameters(
        tr.templates.junction, ps, "components.$(name(tr)).junction";
        ground_island_length=tr.junction_gap,
    )

    return (island, junction)
end
```

Precedence is explicit and layered:

1. **Template defaults** — whatever `tr.templates.island` was constructed with (e.g. `cap_width=30μm`).
2. **`ParameterSet` overrides the template** — every leaf under `components.transmon.island` overwrites the matching template field.
3. **Composite overrides the `ParameterSet`** — trailing kwargs to `set_parameters(c, ps, address; …)` always win, so composite invariants (e.g. "the island's `junction_gap` is whatever the composite decides") can never be silently undermined by `ParameterSet` contents.

Typos surface early: if the `ParameterSet` carries a leaf at `components.transmon.island.fictional_param` and `ExampleRectangleIsland` has no such field, `set_parameters(tr.templates.island, ps, ...)` throws `ArgumentError` naming the unknown leaf — rather than silently ignoring it or erroring later inside the constructor.

`set_parameters(c, ps, address)` also has a scoped-view sibling `set_parameters(c, ps.components.transmon.island)` for cases where the scoped `ParameterSet` is already in hand.

## Access Tracking

The `accessed` field tracks which leaf parameters were read, enabling auditing of unused or missing parameters:

```julia
ps = ParameterSet()
ps.components.qubit.cap_width = 300μm
ps.components.qubit.cap_gap = 20μm

# Nothing accessed yet
isempty(ps.accessed)  # => true

# Read a parameter — the fully qualified path is recorded
ps.components.qubit.cap_width                    # => 300μm
"components.qubit.cap_width" in ps.accessed      # => true

# Tracking is shared across scoped views and still fully qualified
sub = ps.components.qubit
sub.cap_gap                                      # => 20μm
"components.qubit.cap_gap" in ps.accessed        # => true
```
