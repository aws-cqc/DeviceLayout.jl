######## Postrendering
function _postrender!(sm::SolidModel, operations)
    # Operations
    for (destination, op, args, kwargs...) in operations
        dimtags = op(sm, args...; kwargs...)
        sm[destination] = dimtags
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

If the `numElements` vector is not
empty, also extrude the mesh: the entries in `numElements` give the number of
elements in each layer. If the `height` vector is not empty, it provides the
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
    revolve!(g::PhysicalGroup, x, y, z, ax, ay, az, θ; num_elements=[], heights=[], recombine=false)
    revolve!(sm::SolidModel, groupname, groupdim, x, y, z, ax, ay, az, θ; num_elements=[], heights=[], recombine=false)

Extrude the entities in `g` using a rotation of `θ` radians around the axis of revolution
through `(x, y, z)` in the direction `(ax, ay, az)`.

If the `numElements` vector is not
empty, also extrude the mesh: the entries in `numElements` give the number of
elements in each layer. If the `height` vector is not empty, it provides the
(cumulative) height of the different layers, normalized to 1. If `recombine` is
set, recombine the mesh in the layers. When
the mesh is extruded the angle should be strictly smaller than 2π.

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
        object::Union{PhysicalGroup, AbstractArray{PhysicalGroup}},
        tool::Union{PhysicalGroup, AbstractArray{PhysicalGroup}};
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
        if length(dt) == 1
            @info "union_geom!(sm, $object, $d): ($object, $d) is a single entity, skipping union"
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
        remove_group!.(getindex.(sm, valid_object, d1))
    end
    if remove_tool
        remove_group!.(
            getindex.(
                sm,
                remove_object ? setdiff(valid_tool, valid_object) : valid_tool,
                d2
            )
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
        remove_group!.(getindex.(sm, valid_object, d1))
    end
    if remove_tool
        remove_group!.(
            getindex.(
                sm,
                remove_object ? setdiff(valid_tool, valid_object) : valid_tool,
                d2
            )
        )
    end
    return dt
end

"""
    restrict_to_volume(sm::SolidModel, volume)

Replace all entities and groups with their intersection with `sm[volume, 3]`.

Embeds entities if they are on the boundary of higher-dimensional entities and removes
duplicate entities.

Preserves the meaning of existing groups by assigning to them the (possibly new) entities
corresponding to that group's intersection with the volume.
"""
function restrict_to_volume!(sm::SolidModel, volume)
    dims = [3, 2, 1, 0]
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
        remove_group!.(getindex.(sm, valid_object, d1))
    end
    if remove_tool
        remove_group!.(
            getindex.(
                sm,
                remove_object ? setdiff(valid_tool, valid_object) : valid_tool,
                d2
            )
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
        remove_group!.(getindex.(sm, valid_object, d1))
    end
    if remove_tool
        remove_group!.(
            getindex.(
                sm,
                remove_object ? setdiff(valid_tool, valid_object) : valid_tool,
                d2
            )
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
    remove_group!(sm::SolidModel, group::Union{String, Symbol}, dim; recursive=true, remove_entities=false)
    remove_group!(group::AbstractPhysicalGroup; recursive=true, remove_entities=false)

Remove entities in `group` from the model, unless they are boundaries of higher-dimensional entities.

If `recursive` is true, remove all entities on their boundaries, down to dimension zero (points).

Also removes the (now-empty) physical group.
"""
function remove_group!(
    sm::SolidModel,
    group::Union{String, Symbol},
    dim;
    recursive=true,
    remove_entities=false
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

function remove_group!(group::PhysicalGroup; recursive=true, remove_entities=false)
    if remove_entities
        kernel(group).remove(dimtags(group), recursive)
    end
    gmsh.model.removePhysicalGroups([group.dim, group.grouptag])
    delete!(dimgroupdict(group.model, group.dim), group.name)
    return Tuple{Int32, Int32}[]
end

"""
    staple_bridge_postrendering(; levels=[], base, bridge, bridge_height=1μm, output="bridge_metal")

Returns a vector of postrendering operations for creating air bridges from a `base` and
`bridge` group. `levels` specifies the indices of levelwise layers to build bridges upon,
for examples `levels = [1,2]` will attempt to form airbridges on the L1 and L2 layers.
Representing air bridges as a metalic staple is a basic modeling simplification made for
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
