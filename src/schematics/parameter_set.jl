const REQUIRED_NAMESPACES = ("global", "components")

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

  - `global` - parameters shared across the design
  - `components` - per-component parameter trees

# Fields

  - `path::String`: source file path (empty string if constructed from a Dict)
  - `data::Dict{String, Any}`: nested parameter dictionary
  - `accessed::Set{String}`: tracks which parameter paths were consumed (for auditing)
  - `prefix::String`: dot-separated namespace prefix for scoped views (empty at root)
"""
struct ParameterSet
    path::String
    data::Dict{String, Any}
    accessed::Set{String}
    prefix::String

    # A non-empty `prefix` marks a scoped view over an interior subtree of a
    # larger ParameterSet (e.g. `ps.components.qubit`); those subtrees must not
    # be polluted with the top-level "global"/"components" keys. A root
    # ParameterSet has `prefix == ""` and gets the required namespaces ensured
    # so every caller can rely on them existing.
    function ParameterSet(
        path::String,
        data::Dict{String, Any},
        accessed::Set{String},
        prefix::String=""
    )
        if isempty(prefix) && !all(haskey(data, ns) for ns in REQUIRED_NAMESPACES)
            # Shallow copy before injecting required namespaces so we don't
            # mutate the caller's dict. Nested dicts stay shared - we only add
            # new top-level keys here.
            data = copy(data)
            for ns in REQUIRED_NAMESPACES
                haskey(data, ns) || (data[ns] = Dict{String, Any}())
            end
        end
        return new(path, data, accessed, prefix)
    end
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
    prefix::String  # namespace prefix inherited from the scoped ParameterSet that spawned this chain
end

function _namespace_path(d::MissingNamespace)
    chain = _key_chain(d)
    return isempty(d.prefix) ? chain : d.prefix * "." * chain
end

function _key_chain(d::MissingNamespace)
    if d.parent isa MissingNamespace
        return _key_chain(d.parent) * "." * d.key
    end
    return d.key
end

function _missing_error(d::MissingNamespace)
    throw(ParameterKeyError(d.key, _namespace_path(d)))
end

"""
    _materialize!(d::MissingNamespace) -> Dict{String, Any}

Walk `d`'s `parent` chain back to a real `Dict{String, Any}`, creating an empty
`Dict{String, Any}` at every missing segment along the way, and return the dict
at `d.key`. Internal helper for `setproperty!(::MissingNamespace, ...)`.

Throws `ArgumentError` if the path collides with an existing leaf (i.e. `d.key`
is already present in its parent dict and holds a non-`Dict` value).
"""
function _materialize!(d::MissingNamespace)
    parent_dict = d.parent isa Dict{String, Any} ? d.parent : _materialize!(d.parent)
    if haskey(parent_dict, d.key)
        val = parent_dict[d.key]
        val isa Dict{String, Any} || throw(
            ArgumentError(
                "Cannot auto-vivify namespace at \"$(_namespace_path(d))\": " *
                "key already holds a leaf value of type $(typeof(val))"
            )
        )
        return val
    end
    return parent_dict[d.key] = Dict{String, Any}()
end

function Base.getproperty(d::MissingNamespace, s::Symbol)
    s in (:parent, :key, :accessed, :prefix) && return getfield(d, s)
    return MissingNamespace(d, String(s), getfield(d, :accessed), getfield(d, :prefix))
end

"""
    setproperty!(d::MissingNamespace, s::Symbol, value)

Auto-vivifying write into a missing path. This is what makes `ParameterSet`'s
dot-write syntax work when intermediate namespaces don't exist yet:

```julia
ps.components.new_qubit.cap_width = 300  # "new_qubit" need not exist
```

Julia lowers that assignment to `setproperty!(mn, :cap_width, 300)` where `mn`
is the `MissingNamespace` returned by `ps.components.new_qubit`. Before the
write can land, every missing segment along the chain must be created as an
empty `Dict{String, Any}` in the underlying `ParameterSet.data` - the actual
walking-and-creating is done by `_materialize!`. This method then places
`value` under `s` in the materialized dict.

If `value isa Pair`, it is wrapped as `Dict(String(first) => second)` so that
syntax like `ps.namespace = (:key => val)` produces a nested namespace rather
than storing a raw `Pair`.

Throws if `s` names an internal struct field (`:parent`, `:key`, `:accessed`,
`:prefix`) or if the auto-vivification path collides with an existing leaf
value (via `_materialize!`).
"""
function Base.setproperty!(d::MissingNamespace, s::Symbol, value)
    s in (:parent, :key, :accessed, :prefix) &&
        error("MissingNamespace.$s is an internal field and cannot be assigned")
    materialized = _materialize!(d)
    # Julia convention: `a.b = x` evaluates to `x`, so return the original RHS
    # even when we wrap a `Pair` into a nested namespace Dict for storage.
    stored = value isa Pair ? Dict{String, Any}(String(value.first) => value.second) : value
    materialized[String(s)] = stored
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
Base.iterate(d::MissingNamespace) = _missing_error(d)
Base.length(d::MissingNamespace) = _missing_error(d)

ParameterSet(path::String, data::Dict{String, Any}) =
    ParameterSet(path, data, Set{String}())
ParameterSet(data::Dict{String, Any}) = ParameterSet("", data)
ParameterSet() = ParameterSet(Dict{String, Any}())

function Base.getproperty(ps::ParameterSet, s::Symbol)
    s in (:path, :data, :accessed, :prefix) && return getfield(ps, s)

    d = getfield(ps, :data)
    key = String(s)
    prefix = getfield(ps, :prefix)
    qualified = isempty(prefix) ? key : prefix * "." * key

    if !haskey(d, key)
        return MissingNamespace(d, key, getfield(ps, :accessed), prefix)
    end

    val = d[key]
    if val isa Dict
        # Scoped view over an interior subtree; `qualified` is non-empty so the
        # constructor skips namespace-ensuring (see ParameterSet inner ctor).
        return ParameterSet(getfield(ps, :path), val, getfield(ps, :accessed), qualified)
    end
    # Track leaf access with qualified path
    push!(getfield(ps, :accessed), qualified)
    return val
end

function Base.setproperty!(ps::ParameterSet, s::Symbol, value)
    s in (:path, :data, :accessed, :prefix) && return setfield!(ps, s, value)
    d = getfield(ps, :data)
    # Julia convention: `a.b = x` evaluates to `x`, so return the original RHS
    # even when we wrap a `Pair` into a nested namespace Dict for storage.
    stored = value isa Pair ? Dict{String, Any}(String(value.first) => value.second) : value
    d[String(s)] = stored
    return value
end

function Base.propertynames(ps::ParameterSet)
    return Symbol.(keys(getfield(ps, :data)))
end

Base.show(io::IO, ps::ParameterSet) = print(
    io,
    "ParameterSet($(length(ps.data)) keys: $(join(sort!(collect(keys(ps.data))), ", ")))"
)

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

Returns the value at the address - either a scoped `ParameterSet` (if the value is a `Dict`)
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
    # keepempty=false makes the empty address a no-op (returns `ps`) and skips
    # empty segments from leading/trailing/repeated dots in malformed addresses.
    for seg in split(address, '.'; keepempty=false)
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

leaf_params(ps::ParameterSet) = leaf_params(getproperty(ps, :data))

"""
    save_parameter_set(path::String, ps::ParameterSet)
    save_parameter_set(io::IO, ps::ParameterSet)

Save a `ParameterSet` to a YAML file at `path` or write YAML to an `IO` stream.

`Unitful.Quantity` values are serialized as `"<value><unit>"` (e.g. `"150μm"`)
for lossless round-tripping.

Requires `YAML.jl` to be loaded (`using YAML`).

    ParameterSet(io::IO)

Load a `ParameterSet` from a YAML IO stream.

Requires `YAML.jl` to be loaded (`using YAML`).
"""
function save_parameter_set end
