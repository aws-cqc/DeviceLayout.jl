# All-pairs symmetric noding for [`render_conformal!`](@ref).
#
# Given a dict of curved boolean op results (one entry per physical group),
# adjacent groups that share a boundary must carry the *same* vertex sequence
# along it for the shared-edge cache in `render_conformal!` to resolve the
# boundary to a single OCC curve on both sides. Clipper does not guarantee
# this: two independent booleans can put a vertex on one side of a shared edge
# but not the other, leaving a T-junction the mesher rejects ("vertex lies in
# segment").
#
# `mutual_node!` fixes this for every group at once. It reuses the shared,
# RTree-based noding core in `src/postrender.jl` (the same core behind
# [`split_t_junctions!`](@ref)): it builds one spatial index of every group's
# vertices tagged by owning group, then re-nodes each group's contours against
# that index, injecting only the vertices owned by *other* groups. The result is
# symmetric by construction — if group A has a vertex on group B's edge, B gets
# it and vice versa — so both sides of every shared boundary end up with the
# identical ordered vertex sequence.

"""
    mutual_node!(groups::AbstractDict{Symbol, <:AbstractVector}; atol=onenanometer(T)) -> Int

Symmetric all-pairs noding across a collection of named region groups. For every
edge of every group, inject the vertices owned by *other* groups that lie on the
edge interior. Straight edges get the foreign vertex inserted verbatim; curved
edges (`Paths.Turn`, `Paths.BSpline`) are split at the foreign vertex's arclength
via [`Paths.split`](@ref), so curves stay native and exact. Modifies each group's
regions in place and returns the total number of vertices injected.

Makes adjacent groups conformal for [`render_conformal!`](@ref): both sides of
every shared boundary end up with the identical ordered vertex sequence, which is
what the shared-edge cache needs to resolve a boundary to one OCC curve on both
sides. Every group is noded against every other in a single pass over a shared
[`RTree`](@ref DeviceLayout.mbr_spatial_index) index — the caller does not need to
know the adjacency graph. This shares its geometry core with
[`split_t_junctions!`](@ref); `mutual_node!` is the symmetric, all-pairs,
foreign-only form used by the conformal pipeline. Foreign-only avoids
re-perturbing the within-group vertex sets that Clipper has already made
consistent for each group's own edges.

`atol` is a length (matching DeviceLayout's atol-with-units convention, same as
`split_t_junctions!`). It must be ≥ the maximum coordinate drift between two
groups' copies of the same logical vertex and ≪ the minimum feature size. Two
nanometers is a safe default: it covers the ≤ ~1.5 nm drift `discretize_curve`
can introduce and is far below any real feature. `atol` applies as a physical
distance regardless of the input Points' unit.

```julia
groups = Dict(:metal => metal_regions, :ground => gnd_regions, :ports => port_regions)
mutual_node!(groups; atol=2u"nm")
for (name, regions) in groups
    add_conformal_loop!.(Ref(ctx), regions, k, z; points_cache)
end
```
"""
function mutual_node!(groups::AbstractDict{Symbol, <:AbstractVector}; atol=nothing)
    isempty(groups) && return 0
    T = _noding_coordinate_type(groups)
    isnothing(T) && return 0
    atol_length = isnothing(atol) ? DeviceLayout.onenanometer(T) * 2 : atol
    # One index over every group's vertices, tagged by an integer owner id.
    # Sort keys so ownership assignment is independent of Dict iteration order —
    # makes group→owner mapping deterministic across runs. `split_t_junctions!`
    # uses owner 0 / no exclusion; here each group excludes its own owner so only
    # *foreign* vertices are injected.
    names = sort!(collect(keys(groups)))
    owner_of = Dict(name => i for (i, name) in enumerate(names))
    indexed = Tuple{Int, Vector{DeviceLayout.Point{T}}}[]
    for name in names
        verts = DeviceLayout.Point{T}[]
        for region in groups[name]
            DeviceLayout._collect_region_vertices!(verts, region)
        end
        push!(indexed, (owner_of[name], verts))
    end
    idx = DeviceLayout._build_vertex_index(indexed, T; atol=atol_length)
    total = 0
    for name in names
        regions = groups[name]
        oid = owner_of[name]
        for (ri, region) in enumerate(regions)
            new_region, n = DeviceLayout._node_region(region, idx, oid, 1e-6)
            if n > 0
                regions[ri] = new_region
                total += n
            end
        end
    end
    return total
end

# Coordinate type of the first non-empty group, or `nothing` if all are empty.
function _noding_coordinate_type(groups)
    for (_, regions) in groups
        isempty(regions) || return coordinatetype(regions[1])
    end
    return nothing
end
