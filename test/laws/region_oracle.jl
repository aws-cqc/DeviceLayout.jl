# Kernel-independent certificates for continuous regions with lattice vertices.
# Rational slab boundaries include every vertex and edge crossing, so membership is
# constant in each open trapezoid. Closing those trapezoids also covers their seams.
const Exact = Rational{BigInt}
const ExactPt = Tuple{Exact, Exact}
exact_point(p) = (Exact(p[1]), Exact(p[2]))
midpoint(a, b) = ((a[1] + b[1]) / 2, (a[2] + b[2]) / 2)
cross2(a, b) = a[1] * b[2] - a[2] * b[1]
sub2(a, b) = (a[1] - b[1], a[2] - b[2])
dot2(a, b) = a[1] * b[1] + a[2] * b[2]

function distance2(q, a, b)
    d, u = sub2(b, a), sub2(q, a)
    l = dot2(d, d)
    t = iszero(l) ? zero(l) : clamp(dot2(u, d) / l, 0, 1)
    r = (u[1] - t * d[1], u[2] - t * d[2])
    return dot2(r, r)
end

function exact_edges(regions...)
    return [
        (exact_point(v[i]), exact_point(v[mod1(i + 1, end)]), k) for
        (k, region) in enumerate(regions) for v in region for
        i in eachindex(v) if v[i] != v[mod1(i + 1, end)]
    ]
end

# Nonparallel intersection parameters; collinear overlap endpoints are already events.
function crossing_parameters(a, b, c, d)
    u, v, w = sub2(b, a), sub2(d, c), sub2(c, a)
    den = cross2(u, v)
    iszero(den) && return nothing
    t, s = cross2(w, v) / den, cross2(w, u) / den
    return 0 <= t <= 1 && 0 <= s <= 1 ? (t, s) : nothing
end

function boxes_overlap(a, b, c, d)
    return all(
        k -> max(min(a[k], b[k]), min(c[k], d[k])) <= min(max(a[k], b[k]), max(c[k], d[k])),
        1:2
    )
end

spend!(remaining, n=1) = (remaining[] -= n; remaining[] >= 0)

# Cancel parity-neutral seams and doubled bridges before using edges as tolerance
# capsules. Collinear overlaps must first be split at both sets of endpoints; merely
# deduplicating whole edges would make the verdict depend on contour decomposition.
function boundary_edges(edges, work)
    cuts = [Exact[0, 1] for _ in edges]
    for i in eachindex(edges), j = (i + 1):length(edges)
        spend!(work) || return nothing
        a, b, _ = edges[i]
        c, d, _ = edges[j]
        boxes_overlap(a, b, c, d) || continue
        u, v = sub2(b, a), sub2(d, c)
        iszero(cross2(u, v)) && iszero(cross2(u, sub2(c, a))) || continue
        k = iszero(u[1]) ? 2 : 1
        for p in (c, d)
            t = (p[k] - a[k]) / u[k]
            0 <= t <= 1 && push!(cuts[i], t)
        end
        for p in (a, b)
            t = (p[k] - c[k]) / v[k]
            0 <= t <= 1 && push!(cuts[j], t)
        end
    end
    atoms = Dict{Tuple{ExactPt, ExactPt}, UInt8}()
    for (edge, ts) in zip(edges, cuts)
        a, b, k = edge
        sort!(unique!(ts))
        for i = 1:(length(ts) - 1)
            spend!(work) || return nothing
            p = (a[1] + ts[i] * (b[1] - a[1]), a[2] + ts[i] * (b[2] - a[2]))
            q = (a[1] + ts[i + 1] * (b[1] - a[1]), a[2] + ts[i + 1] * (b[2] - a[2]))
            key = minmax(p, q)
            atoms[key] = get(atoms, key, 0x00) ⊻ (0x01 << (k - 1))
        end
    end
    return sort!([(a, b, mask) for ((a, b), mask) in atoms if !iszero(mask)])
end

function slab_events(edges, work)
    xs = Exact[p[1] for (a, b, _) in edges for p in (a, b)]
    for i in eachindex(edges), j = (i + 1):length(edges)
        spend!(work) || return nothing
        a, b, _ = edges[i]
        c, d, _ = edges[j]
        boxes_overlap(a, b, c, d) || continue
        ts = crossing_parameters(a, b, c, d)
        isnothing(ts) && continue
        push!(xs, a[1] + ts[1] * (b[1] - a[1]))
    end
    return sort!(unique!(xs))
end
height_at(edge, x) =
    edge[1][2] + (x - edge[1][1]) * (edge[2][2] - edge[1][2]) / (edge[2][1] - edge[1][1])

# A capsule (segment plus a closed radius-r disk) is convex. If it contains every
# vertex of a convex cell, it contains the entire cell. Different capsules covering
# different vertices do NOT suffice; subdivision either proves coverage, finds a
# counterexample, or explicitly exhausts its budget without claiming equality.
function cover_triangle(tri, edges, r², remaining, depth=0)
    spend!(remaining, 1 + length(edges)) || return (false, :inconclusive)
    for (a, b, _) in edges
        all(q -> distance2(q, a, b) <= r², tri) && return (true, nothing)
    end
    q = ((tri[1][1] + tri[2][1] + tri[3][1]) / 3, (tri[1][2] + tri[2][2] + tri[3][2]) / 3)
    any(e -> distance2(q, e[1], e[2]) <= r², edges) || return (false, (:membership, q))
    depth >= 64 && return (false, :inconclusive)
    # Bisect the longest edge to reduce aspect ratio as well as diameter.
    i = argmax([
        dot2(sub2(tri[j], tri[mod1(j + 1, 3)]), sub2(tri[j], tri[mod1(j + 1, 3)])) for
        j = 1:3
    ])
    a, b, c = tri[i], tri[mod1(i + 1, 3)], tri[mod1(i + 2, 3)]
    m = midpoint(a, b)
    for child in ((a, m, c), (m, b, c))
        result = cover_triangle(child, edges, r², remaining, depth + 1)
        first(result) || return result
    end
    return (true, nothing)
end

function region_certificate(
    X::GridRegion,
    Y::GridRegion,
    tol::Integer;
    subset=false,
    max_work=1_000_000
)
    tol >= 0 || throw(ArgumentError("region tolerance must be nonnegative"))
    nvertices(X) + nvertices(Y) <= MAX_VERTICES || return (false, :too_many_vertices)
    canonical_region(X) == canonical_region(Y) && return (true, nothing)
    remaining = Ref(max_work)
    edges = boundary_edges(exact_edges(X, Y), remaining)
    isnothing(edges) && return (false, :inconclusive)
    xs = slab_events(edges, remaining)
    isnothing(xs) && return (false, :inconclusive)
    r² = BigInt(tol)^2
    for i = 1:(length(xs) - 1)
        spend!(remaining, 1 + length(edges)) || return (false, :inconclusive)
        lo, hi = xs[i], xs[i + 1]
        x = (lo + hi) / 2
        active = [(height_at(e, x), e) for e in edges if e[1][1] < x < e[2][1]]
        sort!(active; by=first)
        inside = [false, false]
        for j = 1:(length(active) - 1)
            (y, e), (z, f) = active[j], active[j + 1]
            inside[1] ⊻= !iszero(e[3] & 0x01)
            inside[2] ⊻= !iszero(e[3] & 0x02)
            y == z && continue
            (subset ? inside[1] && !inside[2] : inside[1] != inside[2]) || continue
            tol == 0 && return (false, (:membership, (x, (y + z) / 2)))
            a, b = (lo, height_at(e, lo)), (hi, height_at(e, hi))
            c, d = (hi, height_at(f, hi)), (lo, height_at(f, lo))
            # Bisect across the narrow direction first: on the fm lattice a rounding
            # sliver can be 1e11 times longer than it is wide. Longest-edge recursion
            # alone spends its depth budget before separating the two boundary bands.
            l, r = midpoint(a, d), midpoint(b, c)
            for tri in ((a, b, r), (a, r, l), (l, r, c), (l, c, d))
                iszero(cross2(sub2(tri[2], tri[1]), sub2(tri[3], tri[1]))) && continue
                result = cover_triangle(tri, edges, r², remaining)
                first(result) || return result
            end
        end
    end
    return (true, nothing)
end

# For strict containment, even a tangent contact is forbidden. For weak containment,
# split each child edge at all parent contacts and test every open subsegment. Merely
# checking vertices misses excursions through a concave parent and through pinches.
function contour_contained(child::Vector{GridPt}, parent::Vector{GridPt}; strict=false)
    for q in child
        m = point_in_polygon_exact(q, parent)
        (m === false || (strict && ismissing(m))) && return false
    end
    for i in eachindex(child)
        a, b = exact_point(child[i]), exact_point(child[mod1(i + 1, end)])
        ts = Exact[0, 1]
        for j in eachindex(parent)
            c, d = exact_point(parent[j]), exact_point(parent[mod1(j + 1, end)])
            boxes_overlap(a, b, c, d) || continue
            params = crossing_parameters(a, b, c, d)
            if !isnothing(params)
                strict && return false
                push!(ts, params[1])
            elseif iszero(cross2(sub2(b, a), sub2(c, a)))
                strict && return false
                k = a[1] == b[1] ? 2 : 1
                for p in (c, d)
                    a[k] == b[k] && continue
                    t = (p[k] - a[k]) / (b[k] - a[k])
                    0 <= t <= 1 && push!(ts, t)
                end
            end
        end
        sort!(unique!(ts))
        for j = 1:(length(ts) - 1)
            t = (ts[j] + ts[j + 1]) / 2
            q = (a[1] + t * (b[1] - a[1]), a[2] + t * (b[2] - a[2]))
            point_in_polygon_rational(q, parent) === false && return false
        end
    end
    return true
end

function downward_attachment(q::GridPt, parent::Vector{GridPt})
    ys = Exact[]
    for i in eachindex(parent)
        a, b = exact_point(parent[i]), exact_point(parent[mod1(i + 1, end)])
        min(a[1], b[1]) <= q[1] <= max(a[1], b[1]) || continue
        if a[1] == b[1]
            min(a[2], b[2]) <= q[2] && push!(ys, min(Exact(q[2]), max(a[2], b[2])))
        else
            y = a[2] + (q[1] - a[1]) * (b[2] - a[2]) / (b[1] - a[1])
            y <= q[2] && push!(ys, y)
        end
    end
    return isempty(ys) ? nothing : (q[1], round(Int128, maximum(ys)))
end

function point_in_polygon_rational(q::ExactPt, v::Vector{GridPt})
    inside = false
    for i in eachindex(v)
        a, b = exact_point(v[i]), exact_point(v[mod1(i + 1, end)])
        o = cross2(sub2(b, a), sub2(q, a))
        iszero(o) &&
            all(k -> min(a[k], b[k]) <= q[k] <= max(a[k], b[k]), 1:2) &&
            return missing
        if (a[2] > q[2]) != (b[2] > q[2])
            (b[2] > a[2] ? o : -o) > 0 && (inside = !inside)
        end
    end
    return inside
end

function segment_distance2(a, b, c, d)
    !isnothing(crossing_parameters(a, b, c, d)) && return Exact(0)
    return min(
        distance2(a, c, d),
        distance2(b, c, d),
        distance2(c, a, b),
        distance2(d, a, b)
    )
end

function cover_segment(a, b, edges, r², remaining, depth=0)
    spend!(remaining, 1 + length(edges)) || return false
    any(e -> distance2(a, e[1], e[2]) <= r² && distance2(b, e[1], e[2]) <= r², edges) &&
        return true
    m = midpoint(a, b)
    any(e -> distance2(m, e[1], e[2]) <= r², edges) || return false
    depth >= 32 && return false
    return cover_segment(a, m, edges, r², remaining, depth + 1) &&
           cover_segment(m, b, edges, r², remaining, depth + 1)
end

function is_convex_exact(v::Vector{GridPt})
    return is_simple_exact(v) && all(
        i -> orient_exact(v[mod1(i - 1, end)], v[i], v[mod1(i + 1, end)]) >= 0,
        eachindex(v)
    )
end

# For a convex source and q outside it, distance to the positive round-offset
# boundary is |dist(q,A) - δ|: the outward projection ray realizes the Lipschitz
# lower bound. This identity is false where nonconvex offset fronts merge, so O8
# explicitly uses convex inputs. O3 retains general inputs and negative offsets.
function round_chords_within(A::Polygon, out, δ::Integer, tol::Integer)
    δ > tol >= 0 || throw(ArgumentError("O8 requires δ > tol ≥ 0"))
    gA, gO = togrid(A), togrid(out)
    is_convex_exact(gA) || throw(ArgumentError("O8 requires a convex CCW source"))
    nvertices(gO) <= MAX_VERTICES || return false
    edges = exact_edges([gA])
    lo², hi² = BigInt(abs(δ) - tol)^2, BigInt(abs(δ) + tol)^2
    remaining = Ref(20_000)
    for (a, b, _) in exact_edges(gO)
        point_in_polygon_rational(midpoint(a, b), gA) === false || return false
        all(e -> segment_distance2(a, b, e[1], e[2]) >= lo², edges) || return false
        cover_segment(a, b, edges, hi², remaining) || return false
    end
    return true
end
