# [Developer Guide](@id developer-index)

This section is for developers contributing to DeviceLayout.jl or building extensions.

## Development Setup

### Clone and Setup

```bash
git clone https://github.com/aws-cqc/DeviceLayout.jl.git
cd DeviceLayout.jl
julia --project -e 'using Pkg; Pkg.instantiate()'
```

### Run Tests

```bash
julia --project -e 'using Pkg; Pkg.test()'
```

### Build Documentation Locally

```bash
cd docs
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project make.jl
```

Open `docs/build/index.html` in a browser.

## Code Organization

```
src/
├── DeviceLayout.jl          # Main module
├── points.jl                # Point types
├── polygons.jl              # Polygon types
├── rectangles.jl            # Rectangle type
├── cells.jl                 # Cell/CellReference
├── transform.jl             # Transformations
├── paths/                   # Path system
│   ├── paths.jl             # Path type
│   ├── routes.jl            # Routing
│   └── contstyles/          # Continuous styles
├── render/                  # Rendering system
├── schematics/              # Schematic-driven layout
│   ├── SchematicDrivenLayout.jl
│   ├── schematics.jl        # Graph/Schematic
│   ├── components/          # Component system
│   └── ExamplePDK/          # Example PDK
├── solidmodels/             # 3D geometry
└── backends/                # File I/O
```

## Contributing Guidelines

See [CONTRIBUTING.md](https://github.com/aws-cqc/DeviceLayout.jl/blob/main/CONTRIBUTING.md).

### Code Style

- Use [JuliaFormatter](https://domluna.github.io/JuliaFormatter.jl/stable/)
- Run `julia scripts/format.jl` before committing

### Testing

- Add tests for new functionality in `test/`
- Ensure all tests pass before PR

### Documentation

- Add docstrings to public functions
- Update tutorials/how-to guides as needed

## Architecture Decisions

- [ADR-001: Unit System](adr/units.md)
- [ADR-002: Schematic Architecture](adr/schematics.md)

## See Also

- [CHANGELOG](https://github.com/aws-cqc/DeviceLayout.jl/blob/main/CHANGELOG.md)
- [GitHub Issues](https://github.com/aws-cqc/DeviceLayout.jl/issues)
