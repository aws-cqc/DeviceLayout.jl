######## Importing external CAD geometry
#
# `import_solid!` brings an externally-authored solid (STEP/BREP/IGES — anything the
# OpenCASCADE reader understands — or a Gmsh `.xao` archive) *into the SolidModel's own OCC
# kernel*, positions it with an affine placement, and registers it as a physical group. Because the shape lands in the same
# model as the rest of the geometry, it can then be fused conformally with existing groups
# using the boolean ops in `postrender.jl` (`fragment_geom!`, `union_geom!`, ...), which
# require both operands to belong to the same model.
#
# The placement is decomposed into three pieces (see `_occ_affine_matrix`):
#   * a uniform 3D scale, for deliberate resizing or raw-coordinate unit conversion;
#   * an in-plane `ScaledIsometry` — rotation, optional x-reflection, in-plane magnification,
#     and (x, y) translation — reusing the exact transform that the schematic layer computes
#     when it mates two `Hook`s; and
#   * an out-of-plane z-shift, typically the height of the target layer in the process stack.
# Together these cover placement on a planar chip surface without an arbitrary 3D tilt.

"""
    import_solid!(sm::SolidModel, filename;
                  transform=ScaledIsometry(), z=0.0 * STP_UNIT, scale=1.0,
                  groupname="imported", highest_dim_only=true, format="",
                  group_map=identity)

Import an external CAD solid from `filename` into `sm` and position it with an affine
placement.

The file is read by the OpenCASCADE kernel (STEP `.stp`/`.step`, BREP `.brep`, IGES `.iges`,
or a Gmsh `.xao` archive), so `sm` must use the `OpenCascade` kernel. The imported entities
are positioned by:

 1. scaling the raw geometry uniformly by `scale`, for deliberate resizing or conversion of
    raw coordinates without usable unit metadata. Unit-aware files such as STEP are already
    converted to μm by the `SolidModel`'s OpenCASCADE target-unit setting;
 2. applying the in-plane `transform::ScaledIsometry` (rotation / reflection / in-plane
    magnification / (x, y) translation) — the same transform produced by mating two `Hook`s;
 3. lifting by `z` in the out-of-plane direction (typically the target layer's top surface).

The result is registered as a physical group named `groupname` (pass `groupname=nothing` to
skip group creation). Returns the imported entities as a vector of `(dim, tag)` `Tuple`s.

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

`highest_dim_only` and `format` are forwarded to `occ.importShapes`; the default keeps only
the highest-dimensional entities (the solid volume), discarding stray construction curves.

A `.xao` file also carries physical groups. These are registered in `sm` under
`group_map(name)`, so a mapping such as `n -> n * "_pkg"` keeps them apart from groups already
in the model; with the default `identity`, an imported group with the same name and dimension
as an existing one replaces it. Pass `group_map=nothing` to discard the file's groups. Existing
groups keep their entities regardless of any tag they share with the file, but they are
re-registered with fresh gmsh tags, so look them up by name afterwards rather than through a
`PhysicalGroup` obtained before the import. `.xao` coordinates carry no unit, so a file
authored in mm needs `scale=1000`. `format` is ignored and `highest_dim_only` selects which
of the imported entities are returned and registered as `groupname`; the file's own groups
always cover all dimensions.

Once imported, fuse it conformally to existing geometry, e.g.
`fragment_geom!(sm, groupname, "pad_metal", 3, 3)`.
"""
function import_solid!(
    sm::SolidModel,
    filename::AbstractString;
    transform::DeviceLayout.ScaledIsometry=DeviceLayout.ScaledIsometry(),
    z=0.0 * STP_UNIT,
    scale=1.0,
    groupname="imported",
    highest_dim_only=true,
    format="",
    group_map=identity
)
    # OCC is required both to read the CAD file and to boolean-fuse it afterward.
    kernel(sm) isa OpenCascade || throw(
        ArgumentError("import_solid! requires the OpenCascade kernel (got $(kernel(sm)))")
    )
    isfile(filename) ||
        throw(ArgumentError("import_solid!: file not found: $(repr(filename))"))

    gmsh.model.set_current(name(sm))
    is_xao = lowercase(splitext(filename)[2]) == ".xao"
    if is_xao
        new_dimtags, file_groups, own_groups = _merge_xao!(sm, filename)
    else
        # Import into *this* model's OCC kernel. importShapes returns the (dim,tag) pairs it
        # created, so there's no need to diff the entity list before/after.
        new_dimtags = gmsh.model.occ.importShapes(filename, highest_dim_only, format)
    end

    # Reposition the freshly imported entities in place (an OCC-kernel operation, so no
    # synchronize is needed until we assign the physical group below).
    gmsh.model.occ.affineTransform(
        new_dimtags,
        _occ_affine_matrix(transform, z; scale=scale)
    )

    if is_xao
        _synchronize!(sm)
        # Everything was stripped for the merge; re-register through `setindex!`, which
        # allocates fresh tags. The dict's stale entries are removed first so `setindex!` does
        # not try to delete a tag that no longer exists.
        for (d, nm, tags) in own_groups
            delete!(dimgroupdict(sm, d), nm)
            sm[nm] = [(d, t) for t in tags]
        end
        if !isnothing(group_map)
            for (d, nm, tags) in file_groups
                isempty(nm) && continue   # unnamed groups carry nothing downstream
                sm[group_map(nm)] = [(d, t) for t in tags]
            end
        end
        if highest_dim_only && !isempty(new_dimtags)
            top = maximum(first, new_dimtags)
            new_dimtags = filter(dt -> dt[1] == top, new_dimtags)
        end
    end

    # Registering the group synchronizes the OCC kernel into the gmsh model; if the caller
    # opted out of group creation, synchronize explicitly so downstream ops see the entities.
    if isnothing(groupname)
        _synchronize!(sm)
    else
        sm[groupname] = new_dimtags
    end
    return new_dimtags
end

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
    _occ_affine_matrix(transform::ScaledIsometry, z; scale=1.0)

Build the length-12 affine matrix that OpenCASCADE's `occ.affineTransform` expects.

OCC takes the first three rows of a 4×4 homogeneous transformation matrix, flattened in
**row-major** order — i.e. a `Vector{Float64}` of length 12 laid out as

    [ a11 a12 a13 tx,  a21 a22 a23 ty,  a31 a32 a33 tz ]

where the left 3×3 block is the linear part and the last column of each row is the
translation. A point `p` is mapped to `A * p + t`.

For our planar placement the linear block is a scaled 2D rotation/reflection embedded in 3D:

    [ m·cosφ   -m·sgn·sinφ   0 ]
    [ m·sinφ    m·sgn·cosφ   0 ]      with  m = mag(transform)·scale,  sgn = xrefl ? -1 : 1
    [   0          0         s ]            s = scale  (uniform scale also lifts z)

and the translation is `(tx, ty, z)` in model units (μm). The reflection sign convention
(`sgn` multiplying the second matrix column) matches `linearmap` in `transform.jl`, so a
reflected hook mate produces a consistently reflected solid.
"""
function _occ_affine_matrix(transform::DeviceLayout.ScaledIsometry, z; scale=1.0)
    # In-plane rotation; convert to degrees so cos(90°) is exactly zero (as in `linearmap`).
    φ = uconvert(°, DeviceLayout.rotation(transform))
    sgn = DeviceLayout.xrefl(transform) ? -1 : 1
    # `mag(transform)` follows 2D `ScaledIsometry` semantics and affects x/y only, while
    # `scale` uniformly scales all three dimensions (for example, for unit conversion).
    # Thus x/y use `mag(transform) * scale`, while z uses `scale` alone.
    # Hook-mating transforms normally have `mag(transform) == 1`.
    m = DeviceLayout.mag(transform) * scale          # combined in-plane scale
    s = scale                                        # uniform (out-of-plane) scale

    # Translation, stripped to model units (μm). `origin` may be `nothing` ⇒ no translation.
    o = DeviceLayout.origin(transform)
    tx = isnothing(o) ? 0.0 : ustrip(STP_UNIT, getx(o))
    ty = isnothing(o) ? 0.0 : ustrip(STP_UNIT, gety(o))
    tz = ustrip(STP_UNIT, z)

    c, sφ = cos(φ), sin(φ)
    # Row-major first three rows of the 4×4 homogeneous matrix: [linear 3×3 | translation].
    # Linear block = 2D scaled rotation/reflection (top-left 2×2) embedded in 3D; the z-axis
    # stays decoupled from x/y (zeros in the third row/column of the 2×2) and carries only the
    # uniform scale `s`, since a flat-on-a-surface placement never tilts the imported solid.
    return Float64[
        m * c,
        -m * sgn * sφ,
        0.0,
        tx,   # x' = m·cosφ·x − m·sgn·sinφ·y + tx
        m * sφ,
        m * sgn * c,
        0.0,
        ty,   # y' = m·sinφ·x + m·sgn·cosφ·y + ty
        0.0,
        0.0,
        s,
        tz    # z' =                    s·z  + tz
    ]
end
