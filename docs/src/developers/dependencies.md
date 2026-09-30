# [Dependencies and Integration Points](@id dev-dependencies)

What each external dependency is used for, where it enters the code, and what to watch when
upgrading it. Compat bounds live in `Project.toml`; `Aqua.test_deps_compat` requires one for
every non-stdlib dependency, and `Aqua.test_stale_deps` fails if a listed dependency is no
longer imported.

## Geometry kernels

### Clipper (`Clipper.jl`)

All 2D polygon Booleans (`union2d`, `difference2d`, `intersect2d`, `xor2d`), offsetting
(`offset`, hence `halo`), and `ClippedPolygon` go through the C++ Clipper library via
`Clipper.jl`'s `ccall` wrapper. Entry points are in `src/clipping.jl` and `Polygons.offset`.

- Clipper works on `Int64` coordinates. `clipperize` converts inputs to femtometers and
  rounds; `declipperize` converts back.
- Two global handles (`_clip`, `_coffset`) are created in `__init__` and reused. Clipper
  itself is not thread-safe through these handles.
- Clipper discards curve information. Inputs are normalized to polygons before clipping.
  `Curvilinear.recover_curves` re-identifies arcs and B-splines in Clipper output by provenance
  so that `*_curved` Booleans can keep exact curves for 3D rendering.
- Polygons with holes come back as a contour tree. `to_polygons(::ClippedPolygon)` serializes
  them with keyhole cuts for GDS; operations on `ClippedPolygon`s extract contours directly
  from the tree for efficiency.

### Gmsh and Open CASCADE (`Gmsh.jl`, `gmsh_jll`)

`SolidModels` drives a single Gmsh session through `Gmsh.jl`'s Julia API (`gmsh.model.occ`
for the Open CASCADE kernel, `gmsh.model.geo` for `GmshNative`). Open CASCADE comes bundled
inside `gmsh_jll`; there is no separate OCC dependency.

- Gmsh has global state: a set of named models with one current model, one option set, one
  mesh-size callback. `SolidModel(name)` adds a Gmsh model of that name and makes it current
  (erroring if the name exists, unless `overwrite=true`). Tests use the `QuietGmshSetup`
  snippet to initialize and silence it.
- Gmsh entity tags are integers assigned by the kernel; `PhysicalGroup`s are how DeviceLayout
  keeps track of which entities mean what across Booleans and fragmentation.
- Mesh sizing is implemented as a `gmsh.model.mesh.setSizeCallback` closure backed by a
  `KDTree` (`NearestNeighbors`, `Distances`) of control points. The callback dictionary is
  explicit rather than a closure because of a limitation on Apple silicon.
- `gmsh_jll` upgrades can change fragmentation behavior and mesh output. The
  `SingleTransmon` example test is the main end-to-end guard.
- Output formats: `.msh` (Gmsh, for Palace), `.msh2`, `.stp`/`.brep` (OCC, for other CAD
  tools), and anything else `gmsh.write()` accepts (e.g. `.xao`). Saving goes through FileIO
  (see below) or `SolidModels.save`.

## Output and input

### FileIO

`save`/`load` dispatch on file extension via FileIO. `__init__` registers `format"GDS"` (with
magic bytes, and both load and save), `format"DXF"`, `format"STEP"`, `format"BREP"`,
`format"MSH2"`, and adds DeviceLayout as a saver for the already-registered `MSH`, `SVG`,
`PDF`, `EPS`, and `PNG` formats. A new format needs a registration here **and** in
`precompile.jl` if the precompile workload writes it.

### Cairo (`Cairo.jl`) and ColorSchemes

`backends/graphics.jl` renders `Cell`s to SVG/PDF/EPS/PNG and provides the `show` methods
that display cells inline in notebooks and VS Code. Colors come from `ColorSchemes`
(Glasbey palettes, light and dark themes). Text uses Cairo's toy text API. These outputs are
not part of the versioning contract (see [What counts as breaking?](@ref dev-breaking)).

### Python and ezdxf

The DXF backend writes a small Python script that calls
[ezdxf](https://ezdxf.readthedocs.io/) and runs it with a user-supplied interpreter
(`save("file.dxf", cell, "python3")`). There is no PyCall/PythonCall dependency. CI installs
`requirements.txt` to exercise it. If DXF support is ever needed without Python, the
polygons-to-`LWPOLYLINE` mapping in `backends/dxf.jl` is small enough to reimplement natively.

## Numerics

### Unitful and Preferences

Every coordinate may carry a `Unitful.Length`. `src/units.jl` uses `Preferences` to pick the
default unit at compile time (`PreferNanometers` by default) and defines the `UPREFERRED`
constant everything else uses. Custom `ForwardDiff` methods there let derivatives work
through `Quantity`s; `Aqua.test_piracies` is told to treat that one method as our own.
Upgrades to Unitful occasionally change promotion rules for mixed-unit arithmetic; the
`μm2nm`-style constants in the test snippet exist to catch that.

### StaticArrays and CoordinateTransformations

`Point{T}` is a `FieldVector{2,T}`, so it gets vector arithmetic and broadcasting for free.
`ScaledIsometry` is an `AbstractAffineMap` from CoordinateTransformations; `Translation`,
`LinearMap`, and `AffineMap` are re-exported and used as fallbacks when a composition isn't
angle-preserving.

### ForwardDiff, Interpolations, Optim, QuadGK, Memoization

All in service of paths, mostly B-splines:

- `ForwardDiff` gives tangents and curvature of any segment from its `seg(t)` function, so
  new segment types must be written with generic arithmetic.
- `Interpolations` implements the B-spline itself and the arc-length interpolation used to
  reparameterize by path length; also used by `discretize_curve` and offset segments.
- `Optim` fits B-spline tangents (`bspline_optimization.jl`), solves for taper geometry, and
  is used in `SolidModels` rendering.
- `QuadGK` integrates arc length.
- `Memoization` caches B-spline optimization results in a `ThreadSafeDict`.

### SpatialIndexing and IntervalTrees

`SpatialIndexing` provides the R-tree used for tiled clipping, `split_t_junctions!`, point
deduplication in `SolidModels`, and `ConformalRender`. `IntervalTrees` backs gridpoint-in-polygon
operations (autofill/raster) as well as the sweep in `Intersect` for finding path crossings.

## Schematic layer

- `Graphs` + `MetaGraphs`: `SchematicGraph` is a `MetaGraph` whose vertex and edge properties
  hold components and hook pairings. `GraphMakie` (weak dependency, `ext/SchematicGraphMakieExt.jl`)
  adds plotting.
- `YAML` (weak dependency, `ext/ParameterSetYAMLExt.jl`): `ParameterSet` file I/O.
- `NamedTupleTools`, `Accessors`: recursive parameter merging and immutable updates.
- `LoggingExtras`: the tee/filter loggers `SchematicDrivenLayout` uses to produce a per-build
  log file alongside console output.
- `PkgTemplates` and `Pkg`: `generate_pdk` and `generate_component_package` create new
  packages from `templates/*.jlt`. PkgTemplates has had breaking minor releases; test
  `test_pdktools.jl` when bumping it.

## Related projects

- **[Palace](https://awslabs.github.io/palace/stable/)** is the finite-element solver
  DeviceLayout's `SolidModel` output is designed for. DeviceLayout does not depend on
  Palace; the interface is the `.msh` file plus physical-group names that a Palace config
  refers to. `examples/SingleTransmon` shows the hand-off. Changes to physical-group naming
  conventions therefore affect users' Palace configs and should be treated as breaking.
- **PDKs** are separate Julia packages, typically in a private registry, that depend on
  DeviceLayout. `ExamplePDK` inside this repository is the reference pattern (see
  [PDKs](@ref pdk-architecture)). Downstream PDK test suites are the best available integration
  test for a DeviceLayout change; run them before a release when you can.
