module Intersect
using LinearAlgebra
import Base: intersect!
import CoordinateTransformations: IdentityTransformation
using IntervalTrees

using Unitful
using Unitful: Length

import DeviceLayout
import DeviceLayout: Coordinate, CoordinateUnits, Meta, Point
import DeviceLayout: uniquename, centered, place!, sref
using ..Paths
using ..Polygons
using ..CoordinateSystems
using ..Rectangles

const SegmentTree{T} =
    IntervalTrees.IntervalMap{T, Tuple{Int, Int, Polygons.LineSegment{T}}}

"""
    segment_tree(paths::Path{T}...) where {T}

Process `paths` into a `SegmentTree`, a data structure useful for finding intersections.

Output can be used as input for `intersect_segment_tree`.
"""
function segment_tree(paths::Path{T}...) where {T}
    x_iv = map(enumerate(paths)) do (path_idx, path)
        inds, segs = Paths.line_segments(path)
        segs_x = Polygons.xinterval.(segs)

        # Interval values: segment x-interval => (path index, node index, segment)
        # The path index keeps track of which path in `paths` the interval belongs to
        iv = map(zip(inds, segs, segs_x)) do (node_idx, seg, seg_x)
            return IntervalValue{T, Tuple{Int, Int, Polygons.LineSegment{T}}}(
                first(seg_x),
                last(seg_x),
                (path_idx, node_idx, seg)
            )
        end
        return iv
    end
    tree = SegmentTree{T}(sort!(collect(Iterators.flatten(x_iv))))
    return tree
end

"""
    intersect_segment_tree(tree1::SegmentTree{T}, tree2::SegmentTree{T}) where {T}

Find intersections between the paths represented in `tree1` and `tree2`.

Results are returned as a vector of three-element `Tuple`s containing the following:

  - A Tuple{Int, Int}, containing

      + The index of the intersecting `Path` in `tree1`
      + The index of the `Node` in that `Path` to which the intersecting segment belongs

  - A corresponding `Tuple{Int, Int}` for the intersecting element in `tree2`
  - The intersection `Point{T}`
"""
function intersect_segment_tree(tree1::SegmentTree{T}, tree2::SegmentTree{T}) where {T}
    # This method does considerable extra work, checking intersections for every pair
    # of segments overlapping in x. A better implementation would use an R-tree to take
    # advantage of the 2D nature of the problem.
    ixns = Tuple{Tuple{Int, Int}, Tuple{Int, Int}, Point{T}}[]
    for (i1, i2) in intersect(tree1, tree2)
        # Each segment trivially intersects with itself
        i1 === i2 && continue # Ignore trivial _and_ non-trivial segment self-intersections
        pa1_idx, node1_idx, seg1 = i1.value
        pa2_idx, node2_idx, seg2 = i2.value
        intersects, atapoint, atendpoints = Polygons.intersects_at_endpoint(seg1, seg2)
        # intersects => there is an overlap in x
        # atapoint => there is only one intersection point
        # !atendpoints => segments are not neighbors
        # ... Nontrivial endpoint intersections are not handled!
        if intersects && atapoint && !atendpoints
            # Lower (path, node) index is always first seg in intersection
            # ... Tuple comparison: Compare first element
            # ... Then use successive elements as tiebreakers as far as is necessary
            # (Guarantees the intersection (seg_a, seg_b) is the same as (seg_b, seg_a))
            seg_first, seg_sec =
                (pa1_idx, node1_idx) < (pa2_idx, node2_idx) ? (seg1, seg2) : (seg2, seg1)
            # Check for an intersection
            tf, point = Polygons.intersection(
                Polygons.Line(seg_first.p0, seg_first.p1),
                Polygons.Line(seg_sec.p0, seg_sec.p1),
                false
            )

            !tf && continue # No intersection 
            push!(ixns, ((pa1_idx, node1_idx), (pa2_idx, node2_idx), point))
        end
    end
    return ixns
end

function intersections(paths::Path...)
    tree = segment_tree(paths...)
    return intersect_segment_tree(tree, tree)
end

"""
    prepared_intersections(paths::Path...)

The intersections between `paths`, prepared in a format convenient for sequential processing.

Results are returned as a vector of three-element `Tuple`s:

  - `(path_idx_1, node_idx_1, pathlength_ixn_1)`

      + The index in `paths` of the first `Path` involved in the intersection
      + The index of the intersecting `Node` in that `Path`
      + The length along that node's `Paths.Segment` at which the intersection occurs

  - `(path_idx_2, node_idx_2, pathlength_ixn_2)`

      + As above, for the second `Path` involved in the intersection
  - The intersection point _on the discretized paths_

The vector is sorted by descending `(path_idx_2, node_idx_2, pathlength_ixn_2)`, and it is
guaranteed that `(path_idx_2, node_idx_2, pathlength_ixn_2) > (path_idx_1, node_idx_1, pathlength_ixn_1)`.
The second path at the intersection point thus has a later index (in the path list, in the
nodes list of a single path, or in the pathlength along a single node) than all
intersections remaining to be processed.

In other words, the results can safely be processed sequentially by modifying each second
path at the intersection point, without changing the indexing of subsequent intersections in
the list.
"""
function prepared_intersections(paths)
    ixns = intersections(paths...)
    swapped = map(ixns) do (int1, int2, pt)
        pa1, node1 = int1
        pa2, node2 = int2

        s1 = pathlength_nearest(paths[pa1][node1].seg, pt)
        s2 = pathlength_nearest(paths[pa2][node2].seg, pt)

        out1, out2 = minmax((pa1, node1, s1), (pa2, node2, s2))
        return (out1, out2, pt)
    end

    return unique(sort(swapped, by=(x) -> x[2], rev=true))
end

"""
    IntersectStyle{N}

Abstract type specifying "2-body interactions" for path intersection.
"""
abstract type IntersectStyle end

"""
    intersect!(sty::IntersectStyle, paths::Path...;
        intersections=prepared_intersections(paths...))

Automatically modify paths to handle cases where they intersect.

Paths later in the argument list cross over paths earlier in the argument list. For
self-intersection (path with itself), segments later in a path will cross over segments
earlier in the same path (perhaps later this will be configurable by an option).
"""
function intersect!(
    sty::IntersectStyle,
    paths::Path...;
    intersections=prepared_intersections(paths)
)
    for (int1, int2, pt) in intersections
        try
            intersect_pairwise!(
                sty,
                paths[int1[1]],
                int1[2],
                int1[3],
                paths[int2[1]],
                int2[2],
                int2[3]
            )
        catch e
            if e isa ErrorException
                error("""Intersection failed at $pt:
                    $(e.msg)""")
            else
                throw(e)
            end
        end
    end
end

"""
    intersect_pairwise!(
        xsty::IntersectStyle,
        pa1::Path,
        node1_idx::Int,
        s1,
        pa2::Path,
        node2_idx::Int,
        s2;
        a1=IdentityTransformation(),
        a2=IdentityTransformation()
    )

Automatically modify `pa2` at `pa2[node2_idx].seg(s2)` to cross over `pa1` using `xsty`.

`pa1 === pa2` is acceptable. The crossing-over segments must be `Paths.Straight`.
"""
function intersect_pairwise!(
    xsty::IntersectStyle,
    pa1::Path,
    node1_idx::Int,
    s1,
    pa2::Path,
    node2_idx::Int,
    s2;
    a1=IdentityTransformation(),
    a2=IdentityTransformation()
)
    # Path 2 crosses over path 1
    xpath = pa2
    xnode = xpath[node2_idx]

    (xnode.seg isa Paths.Straight) || error("""Can only handle Straight crossing segments.
                                      """)

    # Crossing angle
    dα =
        rotated_direction(direction(xnode.seg, s2), a2) -
        rotated_direction(direction(pa1[node1_idx].seg, s1), a1)
    sin(dα) == 0 && error("Colinear paths")

    # Find extent of crossing
    extent_1 =
        (Paths.extent(pa1[node1_idx].sty, s1) + crossing_gap(xsty)) / abs(sin(dα)) +
        Paths.extent(pa2[node2_idx].sty, s2) * abs(cot(dα))

    # Create crossover section to splice into crossing segment
    x = intersection(xsty, xnode, extent_1, s2)

    # Split crossing segment into 3
    splice!(
        xpath,
        node2_idx,
        split(xnode, [s2 - pathlength(x) / 2, s2 + pathlength(x) / 2])
    )
    # Replace new middle segment with crossover
    splice!(xpath, node2_idx + 1, x)

    # Clear decorations from the crossed path (pa1) near the crossover point.
    # The crossover replaces a segment of pa2 with a bridge/gap — any decorations
    # on pa1 that fall within the crossing extent would be geometrically occluded.
    _clear_crossing_decorations!(pa1, node1_idx, s1, extent_1)

    return nothing
end

function intersection(
    xsty::IntersectStyle,
    xnode::Paths.Node{T},
    crossing_extent,
    pos
) where {T}
    # Account for path terminations (relevant for CPW)
    sty = undecorated(xnode.sty)
    termlen_0 = Paths.terminationlength(sty, pos - crossing_extent)
    termlen_1 = Paths.terminationlength(sty, pos + crossing_extent)
    s2_0 = pos - crossing_extent - termlen_0
    s2_1 = pos + crossing_extent + termlen_1

    if (s2_0 < zero(s2_0)) || (s2_1 > pathlength(xnode))
        error("Too close to segment endpoint")
    end

    x = Path(zero(Point{T}))
    (termlen_0 > zero(termlen_0)) &&
        straight!(x, termlen_0, Paths.CPWOpenTermination(sty, s2_0))
    nr = Paths.NoRender(2 * Paths.extent(sty, pos - crossing_extent))
    straight!(x, 2 * crossing_extent, nr)
    intersection!(x, sty, crossing_extent, (s2_1 - s2_0), xsty)
    (termlen_1 > zero(termlen_1)) &&
        straight!(x, termlen_1, Paths.CPWOpenTermination(sty, s2_1))
    return x
end

function intersection!(
    pa::Path,
    psty::Paths.Style,
    pos,
    crossing_extent,
    xsty::IntersectStyle
)
    return attach!(pa, sref(intersection(xsty, psty, crossing_extent)), pos)
end

"""
    crossing_gap(xsty::IntersectStyle)

Extra length beyond the extent of the path being crossed (measured from the center).
"""
crossing_gap(xsty::IntersectStyle) = xsty.crossing_gap

"""
    AirBridge(; crossing_gap, foot_gap, foot_length, extent_gap, scaffold_gap,
        scaffold_meta=SemanticMeta(:scaffold), air_bridge_meta=SemanticMeta(:air_bridge), 
        name="airbridge", unit=[nm or NoUnits])

Style for automatically leaping one path over another with scaffolded air bridges.

# Parameters ("lengths" are along path direction, "extents" are transverse from the center)

  - `name`: Prefix for unique `CoordinateSystem` name
  - `scaffold_meta`: Scaffold layer metadata
  - `air_bridge_meta`: Air bridge layer metadata
  - `crossing_gap`: Extra length beyond extent of path being crossed (on one side)
  - `foot_gap`: Extra length beyond original path termination before bridge foot starts
  - `foot_length`: Length of bridge foot
  - `extent_gap`: Gap between edge of bridge trace and edge of original path trace
  - `scaffold_gap`: Gap between edge of original trace and edge of scaffold
  - `rounding`: Rounding radius for scaffold and air bridge rectangles
  - `unit`: Coordinate system unit
"""
struct AirBridge{S <: Meta, T <: Coordinate, U <: CoordinateUnits} <: IntersectStyle
    name::String
    scaffold_meta::S
    air_bridge_meta::S
    crossing_gap::T
    foot_gap::T
    foot_length::T
    extent_gap::T
    scaffold_gap::T
    rounding::T
    unit::U
    function AirBridge(;
        crossing_gap::Coordinate,
        foot_gap::Coordinate,
        foot_length::Coordinate,
        extent_gap::Coordinate,
        scaffold_gap::Coordinate,
        rounding::Coordinate=zero(crossing_gap),
        scaffold_meta::Meta=DeviceLayout.SemanticMeta(:scaffold),
        air_bridge_meta::Meta=DeviceLayout.SemanticMeta(:air_bridge),
        name::AbstractString="airbridge",
        unit::CoordinateUnits=(crossing_gap isa Length ? DeviceLayout.UPREFERRED : NoUnits)
    )
        cg, fg, fl, eg, sg =
            promote(crossing_gap, foot_gap, foot_length, extent_gap, scaffold_gap)
        S = typeof(scaffold_meta)
        T = eltype(cg)
        U = typeof(unit)
        return new{S, T, U}(
            name,
            scaffold_meta,
            air_bridge_meta,
            cg,
            fg,
            fl,
            eg,
            sg,
            rounding,
            unit
        )
    end
end

"""
    intersection(ab::AirBridge, style::Paths.Style, crossing_extent)

Return a `CoordinateSystem` containing an air bridge for a segment with `style` crossing the distance `crossing_extent`.
"""
function intersection(ab::AirBridge, sty::Paths.Style, crossing_extent)
    cs = DeviceLayout.CoordinateSystem(uniquename(ab.name), ab.unit)

    place!(
        cs,
        Polygons.Rounded(
            centered(
                DeviceLayout.Rectangle(
                    crossing_extent + 2 * ab.foot_gap,
                    Paths.trace(sty) + 2 * ab.scaffold_gap
                )
            ),
            ab.rounding
        ),
        ab.scaffold_meta
    )
    place!(
        cs,
        Polygons.Rounded(
            centered(
                DeviceLayout.Rectangle(
                    crossing_extent + 2 * ab.foot_gap + 2 * ab.foot_length,
                    Paths.trace(sty) - 2 * ab.extent_gap
                )
            ),
            ab.rounding
        ),
        ab.air_bridge_meta
    )

    return cs
end

"""
    _clear_crossing_decorations!(pa, node_idx, s, extent)

Remove decorations from `pa[node_idx]` that fall within `[s - extent, s + extent]`.
"""
function _clear_crossing_decorations!(pa::Path, node_idx::Int, s, extent)
    node = pa[node_idx]
    t_lo = s - extent
    t_hi = s + extent
    # Clamp to segment bounds
    t_lo = max(t_lo, zero(t_lo))
    t_hi = min(t_hi, pathlength(node.seg))
    Paths.undecorate_range!(node.sty, t_lo, t_hi)
    return nothing
end

end #module
