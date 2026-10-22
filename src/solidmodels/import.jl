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

    gmsh.model.set_current(name(sm))
    is_xao = lowercase(splitext(filename)[2]) == ".xao"
    if is_xao
        new_dimtags, file_groups, own_groups = _merge_xao!(sm, filename)
    else
        # Import into this model's OCC kernel, scaled while reading: OCC's own scaling keeps
        # analytic surfaces, which a later `dilate` would turn into BSplines.
        new_dimtags = _with_gmsh_option("Geometry.OCCScaling", scale) do
            return gmsh.model.occ.importShapes(filename, true, format)
        end
    end

    # Reposition the freshly imported entities in place (OCC-kernel operations, so no
    # synchronize is needed until we assign the physical group below).
    _place_imported!(new_dimtags, transform, z; scale=is_xao ? scale : 1.0)

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
        # `merge` returns entities of every dimension, and all of them are transformed above
        # so that the file's lower-dimensional groups keep their tags. Only the solids are
        # returned and registered.
        if !isempty(new_dimtags)
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
