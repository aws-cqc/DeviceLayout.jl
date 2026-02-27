# How to Connect Components

This guide shows how to connect components in a schematic.

## Using fuse!

```julia
using DeviceLayout.SchematicDrivenLayout

g = SchematicGraph("example")

# Add first component
node1 = add_node!(g, Component1())

# Connect second component to first
node2 = fuse!(g, node1 => :p1, Component2() => :p0)

# Connect existing nodes
node3 = add_node!(g, Component3())
fuse!(g, node2 => :output, node3 => :input)
```

## Default Hook Matching

Some components define default hooks:

```julia
# If matching_hooks is defined, you can omit hook names
node2 = fuse!(g, node1, Component2())
```

## Fixed Positioning

```julia
# Use Spacer for fixed positions
spacer = add_node!(g, Spacer(p1=Point(5mm, 3mm)))
fuse!(g, spacer => :p1_north, my_component => :south)
```

## Ad-Hoc Hooks

```julia
# Connect with custom hook positions
fuse!(g, 
    node1 => PointHook(Point(100μm, 50μm), 0°),
    Component2() => :p0
)
```

## See Also

- [Routing Strategies](routing_strategies.md)
- [Tutorial: Schematic Basics](../../tutorials/schematic_basics.md)
