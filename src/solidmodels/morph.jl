######## Mesh morphing
#
# A morph moves the nodes of a Gmsh mesh file by a displacement field, such as a
# `DesignDisplacement`, and keeps its elements, physical groups and format. It is an
# alternative to re-meshing after small design changes, and keeps the mesh's topology (and
# so a solver's discretization) fixed between designs. Files are read and written by Gmsh,
# in a temporary model.

import StaticArrays: SMatrix

"""
    struct MorphQuality
        num_elements::Int
        num_inverted::Int
        min_jacobian_ratio::Float64
        max_jacobian_ratio::Float64
        max_strain::Float64
        max_displacement::Float64
    end

The change in element quality from a [`SolidModels.morph_mesh`](@ref).

  - `num_elements`: The number of elements checked: the volume elements, or the surface
    elements of a mesh without volume elements. Each is checked at its corners.
  - `num_inverted`: The number of checked elements that the morph inverted at some corner.
  - `min_jacobian_ratio`, `max_jacobian_ratio`: The extreme ratios of the Jacobian
    determinant at a corner after the morph to its value before. For surface elements, this
    is the ratio of area elements, negative where the normal flips.
  - `max_strain`: The largest norm of the displacement gradient at a corner.
  - `max_displacement`: The largest node displacement, in the mesh file's units.

A small `min_jacobian_ratio` (below about 0.3) or a large `max_strain` (above about 0.3)
indicates that the morphed mesh has degraded and the design should be re-meshed.
"""
struct MorphQuality
    num_elements::Int
    num_inverted::Int
    min_jacobian_ratio::Float64
    max_jacobian_ratio::Float64
    max_strain::Float64
    max_displacement::Float64
end

"""
    morph_mesh(src, dst, displacement; unit=STP_UNIT, check=true)
    morph_mesh(src, dst, velocities, δp::NamedTuple; unit=STP_UNIT, check=true)

Write to `dst` the mesh in the file `src` with each node `X` moved to `X + displacement(X)`,
and return the [`SolidModels.MorphQuality`](@ref) of the result.

`displacement` maps a `3 × N` matrix of node coordinates in `STP_UNIT` to a `3 × N` matrix
of displacements in `STP_UNIT`, like a [`SolidModels.DesignDisplacement`](@ref). The second
form uses [`SolidModels.design_displacement(velocities, δp)`](@ref
SolidModels.design_displacement). `unit` is the length unit of the coordinates in the file;
meshes saved from a `SolidModel` use `STP_UNIT`.

The mesh must be a Gmsh MSH 2.2 or 4.1 file, ASCII or binary, of any order, and `dst` must
have the extension `.msh` or that of the format (`.msh2` or `.msh4`). Gmsh reads the mesh
and writes it back in the same format with only the nodes moved, but MSH 2.2 files have
their nodes and elements renumbered, and the bounding boxes of MSH 4.1 entities are not
kept. Parametric node coordinates are kept unchanged.

With `check=true`, an error is thrown if the morph inverts any element at any corner, and
nothing is written.
"""
function morph_mesh(
    src::AbstractString,
    dst::AbstractString,
    displacement;
    unit=STP_UNIT,
    check=true
)
    version, binary = _msh_format(src)
    _check_destination(dst, version, src)
    scale = Float64(ustrip(STP_UNIT, 1.0 * unit))
    return _with_mesh(src, version) do mesh
        D = displacement(mesh.nodes .* scale) ./ scale
        size(D) == size(mesh.nodes) || throw(
            DimensionMismatch(
                "the displacement of $(size(mesh.nodes, 2)) nodes has size $(size(D))"
            )
        )
        newnodes = mesh.nodes .+ D
        quality = _morph_quality(mesh, mesh.nodes, newnodes)
        check &&
            quality.num_inverted > 0 &&
            error(
                "The morph inverts $(quality.num_inverted) of $(quality.num_elements) elements of $src (minimum Jacobian ratio $(quality.min_jacobian_ratio)); the displacement is too large for this mesh"
            )
        _set_nodes!(mesh, newnodes)
        _write_msh(dst, version, binary, mesh, src)
        return quality
    end
end

morph_mesh(
    src::AbstractString,
    dst::AbstractString,
    velocities,
    δp::NamedTuple;
    kwargs...
) = morph_mesh(src, dst, design_displacement(velocities, δp); kwargs...)

"""
    morph_quality(reference, mesh)

The [`SolidModels.MorphQuality`](@ref) of the mesh file `mesh` relative to the mesh file
`reference`, which must have the same elements: for example, a mesh after a sequence of
morphs relative to the mesh before the first, to decide when to re-mesh. Nodes correspond
through the elements, so they may be numbered differently. `max_displacement` is in the
files' units.
"""
function morph_quality(reference::AbstractString, mesh::AbstractString)
    a = _with_mesh(identity, reference, first(_msh_format(reference)))
    b = _with_mesh(identity, mesh, first(_msh_format(mesh)))
    return _morph_quality(a, a.nodes, _corresponding_nodes(a, b, reference, mesh))
end

######## Reading and writing

# The elements of one type on one entity.
struct _ElementBlock
    dim::Int
    entity::Int
    type::Int
    nodes::Matrix{Int} # nodes per element × elements, columns of the node matrix
end

# The nodes (3 × N, file units) of the mesh in the current Gmsh model, with the entities
# they are classified on, and its elements by entity and type.
struct _MeshData
    tags::Vector{Int}
    nodes::Matrix{Float64}
    # The columns of the nodes of each entity, and their parametric coordinates.
    entities::Vector{Tuple{UnitRange{Int}, Vector{Float64}}}
    blocks::Vector{_ElementBlock}
    # The gradients of the Lagrange basis of each element type at its corners:
    # dim × nodes per element × corners.
    gradients::Dict{Int, Array{Float64, 3}}
end

function _msh_format(path::AbstractString)
    isfile(path) || throw(ArgumentError("no mesh file $path"))
    lines = split(open(io -> String(read(io, 128)), path), '\n')
    if length(lines) >= 2 && strip(lines[1]) == "\$MeshFormat"
        fields = split(lines[2])
        version = tryparse(Float64, get(fields, 1, ""))
        binary = tryparse(Int, get(fields, 2, ""))
        version in (2.2, 4.1) && binary in (0, 1) && return version, binary
    end
    return error("Unsupported mesh format in $path (expected Gmsh MSH 2.2 or 4.1)")
end

# Gmsh writes `.msh2` files as MSH 2.2 and `.msh4` files as MSH 4.1, whatever the version set.
function _check_destination(dst, version, src)
    ext = lowercase(splitext(dst)[2])
    ext == ".msh" && return
    ext == (version < 3 ? ".msh2" : ".msh4") && return
    throw(
        ArgumentError(
            "Cannot write $dst in the format of $src (MSH $version); use the extension .msh or $(version < 3 ? ".msh2" : ".msh4")"
        )
    )
end

# Call `f(mesh)` with the mesh in the file `path` read into a temporary Gmsh model, then
# restore the current model and options.
function _with_mesh(f, path, version)
    initialized = gmsh.is_initialized() != 0
    initialized || gmsh.initialize()
    current = initialized ? gmsh.model.get_current() : ""
    verbosity = gmsh.option.get_number("General.Verbosity")
    gmsh.option.set_number("General.Verbosity", min(verbosity, 2))
    name = "morph_mesh"
    while name in gmsh.model.list()
        name *= "_"
    end
    gmsh.model.add(name)
    try
        gmsh.merge(path)
        version < 3 && _remove_repeated_elements!()
        return f(_mesh_data())
    finally
        gmsh.model.set_current(name)
        gmsh.model.remove()
        initialized && current in gmsh.model.list() && gmsh.model.set_current(current)
        gmsh.option.set_number("General.Verbosity", verbosity)
        initialized || gmsh.finalize()
    end
end

# MSH 2.2 repeats an element for each physical group it is in, which Gmsh reads as separate
# elements of one entity. Remove all but the first, keeping the order of elements, by which
# `morph_quality` matches the nodes of two files.
function _remove_repeated_elements!()
    for (dim, tag) in gmsh.model.get_entities()
        types, elements, nodes = gmsh.model.mesh.get_elements(dim, tag)
        keep = [Int[] for _ in types]
        for (k, (et, en)) in enumerate(zip(elements, nodes))
            n = length(en) ÷ length(et)
            seen = Set{Vector{Csize_t}}()
            for e in eachindex(et)
                key = sort!(en[(n * (e - 1) + 1):(n * e)])
                key in seen || (push!(seen, key); push!(keep[k], e))
            end
        end
        all(k -> length(keep[k]) == length(elements[k]), eachindex(types)) && continue
        # Rebuild the entity's elements, which is faster than removing the repeats.
        gmsh.model.mesh.remove_elements(dim, tag)
        for (k, type) in enumerate(types)
            n = length(nodes[k]) ÷ length(elements[k])
            gmsh.model.mesh.add_elements_by_type(
                tag,
                type,
                elements[k][keep[k]],
                vec(reshape(nodes[k], n, :)[:, keep[k]])
            )
        end
    end
end

function _mesh_data()
    tags, coords = Int[], Float64[]
    entities = Tuple{UnitRange{Int}, Vector{Float64}}[]
    for (dim, tag) in gmsh.model.get_entities()
        t, x, u = gmsh.model.mesh.get_nodes(dim, tag, false, true)
        push!(entities, ((length(tags) + 1):(length(tags) + length(t)), u))
        append!(tags, t)
        append!(coords, x)
    end
    index = Dict(t => k for (k, t) in enumerate(tags))
    blocks = _ElementBlock[]
    gradients = Dict{Int, Array{Float64, 3}}()
    for (dim, tag) in gmsh.model.get_entities()
        types, _, nodetags = gmsh.model.mesh.get_elements(dim, tag)
        for (type, nt) in zip(types, nodetags)
            n = gmsh.model.mesh.get_element_properties(type)[4]
            nodes = reshape([index[Int(t)] for t in nt], n, :)
            push!(blocks, _ElementBlock(dim, tag, type, nodes))
            dim >= 2 &&
                !haskey(gradients, type) &&
                (gradients[type] = _corner_gradients(type))
        end
    end
    return _MeshData(tags, reshape(coords, 3, :), entities, blocks, gradients)
end

function _corner_gradients(type)
    _, dim, _, n, local_coords, ncorners = gmsh.model.mesh.get_element_properties(type)
    m = length(local_coords) ÷ n
    ξ = zeros(3ncorners)
    for c = 1:ncorners, i = 1:m
        ξ[3(c - 1) + i] = local_coords[m * (c - 1) + i]
    end
    _, basis, _ = gmsh.model.mesh.get_basis_functions(type, ξ, "GradLagrange")
    return reshape(basis, 3, n, ncorners)[1:dim, :, :]
end

function _set_nodes!(mesh::_MeshData, newnodes)
    for (columns, u) in mesh.entities
        m = isempty(u) ? 0 : length(u) ÷ length(columns)
        for (i, k) in enumerate(columns)
            gmsh.model.mesh.set_node(
                mesh.tags[k],
                newnodes[:, k],
                u[(m * (i - 1) + 1):(m * i)]
            )
        end
    end
end

function _write_msh(dst, version, binary, mesh, src)
    # Gmsh writes the elements of physical groups, or with `SaveAll` every element: in
    # MSH 2.2 without groups, and in MSH 4.1 with empty node blocks for entities without
    # nodes.
    ungrouped =
        !isempty(gmsh.model.get_physical_groups()) && any(
            b -> isempty(gmsh.model.get_physical_groups_for_entity(b.dim, b.entity)),
            mesh.blocks
        )
    version < 3 &&
        ungrouped &&
        error(
            "Cannot morph $src: it has elements outside physical groups, which Gmsh writes to MSH 2.2 only without groups; save the mesh as MSH 4.1"
        )
    options = (
        "Mesh.MshFileVersion" => version,
        "Mesh.Binary" => binary,
        "Mesh.SaveAll" => ungrouped ? 1 : 0,
        "Mesh.Renumber" => 0,
        "Mesh.SaveParametric" => any(e -> !isempty(e[2]), mesh.entities) ? 1 : 0
    )
    saved = [k => gmsh.option.get_number(k) for (k, _) in options]
    try
        foreach(o -> gmsh.option.set_number(o[1], o[2]), options)
        gmsh.write(dst)
    finally
        foreach(o -> gmsh.option.set_number(o[1], o[2]), saved)
    end
end

# The coordinates of the nodes of `b` at the nodes of `a`, corresponding through the
# elements, which must be the same.
function _corresponding_nodes(a::_MeshData, b::_MeshData, reference, mesh)
    mismatch() = error("$mesh does not have the elements of $reference")
    length(a.blocks) == length(b.blocks) || mismatch()
    match = zeros(Int, size(a.nodes, 2))
    for (ba, bb) in zip(a.blocks, b.blocks)
        (ba.dim, ba.entity, ba.type, size(ba.nodes)) ==
        (bb.dim, bb.entity, bb.type, size(bb.nodes)) || mismatch()
        for k in eachindex(ba.nodes)
            i, j = ba.nodes[k], bb.nodes[k]
            iszero(match[i]) ? (match[i] = j) : (match[i] == j || mismatch())
        end
    end
    Y = copy(a.nodes)
    for i in eachindex(match)
        iszero(match[i]) || (Y[:, i] .= view(b.nodes, :, match[i]))
    end
    return Y
end

######## Quality

function _morph_quality(mesh::_MeshData, X, Y)
    dmax = 0.0
    for j in axes(X, 2)
        dmax = max(dmax, hypot(Y[1, j] - X[1, j], Y[2, j] - X[2, j], Y[3, j] - X[3, j]))
    end
    # The volume elements, or the surface elements if there are none.
    dim = maximum(b -> b.dim, mesh.blocks; init=0)
    rmin, rmax, smax, ninv, nel = Inf, -Inf, 0.0, 0, 0
    for b in mesh.blocks
        (b.dim == dim && dim >= 2) || continue
        G = mesh.gradients[b.type]
        for e in axes(b.nodes, 2)
            inverted = false
            for c in axes(G, 3)
                r, s = _corner_change(X, Y, view(b.nodes, :, e), view(G, :, :, c), dim)
                isfinite(r) || continue
                rmin, rmax, smax = min(rmin, r), max(rmax, r), max(smax, s)
                inverted |= r <= 0
            end
            ninv += inverted
        end
        nel += size(b.nodes, 2)
    end
    iszero(nel) && ((rmin, rmax) = (1.0, 1.0))
    return MorphQuality(nel, ninv, rmin, rmax, smax, dmax)
end

# The Jacobian ratio and the norm of the displacement gradient at one corner of an element
# with nodes `nodes`, where the basis has gradients `G` (dim × nodes).
function _corner_change(X, Y, nodes, G, dim)
    if dim == 3
        J0, J1 = zero(SMatrix{3, 3, Float64}), zero(SMatrix{3, 3, Float64})
        for a in eachindex(nodes)
            g = SVector(G[1, a], G[2, a], G[3, a])
            J0 += _col(X, nodes[a]) * g'
            J1 += _col(Y, nodes[a]) * g'
        end
        d0 = LinearAlgebra.det(J0)
        (iszero(d0) || !isfinite(d0)) && return NaN, 0.0
        r = LinearAlgebra.det(J1) / d0
        return r, LinearAlgebra.opnorm((J1 - J0) / J0)
    end
    T0, T1 = zero(SMatrix{3, 2, Float64}), zero(SMatrix{3, 2, Float64})
    for a in eachindex(nodes)
        g = SVector(G[1, a], G[2, a])
        T0 += _col(X, nodes[a]) * g'
        T1 += _col(Y, nodes[a]) * g'
    end
    n0 = LinearAlgebra.cross(T0[:, 1], T0[:, 2])
    a0 = LinearAlgebra.dot(n0, n0)
    (iszero(a0) || !isfinite(a0)) && return NaN, 0.0
    r = LinearAlgebra.dot(LinearAlgebra.cross(T1[:, 1], T1[:, 2]), n0) / a0
    # The displacement gradient along the surface, through the pseudoinverse of T0.
    return r, LinearAlgebra.opnorm((T1 - T0) * (inv(T0' * T0) * T0'))
end

_col(X, i) = SVector(X[1, i], X[2, i], X[3, i])
