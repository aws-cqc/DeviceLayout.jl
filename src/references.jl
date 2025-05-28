"""
    mutable struct StructureReference{S, T} <: GeometryReference{S, T}
        structure::T
        origin::Point{S}
        xrefl::Bool
        mag::Float64
        rot::Float64
    end

Reference to a `structure` positioned at `origin`, with optional x-reflection
`xrefl`, magnification factor `mag`, and rotation angle `rot`. If an angle
is given without units it is assumed to be in radians.

That is, the transformation applied by the reference is the composition of the following
transformations, ordered with reflection applied first:

 1. If `xrefl(f)` is `true`, a reflection across the `x`-axis
 2. Rotation by `rotation(f)`
 3. Magnification by `mag(f)`
 4. Translation by `origin(f)`

The type variable `T` is to avoid circular definitions.
"""
mutable struct StructureReference{S, T} <: GeometryReference{S, T}
    structure::T
    origin::Point{S}
    xrefl::Bool
    mag::Float64
    rot::Float64
end
Base.convert(::Type{GeometryReference{S}}, x::StructureReference) where {S} =
    StructureReference(
        x.structure, # don't convert, to avoid copying
        convert(Point{S}, x.origin),
        x.xrefl,
        x.mag,
        x.rot
    )
Base.convert(::Type{StructureReference{S}}, x::StructureReference) where {S} =
    convert(GeometryReference{S}, x)

"""
    StructureReference(x::GeometryStructure{S}; kwargs...) where {S <: Coordinate}
    StructureReference(x::GeometryStructure{S}, origin::Point{T}; kwargs...) where
        {S <: Coordinate, T <: Coordinate}
    StructureReference(x, origin::Point{T}; kwargs...) where {T <: Coordinate}

Convenience constructor for `StructureReference{float(T), typeof(x)}`.

Keyword arguments can specify x-reflection, magnification, or rotation.
Synonyms are accepted, in case you forget the "correct keyword"...

  - X-reflection: `:xrefl`, `:xreflection`, `:refl`, `:reflect`, `:xreflect`,
    `:xmirror`, `:mirror`
  - Magnification: `:mag`, `:magnification`, `:magnify`, `:zoom`, `:scale`
  - Rotation: `:rot`, `:rotation`, `:rotate`, `:angle`
"""
function StructureReference(
    x::GeometryStructure{S},
    origin::Point{T}=zero(Point{S});
    kwargs...
) where {S <: Coordinate, T <: Coordinate}
    return sref(x, origin; kwargs...)
end

StructureReference(x::GeometryStructure{S}, f::Transformation) where {S} =
    StructureReference(
        x,
        isnothing(origin(f)) ? zero(Point{S}) : origin(f),
        xrefl=xrefl(f),
        mag=mag(f),
        rot=rotation(f)
    )

"""
    mutable struct ArrayReference{S,T} <: GeometryReference{S,T}
        structure::T
        origin::Point{S}
        deltacol::Point{S}
        deltarow::Point{S}
        col::Int
        row::Int
        xrefl::Bool
        mag::Float64
        rot::Float64
    end

Array of `structure` starting at `origin` with `row` rows and `col` columns,
spanned by vectors `deltacol` and `deltarow`. Optional x-reflection
`xrefl`, magnification factor `mag`, and rotation angle `rot` for the array
as a whole. If an angle is given without units it is assumed to be in radians.

The type variable `T` is to avoid circular definitions.
"""
mutable struct ArrayReference{S, T} <: GeometryReference{S, T}
    structure::T
    origin::Point{S}
    deltacol::Point{S}
    deltarow::Point{S}
    col::Int
    row::Int
    xrefl::Bool
    mag::Float64
    rot::Float64
end
Base.convert(::Type{GeometryReference{S}}, x::ArrayReference) where {S} = ArrayReference(
    x.structure,
    convert(Point{S}, x.origin),
    convert(Point{S}, x.deltacol),
    convert(Point{S}, x.deltarow),
    x.col,
    x.row,
    x.xrefl,
    x.mag,
    x.rot
)
Base.convert(::Type{ArrayReference{S}}, x::ArrayReference) where {S} =
    convert(GeometryReference{S}, x)

"""
    ArrayReference(x::GeometryStructure{S}; kwargs...) where {S <: Coordinate}
    ArrayReference(x::GeometryStructure{S}, origin::Point{T}; kwargs...) where
        {S <: Coordinate, T <: Coordinate}
    ArrayReference(x, origin::Point{T}; kwargs...) where {T <: Coordinate}

Construct a `ArrayReference{float(T),typeof(x)}` object.

Keyword arguments specify the column vector, row vector, number of columns,
number of rows, x-reflection, magnification factor, and rotation.

Synonyms are accepted for these keywords:

  - Column vector `dc::Point{T}`: `:deltacol`, `:dcol`, `:dc`, `:vcol`, `:colv`, `:colvec`,
    `:colvector`, `:columnv`, `:columnvec`, `:columnvector`
  - Row vector: `:deltarow`, `:drow`, `:dr`, `:vrow`, `:rv`, `:rowvec`,
    `:rowvector`
  - Number of columns: `:nc`, `:numcols`, `:numcol`, `:ncols`, `:ncol`, `:col`
  - Number of rows: `:nr`, `:numrows`, `:numrow`, `:nrows`, `:nrow`, `:col`
  - X-reflection: `:xrefl`, `:xreflection`, `:refl`, `:reflect`, `:xreflect`,
    `:xmirror`, `:mirror`
  - Magnification: `:mag`, `:magnification`, `:magnify`, `:zoom`, `:scale`
  - Rotation: `:rot`, `:rotation`, `:rotate`, `:angle`
"""
function ArrayReference(
    x::GeometryStructure{S},
    origin::Point{T}=zero(Point{S});
    kwargs...
) where {S <: Coordinate, T <: Coordinate}
    return aref(x, origin; kwargs...)
end

ArrayReference(x, c::AbstractRange, r::AbstractRange; kwargs...) = aref(x, c, r; kwargs...)

ArrayReference(x::GeometryStructure{S}, f::Transformation; kwargs...) where {S} =
    ArrayReference(
        x,
        isnothing(origin(f)) ? zero(Point{S}) : origin(f);
        xrefl=xrefl(f),
        mag=mag(f),
        rot=rotation(f),
        kwargs...
    )

### API
"""
    structure(ref::GeometryReference)

The `GeometryStructure` that `ref` points to.
"""
structure(x::GeometryReference) = x.structure

"""
    origin(ref::GeometryReference)

The origin of the structure that `ref` points to, in `ref`'s parent coordinate system.

Equivalently, the translation part of `transformation(ref)`
(the transformation that `ref` would apply to `structure(ref)`).
"""
origin(x::GeometryReference) = x.origin

"""
    xrefl(ref::GeometryReference)

A `Bool` indicating whether `transformation(ref)` includes a reflection.
"""
xrefl(x::GeometryReference) = x.xrefl

"""
    mag(ref::GeometryReference)

The magnification (uniform scaling factor) applied by `transformation(ref)`.
"""
mag(x::GeometryReference) = x.mag

"""
    rotation(ref::GeometryReference; α0=0)

The change in angle when applying `transformation(ref)` to a line originally at `α0` CCW from the `x`-axis.

Equivalent to `rotation(transformation(ref); α0=α0)`.
"""
rotation(x::GeometryReference; α0=0) = xrefl(x) ? x.rot - 2 * α0 : x.rot

_kwargs(x::StructureReference) = (xrefl=xrefl(x), mag=mag(x), rot=rotation(x))
_kwargs(x::ArrayReference) = (
    deltacol=x.deltacol,
    deltarow=x.deltarow,
    col=x.col,
    row=x.row,
    xrefl=xrefl(x),
    mag=mag(x),
    rot=rotation(x)
)
_optargs(x::GeometryReference) = values(_kwargs(x)) # Assumes correct order in _kwargs

"""
    copy(x::GeometryReference)

Creates a shallow copy of `x` (does not copy the referenced structure).
"""
Base.copy(x::T) where {T <: GeometryReference} = T(structure(x), origin(x), _optargs(x)...)

### Transformations
"""
    transformation(c::GeometryReference)

Return the angle-preserving transformation to be applied to the referenced structure.
"""
transformation(c::GeometryReference) =
    ScaledIsometry(origin(c), rotation(c), xrefl(c), mag(c))

function transform(ref::StructureReference, f)
    return StructureReference(structure(ref), ScaledIsometry(f) ∘ transformation(ref))
end

function transform(ref::ArrayReference, f)
    lin = Transformations.linearmap(rotation(f), xrefl(f), mag(f))
    return ArrayReference(
        structure(ref),
        ScaledIsometry(f) ∘ transformation(ref),
        deltacol=lin(ref.deltacol),
        deltarow=lin(ref.deltarow),
        col=ref.col,
        row=ref.row
    )
end

"""
    transformation(c::GeometryStructure, d::GeometryReference)

Given a GeometryStructure `c` containing [`GeometryReference`](@ref)
`d` in its tree of references, this function returns a
`Transformations.ScaledIsometry` object that lets you translate from the
coordinate system of `d` to the coordinate system of `c`.

If the *same exact* `GeometryReference` (as in `===`, same address in
memory) is included multiple times in the tree of references, then the resulting
transform will be based on the first time it is encountered. The tree is
traversed using a depth-first search (but checking all references of a
structure before looking inside each reference).

Example: You want to translate (2.0,3.0) in the coordinate system of the
referenced coordinate system `d` to the coordinate system of `c`:

```
julia> trans = transformation(c,d)

julia> trans(Point(2.0,3.0))
```
"""
function transformation(c::GeometryStructure, d::GeometryReference)
    x, y = transformation(c, d, ScaledIsometry())

    x || error("Reference tree does not contain $d.")
    return y
end

function transformation(c::GeometryStructure, d::GeometryReference, a)
    # look for the reference in the top level of the reference tree.
    for ref in refs(c)
        if ref === d
            return true, a ∘ transformation(ref)
        end
    end

    # didn't find the reference at this level.
    # we must go deeper...
    for ref in refs(c)
        (x, y) = transformation(structure(ref), d, a ∘ transformation(ref))
        # were we successful?
        if x
            return x, y
        end
    end

    # we should have found `d` by now. report our failure
    return false, a
end

"""
    transformation(c::GeometryStructure, d::GeometryReference, e::GeometryReference, f::GeometryReference...)

Given a geometry structure `c` containing [`GeometryReference`](@ref)
`last(f)` in its tree of references, this function returns a
`Transformations.ScaledIsometry` object that lets you translate from the
coordinate system of `last(f)` to the coordinate system of `c`. This method is needed
when you want to specify intermediate `GeometryReference`s explicitly.

For example, suppose for instance you have a hierarchy of coordinate systems, where coordinate system A references
B1 and B2, which both reference C. Schematically, it might look like this:

```
a -- b1 -- c
  \\      /
   \\ b2 /
```

Coordinate system C appears in two places inside coordinate system A, owing to the fact that it is referenced by
both B1 and B2. If you need to get the coordinate system of C via B2, then you need to do
`transformation(coordinatesystemA, coordsysrefB2, coordsysrefC)`, rather than simply `transform(coordinatesystemA, coordsysrefC)`,
because the latter will just take the first path to C available, via B1.
"""
function transformation(
    c::GeometryStructure,
    d::GeometryReference,
    e::GeometryReference,
    f::GeometryReference...
)
    t = transformation(c, d) ∘ transformation(structure(d), e)
    if length(f) == 0
        return t
    else
        t = t ∘ transformation(structure(e), f[1])
        for i = 1:(length(f) - 1)
            t = t ∘ transformation(structure(f[i]), f[i + 1])
        end
        return t
    end
end

### Flattening
"""
    flatten(c::GeometryReference; depth::Integer=-1, name=uniquename("flatten_"*name(structure(c))), metadata_filter=nothing)

Return a new structure with name `name` with recursively flattened references and arrays up to a hierarchical `depth`.

Flattening adds the elements of references to the top-level coordinate system with appropriate
transformations, then discards those references. Deeper references and arrays are brought
upwards and are not discarded. If `depth=0`, a new coordinate system is returned containing
only the reference.

`metadata_filter` can be a function that takes a `DeviceLayout.Meta` and returns a `Bool`,
like a function returned by [`layer_inclusion`](@ref). In that case, only elements whose metadata `m`
have `metadata_filter(m) == true` will be retained while flattening. Elements of deeper references
and arrays are not filtered.

The reference `c` remains unmodified.
"""
function flatten(
    c::GeometryReference;
    depth::Integer=-1,
    name=uniquename("flatten_" * name(structure(c))),
    metadata_filter=nothing
)
    cflat = coordsys_type(structure(c))(name)
    push!(cflat.refs, c)
    return flatten!(cflat; depth=depth, metadata_filter=metadata_filter)
end

"""
    flat_elements(geom::Union{GeometryStructure,GeometryReference}, only_layers=[], ignore_layers=[])
    flat_elements(geom_layer::Pair{<:Union{GeometryStructure,GeometryReference}})

Return a list of `GeometryEntity` elements in flatten(cs), optionally filtering metadata.

`only_layers` and `ignore_layers` can be layer name `Symbol`s, `DeviceLayout.Meta`, or collections of either.
The metadata filtering function is produced using [`layer_inclusion(only_layers, ignore_layers)`](@ref).
This means that the default empty `only_layers` is the same as listing all layers.

Using an argument pair `geom => layer` is equivalent to `flat_elements(geom, layer)`.
"""
function flat_elements(
    geom::Union{GeometryStructure, GeometryReference},
    only_layers=[],
    ignore_layers=[]
)
    metadata_filter = DeviceLayout.layer_inclusion(only_layers, ignore_layers)
    cs_flat = if (metadata_filter == trivial_inclusion)
        flatten(geom; metadata_filter=nothing)
    else
        flatten(geom; metadata_filter)
    end
    return elements(cs_flat)
end

# Second of pair is only_layers input to layer_inclusion (Symbol, DeviceLayout.Meta, or a collection of either)
flat_elements(geom_layer::Pair{<:Union{GeometryStructure, GeometryReference}}) =
    flat_elements(geom_layer.first, geom_layer.second)

### Creating references
"""
    sref(x::GeometryStructure{T}, origin=zero(Point{T}); kwargs...)

Convenience constructor for `StructureReference{float(T), typeof(x)}`.

Synonyms are accepted for these keywords:

    - X-reflection: `:xrefl`, `:xreflection`, `:refl`, `:reflect`, `:xreflect`,
    `:xmirror`, `:mirror`
    - Magnification: `:mag`, `:magnification`, `:magnify`, `:zoom`, `:scale`
    - Rotation: `:rot`, `:rotation`, `:rotate`, `:angle`
"""
function sref(
    x::GeometryStructure{S},
    origin::Point{T}=zero(Point{S});
    kwargs...
) where {S, T}
    dimension(S) != dimension(T) && throw(Unitful.DimensionError(oneunit(S), oneunit(T)))
    vals = sref_transform_values(origin; kwargs...)
    return StructureReference{float(T), typeof(x)}(x, vals...)
end
sref(x::GeometryStructure{S}, f::Transformation; kwargs...) where {S} = sref(
    x,
    isnothing(origin(f)) ? zero(Point{S}) : origin(f);
    rot=rotation(f),
    mag=mag(f),
    xrefl=xrefl(f),
    kwargs...
)

function sref_transform_values(origin::Point{T}; kwargs...) where {T <: Coordinate}
    argdict = Dict(k => v for (k, v) in kwargs)
    xreflkeys = [:xrefl, :xreflection, :refl, :reflect, :xreflect, :xmirror, :mirror]
    magkeys = [:mag, :magnification, :magnify, :zoom, :scale]
    rotkeys = [:rot, :rotation, :rotate, :angle]

    xrefl = false
    for k in xreflkeys
        if haskey(argdict, k)
            @inbounds xrefl = argdict[k]
            break
        end
    end

    mag = 1.0
    for k in magkeys
        if haskey(argdict, k)
            @inbounds mag = argdict[k]
            break
        end
    end

    rot = 0.0
    for k in rotkeys
        if haskey(argdict, k)
            @inbounds rot = argdict[k]
            break
        end
    end

    return float(origin), xrefl, mag, rot
end

"""
    aref(x::GeometryStructure{S}, origin::Point{T}=zero(Point{S}); kwargs...) where
        {S <: Coordinate, T <: Coordinate}

Construct a `ArrayReference{float(T),typeof(x)}` object.

Keyword arguments specify the column vector, row vector, number of columns,
number of rows, x-reflection, magnification factor, and rotation.

Synonyms are accepted for these keywords:

  - Column vector `dc::Point{T}`: `:deltacol`, `:dcol`, `:dc`, `:vcol`, `:colv`, `:colvec`,
    `:colvector`, `:columnv`, `:columnvec`, `:columnvector`
  - Row vector: `:deltarow`, `:drow`, `:dr`, `:vrow`, `:rv`, `:rowvec`,
    `:rowvector`
  - Number of columns: `:nc`, `:numcols`, `:numcol`, `:ncols`, `:ncol`
  - Number of rows: `:nr`, `:numrows`, `:numrow`, `:nrows`, `:nrow`
  - X-reflection: `:xrefl`, `:xreflection`, `:refl`, `:reflect`, `:xreflect`,
    `:xmirror`, `:mirror`
  - Magnification: `:mag`, `:magnification`, `:magnify`, `:zoom`, `:scale`
  - Rotation: `:rot`, `:rotation`, `:rotate`, `:angle`
"""
function aref(
    x::GeometryStructure{S},
    origin::Point{T}=zero(Point{S});
    kwargs...
) where {S, T}
    dimension(S) != dimension(T) && throw(Unitful.DimensionError(oneunit(S), oneunit(T)))
    vals = aref_transform_values(origin; kwargs...)
    return ArrayReference{float(T), typeof(x)}(x, vals...)
end
aref(x::GeometryStructure{S}, f::Transformation; kwargs...) where {S} = aref(
    x,
    isnothing(origin(f)) ? zero(Point{S}) : origin(f);
    rot=rotation(f),
    mag=mag(f),
    xrefl=xrefl(f),
    kwargs...
)

"""
    aref(x, c::AbstractRange, r::AbstractRange; kwargs...)

Construct an `ArrayReference` based on ranges (probably `LinSpace` or
`FloatRange`). `c` specifies column coordinates and `r` for the rows. Pairs from
`c` and `r` specify the origins of the repeated cells. The extrema of the ranges
therefore do not specify the extrema of the resulting `ArrayReference`'s bounding box;
some care is required.

Keyword arguments specify x-reflection, magnification factor, and rotation,
with synonyms allowed:

  - X-reflection: `:xrefl`, `:xreflection`, `:refl`, `:reflect`, `:xreflect`,
    `:xmirror`, `:mirror`
  - Magnification: `:mag`, `:magnification`, `:magnify`, `:zoom`, `:scale`
  - Rotation: `:rot`, `:rotation`, `:rotate`, `:angle`
"""
function aref(x, c::AbstractRange, r::AbstractRange; kwargs...)
    origin = Point(first(c), first(r))
    _, xrefl, mag, rot = sref_transform_values(origin; kwargs...)
    T = promote_type(eltype(c), eltype(r))
    return ArrayReference{float(T), typeof(x)}(
        x,
        origin,
        Point(step(c), zero(step(c))),
        Point(zero(step(r)), step(r)),
        length(c),
        length(r),
        xrefl,
        mag,
        rot
    )
end

function aref_transform_values(origin::Point{T}; kwargs...) where {T <: Coordinate}
    _, xrefl, mag, rot = sref_transform_values(origin; kwargs...)
    argdict = Dict(k => v for (k, v) in kwargs)

    dckeys = [
        :deltacol,
        :dcol,
        :dc,
        :vcol,
        :colv,
        :colvec,
        :colvector,
        :columnv,
        :columnvec,
        :columnvector
    ]
    drkeys = [:deltarow, :drow, :dr, :vrow, :rv, :rowvec, :rowvector]
    ckeys = [:nc, :numcols, :numcol, :ncols, :ncol, :col]
    rkeys = [:nr, :numrows, :numrow, :nrows, :nrow, :row]

    dc = Point(zero(T), zero(T))
    for k in dckeys
        if haskey(argdict, k)
            @inbounds dc = argdict[k]
            break
        end
    end

    dr = Point(zero(T), zero(T))
    for k in drkeys
        if haskey(argdict, k)
            @inbounds dr = argdict[k]
            break
        end
    end

    c = 1
    for k in ckeys
        if haskey(argdict, k)
            @inbounds c = argdict[k]
            break
        end
    end

    r = 1
    for k in rkeys
        if haskey(argdict, k)
            @inbounds r = argdict[k]
            break
        end
    end

    return (origin, dc, dr, c, r, xrefl, mag, rot)
end

#################
function bounds(
    ref::ArrayReference{S, U}
) where {T, S <: Coordinate, U <: GeometryStructure{T}}
    b = bounds(structure(ref))::Rectangle{S}
    a = transformation(ref)
    bb = bounds(a(b))

    # The following code block is very inefficient

    lls = [
        (
            bb.ll + (i - 1) * ref.deltarow + (j - 1) * ref.deltacol
        )::Point{promote_type(S, T)} for i in (1, ref.row), j in (1, ref.col)
    ]
    urs = lls .+ Point(width(bb), height(bb))
    mb = Rectangle(lowerleft(lls), upperright(urs))

    return mb
end

"""
    bounds(ref::GeometryReference)

Return a `Rectangle` bounding box around all objects in `ref`. The bounding box respects
reflection, rotation, and magnification specified by `ref`.
"""
function bounds(ref::GeometryReference)
    b = bounds(structure(ref))
    a = transformation(ref)
    c = a(b)
    return bounds(c)
end

lowerleft(ref::GeometryReference) = lowerleft(bounds(ref))
upperright(ref::GeometryReference) = upperright(bounds(ref))

function halo(ref::GeometryReference, outer_delta, inner_delta=nothing; kwargs...)
    newref = copy(ref)
    newref.structure = halo(structure(ref), outer_delta, inner_delta; kwargs...)
    return newref
end

function footprint(ref::GeometryReference)
    return transformation(ref)(footprint(structure(ref)))
end

"""
    name(r::GeometryReference)

The name of the structure referenced by `r`; that is, `name(structure(r))`.
"""
name(r::GeometryReference) = name(structure(r))

"""
    getindex(c::GeometryStructure, nom::AbstractString, index::Integer=1)

If `c` references a structure with name `nom`, this method will return the
corresponding `GeometryReference`. If there are several references to that
coordinate system, then `index` specifies which one is returned (in the order they
are found in `refs(c)`). e.g. to specify an index of 2: `myCS["myreferencedCS",2]`.
"""
function Base.getindex(c::GeometryStructure, nom::AbstractString, index::Integer=1)
    inds = findall(x -> name(x) == nom, refs(c))
    return refs(c)[inds[index]]
end

"""
    getindex(c::GeometryReference, nom::AbstractString, index::Integer=1)

If the structure referenced by `c` references a structure with name `nom`,
this method will return the corresponding `GeometryReference`. If
there are several references to that structure, then `index` specifies which one is
returned (in the order they are found in `refs(structure(c))`).

This method is typically used so that we can type the first line instead of the
second line in the following:

```julia
myCS["myreferencedCS"]["onedeeper"]
myCS["myreferencedCS"].structure["onedeeper"]
```
"""
function Base.getindex(c::GeometryReference, nom::AbstractString, index::Integer=1)
    inds = findall(x -> name(x) == nom, refs(structure(c)))
    return refs(structure(c))[inds[index]]
end
