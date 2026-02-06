using DeviceLayout, .PreferredUnits
using SpatialIndexing

import DeviceLayout: ustrip, unit
import SpatialIndexing: mbr

function SpatialIndexing.mbr(ent::GeometryEntity)
    r = bounds(ent)
    return SpatialIndexing.Rect((ustrip(r.ll)...,), (ustrip(r.ur)...,))
end

function spatial_index(ents::Vector{T}) where {T <: GeometryEntity}
    tree = RTree{Float64, 2}(Int)
    function convertel(enum_ent)
        idx, ent = enum_ent
        return SpatialIndexing.SpatialElem(mbr(ent), nothing, idx)
    end
    SpatialIndexing.load!(tree, enumerate(ents), convertel=convertel)
    return tree
end

# Goal is to have around 1000 polygons per tile
function intersect2d_tiled(poly1::Vector{Polygon{T}},
        poly2::Vector{Polygon{T}},
        max_tile_size=1mm;
        heal=false) where T
    # Create spatial index for each set of polygons
    @time "Tree1" tree1 = spatial_index(poly1)
    @time "Tree2" tree2 = spatial_index(poly2)

    # Get tiles and indices of polygons intersecting tiles
    bnds = SpatialIndexing.combine(mbr(tree1), mbr(tree2))
    bnds_dl = Rectangle(Point(bnds.low...)*unit(T), Point(bnds.high...)*unit(T))
    tiles, edges = tiles_edges(bnds_dl, max_tile_size) # DeviceLayout Rectangles
    @time "Finding" tile_poly_indices = map(tiles) do tile
        idx1 = intersecting_idx(tree1, tile)
        idx2 = intersecting_idx(tree2, tile)
        return (idx1, idx2)
    end
    # Intersect within each tile
    @time "Intersecting" res = map(tile_poly_indices) do (idx1, idx2)
        obj = @view poly1[idx1]
        tool = @view poly2[idx2]
        return to_polygons(intersect2d(obj, tool))
    end
    output_poly = reduce(vcat, res; init=Polygon{T}[])
    
    # Output from polygons touching edges may be duplicated
    heal && heal_edges!(output_poly, edges)
    # Output that does not itself touch an edge will still be duplicated
    return output_poly
end

function intersecting_idx(tree, tile)
    return map(x -> x.val, intersects_with(tree, mbr(tile)))
end

function heal_edges!(polygons::Vector{Polygon{T}}, edges) where T
    tree = spatial_index(polygons)
    touching_edge_idx = map(edges) do edge
        intersects_with(tree, edge)
    end
    healed = reduce(vcat,
        to_polygons(union2d(@view polygons[touching_edge_idx])),
        init=Polygon{T}[])
    delete_at!(polygons, touching_edge_idx)
    append!(polygons, healed)
end

function tiles_edges(r::Rectangle, max_tile_size)
    d = min(width(r), height(r))
    tile_size = d / ceil(d / max_tile_size)
    nx = width(r) / tile_size
    ny = height(r) / tile_size
    tile0 = r.ll + Rectangle(tile_size, tile_size)
    tiles = [tile0 + Point((i-1)*tile_size, (j-1)*tile_size)
        for i in 1:nx for j in 1:ny]
    h_edges = [
        Rectangle(Point(r.ll.x, r.ll.y + (i-1)*tile_size),
            Point(r.ur.x, r.ll.y + (i-1)*tile_size)) for i = 2:nx
    ]
    v_edges = [
        Rectangle(Point(r.ll.x + (i-1)*tile_size, r.ll.y),
            Point(r.ll.x + (i-1)*tile_size, r.ur.y)) for i = 2:nx
    ]
    return tiles, vcat(h_edges, v_edges)
end

function benchmark_clip(ntot; tiled=false)
    n = Int(round(sqrt(ntot)))

    circ1 = Cell("circ1", nm)
    render!(circ1, Circle(10μm), GDSMeta(1))
    circ2 = Cell("circ2", nm)
    render!(circ2, Circle(10μm), GDSMeta(2))

    arr1 = aref(circ1, dc=Point(100μm, 0μm), dr=Point(0μm, 100μm), nc=n, nr=n)
    arr2 = aref(circ2, Point(5μm, 5μm), dc=Point(100μm, 0μm), dr=Point(0μm, 100μm), nc=n, nr=n)

    poly1 = elements(flatten(arr1))
    poly2 = elements(flatten(arr2))

    if tiled
        @time "Tiled (total)" intersect2d_tiled(poly1, poly2)
    else
        @time "Direct (total)" to_polygons(intersect2d(poly1, poly2))
    end
end
