import SHA
import Dates

"""
    save_schematic(dir::String, g::SchematicGraph)
    save_schematic(dir::String, sch::Schematic)

Save a read-only YAML description of a schematic into the directory `dir`
(created if necessary), returning `dir`.

The bundle is intended for consumption by external tooling (viewers, diff
tools, documentation generators). It is not a round-trip persistence format:
graphs cannot be reconstructed from YAML, and the export makes no claim about
realized fabrication or simulation geometry.

  - `save_schematic(dir, g::SchematicGraph)` writes `topology.yml`, describing
    the graph's nodes (recursing into composite-component subgraphs), edges,
    additional hooks, and vertex/edge properties, and `parameters.yml`, the
    [`extract_parameter_set`](@ref) result for `g` in the existing
    `ParameterSet` YAML format. Every node has an entry under
    `components.<node id>` (dots in IDs become nested namespaces, and
    composite subgraph components nest below their parent), which
    `topology.yml` references through each node's `component.params` address.
  - `save_schematic(dir, sch::Schematic)` additionally writes `floorplan.yml`
    with the planned global transformation, resolved hooks, and bounding
    rectangle of every top-level node, a flat `routes` list of resolved
    `RouteComponent` endpoints and waypoints, and a flat `nested_nodes` list
    addressing composite-internal nodes by their node-ID path.

All files carry the same `bundle` identity mapping: the graph name as
`design_id`, a `source_fingerprint` (SHA-256 of the topology and parameters
documents with the `bundle` mapping omitted), the generating package version,
and a UTC timestamp. In `parameters.yml`, the identity is stored as a
top-level `bundle` namespace.

Requires `YAML.jl` to be loaded (`using YAML`).
"""
function save_schematic end

# Fingerprint and timestamp helpers live in the parent module rather than the
# YAML extension because extensions cannot rely on loading the parent's strong
# dependencies (SHA, Dates) on all supported Julia versions.
_bundle_fingerprint(document::String) = "sha256:" * SHA.bytes2hex(SHA.sha256(document))

_bundle_timestamp() =
    Dates.format(Dates.now(Dates.UTC), Dates.dateformat"yyyy-mm-dd\THH:MM:SS\Z")
