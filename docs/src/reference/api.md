# [Full API Reference](@id api-reference)

## DeviceLayout Core

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
    intersect2d
    union2d
    xor2d
    clip
    Polygons.StyleDict
```

### [Shapes](@id api-shapes)

```@docs
    Circle
    Ellipse
    circular_arc
    draw_pixels
    hatching_unit
    radial_cut
    radial_stub
    simple_cross
    simple_ell
    simple_tee
```

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

#### Cells

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

### [Autofill](@id api-autofill)

```@docs
    Autofill.autofill!
    Autofill.halo
    Autofill.make_halo
```

### [Rendering](@id api-rendering)

```@docs
    render!
    DeviceLayout.adapted_grid
    DeviceLayout.discretize_curve
```

## [Paths](@id api-paths)

```@docs
    Paths.Path
    Paths.α0
    Paths.α1
    Paths.direction
    Paths.pathlength
    Paths.p0
    Paths.p1
    Paths.style0
    Paths.style1
    Paths.discretestyle1
    Paths.contstyle1
    Paths.nextstyle
```

### [Path Manipulation](@id api-path-manipulation)

```@docs
    Paths.setp0!
    Paths.setα0!
    append!(::Path, ::Path)
    attach!(::Path{T}, ::DeviceLayout.GeometryReference{T}, ::DeviceLayout.Coordinate) where {T}
    bspline!
    corner!
    launch!
    meander!
    overlay!
    reconcile!
    Paths.round_trace_transitions!
    simplify
    simplify!
    straight!
    terminate!
    turn!
```

### [Path Intersection](@id api-path-intersection)

```@docs
    Intersect.IntersectStyle
    Intersect.AirBridge
    intersect!
```

### Path Nodes

```@docs
    Paths.Node
    Paths.previous
    Paths.next
    Paths.segment
    Paths.split(::Paths.Node, ::DeviceLayout.Coordinate)
    Paths.style
    Paths.setsegment!
    Paths.setstyle!
```

### [Path Segments](@id api-path-segments)

```@docs
    Paths.Segment
    Paths.Straight
    Paths.Turn
    Paths.Corner
    Paths.CompoundSegment
    Paths.BSpline
```

### [Path Styles](@id api-path-styles)

```@docs
    Paths.Style
    Paths.ContinuousStyle
    Paths.DiscreteStyle
    Paths.Trace
    Paths.CPW
    Paths.Taper
    Paths.Strands
    Paths.NoRender
    Paths.SimpleNoRender
    Paths.SimpleTrace
    Paths.GeneralTrace
    Paths.SimpleCPW
    Paths.GeneralCPW
    Paths.TaperTrace
    Paths.TaperCPW
    Paths.SimpleStrands
    Paths.GeneralStrands
    Paths.CompoundStyle
    Paths.DecoratedStyle
    Paths.PeriodicStyle
    Paths.pin
    Paths.translate
    Paths.undecorated
```

## [Routes](@id api-routes)

```@docs
    Paths.Route
```

### Route rules

```@docs
    Paths.RouteRule
    Paths.BSplineRouting
    Paths.StraightAnd90
    Paths.StraightAnd45
    Paths.CompoundRouteRule
    Paths.SingleChannelRouting
    Paths.RouteChannel
```

### Route drawing

```@docs
    Paths.Path(::Paths.Route, ::Paths.Style)
    Paths.route!
    Paths.reconcile!(::Paths.Path, ::Point, ::Any, ::Paths.RouteRule, ::Any, ::Any)
```

### Route inspection

```@docs
    Paths.p0(::Paths.Route)
    Paths.α0(::Paths.Route)
    Paths.p1(::Paths.Route)
    Paths.α1(::Paths.Route)
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

## Schematic-Driven Layout

### [Components](@id api-components)

```@docs
    SchematicDrivenLayout.AbstractComponent
    SchematicDrivenLayout.Component
    SchematicDrivenLayout.@compdef
    SchematicDrivenLayout.@component
    SchematicDrivenLayout.allowed_rotation_angles
    SchematicDrivenLayout.check_rotation
    SchematicDrivenLayout.create_component
    SchematicDrivenLayout.matching_hooks
    SchematicDrivenLayout.matching_hook
    SchematicDrivenLayout.geometry
    SchematicDrivenLayout.hooks
    SchematicDrivenLayout.default_parameters
    halo(::SchematicDrivenLayout.AbstractComponent, ::Any, ::Any)
    SchematicDrivenLayout.name(::SchematicDrivenLayout.AbstractComponent)
    SchematicDrivenLayout.non_default_parameters
    SchematicDrivenLayout.parameters
    SchematicDrivenLayout.parameter_names
    SchematicDrivenLayout.set_parameters
    SchematicDrivenLayout.base_variant
    SchematicDrivenLayout.flipchip!
    SchematicDrivenLayout.@variant
    SchematicDrivenLayout.@composite_variant
```

#### Built-in Components

```@docs
SchematicDrivenLayout.ArrowAnnotation
SchematicDrivenLayout.BasicComponent
SchematicDrivenLayout.GDSComponent
SchematicDrivenLayout.Spacer
SchematicDrivenLayout.WeatherVane
```

#### Composite Components

```@docs
SchematicDrivenLayout.AbstractCompositeComponent
SchematicDrivenLayout.CompositeComponent
SchematicDrivenLayout.BasicCompositeComponent
SchematicDrivenLayout.components(::SchematicDrivenLayout.CompositeComponent)
SchematicDrivenLayout.flatten(::SchematicDrivenLayout.SchematicGraph)
SchematicDrivenLayout.graph
SchematicDrivenLayout.map_hooks
```

### [Hooks](@id api-hooks)

```@docs
    SchematicDrivenLayout.Hook
    SchematicDrivenLayout.PointHook
    SchematicDrivenLayout.HandedPointHook
    DeviceLayout.hooks(::Path) 
    SchematicDrivenLayout.p0_hook
    SchematicDrivenLayout.p1_hook
    SchematicDrivenLayout.in_direction
    SchematicDrivenLayout.out_direction
    SchematicDrivenLayout.path_in
    SchematicDrivenLayout.path_out
    SchematicDrivenLayout.transformation(::DeviceLayout.PointHook, ::DeviceLayout.PointHook)
    SchematicDrivenLayout.compass
```

### [Schematics](@id api-schematics)

#### Schematic Graph

```@docs
SchematicDrivenLayout.SchematicGraph
SchematicDrivenLayout.ComponentNode
SchematicDrivenLayout.add_node!
SchematicDrivenLayout.fuse!
route!(::SchematicDrivenLayout.SchematicGraph,
    ::Paths.RouteRule,
    ::Pair{SchematicDrivenLayout.ComponentNode, Symbol},
    ::Pair{SchematicDrivenLayout.ComponentNode, Symbol},
    ::Any,
    ::Any)
SchematicDrivenLayout.RouteComponent
attach!(::SchematicDrivenLayout.SchematicGraph,
    ::S,
    ::Pair{T, Symbol},
    ::DeviceLayout.Coordinate
) where {S <: SchematicDrivenLayout.ComponentNode, T <: SchematicDrivenLayout.ComponentNode}
SchematicDrivenLayout.plan
```

#### Schematic

```@docs
SchematicDrivenLayout.Schematic
SchematicDrivenLayout.bounds(::SchematicDrivenLayout.Schematic, ::SchematicDrivenLayout.ComponentNode)
SchematicDrivenLayout.center(::SchematicDrivenLayout.Schematic, ::SchematicDrivenLayout.ComponentNode)
SchematicDrivenLayout.crossovers!
SchematicDrivenLayout.find_components
SchematicDrivenLayout.find_nodes
SchematicDrivenLayout.hooks(::SchematicDrivenLayout.Schematic, ::SchematicDrivenLayout.ComponentNode)
SchematicDrivenLayout.indexof(::SchematicDrivenLayout.ComponentNode, ::SchematicDrivenLayout.SchematicGraph)
SchematicDrivenLayout.origin(::SchematicDrivenLayout.Schematic, ::SchematicDrivenLayout.ComponentNode)
SchematicDrivenLayout.position_dependent_replace!
SchematicDrivenLayout.replace_component!
SchematicDrivenLayout.rotations_valid
SchematicDrivenLayout.transformation(::SchematicDrivenLayout.Schematic, ::SchematicDrivenLayout.ComponentNode)
SchematicDrivenLayout.check!
SchematicDrivenLayout.build!
SchematicDrivenLayout.render!(::SchematicDrivenLayout.AbstractCoordinateSystem, ::SchematicDrivenLayout.Schematic, ::SchematicDrivenLayout.LayoutTarget; kwargs...)
render!(::DeviceLayout.SolidModel, ::SchematicDrivenLayout.Schematic, ::SchematicDrivenLayout.Target; kwargs...)
```

### [Technologies](@id api-technologies)

```@docs
SchematicDrivenLayout.ProcessTechnology
SchematicDrivenLayout.chip_thicknesses
SchematicDrivenLayout.flipchip_gaps
SchematicDrivenLayout.layer_thickness
SchematicDrivenLayout.layer_height
SchematicDrivenLayout.layer_z
SchematicDrivenLayout.level_z
```

### [Targets](@id api-targets)

```@docs
    SchematicDrivenLayout.Target
    SchematicDrivenLayout.LayoutTarget
    SchematicDrivenLayout.ArtworkTarget
    SchematicDrivenLayout.SimulationTarget
    SchematicDrivenLayout.SolidModelTarget
    SchematicDrivenLayout.backing
    SchematicDrivenLayout.facing
    SchematicDrivenLayout.not_simulated
    SchematicDrivenLayout.only_simulated
    SchematicDrivenLayout.not_solidmodel
    SchematicDrivenLayout.only_solidmodel
```

### [PDKs](@id api-pdks)

```@docs
SchematicDrivenLayout.generate_component_definition
SchematicDrivenLayout.generate_component_package
SchematicDrivenLayout.generate_pdk
```
