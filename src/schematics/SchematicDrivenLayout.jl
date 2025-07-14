module SchematicDrivenLayout

using DeviceLayout
using FileIO
using NamedTupleTools
using Unitful
import DeviceLayout: nm, μm, mm
using Accessors

import Base: getproperty, hasproperty
import Logging
import Logging:
    AbstractLogger,
    LogLevel,
    current_logger,
    handle_message,
    min_enabled_level,
    shouldlog,
    with_logger
import LoggingExtras: FormatLogger, MinLevelLogger, TeeLogger

import DeviceLayout:
    AbstractComponent,
    AbstractCoordinateSystem,
    AbstractGeometry,
    Cell,
    Coordinate,
    CoordSysRef,
    GeometryEntity,
    GeometryStructure,
    Hook,
    Meta,
    PointHook,
    Transformation,
    UPREFERRED
import DeviceLayout:
    attach!,
    autofill!,
    bspline!,
    bounds,
    center,
    compass,
    elements,
    flatten,
    flatten!,
    footprint,
    halo,
    hooks,
    in_direction,
    make_halo,
    map_metadata!,
    name,
    origin,
    parameters,
    refs,
    render!,
    sref,
    transform,
    transformation,
    _geometry!
import ..Paths: setα0p0!, setp0!, Route, RouteRule, route!
import ..CoordinateSystems: append_coordsys!

export Component,
    BasicComponent, ComponentNode, GDSComponent, RouteComponent, Spacer, WeatherVane
export PLAN_SKIPS_EDGE
export Schematic, SchematicGraph, BasicCompositeComponent, CompositeComponent
export @component,
    @compdef,
    add_node!,
    attach!,
    autofill!,
    backing,
    build!,
    check!,
    compass,
    component,
    components,
    create_component,
    default_parameters,
    facing,
    find_components,
    find_nodes,
    flatten,
    flatten!,
    fuse!,
    generate_component_definition,
    generate_component_package,
    generate_pdk,
    _geometry!,
    geometry,
    graph,
    hooks,
    layer_record,
    name,
    nodes,
    not_simulated,
    not_simulated!,
    only_simulated,
    not_solidmodel,
    not_solidmodel!,
    only_solidmodel,
    origin,
    parameters,
    parameter_names,
    plan,
    position_dependent_replace!,
    rem_node!,
    replace_component!,
    route!,
    set_parameters
export ProcessTechnology, SimulationTarget, ArtworkTarget, SolidModelTarget
export base_variant, flipchip!, map_metadata!, @composite_variant, @variant

"""
    const Component = AbstractComponent{typeof(1.0UPREFERRED)}

`Component` is an alias for `AbstractComponent` with the coordinate type `typeof(1.0UPREFERRED)`.

[`DeviceLayout.UPREFERRED`](@ref) is a constant set according to the `unit` preference in `Project.toml` or `LocalPreferences.toml`.
The default (`"PreferNanometers"`) gives `const UPREFERRED = DeviceLayout.nm`, with mixed-unit operations
preferring conversion to `nm`.
"""
const Component = AbstractComponent{typeof(1.0UPREFERRED)}

include("technologies.jl")
include("utils.jl")
include("targets.jl")
include("schematics.jl")
include("components/components.jl")
include("components/compdef.jl")
include("components/composite_components.jl")
include("components/builtin_components.jl")
include("routes.jl")
include("components/variants.jl")
include("solidmodels.jl")
include("pdktools.jl")

include("ExamplePDK/ExamplePDK.jl")

end # module
