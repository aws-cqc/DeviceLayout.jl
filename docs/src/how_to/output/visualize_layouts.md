# How to Visualize Layouts

This guide shows different ways to view your layouts.

## VS Code Preview

In the Julia extension's REPL, display a cell:

```julia
julia> my_cell  # Shows in plot pane
```

Zoom with `Cmd+scroll` (Mac) or `Alt+scroll` (Windows/Linux).

## Save to SVG

```julia
using FileIO

save("layout.svg", cell)

# Custom layer colors
save("layout.svg", cell;
    layercolors=Dict(
        0 => (0, 0, 0, 1),      # Black
        1 => (1, 0, 0, 1),      # Red
        2 => (0, 0, 1, 0.5),    # Semi-transparent blue
    )
)
```

## Save to PNG

```julia
save("layout.png", cell, width=1024, height=1024)
```

## KLayout (External)

1. Save to GDS: `save("layout.gds", cell)`
2. Open in KLayout (auto-refreshes on file changes)

## Jupyter/IJulia

Cells automatically display when returned:

```julia
cell  # Displays inline
```

## See Also

- [Export to GDS](export_gds.md)
- [IDE Setup](../../getting_started/workflow_setup.md)
