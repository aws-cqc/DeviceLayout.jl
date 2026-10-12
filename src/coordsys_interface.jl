# CoordSys interface
Base.broadcastable(x::AbstractCoordinateSystem) = Ref(x)
function Base.show(io::IO, c::T) where {S, T <: AbstractCoordinateSystem{S}}
    print(io, type_with_coordinate_string(T, S), " ")
    show(io, name(c))
    return print(io, " with ", length(elements(c)), " els, ", length(refs(c)), " refs")
end

"""
    addref!(c1::AbstractCoordinateSystem, cr::GeometryReference)

Add the reference `cr` to the list of references in `c1`.
"""
function addref!(c1::AbstractCoordinateSystem, cr::GeometryReference)
    return push!(refs(c1), cr)
end

"""
    addref!(c1::AbstractCoordinateSystem{T},
        c2::GeometryStructure,
        origin=zero(Point{T});
        kwargs...)

Add a reference to `c2` to the list of references in `c1`.

The reference to `c2` has origin `origin`; x-reflection, magnification factor, and rotation
are set by keywords arguments.

Keyword arguments:

  - `xrefl`: `true` to reflect across the x-axis
  - `mag`: magnification factor
  - `rot`: rotation angle

Other spellings of these keywords (such as `mirror`, `zoom`, or `angle`) are deprecated
and will be removed in DeviceLayout.jl 2.0.
"""
function addref!(
    c1::AbstractCoordinateSystem{T},
    c2::GeometryStructure,
    origin=zero(Point{T});
    kwargs...
) where {T}
    return addref!(c1, sref(c2, origin; kwargs...))
end

"""
    addarr!(
        c1::AbstractCoordinateSystem{T},
        c2::GeometryStructure,
        origin::Point=zero(Point{T});
        kwargs...
    )

Add an `ArrayReference` to `c2` to the list of references in `c1`.

The reference to `c2` has origin `origin`. Keyword arguments specify the column vector, row vector, number of columns,
number of rows, x-reflection, magnification factor, and rotation.

Keyword arguments:

  - `dc::Point`: column vector
  - `dr::Point`: row vector
  - `nc::Int`: number of columns
  - `nr::Int`: number of rows
  - `xrefl`: `true` to reflect across the x-axis
  - `mag`: magnification factor
  - `rot`: rotation angle

Other spellings of these keywords (such as `mirror`, `zoom`, `angle`, `deltacol`, or `ncols`)
are deprecated and will be removed in DeviceLayout.jl 2.0.
"""
function addarr!(
    c1::AbstractCoordinateSystem{T},
    c2::GeometryStructure,
    origin::Point=zero(Point{T});
    kwargs...
) where {T}
    return addref!(c1, aref(c2, origin; kwargs...))
end

"""
    addarr!(
        c1::AbstractCoordinateSystem,
        c2::GeometryStructure,
        c::AbstractRange,
        r::AbstractRange;
        kwargs...
    )

Add an `ArrayReference` to `c2` to the list of references in `c1`, based on ranges.

`c` specifies column coordinates and `r` for the rows. Pairs from
`c` and `r` specify the origins of the repeated cells. The extrema of the ranges
therefore do not specify the extrema of the resulting `ArrayReference`'s bounding box;
some care is required.

Keyword arguments:

  - `xrefl`: `true` to reflect across the x-axis
  - `mag`: magnification factor
  - `rot`: rotation angle

Other spellings of these keywords (such as `mirror`, `zoom`, or `angle`) are deprecated
and will be removed in DeviceLayout.jl 2.0.
"""
function addarr!(
    c1::AbstractCoordinateSystem,
    c2::GeometryStructure,
    c::AbstractRange,
    r::AbstractRange;
    kwargs...
)
    return addref!(c1, aref(c2, c, r; kwargs...))
end

# CoordSysRef interface (beyond references.jl)
coordsys(x::CoordSysRef) = x.structure

function transform(r::AbstractCoordinateSystem, f::Transformation)
    n = copy(r)
    for (ia, ib) in zip(eachindex(r.elements), eachindex(n.elements))
        @inbounds n.elements[ib] = f(r.elements[ia])
    end
    for (ia, ib) in zip(eachindex(r.refs), eachindex(n.refs))
        @inbounds n.refs[ib] = f(r.refs[ia])
    end
    return n
end

### Flattening and traversal
"""
    traverse!(a::AbstractArray, c::GeometryStructure, level=1)

Given a coordinate system, recursively traverse its references for other coordinate systems and add
to array `a` some tuples: `(level, c)`. `level` corresponds to how deep the coordinate system
was found, and `c` is the found coordinate system.
"""
function traverse!(a::AbstractArray, c::GeometryStructure, level=1)
    push!(a, (level, c))
    for ref in refs(c)
        traverse!(a, structure(ref), level + 1)
    end
end

"""
    order!(a::AbstractArray)

Given an array of tuples like that coming out of [`traverse!`](@ref), we
sort by the `level`, strip the level out, and then retain unique entries.
The aim of this function is to determine an optimal writing order when
saving pattern data (although the GDSII spec does not require cells to be
in a particular order, there may be performance ramifications).

For performance reasons, this function modifies `a` but what you want is the
returned result array.
"""
function order!(a::AbstractArray)
    a = sort!(a, lt=(x, y) -> x[1] < y[1], rev=true)
    return unique(map(x -> x[2], a))
end

"""
    flatten!(c::AbstractCoordinateSystem; depth::Integer=-1, metadata_filter=nothing, max_copy=Inf)

Recursively flatten references and arrays up to a hierarchical `depth`, adding their elements to `c` with appropriate transformations.

The references and arrays that were flattened are then discarded. Deeper references and arrays are brought upwards and are not discarded.

This function has no effect for `depth == 0`, and unlimited depth by default.
"""
function flatten!(
    c::AbstractCoordinateSystem;
    depth::Integer=-1,
    metadata_filter=nothing,
    max_copy=Inf
)
    depth == 0 && return c
    cflat = flatten(c; depth=depth, metadata_filter=metadata_filter, max_copy=max_copy)
    c.elements = elements(cflat)
    c.element_metadata = element_metadata(cflat)
    c.refs = refs(cflat)
    return c
end

"""
    flatten(c::GeometryStructure; depth::Integer=-1, name=uniquename("flatten_"*name(c)), metadata_filter=nothing, max_copy=Inf)

Return a new coordinate system with name `name` with recursively flattened references and arrays up to a hierarchical `depth`.

Flattening a `CoordinateSystem` or `Cell` produces a coordinate system of the same type
(meaning these can also be flattened in-place with [`flatten!`](@ref)), while flattening
other structures generally produces a `CoordinateSystem` with the same coordinate type.

Flattening adds the elements of references to the top-level structure with appropriate
transformations, then discards those references. Deeper references and arrays are brought
upwards and are not discarded.

This function has no effect on references for `depth == 0`, and unlimited depth by default.

References to any structure that is referenced more than `max_copy` times within `depth`
levels of the hierarchy are brought upwards but not flattened, and their contents stay
inside them. References are counted as they would appear after flattening: an
`ArrayReference` counts once, but each reference inside its structure counts once per array
element.
"""
function flatten(
    c::T;
    depth::Integer=-1,
    name=uniquename("flatten_" * name(c)),
    metadata_filter=nothing,
    max_copy=Inf
) where {S, T <: GeometryStructure{S}}
    cflat = coordsys_type(c)(name)
    if depth == 0
        append_coordsys!(cflat, c; addrefs=true, metadata_filter=metadata_filter)
        return cflat
    end
    # append the top-level elements
    append_coordsys!(cflat, c; addrefs=false, metadata_filter=metadata_filter)
    keep = if isinf(max_copy)
        Returns(false)
    else
        counts = structure_counts(c; depth=depth)
        s -> counts[s] > max_copy
    end
    flatrefs, keptrefs, deeprefs = flatten_refs(c; depth=depth, keep=keep)
    # append the references beyond `depth` brought down to top level
    append!(cflat.refs, deeprefs)
    # append the references that are kept rather than flattened
    append!(cflat.refs, keptrefs)
    # append the elements of the flattened references
    append_coordsys!.(cflat, flatrefs; addrefs=false, metadata_filter=metadata_filter)
    return cflat
end

# coordsys_type is the type of the cs generated by `flatten`
# CoordinateSystem for non-CS structures, identical type for other AbstractCS
coordsys_type(::GeometryStructure{T}) where {T} = CoordinateSystem{T}
coordsys_type(::T) where {T <: AbstractCoordinateSystem} = T

# Transformation of each copy of the referenced structure, in the parent's coordinates
instance_transformations(ref::StructureReference) = (transformation(ref),)
function instance_transformations(ref::ArrayReference)
    a = transformation(ref)
    return (
        Transformations.Translation((i - 1) * ref.deltarow + (j - 1) * ref.deltacol) ∘ a for
        i = 1:(ref.row) for j = 1:(ref.col)
    )
end

ninstances(::StructureReference) = 1
ninstances(ref::ArrayReference) = ref.row * ref.col

# Number of references to each structure that flattening to `depth` would produce
function structure_counts(geom::GeometryStructure; depth=-1)
    counts = Dict{GeometryStructure, Int}()
    _structure_counts!(counts, geom, depth, 1)
    return counts
end

# `n` is the number of copies of `geom` in the flattened result
function _structure_counts!(counts, geom, depth, n)
    depth == 0 && return
    for ref in refs(geom)
        s = structure(ref)
        counts[s] = get(counts, s, 0) + n
        _structure_counts!(counts, s, depth - 1, n * ninstances(ref))
    end
end

# References to structures satisfying `keep` go into `keptrefs` without descending into them;
# otherwise their contents would appear both inside the kept reference and flattened.
function flatten_refs(geom::GeometryStructure{T}; depth=-1, keep=Returns(false)) where {T}
    flatrefs = GeometryReference{T}[]
    keptrefs = GeometryReference{T}[]
    deeprefs = GeometryReference{T}[]
    _flatten_refs(
        flatrefs,
        keptrefs,
        deeprefs,
        geom,
        Transformations.IdentityTransformation();
        depth=depth,
        keep=keep
    )
    return flatrefs, keptrefs, deeprefs
end

# Recursive helper accumulates transformations and appends results to refs_flat
function _flatten_refs(flatrefs, keptrefs, deeprefs, geom, a; depth, keep)
    if depth == 0 # this structure's references will be brought upward but not flattened
        append!(deeprefs, a.(refs(geom)))
        return
    end

    for ref in refs(geom)
        push!(keep(structure(ref)) ? keptrefs : flatrefs, a(ref))
    end
    for ref in refs(geom)
        keep(structure(ref)) && continue
        for t in instance_transformations(ref)
            _flatten_refs(
                flatrefs,
                keptrefs,
                deeprefs,
                structure(ref),
                a ∘ t;
                depth=depth - 1,
                keep=keep
            )
        end
    end
end

function append_coordsys!(cs::AbstractCoordinateSystem, ref::StructureReference; kwargs...)
    return append_coordsys!(
        cs,
        structure(ref);
        transformation=transformation(ref),
        kwargs...
    )
end

function append_coordsys!(cs::AbstractCoordinateSystem, ref::ArrayReference; kwargs...)
    a = transformation(ref)
    pts = [
        (i - 1) * ref.deltarow + (j - 1) * ref.deltacol for i = 1:(ref.row) for
        j = 1:(ref.col)
    ]
    for pt in pts
        append_coordsys!(
            cs,
            structure(ref);
            transformation=Transformations.Translation(pt) ∘ a,
            kwargs...
        )
    end
end

# Metadata filter is not applied to refs
function append_coordsys!(
    cs::AbstractCoordinateSystem,
    geom::GeometryStructure;
    transformation=Transformations.IdentityTransformation(),
    metadata_filter=nothing,
    addrefs=true
)
    if isnothing(metadata_filter)
        render!(cs, transformation.(elements(geom)), element_metadata(geom))
    else
        idx = findall(metadata_filter, element_metadata(geom))
        render!(cs, transformation.(elements(geom)[idx]), element_metadata(geom)[idx])
    end

    return addrefs && append!(cs.refs, transformation.(refs(geom)))
end
