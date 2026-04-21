module ParameterSetYAMLExt

import DeviceLayout
import DeviceLayout.SchematicDrivenLayout: ParameterSet
import YAML
import Unitful

"""
    _parse_units!(data::Dict{String, Any})

Recursively walk a parsed YAML dict. String values parseable by `Unitful.uparse`
(e.g. `"150μm"`) are converted to `Unitful.Quantity` values.
"""
function _parse_units!(data::Dict{String, Any})
    for (k, v) in data
        if v isa Dict{String, Any}
            _parse_units!(v)
        elseif v isa AbstractString
            try
                data[k] = Unitful.uparse(v)
            catch
                # not a valid unit expression, keep as-is
            end
        end
    end
    return data
end

"""
    _serialize_units(data::Dict{String, Any}) -> Dict{String, Any}

Return a deep copy of `data` with `Unitful.Quantity` values converted to
strings like `"150μm"` (no space, round-trips through `Unitful.uparse`).
"""
function _serialize_units(data::Dict{String, Any})
    out = Dict{String, Any}()
    for (k, v) in data
        if v isa Dict{String, Any}
            out[k] = _serialize_units(v)
        elseif v isa Unitful.Quantity
            out[k] = "$(Unitful.ustrip(v))$(Unitful.unit(v))"
        else
            out[k] = v
        end
    end
    return out
end

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
