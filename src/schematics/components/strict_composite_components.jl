"""
    abstract type AbstractStrictCompositeComponent{T} <: AbstractCompositeComponent{T}

An `AbstractCompositeComponent` whose subcomponent structure is declared up front by
[`composite_spec`](@ref) and validated when the graph is first built.

The alias `StrictCompositeComponent = AbstractStrictCompositeComponent{typeof(1.0UPREFERRED)}`
is provided for convenience.

A v1 `CompositeComponent` describes its structure operationally: `_build_subcomponents`
returns instances, `_graph!` adds nodes and edges, and `map_hooks` addresses subcomponents
by graph node index. A strict composite component instead declares named "slots"
(subcomponent roles with types) and named graph nodes in a type-level spec. The framework
derives subcomponent construction and graph node population from the spec, so user code
only supplies per-slot parameter overrides ([`_build_subcomponent`](@ref)) and graph
*edges* (`_graph!`). Hook mapping and hook fallback names use stable node ids
rather than positional indices.

# Implementing subtypes

Components must have a `name` field; defining them with [`@compdef`](@ref) is recommended.
A strict composite component must implement:

  - `composite_spec(::Type{MyComponent})`: the declaration of slots and nodes
    (see [`composite_spec`](@ref)).
  - `_graph!(g::SchematicGraph, cc::MyComponent, subcomps::NamedTuple)`: Connects the
    declared nodes (already added to `g` by the framework, accessible as `g.mynode`)
    with `fuse!`/`route!` edges. Unlike the v1 interface, this method must not add nodes
    for the declared subcomponents and must not remove or reorder the declared nodes;
    *appending* machinery nodes (e.g. by `route!` or by fusing a bare component) is
    allowed.

and may optionally implement:

  - `_build_subcomponent(cc::MyComponent, ::Val{:slot_name})`: per-slot parameter
    overrides applied last (see [`_build_subcomponent`](@ref)).
  - `map_hooks(::Type{MyComponent})`: a `Dict{Pair{Symbol, Symbol}, Symbol}` mapping
    `node_id => subcomponent_hook` to composite hook names (see [`map_hooks`](@ref)).

The spec and hook map are validated by [`validate_composite_spec`](@ref) when
`graph(cc)` is first built; malformed declarations throw `ArgumentError` naming the
offending entry.
"""
abstract type AbstractStrictCompositeComponent{T} <: AbstractCompositeComponent{T} end

"""
    const StrictCompositeComponent = AbstractStrictCompositeComponent{typeof(1.0UPREFERRED)}

`StrictCompositeComponent` is an alias for `AbstractStrictCompositeComponent` with the
coordinate type `typeof(1.0UPREFERRED)`.

[`DeviceLayout.UPREFERRED`](@ref) is a constant set according to the `unit` preference in
`Project.toml` or `LocalPreferences.toml`. The default (`"PreferNanometers"`) gives
`const UPREFERRED = DeviceLayout.nm`, with mixed-unit operations preferring conversion
to `nm`.
"""
const StrictCompositeComponent = AbstractStrictCompositeComponent{typeof(1.0UPREFERRED)}
# For @compdef, since we can't eval the supertype expression inside the macro
iscomposite(::Val{:AbstractStrictCompositeComponent}) = true
iscomposite(::Val{:StrictCompositeComponent}) = true

"""
    composite_spec(::Type{T}) where {T <: AbstractStrictCompositeComponent}

Type-level declaration of a strict composite component's subcomponent structure.

Subtypes must implement this method, returning a `NamedTuple` with exactly two keys:

  - `slots`: a non-empty `NamedTuple` mapping slot names to subcomponent types
    (`Type{<:AbstractComponent}`). A slot is a named subcomponent role; the framework
    constructs exactly one instance per slot (see [`_build_subcomponents`](@ref)).
  - `nodes`: a non-empty `Tuple` of `Pair{Symbol, Symbol}`s `node_id => slot_name`,
    in the order nodes appear in `graph(cc)`. Node ids must be unique and each must
    reference a declared slot; every slot must be used by at least one node. A slot
    referenced by multiple nodes places the *same* component instance at each node.

# Example

```julia
SchematicDrivenLayout.composite_spec(::Type{MyTransmon}) = (
    slots=(; island=MyIsland, junction=MyJunction),
    nodes=(:island => :island, :junction => :junction)
)
```

For a type created with [`@composite_variant`](@ref), the default method falls back to
the spec of `base_variant(T)`, so variants inherit the base type's structure without
further definitions.
"""
function composite_spec(::Type{T}) where {T <: AbstractStrictCompositeComponent}
    B = base_variant(T)
    # `base_variant` is the identity for non-variants, so reaching this method with
    # `B === T` means the subtype never declared its spec; recursing would stack
    # overflow. Make the missing method an actionable error instead.
    B === T && throw(
        ArgumentError(
            "$T <: AbstractStrictCompositeComponent must implement " *
            "`SchematicDrivenLayout.composite_spec(::Type{$T})` returning " *
            "`(slots=(; slot_name=SlotType, ...), nodes=(:node_id => :slot_name, ...))`."
        )
    )
    return composite_spec(B)
end

"""
    slot_names(::Type{T}) where {T <: AbstractStrictCompositeComponent}

The declared slot names of `T`, as a tuple of `Symbol`s (the keys of
`composite_spec(T).slots`).
"""
slot_names(::Type{T}) where {T <: AbstractStrictCompositeComponent} =
    keys(composite_spec(T).slots)

"""
    slot_types(::Type{T}) where {T <: AbstractStrictCompositeComponent}

The declared subcomponent types of `T`, in slot order (the values of
`composite_spec(T).slots`).
"""
slot_types(::Type{T}) where {T <: AbstractStrictCompositeComponent} =
    values(composite_spec(T).slots)

"""
    node_ids(::Type{T}) where {T <: AbstractStrictCompositeComponent}

The declared graph node ids of `T`, in graph order (the first elements of
`composite_spec(T).nodes`).
"""
node_ids(::Type{T}) where {T <: AbstractStrictCompositeComponent} =
    map(first, composite_spec(T).nodes)

"""
    node_slots(::Type{T}) where {T <: AbstractStrictCompositeComponent}

The slot name filling each declared graph node of `T`, in graph order (the second
elements of `composite_spec(T).nodes`).
"""
node_slots(::Type{T}) where {T <: AbstractStrictCompositeComponent} =
    map(last, composite_spec(T).nodes)

"""
    slot_of_node(::Type{T}, node_id::Symbol) where {T <: AbstractStrictCompositeComponent}

The slot name filling the declared node `node_id` of `T`.

Throws `ArgumentError` if `node_id` is not a declared node id.
"""
function slot_of_node(
    ::Type{T},
    node_id::Symbol
) where {T <: AbstractStrictCompositeComponent}
    for (id, slot) in composite_spec(T).nodes
        id === node_id && return slot
    end
    throw(
        ArgumentError(
            "$T has no declared node :$node_id. Declared nodes: " *
            "$(join(node_ids(T), ", "))."
        )
    )
end

"""
    validate_composite_spec(::Type{T}) where {T <: AbstractStrictCompositeComponent}

Validate `composite_spec(T)` and the type-level hook map `map_hooks(T)`, returning
the spec.

Checks that the spec is a `NamedTuple` with exactly the keys `slots` and `nodes`; that
`slots` is a non-empty `NamedTuple` of `Type{<:AbstractComponent}` values; that `nodes`
is a non-empty `Tuple` of `Pair{Symbol, Symbol}`s with unique node ids, each referencing
a declared slot; that every declared slot is used by at least one node; and that
`map_hooks(T)` keys are `node_id => hook_name` pairs referencing declared node ids with
unique composite hook names as values.

Throws `ArgumentError` naming the offending entry. Called automatically the first time
`graph(cc)` is built; also usable directly (e.g. in a package test suite) to check a
declaration without instantiating the component.
"""
function validate_composite_spec(::Type{T}) where {T <: AbstractStrictCompositeComponent}
    spec = composite_spec(T)
    spec isa NamedTuple || throw(
        ArgumentError("composite_spec($T) must return a NamedTuple, got $(typeof(spec)).")
    )
    Set(propertynames(spec)) == Set((:slots, :nodes)) || throw(
        ArgumentError(
            "composite_spec($T) must have exactly the keys (:slots, :nodes), " *
            "got $(propertynames(spec))."
        )
    )
    slots = spec.slots
    slots isa NamedTuple || throw(
        ArgumentError(
            "composite_spec($T).slots must be a NamedTuple mapping slot names to " *
            "component types, got $(typeof(slots))."
        )
    )
    isempty(slots) &&
        throw(ArgumentError("composite_spec($T).slots must declare at least one slot."))
    for (slot, S) in pairs(slots)
        S isa Type && S <: AbstractComponent || throw(
            ArgumentError(
                "composite_spec($T).slots.$slot must be a Type{<:AbstractComponent}, " *
                "got $(repr(S))."
            )
        )
    end
    nodes = spec.nodes
    nodes isa Tuple || throw(
        ArgumentError(
            "composite_spec($T).nodes must be a Tuple of Pair{Symbol, Symbol}, " *
            "got $(typeof(nodes))."
        )
    )
    isempty(nodes) &&
        throw(ArgumentError("composite_spec($T).nodes must declare at least one node."))
    for node in nodes
        node isa Pair{Symbol, Symbol} || throw(
            ArgumentError(
                "composite_spec($T).nodes entries must be Pair{Symbol, Symbol} " *
                "(:node_id => :slot_name), got $(repr(node))."
            )
        )
    end
    ids = map(first, nodes)
    allunique(ids) || throw(
        ArgumentError(
            "composite_spec($T).nodes has duplicate node ids: " *
            "$(join(unique([id for id in ids if count(==(id), ids) > 1]), ", "))."
        )
    )
    used_slots = Set(map(last, nodes))
    for slot in used_slots
        haskey(slots, slot) || throw(
            ArgumentError(
                "composite_spec($T).nodes references undeclared slot :$slot. " *
                "Declared slots: $(join(keys(slots), ", "))."
            )
        )
    end
    for slot in keys(slots)
        slot in used_slots || throw(
            ArgumentError(
                "composite_spec($T).slots.$slot is not used by any node in " *
                "composite_spec($T).nodes."
            )
        )
    end
    _validate_strict_map_hooks(map_hooks(T), ids, T)
    return spec
end

# Validate a strict hook map against the declared node ids. Shared between
# `validate_composite_spec` (type-level map) and `graph` (instance-level map, which
# subtypes may override like v1's `map_hooks(tr::ExampleStarTransmon)`).
function _validate_strict_map_hooks(mh, ids, ::Type{T}) where {T}
    mh isa AbstractDict || throw(
        ArgumentError(
            "map_hooks for $T must be a Dict{Pair{Symbol, Symbol}, Symbol}, " *
            "got $(typeof(mh))."
        )
    )
    for (k, v) in mh
        k isa Pair{Symbol, Symbol} || throw(
            ArgumentError(
                "map_hooks for $T must use name-based keys " *
                "(:node_id => :hook_name); got key $(repr(k)). " *
                "Strict composite components do not support v1 integer-indexed keys."
            )
        )
        first(k) in ids || throw(
            ArgumentError(
                "map_hooks for $T references undeclared node :$(first(k)). " *
                "Declared nodes: $(join(ids, ", "))."
            )
        )
        v isa Symbol || throw(
            ArgumentError(
                "map_hooks for $T must map to composite hook names (Symbol); " *
                "got value $(repr(v)) for key $(repr(k))."
            )
        )
    end
    vals = collect(values(mh))
    allunique(vals) || throw(
        ArgumentError(
            "map_hooks for $T maps multiple subcomponent hooks to the same " *
            "composite hook name: " *
            "$(join(unique([v for v in vals if count(==(v), vals) > 1]), ", "))."
        )
    )
    return mh
end

"""
    map_hooks(::Type{T}) where {T <: AbstractStrictCompositeComponent}

A `Dict{Pair{Symbol, Symbol}, Symbol}` mapping subcomponent hooks to composite hooks,
keyed by declared node id rather than by graph node index.

For example, the entry `(:island => :readout) => :readout` means the `readout` hook of
the subcomponent at declared node `:island` will be available as `hooks(cc).readout`.

Subcomponent `Hook`s that are not mapped are still available as `:\$(node_id)_\$h`,
where `node_id` is the declared node id and `h` is the hook name (e.g.
`:island_readout`). Hooks of machinery nodes appended by `_graph!` beyond the declared
nodes (e.g. by `route!`) keep the v1 positional fallback `:_\$(i)_\$h`.

The default is an empty `Dict` (every hook gets its fallback name).
"""
function map_hooks(::Type{T}) where {T <: AbstractStrictCompositeComponent}
    return Dict{Pair{Symbol, Symbol}, Symbol}()
end

function compose_hookname(cc::AbstractStrictCompositeComponent, i::Int, h::Symbol)
    ids = node_ids(typeof(cc))
    # Machinery nodes appended by `_graph!` beyond the declared prefix have no stable
    # id in the spec, so they keep the v1 positional fallback naming.
    i <= length(ids) || return Symbol("_$(i)_$h")
    return get(map_hooks(cc), (ids[i] => h), Symbol("$(ids[i])_$h"))
end

"""
    hooks(cc::AbstractStrictCompositeComponent, node_id::Symbol, h::Symbol)

The composite hook corresponding to hook `h` of the subcomponent at declared node
`node_id`.
"""
function hooks(cc::AbstractStrictCompositeComponent, node_id::Symbol, h::Symbol)
    ids = node_ids(typeof(cc))
    i = findfirst(==(node_id), ids)
    isnothing(i) && throw(
        ArgumentError(
            "$(typeof(cc)) has no declared node :$node_id. Declared nodes: " *
            "$(join(ids, ", "))."
        )
    )
    return hooks(cc, compose_hookname(cc, i, h))
end

"""
    _build_subcomponent(cc::AbstractStrictCompositeComponent, ::Val{slot_name})

Per-slot parameter overrides for the framework-derived subcomponent build, as a
`NamedTuple` (or any collection of `Symbol => value` pairs splattable as keyword
arguments to [`set_parameters`](@ref)).

The default returns an empty `NamedTuple` (no overrides). Specialize on
`Val{:slot_name}` to enforce composite invariants that are not simple parameter
forwarding, e.g.

```julia
SchematicDrivenLayout._build_subcomponent(tr::MyTransmon, ::Val{:junction}) =
    (; ground_island_length=tr.junction_gap)
```

Overrides are applied last, taking precedence over forwarded composite parameters and
`ParameterSet` overlays (see [`_build_subcomponents`](@ref) for the full precedence).
"""
_build_subcomponent(::AbstractStrictCompositeComponent, ::Val) = (;)

"""
    _build_subcomponents(cc::AbstractStrictCompositeComponent)

Framework-derived subcomponent construction: build one instance per declared slot,
returned as a `NamedTuple` keyed by slot name.

For each slot, the instance is constructed from the slot type's defaults with parameter
values layered in the following precedence (later wins):

 1. Slot type defaults.
 2. Shared parameters of `cc`: any parameter of `cc` (except `name`) whose name is also
    a parameter name of the slot type.
 3. Prefixed parameters of `cc`: any parameter named `\$(slot_name)_\$(param)` where
    `param` is a parameter name of the slot type.
 4. `ParameterSet` overlay: if `cc` was created from a `ParameterSet` (via
    `create_component(T, ps, address)`), leaves under
    `"components.\$(name(cc)).\$(slot_name)"` are applied with
    [`set_parameters`](@ref), which validates leaf names and records access.
 5. [`_build_subcomponent`](@ref)`(cc, Val(slot_name))` overrides.

The instance's `name` is the slot name. Unlike [`filter_parameters`](@ref), matching
here is quiet: a composite need not share or prefix-forward any parameters to a slot.
"""
function _build_subcomponents(cc::AbstractStrictCompositeComponent)
    slots = composite_spec(typeof(cc)).slots
    return NamedTuple{keys(slots)}(
        map(slot -> _build_slot(cc, slot, slots[slot]), keys(slots))
    )
end

function _build_slot(
    cc::AbstractStrictCompositeComponent,
    slot_name::Symbol,
    ::Type{S}
) where {S <: AbstractComponent}
    forwarded = _forwarded_parameters(S, cc, slot_name)
    comp = create_component(S, String(slot_name); forwarded...)
    ps = parameter_set(cc._graph)
    if !isnothing(ps)
        address = "components." * name(cc) * "." * String(slot_name)
        sub = resolve(ps, address)
        if sub isa ParameterSet
            comp = set_parameters(comp, sub)
        elseif !(sub isa MissingNamespace)
            # A leaf at the slot address is always a mistake (slot parameters live one
            # level deeper); silently ignoring it would drop user data.
            throw(
                ArgumentError(
                    "ParameterSet address \"$address\" resolves to a leaf value " *
                    "($(typeof(sub))), but slot :$slot_name of $(typeof(cc)) " *
                    "expects a namespace of $(S) parameters there."
                )
            )
        end
        # A MissingNamespace just means the PS doesn't customize this slot.
    end
    overrides = _build_subcomponent(cc, Val(slot_name))
    isempty(overrides) && return comp
    return set_parameters(comp; pairs(overrides)...)
end

# Quiet analogue of `filter_parameters` for the derived build: collect the parameters
# of `cc` forwarded to slot `slot_name` of type `S`, by shared name (unprefixed) and by
# `"$(slot_name)_"` prefix, with prefixed matches taking precedence. No warning is
# emitted when nothing matches — a slot with no forwarded parameters is normal here,
# whereas `filter_parameters` treats an empty match as a likely user error.
function _forwarded_parameters(
    ::Type{S},
    cc::AbstractStrictCompositeComponent,
    slot_name::Symbol
) where {S <: AbstractComponent}
    sub_names = parameter_names(S)
    prefix = String(slot_name) * "_"
    shared = Pair{Symbol, Any}[]
    prefixed = Pair{Symbol, Any}[]
    for (k, v) in pairs(parameters(cc))
        # The composite's `name` is never forwarded; slot instances are named after
        # their slot.
        k === :name && continue
        k in sub_names && push!(shared, k => v)
        kstr = String(k)
        if startswith(kstr, prefix)
            # `chop` counts characters (not bytes), matching `length(prefix)`.
            stripped = Symbol(chop(kstr; head=length(prefix), tail=0))
            stripped in sub_names && push!(prefixed, stripped => v)
        end
    end
    # NamedTuple keeps the last occurrence of a duplicate key, so listing `prefixed`
    # second gives it precedence over `shared`.
    return (; shared..., prefixed...)
end

"""
    graph(cc::AbstractStrictCompositeComponent)

The `SchematicGraph` represented by `cc`.

On first call, validates the spec with [`validate_composite_spec`](@ref), builds the
slot instances with [`_build_subcomponents`](@ref), adds one node per declared
`node_id => slot_name` entry (in declaration order, with the declared id), then calls
`_graph!(g, cc, subcomps)` to add edges. After `_graph!` returns, checks that the
declared nodes are still an unmodified prefix of the graph's nodes, so that hook
naming by node id remains valid.
"""
function graph(c::AbstractStrictCompositeComponent)
    !isempty(c._graph.nodes) && return c._graph
    T = typeof(c)
    spec = validate_composite_spec(T)
    # Subtypes may override the instance-level `map_hooks(cc)` (e.g. to make the map
    # depend on parameters), so validate it separately from the type-level map.
    _validate_strict_map_hooks(map_hooks(c), map(first, spec.nodes), T)
    subcomps = subcomp_namedtuple(_build_subcomponents(c))
    for (node_id, slot_name) in spec.nodes
        haskey(subcomps, slot_name) || throw(
            ArgumentError(
                "_build_subcomponents($T) returned no entry for slot :$slot_name " *
                "(node :$node_id). Returned slots: $(join(keys(subcomps), ", "))."
            )
        )
        add_node!(c._graph, subcomps[slot_name]; id=node_id)
    end
    _graph!(c._graph, c, subcomps)
    _validate_declared_nodes(c._graph, spec, T)
    return c._graph
end

# After `_graph!`, the declared nodes must still sit unmodified at indices 1:n —
# hook composition and `flatten` both rely on that positional correspondence.
# `rem_node!` swaps with the last node, so removal or reordering shows up as an id
# mismatch here.
function _validate_declared_nodes(g::SchematicGraph, spec, ::Type{T}) where {T}
    n = length(spec.nodes)
    length(nodes(g)) >= n || throw(
        ArgumentError(
            "_graph!($T) removed declared nodes: expected at least $n nodes, " *
            "found $(length(nodes(g))). _graph! must only add edges (and optionally " *
            "append machinery nodes)."
        )
    )
    for (i, (node_id, _)) in enumerate(spec.nodes)
        actual = nodes(g)[i].id
        actual == String(node_id) || throw(
            ArgumentError(
                "_graph!($T) modified declared nodes: expected node :$node_id at " *
                "index $i, found \"$actual\". _graph! must not remove or reorder " *
                "the declared nodes."
            )
        )
    end
    return nothing
end
