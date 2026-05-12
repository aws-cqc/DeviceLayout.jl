module ParameterSetYAMLExt

import DeviceLayout
import DeviceLayout.SchematicDrivenLayout: ParameterSet
import YAML
import Unitful

"""
    _parse_units!(data::Dict{String, Any})

Recursively walk a parsed YAML dict. String values that parse into a
`Unitful.Quantity` (e.g. `"150μm"`) are converted in place.

Bare unit names like `"s"`, `"m"`, `"cm"` parse into `Unitful.Units`, not
`Quantity` - those are left as strings so that ordinary text values (e.g.
`process_node: "s"`) are not silently coerced into the seconds unit.

Length-dimensioned quantities are re-attached to `DeviceLayout.PreferredUnits.UPREFERRED`
so they share a single promotion context with the rest of the package.
"""
function _parse_units!(data::Dict{String, Any})
    for (k, v) in data
        if v isa Dict{String, Any}
            _parse_units!(v)
        elseif v isa AbstractString
            try
                parsed = Unitful.uparse(v)
                if parsed isa Unitful.Quantity
                    data[k] = _recontext_length(parsed)
                end
            catch
                # not a valid unit expression, keep as-is
            end
        end
    end
    return data
end

const _LENGTH_DIM = Unitful.dimension(Unitful.m)

function _recontext_length(v::Unitful.Quantity)
    # `Unitful.uparse` returns `FreeUnits` quantities whose promotion target is `m`, which mismatches the
    # package's `ContextUnits` (target `nm` or `μm`) and breaks mixed arithmetic such as
    # `layer_z` in `technologies.jl`.
    Unitful.dimension(v) == _LENGTH_DIM || return v
    target = DeviceLayout.PreferredUnits.UPREFERRED
    # PreferNoUnits sets UPREFERRED = NoUnits - skip re-contexting in that case.
    Unitful.dimension(target) == _LENGTH_DIM || return v
    ctx = Unitful.ContextUnits(Unitful.unit(v), target)
    return Unitful.ustrip(v) * ctx
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
