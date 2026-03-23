# [Geometry-Level Layout API Reference](@id api-reference)

### [Units](@id api-units)

```@docs
    DeviceLayout.PreferredUnits
    DeviceLayout.set_unit_preference!
    DeviceLayout.Coordinate
    DeviceLayout.UPREFERRED
    DeviceLayout.PreferMicrons.UPREFERRED
    DeviceLayout.PreferNoUnits.UPREFERRED
```

### [Points](@id api-points)

```@docs
    DeviceLayout.PointTypes
    Points.Point
    Points.getx
    Points.gety
    Points.lowerleft(::AbstractArray{Point{T}}) where T
    Points.upperright(::AbstractArray{Point{T}}) where T
```

### [AbstractGeometry](@id api-abstractgeometry)

```@docs
    DeviceLayout.AbstractGeometry
    coordinatetype
    bounds(::DeviceLayout.AbstractGeometry)
    center(::DeviceLayout.AbstractGeometry)
    footprint
    lowerleft(::DeviceLayout.GeometryEntity)
    upperright(::DeviceLayout.GeometryEntity)
    transform
    findbox
    mbr_spatial_index
```

### [GeometryEntity](@id api-geometryentity)

```@docs
    DeviceLayout.GeometryEntity
    DeviceLayout.to_polygons
    halo(::GeometryEntity, ::Any, ::Any)
```

#### [Entity Styles](@id api-entitystyle)

```@docs
    DeviceLayout.GeometryEntityStyle
    DeviceLayout.StyledEntity
    DeviceLayout.entity
    DeviceLayout.style(::DeviceLayout.StyledEntity)
    DeviceLayout.styled
    DeviceLayout.unstyled
    DeviceLayout.unstyled_type
    DeviceLayout.Plain
    DeviceLayout.MeshSized
    DeviceLayout.meshsized_entity
    DeviceLayout.NoRender
    DeviceLayout.OptionalStyle
    DeviceLayout.optional_entity
    DeviceLayout.ToTolerance
```

### [GeometryStructure](@id api-geometrystructure)

```@docs
    DeviceLayout.GeometryStructure
    elements(::DeviceLayout.GeometryStructure)
    elementtype(::DeviceLayout.GeometryStructure)
    element_metadata(::DeviceLayout.GeometryStructure)
    flatten(::DeviceLayout.GeometryStructure)
    Base.getindex(::DeviceLayout.GeometryStructure, ::AbstractString, ::Integer)
    map_metadata
    map_metadata!
    name(::DeviceLayout.GeometryStructure)
    refs(::DeviceLayout.GeometryStructure)
    reset_uniquename!
    uniquename
```

### [GeometryReference](@id api-geometryreference)

```@docs
    DeviceLayout.GeometryReference
    StructureReference
    ArrayReference
    Base.copy(::DeviceLayout.GeometryReference)
    Base.getindex(::DeviceLayout.GeometryReference, ::AbstractString, ::Integer)
    aref
    flatten(::DeviceLayout.GeometryReference)
    flat_elements
    layer_inclusion
    sref
    structure
    transformation(::DeviceLayout.GeometryReference)
    transformation(::DeviceLayout.GeometryStructure, ::DeviceLayout.GeometryReference)
    transformation(c::DeviceLayout.GeometryStructure, d::DeviceLayout.GeometryReference, e::DeviceLayout.GeometryReference, f::DeviceLayout.GeometryReference...)
    origin(::DeviceLayout.GeometryReference)
    mag(::DeviceLayout.GeometryReference)
    rotation(::DeviceLayout.GeometryReference)
    xrefl(::DeviceLayout.GeometryReference)
```

### [Transformations](@id api-transformations)

```@docs
    CoordinateTransformations.compose
    CoordinateTransformations.Translation
    Reflection
    XReflection
    YReflection
    Rotation
    RotationPi
    ScaledIsometry
    centered
    magnify
    reflect_across_line
    reflect_across_xaxis
    rotate
    rotate90
    translate
    +(::DeviceLayout.AbstractGeometry, ::Point)
    -(::DeviceLayout.AbstractGeometry, ::Point)
    *(::DeviceLayout.AbstractGeometry, a::Real)
    /(::DeviceLayout.AbstractGeometry, a::Real)
    isapprox_angle
    isapprox_cardinal
    mag
    origin
    preserves_angles
    rotated_direction
    rotation
    DeviceLayout.Transformations.rounding_safe
    xrefl
```

#### Alignment

```@docs
    Align.above
    Align.below
    Align.leftof
    Align.rightof
    Align.flushbottom
    Align.flushtop
    Align.flushleft
    Align.flushright
    Align.centered_on
    Align.aligned_to
```

### [Polygons](@id api-polygons)

```@docs
    DeviceLayout.AbstractPolygon
    Polygon
    Polygon(::AbstractVector{Point{T}}) where {T}
    Polygon(::Point, ::Point, ::Point, ::Point...)
    Rectangle
    Polygons.area
    bounds
    circle_polygon
    gridpoints_in_polygon
    offset
    perimeter
    points
    sweep_poly
    unfold
    Polygons.Rounded
```

#### Polygon clipping

```@docs
    Polygons.ClippedPolygon
    difference2d
    difference2d_layerwise
    intersect2d
    intersect2d_layerwise
    union2d
    union2d_layerwise
    xor2d
    xor2d_layerwise
    clip
    clip_tiled
    Polygons.StyleDict
```

#### [Curvilinear geometry](@id api-curvilinear)

```@docs
    CurvilinearPolygon
    CurvilinearRegion
    Curvilinear.edge_type_at_vertex
    Curvilinear.line_arc_cornerindices
```

### [Shapes](@id api-shapes)

```@docs
    Circle
    Ellipse
```

See [Shapes](./shapes.md).

### [Coordinate Systems](@id api-coordinate-systems)

```@docs
    DeviceLayout.AbstractCoordinateSystem
    CoordinateSystem
    CoordinateSystemReference
    CoordinateSystemArray
    SemanticMeta
    addref!
    addarr!
    DeviceLayout.default_meta_map
    flatten!(::DeviceLayout.AbstractCoordinateSystem)
    gdslayers(::DeviceLayout.GeometryStructure)
    layer
    layerindex
    layername
    level
    place!
```

#### [Cells](@id api-cells)

```@docs    
    Cell
    Cell(::AbstractString)
    Cell(::CoordinateSystem{S}) where {S}
    Cells.dbscale(::Cell)
    Cells.dbscale(::Cell, ::Cell, ::Cell...)
    CellArray
    CellReference
    GDSMeta
    GDSWriterOptions
    gdslayers(::Cell)
    render!(::Cell, ::Polygon, ::GDSMeta)
    render!(::Cell, ::DeviceLayout.GeometryStructure)
    DeviceLayout.save(::File{format"GDS"}, ::Cell, ::Cell...)
    DeviceLayout.load(::File{format"GDS"})
    traverse!
    order!
```

### [Texts](@id api-texts)

```@docs
    Texts.Text
    text!
```

#### PolyText

```@docs
    DotMatrix
    PolyTextComic
    PolyTextSansMono
    polytext
    polytext!
    characters_demo
    scripted_demo
    referenced_characters_demo
```

### [Rendering](@id api-rendering)

```@docs
    render!
    DeviceLayout.adapted_grid
    DeviceLayout.discretize_curve
```

## [SolidModels](@id api-solidmodels)

```@docs
    SolidModel
    SolidModels.SolidModelKernel
    SolidModels.attributes
    SolidModels.to_primitives
    render!(::SolidModel, ::CoordinateSystem; kwargs...)
    SolidModels.save(::File, ::SolidModel)
```

### Physical Groups

```@docs
    SolidModels.PhysicalGroup
    SolidModels.dimtags
    SolidModels.entitytags
    SolidModels.bounds3d
```

### Postrendering

```@docs
    SolidModels.box_selection
    SolidModels.difference_geom!
    SolidModels.extrude_z!
    SolidModels.fragment_geom!
    SolidModels.get_boundary
    SolidModels.intersect_geom!
    SolidModels.remove_group!
    SolidModels.restrict_to_volume!
    SolidModels.revolve!
    SolidModels.set_periodic!
    SolidModels.translate!
    SolidModels.union_geom!
    SolidModels.staple_bridge_postrendering
```

### Meshing

```@docs
    SolidModels.MeshingParameters
    SolidModels.mesh_order
    SolidModels.mesh_scale
    SolidModels.mesh_grading_default
    SolidModels.set_gmsh_option
    SolidModels.get_gmsh_number
    SolidModels.get_gmsh_string
    SolidModels.mesh_control_points
    SolidModels.mesh_control_trees
    SolidModels.add_mesh_size_point
    SolidModels.finalize_size_fields!
    SolidModels.clear_mesh_control_points!
    SolidModels.reset_mesh_control!
```