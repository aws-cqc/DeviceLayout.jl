module DeviceLayout
using Random
using LinearAlgebra
using ForwardDiff
using FileIO
using UUIDs
include("units.jl")
export PreferredUnits

import StaticArrays
import Clipper
import Clipper: libcclipper

import Base: length, show, eltype
import CoordinateTransformations:
    AffineMap, LinearMap, Translation, Transformation, IdentityTransformation
import Unitful: Length, LengthUnits, DimensionlessQuantity, NoUnits, DimensionError
import Unitful: ustrip, unit, inch
Unitful.@derived_dimension InverseLength inv(Unitful.𝐋)

function render! end
export render!

const DEFAULT_LAYER = 0
const DEFAULT_DATATYPE = 0
const GDS_POLYGON_MAX = 8190

# setup for robust 2d predicates
const splitter, epsilon =
    let every_other = true, half = 0.5, epsilon = 1.0, splitter = 1.0, check = 1.0
        lastcheck = check
        epsilon *= half
        every_other && (splitter *= 2.0)
        every_other = !every_other
        check = 1.0 + epsilon

        while (check != 1.0) && (check != lastcheck)
            lastcheck = check
            epsilon *= half
            every_other && (splitter *= 2.0)
            every_other = !every_other
            check = 1.0 + epsilon
        end
        splitter += 1.0
        splitter, epsilon
    end

const resulterrbound = (3.0 + 8.0 * epsilon) * epsilon
const ccwerrboundA   = (3.0 + 16.0 * epsilon) * epsilon
const ccwerrboundB   = (2.0 + 12.0 * epsilon) * epsilon
const ccwerrboundC   = (9.0 + 64.0 * epsilon) * epsilon * epsilon

function __init__()
    # To ensure no crashes
    global _clip = Ref(Clipper.Clip())
    global _coffset = Ref(Clipper.ClipperOffset())
    # The magic bytes are the GDS HEADER tag (0x0002), preceded by the number of
    # bytes in total (6 == 0x0006) for the HEADER record.
    add_format(
        format"GDS",
        UInt8[0x00, 0x06, 0x00, 0x02],
        ".gds",
        [:DeviceLayout => UUID("ebf59a4a-04ec-49d7-8cd4-c9382ceb8e85")]
    )
    # A .dxf file should start with "0" on the first line and "SECTION" on the next, but
    # sometimes there's extra whitespace. For now we'll trust the file extension.
    add_format(
        format"DXF",
        (),
        ".dxf",
        [:DeviceLayout => UUID("ebf59a4a-04ec-49d7-8cd4-c9382ceb8e85"), FileIO.SAVE]
    )
    # SolidModels can be saved to various formats depending on the geometry kernel
    add_format(
        format"STEP",
        (),
        ".stp",
        [:DeviceLayout => UUID("ebf59a4a-04ec-49d7-8cd4-c9382ceb8e85"), FileIO.SAVE]
    )
    add_format(
        format"BREP",
        (),
        ".brep",
        [:DeviceLayout => UUID("ebf59a4a-04ec-49d7-8cd4-c9382ceb8e85"), FileIO.SAVE]
    )
    add_format(
        format"MSH2",
        (),
        ".msh2",
        [:DeviceLayout => UUID("ebf59a4a-04ec-49d7-8cd4-c9382ceb8e85"), FileIO.SAVE]
    )
    add_saver(format"MSH", :DeviceLayout => UUID("ebf59a4a-04ec-49d7-8cd4-c9382ceb8e85"))

    # Add the various graphics formats, which are registered already.
    add_saver(format"SVG", :DeviceLayout => UUID("ebf59a4a-04ec-49d7-8cd4-c9382ceb8e85"))
    add_saver(format"PDF", :DeviceLayout => UUID("ebf59a4a-04ec-49d7-8cd4-c9382ceb8e85"))
    add_saver(format"EPS", :DeviceLayout => UUID("ebf59a4a-04ec-49d7-8cd4-c9382ceb8e85"))
    return add_saver(
        format"PNG",
        :DeviceLayout => UUID("ebf59a4a-04ec-49d7-8cd4-c9382ceb8e85")
    )
end

function save end
function load end

"""
    Coordinate = Union{Real, Length}

Type alias for numeric types suitable for coordinate systems.
"""
const Coordinate = Union{Real, Length}

"""
    CoordinateUnits = Union{typeof(NoUnits), LengthUnits}

Type alias for units suitable for coordinate systems.
"""
const CoordinateUnits = Union{typeof(NoUnits), LengthUnits}

"""
    PointTypes = Union{Real, DimensionlessQuantity, Length, InverseLength}

Allowed type variables for `Point{T}` types.
"""
const PointTypes = Union{Real, DimensionlessQuantity, Length, InverseLength}
const FloatCoordinate = Union{AbstractFloat, Length{<:AbstractFloat}}
const IntegerCoordinate = Union{Integer, Length{<:Integer}}

include("points.jl")
import .Points: Point, getx, gety, lowerleft, upperright
export Points, Point, getx, gety, lowerleft, upperright

include("transform.jl")
import .Transformations:
    Reflection,
    Rotation,
    RotationPi,
    ScaledIsometry,
    Transformation,
    Translation,
    XReflection,
    YReflection,
    ∘,
    compose,
    isapprox_angle,
    isapprox_cardinal,
    mag,
    origin,
    preserves_angles,
    rotated_direction,
    rotation,
    xrefl
export Transformations,
    Reflection,
    Rotation,
    RotationPi,
    ScaledIsometry,
    Transformation,
    Translation,
    XReflection,
    YReflection,
    ∘,
    compose,
    isapprox_angle,
    isapprox_cardinal,
    mag,
    origin,
    preserves_angles,
    rotated_direction,
    rotation,
    xrefl

"""
    AbstractGeometry{S <: Coordinate}

Abstract supertype for things that have a geometric representation.

Abstract subtypes include `GeometryStructure`, `GeometryEntity`, and
`GeometryReference`. Provides an interface for coordinate transformations
and bounding boxes.
"""
abstract type AbstractGeometry{S <: Coordinate} end

"""
    coordinatetype(::Type{S}) where {T, S <: AbstractGeometry{T}}
    coordinatetype(S) where {T, S <: AbstractGeometry{T}}

Return the coordinate type of the geometry.
"""
coordinatetype(::Type{S}) where {T, S <: AbstractGeometry{T}} = T
coordinatetype(::S) where {T, S <: AbstractGeometry{T}} = T
coordinatetype(::AbstractArray{S}) where {T, S <: AbstractGeometry{T}} = T
coordinatetype(iterable) = promote_type(coordinatetype.(iterable))

# Entity interface
include("entities.jl")
export GeometryEntity,
    ScaledIsometry,
    bounds,
    center,
    centered,
    coordinatetype,
    footprint,
    halo,
    offset,
    to_polygons,
    lowerleft,
    upperright
export transform,
    translate, rotate, rotate90, magnify, reflect_across_xaxis, reflect_across_line

# Entity styles
include("styles.jl")
export OptionalStyle, ToTolerance, optional_entity, MeshSized, meshsized_entity, styled

"""
    abstract type GeometryStructure{S} <: AbstractGeometry{S}

Supertype for structures that may contain entities and references to other structures.

Subtypes include [`DeviceLayout.AbstractCoordinateSystem`](@ref) and [`Path`](@ref).
"""
abstract type GeometryStructure{S} <: AbstractGeometry{S} end

include("structures.jl")
export element_metadata,
    elements,
    elementtype,
    map_metadata,
    map_metadata!,
    name,
    refs,
    reset_uniquename!,
    uniquename

# Need AbstractComponent for Paths, but also need Paths in SchematicDrivenLayout
"""
    abstract type AbstractComponent{T} <: GeometryStructure{T}

A parameterized layout element, to be used as a building block in schematic-driven design.

The alias `Component = AbstractComponent{typeof(1.0UPREFERRED)}` is provided for convenience.

Each `AbstractComponent` comes with the necessary parameters and methods to render its geometry and
to attach it to other components in a schematic. Something similar to this concept may be
familiar from other electronic design automation tools as a PCell ("parameterized cell").

You might call something a component if you would include it in a schematic or diagram
rather than abstracting it away, if it can be described as a black box with ports, or if you
might want to simulate it independently. For example, a series interdigital capacitor could
be defined as a `AbstractComponent`, with attachment points (`Hook`s) at the end of each lead.

`AbstractComponent`s provide a common interface:

  - `name(c::MyComponent)`: The name of the component.
  - `parameters(c::MyComponent)`: The parameters of the component as a `NamedTuple`.
  - `geometry(c::MyComponent)`: A coordinate system containing `c`'s rendered geometry.
  - `hooks(c::MyComponent)`: A `NamedTuple` of `Hook`s and `Hook` arrays that specify how
    connections are made with `c`.
  - `hooks(c::MyComponent, h::Symbol)`: The specific hook identified by `h`.
  - `default_parameters(c::Union{MyComponent, Type{MyComponent}})`: Default parameters as a `NamedTuple`.
  - `parameter_names(c::Union{MyComponent, Type{MyComponent}})`: Parameter names as a collection of `Symbol`s.
  - A keyword constructor that merges keyword arguments into `default_parameters` non-recursively. (That is,
    a `NamedTuple` keyword argument will overwrite the default parameter entirely, meaning every
    "subparameter" in the `NamedTuple` needs to be specified.)
  - `create_component(::Type{MyComponent}, name::String=default_parameters(MyComponent).name, base_parameters::NamedTuple=default_parameters(MyComponent); kwargs...)`: Constructor that
    recursively merges `kwargs` into `base_parameters`. (That is, a `NamedTuple` keyword argument
    will be merged into the corresponding `NamedTuple` base parameter, meaning not every "subparameter"
    needs to be fully specified.)
  - `set_parameters(mycomp::MyComponent, name::String=name(mycomp), params::NamedTuple=parameters(c); kwargs...)`:
    Shorthand for `create_component` using `mycomp` for base parameters
  - `(mycomp::MyComponent)(name::String=name(mycomp), params::NamedTuple=parameters(mycomp)=; kwargs...)`: Shorter shorthand for the above

Since `AbstractComponent` is a subtype of `GeometryStructure`, they can also be referenced
by a `StructureReference`. Other `GeometryStructure` interface methods, including `elements`,
`element_metadata`, `refs`, `flatten`,  `footprint`, `halo`, and `transform` operate on `geometry(mycomp)`.

The `name` of a component is not guaranteed to be unique. Instances of components within
schematics as well as their coordinate systems within a layout will always have unique identifiers,
which are automatically constructed from a component's name using `uniquename` if it is not
already unique. For this reason, it is still often helpful for designers to explicitly
give important components unique names, guaranteeing that the corresponding identifiers
are the same.

# Implementing subtypes

Components must have a `name` field. Defining components with [`@compdef`](@ref) is
recommended, since it creates a `name` field if not specified, allows specification of default parameters,
creates a field to store the geometry after it is first calculated, and defines a `default_parameters` method.

Non-composite components must implement the following specializations:

  - `_geometry!(cs::CoordinateSystem, comp::MyComponent)`: Add the geometry to cs
  - `hooks(comp::MyComponent)`: Return a `NamedTuple` of `Hook`s

For composite components (those with subcomponents), see [`DeviceLayout.AbstractCompositeComponent`](@ref).
"""
abstract type AbstractComponent{T} <: GeometryStructure{T} end
function parameters end
function _geometry! end
function hooks end

"""
    GeometryReference{S<:Coordinate, T<:GeometryStructure} <: AbstractGeometry{S}

Abstract supertype for references to geometry structures.

Subtypes are `StructureReference` and `ArrayReference`.
"""
abstract type GeometryReference{S, T <: GeometryStructure} <: AbstractGeometry{S} end

include("references.jl")
export ArrayReference,
    StructureReference, aref, flatten, flat_elements, sref, structure, transformation

"""
    AbstractCoordinateSystem{S<:Coordinate} <: GeometryStructure{S}

Abstract supertype for coordinate systems, including `CoordinateSystem` and `Cell`.

Also exists to avoid circular definitions involving the concrete
`AbstractCoordinateSystem` types and subtypes of `GeometryReference`.
"""
abstract type AbstractCoordinateSystem{S} <: GeometryStructure{S} end

const CoordSysRef = GeometryReference{S, T} where {S, T <: AbstractCoordinateSystem}

# Geometry predicates
include("predicates.jl")

abstract type Meta end
include("metadata.jl")
export GDSMeta,
    SemanticMeta,
    datatype,
    gdslayer,
    layer,
    layerindex,
    layername,
    layer_inclusion,
    layer_included,
    level

"""
    abstract type AbstractPolygon{T} <: GeometryEntity{T} end

Anything you could call a polygon regardless of the underlying representation.
Currently only `Rectangle` or `Polygon` are concrete subtypes, but one could
imagine further subtypes to represent specific shapes that appear in highly
optimized pattern formats. Examples include the OASIS format (which has 25
implementations of trapezoids) or e-beam lithography pattern files like the Raith
GPF format.
"""
abstract type AbstractPolygon{T} <: GeometryEntity{T} end

eltype(::AbstractPolygon{T}) where {T} = T
eltype(::Type{AbstractPolygon{T}}) where {T} = T

include("rectangles.jl")
import .Rectangles: Rectangle, height, isproper, width
export Rectangles, Rectangle, height, isproper, width

include("polygons.jl")
import .Polygons:
    Polygon,
    Ellipse,
    Circle,
    ClippedPolygon,
    RelativeRounded,
    Rounded,
    StyleDict,
    addstyle!,
    circle,
    clip,
    cliptree,
    difference2d,
    gridpoints_in_polygon,
    intersect2d,
    offset,
    perimeter,
    points,
    radius,
    rounded_corner,
    sweep_poly,
    union2d
export Polygons,
    Polygon,
    Ellipse,
    Circle,
    ClippedPolygon,
    RelativeRounded,
    Rounded,
    StyleDict,
    addstyle!,
    circle,
    clip,
    cliptree,
    difference2d,
    gridpoints_in_polygon,
    intersect2d,
    offset,
    perimeter,
    points,
    radius,
    rounded_corner,
    sweep_poly,
    union2d

include("align.jl")
using .Align
export Align

include("texts.jl")
export Texts

include("coordinate_systems.jl")
import .CoordinateSystems:
    CoordinateSystem,
    CoordinateSystemReference,
    CoordinateSystemArray,
    addarr!,
    addref!,
    coordsys,
    flatten!,
    order!,
    place!,
    traverse!
export CoordinateSystems,
    CoordinateSystem,
    CoordinateSystemReference,
    CoordinateSystemArray,
    addarr!,
    addref!,
    coordsys,
    flatten!,
    order!,
    place!,
    traverse!

include("hooks.jl")
export HandedPointHook, Hook, PointHook, compass, in_direction, out_direction

include("paths/paths.jl")
import .Paths:
    Path,
    Route,
    α0,
    α1,
    reconcile!,
    attach!,
    bspline!,
    contstyle1,
    corner!,
    direction,
    discretestyle1,
    laststyle,
    launch!,
    meander!,
    next,
    nodes,
    overlay!,
    p0,
    p0_hook,
    p1,
    p1_hook,
    pathf,
    pathlength,
    pathlength_nearest,
    path_in,
    path_out,
    previous,
    rotated_direction,
    route!,
    segment,
    setsegment!,
    simplify,
    simplify!,
    straight!,
    style,
    style0,
    style1,
    setstyle!,
    terminate!,
    transform,
    turn!,
    undecorated

export Paths,
    Path,
    Route,
    α0,
    α1,
    reconcile!,
    attach!,
    bspline!,
    corner!,
    direction,
    meander!,
    laststyle,
    launch!,
    overlay!,
    p0,
    p0_hook,
    p1,
    p1_hook,
    pathf,
    pathlength,
    pathlength_nearest,
    path_in,
    path_out,
    rotated_direction,
    route!,
    segment,
    setsegment!,
    simplify,
    simplify!,
    style,
    style0,
    style1,
    setstyle!,
    straight!,
    terminate!,
    transform,
    turn!,
    undecorated

include("cells.jl")
import .Cells: Cell, CellReference, CellArray, cell, layers, text!
export Cells, Cell, CellReference, CellArray, cell, layers, text!

include("utils.jl")

include("render/render.jl")

# After render.jl to ensure access to `to_polygons`
include("curvilinear.jl")
using .Curvilinear
export Curvilinear, CurvilinearPolygon, CurvilinearRegion, pathtopolys

include("simple_shapes.jl")
import .SimpleShapes:
    circular_arc,
    draw_pixels,
    hatching_unit,
    radial_cut,
    radial_stub,
    simple_cross,
    simple_ell,
    simple_tee,
    checkerboard!,
    grating!,
    interdigit!
export SimpleShapes,
    circular_arc,
    draw_pixels,
    hatching_unit,
    radial_cut,
    radial_stub,
    simple_cross,
    simple_ell,
    simple_tee,
    checkerboard!,
    grating!,
    interdigit!

include("intersect.jl")
using .Intersect
export Intersect

include("autofill.jl")
import .Autofill: autofill!, make_halo
export Autofill, autofill!, make_halo

include("backends/gds.jl")
include("backends/graphics.jl")
include("backends/dxf.jl")

include("solidmodels/solidmodels.jl")
import .SolidModels: SolidModel
export SolidModels, SolidModel

include("polytext/polytext.jl")
import .PolyText:
    DotMatrix,
    PolyTextSansMono,
    PolyTextComic,
    characters_demo,
    polytext,
    polytext!,
    referenced_characters_demo,
    scripted_demo
export PolyText,
    DotMatrix,
    PolyTextSansMono,
    PolyTextComic,
    characters_demo,
    polytext,
    polytext!,
    referenced_characters_demo,
    scripted_demo

include("schematics/SchematicDrivenLayout.jl")
export SchematicDrivenLayout

include("precompile.jl")

end
