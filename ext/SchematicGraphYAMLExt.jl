module SchematicGraphYAMLExt

import DeviceLayout
import DeviceLayout:
    Hook, HandedPointHook, Point, PointHook, StyledHook, in_direction, transformation
import DeviceLayout.SchematicDrivenLayout:
    AbstractCompositeComponent,
    ComponentNode,
    RouteComponent,
    Schematic,
    SchematicGraph,
    additional_hooks,
    component,
    extract_parameter_set,
    getpath,
    graph,
    save_parameter_set,
    save_schematic
import YAML
import Unitful

const SDL = DeviceLayout.SchematicDrivenLayout

const TOPOLOGY_FILE = "topology.yml"
const FLOORPLAN_FILE = "floorplan.yml"
const PARAMETERS_FILE = "parameters.yml"
const SCHEMA_VERSION = "1" # Advances in lockstep across all bundle files

# Reuse the serialization conventions (unit-suffix plain scalars, !symbol tags)
# from ParameterSetYAMLExt so the whole bundle shares one YAML dialect. Both
# extensions are triggered by YAML.jl, so by the time any exported function
# runs, the sibling extension is loaded and resolvable.
function _parameter_set_yaml_ext()
    ext = Base.get_extension(DeviceLayout, :ParameterSetYAMLExt)
    isnothing(ext) &&
        error("ParameterSetYAMLExt is not loaded. Load YAML.jl (`using YAML`) first.")
    return ext
end

_serialize(data::Dict{String, Any}) = _parameter_set_yaml_ext()._serialize_units(data)

function DeviceLayout.SchematicDrivenLayout.save_schematic(dir::String, g::SchematicGraph)
    return _save_schematic(dir, g, nothing)
end

function DeviceLayout.SchematicDrivenLayout.save_schematic(dir::String, sch::Schematic)
    return _save_schematic(dir, sch.graph, sch)
end

function _save_schematic(dir::String, g::SchematicGraph, sch::Union{Nothing, Schematic})
    mkpath(dir)
    topology = _topology_data(g, !isnothing(sch))
    parameter_set = extract_parameter_set(g)
    # The fingerprint covers the topology and parameters documents before the
    # bundle identity is inserted, so identical graph states produce identical
    # fingerprints regardless of when the bundle was generated.
    topology_yaml = sprint(io -> YAML.write(io, _serialize(topology)))
    parameters_yaml = sprint(io -> save_parameter_set(io, parameter_set))
    identity = _bundle_identity(SDL.name(g), topology_yaml * parameters_yaml)

    topology["bundle"] = identity
    open(joinpath(dir, TOPOLOGY_FILE), "w") do io
        return YAML.write(io, _serialize(topology))
    end

    # ParameterSet data is a plain string-keyed namespace tree, so the bundle
    # identity is stored as a top-level `bundle` namespace.
    getfield(parameter_set, :data)["bundle"] = copy(identity)
    save_parameter_set(joinpath(dir, PARAMETERS_FILE), parameter_set)

    if !isnothing(sch)
        floorplan = _floorplan_data(sch)
        floorplan["bundle"] = copy(identity)
        open(joinpath(dir, FLOORPLAN_FILE), "w") do io
            return YAML.write(io, _serialize(floorplan))
        end
    end
    return dir
end

function _bundle_identity(design_id::String, document::String)
    return Dict{String, Any}(
        "design_id" => design_id,
        "source_fingerprint" => SDL._bundle_fingerprint(document),
        "generator" => "DeviceLayout v$(pkgversion(DeviceLayout))",
        "generated_at" => SDL._bundle_timestamp()
    )
end

##### topology.yml

function _topology_data(g::SchematicGraph, has_floorplan::Bool)
    data = Dict{String, Any}(
        "schema_version" => SCHEMA_VERSION,
        "name" => SDL.name(g),
        "parameters" => PARAMETERS_FILE
    )
    has_floorplan && (data["floorplan"] = FLOORPLAN_FILE)
    data["nodes"], data["edges"] = _graph_data(g, String[])
    return data
end

function _graph_data(g::SchematicGraph, parent_segments::Vector{String})
    nodes_list = Any[_topology_node(g, idx, parent_segments) for
    idx in eachindex(SDL.nodes(g))]
    edges_list = Any[_topology_edge(g, e) for e in SDL.edges(g.graph)]
    return nodes_list, edges_list
end

function _topology_node(g::SchematicGraph, idx::Int, parent_segments::Vector{String})
    node = SDL.nodes(g)[idx]
    comp = component(node)
    T = typeof(comp)
    # Dots in node IDs denote nested parameter namespaces, matching the
    # addressing used by `extract_parameter_set`.
    segments = [parent_segments; String.(split(node.id, '.'))]
    data = Dict{String, Any}(
        "id" => node.id,
        "component" => Dict{String, Any}(
            "type" => string(nameof(T)),
            "module" => join(string.(fullname(parentmodule(T))), "."),
            "name" => SDL.name(comp),
            "params" => join(["components"; segments], ".")
        )
    )
    vertex_props = SDL.props(g.graph, idx)
    add_hooks = get(vertex_props, :additional_hooks, nothing)
    if !isnothing(add_hooks) && !isempty(add_hooks)
        data["additional_hooks"] =
            Dict{String, Any}(String(k) => _hook_data(v) for (k, v) in add_hooks)
    end
    properties = Dict{String, Any}(
        String(k) => _property_value(v) for
        (k, v) in vertex_props if k !== :additional_hooks
    )
    isempty(properties) || (data["properties"] = properties)
    if comp isa AbstractCompositeComponent
        subgraph = graph(comp)
        sub_nodes, sub_edges = _graph_data(subgraph, segments)
        data["subgraph"] = Dict{String, Any}(
            "name" => SDL.name(subgraph),
            "nodes" => sub_nodes,
            "edges" => sub_edges
        )
    end
    return data
end

function _topology_edge(g::SchematicGraph, e)
    edge_props = SDL.props(g.graph, e)
    n1 = SDL.nodes(g)[SDL.src(e)]
    n2 = SDL.nodes(g)[SDL.dst(e)]
    nodehooks = edge_props[:nodehooks]
    data = Dict{String, Any}(
        "nodes" => Any[n1.id, n2.id],
        "hooks" => Any[String(nodehooks[n1]), String(nodehooks[n2])]
    )
    properties = Dict{String, Any}(
        String(k) => _property_value(v) for (k, v) in edge_props if k !== :nodehooks
    )
    isempty(properties) || (data["properties"] = properties)
    return data
end

# Vertex and edge properties are arbitrary user values. Values supported by
# the ParameterSet extraction rules are exported as data; anything else is
# exported as its `repr` string, since the bundle is inspection-only.
function _property_value(v)
    extracted = SDL._extracted_parameter_value(v)
    extracted isa SDL._UnsupportedParameterValue && return repr(v)
    return extracted
end

##### Shared geometry serialization

_point_data(p::Point) = Any[p.x, p.y]

function _hook_data(h::PointHook)
    return Dict{String, Any}(
        "kind" => "PointHook",
        "point" => _point_data(h.p),
        "direction" => in_direction(h)
    )
end

function _hook_data(h::HandedPointHook)
    data = _hook_data(getfield(h, :h))
    data["kind"] = "HandedPointHook"
    data["handedness"] = h.right_handed ? "right" : "left"
    return data
end

# A StyledHook is flattened to its positional hook's data plus a `style` type
# name, so consumers see uniform point/direction geometry for every hook.
function _hook_data(h::StyledHook)
    data = _hook_data(getfield(h, :h))
    data["style"] = string(nameof(typeof(getfield(h, :style))))
    return data
end

# Fallback for user-defined hook subtypes, which carry at least a point and an
# inward direction.
function _hook_data(h::Hook)
    return Dict{String, Any}(
        "kind" => string(nameof(typeof(h))),
        "point" => _point_data(h.p),
        "direction" => in_direction(h)
    )
end

##### floorplan.yml

function _floorplan_data(sch::Schematic{S}) where {S}
    g = sch.graph
    unit_string = string(Unitful.unit(zero(S)))
    data = Dict{String, Any}(
        "schema_version" => SCHEMA_VERSION,
        "topology" => TOPOLOGY_FILE,
        "name" => SDL.name(g),
        "coordinate_type" => isempty(unit_string) ? "NoUnits" : unit_string
    )
    nodes_list = Any[]
    routes_list = Any[]
    for node in SDL.nodes(g)
        # A node without a reference was never placed (e.g. planned with
        # strict=:no after a failure), so it has no floorplan entry.
        haskey(sch.ref_dict, node) || continue
        entry = Dict{String, Any}("id" => node.id)
        trans = transformation(sch, node)
        entry["transformation"] =
            _transformation_data(DeviceLayout.ScaledIsometry(trans), S)
        hs = SDL.hooks(sch, node)
        entry["hooks"] =
            Dict{String, Any}(String(k) => _hook_data(v) for (k, v) in pairs(hs))
        bounds_entry = _bounds_data(() -> DeviceLayout.bounds(sch, node), node.id)
        isnothing(bounds_entry) || (entry["bounds"] = bounds_entry)
        push!(nodes_list, entry)

        comp = component(node)
        comp isa RouteComponent && push!(routes_list, _floorplan_route(node, comp))
    end
    data["nodes"] = nodes_list
    data["routes"] = routes_list
    data["nested_nodes"] = _nested_nodes_data(sch)
    return data
end

function _transformation_data(f::DeviceLayout.ScaledIsometry, ::Type{S}) where {S}
    o = DeviceLayout.origin(f)
    # Purely linear maps (e.g. the identity) have no stored origin.
    isnothing(o) && (o = zero(Point{S}))
    return Dict{String, Any}(
        "origin" => _point_data(o),
        "rotation" => DeviceLayout.rotation(f),
        "xrefl" => DeviceLayout.xrefl(f),
        "mag" => DeviceLayout.mag(f)
    )
end

# Bounds require realizing component geometry, which is not guaranteed to
# succeed for every plannable component; the entry is omitted with a warning
# rather than failing the whole export.
function _bounds_data(get_bounds, id::String)
    rect = try
        get_bounds()
    catch e
        @warn "Could not compute bounds for floorplan entry $id; omitting." exception = e
        return nothing
    end
    return Dict{String, Any}("ll" => _point_data(rect.ll), "ur" => _point_data(rect.ur))
end

function _floorplan_route(node::ComponentNode, comp::RouteComponent)
    r = comp.r
    data = Dict{String, Any}(
        "id" => node.id,
        "p0" => _point_data(r.p0),
        "p1" => _point_data(r.p1),
        "α0" => r.α0,
        "α1" => r.α1,
        "rule_type" => string(nameof(typeof(r.rule)))
    )
    isempty(r.waypoints) ||
        (data["waypoints"] = Any[_point_data(w) for w in r.waypoints])
    isempty(r.waydirs) || (data["waydirs"] = Any[d for d in r.waydirs])
    return data
end

function _nested_nodes_data(sch::Schematic{S}) where {S}
    entries = Any[]
    for idx in SDL.find_nodes(_ -> true, sch.graph)
        # Top-level nodes (integer indices) are covered by the `nodes` list;
        # tuple indices address composite-internal nodes at any depth.
        idx isa Tuple || continue
        node_path = getpath(sch.graph, idx...)
        node = last(node_path)
        comp = component(node)
        entry = Dict{String, Any}("path" => Any[n.id for n in node_path])
        trans = try
            transformation(sch, idx)
        catch e
            @warn "Could not resolve transformation for nested node $(join([n.id for n in node_path], ".")); omitting." exception =
                e
            continue
        end
        entry["transformation"] =
            _transformation_data(DeviceLayout.ScaledIsometry(trans), S)
        # Additional hooks for a nested node live as vertex properties on its
        # composite's subgraph.
        subgraph = graph(component(node_path[end - 1]))
        hs = SDL.hooks(comp)
        add_hooks = additional_hooks(subgraph, node)
        isempty(add_hooks) || (hs = merge(hs, (; pairs(add_hooks)...)))
        entry["hooks"] = Dict{String, Any}(
            String(k) => _hook_data(trans(v)) for (k, v) in pairs(hs)
        )
        bounds_entry = _bounds_data(
            () -> DeviceLayout.bounds(sch, node_path...),
            join([n.id for n in node_path], ".")
        )
        isnothing(bounds_entry) || (entry["bounds"] = bounds_entry)
        push!(entries, entry)
    end
    return entries
end

end # module SchematicGraphYAMLExt
