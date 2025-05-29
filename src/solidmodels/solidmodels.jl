module SolidModels

import Gmsh: gmsh, gmsh.model.occ
export gmsh

import DeviceLayout
import DeviceLayout:
    AbstractCoordinateSystem,
    AbstractPolygon,
    ClippedPolygon,
    Coordinate,
    CoordinateSystem,
    CurvilinearPolygon,
    CurvilinearRegion,
    GeometryEntity,
    GeometryEntityStyle,
    Ellipse,
    Meta,
    MeshSized,
    NoRender,
    OptionalStyle,
    Paths,
    Plain,
    Polygon,
    StyledEntity,
    Point,
    save,
    getx,
    gety,
    points,
    pathtopolys,
    perimeter,
    flatten,
    dimension,
    elements,
    element_metadata,
    to_polygons,
    layer,
    level,
    norm,
    render!,
    uniquename
import DeviceLayout.Paths: trace, gap, offset, extent, pathlength, bspline_approximation
import DeviceLayout.Polygons:
    RelativeRounded,
    Rounded,
    orientation,
    StyleDict,
    cornerindices,
    perimeter,
    center,
    angle,
    r1,
    r2,
    radius
import Unitful: μm, mm, ustrip, °, uconvert, Length
import FileIO: File

import SpatialIndexing
import SpatialIndexing: RTree

# Units that all dimensions will be converted to before rendering to STP
const STP_UNIT = μm

abstract type AbstractPhysicalGroup end
const DimGroupDict = Dict{String, AbstractPhysicalGroup}

Base.broadcastable(p::AbstractPhysicalGroup) = Ref(p)

"""
    abstract type SolidModelKernel

Supertype for solid geometry kernels. Subtypes are `OpenCascade` and `GmshNative`.

Note that `GmshNative` does not support Boolean geometry operations.
"""
abstract type SolidModelKernel end
struct OpenCascade <: SolidModelKernel end
struct GmshNative <: SolidModelKernel end

Base.broadcastable(x::SolidModelKernel) = Ref(x)

kernelmodule(::OpenCascade) = gmsh.model.occ
kernelmodule(::GmshNative) = gmsh.model.geo

function Base.getproperty(k::SolidModelKernel, s::Symbol)
    return getproperty(kernelmodule(k), s)
end

function Base.propertynames(k::SolidModelKernel)
    return propertynames(kernelmodule(k))
end

"""
    struct SolidModel{T} where {T <: SolidModelKernel}
        name::String
        groups::NTuple{4,Dict{String,AbstractPhysicalGroup}}
    end
    SolidModel(name::String, kernel=OpenCascade; overwrite=false)

A 3D geometry model.

Geometry rendering, boolean operations, and export are provided by the specified `kernel`.

Physical groups can be accessed by name using indexing with a `String` or `Symbol` and a
dimension: `mymodel["mygroup", 3]` will return the `PhysicalGroup` with dimension 3 called
`mygroup`.

Physical groups can also be assigned as `mymodel["mygroup"] = dimtags`, where `dimtags`
is a list of `NTuple{2, Int32}` of entities identified by `(dim, tag)` in `mymodel`.
If `dimtags` includes entities of multiple dimensions, then a group is created for each
dimension.

If the constructor is called with `overwrite=false` (the default), then an error will be thrown if a
model with the same name already exists. If `overwrite=true`, then any existing model
with the same name will be deleted and a new model will be created.

A `SolidModel` can be saved to a file with `FileIO.save(filename, sm)`.
Supported filetypes for OpenCASCADE geometries are `.brep` and `.stp`.
Meshes can be exported as `.msh2` (compatible with Palace) or `.msh` (most recent Gmsh format) files.
Other filetypes supported by `gmsh.write()` like `.xao` can be used with `DeviceLayout.save`.
"""
struct SolidModel{T <: SolidModelKernel}
    name::String
    groups::NTuple{4, DimGroupDict}
    kernel::T

    function SolidModel(
        name::String,
        kernel::SolidModelKernel=OpenCascade();
        overwrite=false
    )
        iszero(gmsh.is_initialized()) && gmsh.initialize()
        # SolidModel initiated gmsh uses μm
        gmsh.option.set_string("Geometry.OCCTargetUnit", "UM")

        # If a model with this name exists, throw error or delete it
        names = gmsh.model.list()
        if name in names
            !overwrite && error(
                "Gmsh model $name already exists; use SolidModel($name; overwrite=true) to overwrite"
            )
            gmsh.model.set_current(name) # Activate the old model "name"
            gmsh.model.remove() # Remove the old model
        end
        gmsh.model.add(name) # Add and set as current model

        return new{typeof(kernel)}(
            name,
            (DimGroupDict(), DimGroupDict(), DimGroupDict(), DimGroupDict()),
            kernel
        )
    end
end
Base.broadcastable(x::SolidModel) = Ref(x)

"""
    struct PhysicalGroup
        name::String
        model::SolidModel
        dim::Int32
        grouptag::Int32
    end

A named group of entities of dimension `dim` in a `SolidModel`.
"""
struct PhysicalGroup <: AbstractPhysicalGroup
    name::String
    model::SolidModel
    dim::Int32
    grouptag::Int32
end

summary(pg::PhysicalGroup) =
    "Physical Group $(pg.name) of dimension $(pg.dim) with $(length(dimtags(pg))) entities"
Base.show(io::IO, pg::PhysicalGroup) = print(io, summary(pg))

"""
    entitytags(pg::AbstractPhysicalGroup)

Return the integer tags for `SolidModel` entities in `pg`.
"""
function entitytags(pg::AbstractPhysicalGroup)
    if (pg.dim, pg.grouptag) in gmsh.model.getPhysicalGroups(pg.dim)
        return gmsh.model.getEntitiesForPhysicalGroup(pg.dim, pg.grouptag)
    end
    return Int32[]
end

"""
    dimtags(pg::AbstractPhysicalGroup)

Return the `(dimension, integer tag)` tuples for `SolidModel` entities in `pg`.
"""
dimtags(pg::AbstractPhysicalGroup) = [(pg.dim, tag) for tag in entitytags(pg)]
dimtags(groups::Vector{<:AbstractPhysicalGroup}) = vcat(dimtags.(groups))

name(pg::PhysicalGroup) = pg.name

name(sm::SolidModel) = sm.name
kernel(sm::SolidModel) = sm.kernel
kernel(pg::AbstractPhysicalGroup) = kernel(pg.model)
function kernel(pg::AbstractArray{<:AbstractPhysicalGroup})
    isempty(pg) && error("Cannot establish kernel for empty array.")
    return kernel(pg[1].model)
end
model(pg::PhysicalGroup) = pg.model
function model(pg::AbstractArray{<:AbstractPhysicalGroup})
    isempty(pg) && error("Cannot establish model for empty array.")
    return model(pg[1])
end

_synchronize!(sm::SolidModel) = kernel(sm).synchronize()

### SolidModel API
"""
    dimgroupdict(sm::SolidModel, dim::Int)

The `PhysicalGroup`s of dimension `dim` in `sm`, as a `DimGroupDict` (alias for `Dict{String, PhysicalGroup}`).
"""
dimgroupdict(sm::SolidModel, dim::Integer) = sm.groups[dim + 1]

"""
    getindex(sm::SolidModel, name::String, dim::Int)

Get the `PhysicalGroup` with name `name` and dimension `dim`.
"""
function Base.getindex(sm::SolidModel, name::String, dim::Integer)::PhysicalGroup
    return dimgroupdict(sm, dim)[name]
end
Base.getindex(sm::SolidModel, name::Symbol, dim) = getindex(sm, string(name), dim)

"""
    hasgroup(sm::SolidModel, name::String, dim::Integer)

Return `true` if `sm` has a group of dimension `dim` named `name`, and return `false` otherwise.
"""
function hasgroup(sm::SolidModel, name::String, dim::Integer)
    return haskey(dimgroupdict(sm, dim), name)
end
hasgroup(sm::SolidModel, name::Symbol, dim::Integer) = hasgroup(sm, string(name), dim)

"""
    setindex!(sm::SolidModel, dimtags, name::String)

Create a `PhysicalGroup` with name `name` and `(dim, tag)` integer pairs `dimtags`.

If `dimtags` contains elements of different dimensions, a group is created for each
dimension.

If any groups with the same name and dimension already exists, they will be removed and replaced
with the new groups. (No entities are deleted, just the group entries.)
"""
function Base.setindex!(sm::SolidModel, dimtags, groupname::String)
    gmsh.model.set_current(name(sm))
    _synchronize!(sm) # Need to synchronize to add elements to physical group
    # Set the group for each dimension
    for dim in unique(first.(dimtags))
        tags = last.(dimtags[first.(dimtags) .== dim])
        if hasgroup(sm, groupname, dim)
            pg = sm[groupname, dim]
            gmsh.model.remove_physical_groups([(dim, pg.grouptag)])
        end
        tag = gmsh.model.addPhysicalGroup(dim, tags, -1, groupname)
        dimgroupdict(sm, dim)[groupname] = PhysicalGroup(groupname, sm, dim, tag)
        gmsh.model.setPhysicalName(dim, tag, groupname)
    end
end
Base.setindex!(sm::SolidModel, dimtags, name::Symbol) = setindex!(sm, dimtags, string(name))

"""
    get(sm::SolidModel, name, dim, default::AbstractPhysicalGroup)

Get the `PhysicalGroup` with name `name` and dimension `dim` or return `default`.
"""
function Base.get(sm::SolidModel, name, dim, default::AbstractPhysicalGroup)
    return hasgroup(sm, name, dim) ? sm[name, dim] : default
end

"""
    save(file::File, sm::SolidModel)
    save(filename::String, sm::SolidModel)

Save a `SolidModel` instance to a `file` or `filename`.

Using `FileIO.save`, supported filetypes using for OpenCASCADE geometries are `.brep` and `.stp`.
Meshes can be exported as `.msh2` (compatible with Palace) or `.msh` (most recent Gmsh format) files.

Using `DeviceLayout.save`, you can also choose any other extension supported by `gmsh.write()` like `.xao`.
"""
function save(file::File, sm::SolidModel)
    gmsh.model.set_current(name(sm))
    _synchronize!(sm)
    return gmsh.write(file.filename)
end
function save(filename::String, sm::SolidModel)
    gmsh.model.set_current(name(sm))
    _synchronize!(sm)
    return gmsh.write(filename)
end

"""
    bounds3d(group::AbstractPhysicalGroup; delta=0)
    bounds3d(dimtags; delta=0)

Return the rectangular prism defined bounding `group` or `dimtags` with an offset of `delta`.

Note that OpenCASCADE bounding boxes are not tight, and will typically extend beyond the exact
bounding box by 1e-7μm at each face.

The result is returned as the tuple `(xmin, ymin, zmin, xmax, ymax, zmax)`.
"""
function bounds3d(group::AbstractPhysicalGroup; delta=0)
    return bounds3d(dimtags(group), delta=delta)
end

function bounds3d(dims_tags; delta=0)
    xmin, ymin, zmin = Inf, Inf, Inf
    xmax, ymax, zmax = -Inf, -Inf, -Inf
    for (dim, tag) in dims_tags
        x1, y1, z1, x2, y2, z2 = gmsh.model.getBoundingBox(dim, tag)
        xmin = min(xmin, x1)
        ymin = min(ymin, y1)
        zmin = min(zmin, z1)
        xmax = max(xmax, x2)
        ymax = max(ymax, y2)
        zmax = max(zmax, z2)
    end
    return xmin - delta,
    ymin - delta,
    zmin - delta,
    xmax + delta,
    ymax + delta,
    zmax + delta
end

"""
    reindex_physical_groups!(sm::SolidModel)

Reassign all physical group tags so that the numbering is 1-based and contiguous. This is
not necessary for the mesh to be valid, but helps with human readability in generated config files.
"""
function reindex_physical_groups!(sm::SolidModel)
    # Create a copy of all entity tags in each physical group, then delete them.
    dim_name_to_tag = Vector{Tuple{Int, String, Vector{Int}}}()
    for dim = 3:-1:0
        for (n, _) ∈ dimgroupdict(sm, dim)
            push!(dim_name_to_tag, (dim, n, entitytags(sm[n, dim])))
            gmsh.model.remove_physical_groups([(dim, dimgroupdict(sm, dim)[n].grouptag)])
        end
    end

    # Sort with descending integer, then in alphabetical
    function comparator(x, y)
        if x[1] > y[1]
            return true
        elseif x[1] < y[1]
            return false
        else
            return x[2] < y[2]
        end
    end
    sort!(dim_name_to_tag, lt=comparator)

    # Re-add physical groups
    grouptag = 1
    for (dim, n, tags) ∈ dim_name_to_tag
        newtag = gmsh.model.add_physical_group(dim, tags, grouptag, n)
        @assert newtag == grouptag
        dimgroupdict(sm, dim)[n] = PhysicalGroup(n, sm, dim, grouptag)
        grouptag = grouptag + 1
    end
end

"""
    attributes(sm::SolidModel)

Given a `SolidModel` construct a dictionary from physical group name to attribute number for
use in specification of a configuration file for use with *Palace*.
"""
function attributes(sm::SolidModel)
    attributes = Dict{String, Int}()
    for d = 0:3
        for (k, v) ∈ dimgroupdict(sm, d)
            attributes[k] = v.grouptag
        end
    end
    return attributes
end

include("render.jl")
include("postrender.jl")

end # module
