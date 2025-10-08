"""
    not_simulated(ent::GeometryEntity)

Return a version of `ent` that is rendered unless `simulation=true` in the rendering options.

The `simulation` option can be set as a keyword argument to `render!` or as an element in
`rendering_options` in the `Target` provided to `render!`.
"""
not_simulated(ent::GeometryEntity) =
    OptionalStyle(DeviceLayout.NoRender(), DeviceLayout.Plain(), :simulation, false)(ent)

function not_simulated!(cs::CoordinateSystem)
    not_simulated!.(cs.refs)
    cs.elements .= not_simulated.(cs.elements)
    return cs
end

function not_simulated!(csref::CoordinateSystemReference)
    not_simulated!(csref.structure)
    return csref
end

"""
    only_simulated(ent::GeometryEntity)

Return a `GeometryEntity` that is rendered if and only if `simulation=true` in the rendering options.

The `simulation` option can be set as a keyword argument to `render!` or as an element in
`rendering_options` in the `Target` provided to `render!`.
"""
only_simulated(ent::GeometryEntity) = optional_entity(ent, :simulation, default=false)

"""
    not_solidmodel(ent::GeometryEntity)

Return a version of `ent` that is rendered unless `solidmodel=true` in the rendering options.

The `solidmodel` option can be set as a keyword argument to `render!` or as an element in
`rendering_options` in the `Target` provided to `render!`.
"""
not_solidmodel(ent::GeometryEntity) =
    OptionalStyle(DeviceLayout.NoRender(), DeviceLayout.Plain(), :solidmodel, false)(ent)

function not_solidmodel!(cs::CoordinateSystem)
    not_solidmodel!.(cs.refs)
    cs.elements .= not_solidmodel.(cs.elements)
    return cs
end

function not_solidmodel!(csref::CoordinateSystemReference)
    not_solidmodel!(csref.structure)
    return csref
end

"""
    only_solidmodel(ent::GeometryEntity)

Return a `GeometryEntity` that is rendered if and only if `solidmodel=true` in the rendering options.

The `solidmodel` option can be set as a keyword argument to `render!` or as an element in
`rendering_options` in the `Target` provided to `render!`.
"""
only_solidmodel(ent::GeometryEntity) = optional_entity(ent, :solidmodel, default=false)

"""
    facing(l::Int)
    facing(s::SemanticMeta)
    facing(m::Meta)

The level facing `l` or metadata like `s` in the level facing `level(s)`.

For example, level 2 faces level 1, so `facing(2) == 1` and
`facing(SemanticMeta("lyr"; level=1)) == SemanticMeta(lyr; level=2)`

If a metadata object `m` has no layer attribute, then `facing(m) == m`.
"""
facing(l::Int) = isodd(l) ? l + 1 : l - 1
facing(s::SemanticMeta) = SemanticMeta(s, level=facing(level(s)))
facing(m::Meta) = m

"""
    backing(l::Int)
    backing(s::SemanticMeta)
    backing(m::Meta)

The level backing `l` or metadata like `s` in the level backing `level(s)`.

For example, level 3 backs level 2, so `backing(2) == 3` and
`backing(SemanticMeta("lyr"; level=2)) == SemanticMeta(lyr; level=3)`

If a metadata object `m` has no layer attribute, then `backing(m) == m`.
"""
backing(l::Int) = isodd(l) ? l - 1 : l + 1
backing(s::SemanticMeta) = SemanticMeta(s, level=backing(level(s)))
backing(m::Meta) = m

"""
    function map_metadata(comp::AbstractComponent, map_meta)

For every element in `geometry(comp)` with original meta `m`, set its metadata to `map_meta(m)`.

Recursive on referenced structures.
"""
DeviceLayout.map_metadata!(comp::AbstractComponent, map_meta) =
    map_metadata!(geometry(comp), map_meta)

"""
    flipchip!(geom::GeometryStructure)

Map all metadata in `geom` to [`facing`](@ref) copies. Recursive on referenced structures.
"""
flipchip!(geom::GeometryStructure) = map_metadata!(geom, facing)

"""
    abstract type Target

A `Target` can customize behavior during `plan`, `build!`, and/or `render!`.

Given a `target::Target`, you would use it like this:

```julia
g = SchematicGraph("example")
# ... build up schematic graph here
floorplan = plan(g, target)
check!(floorplan)
build!(floorplan, target)
output = Cell(floorplan, target)
```
"""
abstract type Target end

function map_layer(target::Target, meta::DeviceLayout.Meta)
    # memoize - if it's not already in the dict, run _map_layer and store the result
    haskey(target.map_meta_dict, meta) && return target.map_meta_dict[meta]
    res = _map_layer(target, meta)
    target.map_meta_dict[meta] = res
    return res
end

# For GDSMeta, return as-is (pass through)
_map_layer(target, meta::GDSMeta) = meta

function _map_layer(target, meta)
    (layer(meta) == layer(DeviceLayout.NORENDER_META)) && return nothing
    !(level(meta) in target.levels) && return nothing
    if !haskey(layer_record(target.technology), layer(meta))
        # Layer :GDS$(x::Int)_$(y::Int) gets mapped to GDSMeta(x,y)
        if startswith(layername(meta), "GDS")
            ld = tryparse.(Int, split(layername(meta)[4:end], "_"))
            if length(ld) == 2 && !(isnothing(ld[1]) || isnothing(ld[2]))
                return _map_level_and_index(
                    target,
                    GDSMeta(ld[1], ld[2]),
                    layer(meta),
                    level(meta),
                    layerindex(meta)
                )
            elseif length(ld) == 1 && !isnothing(ld[1]) # :GDS$(x::Int) is GDSMeta(x, 0)
                return _map_level_and_index(
                    target,
                    GDSMeta(ld[1], 0),
                    layer(meta),
                    level(meta),
                    layerindex(meta)
                )
            end
        end
        @warn "Target technology does not have a mapping for layer `:$(layer(meta))`; mapping to GDS layer/datatype 0/0"
        return GDSMeta()
    end
    gdsmeta = layer_record(target.technology)[layer(meta)]
    isnothing(gdsmeta) && return nothing
    return _map_level_and_index(target, gdsmeta, layer(meta), level(meta), layerindex(meta))
end

function _map_level_and_index(target, gdsmeta, layersym, level, index)
    if length(target.levels) > 1
        level_idx = findfirst(x -> x == level, target.levels)
        delta = level_idx - 1
        gdsmeta = GDSMeta(
            gdslayer(gdsmeta) + delta * gdslayer(target.level_increment),
            datatype(gdsmeta) + delta * datatype(target.level_increment)
        )
    end
    if layersym in target.indexed_layers
        gdsmeta = GDSMeta(gdslayer(gdsmeta), datatype(gdsmeta) + index)
    end
    return gdsmeta
end

"""
    struct LayoutTarget <: Target
        technology::ProcessTechnology
        rendering_options::NamedTuple
        levels::Vector{Int}
        level_increment::GDSMeta
        indexed_layers::Vector{Symbol}
        map_meta_dict::Dict{DeviceLayout.Meta, Union{GDSMeta,Nothing}}
    end

Contains information about how to render schematics, typically to a `Cell` (for the GDSII backend).

A `LayoutTarget` contains:

  - `technology::ProcessTechnology`: used to map semantic layers to output layers when
    `render`ing to an output format (using `layer_record(technology)`).
  - `rendering_options`: a `NamedTuple` of keyword arguments to be supplied to `render!`
  - `levels::Vector{Int}`: a list of metadata levels to be rendered
  - `level_increment::GDSMeta`: if there are multiple levels in the list, each successive level in the list will have its GDSMeta remapped by this increment
  - `indexed_layers::Vector{Symbol}`: a list of layer symbols whose entities should have GDS datatype incremented by their metadata index, for example to give distinct layers to different port boundaries for simulation
  - `map_meta_dict::Dict{SemanticMeta, Union{GDSMeta,Nothing}}`: used for memoization of the `SemanticMeta -> GDSMeta` map; it can also be populated manually to customize behavior

Rendering options might include tolerance (`atol`) or keyword flags like `simulation=true`
that determine how or whether entities with an `OptionalStyle` with the corresponding flag are rendered.

When rendering `ent::GeometryEntity` with `target::LayoutTarget`, its metadata `m` is handled as follows:

 0. If `target.map_meta_dict[m]` exists (as a `GDSMeta` instance or `nothing`), use that. This can be manually assigned before rendering, overriding the default behavior for any metadata type, including `GDSMeta`.
 1. If `m` is already a `GDSMeta` and not in `map_meta_dict`, use as is.
 2. If `layer(m) == layer(DeviceLayout.NORENDER_META)` (that is, `:norender`), use `nothing`.
 3. If `!(level(m) in target.levels)`, use `nothing`.
 4. If `layer(m)` is not present as a key in `layer_record(target.technology)` and is not of the form `:GDS<layer>_<datatype>`, then emit a warning and use `GDSMeta(0,0)`, ignoring level and layer index.
 5. If `layer(m)` is not present as a key in `layer_record(target.technology)` but is of the form `:GDS<layer>_<datatype>`, then take `GDSMeta(layer, datatype)` and add any increments according to `level(m)` and `layerindex(m)` as below.
 6. If `layer(m)` is present as a key in `layer_record(target.technology)`, then map `layer(m)` to a `GDSMeta` or `nothing` using `layer_record(target.technology)[layer(m)]`. If the result is `nothing`, use that. Otherwise, also consider `level(m)` and `layerindex(m)` as below.
 7. If `target.levels` has more than one element and `level(m)` is the `n`th element, increment the result by `(n-1)` times the GDS layer and datatype of `target.level_increment`.
 8. If `layer(m) in target.indexed_layers`, then increment the GDS datatype of the result by `layerindex(m)`.

If the result is `nothing`, then `ent` is not rendered. Here are some examples:

```jl
julia> using DeviceLayout, DeviceLayout.SchematicDrivenLayout, DeviceLayout.PreferredUnits

julia> tech = ProcessTechnology((; base_negative=GDSMeta()), (;));

julia> meta = SemanticMeta(:base_negative);

julia> cs = CoordinateSystem("test", nm);

julia> render!.(cs, Ref(Rectangle(10μm, 10μm)), [
    meta,
    facing(meta),
    SemanticMeta(:GDS2_2, index=2, level=2),
    DeviceLayout.UNDEF_META,
    DeviceLayout.NORENDER_META,
    GDSMeta(2, 2)
    ]);

julia> cell = Cell("test", nm);

julia> render!(cell, cs, ArtworkTarget(tech; levels=[1, 2], indexed_layers=[:GDS2_2]));
│ ┌ Warning: Target technology does not have a mapping for layer `:undefined`; mapping to GDS layer/datatype 0/0
│ [...]

julia> cell.element_metadata == [
    GDSMeta(), # :base_negative => GDSMeta()
    GDSMeta(300), # :base_negative => GDSMeta() => GDSMeta(300) [level increment]
    GDSMeta(302, 4), # :GDS2_2 => GDSMeta(2, 2) => GDSMeta(302, 2) [level] => GDSMeta(302, 4) [index]
    GDSMeta(), # UNDEF_META is not in the layer record, so it's mapped to GDSMeta(0, 0)
    # NORENDER_META is skipped
    GDSMeta(2, 2) # GDSMeta(2, 2) is passed through without modification
    ]
true
```
"""
struct LayoutTarget <: Target
    technology::ProcessTechnology
    rendering_options::NamedTuple
    levels::Vector{Int}
    level_increment::GDSMeta
    indexed_layers::Vector{Symbol}
    map_meta_dict::Dict{DeviceLayout.Meta, Union{GDSMeta, Nothing}}
end

"""
    SimulationTarget(technology::ProcessTechnology;
        rendering_options = (; simulation=true, artwork=false),
        levels = [1,2],
        level_increment = GDSMeta(300,0),
        indexed_layers = Symbol[],
        map_meta_dict = Dict{SemanticMeta, Union{GDSMeta,Nothing}}()
    )

A `LayoutTarget` with defaults set for simulation.
"""
SimulationTarget(
    technology::ProcessTechnology;
    rendering_options = (; simulation=true, artwork=false),
    levels            = [1, 2],
    level_increment   = GDSMeta(300, 0),
    indexed_layers    = Symbol[],
    map_meta_dict     = Dict{SemanticMeta, Union{GDSMeta, Nothing}}()
) = LayoutTarget(
    technology,
    rendering_options,
    levels,
    level_increment,
    indexed_layers,
    map_meta_dict
)

"""
    ArtworkTarget(technology::ProcessTechnology;
        rendering_options = (; simulation=false, artwork=true),
        levels = [1,2],
        level_increment = GDSMeta(300,0),
        indexed_layers = Symbol[],
        map_meta_dict = Dict{SemanticMeta, Union{GDSMeta,Nothing}}()
    )

A `LayoutTarget` with defaults set for artwork.
"""
ArtworkTarget(
    technology::ProcessTechnology;
    rendering_options = (; simulation=false, artwork=true),
    levels            = [1, 2],
    level_increment   = GDSMeta(300, 0),
    indexed_layers    = Symbol[],
    map_meta_dict     = Dict{SemanticMeta, Union{GDSMeta, Nothing}}()
) = LayoutTarget(
    technology,
    rendering_options,
    levels,
    level_increment,
    indexed_layers,
    map_meta_dict
)

"""
    render!(cs::AbstractCoordinateSystem, obj::GeometryEntity, meta::DeviceLayout.Meta,
        target::LayoutTarget; kwargs...)

Render `obj` to `cs`, with metadata mapped to layers and rendering options by `target`.
"""
function render!(
    cs::AbstractCoordinateSystem,
    obj::GeometryEntity,
    meta::DeviceLayout.Meta,
    target::LayoutTarget;
    kwargs...
)
    return render!(cs, obj, meta; _maps(target)..., kwargs...)
end

"""
    render!(cs::AbstractCoordinateSystem, cs2::GeometryStructure, target::LayoutTarget; kwargs...)

Render `cs2` to `cs`, with metadata mapped to layers and rendering options by `target`.

See [`LayoutTarget`](@ref) documentation for details.
"""
function render!(
    cs::AbstractCoordinateSystem,
    cs2::GeometryStructure,
    target::LayoutTarget;
    kwargs...
)
    return render!(cs, cs2; _maps(target)..., kwargs...)
end

"""
    Cell{S,T}(cs::CoordinateSystem, target::LayoutTarget; kwargs...) where {S,T}
    Cell{S}(cs::CoordinateSystem, target::LayoutTarget; kwargs...) where {S}
    Cell(cs::CoordinateSystem, unit::CoordinateUnits, target::LayoutTarget; kwargs...)

Create a new cell and render `cs` to it according to `target`.

See [`LayoutTarget`](@ref) documentation for details.
"""
function DeviceLayout.Cell{S}(
    cs::GeometryStructure,
    target::LayoutTarget;
    kwargs...
) where {S}
    c = Cell{S}(cs.name)
    render!(c, cs, target; kwargs...)
    return c
end
DeviceLayout.Cell(cs::GeometryStructure{S}, target::LayoutTarget; kwargs...) where {S} =
    Cell{S}(cs, target; _maps(target)..., kwargs...)
DeviceLayout.Cell(
    cs::GeometryStructure,
    unit::DeviceLayout.CoordinateUnits,
    target::LayoutTarget;
    kwargs...
) = Cell{typeof(1.0unit)}(cs, target; kwargs...)

function _maps(target::LayoutTarget)
    map_meta = (m) -> map_layer(target, m)
    return (; map_meta=map_meta, target.rendering_options...)
end
