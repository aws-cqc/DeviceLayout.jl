using IntervalTrees

"""
    render!(c::Cell, p::Polygon, meta::GDSMeta=GDSMeta())

Render a polygon `p` to cell `c`, defaulting to plain styling.
If `p` has more than 8190 (set by DeviceLayout's `GDS_POLYGON_MAX` constant),
then it is partitioned into smaller polygons which are then rendered.
Environment variable `ENV["GDS_POLYGON_MAX"]` will override this constant.
The partitioning algorithm implements guillotine cutting, that goes through
at least one existing vertex and in manhattan directions.
Cuts are selected by ad hoc optimization for "nice" partitions.
"""
function render!(c::Cell{S}, p::Polygon, meta::GDSMeta=GDSMeta(); kwargs...) where {S}
    if length(points(p)) <= (
        haskey(ENV, "GDS_POLYGON_MAX") ? parse(Int, ENV["GDS_POLYGON_MAX"]) :
        GDS_POLYGON_MAX
    )
        push!(c.elements, p)
        push!(c.element_metadata, meta)
        return c
    end

    # for determinism
    rng = MersenneTwister(1234)

    # idea will be to make a cut that balances the number of line segments
    # on one side of the cut or the other. should be cheaper than clipping.

    T = eltype(eltype(points(p)))
    xtree = IntervalTree{T, IntervalValue{T, Int}}()
    ytree = IntervalTree{T, IntervalValue{T, Int}}()
    lsview = Polygons.LineSegmentView(points(p))
    for i in eachindex(lsview)
        push!(xtree, IntervalValue(Polygons.xinterval(lsview[i])..., i))
        push!(ytree, IntervalValue(Polygons.yinterval(lsview[i])..., i))
    end

    b = bounds(p)
    bestclip = b
    bestscore = typemax(Int)
    for _ = 1:200
        x1 = getx(points(p)[rand(rng, 1:end)])
        clipPoly = Rectangle(lowerleft(b), Point(x1, upperright(b).y))
        left, right = Interval(b.ll.x, x1), Interval(x1, b.ur.x)
        nleft = nright = 0
        for i in intersect(xtree, left)
            nleft += 1
        end
        for _ in intersect(xtree, right)
            nright += 1
        end
        score = abs(nleft - nright)
        if bestscore > score
            bestscore = score
            bestclip = clipPoly
        end
    end
    for _ = 1:200
        y1 = gety(points(p)[rand(rng, 1:end)])
        clipPoly = Rectangle(lowerleft(b), Point(upperright(b).x, y1))
        left, right = Interval(b.ll.y, y1), Interval(y1, b.ur.y)
        nleft = nright = 0
        for i in intersect(ytree, left)
            nleft += 1
        end
        for _ in intersect(ytree, right)
            nright += 1
        end
        score = abs(nleft - nright)
        if bestscore > score
            bestscore = score
            bestclip = clipPoly
        end
    end

    for q in [
        clip(Clipper.ClipTypeIntersection, p, bestclip)
        clip(Clipper.ClipTypeDifference, p, bestclip)
    ]
        render!(c, q, meta)
    end
    return c
end

"""
    render!(c::CoordinateSystem, ent, meta)

Synonym for [`place!`](@ref).
"""
render!(cs::CoordinateSystem, r::GeometryEntity, meta::Meta; kwargs...) =
    place!(cs, r, meta; kwargs...)
render!(cs::CoordinateSystem, r::Vector, meta::Vector; kwargs...) =
    place!(cs, r, meta; kwargs...)
