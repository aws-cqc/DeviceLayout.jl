# Getting Started

Welcome to DeviceLayout.jl! This section will help you get up and running with the package.

## What is DeviceLayout.jl?

DeviceLayout.jl is a Julia package for computer-aided design (CAD) of quantum integrated circuits developed at the AWS Center for Quantum Computing. It supports:

- **2D layout generation** for fabrication (GDSII export)
- **3D model generation** for electromagnetic simulation
- **Schematic-driven design** for managing complex devices with many components

## Installation

DeviceLayout.jl requires Julia v1.10 or later. You can follow [these instructions](https://julialang.org/install/) to install Julia.

Navigate to the directory where you want to create your project environment, and run `julia` to start the Julia REPL (read-eval-print loop). From the REPL, install DeviceLayout.jl using the built-in package manager, [Pkg.jl](https://pkgdocs.julialang.org/v1/getting-started/):

```julia
julia> ] # Pressing ] in the Julia REPL activates the Pkg REPL mode
pkg> activate . # Activates an environment in the current directory
pkg> add DeviceLayout # Adds DeviceLayout.jl to the environment
pkg> add FileIO # You'll want FileIO too, to save output files
```

!!! tip "Use Project Environments"
    We recommend [using an environment for each project](https://julialang.github.io/Pkg.jl/v1/environments/) rather than installing packages in the default environment. This ensures reproducibility and avoids version conflicts.

Leave the Pkg REPL mode by pressing backspace with an empty prompt.

To verify that DeviceLayout.jl is installed correctly, run:

```julia
using DeviceLayout, DeviceLayout.PreferredUnits

# Create a simple rectangle
r = centered(Rectangle(10μm, 20μm))

# Create a cell and render the rectangle
my_cell = Cell("test", nm)
render!(my_cell, r, GDSMeta(0))

# Check that it worked
println("Success! Cell contains $(length(elements(my_cell))) element(s).")
```

You should see:
```
Success! Cell contains 1 element(s).
```

## Workflow tips

This section covers setting up your development environment for efficient work with DeviceLayout.jl.

### Recommended IDE: Visual Studio Code

[Visual Studio Code](https://code.visualstudio.com/) with the [Julia extension](https://www.julia-vscode.org/) is the recommended development environment:

1. Install VS Code from [code.visualstudio.com](https://code.visualstudio.com/)
2. Open VS Code and go to Extensions (`Ctrl+Shift+X` / `Cmd+Shift+X` on Mac)
3. Search for "Julia" and install the official Julia extension

### GDS Viewer: KLayout

[KLayout](https://www.klayout.de/) is a free (GPL v2+) GDS viewer and editor. KLayout detects changes to open files and asks whether to reload them (`Ctrl-R` / `Cmd-R`), making it easy to use as a fast previewer alongside DeviceLayout.jl.

### Geometry Previews in VS Code

For quick geometry display, you can also use the integrated REPL provided by the VS Code Julia extension (`Alt+J Alt+O` / `Option+J Option+O`). When a `Cell` or `CoordinateSystem` is returned by REPL execution, it will be displayed in a separate tab:

```bash
# In the REPL, just enter the variable name to display it
julia> my_cell
```

You can zoom in and out to inspect details by holding `Command` (Mac) or `Alt` and scrolling.

### Use Functions, Not Scripts

Since Julia has a just-in-time compiler, the first execution of code takes longer due to compilation. Subsequent runs in the same session are much faster. To take advantage of this:

**Don't** run scripts from the command line each time:
```bash
# Slow: Recompiles everything each time
julia my_cad_script.jl
```

**Do** use functions and `include` in a persistent REPL session:
```julia
# my_cad.jl
using DeviceLayout, DeviceLayout.PreferredUnits, FileIO

function subroutine_1()
    # do some thing
end

function subroutine_2(result_1)
    # do some other thing
end

function main()
    result_1 = subroutine_1()
    result_2 = subroutine_2(result_1)
    # ... everything else...
    return save("output.gds", final_result)
end

main()
```

Then in your REPL:
```bash
julia> include("my_cad.jl")  # First run: slow (compilation)
julia> include("my_cad.jl")  # Second run: fast!
```

Even if you edit some code in between runs, as little as possible will be recompiled each time you run it.

### Use Revise.jl for Development

Install [Revise.jl](https://timholy.github.io/Revise.jl/stable/) in your default environment by starting a REPL with `julia` and running `] add Revise`. Revise.jl automatically tracks and reloads code changes without restarting Julia:

```julia
using Revise
includet("my_cad.jl")  # Use includet instead of include
# Now edit my_cad.jl, save, and your changes are automatically available!
```

This is especially useful when developing components or PDKs.

When you start Julia in the default environment with `julia` and then activate your project environment, packages from the default environment will still be available. It's useful to add development tools with few dependencies, such as Revise.jl, to the default environment, so that you don't have to install them for every project.

!!! tip "Reproducibility with stacked environments"
    You will sometimes want to run code without this environment stack to make sure everything you do is reproducible given only your `Project.toml`. To start Julia using only your project environment, use `julia --project=<project_dir>` with the appropriate directory.

### Avoid global variables

Code in global scope typically runs slower than code in functions. Wrap your CAD code in functions:

```julia
# Slow
cr = Cell("rect")
r = centered(Rectangle(20μm, 40μm))
render!(cr, r, GDSMeta(1))

# Fast
function make_rect_cell()
    cr = Cell("rect")
    r = centered(Rectangle(20μm, 40μm))
    render!(cr, r, GDSMeta(1))
    return cr
end
cr = make_rect_cell()
```

If you have to use a global variable, declare it with `const` so that the compiler knows the type will not change.

For more performance tips, see [the Julia manual](https://docs.julialang.org/en/v1/manual/performance-tips/).

## Which section should I read next?

- **Want to learn systematically?** Head to the [Tutorials](@ref tutorials-index).
- **Have a specific task in mind?** Check the [How-To Guides](@ref how-to-index).
- **Want to understand the concepts?** Read the [Concepts](@ref concepts-index) section.
- **Looking for API details?** Browse the [Reference](@ref reference-index).
