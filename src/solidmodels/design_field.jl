######## Design velocities: the in-plane field
#
# The velocities of the rendered edges in a window, extended into the window by harmonic
# interpolation: a planar arrangement of the edges, a constrained triangulation of the window,
# and a P1 harmonic interpolation on it, with a point locator to evaluate it.

import DelaunayTriangulation
import LinearAlgebra
import SparseArrays
import Random
import DeviceLayout: orientation

# Coordinates closer than this (in STP_UNIT) are the same point. This is far below layout
# tolerances (`onenanometer`) and far above Float64 resolution at chip scale.
const VELOCITY_MERGE_ATOL = 1e-6

# A triangulation of the window of one plane: points, triangles and a point locator. Shared
# by the design velocities of all parameters built together.
struct _PlaneMesh
    window::NTuple{4, Float64} # (xmin, xmax, ymin, ymax)
    points::Matrix{Float64} # 2 × n
    triangles::Matrix{Int32} # 3 × nt
    cell_size::NTuple{2, Float64}
    cell_counts::NTuple{2, Int}
    cell_offsets::Vector{Int32} # CSR offsets into `cell_triangles`
    cell_triangles::Vector{Int32}
end

# Return the index of the triangle containing (x, y) and the barycentric coordinates there,
# or 0 outside the window.
function _locate(m::_PlaneMesh, x::Float64, y::Float64)
    xmin, xmax, ymin, ymax = m.window
    λ0 = SVector(0.0, 0.0, 0.0)
    (xmin <= x <= xmax && ymin <= y <= ymax) || return 0, λ0
    i = clamp(floor(Int, (x - xmin) / m.cell_size[1]) + 1, 1, m.cell_counts[1])
    j = clamp(floor(Int, (y - ymin) / m.cell_size[2]) + 1, 1, m.cell_counts[2])
    c = (j - 1) * m.cell_counts[1] + i
    best, bestλ, bestmin = 0, λ0, -Inf
    for k = m.cell_offsets[c]:(m.cell_offsets[c + 1] - 1)
        t = m.cell_triangles[k]
        λ = _barycentric(m, t, x, y)
        μ = minimum(λ)
        μ >= -1e-12 && return Int(t), λ
        if μ > bestmin
            best, bestλ, bestmin = Int(t), λ, μ
        end
    end
    # Only reached on round-off at the window boundary, where the field vanishes.
    return best, bestλ
end

function _barycentric(m::_PlaneMesh, t, x, y)
    a, b, c = m.triangles[1, t], m.triangles[2, t], m.triangles[3, t]
    ax, ay = m.points[1, a], m.points[2, a]
    bx, by = m.points[1, b], m.points[2, b]
    cx, cy = m.points[1, c], m.points[2, c]
    d = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay)
    λb = ((x - ax) * (cy - ay) - (cx - ax) * (y - ay)) / d
    λc = ((bx - ax) * (y - ay) - (x - ax) * (by - ay)) / d
    return SVector(1 - λb - λc, λb, λc)
end

# A planar arrangement of the rendered edges in the window: merged vertices with velocities
# (2 rows per parameter), and segments that cross or touch only at shared vertices.
struct _Arrangement
    window::NTuple{4, Float64}
    points::Vector{SVector{2, Float64}}
    velocities::Vector{Vector{Float64}}
    segments::Vector{NTuple{2, Int}}
    cell::Float64
    lookup::Dict{NTuple{2, Int}, Vector{Int}}
end

function _Arrangement(window, cell)
    return _Arrangement(
        window,
        SVector{2, Float64}[],
        Vector{Float64}[],
        NTuple{2, Int}[],
        cell,
        Dict{NTuple{2, Int}, Vector{Int}}()
    )
end

_cellkey(arr, p) = (floor(Int, p[1] / arr.cell), floor(Int, p[2] / arr.cell))

function _velocity_tol(v)
    return 1e-6 * max(1.0, maximum(abs, v; init=0.0))
end

# Add a point (merging with an existing one) and return its index.
function _add_point!(arr::_Arrangement, p::SVector{2, Float64}, v::Vector{Float64})
    kx, ky = _cellkey(arr, p)
    for dx = -1:1, dy = -1:1
        for i in get(arr.lookup, (kx + dx, ky + dy), Int[])
            if hypot(arr.points[i][1] - p[1], arr.points[i][2] - p[2]) <=
               VELOCITY_MERGE_ATOL
                maximum(abs, arr.velocities[i] .- v) <= _velocity_tol(v) || error(
                    "Rendered features that touch at $(Tuple(p)) μm move apart; the parameter changes the layout's topology"
                )
                return i
            end
        end
    end
    push!(arr.points, p)
    push!(arr.velocities, v)
    push!(get!(arr.lookup, (kx, ky), Int[]), length(arr.points))
    return length(arr.points)
end

# Clip a segment to the window (Liang–Barsky) and return the parameter interval, or nothing.
function _clip_segment(win, a, b)
    xmin, xmax, ymin, ymax = win
    t0, t1 = 0.0, 1.0
    d = b - a
    for (p, q) in (
        (-d[1], a[1] - xmin),
        (d[1], xmax - a[1]),
        (-d[2], a[2] - ymin),
        (d[2], ymax - a[2])
    )
        if iszero(p)
            q < 0 && return nothing
        else
            r = q / p
            if p < 0
                t0 = max(t0, r)
            else
                t1 = min(t1, r)
            end
        end
    end
    return t0 < t1 ? (t0, t1) : nothing
end

function _on_window_boundary(win, p)
    xmin, xmax, ymin, ymax = win
    tol = VELOCITY_MERGE_ATOL
    return abs(p[1] - xmin) <= tol ||
           abs(p[1] - xmax) <= tol ||
           abs(p[2] - ymin) <= tol ||
           abs(p[2] - ymax) <= tol
end

function _arrangement(base, vel, z, win)
    xmin, xmax, ymin, ymax = win
    arr = _Arrangement(win, max(xmax - xmin, ymax - ymin) / 1e4)
    np = length(vel)
    vertex_velocity(i, l, k) = vcat((v[i][l][:, k] for v in vel)...)
    for (i, e) in enumerate(base)
        (_onplane(e, z) && _bbox_overlaps(e.loops, win)) || continue
        for (l, loop) in enumerate(e.loops)
            n = size(loop, 2)
            for k = 1:n
                k2 = mod1(k + 1, n)
                a, b = SVector(loop[1, k], loop[2, k]), SVector(loop[1, k2], loop[2, k2])
                t = _clip_segment(win, a, b)
                isnothing(t) && continue
                va, vb = vertex_velocity(i, l, k), vertex_velocity(i, l, k2)
                ends = map(t) do s
                    p, v = a + s * (b - a), (1 - s) .* va .+ s .* vb
                    _on_window_boundary(win, p) &&
                        maximum(abs, v) > _velocity_tol(v) &&
                        error(
                            "The design velocity window cuts a moving edge of layer $(layer(e.meta)) at $(Tuple(p)) μm; enlarge the window"
                        )
                    return _add_point!(arr, p, v)
                end
                ends[1] != ends[2] && push!(arr.segments, minmax(ends...))
            end
        end
    end
    unique!(arr.segments)
    _split_segments!(arr, np)
    return arr
end

# A uniform grid over the window listing the segments whose bounding box overlaps each cell.
struct _SegmentGrid
    origin::NTuple{2, Float64}
    cell::NTuple{2, Float64}
    cells::Dict{NTuple{2, Int}, Vector{Int}}
end

function _SegmentGrid(arr::_Arrangement)
    xmin, xmax, ymin, ymax = arr.window
    nc = max(1, round(Int, sqrt(length(arr.segments))))
    grid = _SegmentGrid(
        (xmin, ymin),
        ((xmax - xmin) / nc, (ymax - ymin) / nc),
        Dict{NTuple{2, Int}, Vector{Int}}()
    )
    for (s, (i, j)) in enumerate(arr.segments)
        p, q = arr.points[i], arr.points[j]
        (i0, j0), (i1, j1) = _cellindex(grid, min.(p, q)), _cellindex(grid, max.(p, q))
        for cx = i0:i1, cy = j0:j1
            push!(get!(grid.cells, (cx, cy), Int[]), s)
        end
    end
    return grid
end

_cellindex(g::_SegmentGrid, p) = (
    floor(Int, (p[1] - g.origin[1]) / g.cell[1]),
    floor(Int, (p[2] - g.origin[2]) / g.cell[2])
)

# Split the segments at their crossings and at vertices that lie on them, so that segments
# meet only at shared endpoints, and give each crossing the velocity it moves with.
function _split_segments!(arr::_Arrangement, np)
    segs = arr.segments
    splits = [Tuple{Float64, Int}[] for _ in segs]
    grid = _SegmentGrid(arr)
    tested = Set{NTuple{2, Int}}()
    for candidates in values(grid.cells), s1 in candidates, s2 in candidates
        s1 < s2 || continue
        (s1, s2) in tested && continue
        push!(tested, (s1, s2))
        _intersect_segments!(arr, splits, s1, s2, np)
    end
    newsegs = NTuple{2, Int}[]
    for (s, (i, j)) in enumerate(segs)
        chain = vcat([(0.0, i)], sort!(splits[s]), [(1.0, j)])
        for k = 1:(length(chain) - 1)
            a, b = chain[k][2], chain[k + 1][2]
            a != b && push!(newsegs, minmax(a, b))
        end
    end
    empty!(segs)
    return append!(segs, unique!(newsegs))
end

_cross(a, b) = a[1] * b[2] - a[2] * b[1]

function _intersect_segments!(arr, splits, s1, s2, np)
    (a, b), (c, d) = arr.segments[s1], arr.segments[s2]
    A, B, C, D = arr.points[a], arr.points[b], arr.points[c], arr.points[d]
    # Endpoints of one segment on the interior of the other: T-junctions and collinear
    # overlaps. The vertex keeps its velocity, which must keep it on the other segment.
    touching = false
    for (s, (p, q), P, Q, e, E) in (
        (s2, (c, d), C, D, a, A),
        (s2, (c, d), C, D, b, B),
        (s1, (a, b), A, B, c, C),
        (s1, (a, b), A, B, d, D)
    )
        e in (p, q) && continue
        t = _on_segment(E, P, Q)
        isnothing(t) && continue
        vint = (1 - t) .* arr.velocities[p] .+ t .* arr.velocities[q]
        n = SVector(-(Q - P)[2], (Q - P)[1]) / hypot((Q - P)...)
        for k = 1:np
            δ = arr.velocities[e][(2k - 1):(2k)] .- vint[(2k - 1):(2k)]
            abs(n[1] * δ[1] + n[2] * δ[2]) <= _velocity_tol(arr.velocities[e]) || error(
                "A rendered vertex at $(Tuple(E)) μm leaves the edge it lies on; the parameter changes the layout's topology"
            )
        end
        push!(splits[s], (t, e))
        touching = true
    end
    # Proper crossings, of segments that do not already touch: a vertex within the merge
    # tolerance of the other segment is a T-junction, not a crossing.
    (touching || length(intersect((a, b), (c, d))) > 0) && return
    o1 = orientation(Point(A...), Point(B...), Point(C...))
    o2 = orientation(Point(A...), Point(B...), Point(D...))
    o3 = orientation(Point(C...), Point(D...), Point(A...))
    o4 = orientation(Point(C...), Point(D...), Point(B...))
    (o1 * o2 < 0 && o3 * o4 < 0) || return
    r, u = B - A, D - C
    den = _cross(r, u)
    s = _cross(C - A, u) / den
    t = _cross(C - A, r) / den
    X = A + s * r
    v = zeros(2np)
    for k = 1:np
        idx = (2k - 1):(2k)
        dA, dB = arr.velocities[a][idx], arr.velocities[b][idx]
        dC, dD = arr.velocities[c][idx], arr.velocities[d][idx]
        # Differentiate A + s (B - A) = C + t (D - C) with respect to the parameter.
        rhs = dC .+ t .* (dD .- dC) .- dA .- s .* (dB .- dA)
        ds = _cross(rhs, u) / den
        v[idx] .= dA .+ ds .* r .+ s .* (dB .- dA)
    end
    x = _add_point!(arr, X, v)
    push!(splits[s1], (s, x))
    push!(splits[s2], (t, x))
    return
end

# The parameter of `E` on the interior of segment PQ, or nothing.
function _on_segment(E, P, Q)
    d = Q - P
    L2 = d[1]^2 + d[2]^2
    t = ((E - P)[1] * d[1] + (E - P)[2] * d[2]) / L2
    (0 < t < 1) || return nothing
    abs(_cross(E - P, d)) / sqrt(L2) <= VELOCITY_MERGE_ATOL || return nothing
    return t
end

function _plane_velocity(base, vel, z, win, triangle_size, min_angle)
    np = length(vel)
    arr = _arrangement(base, vel, z, win)
    xmin, xmax, ymin, ymax = win
    # The window boundary, counterclockwise, through every arrangement point on it.
    zero2 = zeros(2np)
    for p in ((xmin, ymin), (xmax, ymin), (xmax, ymax), (xmin, ymax))
        _add_point!(arr, SVector(p...), zero2)
    end
    along_boundary(p) =
        abs(p[2] - ymin) <= VELOCITY_MERGE_ATOL ? (p[1] - xmin) :
        abs(p[1] - xmax) <= VELOCITY_MERGE_ATOL ? (xmax - xmin) + (p[2] - ymin) :
        abs(p[2] - ymax) <= VELOCITY_MERGE_ATOL ?
        2(xmax - xmin) + (ymax - ymin) - (p[1] - xmin) :
        2(xmax - xmin) + 2(ymax - ymin) - (p[2] - ymin)
    onboundary =
        [i for i in eachindex(arr.points) if _on_window_boundary(win, arr.points[i])]
    sort!(onboundary, by=i -> along_boundary(arr.points[i]))
    boundary_nodes = vcat(onboundary, onboundary[1])
    isboundary = falses(length(arr.points))
    isboundary[onboundary] .= true
    interior = Set(
        (i, j) for (i, j) in arr.segments if !(
            isboundary[i] && isboundary[j] && _same_side(win, arr.points[i], arr.points[j])
        )
    )
    rng = Random.Xoshiro(20250101)
    tri = DelaunayTriangulation.triangulate(
        [(p[1], p[2]) for p in arr.points];
        boundary_nodes=boundary_nodes,
        segments=interior,
        rng=rng
    )
    h =
        isnothing(triangle_size) ? max(xmax - xmin, ymax - ymin) / 40 :
        _stp_float(triangle_size)
    DelaunayTriangulation.refine!(
        tri;
        min_angle=_degrees(min_angle),
        max_area=sqrt(3) / 4 * h^2,
        rng=rng
    )
    return _harmonic_fields(tri, arr, np)
end

_degrees(θ::Real) = Float64(θ)
_degrees(θ) = Float64(ustrip(°, θ))

_same_side(win, p, q) = any(
    abs(p[c] - w) <= VELOCITY_MERGE_ATOL && abs(q[c] - w) <= VELOCITY_MERGE_ATOL for
    (c, w) in ((1, win[1]), (1, win[2]), (2, win[3]), (2, win[4]))
)

# Harmonic interpolation of the arrangement's velocities on the refined triangulation: the
# velocities at points on constrained edges and the window boundary, P1 harmonic elsewhere.
function _harmonic_fields(tri, arr::_Arrangement, np)
    DT = DelaunayTriangulation
    n = DT.num_points(tri)
    n0 = length(arr.points)
    pts = zeros(2, n)
    for i = 1:n
        p = DT.get_point(tri, i)
        pts[1, i], pts[2, i] = p[1], p[2]
    end
    values = zeros(2np, n)
    dirichlet = falses(n)
    for i = 1:n0
        values[:, i] .= arr.velocities[i]
        dirichlet[i] = true
    end
    # Steiner points on the window boundary, where the field vanishes.
    for i = (n0 + 1):n
        dirichlet[i] = _on_window_boundary(arr.window, SVector(pts[1, i], pts[2, i]))
    end
    # Steiner points that refinement put on constrained edges take the edge's velocity.
    onsegment = Set{Int}()
    for (i, j) in DT.get_interior_segments(tri)
        i > n0 && push!(onsegment, i)
        j > n0 && push!(onsegment, j)
    end
    _interpolate_on_segments!(values, dirichlet, pts, onsegment, arr)
    triangles = Int32[]
    for T in DT.each_solid_triangle(tri)
        i, j, k = DT.triangle_vertices(T)
        append!(triangles, (i, j, k))
    end
    triangles = reshape(triangles, 3, :)
    used = falses(n)
    used[vec(triangles)] .= true
    dirichlet .|= .!used
    _solve_harmonic!(values, dirichlet, pts, triangles)
    mesh = _plane_mesh(arr.window, pts, triangles)
    return mesh, [values[(2k - 1):(2k), :] for k = 1:np]
end

function _interpolate_on_segments!(values, dirichlet, pts, onsegment, arr)
    isempty(onsegment) && return
    grid = _SegmentGrid(arr)
    for i in onsegment
        p = SVector(pts[1, i], pts[2, i])
        found = false
        for s in get(grid.cells, _cellindex(grid, p), Int[])
            a, b = arr.segments[s]
            t = _on_segment(p, arr.points[a], arr.points[b])
            isnothing(t) && continue
            values[:, i] .= (1 - t) .* arr.velocities[a] .+ t .* arr.velocities[b]
            dirichlet[i] = true
            found = true
            break
        end
        found || error("internal error: a refinement point is not on any constrained edge")
    end
end

function _solve_harmonic!(values, dirichlet, pts, triangles)
    n = size(pts, 2)
    I, J, K = Int[], Int[], Float64[]
    for t in axes(triangles, 2)
        v = view(triangles, :, t)
        x = SVector(pts[1, v[1]], pts[1, v[2]], pts[1, v[3]])
        y = SVector(pts[2, v[1]], pts[2, v[2]], pts[2, v[3]])
        area2 = (x[2] - x[1]) * (y[3] - y[1]) - (x[3] - x[1]) * (y[2] - y[1])
        # Gradients of the barycentric coordinates, times twice the area.
        gx = SVector(y[2] - y[3], y[3] - y[1], y[1] - y[2])
        gy = SVector(x[3] - x[2], x[1] - x[3], x[2] - x[1])
        for a = 1:3, b = 1:3
            push!(I, v[a])
            push!(J, v[b])
            push!(K, (gx[a] * gx[b] + gy[a] * gy[b]) / (2 * abs(area2)))
        end
    end
    A = SparseArrays.sparse(I, J, K, n, n)
    free = findall(.!dirichlet)
    isempty(free) && return values
    fixed = findall(dirichlet)
    Aff = A[free, free]
    rhs = -(A[free, fixed] * permutedims(values[:, fixed]))
    for c in axes(rhs, 2)
        values[c, free] .= _conjugate_gradient(Aff, rhs[:, c])
    end
    return values
end

# Jacobi-preconditioned conjugate gradients for the symmetric positive definite P1
# Laplacian. Iterative, in Julia, so that design velocities do not load a sparse direct
# solver library (whose OpenMP runtime can conflict with the one Gmsh is linked with).
function _conjugate_gradient(A, b; rtol=1e-13)
    x = zeros(length(b))
    nb = LinearAlgebra.norm(b)
    iszero(nb) && return x
    d = LinearAlgebra.diag(A)
    r = copy(b)
    z = r ./ d
    p = copy(z)
    rz = LinearAlgebra.dot(r, z)
    Ap = similar(b)
    for _ = 1:(10 * length(b))
        LinearAlgebra.mul!(Ap, A, p)
        α = rz / LinearAlgebra.dot(p, Ap)
        x .+= α .* p
        r .-= α .* Ap
        LinearAlgebra.norm(r) <= rtol * nb && return x
        z .= r ./ d
        rz, rzold = LinearAlgebra.dot(r, z), rz
        p .= z .+ (rz / rzold) .* p
    end
    return error("internal error: the in-plane harmonic interpolation did not converge")
end

function _plane_mesh(window, pts, triangles)
    xmin, xmax, ymin, ymax = window
    nt = size(triangles, 2)
    nc = max(1, round(Int, sqrt(nt / 2)))
    nx = max(1, round(Int, nc * sqrt((xmax - xmin) / (ymax - ymin))))
    ny = max(1, round(Int, nt / 2 / nx))
    cw, ch = (xmax - xmin) / nx, (ymax - ymin) / ny
    lists = [Int32[] for _ = 1:(nx * ny)]
    for t = 1:nt
        v = view(triangles, :, t)
        x0, x1 = extrema(pts[1, v])
        y0, y1 = extrema(pts[2, v])
        i0 = clamp(floor(Int, (x0 - xmin) / cw) + 1, 1, nx)
        i1 = clamp(floor(Int, (x1 - xmin) / cw) + 1, 1, nx)
        j0 = clamp(floor(Int, (y0 - ymin) / ch) + 1, 1, ny)
        j1 = clamp(floor(Int, (y1 - ymin) / ch) + 1, 1, ny)
        for j = j0:j1, i = i0:i1
            push!(lists[(j - 1) * nx + i], t)
        end
    end
    offsets = Int32[1]
    for l in lists
        push!(offsets, offsets[end] + length(l))
    end
    return _PlaneMesh(
        window,
        pts,
        triangles,
        (cw, ch),
        (nx, ny),
        offsets,
        reduce(vcat, lists; init=Int32[])
    )
end
