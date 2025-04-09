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
    p = merge_recursive(base_parameters, (; name=name, pairs(kwargs)...))
    return (T)(; p...)
end

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
