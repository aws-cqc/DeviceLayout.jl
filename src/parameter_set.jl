"""
    ParameterSet

Mutable parameter source, typically loaded from a YAML file.

The internal dict uses a namespace convention: `String` keys are namespace segments
(navigate deeper into the hierarchy), non-`Dict` values are leaf parameters.

Supports dot access for both reading and writing:

```julia
ps.components.qubit.cap_width        # read
ps.components.qubit.cap_width = 350  # write
```

Every `ParameterSet` contains two required top-level namespaces:

  - `"global"` — parameters shared across the design
  - `"components"` — per-component parameter trees

# Fields

  - `path::String`: source file path (empty string if constructed from a Dict)
  - `data::Dict{String, Any}`: nested parameter dictionary
  - `accessed::Set{String}`: tracks which parameter paths were consumed (for auditing)
"""
mutable struct ParameterSet
    path::String
    data::Dict{String, Any}
    accessed::Set{String}
end

const _REQUIRED_NAMESPACES = ("global", "components")

function _ensure_required_namespaces!(data::Dict{String, Any})
    for ns in _REQUIRED_NAMESPACES
        if !haskey(data, ns)
            data[ns] = Dict{String, Any}()
        end
    end
    return data
end

function ParameterSet(data::Dict{String, Any})
    _ensure_required_namespaces!(data)
    return ParameterSet("", data, Set{String}())
end

ParameterSet() = ParameterSet(Dict{String, Any}())

function Base.getproperty(ps::ParameterSet, s::Symbol)
    s in (:path, :data, :accessed) && return getfield(ps, s)

    d = getfield(ps, :data)
    key = String(s)
    if !haskey(d, key)
        # Auto-vivify: create intermediate namespace so chained dot-access works
        d[key] = Dict{String, Any}()
    end

    val = d[key]
    if val isa Dict
        return ParameterSet(getfield(ps, :path), val, getfield(ps, :accessed))
    end
    # Track leaf access
    push!(getfield(ps, :accessed), key)
    return val
end

function Base.setproperty!(ps::ParameterSet, s::Symbol, value)
    s in (:path, :data, :accessed) && return setfield!(ps, s, value)
    d = getfield(ps, :data)
    if value isa Pair
        value = Dict{String, Any}(String(value.first) => value.second)
    end
    d[String(s)] = value
    return value
end

function Base.propertynames(ps::ParameterSet)
    return Symbol.(keys(getfield(ps, :data)))
end

Base.show(io::IO, ps::ParameterSet) =
    print(io, "ParameterSet($(length(ps.data)) keys: $(join(keys(ps.data), ", ")))")

"""
    resolve(ps::ParameterSet, address::String)

Navigate a dot-separated address within the `ParameterSet`.

Returns the value at the address — either a scoped `ParameterSet` (if the value is a `Dict`)
or a leaf value.

# Examples

```julia
ps = ParameterSet(
    Dict{String, Any}(
        "global" => Dict{String, Any}(),
        "components" =>
            Dict{String, Any}("qubit" => Dict{String, Any}("cap_width" => 300))
    )
)
resolve(ps, "components.qubit.cap_width")  # => 300
resolve(ps, "components.qubit")            # => ParameterSet scoped to qubit
```
"""
function resolve(ps::ParameterSet, address::String)
    current = ps
    for seg in split(address, '.')
        current = getproperty(current, Symbol(seg))
    end
    return current
end

"""
    leaf_params(ps::ParameterSet)
    leaf_params(d::Dict)

Extract non-`Dict` entries as a `NamedTuple` (the "leaf" parameters at this level).
`Dict` entries (namespace segments) are excluded.

# Examples

```julia
ps = ParameterSet(
    Dict{String, Any}(
        "global" => Dict{String, Any}(),
        "components" => Dict{String, Any}("cap_width" => 300, "cap_gap" => 20)
    )
)
leaf_params(ps.components)  # => (cap_width = 300, cap_gap = 20)
```
"""
function leaf_params(d::Dict)
    pairs_list = [Symbol(k) => v for (k, v) in d if !(v isa Dict)]
    isempty(pairs_list) && return (;)
    return NamedTuple(pairs_list)
end

leaf_params(ps::ParameterSet) = leaf_params(getfield(ps, :data))
