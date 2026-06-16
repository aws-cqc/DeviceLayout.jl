module ParameterSetYAMLExt

import DeviceLayout
import DeviceLayout.SchematicDrivenLayout: ParameterSet
import YAML
import Unitful

"""
    _parse_units!(data::Dict{String, Any})

Recursively walk a parsed YAML dict. String values, including strings inside
array leaves, that parse into a `Unitful.Quantity` (e.g. `"150μm"`) are
converted via
[`DeviceLayout.uparse`](@ref), so length-dimensioned values share the
package's promotion context (`ContextUnits`) instead of carrying bare
`FreeUnits` (which would later trip the mixed-context promotion bug
fixed in https://github.com/JuliaPhysics/Unitful.jl/pull/845 — surfaced
in DeviceLayout via `layer_z` arithmetic).

Bare unit names like `"s"`, `"m"`, `"cm"` parse into `Unitful.Units`, not
`Quantity` - those are left as strings so that ordinary text values (e.g.
`process_node: "s"`) are not silently coerced into the seconds unit.
"""
function _parse_unit_value(v::AbstractString)
    try
        parsed = DeviceLayout.uparse(v)
        return parsed isa Unitful.Quantity ? parsed : v
    catch
        return v
    end
end

function _parse_unit_value(v::Dict{String, Any})
    _parse_units!(v)
    return v
end

_parse_unit_value(v::AbstractVector) = map(_parse_unit_value, v)
_parse_unit_value(v) = v

function _parse_units!(data::Dict{String, Any})
    for (k, v) in data
        data[k] = _parse_unit_value(v)
    end
    return data
end

"""
    _serialize_units(data::Dict{String, Any}) -> Dict{String, Any}

Return a deep copy of `data` with `Unitful.Quantity` values, including values
inside arrays, converted to strings like `"150μm"` (no space, round-trips
through `Unitful.uparse`).
"""
function _serialize_unit_value(v::Dict{String, Any})
    return _serialize_units(v)
end

_serialize_unit_value(v::AbstractVector) = map(_serialize_unit_value, v)
_serialize_unit_value(v::Unitful.Quantity) = "$(Unitful.ustrip(v))$(Unitful.unit(v))"
_serialize_unit_value(v) = v

function _serialize_units(data::Dict{String, Any})
    out = Dict{String, Any}()
    for (k, v) in data
        out[k] = _serialize_unit_value(v)
    end
    return out
end

"""
    ParameterSet(io::IO, path::String="")
    ParameterSet(path::String)

Load a `ParameterSet` from a YAML source — either an `IO` stream or a file at
`path`. String values that parse as `Unitful.Quantity` (e.g. `"150μm"`) are
converted in place.

Requires `YAML.jl` to be loaded (`using YAML`).
"""
function ParameterSet(io::IO, path::String="")
    data = YAML.load(io; dicttype=Dict{String, Any})
    _parse_units!(data)
    return DeviceLayout.SchematicDrivenLayout.ParameterSet(path, data)
end

function ParameterSet(path::String)
    return open(path) do io
        DeviceLayout.SchematicDrivenLayout.ParameterSet(io, path)
    end
end

function DeviceLayout.SchematicDrivenLayout.save_parameter_set(io::IO, ps::ParameterSet)
    data = _serialize_units(getfield(ps, :data))
    YAML.write(io, data)
    return io
end

function DeviceLayout.SchematicDrivenLayout.save_parameter_set(path::String, ps::ParameterSet)
    open(path, "w") do io
        DeviceLayout.SchematicDrivenLayout.save_parameter_set(io, ps)
    end
    return path
end

end # module ParameterSetYAMLExt
