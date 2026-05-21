######## Postrendering
function _postrender!(sm::SolidModel, operations)
    # Operations
    for (destination, op, args, kwargs...) in operations
        sm[destination] = op(sm, args...; kwargs...)
    end
end

function _fuse!(k, object, tool; tag=-1, remove_object=true, remove_tool=true)
    return _boolean_op!(
        k.fuse,
        object,
        tool;
        tag=tag,
        remove_object=remove_object,
        remove_tool=remove_tool
    )
end

function _intersect!(k, object, tool; tag=-1, remove_object=true, remove_tool=true)
    return _boolean_op!(
        k.intersect,
        object,
        tool;
        tag=tag,
        remove_object=remove_object,
        remove_tool=remove_tool
    )
end

function _cut!(k, object, tool; tag=-1, remove_object=true, remove_tool=true)
    return _boolean_op!(
        k.cut,
        object,
        tool;
        tag=tag,
        remove_object=remove_object,
        remove_tool=remove_tool
    )
end

function _fragment!(k, object, tool; tag=-1, remove_object=true, remove_tool=true)
    return _boolean_op!(
        k.fragment,
        object,
        tool;
        tag=tag,
        remove_object=remove_object,
        remove_tool=remove_tool
    )
end

function _boolean_op!(op, object, tool; tag=-1, remove_object=true, remove_tool=true)
    model(object) === model(tool) || error(
        "Physical groups $(object.name) and $(tool.name) must belong to the same model to use $op"
    )
    out_dim_tags, _ = op(
        vcat(dimtags.(object)...),
        vcat(dimtags.(tool)...),
        tag,
        remove_object,
        remove_tool
    )
    _synchronize!(model(object))
    return out_dim_tags
end

"""
    box_selection(x1, y1, z1, x2, y2, z2; dim=-1, delta=zero(x1))
    box_selection(::SolidModel, x1, y1, z1, x2, y2, z2; dim=-1, delta=zero(x1))

Get the model entities in the bounding box defined by the two points (`xmin`,
`ymin`, `zmin`) and (`xmax`, `ymax`, `zmax`). If `dim` is >= 0, return only the
entities of the specified dimension (e.g. points if `dim` == 0).

Return the selected entities as a vector of `(dimension, entity_tag)` `Tuple`s.
"""
function box_selection(x1, y1, z1, x2, y2, z2; dim=-1, delta=zero(x1))
    xmin, ymin, zmin = ustrip.(STP_UNIT, (x1, y1, z1) .- delta)
    xmax, ymax, zmax = ustrip.(STP_UNIT, (x2, y2, z2) .+ delta)
    return gmsh.model.getEntitiesInBoundingBox(xmin, ymin, zmin, xmax, ymax, zmax, dim)
end
box_selection(::SolidModel, x1, y1, z1, x2, y2, z2; dim=-1, delta=zero(x1)) =
    box_selection(x1, y1, z1, x2, y2, z2; dim=dim, delta=delta) # For use as postrender op

"""
    translate!(group, dx, dy, dz; copy=true)
    translate!(sm::SolidModel, groupname, dx, dy, dz, groupdim=2; copy=true)

Translate the entities in physical group `group` by `(dx, dy, dz)`.

If `copy=true`, then a copy of the entities in `group` are translated instead.

Return the resulting entities as a vector of `(dimension, entity_tag)` `Tuple`s.
"""
function translate!(group, dx, dy, dz; copy=true)
    dt = dimtags(group)
    k = kernel(group)
    if copy
        dt = k.copy(dt)
        _synchronize!(group.model)
    end
    k.translate(dt, ustrip.(STP_UNIT, (dx, dy, dz))...)
    _synchronize!(group.model)
    return dt
end
function translate!(sm::SolidModel, groupname, dx, dy, dz, groupdim=2; copy=true)
    if !hasgroup(sm, groupname, groupdim)
        @error "translate!(sm, $groupname, $dx, $dy, $dz, $groupdim; copy=$copy): ($groupname, $groupdim) is not a physical group."
        return Tuple{Int32, Int32}[]
    end
    return translate!(sm[groupname, groupdim], dx, dy, dz; copy=copy)
end

"""
    extrude_z!(g::PhysicalGroup, dz; num_elements=[], heights=[], recombine=false)
    extrude_z!(sm::SolidModel, groupname, dz, groupdim=2; num_elements=[], heights=[], recombine=false)

Extrude the entities in `g` in the `z` direction by `dz`.

If the `num_elements` vector is not
empty, also extrude the mesh: the entries in `num_elements` give the number of
elements in each layer. If the `heights` vector is not empty, it provides the
(cumulative) height of the different layers, normalized to 1. If `recombine` is
set, recombine the mesh in the layers.

Return the resulting entities as a vector of `(dimension, entity_tag)` `Tuple`s.
"""
function extrude_z!(g::PhysicalGroup, dz; num_elements=[], heights=[], recombine=false)
    dzu = ustrip(STP_UNIT, dz)
    return kernel(g).extrude(
        dimtags(g),
        zero(dzu),
        zero(dzu),
        dzu,
        num_elements,
        heights,
        recombine
    )
end
function extrude_z!(sm::SolidModel, groupname, dz, groupdim=2; kwargs...)
    if !hasgroup(sm, groupname, groupdim)
        @info "extrude_z!(sm, $groupname, $dz, $groupdim): ($groupname, $groupdim) is not a physical group."
        return Tuple{Int32, Int32}[]
    end
    return extrude_z!(sm[groupname, groupdim], dz; kwargs...)
end
"""
    revolve!(g::AbstractPhysicalGroup, x, y, z, ax, ay, az, θ)
    revolve!(sm::SolidModel, groupname, groupdim, x, y, z, ax, ay, az, θ)

Extrude the entities in `g` using a rotation of `θ` radians around the axis of revolution
through `(x, y, z)` in the direction `(ax, ay, az)`.

When the mesh is extruded the angle should be strictly smaller than 2π.

Return the resulting entities as a vector of `(dimension, entity_tag)` `Tuple`s.
"""
function revolve!(g::AbstractPhysicalGroup, x, y, z, ax, ay, az, θ)
    outdimtags = kernel(g).revolve(dimtags(g), x, y, z, ax, ay, az, θ)
    return outdimtags
end
function revolve!(sm::SolidModel, groupname, groupdim, args...)
    if !hasgroup(sm, groupname, groupdim)
        @error "revolve!(sm, $groupname, $groupdim, $args): ($groupname, $groupdim) is not a physical group."
        return Tuple{Int32, Int32}[]
    end
    return revolve!(sm[groupname, groupdim], args...)
end

"""
    +(object::AbstractPhysicalGroup, tool::AbstractPhysicalGroup)

Equivalent to `union_geom!(object, tool)`. Can be used as an infix (`object + tool`).
"""
Base.:+(object::AbstractPhysicalGroup, tool::AbstractPhysicalGroup) =
    union_geom!(object, tool)

"""
    ∪(object::AbstractPhysicalGroup, tool::AbstractPhysicalGroup)

Equivalent to `union_geom!(object, tool)`. Can be used as an infix (`object ∪ tool`).
"""
Base.:∪(object::AbstractPhysicalGroup, tool::AbstractPhysicalGroup) =
    union_geom!(object, tool)

"""
    -(object::AbstractPhysicalGroup, tool::AbstractPhysicalGroup)

Equivalent to `difference_geom!(object, tool)`. Can be used as an infix (`object - tool`).
"""
Base.:-(object::AbstractPhysicalGroup, tool::AbstractPhysicalGroup) =
    difference_geom!(object, tool)

"""
    *(object::AbstractPhysicalGroup, tool::AbstractPhysicalGroup)

Equivalent to `intersect_geom!(object, tool)`. Can be used as an infix (`object * tool`).
"""
Base.:*(object::AbstractPhysicalGroup, tool::AbstractPhysicalGroup) =
    intersect_geom!(object, tool)

"""
    ∩(object::AbstractPhysicalGroup, tool::AbstractPhysicalGroup)

Equivalent to `intersect_geom!(object, tool)`. Can be used as an infix (`object ∩ tool`).
"""
Base.:∩(object::AbstractPhysicalGroup, tool::AbstractPhysicalGroup) =
    intersect_geom!(object, tool)

"""
    union_geom!(
        object::Union{PhysicalGroup, AbstractArray{<:AbstractPhysicalGroup}},
        tool::Union{PhysicalGroup, AbstractArray{<:AbstractPhysicalGroup}};
        tag=-1,
        remove_object=false,
        remove_tool=false
    )

Create the geometric union (the fusion) of the groups `object` and `tool`.

Return the resulting entities as a vector of `(dimension, entity_tag)` `Tuple`s.

If `tag` is positive, try to set the tag explicitly (only valid if the boolean operation
results in a single entity). Remove the object if `remove_object` is set. Remove
the tool if `remove_tool` is set.

The operators `+` and `∪` can be used as synonymous infix operators.
"""
function union_geom!(
    object::Union{PhysicalGroup, AbstractArray{<:AbstractPhysicalGroup}},
    tool::Union{PhysicalGroup, AbstractArray{<:AbstractPhysicalGroup}};
    tag=-1,
    remove_object=false,
    remove_tool=false
)
    if !isa(kernel(object), OpenCascade)
        throw(ArgumentError("Only OpenCascade kernel supports union_geom!"))
    end
    return _fuse!(
        kernel(object),
        object,
        tool;
        tag=tag,
        remove_object=remove_object,
        remove_tool=remove_tool
    )
end

"""
    union_geom!(sm::SolidModel, object::Union{String, Symbol}, tool::Union{String, Symbol}, d1=2, d2=2;
        tag=-1,
        remove_object=false,
        remove_tool=false)

Create the geometric union of groups with `Symbol` or `String` names `object, tool` in `sm`.

Return the resulting entities as a vector of `(dimension, entity_tag)` `Tuple`s.

The dimensions of the object and tool groups can be specified as `d1` and `d2`, respectively.
The dimension defaults to 2 (surfaces).

If `tag` is positive, try to set the tag explicitly (only valid if the boolean operation
results in a single entity). Remove the object if `remove_object` is set. Remove
the tool if `remove_tool` is set.

If only one of `object` or `tool` is a physical group in `sm`, will perform union of physical group with
itself, if neither are present will return an empty array.
"""
function union_geom!(
    sm::SolidModel,
    object::Union{String, Symbol},
    tool::Union{String, Symbol},
    d1=2,
    d2=2;
    kwargs...
)
    if !hasgroup(sm, object, d1) && hasgroup(sm, tool, d2)
        @info "union_geom!(sm, $object, $tool, $d1, $d2): ($object, $d1) is not a physical group, using only ($tool, $d2)."
        return union_geom!(sm[tool, d2], sm[tool, d2]; kwargs..., remove_object=false)
    elseif hasgroup(sm, object, d1) && !hasgroup(sm, tool, d2)
        @info "union_geom!(sm, $object, $tool, $d1, $d2): ($tool, $d2) is not a physical group, using only ($object, $d1)."
        return union_geom!(sm[object, d1], sm[object, d1]; kwargs..., remove_tool=false)
    elseif !hasgroup(sm, object, d1) && !hasgroup(sm, tool, d2)
        @error "union_geom!(sm, $object, $tool, $d1, $d2): ($object, $d1) and ($tool, $d2) are not physical groups."
        return Tuple{Int32, Int32}[]
    else
        return union_geom!(sm[object, d1], get(sm, tool, d2, sm[object, d1]); kwargs...)
    end
end

union_geom!(sm::SolidModel, object, d::Int=2; remove_object=true, kwargs...) =
    union_geom!(sm, object, object, d, d; remove_object, kwargs...)

function union_geom!(
    sm::SolidModel,
    object::Union{String, Symbol},
    d::Int=2;
    remove_object=true,
    kwargs...
)
    # Check if there's only one dimtag in this group -- if so can skip!
    if !hasgroup(sm, object, d)
        @error "union_geom!(sm, $object, $d): ($object, $d) is not a physical group."
    else
        dt = dimtags(sm[object, d])
        if length(dt) <= 1
            length(dt) == 1 &&
                @info "union_geom!(sm, $object, $d): ($object, $d) is a single entity, skipping union"
            length(dt) == 0 &&
                @info "union_geom!(sm, $object, $d): ($object, $d) is empty, skipping union"
            return dt
        end
    end
    return union_geom!(sm, object, object, d, d; remove_object, kwargs...)
end

function union_geom!(
    sm::SolidModel,
    object,
    tool,
    d1=2,
    d2=2;
    remove_object=false,
    remove_tool=false,
    kwargs...
)
    object = object isa Vector ? object : [object]
    tool = tool isa Vector ? tool : [tool]
    valid_object = filter(x -> SolidModels.hasgroup(sm, x, d1), object)
    valid_tool = filter(x -> SolidModels.hasgroup(sm, x, d2), tool)
    if valid_object != object
        invalid_object = setdiff(object, valid_object)
        @info "union_geom!(sm, $object, $tool, $d1, $d2): invalid arguments ($invalid_object, $d1)"
    end
    if valid_tool != tool
        invalid_tool = setdiff(tool, valid_tool)
        @info "union_geom!(sm, $object, $tool, $d1, $d2): invalid arguments ($invalid_tool, $d2)"
    end
    if isempty(valid_object) && isempty(valid_tool)
        @error "union_geom!(sm, $object, $tool, $d1, $d2): insufficient valid arguments"
        return Tuple{Int32, Int32}[]
    end

    dt = union_geom!(
        isempty(valid_object) ? getindex.(sm, valid_tool, d2) :
        getindex.(sm, valid_object, d1),
        isempty(valid_tool) ? getindex.(sm, valid_object, d1) :
        getindex.(sm, valid_tool, d2);
        remove_object,
        remove_tool,
        kwargs...
    )

    # Actual entities were deleted as part of the operation, just empty the groups.
    if remove_object
        remove_group!.(getindex.(sm, valid_object, d1), remove_entities=false)
    end
    if remove_tool
        remove_group!.(
            getindex.(
                sm,
                remove_object ? setdiff(valid_tool, valid_object) : valid_tool,
                d2
            ),
            remove_entities=false
        )
    end
    return dt
end

"""
    intersect_geom!(
        object::Union{PhysicalGroup, AbstractArray{PhysicalGroup}},
        tool::Union{PhysicalGroup, AbstractArray{PhysicalGroup}};
        tag=-1,
        remove_object=false,
        remove_tool=false
    )

Create the geometric intersection (the common parts) of the groups `object` and `tool`.

Return the resulting entities as a vector of `(dimension, entity_tag)` `Tuple`s.

If `tag` is positive, try to set the tag explicitly (only valid if the boolean operation
results in a single entity). Remove the object if `remove_object` is set. Remove
the tool if `remove_tool` is set.

The operators `*` and `∩` can be used as synonymous infix operators.
"""
function intersect_geom!(
    object::Union{PhysicalGroup, AbstractArray{PhysicalGroup}},
    tool::Union{PhysicalGroup, AbstractArray{PhysicalGroup}};
    tag=-1,
    remove_object=false,
    remove_tool=false
)
    if !isa(kernel(object), OpenCascade)
        throw(ArgumentError("Only OpenCascade kernel supports intersect_geom!"))
    end
    return _intersect!(
        kernel(object),
        object,
        tool;
        tag=tag,
        remove_object=remove_object,
        remove_tool=remove_tool
    )
end

"""
    intersect_geom!(sm::SolidModel, object::Union{String, Symbol}, tool::Union{String, Symbol}, d1=2, d2=2;
        tag=-1,
        remove_object=false,
        remove_tool=false)

Create the geometric intersection (the common parts) of groups with `Symbol` or `String` names `object, tool` in `sm`.

Return the resulting entities as a vector of `(dimension, entity_tag)` `Tuple`s.

The dimensions of the object and tool groups can be specified as `d1` and `d2`, respectively.
The dimension defaults to 2 (surfaces).

If the `tag` is positive, try to set the tag explicitly (only valid if the boolean operation
results in a single entity). Remove the object if `remove_object` is set. Remove
the tool if `remove_tool` is set.

If `tool` or `object` are not physical groups in `sm`, will error and return an empty dimtag array.
"""
function intersect_geom!(
    sm::SolidModel,
    object::Union{String, Symbol},
    tool::Union{String, Symbol},
    d1=2,
    d2=2;
    kwargs...
)
    if !hasgroup(sm, object, d1)
        @error "intersect_geom!(sm, $object, $tool, $d1, $d2): ($object, $d1) is not a physical group."
        return Tuple{Int32, Int32}[]
    elseif !hasgroup(sm, tool, d2)
        @error "intersect_geom!(sm, $object, $tool, $d1, $d2): ($tool, $d2) is not a physical group."
        return Tuple{Int32, Int32}[]
    end
    return intersect_geom!(sm[object, d1], sm[tool, d2]; kwargs...)
end

function intersect_geom!(
    sm::SolidModel,
    object,
    tool,
    d1=2,
    d2=2;
    remove_tool=false,
    remove_object=false,
    kwargs...
)
    object = object isa Vector ? object : [object]
    tool = tool isa Vector ? tool : [tool]
    valid_object = filter(x -> SolidModels.hasgroup(sm, x, d1), object)
    valid_tool = filter(x -> SolidModels.hasgroup(sm, x, d2), tool)
    if valid_object != object
        invalid_object = setdiff(object, valid_object)
        @info "intersect_geom!(sm, $object, $tool, $d1, $d2): invalid arguments ($invalid_object, $d1)"
    end
    if valid_tool != tool
        invalid_tool = setdiff(tool, valid_tool)
        @info "intersect_geom!(sm, $object, $tool, $d1, $d2): invalid arguments ($invalid_tool, $d2)"
    end

    if isempty(valid_object) || isempty(valid_tool)
        @error "intersect_geom!(sm, $object, $tool, $d1, $d2): insufficient valid arguments"
        return Tuple{Int32, Int32}[]
    end

    dt = intersect_geom!(
        getindex.(sm, valid_object, d1),
        getindex.(sm, valid_tool, d2);
        remove_object,
        remove_tool,
        kwargs...
    )

    # Actual entities were deleted as part of the operation, just empty the groups.
    if remove_object
        remove_group!.(getindex.(sm, valid_object, d1), remove_entities=false)
    end
    if remove_tool
        remove_group!.(
            getindex.(
                sm,
                remove_object ? setdiff(valid_tool, valid_object) : valid_tool,
                d2
            ),
            remove_entities=false
        )
    end
    return dt
end

"""
    restrict_to_volume!(sm::SolidModel, volume)

Checks if all surfaces and volumes are contained within `sm[volume, 3]`, and if not performs
an intersection operation replacing all entities and groups with their intersection with
`sm[volume, 3]`.

Preserves the meaning of existing groups by assigning to them the (possibly new) entities
corresponding to that group's intersection with the volume.
"""
function restrict_to_volume!(sm::SolidModel, volume)

    # Check if the subtraction of the bounding volume from all surfaces and volumes is the
    # empty set.
    dims = SVector(3, 2, 1)
    groups =
        [(name, dimtags(pg)) for dim in dims for (name, pg) in pairs(dimgroupdict(sm, dim))]
    allents = vcat([gmsh.model.get_entities(dim) for dim in dims]...)

    out_dim_tags, _ = kernel(sm).cut(allents, dimtags(sm[volume, 3]), -1, false, false)
    isempty(out_dim_tags) && return dimtags(sm[volume, 3])

    # There were entities found after cutting, the restricting volume is a subset of the
    # rendered geometry, will need to perform the intersection.
    kernel(sm).remove(out_dim_tags, true)
    _synchronize!(sm)

    dims = SVector(3, 2, 1, 0)
    groups =
        [(name, dimtags(pg)) for dim in dims for (name, pg) in pairs(dimgroupdict(sm, dim))]
    allents = vcat([gmsh.model.get_entities(dim) for dim in dims]...)
    out_dim_tags, out_dim_tags_map =
        kernel(sm).intersect(allents, dimtags(sm[volume, 3]), -1, true, true)
    _synchronize!(sm)
    for (name, dim_tags) in groups
        isempty(dim_tags) && continue
        sm[name] = vcat((out_dim_tags_map[indexin(dim_tags, allents)])...)
    end
    return dimtags(sm[volume, 3])
end

"""
    difference_geom!(
        object::Union{PhysicalGroup, AbstractArray{PhysicalGroup}},
        tool::Union{PhysicalGroup, AbstractArray{PhysicalGroup}};
        tag=-1,
        remove_object=false,
        remove_tool=false
    )

Create the geometric difference of the groups `object` and `tool`.

Return the resulting entities as a vector of `(dimension, entity_tag)` `Tuple`s.

If `tag` is positive, try to set the tag explicitly (only valid if the boolean operation
results in a single entity). Remove the object if `remove_object` is set. Remove
the tool if `remove_tool` is set.

The operator `-` can be used as a synonymous infix operator.
"""
function difference_geom!(
    object::Union{PhysicalGroup, AbstractArray{PhysicalGroup}},
    tool::Union{PhysicalGroup, AbstractArray{PhysicalGroup}};
    tag=-1,
    remove_object=false,
    remove_tool=false
)
    if !isa(kernel(object), OpenCascade)
        throw(ArgumentError("Only OpenCascade kernel supports difference_geom!"))
    end
    return _cut!(
        kernel(object),
        object,
        tool;
        tag=tag,
        remove_object=remove_object,
        remove_tool=remove_tool
    )
end

"""
    difference_geom!(sm::SolidModel, object::Union{String, Symbol}, tool::Union{String, Symbol}, d1=2, d2=2;
        tag=-1,
        remove_object=false,
        remove_tool=false)

Create the geometric difference of groups with `Symbol` or `String` names `object, tool` in `sm`.

Return the resulting entities as a vector of `(dimension, entity_tag)` `Tuple`s.

The dimensions of the object and tool groups can be specified as `d1` and `d2`, respectively.
The dimension defaults to 2 (surfaces).

If the `tag` is positive, try to set the tag explicitly (only valid if the boolean operation
results in a single entity). Remove the object if `remove_object` is set. Remove
the tool if `remove_tool` is set.

If `object` is not a physical group in `sm`, will error and return an empty dimtag array. If
`tool` is not a physical group in `sm`, will return dimtags of `object`.
"""
function difference_geom!(
    sm::SolidModel,
    object::Union{String, Symbol},
    tool::Union{String, Symbol},
    d1=2,
    d2=2;
    kwargs...
)
    if !hasgroup(sm, object, d1)
        @error "difference_geom!(sm, $object, $tool, $d1, $d2): ($object, $d1) is not a physical group."
        return Tuple{Int32, Int32}[]
    elseif !hasgroup(sm, tool, d2)
        @info "difference_geom!(sm, $object, $tool, $d1, $d2): ($tool, $d2) is not a physical group, using only ($object, $d1)."
        return dimtags(sm[object, d1])
    end
    return difference_geom!(sm[object, d1], sm[tool, d2]; kwargs...)
end

"""
    difference_geom!(sm::SolidModel, object, tool, d1=2, d2=2; remove_tool=false,
    remove_object=false, kwargs...)

Create the geometric difference of groups `object` and `tool` which can be collections of
`Union{String, Symbol}`.
"""
function difference_geom!(
    sm::SolidModel,
    object,
    tool,
    d1=2,
    d2=2;
    remove_object=false,
    remove_tool=false,
    kwargs...
)
    object = object isa Vector ? object : [object]
    tool = tool isa Vector ? tool : [tool]
    valid_object = filter(x -> SolidModels.hasgroup(sm, x, d1), object)
    valid_tool = filter(x -> SolidModels.hasgroup(sm, x, d2), tool)
    if valid_object != object
        invalid_object = setdiff(object, valid_object)
        @info "difference_geom!(sm, $object, $tool, $d1, $d2): invalid arguments ($invalid_object, $d1)"
    end
    if valid_tool != tool
        invalid_tool = setdiff(tool, valid_tool)
        @info "difference_geom!(sm, $object, $tool, $d1, $d2): invalid arguments ($invalid_tool, $d2)"
    end

    if isempty(valid_object)
        @error "difference_geom!(sm, $object, $tool, $d1, $d2): insufficient valid arguments"
        return Tuple{Int32, Int32}[]
    end
    if isempty(valid_tool)
        return vcat(dimtags.(getindex.(sm, valid_object, d1))...)
    end

    dt = difference_geom!(
        getindex.(sm, valid_object, d1),
        getindex.(sm, valid_tool, d2);
        remove_object,
        remove_tool,
        kwargs...
    )

    # Actual entities were deleted as part of the operation, just empty the groups.
    if remove_object
        remove_group!.(getindex.(sm, valid_object, d1), remove_entities=false)
    end
    if remove_tool
        remove_group!.(
            getindex.(
                sm,
                remove_object ? setdiff(valid_tool, valid_object) : valid_tool,
                d2
            ),
            remove_entities=false
        )
    end
    return dt
end

"""
    fragment_geom!(
        object::Union{PhysicalGroup, AbstractArray{PhysicalGroup}},
        tool::Union{PhysicalGroup, AbstractArray{PhysicalGroup}};
        tag=-1,
        remove_object=false,
        remove_tool=false
    )

Create the Boolean fragments (general fuse) of the groups `object` and `tool`, making all interfaces conformal.

When applied to entities of different dimensions,
the lower dimensional entities will be automatically embedded in the higher dimensional
entities if they are not on their boundary.

Return the resulting entities as a vector of `(dimension, entity_tag)` `Tuple`s.

If `tag` is positive, try to set the tag explicitly (only valid if the boolean operation
results in a single entity). Remove the object if `remove_object` is set. Remove
the tool if `remove_tool` is set.
"""
function fragment_geom!(
    object::Union{PhysicalGroup, AbstractArray{PhysicalGroup}},
    tool::Union{PhysicalGroup, AbstractArray{PhysicalGroup}};
    tag=-1,
    remove_object=false,
    remove_tool=false
)
    if !isa(kernel(object), OpenCascade)
        throw(ArgumentError("Only OpenCascade kernel supports fragment_geom!"))
    end
    return _fragment!(
        kernel(object),
        object,
        tool;
        tag=tag,
        remove_object=remove_object,
        remove_tool=remove_tool
    )
end

"""
    fragment_geom!(sm::SolidModel, object::Union{String, Symbol}, tool::Union{String, Symbol}, d1=2, d2=2;
        tag=-1,
        remove_object=false,
        remove_tool=false)

Create the Boolean fragments (general fuse) of groups with `Symbol` or `String` names `object, tool` in `sm`, making all interfaces conformal.

When applied to entities of different dimensions,
the lower dimensional entities will be automatically embedded in the higher dimensional
entities if they are not on their boundary.

Return the resulting entities as a vector of `(dimension, entity_tag)` `Tuple`s.

The dimensions of the object and tool groups can be specified as `d1` and `d2`, respectively.
The dimension defaults to 2 (surfaces).

If the `tag` is positive, try to set the tag explicitly (only valid if the boolean operation
results in a single entity). Remove the object if `remove_object` is set. Remove
the tool if `remove_tool` is set.

If only one of `object` or `tool` is a physical group in `sm`, will perform union of physical group with
itself, if neither are present will return an empty array.
"""
function fragment_geom!(
    sm::SolidModel,
    object::Union{String, Symbol},
    tool::Union{String, Symbol},
    d1=2,
    d2=2;
    kwargs...
)
    if !hasgroup(sm, object, d1) && hasgroup(sm, tool, d2)
        @info "fragment_geom!(sm, $object, $tool, $d1, $d2): ($object, $d1) is not a physical group, using only ($tool, $d2)."
        return fragment_geom!(sm[tool, d2], sm[tool, d2]; kwargs..., remove_object=false)
    elseif hasgroup(sm, object, d1) && !hasgroup(sm, tool, d2)
        @info "fragment_geom!(sm, $object, $tool, $d1, $d2): ($tool, $d2) is not a physical group, using only ($object, $d1)."
        return fragment_geom!(sm[object, d1], sm[object, d1]; kwargs..., remove_tool=false)
    elseif !hasgroup(sm, object, d1) && !hasgroup(sm, tool, d2)
        @error "fragment_geom!(sm, $object, $tool, $d1, $d2): ($object, $d1) and ($tool, $d2) are not physical groups."
        return Tuple{Int32, Int32}[]
    else
        return fragment_geom!(sm[object, d1], get(sm, tool, d2, sm[object, d1]); kwargs...)
    end
end

fragment_geom!(sm::SolidModel, object, d::Int=2; kwargs...) =
    fragment_geom!(sm, object, object, d, d; kwargs...)

function fragment_geom!(
    sm::SolidModel,
    object,
    tool,
    d1=2,
    d2=2;
    remove_tool=false,
    remove_object=false,
    kwargs...
)
    object = object isa Vector ? object : [object]
    tool = tool isa Vector ? tool : [tool]
    valid_object = filter(x -> SolidModels.hasgroup(sm, x, d1), object)
    valid_tool = filter(x -> SolidModels.hasgroup(sm, x, d2), tool)
    if valid_object != object
        invalid_object = setdiff(object, valid_object)
        @info "fragment_geom!(sm, $object, $tool, $d1, $d2): invalid arguments ($invalid_object, $d1)"
    end
    if valid_tool != tool
        invalid_tool = setdiff(tool, valid_tool)
        @info "fragment_geom!(sm, $object, $tool, $d1, $d2): invalid arguments ($invalid_tool, $d2)"
    end

    if isempty(valid_object) && isempty(valid_tool)
        @error "fragment_geom!(sm, $object, $tool, $d1, $d2): insufficient valid arguments"
        return Tuple{Int32, Int32}[]
    end

    dt = fragment_geom!(
        isempty(valid_object) ? getindex.(sm, valid_tool, d2) :
        getindex.(sm, valid_object, d1),
        isempty(valid_tool) ? getindex.(sm, valid_object, d1) :
        getindex.(sm, valid_tool, d2);
        remove_object,
        remove_tool,
        kwargs...
    )

    # Actual entities were deleted as part of the operation, just empty the groups.
    if remove_object
        remove_group!.(getindex.(sm, valid_object, d1), remove_entities=false)
    end
    if remove_tool
        remove_group!.(
            getindex.(
                sm,
                remove_object ? setdiff(valid_tool, valid_object) : valid_tool,
                d2
            ),
            remove_entities=false
        )
    end
    return dt
end

"""
    get_boundary(group::AbstractPhysicalGroup; combined=true, oriented=true, recursive=false, direction="all", position="all")
    get_boundary(sm::SolidModel, groupname, dim=2; combined=true, oriented=true, recursive=false, direction="all", position="all")

Get the boundary of the model entities in `group`, given as a vector of (dim, tag) tuples.

Return the boundary of the individual entities (if `combined` is false) or the boundary of
the combined geometrical shape formed by all input entities (if `combined` is true).

Return tags multiplied by the sign of the boundary entity if `oriented` is true.

Apply the boundary operator recursively down to dimension 0 (i.e. to points) if `recursive`
is true.

If `direction` is specified, return only the boundaries perperdicular to the x, y, or z axis. If `position` is also specified,
return only the boundaries at the min or max position along the specified `direction`.
"""
function get_boundary(
    sm::SolidModel,
    group,
    dim=2;
    combined=true,
    oriented=true,
    recursive=false,
    direction="all",
    position="all"
)
    if !hasgroup(sm, group, dim)
        @info "get_boundary(sm, $group, $dim): ($group, $dim) is not a physical group, thus has no boundary."
        return Tuple{Int32, Int32}[]
    end
    return get_boundary(
        sm[group, dim];
        combined=combined,
        oriented=oriented,
        recursive=recursive,
        direction=direction,
        position=position
    )
end
function get_boundary(
    group::AbstractPhysicalGroup;
    combined=true,
    oriented=true,
    recursive=false,
    direction="all",
    position="all"
)
    all_bc_entities = gmsh.model.getBoundary(dimtags(group), combined, oriented, recursive)
    if direction == "all"
        return all_bc_entities
    else
        if lowercase(direction) ∉ ["all", "x", "y", "z"]
            @info "get_boundary(sm, $group): direction $direction is not all, X, Y, or Z, thus has no boundary."
            return Tuple{Int32, Int32}[]
        end
        if lowercase(position) ∉ ["all", "min", "max"]
            @info "get_boundary(sm, $group): position $position is not all, min, or max, thus has no boundary."
            return Tuple{Int32, Int32}[]
        end
        direction_map = Dict("x" => 1, "y" => 2, "z" => 3)
        direction_id = direction_map[lowercase(direction)]
        bboxes = Dict()
        for (dim, tag) in all_bc_entities
            bboxes[tag] = gmsh.model.getBoundingBox(dim, abs(tag))
        end
        target_min = minimum(bbox[direction_id] for bbox in values(bboxes))
        target_max = maximum(bbox[direction_id + 3] for bbox in values(bboxes))

        bc_entities = []
        for (dim, tag) in all_bc_entities
            bbox = bboxes[tag]
            min_val = bbox[direction_id]
            max_val = bbox[direction_id + 3]

            # Check if the boundary is perpendicular to the direction
            !isapprox(min_val, max_val, atol=1e-6) && continue

            # Check if at domain min/max position
            if lowercase(position) == "min" || lowercase(position) == "all"
                isapprox(min_val, target_min, atol=1e-6) && push!(bc_entities, (dim, tag))
            end
            if lowercase(position) == "max" || lowercase(position) == "all"
                isapprox(max_val, target_max, atol=1e-6) && push!(bc_entities, (dim, tag))
            end
        end
        return unique(bc_entities)
    end
end

"""
    set_periodic!(group1::AbstractPhysicalGroup, group2::AbstractPhysicalGroup; dim=2)
    set_periodic!(sm, group1, group2, d1=2, d2=2)

Set the model entities in `group1` and `group2` to be periodic. Only supports `d1` = `d2` = 2
and surfaces in both groups need to be parallel and axis-aligned.
"""
function set_periodic!(
    sm::SolidModel,
    group1::Union{String, Symbol},
    group2::Union{String, Symbol},
    d1=2,
    d2=2
)
    if (d1 != 2 || d2 != 2)
        @info "set_periodic!(sm, $group1, $group2, $d1, $d2) only supports d1 = d2 = 2."
        return Tuple{Int32, Int32}[]
    end
    return set_periodic!(sm[group1, d1], sm[group2, d2]; dim=d1)
end

function set_periodic!(group1::AbstractPhysicalGroup, group2::AbstractPhysicalGroup; dim=2)
    tags1 = [dt[2] for dt in dimtags(group1)]
    tags2 = [dt[2] for dt in dimtags(group2)]

    bbox1 = SolidModels.bounds3d(group1)
    bbox2 = SolidModels.bounds3d(group2)

    # Check if surfaces are aligned with x, y, or z axis
    plane1 = [isapprox(bbox1[i], bbox1[i + 3], atol=1e-6) for i = 1:3]
    plane2 = [isapprox(bbox2[i], bbox2[i + 3], atol=1e-6) for i = 1:3]

    # Set periodicity if both surfaces are perpendicular to the same axis
    dist = [0.0, 0.0, 0.0]
    for i = 1:3
        if plane1[i] && plane2[i]
            dist[i] = bbox1[i] - bbox2[i]
        end
    end
    if isapprox(sum(abs.(dist)), 0.0) || count(!iszero, dist) > 1
        @info "set_periodic! only supports distinct parallel axis-aligned surfaces."
        return Tuple{Int32, Int32}[]
    end

    gmsh.model.mesh.set_periodic(
        dim,
        tags1,
        tags2,
        [1, 0, 0, dist[1], 0, 1, 0, dist[2], 0, 0, 1, dist[3], 0, 0, 0, 1]
    )

    return vcat(dimtags(group1), dimtags(group2))
end

"""
    remove_group!(sm::SolidModel, group::Union{String, Symbol}, dim; recursive=true, remove_entities=true)
    remove_group!(group::PhysicalGroup; recursive=true, remove_entities=true)

Remove entities in `group` from the model, unless they are boundaries of higher-dimensional entities or part of another physical group.

If `recursive` is true, remove all entities on their boundaries, down to dimension zero (points).

Also removes the record of the (now-empty) physical group.

If `remove_entities` is false, only removes the record of the group from the model.
"""
function remove_group!(
    sm::SolidModel,
    group::Union{String, Symbol},
    dim;
    recursive=true,
    remove_entities=true
)
    if !hasgroup(sm, group, dim)
        @info "remove_group!(sm, $group, $dim; recursive=$recursive, remove_entities=$remove_entities): ($group, $dim) is not a physical group."
        return Tuple{Int32, Int32}[]
    end
    return remove_group!(
        sm[group, dim],
        recursive=recursive,
        remove_entities=remove_entities
    )
end

remove_group!(sm::SolidModel, group, dim; kwargs...) =
    remove_group!.(sm, group, dim; kwargs...)

function remove_group!(group::PhysicalGroup; recursive=true, remove_entities=true)
    if remove_entities
        kernel(group).remove(dimtags(group), recursive)
    end
    gmsh.model.removePhysicalGroups([group.dim, group.grouptag])
    delete!(dimgroupdict(group.model, group.dim), group.name)
    return Tuple{Int32, Int32}[]
end

"""
    connected_components(dim::Int, tags::Vector{Int32}; staple_tol=1e-6)
    connected_components(sm::SolidModel, group::Union{String, Symbol}, dim=2; staple_tol=1e-6)
    connected_components(sm::SolidModel, groups, dim=2; staple_tol=1e-6)

Find connected components among SolidModel entities at dimension `dim` with the given `tags` or physical group names.

Two entities are connected if they share any boundary entity (dimension `dim - 1`).
Uses union-find with path compression on the adjacency graph from `gmsh.model.getAdjacencies`.

For `dim == 2`, also unites entities that share a "stray" 1D entity that lies in the
interior of a 2D entity without being one of its topological boundary curves. This is
necessary even after embedding with `fragment` because OpenCascade's `getAdjacencies`
does not see the connection (a typical case is the foot edge of a "staple" air-bridge leg
landing on a ground plane). Checking stray 1D entities can be relatively slow if they exist, so
it's better to add dummy 2D entities that attach to them. Set `staple_tol=0` to disable.

Returns a `Vector{Vector{Tuple{Int32, Int32}}}` where each inner vector contains the entity dimtags
of one connected component.

# Notes

  - Requires Gmsh model to be synchronized before calling
  - Works for any dimension ≥ 1 (uses dim - 1 boundary adjacencies)
  - For dim=3 (volumes): shares boundary surfaces (dim=2)
  - For dim=2 (surfaces): shares boundary curves (dim=1)
"""
function connected_components(sm::SolidModel, groups, dim=2; kwargs...)
    tags = reduce(vcat, [entitytags(sm[name, dim]) for name in groups], init=Int32[])
    unique!(tags)
    return connected_components(dim, tags; kwargs...)
end
connected_components(sm::SolidModel, group::Union{String, Symbol}, dim=2; kwargs...) =
    connected_components(dim, entitytags(sm[group, dim]); kwargs...)

function connected_components(dim::Integer, tags::Vector{Int32}; staple_tol=1e-6)
    n = length(tags)
    isempty(tags) && return Vector{Tuple{Int32, Int32}}[]
    n == 1 && return [[(Int32(dim), only(tags))]]

    # Build adjacency: map boundary entities to parent entity indices
    boundary_to_parents = Dict{Int32, Vector{Int}}()
    for (i, tag) in enumerate(tags)
        _, downward = gmsh.model.getAdjacencies(dim, tag)
        for btag in downward
            if haskey(boundary_to_parents, btag)
                push!(boundary_to_parents[btag], i)
            else
                boundary_to_parents[btag] = [i]
            end
        end
    end

    # Union-Find with path compression
    parent = collect(1:n)
    function find(x)
        while parent[x] != x
            parent[x] = parent[parent[x]]
            x = parent[x]
        end
        return x
    end
    function unite(a, b)
        ra = find(a)
        rb = find(b)
        return ra != rb && (parent[ra] = rb)
    end

    # Merge entities that share boundary elements
    for (_, parents) in boundary_to_parents
        for j = 2:length(parents)
            unite(parents[1], parents[j])
        end
    end

    # Geometric augmentation: connect entities through stray (dim-1) entities that lie
    # on the interior of another entity's geometry without being its topological boundary.
    # Only the dim=2 / dim-1=1 case (curve in face) is handled — this catches the
    # staple-bridge foot landing on an interior of a metal plane. For dim=3, "face inside
    # volume interior" is not a typical Palace configuration so we skip it.
    if dim == 2 && staple_tol > 0
        bbox_cache = Dict{Int32, NTuple{6, Float64}}()
        get_bbox(d, t) =
            get!(bbox_cache, t) do
                return gmsh.model.getBoundingBox(d, t)
            end
        for (btag, ps) in boundary_to_parents
            length(ps) == 1 || continue
            owner_idx = ps[1]
            ebbox = gmsh.model.getBoundingBox(dim - 1, btag)
            for (j, ftag) in enumerate(tags)
                j == owner_idx && continue
                find(j) == find(owner_idx) && continue
                _bbox_contains(get_bbox(dim, ftag), ebbox; pad=staple_tol) || continue
                _curve_lies_on_face(btag, ftag; tol=staple_tol) || continue
                unite(owner_idx, j)
            end
        end
    end

    # Collect components
    components = Dict{Int, Vector{Tuple{Int32, Int32}}}()
    for (i, tag) in enumerate(tags)
        root = find(i)
        if haskey(components, root)
            push!(components[root], (dim, tag))
        else
            components[root] = [(dim, tag)]
        end
    end

    return collect(values(components))
end

# Axis-aligned bbox containment test (a contains b). `bbox` is gmsh's (xmin, ymin, zmin, xmax, ymax, zmax).
function _bbox_contains(a, b; pad::Real=0.0)
    return (a[1] - pad <= b[1]) &&
           (b[4] - pad <= a[4]) &&
           (a[2] - pad <= b[2]) &&
           (b[5] - pad <= a[5]) &&
           (a[3] - pad <= b[3]) &&
           (b[6] - pad <= a[6])
end

# Sample a 1D entity (curve) at `n_samples` parametric points and test whether each
# sample lies on the 2D entity (face) within `tol`. Two filters: (1) `getClosestPoint`
# distance ≤ tol confirms the sample is on the face's underlying surface (an infinite
# plane for a planar face — does NOT respect trim curves / holes); (2) batched
# `isInside` in parametric uv-space confirms the sample is on the *trimmed* portion
# of the face. The parametric form of `isInside` skips an internal world→parametric
# reprojection, which is the slow part on large CPW-style faces.
function _curve_lies_on_face(curve_tag::Integer, face_tag::Integer; tol, n_samples::Int=2)
    tmin, tmax = gmsh.model.getParametrizationBounds(1, curve_tag)
    isempty(tmin) && return false
    params = collect(range(Float64(tmin[1]), Float64(tmax[1]); length=n_samples))
    xyz = gmsh.model.getValue(1, curve_tag, params) # flat [x1,y1,z1,x2,y2,z2,...]
    tol2 = Float64(tol)^2
    for k = 1:n_samples
        p = @view xyz[(3k - 2):(3k)]
        closest, uv = gmsh.model.getClosestPoint(2, face_tag, p)
        d2 = (closest[1] - p[1])^2 + (closest[2] - p[2])^2 + (closest[3] - p[3])^2
        d2 > tol2 && return false
        gmsh.model.isInside(2, face_tag, uv, true) > 0 || return false
    end
    return true
end

"""
    check_port_connectivity(sm::SolidModel, port_names, metal_groups; dim=2)
        -> Dict{String, Symbol}

Classify each port in `port_names` by its connectivity to the metal regions defined by
`metal_groups`. Returns a `Dict` mapping each port name (as `String`) to one of:

  - `:short` — at least two of the port's boundary entities touch metal, and every
    metal-touching boundary lands on the same connected metal component. You can
    trace a path from one terminal of the port to another through entities in
    `metal_groups`, which would make a short circuit at DC.
  - `:open` — the port's metal-touching boundaries land on two or more disconnected
    metal components. There is no path through entities in `metal_groups` from one
    terminal of the port to the other, which would make an open circuit at DC.
  - `:floating` — fewer than two of the port's boundary entities touch metal. The
    port has at most one terminal connected to metal; if used as a Palace lumped
    port, this is generally a configuration error.
  - `:missing` — the named port group does not exist in `sm` or is empty.

Wave ports (2D exterior surface ports) are not handled specially; the `dim=2` path can still
classify them algorithmically but the results are generally not electrically meaningful.

# Arguments

  - `sm::SolidModel`: a rendered solid model. Gmsh must be synchronized (the function
    calls `SolidModels._synchronize!` defensively).
  - `port_names::AbstractVector{<:Union{AbstractString, Symbol}}`: names of port
    physical groups.
  - `metal_groups::AbstractVector{<:Union{AbstractString, Symbol}}`: names of metal
    physical groups. All listed groups are fed into a single "metal" connectivity
    question.

# Keyword arguments

  - `dim=2`: dimension of port and metal groups. `3` is appropriate for volumetric lumped
    ports in a 3D model; `2` would be used for surfaces.

# Algorithm

 1. Compute connected components of the metal groups once via
    [`connected_components`](@ref).
 2. Build a reverse map `entity tag → component index`.
 3. For each port, find its boundary entities (via `gmsh.model.getBoundary`) at
    dimension `dim - 1`, then look up adjacent entities at dimension `dim`
    (via `gmsh.model.getAdjacencies`). Count both the number of port boundary
    entities that touch metal and the number of distinct metal components reached.
    A port with fewer than two metal-touching boundaries is `:floating`; otherwise
    it is `:short` (one component) or `:open` (multiple).

See also [`connected_components`](@ref).
"""
function check_port_connectivity(sm::SolidModel, port_names, metal_groups; dim::Integer=2)
    SolidModels._synchronize!(sm)

    # Build connected-components tag → component-index map.
    tag_to_comp = Dict{Int32, Int}()
    if !isempty(metal_groups)
        comps = connected_components(sm, metal_groups, dim)
        for (ci, comp_dimtags) in enumerate(comps)
            for (_, tag) in comp_dimtags
                tag_to_comp[tag] = ci
            end
        end
    end

    results = Dict{String, Symbol}()
    for pn in port_names
        pn_s = string(pn)
        if !SolidModels.hasgroup(sm, pn_s, dim)
            results[pn_s] = :missing
            continue
        end
        port_tags = SolidModels.entitytags(sm[pn_s, dim])
        if isempty(port_tags)
            results[pn_s] = :missing
            continue
        end
        # Boundary faces of the port volume(s).
        port_dimtags = Tuple{Int32, Int32}[(Int32(dim), t) for t in port_tags]
        # getBoundary(dimtags, combined, oriented, recursive)
        boundary = gmsh.model.getBoundary(port_dimtags, false, false, false)
        touched = Set{Int}()
        n_touching_boundaries = 0
        for (bd, bt) in boundary
            # `bt` may be signed (Gmsh convention); use absolute value as the tag.
            upward, _ = gmsh.model.getAdjacencies(bd, abs(bt))
            comps_here = Set{Int}()
            for neighbor in upward
                # Skip the port's own volumes.
                (neighbor in port_tags) && continue
                ci = get(tag_to_comp, neighbor, 0)
                ci == 0 && continue
                push!(comps_here, ci)
            end
            if !isempty(comps_here)
                n_touching_boundaries += 1
                union!(touched, comps_here)
            end
        end
        # A Palace lumped port needs two terminals on metal; a single metal-touching
        # boundary is treated as :floating regardless of how many components it reaches.
        results[pn_s] =
            n_touching_boundaries < 2 ? :floating : length(touched) == 1 ? :short : :open
    end
    return results
end

"""
    check_overlap(sm::SolidModel)

Check for overlap/intersections between SolidModel groups of the same dimension.
Intersections (if any) for entities of dimension dim should have dim-1. Otherwise it means there is overlap.

Return the overlapping groups as a vector of `(group1, group2, dimension)` `Tuple`s.
"""
function check_overlap(sm::SolidModel)
    overlapping_groups = Tuple{String, String, Int}[]
    for dim = 1:3
        for (name1, pg1) in SolidModels.dimgroupdict(sm, dim)
            for (name2, pg2) in SolidModels.dimgroupdict(sm, dim)
                name1 >= name2 && continue
                (
                    isempty(SolidModels.entitytags(pg1)) ||
                    isempty(SolidModels.entitytags(pg2))
                ) && continue
                intersections = intersect_geom!(sm, name1, name2, dim, dim)
                for intersection in intersections
                    if intersection[1] > dim - 1
                        @warn "Overlap of SolidModel groups $name1 and $name2 of dimension $dim."
                        push!(overlapping_groups, (name1, name2, dim))
                    end
                end
            end
        end
    end
    return overlapping_groups
end

"""
    staple_bridge_postrendering(; levels=[], base, bridge, bridge_height=1μm, output="bridge_metal")

Returns a vector of postrendering operations for creating air bridges from a `base` and
`bridge` group. `levels` specifies the indices of levelwise layers to build bridges upon,
for examples `levels = [1,2]` will attempt to form airbridges on the L1 and L2 layers.
Representing air bridges as a metallic staple is a basic modeling simplification made for
purposes of simulation. The support and bridge shapes are intersected to form a bridge
platform which is then connected to the underlying surface with legs which run parallel to
the path.

```
           ______
         >|      |< support
     _____|      |_____
  > |                  |< bridge
  > |_____        _____|
        > |      |
        > |______|
           > /\
           > ||
           > ||< path
```

Outputs a 2D physical group named `output` ("bridge_metal" by default) containing the rectangular
bridge "legs" and "platform".
"""
function staple_bridge_postrendering(;
    levels=[],
    base,
    bridge,
    bridge_height=1μm,
    output="bridge_metal"
)
    steps = Vector{
        Tuple{
            String,
            Function,
            Tuple{String, Any, Vararg{Number}},
            Vararg{Pair{Symbol, Bool}}
        }
    }()

    if isempty(levels)
        append!(
            steps,
            [
                ("_shadow", SolidModels.intersect_geom!, (bridge, base)),
                ("_platform", SolidModels.translate!, ("_shadow", 0μm, 0μm, bridge_height)),
                (
                    "_foot",
                    SolidModels.difference_geom!,
                    (bridge, base),
                    :remove_object => true,
                    :remove_tool => true
                ),
                ("_shadow_bdy", SolidModels.get_boundary, ("_shadow", 2)),
                ("_foot_bdy", SolidModels.get_boundary, ("_foot", 2)),
                ("_leg", SolidModels.intersect_geom!, ("_shadow_bdy", "_foot_bdy", 1, 1)),
                ("_leg", SolidModels.extrude_z!, ("_leg", bridge_height, 1)),
                (
                    "_removed",
                    SolidModels.remove_group!,
                    ("_shadow", 2),
                    :remove_entities => true
                ),
                (
                    "_removed",
                    SolidModels.remove_group!,
                    ("_foot", 2),
                    :remove_entities => true
                ),
                # Combine into bridge metal
                (
                    output,
                    SolidModels.union_geom!,
                    ("_leg", "_platform", 2, 2),
                    :remove_tool => true,
                    :remove_object => true
                )
            ]
        )
        return steps
    end

    for l ∈ levels
        append!(
            steps,
            [
                (
                    "_shadow_L$l",
                    SolidModels.intersect_geom!,
                    (bridge * "_L$l", base * "_L$l")
                ),
                (
                    "_platform_L$l",
                    SolidModels.translate!,
                    # Even layers (0 and 2), are translated downwards.
                    ("_shadow_L$l", 0μm, 0μm, l % 2 == 1 ? bridge_height : -bridge_height)
                ),
                (
                    "_foot_L$l",
                    SolidModels.difference_geom!,
                    (bridge * "_L$l", base * "_L$l"),
                    :remove_object => true,
                    :remove_tool => true
                ),
                ("_shadow_bdy_L$l", SolidModels.get_boundary, ("_shadow_L$l", 2)),
                ("_foot_bdy_L$l", SolidModels.get_boundary, ("_foot_L$l", 2)),
                (
                    "_leg_L$l",
                    SolidModels.intersect_geom!,
                    ("_shadow_bdy_L$l", "_foot_bdy_L$l", 1, 1)
                ),
                # Even layers (0 and 2), are extruded downwards.
                (
                    "_leg_L$l",
                    SolidModels.extrude_z!,
                    ("_leg_L$l", l % 2 == 1 ? bridge_height : -bridge_height, 1)
                ),
                (
                    "_removed",
                    SolidModels.remove_group!,
                    ("_shadow_L$l", 2),
                    :remove_entities => true
                ),
                (
                    "_removed",
                    SolidModels.remove_group!,
                    ("_foot_L$l", 2),
                    :remove_entities => true
                ),
                (
                    "$(output)_L$l",
                    SolidModels.union_geom!,
                    ("_leg_L$l", "_platform_L$l", 2, 2),
                    :remove_tool => true,
                    :remove_object => true
                ),
                # Fold into bridge metal
                (
                    output,
                    SolidModels.union_geom!,
                    (output, "$(output)_L$l", 2, 2),
                    :remove_tool => true
                )
            ]
        )
    end
    return steps
end
