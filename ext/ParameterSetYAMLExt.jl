module ParameterSetYAMLExt

import DeviceLayout: ParameterSet
import YAML

"""
    ParameterSet(path::String)

Load a `ParameterSet` from a YAML file at `path`.

Requires `YAML.jl` to be loaded (`using YAML`).
"""
function ParameterSet(path::String)
    data = YAML.load_file(path; dicttype=Dict{String, Any})
    ps = ParameterSet(data)
    # Replace with path-aware instance (ParameterSet is immutable, path is set to "" by Dict ctor)
    return DeviceLayout.ParameterSet(path, ps.data, ps.accessed)
end

end # module ParameterSetYAMLExt
