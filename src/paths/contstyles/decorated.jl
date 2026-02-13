abstract type AbstractDecoratedStyle <: ContinuousStyle{false} end

"""
    mutable struct DecoratedStyle{T<:FloatCoordinate} <: ContinuousStyle{false}
        s::Style
        ts::Vector{Float64}
        dirs::Vector{Int}
        refs::Vector{GeometryReference}
    end

Style with decorations, like structures periodically repeated along the path, etc.
"""
mutable struct DecoratedStyle{T <: FloatCoordinate} <: AbstractDecoratedStyle
    s::Style
    ts::Vector{T}
    dirs::Vector{Int}
    refs::Vector{GeometryReference}
end
summary(s::DecoratedStyle) = string(summary(s.s), " with ", length(s.refs), " decorations")

"""
    undecorated(s::DecoratedStyle)
    undecorated(s::Style)

Return the underlying, undecorated style if decorated; otherwise just return the style.
"""
undecorated(s::Style) = s
undecorated(s::AbstractDecoratedStyle) = undecorated(s.s)
without_attachments(s::Style) = s
without_attachments(s::DecoratedStyle) = s.s # Shallow and does not remove overlays
# Nodes: Undecorating invalidates linked list (caller can reconcile if necessary), but
# prev/next are still populated (!= n itself) so can still be used to check if node started/ended path
function undecorated(n::Node{T}) where {T}
    n_undec = Node{T}(n.seg, undecorated(n.sty), n.prev, n.next)
    n_undec.prev === n && (n_undec.prev = n_undec)
    n_undec.next === n && (n_undec.next = n_undec)
    return n_undec
end
# CompoundStyle: Undecorating doesn't invalidate pairing with CompoundSegment, so use the same tag
undecorated(s::CompoundStyle) =
    (typeof(s))(deepcopy(undecorated.(s.styles)), copy(s.grid), s.tag)

extent(s::AbstractDecoratedStyle, t...) = extent(undecorated(s), t...)

isvirtual(s::AbstractDecoratedStyle) = isvirtual(undecorated(s))

trace(s::AbstractDecoratedStyle, t...) = trace(undecorated(s), t...)

gap(s::AbstractDecoratedStyle, t...) = gap(undecorated(s), t...)

width(s::AbstractDecoratedStyle, t...) = width(undecorated(s), t...)

"""
    Base.copy(sty::DecoratedStyle)

A copy of `sty`, with shallow copies of attached references.
"""
Base.copy(sty::DecoratedStyle{T}) where {T} =
    DecoratedStyle{T}(deepcopy(sty.s), copy(sty.ts), copy(sty.dirs), copy(sty.refs))

"""
    attach!(p::Path, c::GeometryReference, t::Coordinate;
        i::Integer=length(p), location::Integer=0)
    attach!(p::Path, c::GeometryReference, t;
        i::Integer=length(p), location=zeros(Int, length(t)))

Attach `c` along a path. The second method permits ranges or arrays of `t` and `location`
to be specified (if the lengths do not match, `location` is cycled).

By default, the attachment(s) occur at `t ∈ [zero(pathlength(s)),pathlength(s)]` along the
most recent path segment `s`, but a different path segment index can be specified using `i`.
The reference is oriented with zero rotation if the path is pointing at 0°, otherwise it is
rotated with the path.

The origin of the cell reference tells the method where to place the cell *with
respect to a coordinate system that rotates with the path*. Suppose the path is
a straight line with angle 0°. Then an origin of `Point(0.,10.)` will put the
cell at 10 above the path, or 10 to the left of the path if it turns left by
90°.

The `location` option is for convenience. If `location == 0`, nothing special happens.
If `location == -1`, then the point of attachment for the reference is on the
leftmost edge of the waveguide (the rendered polygons; the path itself has no
width). Likewise if `location == 1`, the point of attachment is on the rightmost
edge. This option does not automatically rotate the cell reference, apart from
what is already done as described in the first paragraph. You can think of this
option as setting a special origin for the coordinate system that rotates with
the path. For instance, an origin for the cell reference of `Point(0.,10.)`
together with `location == -1` will put the cell at 10 above the edge of a
rendered (finite width) path with angle 0°.
"""
function attach!(
    p::Path{T},
    c::GeometryReference{T},
    t::Coordinate;
    i::Int=length(p),
    location::Int=0
) where {T}
    i == 0 && error("cannot attach to an empty path.")
    node = p[i]
    seg0, sty0 = segment(node), style(node)
    sty = decorate(sty0, coordinatetype(p), t, location, c)
    p[i] = Node(seg0, sty)
    return sty
end

function attach!(
    p::Path{T},
    c::GeometryReference{S},
    t::Coordinate;
    i::Int=length(p),
    location::Int=0
) where {S, T}
    return attach!(p, convert(GeometryReference{T}, c), t; i=i, location=location)
end

function attach!(
    p::Path,
    c::GeometryReference,
    t;
    i::Int=length(p),
    location=zeros(Int, length(t))
)
    for (ti, li) in zip(t, Iterators.cycle(location))
        attach!(p, c, ti; i=i, location=li)
    end
end

function transformation(p::Path, c::StructureReference)
    x = false
    for node in p.nodes
        if node.sty isa DecoratedStyle
            for (idx, ref) in enumerate(node.sty.refs)
                a = transformation(
                    node.seg,
                    node.sty.ts[idx],
                    ref,
                    node.sty,
                    node.sty.dirs[idx]
                )
                if ref === c
                    return a
                end
                x, y = transformation(structure(ref), c, a)
                x && return y
            end
        end
    end
    error("Reference tree does not contain $c.")
    return nothing
end

function transformation(
    segment::Segment,
    t,
    c::StructureReference,
    s::Paths.DecoratedStyle,
    dir
)
    rot = direction(segment, t)
    origin = Point(Rotation(rot)(c.origin)) + segment(t)
    if dir != 0
        rot2 = if dir == -1
            rot + 90.0°
        elseif dir == 1
            rot - 90.0°
        end
        offset = Paths.extent(s.s, t)
        dy, dx = offset .* sincos(rot2)
        origin += Point(dx, dy)
    end

    return ScaledIsometry(origin, rot + rotation(c), xrefl(c), mag(c))
end

# undocumented private methods for attach!
function decorate(sty0::Style, T, t, location, c)
    if !(-1 <= location <= 1)
        throw(ArgumentError("location must be >=-1 and <=1"))
    end
    return DecoratedStyle{T}(sty0, T[t], Int[location], GeometryReference[c])
end

function decorate(sty::DecoratedStyle, T, t, location, c)
    if !(-1 <= location <= 1)
        throw(ArgumentError("location must be >=-1 and <=1"))
    end
    push!(sty.ts, t)
    push!(sty.dirs, location)
    push!(sty.refs, c)
    return sty
end

function pin(sty::DecoratedStyle{T}; start=nothing, stop=nothing) where {T}
    x0 = ifelse(start === nothing, zero(T), start)
    x1 = ifelse(stop === nothing, maximum(sty.ts; init=zero(T)), stop)
    s = pin(sty.s; start=start, stop=stop)
    inds = findall(t -> t in x0 .. x1, sty.ts)
    ts = sty.ts[inds] .- x0
    dirs = sty.dirs[inds]
    refs = sty.refs[inds]
    return DecoratedStyle{T}(s, ts, dirs, refs)
end

"""
    undecorate!(sty, t)

Removes all attachments at position `t` from a style.
"""
function undecorate!(sty::DecoratedStyle, t)
    inds = findall(x -> x == t, sty.ts)
    deleteat!(sty.ts, inds)
    deleteat!(sty.dirs, inds)
    deleteat!(sty.refs, inds)
    return sty
end
undecorate!(sty::Style, t) = sty
# handling compound style is probably brittle if it has decorations inside

function _refs(segment::Paths.Segment{T}, s::DecoratedStyle) where {T}
    r = Vector{StructureReference{T}}(undef, length(s.refs))
    for (idx, t, dir, cref) in zip(eachindex(s.ts), s.ts, s.dirs, s.refs)
        (dir < -1 || dir > 1) && error("Invalid direction in $s.")
        a = transformation(segment, t, cref, s, dir)
        ref = sref(structure(cref), a)
        r[idx] = ref
    end
    return vcat(r, _refs(segment, s.s)) # vcat in case s.s is an overlay style and has more refs
end

function change_handedness!(s::DecoratedStyle)
    change_handedness!(s.s)
    s.dirs .= -s.dirs
    return s.refs .= XReflection().(s.refs)
end

"""
    mutable struct OverlayStyle{T<:FloatCoordinate} <: AbstractDecoratedStyle
        s::Style
        overlay::Vector{Style}
        overlay_metadata::Vector{DeviceLayout.Meta}
    end

Style supporting overlay styles with different metadata along the same segment.

See [`overlay!`](@ref).
"""
mutable struct OverlayStyle <: AbstractDecoratedStyle
    s::Style
    overlay::Vector{Style}
    overlay_metadata::Vector{DeviceLayout.Meta}
end
summary(s::OverlayStyle) = string(summary(s.s), " with ", length(s.overlay), " overlays")

Base.copy(sty::OverlayStyle) =
    OverlayStyle(deepcopy(sty.s), copy(sty.overlay), copy(sty.overlay_metadata))

function _refs(segment::Paths.Segment{T}, s::OverlayStyle) where {T}
    cs = DeviceLayout.CoordinateSystem{T}(uniquename("overlay"))
    for (oversty, meta) in zip(s.overlay, s.overlay_metadata)
        # Add dummy neighbors so halo doesn't append/prepend to it
        # Ideally we could track actual neighbors but that gets complicated
        dummy = Node{T}(Straight(zero(T)), NoRenderContinuous())
        DeviceLayout.place!(cs, Node{T}(segment, oversty, dummy, dummy), meta)
    end
    return vcat(_refs(segment, s.s), sref(cs))
end

function pin(sty::OverlayStyle; start=nothing, stop=nothing)
    return OverlayStyle(
        pin(sty.s; start, stop),
        pin.(sty.overlay; start, stop),
        sty.overlay_metadata
    )
end

function change_handedness!(s::OverlayStyle)
    change_handedness!(s.s)
    return change_handedness!.(s.overlay)
end
undecorate!(sty::OverlayStyle, t) = undecorate!(sty.s, t)

"""
    overlay!(path::Path, oversty::Style, metadata::DeviceLayout.Meta; i::Int=length(path))

Apply the style `oversty` in layer `metadata` on top of the segment at `path[i]`.

By default, the overlay is applied to the most recent segment.

Overlays generally count as "decorations". For example, they appear in `refs(path)` and not
`elements(path)`. They are removed by `undecorated(sty)`, and they are ignored when choosing
the default style for continuing a `Path` with methods like `straight!`.

Overlay styles should not be generic `Paths.Taper`s, since they can't see neighboring styles
to resolve the taper style.

You can use `overlay!` after `attach!`, in which case the overlay is applied to the style
underlying the `DecoratedStyle` that holds the attachments.
"""
function overlay!(
    path::Path,
    oversty::Style,
    metadata::DeviceLayout.Meta;
    i::Int=length(path)
)
    i == 0 && error("cannot overlay style on an empty path.")
    node = path[i]
    seg0, sty0 = segment(node), style(node)
    sty = _overlay!(sty0, oversty, metadata) # may modify decorated style or create new
    setstyle!(node, sty) # reconcile in case taper overlay needs a length
    return sty
end

function _overlay!(sty0::Style, oversty::Style, metadata::DeviceLayout.Meta)
    return OverlayStyle(sty0, [oversty], [metadata])
end

function _overlay!(sty0::OverlayStyle, oversty::Style, metadata::DeviceLayout.Meta)
    push!(sty0.overlay, oversty)
    push!(sty0.overlay_metadata, metadata)
    return sty0
end

function _overlay!(sty0::DecoratedStyle, oversty::Style, metadata::DeviceLayout.Meta)
    sty0.s = _overlay!(sty0.s, oversty, metadata)
    return sty0
end

function nextstyle(sty::OverlayStyle)
    return OverlayStyle(nextstyle(sty.s), nextstyle.(sty.overlay), sty.overlay_metadata)
end
