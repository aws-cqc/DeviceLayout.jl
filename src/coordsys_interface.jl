# CoordSys interface
Base.broadcastable(x::AbstractCoordinateSystem) = Ref(x)
Base.show(io::IO, c::T) where {T <: AbstractCoordinateSystem} = print(
    io,
    "$(T.name.wrapper) \"$(name(c))\" with $(length(elements(c))) els, $(length(refs(c))) refs"
)

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

Synonyms are accepted for these keywords:

  - X-reflection: `:xrefl`, `:xreflection`, `:refl`, `:reflect`, `:xreflect`,
    `:xmirror`, `:mirror`
  - Magnification: `:mag`, `:magnification`, `:magnify`, `:zoom`, `:scale`
  - Rotation: `:rot`, `:rotation`, `:rotate`, `:angle`
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

Keyword arguments specify x-reflection, magnification factor, and rotation,
with synonyms allowed:

  - X-reflection: `:xrefl`, `:xreflection`, `:refl`, `:reflect`, `:xreflect`,
    `:xmirror`, `:mirror`
  - Magnification: `:mag`, `:magnification`, `:magnify`, `:zoom`, `:scale`
  - Rotation: `:rot`, `:rotation`, `:rotate`, `:angle`
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
    flatrefs, deeprefs = flatten_refs(c, depth=depth)
    # append the references beyond `depth` brought down to top level
    append!(cflat.refs, deeprefs)
    if isinf(max_copy)
        # append the elements of the flattened references
        append_coordsys!.(cflat, flatrefs; addrefs=false, metadata_filter=metadata_filter)
    else # If any structures are referenced more than `max_copy` times, treat as deeprefs
        structure_count = Dict{GeometryStructure, Int}() # Count up structures
        for s in structure.(flatrefs)
            structure_count[s] = get(structure_count, s, 0) + 1
        end
        keepref_idx = findall(r -> structure_count[structure(r)] > max_copy, flatrefs)
        append_idx = findall(r -> !(structure_count[structure(r)] > max_copy), flatrefs)
        append_coordsys!.(
            cflat,
            flatrefs[append_idx];
            addrefs=false,
            metadata_filter=metadata_filter
        )
        append!(cflat.refs, flatrefs[keepref_idx])
    end
    return cflat
end

# coordsys_type is the type of the cs generated by `flatten`
# CoordinateSystem for non-CS structures, identical type for other AbstractCS
coordsys_type(::GeometryStructure{T}) where {T} = CoordinateSystem{T}
coordsys_type(::T) where {T <: AbstractCoordinateSystem} = T

function flatten_refs(geom::GeometryStructure{T}; depth=-1) where {T}
    flatrefs = GeometryReference{T}[]
    deeprefs = GeometryReference{T}[]
    _flatten_refs(
        flatrefs,
        deeprefs,
        geom,
        Transformations.IdentityTransformation();
        depth=depth
    )
    return flatrefs, deeprefs
end

# Recursive helper accumulates transformations and appends results to refs_flat
function _flatten_refs(flatrefs, deeprefs, geom, a; depth=depth)
    if depth == 0 # this structure's references will be brought upward but not flattened
        append!(deeprefs, a.(refs(geom)))
        return
    end

    append!(flatrefs, a.(refs(geom)))
    for ref in refs(geom)
        _flatten_refs(
            flatrefs,
            deeprefs,
            structure(ref),
            a ∘ transformation(ref);
            depth=depth - 1
        )
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
