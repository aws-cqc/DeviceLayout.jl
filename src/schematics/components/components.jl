##### GeometryStructure interface
DeviceLayout.elements(c::AbstractComponent) = elements(geometry(c))
DeviceLayout.element_metadata(c::AbstractComponent) = element_metadata(geometry(c))
DeviceLayout.refs(c::AbstractComponent) = refs(geometry(c))
DeviceLayout.transform(c::AbstractComponent, f::DeviceLayout.Transformation) =
    transform(geometry(c), f)

##### Component interface
"""
    default_parameters(::Type{T}) where T <: AbstractComponent
    default_parameters(::T) where T <: AbstractComponent

A `NamedTuple` of default parameters for component type `T`.
"""
default_parameters(::Type{T}) where {T <: AbstractComponent} = (; name=string(T))
default_parameters(::T) where {T <: AbstractComponent} = default_parameters(T)

"""
    parameter_names(::Type{T}) where T <: AbstractComponent
    parameter_names(::T) where T <: AbstractComponent

Parameter name `Symbol`s for component type `T`.
"""
parameter_names(::Type{T}) where {T <: AbstractComponent} =
    setdiff(fieldnames(T), [:_geometry, :_graph, :_schematic, :_hooks])
parameter_names(::T) where {T <: AbstractComponent} = parameter_names(T)

##### Creation
"""
    create_component(
        ::Type{T},
        name::String=default_parameters(T).name,
        base_parameters::NamedTuple=default_parameters(T);
        kwargs...
    ) where {T <: AbstractComponent}

Create an instance of type `T` with name `name` and parameters derived by merging `kwargs` into `base_parameters`.

The parameter merge is recursive, meaning that a `NamedTuple` keyword argument
will be merged into the corresponding `NamedTuple` base parameter. This can be convenient
because not every "subparameter" within that `NamedTuple` needs to be specified.
This is in contrast to the default component keyword constructor, which does not merge recursively.
"""
function create_component(
    ::Type{T},
    name::String=default_parameters(T).name,
    base_parameters::NamedTuple=default_parameters(T);
    kwargs...
) where {T <: AbstractComponent}
    # Surface ParameterSet-shaped values at the call site rather than silently
    # storing them in the component and erroring later.
    for (k, v) in kwargs
        # Failed PS lookup (typo or stale address) — surface the qualified path.
        v isa MissingNamespace &&
            throw(ParameterKeyError(getfield(v, :key), _namespace_path(v)))
        # A ParameterSet (root or scoped view) is never a valid component-field
        # value; the user almost certainly forgot a leaf access. Templates-aliasing
        # is the right entry point for overlaying a ParameterSet subtree.
        v isa ParameterSet && throw(
            ArgumentError(
                "kwarg `$k` received a `ParameterSet`. Did you forget a leaf " *
                "access (e.g. `ps.components.x.length` instead of `ps.components.x`)? " *
                "To overlay an entire ParameterSet subtree onto a template, use " *
                "`set_parameters(c, ps, address)` rather than passing the subtree " *
                "as a kwarg."
            )
        )
    end
    p = merge_recursive(base_parameters, (; name=name, pairs(kwargs)...))
    return (T)(; p...)
end

"""
    create_component(::Type{T}, ps::ParameterSet, address::String) where {T <: AbstractComponent}

Create an instance of type `T` using parameters from a `ParameterSet` at the given `address`.

The address is resolved to a scoped `ParameterSet`, and the call is delegated to
[`create_component(T, sub::ParameterSet)`](@ref). That overload splats the
leaves at `sub` as keyword arguments into the keyword-only `create_component(T; kwargs...)`,
which merges them recursively with `default_parameters(T)`. Nested namespaces
below `address` are not merged - scope at the level whose leaves match `T`'s
parameters.

Consumed leaves (those matching `parameter_names(T)`) are recorded in `ps.accessed`
as qualified paths rooted at the original PS.
"""
function create_component(
    ::Type{T},
    ps::ParameterSet,
    address::String
) where {T <: AbstractComponent}
    return create_component(T, resolve(ps, address))
end

"""
    create_component(::Type{T}, sub::ParameterSet) where {T <: AbstractComponent}

Create an instance of type `T` from a scoped `ParameterSet`, typically obtained by
chained-dot access like `ps.components.transmon.junction`.

Leaf parameters (non-`Dict` values) at `sub` are extracted via `leaf_params` and
passed as keyword arguments. Consumed leaves are recorded in the shared `accessed`
set as qualified paths (e.g. `"components.transmon.junction.w_jj"`), matching the
behavior of the address-string form.

`sub` must be a scoped view (non-empty prefix); passing a root `ParameterSet`
raises an `ArgumentError` because bare leaf names at the root have no meaningful
qualified path and the use case is ambiguous - use the address-string form.

# Example

```julia
junction = create_component(ExampleSimpleJunction, ps.components.transmon.junction)
```
"""
function create_component(
    ::Type{T},
    sub::ParameterSet;
    kwargs...
) where {T <: AbstractComponent}
    prefix = getfield(sub, :prefix)
    isempty(prefix) && throw(
        ArgumentError(
            "create_component(T, ::ParameterSet) requires a scoped view " *
            "(e.g. `ps.components.qubit`). For a root ParameterSet, use " *
            "`create_component(T, ps, address)` with an explicit address."
        )
    )
    kw = leaf_params(sub)
    # Track accessed parameter leaves with the scoped ParameterSet's qualified prefix
    accessed = getfield(sub, :accessed)
    for k in keys(kw)
        if k in parameter_names(T)
            push!(accessed, prefix * "." * String(k))
        end
    end
    # `kwargs` lets callers inject fields like `_graph=...` - e.g. the composite
    # address-form needs to thread the root PS into the composite's private graph.
    return create_component(T; kwargs..., pairs(kw)...)
end

# Reached when `create_component(T, ps, address)` or `create_component(T, ps.x.y)`
# targets a path that does not exist. Surface the qualified path in a
# ParameterKeyError instead of letting the caller see a generic MethodError.
function create_component(::Type{<:AbstractComponent}, sub::MissingNamespace)
    throw(ParameterKeyError(getfield(sub, :key), _namespace_path(sub)))
end

# Composite-specific `create_component` specializations live in
# `composite_components.jl` (included after this file) because they dispatch
# on `AbstractCompositeComponent`.

"""
    (c::AbstractComponent)(
        name::String=name(c),
        params::NamedTuple=parameters(c);
        kwargs...
    )

Create an instance of type `typeof(c)` with name `name` and parameters derived by merging `kwargs` into `params.

The parameter merge is recursive, meaning that a `NamedTuple` keyword argument
will be merged into the corresponding `NamedTuple` base parameter. This can be convenient
because not every "subparameter" within that `NamedTuple` needs to be specified.
This is in contrast to the default component keyword constructor, which does not merge recursively.

This is equivalent to `set_parameters(c, name, params; kwargs...)`.
"""
function (c::AbstractComponent)(
    name::String=name(c),
    params::NamedTuple=parameters(c);
    kwargs...
)
    return create_component(typeof(c), name, params; kwargs...)
end

"""
    set_parameters(
        c::AbstractComponent,
        name::String=name(c),
        params::NamedTuple=parameters(c);
        kwargs...
    )

Create an instance of type `typeof(c)` with name `name` and parameters derived by merging `kwargs` into `params.

The parameter merge is recursive, meaning that a `NamedTuple` keyword argument
will be merged into the corresponding `NamedTuple` base parameter. This can be convenient
because not every "subparameter" within that `NamedTuple` needs to be specified.
This is in contrast to the default component keyword constructor, which does not merge recursively.

This can also be written by calling the component instance `c` like a function:
`c(name, params; kwargs...)`.
"""
function set_parameters(
    c::AbstractComponent,
    name::String=name(c),
    params::NamedTuple=parameters(c);
    kwargs...
)
    return create_component(typeof(c), name, params; kwargs...)
end

"""
    set_parameters(c::AbstractComponent, ps::ParameterSet, address::String; kwargs...)

Apply `ParameterSet` leaves at `address` on top of the template instance `c`,
optionally followed by composite-level keyword overrides.

Starting from `c`'s parameters as the base, each leaf under `resolve(ps, address)`
overrides the corresponding field. Nested namespaces below `address` are ignored —
scope at the level whose leaves match `c`'s parameters. Any `kwargs` are then
applied on top of the `ParameterSet` overlay, so precedence is:
template defaults < `ParameterSet` overlay < `kwargs`.

Throws `ParameterKeyError` if `address` doesn't resolve to anything (no such
namespace), or if a `kwarg` value is a `MissingNamespace` (failed PS lookup).
Throws `ArgumentError` if `address` resolves to a leaf scalar rather than a
namespace, if any leaf under `address` is not a parameter of `typeof(c)`
(surfaces typos at aliasing time rather than as a `MethodError` inside the
constructor), or if a `kwarg` value is itself a `ParameterSet` (a subtree is
never a valid component-field value and almost always indicates a missing
leaf access).

Every PS leaf under `address` is recorded in `ps.accessed` as a fully qualified
path — including leaves whose value happens to equal the template's default and
leaves that are subsequently shadowed by a trailing `kwarg`. The audit semantics
is "the loader read this PS leaf during build", not "this value reached the
final component". A trailing `kwarg` that overrides a PS leaf does not unmark it.

This is the "templates-aliasing" entry point: a composite declares subcomponent
defaults in a `templates` field, then `_build_subcomponents` overlays `ParameterSet`
values on top of each template via this overload, optionally with trailing
composite-level kwargs to enforce composite invariants.

```julia
function _build_subcomponents(tr::MyTransmon)
    ps = parameter_set(tr._graph)
    island = set_parameters(
        tr.templates.island,
        ps,
        "components.\$(name(tr)).island";
        junction_gap=tr.junction_gap
    )
    return (island,)
end
```
"""
function set_parameters(c::AbstractComponent, ps::ParameterSet, address::String; kwargs...)
    # An empty address would hand the root `ps` to the scoped form, which
    # rejects roots with a message telling the caller to use the address-form
    # — confusing when they just did. Reject empty addresses up front.
    isempty(address) && throw(
        ArgumentError(
            "set_parameters(c, ps, address): `address` must be non-empty. " *
            "Pass the dot-separated path to the namespace whose leaves " *
            "match `c`'s parameters (e.g. \"components.transmon.island\")."
        )
    )
    sub = resolve(ps, address)
    sub isa MissingNamespace &&
        throw(ParameterKeyError(getfield(sub, :key), _namespace_path(sub)))
    # `resolve` returns a leaf value when the address terminates at a scalar
    # (e.g. "components.x.junction_gap"). That's never a valid argument to the
    # scoped form below — surface it directly with an actionable message rather
    # than letting dispatch fall through to a generic MethodError.
    sub isa ParameterSet || throw(
        ArgumentError(
            "address \"$address\" resolves to a leaf value ($(typeof(sub))), " *
            "not a ParameterSet namespace. `set_parameters(c, ps, address)` " *
            "expects `address` to point at the namespace whose leaves match " *
            "`c`'s parameters; pass a leaf as a kwarg instead, e.g. " *
            "`set_parameters(c; <param>=resolve(ps, \"$address\"))`."
        )
    )
    overlaid = set_parameters(c, sub)
    isempty(kwargs) && return overlaid
    return set_parameters(overlaid; kwargs...)
end

"""
    set_parameters(c::AbstractComponent, sub::ParameterSet)

Apply leaves from a scoped `ParameterSet` on top of `c`.

`sub` must be a scoped view (non-empty prefix, typically reached via chained-dot
access like `ps.components.transmon.island`). For a root `ParameterSet` use the
address-string form instead.

Throws `ArgumentError` if any leaf in `sub` is not a parameter of `typeof(c)`,
surfacing typos in the `ParameterSet` source early.

Every leaf in `sub` is pushed into `ps.accessed` with its qualified path, even
when the leaf's value happens to equal the field's existing value on `c`. The
recorded fact is "the loader read this PS leaf", not "the value differed from
the template default".
"""
function set_parameters(c::AbstractComponent, sub::ParameterSet)
    prefix = getfield(sub, :prefix)
    isempty(prefix) && throw(
        ArgumentError(
            "set_parameters(c, ::ParameterSet) requires a scoped view " *
            "(e.g. `ps.components.transmon.island`). For a root ParameterSet " *
            "use `set_parameters(c, ps, address)` with an explicit address."
        )
    )
    kw = leaf_params(sub)
    names_c = parameter_names(typeof(c))
    unknown = [String(k) for k in keys(kw) if !(k in names_c)]
    if !isempty(unknown)
        throw(
            ArgumentError(
                "ParameterSet at \"$prefix\" has unknown leaves for " *
                "$(typeof(c)): $(join(unknown, ", ")). " *
                "Valid parameters: $(join(names_c, ", "))."
            )
        )
    end
    accessed = getfield(sub, :accessed)
    for k in keys(kw)
        push!(accessed, prefix * "." * String(k))
    end
    return set_parameters(c; pairs(kw)...)
end

# Reached when a caller passes a chained-dot lookup that fizzled, e.g.
# `set_parameters(c, ps.foo.bar)` where `foo` (or any segment after) is not a
# namespace in `ps`. The address-form `set_parameters(c, ps, address)` already
# guards `MissingNamespace` before delegating, so this method exists as
# defense-in-depth for the direct-invocation path. Surface the qualified path
# in a `ParameterKeyError` rather than a generic `MethodError`.
function set_parameters(::AbstractComponent, sub::MissingNamespace)
    return throw(ParameterKeyError(getfield(sub, :key), _namespace_path(sub)))
end

Base.show(io::IO, ::MIME"text/plain", c::T) where {T <: AbstractComponent} =
    print(io, "$T \"$(name(c))\" with non-default parameters $(non_default_parameters(c))")

"""
    non_default_parameters(c::AbstractComponent)

A `NamedTuple` of the parameters of `c` that were set to values other than their defaults.
"""
function non_default_parameters(c::AbstractComponent)
    changed = Symbol[]
    for (k, v) in pairs(parameters(c))
        (k == :_geometry || k == :_graph || k == :_schematic || k == :_hooks) && continue
        if !haskey(default_parameters(c), k) || !(default_parameters(c)[k] == v)
            if v isa Tuple && all(v .== default_parameters(c)[k])
                continue
            end
            push!(changed, k)
        end
    end
    return NamedTupleTools.select(parameters(c), changed)
end

"""
    name(comp::AbstractComponent)

The component's name.
"""
name(comp::AbstractComponent) = comp.name

"""
    parameters(comp::AbstractComponent)

The component's `NamedTuple` of parameters.
"""
parameters(comp::AbstractComponent) = select(ntfromstruct(comp), parameter_names(comp))

"""
    hooks(comp::AbstractComponent)

A component's `Hook`s (a set of locations and rules for attaching to other components).

Returns a `NamedTuple` of `Hook`s and/or arrays of `Hook`s for a AbstractComponent instance.
To access a `Hook` directly whether or not it's in an array, use
[`hooks(::AbstractComponent, ::Symbol)`](@ref).
"""
hooks(::AbstractComponent) = (;)

"""
    hooks(comp::AbstractComponent, h::Symbol)

A component's `Hook` identified by `h`.

Preferred way to retrieve a hook over accessing the `NamedTuple` directly (`hooks(comp).h`).
Allows access to hooks in arrays by interpreting `:hookname_i` as `hooks(comp).hookname[i]`
if `:hookname_i` is not itself a key in `hooks(comp)`.
"""
function hooks(comp::AbstractComponent, h::Symbol)
    hasproperty(hooks(comp), h) && return getproperty(hooks(comp), h)

    s = rsplit(string(h), "_", limit=2)
    if length(s) == 2
        idx = tryparse(Int, s[2])
        if !isnothing(idx) && hasproperty(hooks(comp), Symbol(s[1]))
            return hooks(comp, Symbol(s[1]), idx)
        end
    end
    return error(
        "$(typeof(comp)) $(name(comp)) has no hook $h. Available hooks are $(keys(hooks(comp)))."
    )
end

function hooks(comp::AbstractComponent, h::Symbol, idx::Int)
    h_arr = hooks(comp, h)
    try
        return h_arr[idx]
    catch
        error("$(typeof(comp)) $(name(comp)): No hook $h[$idx] or $(h)_$idx")
    end
end

function has_hook(comp::AbstractComponent, h::Symbol)
    hasproperty(hooks(comp), h) && return true

    s = rsplit(string(h), "_", limit=2)
    if length(s) == 2
        # check that hook array exists; if so, is it a valid index?
        idx = tryparse(Int, s[2])
        if !isnothing(idx) && hasproperty(hooks(comp), Symbol(s[1]))
            return idx in eachindex(hooks(comp, Symbol(s[1])))
        end
    end
    return false
end

"""
    geometry(comp::AbstractComponent)

A `CoordinateSystem` containing the `AbstractComponent`'s geometry with metadata.

The result for each unique `comp` (by `===`) is memoized.

The result has `result.name == uniquename(name(comp))`.
"""
function geometry(comp::AbstractComponent)
    # If we have a _geometry field, then use that to cache the result
    if hasproperty(comp, :_geometry)
        !isempty(comp._geometry) && return comp._geometry
        _geometry!(comp._geometry, comp)
        return comp._geometry
    end
    # Otherwise, just make a new CS with a unique name
    cs = CoordinateSystem{coordinatetype(comp)}(uniquename(name(comp)))
    _geometry!(cs, comp)
    return cs
end

"""
    _geometry!(cs::CoordinateSystem, comp::AbstractComponent)

Render the geometry of `comp` to `cs`.
"""
function _geometry!(cs::CoordinateSystem, comp::AbstractComponent) end

_footprint!(cs::AbstractCoordinateSystem, comp::AbstractComponent, meta) =
    render!(cs, DeviceLayout.footprint(comp), meta)
function footprint(comp::AbstractComponent, meta)
    cs = CoordinateSystem(uniquename(name(comp) * "_foot"), nm)
    _footprint!(cs, comp, meta)
    return cs
end
make_footprint(meta) = (c) -> footprint(c, meta)

"""
    check_rotation(::AbstractComponent)

Determines whether the global orientation of a component will be checked by
`check!(::Schematic)`. `check_rotation(::AbstractComponent`) returns `false`, so any components
of type `T` requiring rotation checks must overload
this method as `check_rotation(::T) = true`. Checkable components
must also overload the method `allow_rotation_angles(::T)`.
"""
check_rotation(::AbstractComponent) = false

"""
    allowed_rotation_angles(::AbstractComponent)

Return a vector of allowed rotation angles. If the net rotation of a component in a
planned `Schematic` (the rotation of its native axes relative to the axes of the
global coordinate system) matches a number in this list, the component passes the check.
"""
allowed_rotation_angles(::AbstractComponent) = nothing

"""
    halo(c::AbstractComponent, delta, inner_delta=nothing; only_layers=[], ignore_layers=[])

A component's halo, intended for use as an exclusion zone parameterized by a bias `delta`.

By default, this applies a `delta` halo to all `geometry` elements whose metadata matches
the inclusion/exclusion requirements. For example, polygons are offset
by `delta` (enlarged by growing `delta` away from each original edge).
Any entities in layers in `ignore_layers` will be skipped.
If `only_layers` is not empty, only those layers will be used to generate the halo.
Layers for inclusion and exclusion can be provided as layer name `Symbol`s, in which case
only the layer name needs to be matched, or as full `DeviceLayout.Meta` objects, in which case all
metadata fields (e.g., index and level for `SemanticMeta`) must match.

An `inner_delta` may be specified to subtract the halo at that bias from the result.

`AbstractComponent`s may define their own `halo` methods.
"""
function halo(c::AbstractComponent, outer_delta, inner_delta=nothing; kwargs...)
    cs = geometry(c)
    return halo(cs, outer_delta, inner_delta; kwargs...)
end

"""
    footprint_halo(comp::AbstractComponent, outer_delta, inner_delta=nothing; kwargs...)

Compute a component's halo from its [`footprint`](@ref) rather than from all geometry elements.

This is much cheaper than the default `halo(::AbstractComponent, ...)` when the component has
a simple bounding entity (e.g., a `circle_polygon` or `Rectangle`) that covers all its geometry.
The footprint is `halo`ed once and replicated across all matching layers.

Component authors opt in by defining a `footprint` method and delegating:

```julia
DeviceLayout.footprint(c::MyComponent) = circle_polygon(c.outer_radius + c.gap)
DeviceLayout.halo(c::MyComponent, d, d_i=nothing; kw...) = footprint_halo(c, d, d_i; kw...)
```

Keyword arguments `only_layers` and `ignore_layers` are forwarded with
the same semantics as [`halo(::CoordinateSystem, ::Any, ::Any)`](@ref).

Custom footprints can be validated with [`DeviceLayout.has_valid_footprint`](@ref).
"""
function footprint_halo(
    comp::AbstractComponent{T},
    outer_delta,
    inner_delta=nothing;
    only_layers=[],
    ignore_layers=[],
    memoized_halos=Dict{GeometryStructure, GeometryStructure}()
) where {T}
    haskey(memoized_halos, comp) && return memoized_halos[comp]

    halo_cs = CoordinateSystem{T}(uniquename("halo_" * name(comp)))
    memoized_halos[comp] = halo_cs

    fp_halo = halo(footprint(comp), outer_delta, inner_delta)

    cs = geometry(comp)
    all_meta = unique(_collect_metadata(cs))
    halo_meta = filter(layer_inclusion(only_layers, ignore_layers), all_meta)
    for meta in halo_meta
        place!.(halo_cs, fp_halo, meta)
    end

    return halo_cs
end

function _collect_metadata(cs::GeometryStructure, seen=Set{UInt}())
    id = objectid(cs)
    id in seen && return eltype(element_metadata(cs))[]
    push!(seen, id)
    result = collect(element_metadata(cs))
    for ref in refs(cs)
        append!(result, _collect_metadata(structure(ref), seen))
    end
    return result
end

##### Macros
"""
    @component comp = MyComponent param1=val1 param2=val2 ...
    @component comp = MyComponent begin
        param1 = val1
        param2 = val2
        ...
    end
    @component comp[1:10] = MyComponent begin 
        param1 .= vals1_vec
        param2 = val2
        ...
    end
    @component comp[1:10, 1:10] = MyComponent begin
        param1 .= vals1_arr
        param2 = val2
        ...
    end

Create a `Component` or vector of components with specified name and parameters.

For a single component, the symbol on the left-hand side is passed as the `name` of the
component. Parameters can be provided like keyword arguments on the same line or in a
block (multiple lines enclosed by `begin` and `end`).

If the left-hand side is written as `comp[1:n]`, then `comp` will be an array of `n`
components with names `comp1`, `comp2`, ..., `comp\$n`. A parameter can be passed to all instances
using the same syntax as for a single component, or each component can be passed its parameter
out of a vector of parameters values `vals_vec` by using broadcast assignment (`param .= vals_vec`).

Similarly, multidimensional arrays of components can be created using `@component comp[1:m, 1:n]`.

A component instance can also be used in place of the component type, in which case the
"default" values for unspecified parameters will be those of that component.
"""
macro component(name_equals_type, params...)
    Base.Meta.isexpr(name_equals_type, :(=)) ||
        error("Invalid macro call: @component $name_equals_type")
    compname, comptype = name_equals_type.args

    return component_expr(compname, comptype, params...)
end

function check_name(name)
    return name isa Symbol || throw(
        Base.Meta.ParseError(
            "The left-hand side must be a symbol (comp) or a ref (comp[1:10]). Got $name."
        )
    )
end

function parse_param!(kwargs, vector_kwargs, ex::Expr)
    Base.Meta.isexpr(ex, :(=)) || Base.Meta.isexpr(ex, :(.=)) || error("""
                                Invalid parameter expression: @component ... $ex"
                                """)
    if Base.Meta.isexpr(ex, :(.=)) # Vector of parameters
        push!(vector_kwargs, Pair(ex.args[1], esc(ex.args[2])))
    else
        push!(kwargs, Pair(ex.args[1], esc(ex.args[2])))
    end
end

function component_expr(compname, comptype, params...)
    kwargs = Pair{Symbol, Any}[]
    vector_kwargs = Pair{Symbol, Any}[]
    # Parse parameters
    for expr in params
        if Base.Meta.isexpr(expr, :block) # begin ... end
            for ex in expr.args
                ex isa LineNumberNode && continue
                parse_param!(kwargs, vector_kwargs, ex)
            end
        else
            parse_param!(kwargs, vector_kwargs, expr)
        end
    end
    params = (; kwargs...)
    vector_params = (; vector_kwargs...)
    if Base.Meta.isexpr(compname, :ref)
        # Make a vector of components
        vecname, idxs... = compname.args
        ndims = length(idxs)
        dims = [esc(i) for i in idxs]
        check_name(vecname)
        namestr = "$vecname"
        escname = esc(vecname)
        esctype = esc(comptype)
        return quote
            vals = ($(values(params)...),)
            param_tuple = NamedTuple{keys($params)}(vals)
            T = ($esctype isa AbstractComponent ? typeof($esctype) : $esctype)
            $escname = Array{T, $ndims}(undef, length.([$(dims...)])...)
            for i in eachindex($escname) # Select the ith value for all vectorized parameters
                vector_vals = ($(values(vector_params)...),)
                vector_tuple = NamedTuple{keys($vector_params)}(getindex.(vector_vals, i))
                if $esctype isa AbstractComponent
                    setindex!(
                        $escname,
                        ($esctype)($namestr * string(i); param_tuple..., vector_tuple...),
                        i
                    )
                else
                    setindex!(
                        $escname,
                        create_component(
                            T;
                            name=($namestr * string(i)),
                            param_tuple...,
                            vector_tuple...
                        ),
                        i
                    )
                end
            end
            $escname
        end
    else
        return single_component_expr(compname, comptype; kwargs...)
    end
end

function single_component_expr(compname, comptype; params...)
    check_name(compname)
    namestr = "$compname"
    escname = esc(compname)
    esctype = esc(comptype)
    return quote
        vals = ($(values(params)...),)
        param_tuple = NamedTuple{keys($params)}(vals)
        $escname = if $esctype isa AbstractComponent
            ($esctype)($namestr; param_tuple...)
        else
            create_component($esctype; name=($namestr), param_tuple...)
        end
        $escname
    end
end

DeviceLayout.coordsys_name(comp::AbstractComponent) = name(geometry(comp))
