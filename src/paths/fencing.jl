"""
    fence!(pa::Path, post::GeometryReference, offsets, pitch;
        side=:both, start=zero(T), stop=pathlength(pa), margin=zero(T))

Attach `post` alongside `pa` in rows ("fences"), spaced by `pitch` along each row.

Each element of `offsets` (a single `Coordinate` or a collection of them) is the nonnegative
distance of a row outward from the edge of the rendered path, as given by the extent of its
style. `side` may be `:left`, `:right`, or `:both`. Each offset gives one row on each
selected side. Because rows follow the extent, a row jumps sideways wherever the extent
changes abruptly, as at a change of style between segments. The spacing across such a jump
is measured along the row on either side of it, not across the gap.

`pitch` is measured along the row itself rather than along the path. This is the difference
from attaching at regularly spaced positions with [`attach!`](@ref): on curves, a row on the
inside of a turn does not become crowded, and a row on the outside does not become sparse. As
a result, rows on opposite sides of a curved path do not stay abreast of each other.

Each row has its first post at `start` and continues up to `stop`, both measured as
pathlength along `pa`. `margin` keeps posts at least that far from both ends of `pa`. The
spacing carries over from one path segment to the next. A post that falls exactly where one
segment ends, including the first post of a row that starts there, goes on the next
segment's row. If that row doesn't exist at the start of the next segment (see below), a
post that falls due there stays at the end of the segment instead.

If a row on the inside of a turn would lie at or past the turn's center of curvature, it has
no length there. No posts are placed on it there, and a warning is issued.

As with `attach!`, the origin of `post` is relative to a coordinate system that rotates with
the path. Here, that coordinate system's origin is on the row. Each row attaches its own copy of
the reference `post`, so later changes to the reference itself, such as its origin, are not
reflected in the attachments. The referenced structure is shared. Also as with `attach!`,
posts are positioned by pathlength. Their positions are not recomputed if `pa` is modified
later.

Returns the points on the rows where posts were attached, in the coordinate system of `pa`:
for each offset in turn, the points of its left row and then of its right row, each in order
of pathlength. The return value is experimental: it may change in a minor release, for
example to records that also give each post's row and node.

Throws an `ArgumentError` if `pa` has a node anywhere along it that `fence!` does not
support, even outside the window from `start` to `stop`:

  - A generic [`Paths.Taper`](@ref) style. Its extent depends on its neighbors, so replace it
    with an explicit `Paths.TaperTrace` or `Paths.TaperCPW` first.
  - A `Paths.Corner`. Rows on the inside of a sharp corner would overlap the path and each
    other, so use [`turn!`](@ref) with a radius larger than each row's distance from the
    centerline instead.

Every segment of `pa` must implement `Paths.curvatureradius`.
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
    for (i, node) in enumerate(nodes(pa))
        reason = _fence_unsupported(segment(node), undecorated(style(node)))
        isnothing(reason) || throw(ArgumentError("Node $i of path \"$(name(pa))\" $reason"))
    end
    pitch = convert(T, pitch)
    post = convert(GeometryReference{T}, post)
    s0 = convert(T, max(start, margin))
    s1 = convert(T, min(stop, pathlength(pa) - margin))
    sides = side == :left ? (1,) : side == :right ? (-1,) : (1, -1)
    rows = [(convert(T, o), σ) for o in offsets for σ in sides]
    for (o, _) in rows
        o >= zero(T) || throw(
            ArgumentError(
                "Fence offsets must be nonnegative distances from the edge; got $o."
            )
        )
    end
    # `attach!` replaces nodes of `pa` and reconciles it, so find every row's posts before
    # attaching any, rather than while `_fence_row` iterates over the nodes
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

# Why `fence!` can't place rows along a node with segment `seg` and undecorated style `sty`,
# or `nothing` if it can
function _fence_unsupported(seg, sty)
    sty isa Taper && return """
        has a generic `Paths.Taper()` style, which `fence!` does not support. Replace it \
        with an explicit `Paths.TaperTrace` or `Paths.TaperCPW`, such as \
        `Paths.TaperCPW(style_before, style_after)`."""
    seg isa Corner && return """
        is a `Paths.Corner`, which `fence!` does not support: rows on the inside of a sharp \
        corner would overlap the path and each other. Use `turn!` with a radius larger than \
        each row's distance from the centerline instead."""
    return nothing
end

# Posts for one row at distance `o` outside the extent edge on side `σ` (+1 left, -1 right),
# as (node index, pathlength within node, row point) with uniform spacing along the row.
function _fence_row(pa::Path{T}, o::T, σ, pitch::T, s0::T, s1::T) where {T}
    posts = Tuple{Int, T, Point{T}}[]
    degenerate_nodes = Int[]
    tol = sqrt(eps(Float64)) * pitch
    need = zero(T) # Length along the row still to go before the next post
    l0 = zero(T) # Pathlength of `pa` before the current node
    # Last node with a row; zero-length nodes have none
    i_last = something(findlast(n -> !iszero(pathlength(segment(n))), nodes(pa)), 0)
    for (i, node) in enumerate(nodes(pa))
        seg, sty = segment(node), style(node)
        len = pathlength(seg)
        a, b = max(s0 - l0, zero(T)), min(s1 - l0, len)
        l0 += len
        # A window starting exactly at the end of a node starts on the next node's row, as
        # in a `CompoundStyle`, so that `simplify!` doesn't move posts
        (iszero(len) || a > b || (a == len && i < i_last)) && continue
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
            # Likewise, a post due exactly at the end of a node goes on the next node's row. If
            # that row doesn't exist at its start, the post stays here, as after `simplify!`,
            # rather than moving to wherever the row resumes or being dropped if it doesn't.
            if s_next == len && i < i_last && _row_starts_after(pa, i, o, σ)
                need = zero(T)
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

# Whether the row at distance `o` outside the extent edge on side `σ` exists at the start of
# the first node with length after node `i`
function _row_starts_after(pa::Path{T}, i, o, σ) where {T}
    node = nodes(pa)[findnext(n -> !iszero(pathlength(segment(n))), nodes(pa), i + 1)]
    d = σ * (extent(style(node), zero(T)) + o)
    return _row_tangential_speed(segment(node), d, zero(T)) > 0
end

# Speed of the row point γ(t) + σ ℓ(t) n(t) with respect to pathlength t along the segment,
# or zero where the row lies at or past the center of curvature (it would run backward)
function _row_speed(seg, ℓ, σ, t, degenerate)
    a = _row_tangential_speed(seg, σ * ℓ(t), t)
    if a <= 0
        degenerate[] = true
        return 0.0
    end
    dℓ = uconvert(NoUnits, ForwardDiff.derivative(ℓ, t))
    return sqrt(a^2 + dℓ^2)
end

# Speed along the segment's direction of the point at signed distance `d` to the left of
# `seg(t)`, with respect to `t`
_row_tangential_speed(seg, d, t) = 1 - uconvert(NoUnits, d * signed_curvature(seg, t))
# Offset segments are parameterized by the pathlength of the curve they offset rather than by
# their own, and `curvatureradius` is only approximate for some of them, so differentiate
# their direction instead
function _row_tangential_speed(seg::OffsetSegment, d, t)
    dα = ForwardDiff.derivative(s -> direction(seg, s), t)
    return norm(tangent(seg, t)) - uconvert(NoUnits, d * dα)
end
# Compound segments can contain offset segments, at any depth after repeated `simplify!`
function _row_tangential_speed(seg::CompoundSegment, d, t)
    sub, t_sub = subsegment(seg, t)
    return _row_tangential_speed(sub, d, t_sub)
end

# Pathlength in [s, b] after which the row has advanced by `need` beyond the row point at `s`,
# along with `need`; or `nothing` and the distance traveled along the row up to `b`
function _advance_along_row(v, s, b, need, tol)
    if need <= tol
        v(s) > 0 && return s, need
        # The row doesn't exist at `s`, so the post goes where it begins (within `3tol`
        # along it), and the row stays without posts if it doesn't begin before `b`
        x, _ = _advance_along_row(v, s, b, 2tol, tol)
        return x, isnothing(x) ? zero(need) : need
    end
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
