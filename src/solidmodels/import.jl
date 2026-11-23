######## Importing external CAD geometry
#
# `import_solid!` brings an externally-authored solid (STEP, BREP, or a Gmsh `.xao`
# archive) *into the SolidModel's own OCC kernel*, positions it with an affine placement,
# and registers it as a physical group. Because the shape lands in the same model as the
# rest of the geometry, it can then be made conformal with existing groups using the boolean
# ops in `postrender.jl` (`fragment_geom!`, `fragment_near!`, ...), which require both
# operands to belong to the same model.
#
# The placement is decomposed into three pieces (see `_place_imported!`):
#   * a uniform 3D scale, for deliberate resizing or raw-coordinate unit conversion;
#   * an in-plane `ScaledIsometry` — rotation, optional x-reflection, in-plane magnification,
#     and (x, y) translation — reusing the exact transform that the schematic layer computes
#     when it mates two `Hook`s; and
#   * an out-of-plane z-shift, typically the height of the target layer in the process stack.
# Together these cover placement on a planar chip surface without an arbitrary 3D tilt.

"""
    import_solid!(sm::SolidModel, filename;
                  transform=ScaledIsometry(), z=0.0 * STP_UNIT, scale=1.0,
                  groupname="imported", format="", group_map=identity)

Import an external CAD solid from `filename` into `sm` and position it with an affine
placement.

!!! warning "Experimental API"

    `import_solid!` and `SchematicDrivenLayout.SolidModelComponent` are experimental and may
    change in minor versions as they are stress tested and harmonized with the experimental
    solid-model pipeline.

The file is read by the OpenCASCADE kernel (STEP `.stp`/`.step`, BREP `.brep`, or a Gmsh
`.xao` archive), so `sm` must use the `OpenCascade` kernel. Other formats the reader
accepts, such as IGES, typically hold surfaces rather than solids and import as such. The
imported entities are positioned by:

 1. scaling the raw geometry uniformly by `scale`, for deliberate resizing or conversion of
    raw coordinates without usable unit metadata. Unit-aware files such as STEP are already
    converted to μm by the `SolidModel`'s OpenCASCADE target-unit setting;
 2. applying the in-plane `transform::ScaledIsometry` (rotation / reflection / in-plane
    magnification / (x, y) translation) — the same transform produced by mating two `Hook`s;
 3. lifting by `z` in the out-of-plane direction (typically the target layer's top surface).

The result is registered as a physical group named `groupname` (pass `groupname=nothing` to
skip group creation). Returns the imported entities as a vector of `(dim, tag)` `Tuple`s.

To place many copies of one file, pass a vector of transforms instead, which reads the file
once (see the method below).

To use `import_solid!` as a postrender operation, let the postrenderer create the destination
group rather than creating a second group inside `import_solid!`:

    (
        destination,
        import_solid!,
        (filename,),
        :transform => transform,
        :z => z,
        :groupname => nothing,
    )

Only the highest-dimensional entities (the solid volumes) are returned and registered,
discarding stray construction curves. `format` is forwarded to `occ.importShapes`.

Rotation and translation keep analytic surfaces (planes, cylinders, ...). So does `scale`
for STEP and BREP files, which is applied while reading. Scaling a `.xao`, reflecting, and
an in-plane `mag(transform) != 1` convert the affected surfaces to BSplines, so prefer
`.xao` files authored in μm.

A `.xao` file also carries physical groups. These are registered in `sm` under
`group_map(name)`, so a mapping such as `n -> n * "_pkg"` keeps them apart from groups already
in the model; with the default `identity`, an imported group with the same name and dimension
as an existing one replaces it. Pass `group_map=nothing` to discard the file's groups. Existing
groups keep their entities regardless of any tag they share with the file, but they are
re-registered with fresh gmsh tags, so look them up by name afterwards rather than through a
`PhysicalGroup` obtained before the import. `.xao` coordinates carry no unit, so a file
authored in mm needs `scale=1000`. `format` is ignored, and the file's own groups cover all
dimensions.

Once imported, make it conformal with existing geometry, e.g. with
`fragment_near!(sm, groupname)` (see [`fragment_near!`](@ref)) or
`fragment_geom!(sm, groupname, "pad_metal", 3, 3)`.
"""
function import_solid!(
    sm::SolidModel,
    filename::AbstractString;
    transform::DeviceLayout.ScaledIsometry=DeviceLayout.ScaledIsometry(),
    kwargs...
)
    # One placement is the multi-placement import with no copies.
    return only(import_solid!(sm, filename, [transform]; kwargs...))
end

"""
    import_solid!(sm::SolidModel, filename, transforms::AbstractVector{<:ScaledIsometry};
                  z=0.0 * STP_UNIT, scale=1.0, groupname="imported", format="",
                  group_map=identity)

Import `filename` once and place a copy at each of `transforms`. Returns one vector of
`(dim, tag)` `Tuple`s per transform, in the order of `transforms`.

The result matches one `import_solid!(sm, filename; transform=tr, ...)` per transform, but
the file is read and the model synchronized once per call rather than once per copy, which
dominates the cost of placing many copies of a small part. Keywords mean the same as for a
single placement. A `.xao` with a free-standing entity that shares a sub-shape with another
of a different dimension, such as a sheet with an edge on a solid, is read once per copy
instead, since copying would detach them; the groups are still registered once.

`z`, `groupname`, and `group_map` each take one value used for every copy, or a vector with
one value per copy. Copies that share a name share a group: by default every copy goes in
`"imported"`, and each `.xao` group collects its entities from every copy. Per-copy names keep
them apart, e.g. `groupname=["bond_\$i" for i in eachindex(transforms)]` with
`group_map=[n -> "bond_\$(i)_\$n" for i in eachindex(transforms)]`.

If reading or placing fails, the model's existing groups are restored before the error is
rethrown, but entities already imported stay in the model without a group.
"""
function import_solid!(
    sm::SolidModel,
    filename::AbstractString,
    transforms::AbstractVector{<:DeviceLayout.ScaledIsometry};
    z=0.0 * STP_UNIT,
    scale=1.0,
    groupname="imported",
    format="",
    group_map=identity
)
    # OCC is required both to read the CAD file and to fragment it with the model afterward.
    kernel(sm) isa OpenCascade || throw(
        ArgumentError("import_solid! requires the OpenCascade kernel (got $(kernel(sm)))")
    )
    isfile(filename) ||
        throw(ArgumentError("import_solid!: file not found: $(repr(filename))"))
    isempty(transforms) && throw(ArgumentError("import_solid!: no transforms given"))
    n = length(transforms)
    zs = _per_copy(z, n, :z)
    groupnames = _per_copy(groupname, n, :groupname)
    group_maps = _per_copy(group_map, n, :group_map)

    gmsh.model.set_current(name(sm))
    is_xao = lowercase(splitext(filename)[2]) == ".xao"
    if is_xao
        proto, file_groups, own_groups = _merge_xao!(sm, filename)
        filter!(g -> !isempty(g[2]), file_groups)   # unnamed groups carry nothing downstream
    else
        # Import into this model's OCC kernel, scaled while reading: OCC's own scaling keeps
        # analytic surfaces, which a later `dilate` would turn into BSplines.
        proto = _with_gmsh_option("Geometry.OCCScaling", scale) do
            return gmsh.model.occ.importShapes(filename, true, format)
        end
        file_groups = own_groups = Tuple{Int32, String, Vector{Int32}}[]
    end

    # From here until they are re-registered, the model's own groups exist only in
    # `own_groups` (a `.xao` merge strips them), so an error restores them before rethrowing.
    local placed, placement_groups
    try
        placed, placement_groups = _place_copies!(
            sm,
            filename,
            proto,
            file_groups,
            transforms,
            zs,
            is_xao ? scale : 1.0;
            needs_map=!isempty(file_groups) && any(!isnothing, group_maps[1:(n - 1)])
        )
    catch
        _restore_groups!(sm, own_groups)
        rethrow()
    end
    _restore_groups!(sm, own_groups)

    # `placement_groups[i]` holds the file's groups as they apply to placement `i`.
    file_entries = Pair{String, Vector{Tuple{Int32, Int32}}}[]
    for (gm, groups) in zip(group_maps, placement_groups)
        isnothing(gm) && continue
        for (d, nm, tags) in groups
            push!(file_entries, gm(nm) => [(d, t) for t in tags])
        end
    end
    _register_merged!(sm, file_entries)
    _register_merged!(
        sm,
        [nm => placed[i] for (i, nm) in enumerate(groupnames) if !isnothing(nm)]
    )
    return placed
end

"""
    _place_copies!(sm, filename, proto, file_groups, transforms, zs, place_scale; needs_map)
        -> (placed, placement_groups)

Make one placement of the freshly imported entities `proto` per transform, place them, and
synchronize. The prototype itself is the last placement. Returns the solids of each placement
and, for each placement, the file's groups `file_groups` as `(dim, name, entity_tags)` records
of that placement's entities (left empty for copies when `needs_map` is false).

The other placements are normally `occ.copy`s of the prototype, made before anything moves,
while each coincides with the prototype: that is when the copy's entities can be matched to
the prototype's for the file's groups. A `.xao` whose top-level entities of different
dimensions share sub-shapes, such as a free-standing sheet with an edge on a solid, is merged
again for each placement instead, because `occ.copy` would separate them.
"""
function _place_copies!(
    sm,
    filename,
    proto,
    file_groups,
    transforms,
    zs,
    place_scale;
    needs_map
)
    # OCC can read an empty or corrupt BREP without an error and import nothing.
    isempty(proto) &&
        throw(ArgumentError("import_solid!: no entities imported from $(repr(filename))"))
    n = length(transforms)
    # `merge` returns entities of every dimension; only the solids are returned and
    # registered. `importShapes` already returns only the highest dimension.
    top = maximum(first, proto)
    solids = filter(dt -> dt[1] == top, proto)

    # Copying the top-level entities, the solids and anything not on their boundary such as
    # a free-standing sheet, copies everything the file brought in, as a separate import
    # would. Only a `.xao` merge brings in entities other than the solids. `merge`
    # synchronizes, so the boundaries can be read without another synchronize.
    roots, shared =
        n > 1 && length(solids) < length(proto) ? _top_level(proto) : (solids, false)
    if shared
        # Reading once per copy costs n reads, so say so for anyone profiling a slow import.
        @debug "import_solid!: $(repr(filename)) has free-standing entities that share " *
               "sub-shapes with others, so it is read once per copy ($n reads)"
        return _place_merges!(sm, filename, proto, file_groups, transforms, zs, place_scale)
    end
    copies = Vector{Tuple{Int32, Int32}}[_copy_by_dim(roots) for _ = 1:(n - 1)]
    closures = needs_map ? _copy_closures(sm, roots, copies) : nothing

    # Placement runs on OCC entities directly, so no synchronize is needed until the groups
    # are registered. A copy whose groups are tracked moves together with its boundary, just
    # as the merged prototype does, so the matched lower-dimensional tags stay valid. The
    # entities go lowest dimension first, the order `merge` reports them in: OCC rebinds each
    # listed entity under its tag in turn, and a solid listed before its faces would hand
    # them new tags first. The sort is stable, so the order within a dimension is the
    # deterministic order of the boundary walk.
    # STEP/BREP are scaled while reading, which the copies inherit; only `.xao` scales here.
    for i = 1:(n - 1)
        dts = needs_map ? sort(last(closures[i]); by=first) : copies[i]
        _place_imported!(dts, transforms[i], zs[i]; scale=place_scale)
    end
    _place_imported!(proto, transforms[n], zs[n]; scale=place_scale)
    _synchronize!(sm)

    placed = [filter(dt -> dt[1] == top, cp) for cp in copies]
    push!(placed, solids)
    # Translate the prototype's groups to each copy's entities; the prototype keeps its own.
    copy_groups = map(1:(n - 1)) do i
        needs_map || return eltype(file_groups)[]
        entity_map = Dict(zip(closures[i]...))
        return [
            (d, nm, [entity_map[(d, t)][2] for t in tags]) for (d, nm, tags) in file_groups
        ]
    end
    return placed, push!(copy_groups, file_groups)
end

"""
    _place_merges!(sm, filename, proto, file_groups, transforms, zs, place_scale)
        -> (placed, placement_groups)

The fallback of `_place_copies!` for a `.xao` that `occ.copy` cannot reproduce: merge the file
once more for each placement but the last, which is the already merged `proto`, and place each
merge as a whole, as a separate import would. The model's groups are already stripped, so
each merge only has to strip its own groups.
"""
function _place_merges!(sm, filename, proto, file_groups, transforms, zs, place_scale)
    n = length(transforms)
    top = maximum(first, proto)
    merges = map(1:(n - 1)) do _
        before = Set(gmsh.model.getEntities())
        gmsh.merge(filename)
        new_dimtags = [dt for dt in gmsh.model.getEntities() if !(dt in before)]
        groups = filter!(g -> !isempty(g[2]), _strip_physical_groups!())
        return new_dimtags, groups
    end
    # Merges happen before anything moves, so a merge never lands on a placed copy. Each
    # merge's entities are listed lowest dimension first, as for the prototype.
    for (i, (dts, _)) in enumerate(merges)
        _place_imported!(dts, transforms[i], zs[i]; scale=place_scale)
    end
    _place_imported!(proto, transforms[n], zs[n]; scale=place_scale)
    _synchronize!(sm)
    placed = [filter(dt -> dt[1] == top, dts) for (dts, _) in merges]
    push!(placed, filter(dt -> dt[1] == top, proto))
    return placed, push!(last.(merges), file_groups)
end

# Re-register groups stripped by a `.xao` merge through `setindex!`, which allocates fresh
# tags. The dict's stale entries are removed first so `setindex!` does not try to delete a tag
# that no longer exists.
function _restore_groups!(sm::SolidModel, groups)
    for (d, nm, tags) in groups
        delete!(dimgroupdict(sm, d), nm)
        sm[nm] = [(d, t) for t in tags]
    end
end

# Expand a keyword of the multi-placement `import_solid!` to one value per copy.
function _per_copy(x::AbstractVector, n, kw)
    length(x) == n || throw(
        ArgumentError("import_solid!: `$kw` has $(length(x)) entries for $n transforms")
    )
    return x
end
_per_copy(x, n, kw) = fill(x, n)

# Register `name => dimtags` entries, merging entries with the same name into one group.
# Names may be `Symbol`s, as for `sm[name] = ...`. They are registered in order of first
# appearance so group tags are deterministic.
function _register_merged!(sm::SolidModel, entries)
    merged = Dict{String, Vector{Tuple{Int32, Int32}}}()
    order = String[]
    for (nm, dts) in entries
        key = string(nm)
        haskey(merged, key) || (push!(order, key); merged[key] = Tuple{Int32, Int32}[])
        append!(merged[key], dts)
    end
    for nm in order
        sm[nm] = merged[nm]
    end
end

# `occ.copy` of `dimtags`, one dimension at a time: given several dimensions at once it
# returns only the highest-dimensional copies. The copies follow the order of `dimtags` when
# it is sorted by dimension, as `_top_level` returns it.
_copy_by_dim(dimtags) = reduce(
    vcat,
    (
        gmsh.model.occ.copy(filter(dt -> dt[1] == d, dimtags)) for
        d in unique(first.(dimtags))
    )
)

"""
    _top_level(dimtags) -> (roots, shared)

The entities of `dimtags` that are not on the boundary of another of them, highest dimension
first: the solids, then any free-standing faces, curves, or points. `shared` is true if roots
of different dimensions share a sub-shape, such as a sheet with an edge on a solid's face.
"""
function _top_level(dimtags)
    roots = Tuple{Int32, Int32}[]
    covered = Set{Tuple{Int32, Int32}}()
    shared = false
    # One boundary walk per dimension. An entity cannot bound another of its own dimension,
    # so a dimension's roots are what higher roots have not covered. Folding each
    # dimension's closure into `covered` before the next keeps, e.g., the edges of a free
    # sheet from counting as free curves.
    for d = 3:-1:0
        layer = [dt for dt in dimtags if dt[1] == d && !(dt in covered)]
        isempty(layer) && continue
        closure = _boundary_closure(layer)
        # The layer itself is uncovered, so anything of its closure already covered is a
        # sub-shape it shares with a higher-dimensional root.
        shared |= any(in(covered), closure)
        union!(covered, closure)
        append!(roots, layer)
    end
    return roots, shared
end

"""
    _copy_closures(sm, roots, copies) -> Vector{Pair}

For each copy in `copies` (from `occ.copy(roots)`, not yet moved), pair the boundary closure
of the prototype `roots` with the copy's, entity by entity.

`occ.copy` returns only the copied top-level entities. Their boundaries are walked in the same
order as the prototype's, which pairs entities by position. Because a copy coincides with its
prototype at this point, each pair is checked to have the same dimension, center, and size
(length, area, or volume), and a mismatch is an error rather than a silently mislabeled group.
The size check tells apart entities that share a center, such as the two walls of a tube.
"""
function _copy_closures(sm::SolidModel, roots, copies)
    _synchronize!(sm)
    proto = _boundary_closure(roots)
    signatures = _entity_signature.(proto)
    bb = gmsh.model.getBoundingBox(-1, -1)
    tol = sqrt(eps()) * (1 + hypot(bb[4] - bb[1], bb[5] - bb[2], bb[6] - bb[3]))
    return map(copies) do cp
        closure = _boundary_closure(cp)
        matches =
            length(closure) == length(proto) && all(
                p[1] == c[1] && _same_signature(_entity_signature(c), s, tol) for
                (p, c, s) in zip(proto, closure, signatures)
            )
        matches || error(
            "import_solid!: the entities of a copy do not match the imported prototype's, " *
            "so the file's physical groups cannot be assigned to it"
        )
        return proto => closure
    end
end

# Where an entity is and how big: the center of mass and the mass (length, area, or volume),
# or a vertex's coordinates and zero.
_entity_signature((d, t)) =
    d == 0 ? (gmsh.model.getValue(0, t, Float64[]), 0.0) :
    (gmsh.model.occ.getCenterOfMass(d, t), gmsh.model.occ.getMass(d, t))
_same_signature((c1, m1), (c2, m2), tol) =
    maximum(abs.(c1 .- c2)) <= tol && abs(m1 - m2) <= sqrt(eps()) * (1 + abs(m2))

"""
    _merge_xao!(sm, filename) -> (new_dimtags, file_groups, own_groups)

Read a `.xao` file into the current model with `gmsh.merge`, returning the entities it added
and two lists of `(dim, name, entity_tags)` records: the file's physical groups and the groups
`sm` had before the merge. On return the model has no physical groups at all; the caller
re-registers both lists.

`gmsh.merge` matches the file's physical groups to the model's by numeric tag, so a group in
the file that shares a tag with an existing group would be merged into it. Emptying the group
table before the merge removes anything to collide with, and stripping again afterwards leaves
`setindex!` to allocate every tag fresh.
"""
function _merge_xao!(sm::SolidModel, filename)
    _synchronize!(sm)
    own_groups =
        [(Int32(d), nm, entitytags(pg)) for d = 0:3 for (nm, pg) in dimgroupdict(sm, d)]
    _strip_physical_groups!()
    before = Set(gmsh.model.getEntities())
    gmsh.merge(filename)
    new_dimtags = [dt for dt in gmsh.model.getEntities() if !(dt in before)]
    file_groups = _strip_physical_groups!()
    return new_dimtags, file_groups, own_groups
end

"""
    _strip_physical_groups!() -> Vector{Tuple{Int32, String, Vector{Int32}}}

Remove every physical group from the current gmsh model, returning `(dim, name, entity_tags)`
records of what was removed.

Gmsh keeps the group table and the name registry separately; a name left registered would
attach a later `setPhysicalName` for the same name to the old tag, so both are cleared.
"""
function _strip_physical_groups!()
    groups = gmsh.model.getPhysicalGroups()
    records = Tuple{Int32, String, Vector{Int32}}[]
    for (d, t) in groups
        push!(
            records,
            (
                d,
                gmsh.model.getPhysicalName(d, t),
                gmsh.model.getEntitiesForPhysicalGroup(d, t)
            )
        )
    end
    # Remove by explicit list. The no-argument form resets the built-in kernel's group lists
    # and segfaults (gmsh 4.15) when a group was removed selectively earlier, as `setindex!`
    # does whenever it replaces a group.
    isempty(groups) || gmsh.model.removePhysicalGroups(groups)
    for nm in unique(r[2] for r in records)
        isempty(nm) || gmsh.model.removePhysicalName(nm)
    end
    return records
end

"""
    _place_imported!(dimtags, transform::ScaledIsometry, z; scale=1.0)

Move freshly imported entities to their placement, mapping a point `p` to

    R(φ) · diag(m, m·sgn, scale) · p + (tx, ty, z)    with  m = mag(transform)·scale,
                                                             sgn = xrefl(transform) ? -1 : 1

where `R(φ)` rotates by `rotation(transform)` about the z axis and `(tx, ty)` is
`origin(transform)`. The reflection sign convention matches `linearmap` in `transform.jl`,
so a reflected hook mate produces a consistently reflected solid. `scale` multiplies z as
well, while `mag(transform)` follows 2D `ScaledIsometry` semantics and affects x and y only.

The map is applied as separate OCC operations, each skipped when it is the identity, because
OCC's general affine transform converts every surface to a BSpline. Rotation and translation
keep analytic surfaces; reflection and scaling do not.
"""
function _place_imported!(dimtags, transform::DeviceLayout.ScaledIsometry, z; scale=1.0)
    occ = gmsh.model.occ
    # Diagonal part first (reflection and scale commute with each other).
    DeviceLayout.xrefl(transform) && occ.mirror(dimtags, 0, 1, 0, 0)   # y -> -y
    m = DeviceLayout.mag(transform) * scale
    (m != 1 || scale != 1) && occ.dilate(dimtags, 0, 0, 0, m, m, scale)
    φ = ustrip(°, DeviceLayout.rotation(transform))
    iszero(mod(φ, 360)) || occ.rotate(dimtags, 0, 0, 0, 0, 0, 1, deg2rad(φ))
    # Translation in model units (μm). `origin` may be `nothing`, meaning no translation.
    o = DeviceLayout.origin(transform)
    t = (
        isnothing(o) ? 0.0 : ustrip(STP_UNIT, getx(o)),
        isnothing(o) ? 0.0 : ustrip(STP_UNIT, gety(o)),
        ustrip(STP_UNIT, z)
    )
    all(iszero, t) || occ.translate(dimtags, t...)
    return dimtags
end

# Run `f()` with a gmsh number option temporarily set to `value`.
function _with_gmsh_option(f, option, value)
    old = gmsh.option.getNumber(option)
    gmsh.option.setNumber(option, value)
    try
        return f()
    finally
        gmsh.option.setNumber(option, old)
    end
end
