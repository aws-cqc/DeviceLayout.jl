const GLOBAL_NAME_COUNTER = Dict{String, Int}()

"""
    uniquename(str, dlm="\\\$"; modify_first=false, counter=GLOBAL_NAME_COUNTER)

Given string input `str` for the `n`th time, return `str * dlm * string(n)`.

If `str` is already formatted as `str0 * dlm * n`, where `n` is an integer, then `str0`
will be used with the larger of `n` and the number of times `str0` has been counted plus one.

If `modify_first` is `false`, then `str` will be returned the first time
`uniquename(str, dlm; modify_first=false)` is called.

Useful if programmatically making Cells and all of them will
eventually be saved into a GDSII file.

The uniqueness is expected on a per-Julia session basis or until [`reset_uniquename!`](@ref) is
called, so if you load an existing GDSII file and try to save unique
cells on top of that you may get an unlucky clash. Calling `uniquename` on all loaded `Cell`
names will effectively "register" them, making subsequent `uniquename` calls aware of them.

# Example

```jldoctest
julia> reset_uniquename!();

julia> uniquename("name"; modify_first=true)
"name\\\$1"

julia> uniquename("name\\\$4")
"name\\\$4"

julia> uniquename("name\\\$3")
"name\\\$5"

julia> uniquename("name")
"name\\\$6"
```

`counter` is the `Dict{String,Int}` that counts how many times each name has been seen.
The default is a global counter that persists until the end of the Julia session or until
[`reset_uniquename!`](@ref) is called.
"""
function uniquename(str, dlm='\$'; modify_first=false, counter=GLOBAL_NAME_COUNTER)
    # if format is already str0 * dlm * n, count it like the (>=n)th occurrence of str0  
    substrings = split(str, dlm)
    if !isnothing(tryparse(Int, last(substrings)))
        n0 = parse(Int, last(substrings))
        str0 = join(substrings[1:(end - 1)])
        n1 = 1 + get(counter, str0, 0)
        n = max(n0, n1)
        counter[str0] = n
        return str0 * dlm * string(n)
    end
    # otherwise just count
    n = 1 + get(counter, str, 0)
    counter[str] = n
    (!modify_first && n == 1) && return str
    return str * dlm * string(n)
end

"""
    reset_uniquename!(counter=GLOBAL_NAME_COUNTER)

Reset [`uniquename`](@ref) counters for all strings.

`counter` is the `Dict{String,Int}` that counts how many times each name has been seen.
The default is the same default global counter used by `uniquename`.
"""
reset_uniquename!(counter=GLOBAL_NAME_COUNTER) = empty!(counter)

"""
    reset_uniquename!(str::String, counter=GLOBAL_NAME_COUNTER)

Reset [`uniquename`](@ref) counter for `str`.

`counter` is the `Dict{String,Int}` that counts how many times each name has been seen.
The default is the same default global counter used by `uniquename`.
"""
reset_uniquename!(str::String, counter=GLOBAL_NAME_COUNTER) = (counter[str] = 0)

"""
    name(s::GeometryStructure)

Return a name `String` for `s`.
"""
name(s::GeometryStructure) = s.name

"""
    element_metadata(s::GeometryStructure)

Return a vector of metadata associated one-to-one with `elements(s)` in the structure.
"""
element_metadata(s::GeometryStructure) = s.element_metadata

"""
    elements(s::GeometryStructure)

Return a vector of `GeometryEntity` in the structure.

For a `Cell`, these are `Polygon`s. For a `CoordinateSystem`, these can be any `GeometryEntity`.
"""
elements(s::GeometryStructure) = s.elements

"""
    elementtype(cs::GeometryStructure)

Return the type of elements in the structure.
"""
elementtype(s::GeometryStructure) = eltype(elements(s))

"""
    refs(s::GeometryStructure)

Return a vector of references to sub-structures.
"""
refs(s::GeometryStructure) = s.refs

@inline unsafe_floor(x::Unitful.Quantity) = floor(Unitful.ustrip(x)) * Unitful.unit(x)
@inline unsafe_floor(x::Number)           = floor(x)
@inline unsafe_ceil(x::Unitful.Quantity)  = ceil(Unitful.ustrip(x)) * Unitful.unit(x)
@inline unsafe_ceil(x::Number)            = ceil(x)

"""
    bounds(s::GeometryStructure{T}) where {T <: Coordinate}

Return a `Rectangle{T}` bounding box around all objects in a structure or structures.
Return a rectangle with zero width and height if the structures are empty.
"""
function bounds(s::GeometryStructure{T}) where {T <: Coordinate}
    mi, ma = Point(typemax(T), typemax(T)), Point(typemin(T), typemin(T))
    bfl(::Type{S}, x) where {S <: IntegerCoordinate} = Point(unsafe_floor.(x))
    bfl(S, x) = x
    bce(::Type{S}, x) where {S <: IntegerCoordinate} = Point(unsafe_ceil.(x))
    bce(S, x) = x

    isempty(elements(s)) &&
        isempty(refs(s)) &&
        return Rectangle(Point(zero(T), zero(T)), Point(zero(T), zero(T)))

    proper_els = false
    for el in elements(s)
        b = bounds(el)
        !isproper(b) && continue
        proper_els = true
        mi = Point(min(mi.x, lowerleft(b).x), min(mi.y, lowerleft(b).y))
        ma = Point(max(ma.x, upperright(b).x), max(ma.y, upperright(b).y))
    end

    nonempty_ref = false
    for el in refs(s)
        # The referenced cells may not return the same Rectangle{T} type.
        # We should grow to accommodate if necessary.
        br = bounds(el)
        !isproper(br) && continue
        nonempty_ref = true
        b = Rectangle{T}(bfl(T, br.ll), bce(T, br.ur))
        mi = Point(min(mi.x, lowerleft(b).x), min(mi.y, lowerleft(b).y))
        ma = Point(max(ma.x, upperright(b).x), max(ma.y, upperright(b).y))
    end
    !proper_els &&
        !nonempty_ref && # No or zero-extent elements and refs
        return Rectangle(Point(zero(T), zero(T)), Point(zero(T), zero(T)))
    return Rectangle(mi, ma)
end

lowerleft(s::GeometryStructure) = lowerleft(bounds(s))
upperright(s::GeometryStructure) = upperright(bounds(s))

"""
    traversal(cs::GeometryStructure, trans=ScaledIsometry())

Return a vector of `(structure, transformation)` tuples for `cs` and all structures in its
reference hierarchy. The transformation is the global transformation from the root to the
structure.

Note: The same structure may appear multiple times with different transformations if it is
referenced multiple times.
"""
function traversal(cs::GeometryStructure, trans=ScaledIsometry())
    tv = [(cs, trans)]
    for ref in refs(cs)
        tv = vcat(tv, traversal(structure(ref), trans ∘ transformation(ref)))
    end
    return tv
end

"""
    function map_metadata!(geom::GeometryStructure, map_meta, [visited])

For every element in `geom` with original meta `m`, set its metadata to `map_meta(m)`.

Operates on all unique structures in the reference hierarchy exactly once, so that
multiply-referenced structures are not mapped multiple times.

The `visited` argument is used internally to track structures already processed.
"""
function map_metadata!(geom::GeometryStructure, map_meta)
    visited = Set{Any}()
    return map_metadata!(geom, map_meta, visited)
end

function map_metadata!(geom::GeometryStructure, map_meta, visited::Set{Any})
    geom in visited && return nothing
    push!(visited, geom)
    geom.element_metadata .= map_meta.(geom.element_metadata)
    for ref in refs(geom)
        map_metadata!(structure(ref), map_meta, visited)
    end
    return nothing
end

"""
    function map_metadata(geom::GeometryStructure, map_meta)

Create a copy of `geom` and change original metadata `m` to `map_meta(m)` for all elements.

Recursive on the copies of referenced structures.
"""
function map_metadata(geom::GeometryStructure, map_meta)
    new_geom = deepcopy(geom)
    map_metadata!(new_geom, map_meta)
    return new_geom
end

"""
    flatten(c::GeometryStructure; depth::Integer=-1, name=uniquename("flatten_"*name(c)), metadata_filter=nothing)

Return a new coordinate system with name `name` with recursively flattened references and arrays up to a hierarchical `depth`.

Flattening a `CoordinateSystem` or `Cell` produces a coordinate system of the same type
(meaning these can also be flattened in-place with [`flatten!`](@ref)), while flattening
other structures generally produces a `CoordinateSystem` with the same coordinate type.

Flattening adds the elements of references to the top-level structure with appropriate
transformations, then discards those references. Deeper references and arrays are brought
upwards and are not discarded.

`metadata_filter` can be a function that takes a `DeviceLayout.Meta` and returns a `Bool`,
like a function returned by [`layer_inclusion`](@ref). In that case, only elements whose metadata `m`
have `metadata_filter(m) == true` will be retained while flattening. Elements of deeper references
and arrays are not filtered.

This function has no effect for `depth == 0`, and unlimited depth by default.
"""
function flatten end

# type of coordinate system created by flatten
function coordsys_type end # defined elsewhere, once CoordinateSystem is defined
# name used by CoordinateSystem representation
coordsys_name(geom::GeometryStructure) = name(geom)

Base.isempty(geom::GeometryStructure) = isempty(elements(geom)) && isempty(refs(geom))
