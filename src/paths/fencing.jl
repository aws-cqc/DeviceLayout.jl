"""
    fence!(pa::Path, post::GeometryReference, offsets, pitch;
        side=:both, start=zero(T), stop=pathlength(pa), margin=zero(T))

Attach `post` alongside `pa` in rows ("fences"), spaced by `pitch` along each row.

Each element of `offsets` (a single `Coordinate` or a collection of them) is the distance of
a row outward from the edge of the rendered path, as given by the extent of its style.
`side` may be `:left`, `:right`, or `:both`. Each offset gives one row on each selected side.

`pitch` is measured along the row itself rather than along the path. This is the difference
from attaching at regularly spaced positions with [`attach!`](@ref): on curves, a row on the
inside of a turn does not become crowded, and a row on the outside does not become sparse. As
a result, rows on opposite sides of a curved path do not stay abreast of each other.

Each row has its first post at `start` and continues up to `stop`, both measured as
pathlength along `pa`. `margin` keeps posts at least that far from both ends of `pa`. The
spacing carries over from one path segment to the next. `Corner`s have no length and get no
posts.

If a row on the inside of a turn would lie at or past the turn's center of curvature, it has
no length there. No posts are placed on it there, and a warning is issued.

As with `attach!`, the origin of `post` is relative to a coordinate system that rotates with
the path. Here, that coordinate system's origin is on the row. Each row attaches its own copy of
`post`, so later changes to `post` are not reflected in the attachments. Also as with `attach!`,
posts are positioned by pathlength. Their positions are not recomputed if `pa` is modified
later.

Returns the points on the rows where posts were attached, in the coordinate system of `pa`.
"""
function fence!(
    pa::Path{T},
    post::GeometryReference,
    offsets,
    pitch::Coordinate;
    side::Symbol=:both,
    start::Coordinate=zero(T),
    stop::Coordinate=pathlength(pa),
    margin::Coordinate=zero(T)
) where {T}
    side in (:left, :right, :both) ||
        throw(ArgumentError("`side` must be `:left`, `:right`, or `:both`; got `:$side`."))
    pitch > zero(pitch) || throw(ArgumentError("`pitch` must be positive; got $pitch."))
    pitch = convert(T, pitch)
    post = convert(GeometryReference{T}, post)
    s0 = convert(T, max(start, margin))
    s1 = convert(T, min(stop, pathlength(pa) - margin))
    sides = side == :left ? (1,) : side == :right ? (-1,) : (1, -1)
    rows = [(convert(T, o), σ) for o in offsets for σ in sides]
    # Compute every row before attaching anything, so that no row sees another's attachments
    row_posts = [_fence_row(pa, o, σ, pitch, s0, s1) for (o, σ) in rows]

    points = Point{T}[]
    for ((o, σ), posts) in zip(rows, row_posts)
        row_post = transform(post, Translation(Point(zero(T), σ * o)))
        for (i, t, pt) in posts
            # Measured from the edge of the style's extent on the row's side
            attach!(pa, row_post, t; i=i, location=(σ > 0 ? :left : :right))
            push!(points, pt)
        end
    end
    return points
end

# Posts for one row at distance `o` outside the extent edge on side `σ` (+1 left, -1 right),
# as (node index, pathlength within node, row point) with uniform spacing along the row.
function _fence_row(pa::Path{T}, o::T, σ, pitch::T, s0::T, s1::T) where {T}
    posts = Tuple{Int, T, Point{T}}[]
    degenerate_nodes = Int[]
    tol = sqrt(eps(Float64)) * pitch
    need = zero(T) # Length along the row still to go before the next post
    l0 = zero(T) # Pathlength of `pa` before the current node
    for (i, node) in enumerate(nodes(pa))
        seg, sty = segment(node), style(node)
        len = pathlength(seg)
        a, b = max(s0 - l0, zero(T)), min(s1 - l0, len)
        l0 += len
        (iszero(len) || a > b) && continue
        ℓ = t -> extent(sty, t) + o
        degenerate = Ref(false)
        v = t -> _row_speed(seg, ℓ, σ, t, degenerate)
        s = a
        while true
            s_next, traveled = _advance_along_row(v, s, b, need, tol)
            if isnothing(s_next)
                need -= traveled
                break
            end
            dir = direction(seg, s_next)
            pt = seg(s_next) + σ * ℓ(s_next) * Point(-sin(dir), cos(dir))
            push!(posts, (i, s_next, pt))
            s = s_next
            need = pitch
        end
        degenerate[] && push!(degenerate_nodes, i)
    end
    isempty(degenerate_nodes) || @warn """
        The fence row $o outside the $(σ > 0 ? "left" : "right") edge of path \
        "$(name(pa))" lies at or past the center of curvature of node(s) \
        $degenerate_nodes. No posts are placed there.
        """
    return posts
end

# Speed of the row point γ(t) + σ ℓ(t) n(t) with respect to pathlength t along the segment,
# or zero where the row lies at or past the center of curvature (it would run backward)
function _row_speed(seg, ℓ, σ, t, degenerate)
    a = 1 - σ * uconvert(NoUnits, ℓ(t) * signed_curvature(seg, t))
    if a <= 0
        degenerate[] = true
        return 0.0
    end
    dℓ = uconvert(NoUnits, ForwardDiff.derivative(ℓ, t))
    return sqrt(a^2 + dℓ^2)
end

# Pathlength in [s, b] after which the row has advanced by `need` beyond the row point at `s`,
# along with `need`; or `nothing` and the distance traveled along the row up to `b`
function _advance_along_row(v, s, b, need, tol)
    need <= tol && return s, need
    # Bracket the solution locally, so the cost per post doesn't grow with segment length
    h = need
    hi, total = s, zero(need)
    while true
        hi = min(s + h, b)
        total = quadgk(v, s, hi)[1]
        (total >= need - tol || hi == b) && break
        h *= 2
    end
    total < need - tol && return nothing, total
    hi == b && total <= need + tol && return b, need
    # Safeguarded Newton iteration on ∫_s^x v = need (exact in one step for constant speed)
    lo = s
    vs = v(s)
    x = vs > 0 ? min(s + need / vs, hi) : (lo + hi) / 2
    for _ = 1:100
        f = quadgk(v, s, x)[1] - need
        abs(f) <= tol && break
        f < zero(f) ? (lo = x) : (hi = x)
        vx = v(x)
        x_newton = vx > 0 ? x - f / vx : x
        x = lo < x_newton < hi ? x_newton : (lo + hi) / 2
    end
    return x, need
end
