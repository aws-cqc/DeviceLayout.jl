"""
    abstract type AbstractCompositeComponent{T} <: AbstractComponent{T}

An `AbstractComponent` with geometry derived from that of a `SchematicGraph` of subcomponents.

The alias `CompositeComponent = AbstractCompositeComponent{typeof(1.0UPREFERRED)}` is provided for convenience.

A standard `Component` `c` is described by its [`geometry(c)`](@ref), [`parameters(c)`](@ref), and
[`hooks(c)`](@ref). In contrast, a `CompositeComponent` `cc` also has `parameters`, but
is otherwise described at the level of [`graph(cc)`](@ref) and [`map_hooks(cc)`](@ref),
which define a relationship between the `CompositeComponent` and the geometry and hooks of its
subcomponents.

If a `SchematicGraph` `g` contains a node with a `CompositeComponent`, then the subgraph
`graph(cc)` will be accessible to inspection tools for `g`. For example, `find_components`
can return nodes in the subgraph. You can also `flatten!(g)` to simply replace
`cc`'s node with `graph(cc)`.

The list of subcomponents in the graph can be obtained with `components(cc)` (equivalent to
`components(graph(cc))`).

# Implementing subtypes

Components must have a `name` field. Defining components with [`@compdef`](@ref) is
recommended, since it creates a `name` field if not specified, allows specification
of default parameters, creates fields for storing the schematic, graph, and
hooks after they are first calculated, and defines a `default_parameters` method.

A `CompositeComponent` must implement the following specializations:

  - `_build_subcomponents`: Returns a `Tuple` of subcomponents
  - `_graph!(g::SchematicGraph, cc::MyComponent, subcomps::NamedTuple)`: Populates and connects the schematic graph corresponding to `cc`,
    where `subcomps` contains the results of `_build_subcomponents` keyed by name
  - `map_hooks(::Type{MyComponent})`: A `Dict{Pair{Int, Symbol}, Symbol` mapping subcomponent hooks
    to hooks presented by the composite component.

If you define your own abstract composite component subtype, you should define
`SchematicDrivenLayout.iscomposite(::Val{:MyAbstractCompositeComponent}) = true` to allow
the `@compdef` macro to recognize that the component is composite.
"""
abstract type AbstractCompositeComponent{T} <: AbstractComponent{T} end

"""
    const CompositeComponent = AbstractCompositeComponent{typeof(1.0UPREFERRED)}

`CompositeComponent` is an alias for `AbstractCompositeComponent` with the coordinate type `typeof(1.0UPREFERRED)`.

[`DeviceLayout.UPREFERRED`](@ref) is a constant set according to the `unit` preference in `Project.toml` or `LocalPreferences.toml`.
The default (`"PreferNanometers"`) gives `const UPREFERRED = DeviceLayout.nm`, with mixed-unit operations
preferring conversion to `nm`.
"""
const CompositeComponent = AbstractCompositeComponent{typeof(1.0UPREFERRED)}
iscomposite(::T) where {T <: AbstractComponent} = (T <: AbstractCompositeComponent)
iscomposite(::Val{:AbstractCompositeComponent}) = true # For @compdef, since we can't eval
iscomposite(::Val{:CompositeComponent}) = true
# Define your own iscomposite if you want to use `@compdef` with your own abstract supertype
iscomposite(::Any) = false

function Base.getproperty(cc::T, s::Symbol) where {T <: AbstractCompositeComponent}
    if hasfield(T, s)
        return getfield(cc, s)
    else
        return getproperty(graph(cc), s)
    end
end

"""
    graph(cc::AbstractCompositeComponent)

The `SchematicGraph` represented by `cc`.
"""
function graph(c::AbstractCompositeComponent)
    !isempty(c._graph.nodes) && return c._graph
    comps = _build_subcomponents(c)
    _graph!(c._graph, c, subcomp_namedtuple(comps))
    return c._graph
end

function subcomp_namedtuple(comp_tuple)
    u_comps = unique(comp_tuple)
    keys = Symbol.(name.(u_comps))
    # Will throw "duplicate field name" error if different components share a name
    return NamedTuple{(keys...,)}(u_comps)
end

# If a named tuple is provided, the tuple element names are used for sub-componenet fields
subcomp_namedtuple(comp_tuple::NamedTuple) = comp_tuple

# Subtypes must implement _build_subcomponents(c::MyCompositeComponent)
function _build_subcomponents end

# Subtypes must implement _graph!(::SchematicGraph, ::MyCompositeComponent, ::NamedTuple)
function _graph! end

"""
    geometry(cc:AbstractCompositeComponent)

Return the `CoordinateSystem` resulting from `build!(plan(graph(cc)))`.
"""
function geometry(cc::AbstractCompositeComponent)
    return geometry_from_graph(cc)
end

function schematic(cc::AbstractCompositeComponent)
    !isempty(cc._schematic.ref_dict) && return cc._schematic
    floorplan = plan(
        graph(cc);
        log_dir=nothing,
        id_prefix=name(graph(cc)) * COMPOSITE_NODE_ID_SEPARATOR
    )
    append_coordsys!(cc._schematic.coordinate_system, floorplan.coordinate_system)
    for (k, v) in pairs(floorplan.ref_dict)
        cc._schematic.ref_dict[k] = v
    end
    return cc._schematic
end

const COMPOSITE_NODE_ID_SEPARATOR = "__"

function geometry_from_graph(cc::AbstractCompositeComponent)
    floorplan = schematic(cc)
    if !floorplan.checked[]
        floorplan.checked[] = true # Skip check
        build!(floorplan)
    end
    return floorplan.coordinate_system
end

compose_hookname(cc::AbstractCompositeComponent, i::Int, h::Symbol) =
    get(map_hooks(cc), (i => h), Symbol("_$(i)_$h"))

function decompose_hookname(cc::AbstractCompositeComponent, comp_h::Symbol)
    for (i, c) in enumerate(components(cc))
        for h in keys(hooks(c))
            if compose_hookname(cc, i, h) == comp_h
                return i => h
            end
        end
    end
    return error("No hook $comp_h found in composite component $(name(cc)). \
               Available hooks: $(keys(hooks(cc))).")
end

"""
    map_hooks(cc::AbstractCompositeComponent)
    map_hooks(cc::Type{<:AbstractCompositeComponent})

A `Dict{Pair{Int, Symbol}, Symbol}` mapping subcomponent hooks to composite hooks.

For example, the entry `(2 => :readout) => :readout_2` means the `readout` hook for
the subcomponent in `graph(cc)`'s node 2 will be available as `hooks(cc).readout_2`
in the composite geometry.

Subcomponent `Hook`s that are not mapped will still be available as `:_\$(i)_\$h`,
where `i` is the subcomponent's node index in `graph(cc)` and `h` is the hook name.
In other words, the above example would have the fallback default `:_2_readout`.
"""
function map_hooks(::Type{T}) where {T <: AbstractCompositeComponent}
    return Dict{Pair{Int, Symbol}, Symbol}()
end
map_hooks(::T) where {T <: AbstractCompositeComponent} = map_hooks(T)
# Subtypes should implement map_hooks(::Type{MyCompositeComponent})
# returning type Dict{Pair{Int, Symbol}, Symbol}

"""
    hooks(cc::AbstractCompositeComponent)

`Hook`s for the composite geometry, placed at corresponding hooks of the subcomponents.

# Hooks

A hook `hcc` is returned for each hook (name `h`) of every subcomponent node (index `i`). If
`keys(map_hooks(cc))` contains `i => h`, then the corresponding composite hook is
`map_hooks(cc)[h]`. Otherwise, it is `_\$(i)_\$h`.
"""
function hooks(cc::T) where {T <: AbstractCompositeComponent}
    if hasfield(T, :_hooks)
        !isempty(cc._hooks) && return (; pairs(cc._hooks)...)
    end
    floorplan = schematic(cc)
    hooknames = [keys(hooks(floorplan, node)) for node in nodes(graph(cc))]
    cc_names = [
        compose_hookname(cc, i, hookname) for (i, hnames) in enumerate(hooknames) for
        hookname in hnames
    ]
    cc_hooks = [values(hooks(floorplan, node)) for node in nodes(graph(cc))]
    if hasfield(T, :_hooks)
        for (name, hook) in zip(cc_names, Iterators.flatten(cc_hooks))
            cc._hooks[name] = hook
        end
    end
    return NamedTuple{(cc_names...,)}(Iterators.flatten(cc_hooks))
end

"""
    hooks(cc::AbstractCompositeComponent, subcompname::String, h::Symbol)

Attempts to retrieve the composite hook corresponding to hook `h` of a `Component`
with name `subcompname` (either its unique name or its name parameters). Will emit an error if the
name is ambiguous.
"""
function hooks(cc::AbstractCompositeComponent, subcompname::String, h::Symbol)
    idx = findall(
        (c) -> (parameters(c).name == subcompname || name(c) == subcompname),
        components(cc)
    )
    length(idx) > 1 && error(
        "Composite component $(name(cc)) has components $(name.(components(cc))...) at indices \
  $(idx...). Use `hooks(cc::AbstractCompositeComponent, idx::Int, $h` to
  specify hook unambiguously."
    )
    return hooks(cc, compose_hookname(cc, first(idx), h))
end

"""
    hooks(cc::AbstractCompositeComponent, i::Int, h::Symbol)
    hooks(cc::AbstractCompositeComponent, (i=>h)::Pair{Int, Symbol})

The composite hook corresponding to hook `h` of `components(cc)[i]`.
"""
hooks(cc::AbstractCompositeComponent, i::Int, h::Symbol) =
    hooks(cc, compose_hookname(cc, i, h))
hooks(cc::AbstractCompositeComponent, p::Pair{Int, Symbol}) = hooks(cc, first(p), last(p))

"""
    subcomponents(cc::AbstractCompositeComponent)

The unique `Component`s in the `SchematicGraph` represented by `cc`, as a `NamedTuple`.

The components are `unique(components(graph(cc)))`, and the `NamedTuple` keys are the subcomponent
names.
"""
subcomponents(cc::AbstractCompositeComponent) = subcomp_namedtuple(components(graph(cc)))
Base.getindex(cc::AbstractCompositeComponent, I) = graph(cc)[I]
function Base.getindex(c::AbstractCompositeComponent, nom::AbstractString, index::Integer=1)
    inds = findall(x -> name(x) == nom, components(c))
    return components(c)[inds[index]]
end

"""
    components(cc::AbstractCompositeComponent)

A list of the components in the subgraph of `cc`. Equivalent to `components(graph(cc))`

Unlike `subcomponents`, `components` will return a component for every node, even if multiple
nodes use the same component.
"""
components(cc::AbstractCompositeComponent) = components(graph(cc))

transformation(d::AbstractCompositeComponent, e::ComponentNode) =
    transformation(schematic(d), e)

"""
    flatten(g::SchematicGraph; depth=-1)

Create a copy of `g` with all `AbstractCompositeComponent`s replaced by their graphs.

For non-composite components, the identical `ComponentNode`s will be preserved.

# Keywords

  - `depth`: How many times to iteratively flatten top-level `AbstractCompositeComponent`s.
    If negative, will repeat until no `AbstractCompositeComponent`s remain.
"""
function DeviceLayout.flatten(g::SchematicGraph; depth=-1)
    g2 = _flatten(g, depth)
    depth = depth - 1
    composite_indices = find_components(AbstractCompositeComponent, g2, depth=1)
    while depth != 0 && !isempty(composite_indices)
        g2 = _flatten(g2, depth)
        depth = depth - 1
        composite_indices = find_components(AbstractCompositeComponent, g2, depth=1)
    end
    return g2
end

function _flatten(g::SchematicGraph, depth)
    g2 = SchematicGraph(g.name)
    for (k, v) in g.namecounter
        g2.namecounter[k] = v
    end
    # For each original node, add the node or subgraph
    nodemap = Dict{Int, UnitRange{Int}}() # Map original index to new index range
    for (idx, node) in enumerate(nodes(g))
        comp = component(node)
        if depth != 0 && comp isa AbstractCompositeComponent
            nv0 = length(nodes(g2))
            # Note that flatten(graph(comp), depth=depth-1) doesn't work
            # Because composite component hook mapping only allows us to identify subcomponent indices at the top level
            # So we get the raw subgraph and flatten iteratively outside this loop
            subg = graph(comp)
            nodemap[idx] = (nv0 + 1):(nv0 + length(nodes(subg)))
            add_graph!(g2, subg; id_prefix=(node.id * "."))
            # vertex properties are lost, except for additional_hooks, which get assigned to root
            add_hooks = additional_hooks(g, node)
            !isempty(add_hooks) &&
                set_prop!(g2.graph, nv0 + 1, :additional_hooks, add_hooks)
        else
            g2.node_dict[Symbol(node.id)] = node
            push!(g2.nodes, node)
            add_vertex!(g2, copy(MetaGraphs.props(g.graph, idx)))
            nodemap[idx] = length(nodes(g2)):length(nodes(g2))
        end
    end
    # For each edge, add that edge between 
    for edge in edges(g.graph)
        eprops = copy(MetaGraphs.props(g.graph, edge))
        # Indices and hook symbols in original graph
        s, d = Tuple(edge)
        hsym_s = get_prop(g, g[s], g[d], g[s])
        hsym_d = get_prop(g, g[s], g[d], g[d])
        # Indices and hook symbols in flattened graph
        s2, hsym_s2 = if length(nodemap[s]) > 1
            n_idx, h_c = decompose_hookname(component(g[s]), hsym_s)
            nodemap[s][n_idx], h_c
        else
            only(nodemap[s]), hsym_s
        end
        d2, hsym_d2 = if length(nodemap[d]) > 1
            n_idx, h_c = decompose_hookname(component(g[d]), hsym_d)
            nodemap[d][n_idx], h_c
        else
            only(nodemap[d]), hsym_d
        end
        eprops[:nodehooks] =
            Dict{ComponentNode, Symbol}(g2[s2] => hsym_s2, g2[d2] => hsym_d2)
        add_edge!(g2.graph, s2, d2, eprops)
    end
    return g2
end
