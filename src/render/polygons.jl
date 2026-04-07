using IntervalTrees

# Find a balanced guillotine cut rectangle from polygon contours.
# Samples random vertex-aligned cuts and scores by edge-count balance.
function _best_guillotine_cut(contours)
    rng = MersenneTwister(1234)
    allpoints = reduce(vcat, contours)
    T = eltype(eltype(allpoints))

    xtree = IntervalTree{T, IntervalValue{T, Int}}()
    ytree = IntervalTree{T, IntervalValue{T, Int}}()
    seg_idx = 0
    for pts in contours
        lsview = Polygons.LineSegmentView(pts)
        for i in eachindex(lsview)
            seg_idx += 1
            push!(xtree, IntervalValue(Polygons.xinterval(lsview[i])..., seg_idx))
            push!(ytree, IntervalValue(Polygons.yinterval(lsview[i])..., seg_idx))
        end
    end

    b = Rectangle(lowerleft(allpoints), upperright(allpoints))
    bestclip = b
    bestscore = typemax(Int)
    for _ = 1:200
        x1 = getx(allpoints[rand(rng, 1:length(allpoints))])
        clipPoly = Rectangle(lowerleft(b), Point(x1, upperright(b).y))
        left, right = Interval(b.ll.x, x1), Interval(x1, b.ur.x)
        nleft = nright = 0
        for _ in intersect(xtree, left)
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
        y1 = gety(allpoints[rand(rng, 1:length(allpoints))])
        clipPoly = Rectangle(lowerleft(b), Point(upperright(b).x, y1))
        left, right = Interval(b.ll.y, y1), Interval(y1, b.ur.y)
        nleft = nright = 0
        for _ in intersect(ytree, left)
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

    return bestclip
end

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
    # Reconstruct ClippedPolygon with topology info to make safe guillotine cuts
    render!(c, union2d(p), meta)
    return c
end

"""
    render!(c::Cell, cp::ClippedPolygon, meta::GDSMeta=GDSMeta())

Render a `ClippedPolygon`, applying guillotine cutting at the PolyNode level
to preserve hole topology. Only converts to keyhole polygons (via `interiorcuts`)
when sub-polygons are small enough to fit within `GDS_POLYGON_MAX`.
"""
function render!(
    c::Cell{S},
    cp::ClippedPolygon{T},
    meta::GDSMeta=GDSMeta();
    kwargs...
) where {S, T}
    gds_max =
        haskey(ENV, "GDS_POLYGON_MAX") ? parse(Int, ENV["GDS_POLYGON_MAX"]) :
        GDS_POLYGON_MAX

    # Check if any outer contour (with its holes) would produce a keyhole polygon
    # exceeding the point limit
    if all(Polygons.total_points(child) <= gds_max for child in Clipper.children(cp.tree))
        for poly in to_polygons(cp)
            render!(c, poly, meta; kwargs...)
        end
        return c
    end

    bestclip = _best_guillotine_cut(Polygons._all_contours(cp.tree))
    for q in [
        clip(Clipper.ClipTypeIntersection, cp, bestclip)
        clip(Clipper.ClipTypeDifference, cp, bestclip)
    ]
        render!(c, q, meta; kwargs...)
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
