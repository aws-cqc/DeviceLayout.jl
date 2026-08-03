struct _UnsupportedParameterValue end
const _UNSUPPORTED_PARAMETER_VALUE = _UnsupportedParameterValue()

_extracted_array_value(value::Union{Number, AbstractString, Symbol, Nothing}) =
    _parameter_value_copy(value)
function _extracted_array_value(value::Vector)
    if isempty(value) &&
       eltype(value) !== Any &&
       !(eltype(value) <: Union{Number, AbstractString, Symbol, Nothing, Vector})
        return _UNSUPPORTED_PARAMETER_VALUE
    end
    result = map(_extracted_array_value, value)
    any(child -> child isa _UnsupportedParameterValue, result) &&
        return _UNSUPPORTED_PARAMETER_VALUE
    return result
end
_extracted_array_value(::Any) = _UNSUPPORTED_PARAMETER_VALUE

function _extracted_parameter_value(value::NamedTuple)
    result = Dict{String, Any}()
    for (key, child) in pairs(value)
        extracted = _extracted_parameter_value(child)
        extracted isa _UnsupportedParameterValue || (result[string(key)] = extracted)
    end
    !isempty(value) && isempty(result) && return _UNSUPPORTED_PARAMETER_VALUE
    return result
end
function _extracted_parameter_value(value::AbstractDict)
    result = Dict{String, Any}()
    for (key, child) in value
        extracted = _extracted_parameter_value(child)
        extracted isa _UnsupportedParameterValue || (result[string(key)] = extracted)
    end
    !isempty(value) && isempty(result) && return _UNSUPPORTED_PARAMETER_VALUE
    return result
end
_extracted_parameter_value(value::Vector) = _extracted_array_value(value)
_extracted_parameter_value(value::Union{Number, AbstractString, Symbol, Nothing}) =
    _parameter_value_copy(value)
_extracted_parameter_value(::Any) = _UNSUPPORTED_PARAMETER_VALUE

function _merge_extracted_namespaces!(
    destination::Dict{String, Any},
    source::Dict{String, Any},
    address::Vector{String}
)
    for (key, value) in source
        if !haskey(destination, key)
            destination[key] = value
        elseif destination[key] isa Dict{String, Any} && value isa Dict{String, Any}
            _merge_extracted_namespaces!(destination[key], value, [address; key])
        else
            path = join([address; key], ".")
            throw(
                ArgumentError(
                    "Cannot extract ParameterSet: component path collides with " *
                    "parameter leaf \"$path\"."
                )
            )
        end
    end
    return destination
end

function _extraction_namespace!(
    destination::Dict{String, Any},
    segments::Vector{String},
    parent_address::Vector{String}
)
    current = destination
    for (index, segment) in enumerate(segments)
        isempty(segment) && throw(
            ArgumentError(
                "Cannot extract ParameterSet: node ID \"$(join(segments, "."))\" " *
                "contains an empty address segment."
            )
        )
        if !haskey(current, segment)
            current[segment] = Dict{String, Any}()
        elseif !(current[segment] isa Dict{String, Any})
            path = join([parent_address; segments[1:index]], ".")
            throw(
                ArgumentError(
                    "Cannot extract ParameterSet: component path collides with " *
                    "parameter leaf \"$path\"."
                )
            )
        end
        current = current[segment]
    end
    return current
end

function _extract_graph_components!(
    destination::Dict{String, Any},
    schematic_graph::SchematicGraph,
    parent_address::Vector{String},
    component_addresses::Set{String}
)
    for node in nodes(schematic_graph)
        segments = String.(split(node.id, '.'; keepempty=true))
        address_segments = [parent_address; segments]
        address = join(address_segments, ".")
        address in component_addresses && throw(
            ArgumentError(
                "Cannot extract ParameterSet: multiple components resolve to \"$address\"."
            )
        )
        push!(component_addresses, address)

        namespace = _extraction_namespace!(destination, segments, parent_address)
        parameter_data = _extracted_parameter_value(parameters(component(node)))
        parameter_data isa _UnsupportedParameterValue &&
            (parameter_data = Dict{String, Any}())
        _merge_extracted_namespaces!(namespace, parameter_data, address_segments)

        comp = component(node)
        if comp isa AbstractCompositeComponent
            _extract_graph_components!(
                namespace,
                graph(comp),
                address_segments,
                component_addresses
            )
        end
    end
    return destination
end

"""
    extract_parameter_set(g::SchematicGraph) -> ParameterSet

Create a detached `ParameterSet` containing the supported final parameters of
the components in `g`.

Each component is stored below `components` at its unique node ID. Dots in node
IDs become nested namespace segments, and composite-component graphs are
recursively nested below their parent component. Parameter values are taken
from the constructed component instances, so defaults and applied overrides
are both included. Scalar values and ordinary one-dimensional `Array`s are
retained. Named tuples and dictionaries form parameter namespaces. Other
values, including `Point`s and component-valued parameters, are omitted.

If `g` carries a source `ParameterSet`, its top-level namespaces other than
`components` are deep-copied into the result. The source `components` namespace
is replaced with the graph-derived component tree. The result has an empty
source path and access log and shares no mutable parameter data with the graph
or source set.

Extraction realizes lazy composite graphs. An `ArgumentError` is thrown if a
component path collides with a parameter leaf.
"""
function extract_parameter_set(g::SchematicGraph)
    data = if isnothing(parameter_set(g))
        Dict{String, Any}()
    else
        Dict{String, Any}(
            key => _parameter_value_copy(value) for
            (key, value) in getfield(parameter_set(g), :data) if key != "components"
        )
    end
    extracted_components = Dict{String, Any}()
    data["components"] = extracted_components
    _extract_graph_components!(extracted_components, g, ["components"], Set{String}())
    return ParameterSet(data)
end
