######## Mesh morphing
#
# A morph moves the nodes of an existing mesh file by a displacement field, such as a
# `DesignDisplacement`, and leaves everything else in the file unchanged: the elements,
# their attributes and physical groups, and the order of nodes. It is an alternative to
# re-meshing after small design changes, and keeps the mesh's topology (and so a solver's
# discretization) fixed between designs.

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

  - `num_elements`: The number of elements checked: the volume elements (tetrahedra,
    hexahedra, prisms and pyramids), or the surface elements (triangles and quadrilaterals)
    of a mesh without volume elements. Each is checked on the simplices at its corners,
    which its corner nodes define.
  - `num_inverted`: The number of checked elements that the morph inverted at some corner.
  - `min_jacobian_ratio`, `max_jacobian_ratio`: The extreme ratios of a corner simplex's
    volume (area for surface elements) after the morph to its volume before.
  - `max_strain`: The largest change in an edge vector of a corner simplex relative to its
    length, an estimate of the largest displacement gradient.
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

Supported formats are Gmsh MSH 2.2 and 4.1, ASCII and binary (`.msh`, `.msh2`), and MFEM
meshes v1.x (`.mesh`), including high-order meshes whose nodes are a vector grid function.
Only node coordinates change. Gmsh parametric node coordinates, if present, are left
unchanged.

With `check=true`, an error is thrown if the morph inverts any element at any corner, and
nothing is written. The quality of a high-order mesh is checked on its corner nodes. For an
MFEM mesh with nodes, this requires the nodes to be an `H1` grid function, whose first
degrees of freedom are the vertices.
"""
function morph_mesh(
    src::AbstractString,
    dst::AbstractString,
    displacement;
    unit=STP_UNIT,
    check=true
)
    mesh = _read_mesh(src)
    scale = Float64(ustrip(STP_UNIT, 1.0 * unit))
    D = displacement(mesh.nodes .* scale) ./ scale
    size(D) == size(mesh.nodes) || throw(
        DimensionMismatch(
            "the displacement of $(size(mesh.nodes, 2)) nodes has size $(size(D))"
        )
    )
    newnodes = mesh.nodes .+ D
    quality = _morph_quality(mesh, newnodes)
    if check
        isnothing(quality) && error(
            "Cannot check the quality of the morphed mesh $src (MFEM nodes that are not an H1 grid function); pass check=false to morph without checking"
        )
        quality.num_inverted > 0 && error(
            "The morph inverts $(quality.num_inverted) of $(quality.num_elements) elements of $src (minimum volume ratio $(quality.min_jacobian_ratio)); the displacement is too large for this mesh"
        )
    end
    open(dst, "w") do io
        return write(io, _morphed_bytes(mesh, newnodes))
    end
    return quality
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
`reference`, which must have the same nodes and elements: for example, a mesh after a
sequence of morphs relative to the mesh before the first, to decide when to re-mesh.
`max_displacement` is in the files' units.
"""
function morph_quality(reference::AbstractString, mesh::AbstractString)
    a, b = _read_mesh(reference), _read_mesh(mesh)
    (size(a.nodes) == size(b.nodes) && a.cells == b.cells) ||
        error("$mesh does not have the nodes and elements of $reference")
    return _morph_quality(a, b.nodes)
end

# A mesh file's bytes, its node coordinates (3 × N, file units, file order), where they are
# stored, and the corner nodes of the elements used to check quality.
struct _MeshFile
    format::Symbol # :msh_ascii, :msh_binary, :mfem
    bytes::Vector{UInt8}
    nodes::Matrix{Float64}
    # Binary: the byte offset of each node's x coordinate (y and z follow). ASCII: the byte
    # range of the coordinate text of each node (or of each value, for MFEM byNODES).
    locations::Vector{UnitRange{Int}}
    mfem_by_nodes::Bool
    # The shape and corner node indices of the elements to check.
    cells::Vector{Tuple{Symbol, Vector{Int}}}
    checkable::Bool # false for MFEM nodes that are not an H1 grid function
end

function _read_mesh(path::AbstractString)
    bytes = read(path)
    head = String(bytes[1:min(end, 64)])
    startswith(head, "MFEM mesh v1.") && return _read_mfem(bytes, path)
    startswith(head, "\$MeshFormat") && return _read_msh(bytes, path)
    return error("Unsupported mesh format in $path (expected Gmsh MSH or MFEM mesh v1.x)")
end

function _morphed_bytes(mesh::_MeshFile, newnodes)
    if mesh.format == :msh_binary
        out = copy(mesh.bytes)
        for (j, r) in enumerate(mesh.locations)
            buf = reinterpret(UInt8, [newnodes[1, j], newnodes[2, j], newnodes[3, j]])
            out[first(r):(first(r) + 23)] .= buf
        end
        return out
    end
    # ASCII: splice new coordinate text in place of the old.
    io = IOBuffer()
    pos = 1
    if mesh.format == :mfem && mesh.mfem_by_nodes
        n = size(newnodes, 2)
        for (k, r) in enumerate(mesh.locations)
            write(io, view(mesh.bytes, pos:(first(r) - 1)))
            c, j = divrem(k - 1, n)
            print(io, newnodes[c + 1, j + 1])
            pos = last(r) + 1
        end
    else
        for (j, r) in enumerate(mesh.locations)
            write(io, view(mesh.bytes, pos:(first(r) - 1)))
            print(io, newnodes[1, j], ' ', newnodes[2, j], ' ', newnodes[3, j])
            pos = last(r) + 1
        end
    end
    write(io, view(mesh.bytes, pos:length(mesh.bytes)))
    return take!(io)
end

######## Quality

# The simplices at the corners of each element shape: each corner with its neighbors, by
# local corner index, in the corner order that Gmsh and MFEM share. An element is inverted
# when the volume (area) of any of them changes sign.
const _CORNER_SIMPLICES = Dict{Symbol, Vector{Vector{Int}}}(
    :tet => [[1, 2, 3, 4]],
    :hex => [
        [1, 2, 4, 5],
        [2, 3, 1, 6],
        [3, 4, 2, 7],
        [4, 1, 3, 8],
        [5, 8, 6, 1],
        [6, 5, 7, 2],
        [7, 6, 8, 3],
        [8, 7, 5, 4]
    ],
    :prism => [
        [1, 2, 3, 4],
        [2, 3, 1, 5],
        [3, 1, 2, 6],
        [4, 6, 5, 1],
        [5, 4, 6, 2],
        [6, 5, 4, 3]
    ],
    :pyramid => [[1, 2, 4, 5], [2, 3, 1, 5], [3, 4, 2, 5], [4, 1, 3, 5]],
    :tri => [[1, 2, 3]],
    :quad => [[1, 2, 4], [2, 3, 1], [3, 4, 2], [4, 1, 3]]
)
const _CORNER_COUNTS =
    Dict(:tet => 4, :hex => 8, :prism => 6, :pyramid => 5, :tri => 3, :quad => 4)
_isvolume(shape) = shape in (:tet, :hex, :prism, :pyramid)

# The elements to check: the volume elements, or the surface elements if there are none.
function _checked_cells(cells)
    any(c -> _isvolume(c[1]), cells) && return filter(c -> _isvolume(c[1]), cells)
    return cells
end

function _morph_quality(mesh::_MeshFile, newnodes)
    mesh.checkable || return nothing
    X, Y = mesh.nodes, newnodes
    dmax = 0.0
    for j in axes(X, 2)
        dmax = max(dmax, hypot(Y[1, j] - X[1, j], Y[2, j] - X[2, j], Y[3, j] - X[3, j]))
    end
    rmin, rmax, smax, ninv = Inf, -Inf, 0.0, 0
    for (shape, corners) in mesh.cells
        inverted = false
        for simplex in _CORNER_SIMPLICES[shape]
            c = view(corners, simplex)
            r = length(c) == 4 ? _volume_ratio(X, Y, c) : _area_ratio(X, Y, c)
            isnan(r) && continue
            rmin, rmax = min(rmin, r), max(rmax, r)
            inverted |= r <= 0
            for a = 1:length(c), b = (a + 1):length(c)
                e, f = _col(X, c[b]) - _col(X, c[a]), _col(Y, c[b]) - _col(Y, c[a])
                L = LinearAlgebra.norm(e)
                L > 0 && (smax = max(smax, LinearAlgebra.norm(f - e) / L))
            end
        end
        ninv += inverted
    end
    isempty(mesh.cells) && ((rmin, rmax) = (1.0, 1.0))
    return MorphQuality(length(mesh.cells), ninv, rmin, rmax, smax, dmax)
end

_col(X, i) = SVector(X[1, i], X[2, i], X[3, i])

function _volume_ratio(X, Y, c)
    volume(X) = LinearAlgebra.dot(
        _col(X, c[2]) - _col(X, c[1]),
        LinearAlgebra.cross(_col(X, c[3]) - _col(X, c[1]), _col(X, c[4]) - _col(X, c[1]))
    )
    v0 = volume(X)
    iszero(v0) && return NaN
    return volume(Y) / v0
end

function _area_ratio(X, Y, c)
    normal(X) =
        LinearAlgebra.cross(_col(X, c[2]) - _col(X, c[1]), _col(X, c[3]) - _col(X, c[1]))
    n0 = normal(X)
    a0 = LinearAlgebra.dot(n0, n0)
    iszero(a0) && return NaN
    return LinearAlgebra.dot(normal(Y), n0) / a0
end

######## Gmsh MSH

# Number of nodes of each Gmsh element type.
const _GMSH_NODES = Dict{Int, Int}(
    1 => 2,
    2 => 3,
    3 => 4,
    4 => 4,
    5 => 8,
    6 => 6,
    7 => 5,
    8 => 3,
    9 => 6,
    10 => 9,
    11 => 10,
    12 => 27,
    13 => 18,
    14 => 14,
    15 => 1,
    16 => 8,
    17 => 20,
    18 => 15,
    19 => 13,
    20 => 9,
    21 => 10,
    22 => 12,
    23 => 15,
    24 => 15,
    25 => 21,
    26 => 4,
    27 => 5,
    28 => 6,
    29 => 20,
    30 => 35,
    31 => 56,
    92 => 64,
    93 => 125
)
# The shape of each Gmsh element type with corners to check. For elements of any order, the
# first nodes are the corners.
const _GMSH_SHAPES = Dict{Int, Symbol}(
    (t => :tet for t in (4, 11, 29, 30, 31))...,
    (t => :hex for t in (5, 12, 17, 92, 93))...,
    (t => :prism for t in (6, 13, 18))...,
    (t => :pyramid for t in (7, 14, 19))...,
    (t => :tri for t in (2, 9, 20, 21, 22, 23, 24, 25))...,
    (t => :quad for t in (3, 10, 16))...
)

# A cursor over a mesh file's bytes.
mutable struct _Cursor
    bytes::Vector{UInt8}
    pos::Int
end

function _readline!(c::_Cursor)
    i = findnext(==(UInt8('\n')), c.bytes, c.pos)
    stop = isnothing(i) ? length(c.bytes) : i
    r = (c.pos):(isnothing(i) ? stop : stop - 1)
    c.pos = stop + 1
    # Tolerate Windows line endings.
    if !isempty(r) && c.bytes[last(r)] == UInt8('\r')
        r = first(r):(last(r) - 1)
    end
    return r
end

_line(c::_Cursor, r) = String(c.bytes[r])

function _read!(c::_Cursor, ::Type{T}) where {T}
    n = sizeof(T)
    c.pos + n - 1 <= length(c.bytes) || error("unexpected end of mesh file")
    v = reinterpret(T, view(c.bytes, (c.pos):(c.pos + n - 1)))[1]
    c.pos += n
    return v
end

function _expect_end!(c::_Cursor, section)
    # Binary data is followed by a newline before the closing tag.
    while c.pos <= length(c.bytes) && c.bytes[c.pos] in (UInt8('\n'), UInt8('\r'))
        c.pos += 1
    end
    l = _line(c, _readline!(c))
    return l == "\$End$section" ||
           error("malformed mesh file: expected \$End$section, found $(repr(l))")
end

function _read_msh(bytes, path)
    c = _Cursor(bytes, 1)
    version, binary = 0.0, false
    nodes = Matrix{Float64}(undef, 3, 0)
    locations = UnitRange{Int}[]
    tags = Int[]
    elements = Tuple{Int, Vector{Int}}[] # (type, node tags) of element types with a shape
    while c.pos <= length(bytes)
        header = strip(_line(c, _readline!(c)))
        isempty(header) && continue
        startswith(header, "\$") || error("malformed mesh file $path near $(repr(header))")
        section = header[2:end]
        if section == "MeshFormat"
            fields = split(_line(c, _readline!(c)))
            version = parse(Float64, fields[1])
            binary = fields[2] == "1"
            (version == 2.2 || 4.0 < version < 5.0) || error(
                "Unsupported Gmsh MSH version $version in $path (2.2 and 4.1 are supported)"
            )
            binary &&
                parse(Int, fields[3]) != 8 &&
                error("Unsupported MSH data size in $path")
            binary && _read!(c, Int32) != 1 && error("Unsupported byte order in $path")
            _expect_end!(c, section)
        elseif section == "Nodes"
            nodes, locations, tags =
                version < 3 ? _msh2_nodes!(c, binary) : _msh4_nodes!(c, binary)
            _expect_end!(c, section)
        elseif section == "Elements"
            elements = version < 3 ? _msh2_elements!(c, binary) : _msh4_elements!(c, binary)
            _expect_end!(c, section)
        elseif section == "ParametricNodes"
            error("Unsupported section \$ParametricNodes in $path")
        else
            # Skip any other section to its closing tag.
            marker = Vector{UInt8}("\n\$End$section")
            r = findnext(marker, bytes, c.pos - 1)
            isnothing(r) && error("malformed mesh file $path: no \$End$section")
            c.pos = last(r) + 1
            _readline!(c)
        end
    end
    isempty(locations) && error("No nodes in $path")
    index = Dict(t => j for (j, t) in enumerate(tags))
    cells = map(elements) do (type, nodetags)
        shape = _GMSH_SHAPES[type]
        return (shape, [index[t] for t in nodetags[1:_CORNER_COUNTS[shape]]])
    end
    return _MeshFile(
        binary ? :msh_binary : :msh_ascii,
        bytes,
        nodes,
        locations,
        false,
        _checked_cells(cells),
        true
    )
end

function _msh2_nodes!(c, binary)
    n = parse(Int, strip(_line(c, _readline!(c))))
    nodes = Matrix{Float64}(undef, 3, n)
    locations = Vector{UnitRange{Int}}(undef, n)
    tags = Vector{Int}(undef, n)
    for j = 1:n
        if binary
            tags[j] = _read!(c, Int32)
            locations[j] = (c.pos):(c.pos + 23)
            for d = 1:3
                nodes[d, j] = _read!(c, Float64)
            end
        else
            r = _readline!(c)
            line = _line(c, r)
            # The coordinates follow the tag and one separator.
            t = findfirst(isspace, line)
            tags[j] = parse(Int, line[1:(t - 1)])
            fields = split(line[(t + 1):end])
            for d = 1:3
                nodes[d, j] = parse(Float64, fields[d])
            end
            locations[j] = (first(r) + t):last(r)
        end
    end
    return nodes, locations, tags
end

function _msh2_elements!(c, binary)
    n = parse(Int, strip(_line(c, _readline!(c))))
    elements = Tuple{Int, Vector{Int}}[]
    if binary
        nread = 0
        while nread < n
            type, count, ntags = _read!(c, Int32), _read!(c, Int32), _read!(c, Int32)
            haskey(_GMSH_NODES, type) || error("Unsupported Gmsh element type $type")
            nn = _GMSH_NODES[type]
            for _ = 1:count
                data = [_read!(c, Int32) for _ = 1:(1 + ntags + nn)]
                haskey(_GMSH_SHAPES, type) &&
                    push!(elements, (Int(type), Int.(data[(2 + ntags):end])))
            end
            nread += count
        end
    else
        for _ = 1:n
            fields = parse.(Int, split(_line(c, _readline!(c))))
            type, ntags = fields[2], fields[3]
            haskey(_GMSH_SHAPES, type) && push!(elements, (type, fields[(4 + ntags):end]))
        end
    end
    return elements
end

function _msh4_nodes!(c, binary)
    if binary
        nblocks, n = Int(_read!(c, UInt64)), Int(_read!(c, UInt64))
        _read!(c, UInt64)
        _read!(c, UInt64)
    else
        fields = parse.(Int, split(_line(c, _readline!(c))))
        nblocks, n = fields[1], fields[2]
    end
    nodes = Matrix{Float64}(undef, 3, n)
    locations = Vector{UnitRange{Int}}(undef, n)
    tags = Vector{Int}(undef, n)
    j = 0
    for _ = 1:nblocks
        if binary
            dim, _, parametric = _read!(c, Int32), _read!(c, Int32), _read!(c, Int32)
            m = Int(_read!(c, UInt64))
        else
            fields = parse.(Int, split(_line(c, _readline!(c))))
            dim, parametric, m = fields[1], fields[3], fields[4]
        end
        extra = parametric == 1 ? dim : 0
        for k = 1:m
            tags[j + k] =
                binary ? Int(_read!(c, UInt64)) : parse(Int, strip(_line(c, _readline!(c))))
        end
        for k = 1:m
            if binary
                locations[j + k] = (c.pos):(c.pos + 23)
                for d = 1:3
                    nodes[d, j + k] = _read!(c, Float64)
                end
                c.pos += 8 * extra
            else
                r = _readline!(c)
                line = _line(c, r)
                fields = split(line)
                for d = 1:3
                    nodes[d, j + k] = parse(Float64, fields[d])
                end
                # Rewrite x y z only, keeping any parametric coordinates that follow.
                stop = extra == 0 ? last(r) : first(r) + _token_end(line, 3) - 1
                locations[j + k] = first(r):stop
            end
        end
        j += m
    end
    j == n || error("malformed \$Nodes section: expected $n nodes, found $j")
    return nodes, locations, tags
end

# The (1-based) index of the last character of the k-th whitespace-separated token.
function _token_end(line, k)
    i, count = 1, 0
    n = lastindex(line)
    while i <= n
        while i <= n && isspace(line[i])
            i = nextind(line, i)
        end
        start = i
        while i <= n && !isspace(line[i])
            i = nextind(line, i)
        end
        count += 1
        count == k && return prevind(line, i)
        start == i && break
    end
    return error("malformed node line $(repr(line))")
end

function _msh4_elements!(c, binary)
    if binary
        nblocks = Int(_read!(c, UInt64))
        _read!(c, UInt64)
        _read!(c, UInt64)
        _read!(c, UInt64)
    else
        nblocks = parse(Int, split(_line(c, _readline!(c)))[1])
    end
    elements = Tuple{Int, Vector{Int}}[]
    for _ = 1:nblocks
        if binary
            _, _, type = _read!(c, Int32), _read!(c, Int32), _read!(c, Int32)
            m = Int(_read!(c, UInt64))
        else
            fields = parse.(Int, split(_line(c, _readline!(c))))
            type, m = fields[3], fields[4]
        end
        haskey(_GMSH_NODES, type) || error("Unsupported Gmsh element type $type")
        nn = _GMSH_NODES[type]
        keep = haskey(_GMSH_SHAPES, type)
        for _ = 1:m
            if binary
                data = [Int(_read!(c, UInt64)) for _ = 1:(1 + nn)]
                keep && push!(elements, (Int(type), data[2:end]))
            else
                fields = parse.(Int, split(_line(c, _readline!(c))))
                keep && push!(elements, (Int(type), fields[2:end]))
            end
        end
    end
    return elements
end

######## MFEM mesh

# Geometry types of MFEM elements and their number of vertices, and the shapes to check.
const _MFEM_VERTICES = Dict(0 => 1, 1 => 2, 2 => 3, 3 => 4, 4 => 4, 5 => 8, 6 => 6, 7 => 5)
const _MFEM_SHAPES =
    Dict(2 => :tri, 3 => :quad, 4 => :tet, 5 => :hex, 6 => :prism, 7 => :pyramid)

function _read_mfem(bytes, path)
    c = _Cursor(bytes, 1)
    nv, sdim = 0, 0
    cells = Tuple{Symbol, Vector{Int}}[]
    nodes = Matrix{Float64}(undef, 3, 0)
    locations = UnitRange{Int}[]
    by_nodes, h1 = false, true
    has_nodes = false
    while c.pos <= length(bytes)
        line = strip(_line(c, _readline!(c)))
        if line == "elements"
            ne = parse(Int, strip(_line(c, _readline!(c))))
            for _ = 1:ne
                fields = parse.(Int, split(_line(c, _readline!(c))))
                geom = fields[2]
                haskey(_MFEM_VERTICES, geom) ||
                    error("Unsupported MFEM geometry type $geom in $path")
                haskey(_MFEM_SHAPES, geom) &&
                    push!(cells, (_MFEM_SHAPES[geom], fields[3:end] .+ 1))
            end
        elseif line == "vertices"
            nv = parse(Int, strip(_line(c, _readline!(c))))
            # Without nodes, the vertex coordinates follow their dimension.
            save = c.pos
            l = strip(_line(c, _readline!(c)))
            if l == "nodes" || isempty(l)
                c.pos = save
            else
                sdim = parse(Int, l)
                sdim == 3 || error("Unsupported MFEM mesh space dimension $sdim in $path")
                nodes = Matrix{Float64}(undef, 3, nv)
                locations = Vector{UnitRange{Int}}(undef, nv)
                for j = 1:nv
                    r = _readline!(c)
                    fields = split(_line(c, r))
                    for d = 1:3
                        nodes[d, j] = parse(Float64, fields[d])
                    end
                    locations[j] = r
                end
            end
        elseif line == "nodes"
            has_nodes = true
            vdim, ordering = 0, -1
            while true
                l = strip(_line(c, _readline!(c)))
                isempty(l) && vdim > 0 && ordering >= 0 && break
                if startswith(l, "FiniteElementCollection:")
                    h1 = startswith(
                        strip(l[(length("FiniteElementCollection:") + 1):end]),
                        "H1"
                    )
                elseif startswith(l, "VDim:")
                    vdim = parse(Int, strip(l[6:end]))
                elseif startswith(l, "Ordering:")
                    ordering = parse(Int, strip(l[10:end]))
                end
            end
            vdim == 3 || error("Unsupported MFEM nodes dimension $vdim in $path")
            by_nodes = ordering == 0
            values, ranges = Float64[], UnitRange{Int}[]
            while c.pos <= length(bytes)
                save = c.pos
                r = _readline!(c)
                l = _line(c, r)
                fields = split(l)
                isempty(fields) && continue
                v = tryparse(Float64, fields[1])
                if isnothing(v)
                    c.pos = save
                    break
                end
                if by_nodes
                    push!(values, v)
                    push!(ranges, r)
                else
                    append!(values, parse.(Float64, fields[1:3]))
                    push!(ranges, r)
                end
            end
            if by_nodes
                n = length(values) ÷ 3
                nodes = permutedims(reshape(values, n, 3))
            else
                nodes = reshape(values, 3, :)
            end
            locations = ranges
        end
    end
    isempty(locations) && error("No vertex or node coordinates in $path")
    # The corners of the elements are their vertices, which are the first degrees of freedom
    # of an H1 nodes space; the nodes of other spaces are not ordered by vertex.
    return _MeshFile(
        :mfem,
        bytes,
        nodes,
        locations,
        by_nodes,
        _checked_cells(cells),
        !has_nodes || h1
    )
end
