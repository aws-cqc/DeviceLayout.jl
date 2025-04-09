"""
    base_variant(comp::AbstractComponent)

If `comp` is a [`@variant`](@ref) of some other component type `T <: AbstractComponent`, return an instance of `T` with the same name as `comp`; otherwise, return `comp`.

When the base component shares a parameter with `comp`, then in the returned component,
that parameter will take the value it has in `comp`.
"""
base_variant(comp::T) where {T <: AbstractComponent} = comp

"""
    base_variant(comptype::Type{<:AbstractComponent})

If `comptype` is a [`@variant`](@ref) of some other component type `T <: AbstractComponent`, return `T`; otherwise, return `comptype`.
"""
base_variant(::Type{T}) where {T <: AbstractComponent} = T

function variant_expr(T::Expr, name::Symbol; new_defaults::Expr=:((;)), map_meta=nothing)
    escname = esc(name)
    esctype = esc(:(Type{$name}))
    return quote
        ($T <: AbstractCompositeComponent) &&
            error("Use @composite_variant for CompositeComponent $($T)")
        Base.@__doc__(struct $name <: supertype($T)
            parameters::NamedTuple
            _geometry::CoordinateSystem{coordinatetype($T)}
        end)
        SchematicDrivenLayout.parameters(comp::$escname) = comp.parameters
        SchematicDrivenLayout.parameter_names(::$esctype) =
            union(parameter_names($T), keys($new_defaults))
        SchematicDrivenLayout.default_parameters(::$esctype) =
            merge_recursive(default_parameters($T), $new_defaults)
        Base.getproperty(comp::$escname, prop::Symbol) = begin
            prop === :parameters && return getfield(comp, :parameters)
            prop === :_geometry && return getfield(comp, :_geometry)
            params = getfield(comp, :parameters)
            hasfield(typeof(params), prop) && return getfield(params, prop)
            return getproperty(graph(comp), prop)
        end
        Base.propertynames(comp::$escname) =
            union([:parameters, :_geometry], parameter_names(comp))
        function ($escname)(; kwargs...)
            params = merge_recursive(default_parameters($escname), (; pairs(kwargs)...))
            return ($escname)(
                params,
                CoordinateSystem{coordinatetype($T)}(uniquename(params.name))
            )
        end

        # Base variant has the same name and parameters (for shared parameters)
        SchematicDrivenLayout.base_variant(comp::$escname) =
            create_component($T, comp.name; select(comp.parameters, parameter_names($T))...)
        SchematicDrivenLayout.base_variant(::$esctype) = $T
        # Hooks are the same
        SchematicDrivenLayout.hooks(comp::$escname) = hooks(base_variant(comp))
        # Geometry is the same, unless a map_meta function was specified
        SchematicDrivenLayout._geometry!(cs::CoordinateSystem, comp::$escname) = begin
            _geometry!(cs, base_variant(comp))
            !isnothing($map_meta) && map_metadata!(cs, $map_meta)
        end
        # Allowed rotations are the same
        SchematicDrivenLayout.check_rotation(comp::$escname) =
            check_rotation(base_variant(comp))
        SchematicDrivenLayout.allowed_rotation_angles(comp::$escname) =
            allowed_rotation_angles(base_variant(comp))
        # Last line will be RHS of assignment (@variant MyOwnNameForVariant = BaseComponent)
        $escname
    end
end

function composite_variant_expr(
    T::Expr,
    name::Symbol;
    new_defaults::Expr=:((;)),
    map_meta=nothing
)
    escname = esc(name)
    esctype = esc(:(Type{$name}))
    return quote
        Base.@__doc__(struct $name <: supertype($T)
            parameters::NamedTuple
            _graph::SchematicGraph
            _schematic::Schematic{coordinatetype($T)}
            _hooks::Dict{Symbol, Union{Hook, <:Vector{Hook}}}
        end)

        SchematicDrivenLayout.parameters(comp::$escname) = comp.parameters
        SchematicDrivenLayout.parameter_names(::$esctype) =
            union(parameter_names($T), keys($new_defaults))
        # Default parameters are overridden via recursive merge with new_defaults
        SchematicDrivenLayout.default_parameters(::$esctype) =
            merge_recursive(default_parameters($T), $new_defaults)
        Base.getproperty(comp::$escname, prop::Symbol) = begin
            prop === :parameters && return getfield(comp, :parameters)
            prop === :_geometry && return getfield(comp, :_geometry)
            prop === :_graph && return getfield(comp, :_graph)
            prop === :_schematic && return getfield(comp, :_schematic)
            prop === :_hooks && return getfield(comp, :_hooks)
            return getfield(getfield(comp, :parameters), prop)
        end
        Base.propertynames(comp::$escname) =
            union(parameter_names(comp), [:parameters, :_graph, :_schematic, :_hooks])
        function ($escname)(; kwargs...)
            params = merge_recursive(default_parameters($escname), (; pairs(kwargs)...))
            uname = uniquename(params.name)
            g = SchematicGraph(uname)
            return ($escname)(
                params,
                g,
                Schematic{coordinatetype($T)}(g; log_dir=nothing),
                Dict{Symbol, Union{Hook, <:Vector{Hook}}}()
            )
        end

        # Base variant has the same name and parameters (for shared parameters)
        SchematicDrivenLayout.base_variant(comp::$escname) =
            create_component($T, comp.name; select(comp.parameters, parameter_names($T))...)
        SchematicDrivenLayout.base_variant(::$esctype) = $T
        # Hook map is the same
        SchematicDrivenLayout.map_hooks(::$esctype) = map_hooks($T)
        # Subcomponents are the same
        SchematicDrivenLayout._build_subcomponents(comp::$escname) =
            _build_subcomponents(base_variant(comp))
        # Graph is the same
        SchematicDrivenLayout._graph!(
            g::SchematicGraph,
            comp::$escname,
            subcomps::NamedTuple
        ) = _graph!(g, base_variant(comp), subcomps)
        # Geometry is the same, unless a map_meta function was specified
        SchematicDrivenLayout.geometry_from_graph(cc::$escname) = begin
            floorplan = schematic(cc)
            floorplan.checked[] = true # Skip check
            build!(floorplan)
            !isnothing($map_meta) && map_metadata!(floorplan.coordinate_system, $map_meta)
            return floorplan.coordinate_system
        end
        # Allowed rotations are the same
        SchematicDrivenLayout.check_rotation(comp::$escname) =
            check_rotation(base_variant(comp))
        SchematicDrivenLayout.allowed_rotation_angles(comp::$escname) =
            allowed_rotation_angles(base_variant(comp))
        $escname
    end
end

"""
    @variant NewType BaseType new_defaults=(;) map_meta=nothing

Create `NewType <: AbstractComponent` based on `BaseType`, with optional `new_defaults` and `map_meta`.

Default parameters for the new type will be `new_defaults` merged into `default_parameters(T)`.
You can override the original defaults or add entirely new parameters this way.

If provided, `map_meta` should be a function of `DeviceLayout.Meta` that returns another `DeviceLayout.Meta`.
It will be applied recursively to the geometry of the base component using `map_metadata!`.

Individual methods like `hooks` and `_geometry!` can then be overridden to create variant behavior.
"""
macro variant(new_type, base_type, kws...)
    kwargs = Pair{Symbol, Any}[]
    for kw in kws
        Base.Meta.isexpr(kw, :(=)) || error("""
                                      Invalid macro call: @variant $new_type $base_type $(join(kws," "))"
                                      """)
        push!(kwargs, Pair(kw.args[1], esc(kw.args[2])))
    end
    return variant_expr(esc(base_type), new_type; kwargs...)
end

"""
    @composite_variant NewType BaseType new_defaults=(;) map_meta=nothing

Create `NewType <: AbstractCompositeComponent` based on `BaseType`, with optional `new_defaults` and `map_meta`.

Default parameters for the new type will be `new_defaults` merged into `default_parameters(T)`.

If provided, `map_meta` should be a function of `DeviceLayout.Meta` that returns another `DeviceLayout.Meta`.
It will be applied recursively to the geometry of the base component using [`map_metadata!`](@ref).

Individual methods like `hooks` and `_geometry!` can then be overridden to create variant behavior.
"""
macro composite_variant(new_type, base_type, kws...)
    kwargs = Pair{Symbol, Any}[]
    for kw in kws
        Base.Meta.isexpr(kw, :(=)) || error("""
                                      Invalid macro call: @variant $new_type $base_type $(join(kws," "))"
                                      """)
        push!(kwargs, Pair(kw.args...))
    end
    return composite_variant_expr(esc(base_type), new_type; kwargs...)
end
