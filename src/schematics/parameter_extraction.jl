"""
    extract_parameters(schematic::Schematic) -> Dict
    extract_parameters(g::SchematicGraph) -> Dict

Walk the component hierarchy and return a dictionary with two top-level keys:
- `:defaults` — maps each component type name to its `default_parameters`
- `:components` — maps each node id to its parameters, with nested `:subcomponents`
"""
function extract_parameters(sch::Schematic)
    return extract_parameters(sch.graph)
end

function extract_parameters(g::SchematicGraph)
    defaults = Dict{String,Any}()
    components_dict = Dict{String,Any}()

    for node in nodes(g)
        comp = component(node)
        _collect_defaults!(defaults, comp)
        components_dict[node.id] = _extract_node(comp, defaults)
    end

    return Dict("defaults" => defaults, "components" => components_dict)
end

function _collect_defaults!(defaults::Dict, comp::AbstractComponent)
    type_name = string(nameof(typeof(comp)))
    if !haskey(defaults, type_name)
        defaults[type_name] = _params_to_dict(default_parameters(typeof(comp)))
    end
    if comp isa AbstractCompositeComponent
        for sub_comp in components(comp)
            _collect_defaults!(defaults, sub_comp)
        end
    end
end

function _extract_node(comp::AbstractComponent, defaults::Dict)
    type_name = string(nameof(typeof(comp)))
    entry = Dict{String,Any}(
        "type" => type_name,
        "parameters" => _params_to_dict(non_default_parameters(comp))
    )
    if comp isa AbstractCompositeComponent
        subs = Dict{String,Any}()
        for sub_node in nodes(graph(comp))
            sub_comp = component(sub_node)
            subs[sub_node.id] = _extract_node(sub_comp, defaults)
        end
        if !isempty(subs)
            entry["subcomponents"] = subs
        end
    end
    return entry
end

function _params_to_dict(params::NamedTuple)
    d = Dict{String,Any}()
    for (k, v) in pairs(params)
        k === :name && continue
        d[string(k)] = _format_value(v)
    end
    return d
end

function _format_value(v)
    if v isa Unitful.Quantity
        return string(v)
    elseif v isa AbstractComponent
        return string(nameof(typeof(v)))
    elseif v isa Tuple
        return [_format_value(x) for x in v]
    elseif v isa AbstractArray
        return [_format_value(x) for x in v]
    elseif v isa NamedTuple
        return _params_to_dict(v)
    else
        return v
    end
end

# --- YAML serialization ---

"""
    parameters_to_yaml(schematic; io=stdout)
    parameters_to_yaml(g::SchematicGraph; io=stdout)

Extract parameters from a schematic and write YAML with anchored defaults
and merge-key-based component instances.
"""
function parameters_to_yaml(sch::Schematic; io::IO=stdout)
    return parameters_to_yaml(sch.graph; io=io)
end

function parameters_to_yaml(g::SchematicGraph; io::IO=stdout)
    data = extract_parameters(g)
    _write_yaml(io, data)
end

function parameters_to_yaml(sch_or_graph, filename::AbstractString)
    open(filename, "w") do io
        parameters_to_yaml(sch_or_graph; io=io)
    end
end

function _write_yaml(io::IO, data::Dict)
    defaults = data["defaults"]
    comps = data["components"]

    println(io, "components:")

    println(io, "  default_parameters:")
    for (type_name, params) in sort(collect(defaults); by=first)
        anchor = _anchor_name(type_name)
        println(io, "    $type_name: &$anchor")
        _write_yaml_dict(io, params, 6)
    end

    println(io)
    for (node_id, entry) in sort(collect(comps); by=first)
        println(io, "  $node_id:")
        _write_component_entry(io, entry, 4)
    end
end

function _write_component_entry(io::IO, entry::Dict, indent::Int)
    prefix = " " ^ indent
    type_name = entry["type"]
    anchor = _anchor_name(type_name)

    println(io, prefix, "type: ", type_name)
    println(io, prefix, "<<: *", anchor)

    params = entry["parameters"]
    if !isempty(params)
        for (k, v) in sort(collect(params); by=first)
            println(io, prefix, k, ": ", _yaml_value(v))
        end
    end

    if haskey(entry, "subcomponents")
        println(io, prefix, "subcomponents:")
        for (sub_id, sub_entry) in sort(collect(entry["subcomponents"]); by=first)
            println(io, prefix, "  ", sub_id, ":")
            _write_component_entry(io, sub_entry, indent + 4)
        end
    end
end

function _write_yaml_dict(io::IO, d::Dict, indent::Int)
    prefix = " " ^ indent
    for (k, v) in sort(collect(d); by=first)
        println(io, prefix, k, ": ", _yaml_value(v))
    end
end

function _yaml_value(v)
    if v isa AbstractString
        needs_quoting = occursin(r"[:#\[\]{}&*!|>'\",]", v) || v in ("true", "false", "null", "yes", "no")
        return needs_quoting ? "\"$(escape_string(v))\"" : v
    elseif v isa Bool
        return v ? "true" : "false"
    elseif v isa Number
        return string(v)
    elseif v isa AbstractVector
        return "[" * join((_yaml_value(x) for x in v), ", ") * "]"
    elseif v isa Dict
        buf = IOBuffer()
        println(buf)
        _write_yaml_dict(buf, v, 0)
        return String(take!(buf))
    else
        return repr(v)
    end
end

_anchor_name(type_name::AbstractString) = type_name * "_defaults"
