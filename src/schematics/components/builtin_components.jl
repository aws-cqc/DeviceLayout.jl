"""
    WeatherVane{T} <: AbstractComponent{T}

A component with empty geometry and an 8-point compass of hooks at the origin.
"""
@compdef struct WeatherVane{T} <: AbstractComponent{T}
    name::String = "vane"
end
WeatherVane(; kwargs...) = WeatherVane{typeof(1.0UPREFERRED)}(; kwargs...)
hooks(::WeatherVane{T}) where {T} = compass(p0=zero(Point{T}))

"""
    Spacer{T} <: AbstractComponent{T}

Provides an 8-point [compass](@ref SchematicDrivenLayout.compass) of hooks at each of two points separated by `p1`.

# Parameters

  - `p1`: The endpoint of the spacer

# Hooks

  - `p0_east`: Hook at the origin, with `in_direction` pointing "east" (positive x direction)
  - `p0_northeast`
  - `p0_north`
  - ...
  - `p0_southeast`
  - `p1_east`: Hook at `p1`, with `in_direction` pointing "east" (positive x direction)
  - `p1_northeast`
  - ...
  - `p1_southeast`
"""
@compdef struct Spacer{T} <: AbstractComponent{T}
    name::String = "spacer"
    p1::Point{T} = zero(Point{T})
end
Spacer(; kwargs...) = Spacer{typeof(1.0UPREFERRED)}(; kwargs...)
function hooks(s::Spacer{T}) where {T}
    return merge(compass("p0_", p0=zero(Point{T})), compass("p1_", p0=s.p1))
end

"""
    struct ArrowAnnotation{T} <: AbstractComponent{T}
        name::String = "arrow"
        length = 0.032mm
        width = 0.005mm
        text::String = ""
        textsize = 0.025mm
        meta = SemanticMeta(:annotation)
    end

An arrow with a given length and width along with a text annotation in the layer given by `meta`.

# Hooks

  - `nock`: The base of the arrow, with inward direction along the arrow
  - `tip`: The tip of the arrow, with inward direction opposite the arrow
"""
@compdef struct ArrowAnnotation{T} <: AbstractComponent{T}
    name::String = "arrow"
    length::T = 32 * DeviceLayout.onemicron(T)
    width::T = 5 * DeviceLayout.onemicron(T)
    text::String = ""
    textsize::T = 25 * DeviceLayout.onemicron(T)
    meta = SemanticMeta(:annotation)
end
ArrowAnnotation(; kwargs...) = ArrowAnnotation{typeof(1.0UPREFERRED)}(; kwargs...)

# Draw an arrow from left to right
function _geometry!(cs::CoordinateSystem, ac::ArrowAnnotation)
    (; length, width, text, textsize) = ac
    rect = centered(Rectangle(length, width))
    zer = zero(width)
    tip_edge = [Point(zer, zer), Point(3 * width, 3 * width), Point(zer, 6 * width)]
    tip = Polygon(vcat(tip_edge, reverse(tip_edge) .- Point(width, zer)))
    tip = Align.flushright(tip, rect, offset=width, centered=true)
    arrow = union2d(rect, tip)

    text_cs = polytext(text, PolyTextSansMono(textsize, ac.meta))

    text_dummy = Cell("temp", nm)
    render!(text_dummy, text_cs; map_meta=(meta) -> GDSMeta())
    lx = bounds(text_dummy).ur.x - bounds(text_dummy).ll.x

    render!(cs, arrow, ac.meta)
    return push!(cs.refs, sref(text_cs, Point(-lx + length / 2, zero(width))))
end

# Define a hook at the base of the arrow, pointing in the same direction
# Plus a hook at the tip of the arrow, pointing in the opposite direction
function hooks(ac::ArrowAnnotation)
    zer = zero(ac.length)
    nockhook = PointHook(Point(-ac.length / 2, zer), pi)
    tiphook = PointHook(ac.length / 2, zer, 0)
    return (nock=nockhook, tip=tiphook)
end

"""
    struct GDSComponent{T} <: AbstractComponent{T}
        name::String
        cell::Cell{T}
        hooks::NamedTuple
        meta::DeviceLayout.Meta
    end

A component with geometry corresponding to an explicit `Cell`.

The `meta` field does not affect metadata inside the
`Cell`, but can still be used by a `LayoutTarget` to decide whether the component should
be rendered or not.

Hooks are supplied by the user, with a default of [`compass()`](@ref).
"""
struct GDSComponent{T} <: AbstractComponent{T}
    name::String
    cell::Cell{T}
    hooks::NamedTuple
    parameters::NamedTuple
    _geometry::CoordinateSystem{T} # For consistency with @compdef-ed components
    function GDSComponent{T}(n, c, h, p) where {T}
        return new{T}(n, c, h, p, CoordinateSystem{T}(n))
    end
end

"""
    GDSComponent(filename::String, cellname::String, hooks=compass(), meta=GDSMeta())

Construct a GDSComponent using only the necessary fields `filename` and `cellname`.

The component will have a unique name based on `cellname`.
"""
GDSComponent(
    filename::String,
    cellname::String,
    hooks::NamedTuple=compass(),
    parameters::NamedTuple=DEFAULT_GDSCOMPONENT_PARAMS
) = GDSComponent(uniquename(cellname), filename, cellname, hooks, parameters)

GDSComponent(
    cell::Cell{T},
    hooks::NamedTuple=compass(),
    parameters::NamedTuple=DEFAULT_GDSCOMPONENT_PARAMS
) where {T} = GDSComponent{T}(uniquename(cell.name), cell, hooks, parameters)

function GDSComponent(
    name::String,
    filename::String,
    cellname::String,
    hooks::NamedTuple,
    parameters::NamedTuple=DEFAULT_GDSCOMPONENT_PARAMS
)
    cell_dict = load(filename)
    l_cell = cell_dict[cellname]
    l_cell.name = name
    return GDSComponent{coordinatetype(l_cell)}(name, l_cell, hooks, parameters)
end

const DEFAULT_GDSCOMPONENT_PARAMS = (;)
default_parameters(::Type{<:GDSComponent}) = DEFAULT_GDSCOMPONENT_PARAMS

function _geometry!(cs::CoordinateSystem, l::GDSComponent)
    return place!(cs, l.cell)
end

hooks(c::GDSComponent) = c.hooks

"""
    struct BasicComponent{T} <: AbstractComponent{T}
    BasicComponent(cs::CoordinateSystem{T}, hooks=(;))

A simple `AbstractComponent` that acts as a lightweight wrapper for a `CoordinateSystem`.

The component `geometry` is a fixed `CoordinateSystem`, provided to the constructor along with `hooks`.
"""
struct BasicComponent{T} <: AbstractComponent{T}
    name::String
    geometry::CoordinateSystem{T}
    hooks
    BasicComponent(cs::CoordinateSystem{T}, hooks=compass()) where {T} =
        new{T}(name(cs), cs, hooks)
end
hooks(c::BasicComponent) = c.hooks
geometry(c::BasicComponent) = c.geometry

"""
    struct BasicCompositeComponent{T} <: AbstractCompositeComponent{T}

A simple `AbstractCompositeComponent` that acts as a lightweight wrapper for a `SchematicGraph`.

The component `scc = BasicCompositeComponent(g::SchematicGraph)` copies `g` and generates
its geometry as `build!(check!(plan(g)))`.

`hooks(scc)` returns a `NamedTuple` with the hook `h` of the `i`th subcomponent as `_i_h`.

Parameters are set indirectly by the internal `SchematicGraph`:

  - `name`: `g.name`, from which the component's unique name is generated
  - `sub_parameters`: A tuple of `NamedTuple`s containing the subcomponent parameters in order

A `BasicCompositeComponent` instance can also be used as a constructor, taking the argument
`param_sets` (a tuple of parameters for each subcomponent, in order), along with keyword
arguments `_i_param` for a parameter named `param` in subcomponent `i`.
Default values are provided by the components in `g`.

````
    (cc::BasicCompositeComponent)(
        param_sets::Tuple = ();
        kwargs...)
````

Create a version of `cc` with different subcomponent parameters.

Argument `param_sets` is a tuple of `NamedTuple`s containing each subcomponent's parameters.
If it is not empty, it must have a `NamedTuple`s for each subcomponent, even an empty one.

Keyword arguments are `_i_param` for a parameter named `param` in subcomponent `i`.
Default values are provided by the components in `g`.
"""
struct BasicCompositeComponent{T} <: AbstractCompositeComponent{T}
    graph::SchematicGraph
    _schematic::Schematic{T}
    _hooks::Dict{Symbol, Union{Hook, Vector{<:Hook}}}
    function BasicCompositeComponent(g::SchematicGraph; coordtype=typeof(1.0UPREFERRED))
        newg = SchematicGraph(name(g))
        add_graph!(newg, g; id_prefix="")
        return new{coordtype}(
            newg,
            Schematic{coordtype}(newg; log_dir=nothing),
            Dict{Symbol, Union{Hook, Vector{<:Hook}}}()
        )
    end
end
name(c::BasicCompositeComponent) = c.graph.name

function (cc::BasicCompositeComponent)(
    compname::String=name(cc),
    param_sets::Tuple=();
    kwargs...
)
    length(param_sets) == 0 && (param_sets = Tuple(repeat([(;)], length(components(cc)))))
    idx_param_values = [(decompose_basic_composite(k)..., v) for (k, v) in kwargs]
    cc2 = BasicCompositeComponent(SchematicGraph(compname); coordtype=coordinatetype(cc))
    g2 = graph(cc2)
    add_graph!(g2, cc.graph; id_prefix="")
    for (idx, p) in enumerate(param_sets)
        ipv_idx = filter(ipv -> ipv[1] == idx, idx_param_values)
        p_kw = map(ipv_idx) do tup
            return tup[2] => tup[3]
        end
        p = merge(p, (; p_kw...))
        length(p) == 0 && continue
        comp = component(nodes(g2)[idx])
        newcomp = set_parameters(comp; p...)
        nodes(g2)[idx].component = newcomp
    end
    return cc2
end

function decompose_basic_composite(s::Symbol)
    (_, idx, sym) = split(String(s), "_", limit=3)
    n_idx = parse(Int, idx)
    return n_idx => Symbol(sym)
end

"""
    parameters(cc::BasicCompositeComponent)

Retrieve the parameters set indirectly by `cc`'s internal `SchematicGraph`:

  - `name`: `g.name`, from which the component's unique name is generated
  - `sub_parameters`: A tuple of `NamedTuple`s containing the subcomponent parameters in order
"""
parameters(cc::BasicCompositeComponent) =
    (; name=name(cc), sub_parameters=(parameters.(components(cc.graph))...,))

default_parameters(cc::BasicCompositeComponent) = parameters(cc)

compose_hookname(::BasicCompositeComponent, i::Int, h::Symbol) = Symbol("_$(i)_$h")

function decompose_hookname(::BasicCompositeComponent, s::Symbol)
    (_, idx, sym) = split(String(s), "_", limit=3)
    n_idx = parse(Int, idx)
    return n_idx => Symbol(sym)
end
graph(c::BasicCompositeComponent) = c.graph
