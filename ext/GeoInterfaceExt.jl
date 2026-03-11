module GeoInterfaceExt

using DeviceLayout
import DeviceLayout: Polygons, Points, Rectangles
using DeviceLayout.Points: Point
using DeviceLayout.Rectangles: Rectangle
using DeviceLayout.Polygons: Polygon, ClippedPolygon, points, to_polygons
import GeoInterface as GI
import Unitful: ustrip

# ── Point{T} → PointTrait ──────────────────────────────────────────────────────

GI.isgeometry(::Type{<:Point}) = true
GI.geomtrait(::Point) = GI.PointTrait()
GI.ncoord(::GI.PointTrait, ::Point) = 2
GI.getcoord(::GI.PointTrait, p::Point, i::Int) = i == 1 ? ustrip(p.x) : ustrip(p.y)

# ── Polygon{T} → PolygonTrait ──────────────────────────────────────────────────

GI.isgeometry(::Type{<:Polygon}) = true
GI.geomtrait(::Polygon) = GI.PolygonTrait()
GI.ngeom(::GI.PolygonTrait, ::Polygon) = 1  # single exterior ring, no holes
GI.getgeom(::GI.PolygonTrait, p::Polygon, i::Int) = ClosedRing(points(p))

# ── Rectangle{T} → PolygonTrait ────────────────────────────────────────────────

GI.isgeometry(::Type{<:Rectangle}) = true
GI.geomtrait(::Rectangle) = GI.PolygonTrait()
GI.ngeom(::GI.PolygonTrait, ::Rectangle) = 1
GI.getgeom(::GI.PolygonTrait, r::Rectangle, i::Int) = ClosedRing(points(r))

# ── ClippedPolygon{T} → MultiPolygonTrait ───────────────────────────────────────

GI.isgeometry(::Type{<:ClippedPolygon}) = true
GI.geomtrait(::ClippedPolygon) = GI.MultiPolygonTrait()

function GI.ngeom(::GI.MultiPolygonTrait, cp::ClippedPolygon)
    return length(to_polygons(cp))
end

function GI.getgeom(::GI.MultiPolygonTrait, cp::ClippedPolygon, i::Int)
    return to_polygons(cp)[i]
end

# ── ClosedRing: lightweight wrapper for GeoInterface ring closure ────────────────
# GeoInterface expects closed rings (first == last point).
# DeviceLayout polygons do NOT repeat the first point.
# This wrapper presents a closed view without copying.

struct ClosedRing{T}
    points::Vector{Point{T}}
end

GI.isgeometry(::Type{<:ClosedRing}) = true
GI.geomtrait(::ClosedRing) = GI.LinearRingTrait()

function GI.ngeom(::GI.LinearRingTrait, r::ClosedRing)
    return length(r.points) + 1  # original points + closing point
end

function GI.getgeom(::GI.LinearRingTrait, r::ClosedRing, i::Int)
    n = length(r.points)
    return i <= n ? r.points[i] : r.points[1]
end

# Coordinate access for the ring itself
GI.ncoord(::GI.LinearRingTrait, r::ClosedRing) = 2

end # module
