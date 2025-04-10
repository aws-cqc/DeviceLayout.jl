"""
    @compdef typedef

This is a helper macro that extends `Base.@kwdef`, which automatically defines a keyword-based constructor for the type
declared in the expression `typedef`, which must be a `struct` or `mutable struct`
expression. The default argument is supplied by declaring fields of the form `field::T = default` or `field = default`. If no default is provided then the keyword argument becomes
a required keyword argument in the resulting type constructor.
Inner constructors can still be defined, but at least one should accept arguments in the
same form as the default inner constructor (i.e. one positional argument per field) in
order to function correctly with the keyword outer constructor.

This generates a `default_parameters` method for the defined type, which returns the
default parameters as a `NamedTuple`. If any parameters are required (have no default),
they do not appear in `default_parameters`.

The new type will also have a `_geometry` field for caching geometry, or `_graph`,
`_schematic`, and `_hooks` fields for composite components. If there is no `name`
field, one will automatically be created with a default name of the type name
(as a string).

If you want to use your own abstract composite supertype, you should define
`SchematicDrivenLayout.iscomposite(::Val{:MyAbstractCompositeComponent}) = true`.

# Examples

```jldoctest
julia> @compdef struct MyComp <: Component
           name::String = "mycomp"
           a::Int = 1         # specified default
           b::String          # required keyword
       end

julia> default_parameters(MyComp)
(name = "mycomp", a = 1)
```
"""
macro compdef(expr)
    # Same as Base.@kwdef
    expr = macroexpand(__module__, expr) # to expand @static
    Base.Meta.isexpr(expr, :struct) || error("Invalid usage of @compdef")
    T = expr.args[2] # struct _________
    S = :(Component) # Default to upreferred Component
    if T isa Expr && T.head === :<: # struct ____ <: Supertype
        S = T.args[2]
        T = T.args[1]
    else
        expr.args[2] = Expr(:(<:), T, S)
    end
    U = :(coordinatetype($S))
    if Base.Meta.isexpr(S, :curly)
        U = S.args[2] # Assume this is the coordinate type...
        S = S.args[1]
    end
    # Can't eval, so test `S::Symbol`. Do we have `iscomposite(::Val{S}) = true` defined?
    # True for AbstractCompositeComponent and CompositeComponent
    composite = iscomposite(Val(S))

    params_ex = Expr(:parameters)
    call_args = Any[]
    _kwdef!(expr.args[3], params_ex.args, call_args, T, U, composite)
    # Composite component has private graph, schematic, hooks; component just has geometry
    public_defaults = composite ? params_ex.args[1:(end - 3)] : params_ex.args[1:(end - 1)]
    # Only define a constructor if the type has fields, otherwise we'll get a stack
    # overflow on construction
    if !isempty(params_ex.args)
        if T isa Symbol
            sig = :(($(esc(T)))($params_ex))
            call = :(($(esc(T)))($(call_args...)))
            body = Expr(:block, __source__, call)
            kwdefs = Expr(:function, sig, body)
            # Define default_parameters method to return NamedTuple of keywords with defaults
            defaults = Expr(
                :(=),
                Expr(
                    :call,
                    esc(:(SchematicDrivenLayout.default_parameters)),
                    :(::Type{$(esc(T))})
                ),
                Expr(
                    :block,
                    __source__,
                    :((; $(filter(arg -> Base.Meta.isexpr(arg, :kw), public_defaults)...)))
                )
            )
        elseif Base.Meta.isexpr(T, :curly)
            # if T == S{A<:AA,B<:BB}, define two methods
            #   S(...) = ...
            #   S{A,B}(...) where {A<:AA,B<:BB} = ...
            S = T.args[1]
            P = T.args[2:end]
            Q = Any[Base.Meta.isexpr(U, :<:) ? U.args[1] : U for U in P]
            SQ = :($S{$(Q...)})
            body1 = Expr(:block, __source__, :(($(esc(S)))($(call_args...))))
            sig1 = :(($(esc(S)))($params_ex))
            def1 = Expr(:function, sig1, body1)
            body2 = Expr(:block, __source__, :(($(esc(SQ)))($(call_args...))))
            sig2 = :(($(esc(SQ)))($params_ex) where {$(esc.(P)...)})
            def2 = Expr(:function, sig2, body2)
            kwdefs = Expr(:block, def1, def2)

            # Define default_parameters method to return NamedTuple of keywords with defaults
            defbody = Expr(
                :block,
                __source__,
                :((; $(filter(arg -> Base.Meta.isexpr(arg, :kw), public_defaults)...)))
            )
            defsig = :(
                $(esc(:SchematicDrivenLayout)).default_parameters(
                    ::Type{$(esc(SQ))}
                ) where {$(esc.(P)...)}
            )
            defaults = Expr(:function, defsig, defbody)
        else
            error("Invalid usage of @compdef")
        end
    else
        kwdefs = nothing
    end
    return quote
        Base.@__doc__ $(esc(expr))
        $kwdefs
        $defaults
    end
end

# @kwdef helper function
# mutates arguments inplace
function _kwdef!(blk, params_args, call_args, T, U, composite)
    for i in eachindex(blk.args)
        ei = blk.args[i]
        if ei isa Symbol
            #  var
            push!(params_args, ei)
            push!(call_args, ei)
        elseif ei isa Expr
            is_atomic = ei.head === :atomic
            ei = is_atomic ? first(ei.args) : ei # strip "@atomic" and add it back later
            is_const = ei.head === :const
            ei = is_const ? first(ei.args) : ei # strip "const" and add it back later
            # Note: `@atomic const ..` isn't valid, but reconstruct it anyway to serve a nice error
            if ei isa Symbol
                # const var
                push!(params_args, ei)
                push!(call_args, ei)
            elseif ei.head === :(=)
                lhs = ei.args[1]
                if lhs isa Symbol
                    #  var = defexpr
                    var = lhs
                elseif lhs isa Expr && lhs.head === :(::) && lhs.args[1] isa Symbol
                    #  var::T = defexpr
                    var = lhs.args[1]
                else
                    # something else, e.g. inline inner constructor
                    #   F(...) = ...
                    continue
                end
                defexpr = ei.args[2]  # defexpr
                push!(params_args, Expr(:kw, var, esc(defexpr)))
                push!(call_args, var)
                lhs = is_const ? Expr(:const, lhs) : lhs
                lhs = is_atomic ? Expr(:atomic, lhs) : lhs
                blk.args[i] = lhs # overrides arg
            elseif ei.head === :(::) && ei.args[1] isa Symbol
                # var::Typ
                var = ei.args[1]
                push!(params_args, var)
                push!(call_args, var)
            elseif ei.head === :block
                # can arise with use of @static inside type decl
                _kwdef!(ei, params_args, call_args)
            end
        end
    end

    # Make sure we have a name field
    idx = findfirst(var -> var == :name, call_args)
    name = (isnothing(idx) ? string(T) : params_args[idx].args[2])
    if isnothing(idx)
        var = :name
        lhs = Expr(:(::), var, :String)
        defexpr = name

        push!(params_args, Expr(:kw, var, defexpr))
        push!(call_args, var)
        push!(blk.args, lhs)
    end

    if !composite # Create empty geometry
        var = :_geometry
        lhs = Expr(:(::), var, :(CoordinateSystem{$U}))
        defexpr = :(CoordinateSystem{$(esc(U))}(uniquename(name)))

        push!(params_args, Expr(:kw, var, defexpr))
        push!(call_args, var)
        push!(blk.args, lhs)
    else # If S is an AbstractCompositeComponent, create an empty graph, schematic
        var = :_graph
        lhs = Expr(:(::), var, :SchematicGraph)
        defexpr = :(SchematicGraph(uniquename(name)))

        push!(params_args, Expr(:kw, var, defexpr))
        push!(call_args, var)
        push!(blk.args, lhs)

        var = :_schematic
        lhs = Expr(:(::), var, :(Schematic{$U}))
        defexpr = :(Schematic{$(esc(U))}(_graph; log_dir=nothing))

        push!(params_args, Expr(:kw, var, defexpr))
        push!(call_args, var)
        push!(blk.args, lhs)

        var = :_hooks
        lhs = Expr(:(::), var, :(Dict{Symbol, Union{Hook, Vector{<:Hook}}}))
        defexpr = :(Dict{Symbol, Union{Hook, Vector{<:Hook}}}())

        push!(params_args, Expr(:kw, var, defexpr))
        push!(call_args, var)
        push!(blk.args, lhs)
    end

    return blk
end
