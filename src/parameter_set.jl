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

"""
    ParameterKeyError <: Exception

Thrown when reading a non-existent key from a `ParameterSet`.
"""
struct ParameterKeyError <: Exception
    key::String
    path::String
end

function Base.showerror(io::IO, e::ParameterKeyError)
    print(io, "ParameterKeyError: ParameterSet has no key :$(e.key)")
    if !isempty(e.path)
        print(io, " at path \"$(e.path)\"")
    end
end

"""
    MissingNamespace

Returned when accessing a non-existent key on a `ParameterSet`.

Supports chained dot-writes (auto-vivifying intermediate namespaces) but shows
a `ParameterKeyError` when used as a value. Check with `x isa MissingNamespace`.
"""
struct MissingNamespace
    parent  # ::Union{Dict{String, Any}, MissingNamespace}
    key::String
    accessed::Set{String}
end

function _namespace_path(d::MissingNamespace)
    if d.parent isa MissingNamespace
        return _namespace_path(d.parent) * "." * d.key
    end
    return d.key
end

function _missing_error(d::MissingNamespace)
    throw(ParameterKeyError(d.key, _namespace_path(d)))
end

function _materialize!(d::MissingNamespace)
    parent_dict = if d.parent isa Dict{String, Any}
        d.parent
    else
        _materialize!(d.parent)
    end
    if !haskey(parent_dict, d.key)
        parent_dict[d.key] = Dict{String, Any}()
    end
    return parent_dict[d.key]
end

function Base.getproperty(d::MissingNamespace, s::Symbol)
    s in (:parent, :key, :accessed) && return getfield(d, s)
    return MissingNamespace(d, String(s), getfield(d, :accessed))
end

function Base.setproperty!(d::MissingNamespace, s::Symbol, value)
    s in (:parent, :key, :accessed) && return setfield!(d, s, value)
    materialized = _materialize!(d)
    if value isa Pair
        value = Dict{String, Any}(String(value.first) => value.second)
    end
    materialized[String(s)] = value
    return value
end

function Base.show(io::IO, ::MIME"text/plain", d::MissingNamespace)
    path = _namespace_path(d)
    printstyled(io, "ParameterKeyError: "; bold=true, color=:red)
    return print(io, "ParameterSet has no key :$(getfield(d, :key)) at path \"$path\"")
end

Base.show(io::IO, d::MissingNamespace) = print(
    io,
    "ParameterKeyError: ParameterSet has no key :$(getfield(d, :key)) at path \"$(_namespace_path(d))\""
)

# Throw on any attempt to use MissingNamespace as a value
Base.convert(::Type{T}, d::MissingNamespace) where {T <: Number} = _missing_error(d)
Base.iterate(d::MissingNamespace) = _missing_error(d)
Base.length(d::MissingNamespace) = _missing_error(d)

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
        return MissingNamespace(d, key, getfield(ps, :accessed))
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

function _show_tree(io::IO, d::Dict{String, Any}, indent::Int)
    for (k, v) in sort(collect(d); by=first)
        if v isa Dict{String, Any}
            print(io, " "^indent, k, "\n")
            _show_tree(io, v, indent + 2)
        else
            print(io, " "^indent, k, " = ", repr(v), "\n")
        end
    end
end

function Base.show(io::IO, ::MIME"text/plain", ps::ParameterSet)
    path = getfield(ps, :path)
    d = getfield(ps, :data)
    if !isempty(path)
        println(io, "ParameterSet (", path, ")")
    else
        println(io, "ParameterSet")
    end
    return _show_tree(io, d, 2)
end

function _show_tree_md(io::IO, d::Dict{String, Any}, depth::Int)
    prefix = "  "^depth * "- "
    for (k, v) in sort(collect(d); by=first)
        if v isa Dict{String, Any}
            print(io, prefix, "**", k, "**\n")
            _show_tree_md(io, v, depth + 1)
        else
            print(io, prefix, k, " = `", repr(v), "`\n")
        end
    end
end

function Base.show(io::IO, ::MIME"text/markdown", ps::ParameterSet)
    path = getfield(ps, :path)
    if !isempty(path)
        println(io, "**ParameterSet** (", path, ")\n")
    else
        println(io, "**ParameterSet**\n")
    end
    return _show_tree_md(io, getfield(ps, :data), 0)
end

function Base.show(io::IO, ::MIME"text/html", ps::ParameterSet)
    path = getfield(ps, :path)
    if !isempty(path)
        print(io, "<b>ParameterSet</b> (", path, ")")
    else
        print(io, "<b>ParameterSet</b>")
    end
    return _show_tree_html(io, getfield(ps, :data))
end

function _show_tree_html(io::IO, d::Dict{String, Any})
    print(io, "<ul>")
    for (k, v) in sort(collect(d); by=first)
        if v isa Dict{String, Any}
            print(io, "<li><b>", k, "</b>")
            _show_tree_html(io, v)
            print(io, "</li>")
        else
            print(io, "<li>", k, " = <code>", repr(v), "</code></li>")
        end
    end
    return print(io, "</ul>")
end

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
