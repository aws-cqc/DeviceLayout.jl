"""
    Locator(p::Point)
    Locator(x, y)

A `Point` wrapper marking the position of a locator. Use `place!` to add it to
geometry structures, like any other geometry entity.
"""
struct Locator{T} <: DeviceLayout.GeometryEntity{T}
    p::DeviceLayout.Point{T}
end
Locator(x, y) = Locator(DeviceLayout.Point(x, y))

coords(loc::Locator) = loc.p

Base.convert(::Type{Locator{T}}, loc::Locator) where {T} =
    Locator(convert(DeviceLayout.Point{T}, loc.p))
Base.convert(::Type{Locator{T}}, loc::Locator{T}) where {T} = loc
Base.convert(::Type{DeviceLayout.GeometryEntity{T}}, loc::Locator) where {T} =
    convert(Locator{T}, loc)

DeviceLayout.transform(loc::Locator, f::DeviceLayout.Transformation) = Locator(f(loc.p))
DeviceLayout.to_polygons(::Locator{T}) where {T} = DeviceLayout.Polygon{T}[]

# ─── Resolution against flat geometry ────────────────────────────────────────

# A locator resolved against the flat geometry: its position in model units at its layer's
# z and, for ports, the direction of the `WithDirection`-styled layer entity containing it.
struct ResolvedLocator
    r::NTuple{3, Float64}
    meta::LocatorMeta
    direction::Union{Nothing, Vector{Float64}}
end
ResolvedLocator(r, meta::LocatorMeta) = ResolvedLocator(r, meta, nothing)

# Resolve every placed locator whose layer is part of the solid model.
function resolve_locators(flat, stack::SourceStack)
    directed = Tuple{Any, Symbol, Any}[] # (entity, layer, direction)
    placed = Tuple{Locator, LocatorMeta}[]
    for (entity, meta) in zip(elements(flat), element_metadata(flat))
        if meta isa LayerRef
            direction = DeviceLayout.extract_direction(entity)
            isnothing(direction) || push!(directed, (entity, meta.layer, direction))
        elseif meta isa LocatorMeta
            entity isa Locator || throw(
                ArgumentError(
                    "locator metadata $(nameof(typeof(meta))) must annotate a Locator " *
                    "point entity"
                )
            )
            push!(placed, (entity, meta))
        end
    end

    locators = ResolvedLocator[]
    for (loc, lm) in placed
        sourcelayer(lm, stack).solidmodel || continue
        lm isa Union{Tag, Port} &&
            any(rl -> rl.meta == lm, locators) &&
            throw(ArgumentError("duplicate locators with metadata $lm"))
        p = coords(loc)
        r = _stp_float.((getx(p), gety(p), layer_z(lm.layer, stack)))
        direction = lm isa Port ? _port_direction(lm, p, directed) : nothing
        push!(locators, ResolvedLocator(r, lm, direction))
    end
    return locators
end

# Return the direction of the single `WithDirection`-styled entity on the port's layer that
# contains `p`, as a unit vector.
function _port_direction(lm::Port, p, directed)
    matches = filter(directed) do (entity, layer, _)
        layer == lm.layer || return false
        box = bounds(entity)
        ll, ur = lowerleft(box), upperright(box)
        # containment check assumes underlying port entity is rectangular
        return (getx(ll) <= getx(p) <= getx(ur)) && (gety(ll) <= gety(p) <= gety(ur))
    end
    length(matches) == 1 || throw(
        ArgumentError(
            "port locator $lm must lie in exactly one `WithDirection`-styled entity on " *
            "layer :$(lm.layer); found $(length(matches))"
        )
    )
    turns = Float64(ustrip(°, matches[1][3])) / 180
    return Float64[cospi(turns), sinpi(turns), 0.0]
end

# ─── Selection of finalized entities ─────────────────────────────────────────

# Finalized 2D entities selected by locators: the single entity containing a tag or port
# locator, or a metal connected component together with the terminal and ground locators on
# it. Each selection is added to the model as a PG so that deduplication isolates it, and
# serialization names it after its locators.
struct Selection
    entity_tags::Vector{Int32}
    locators::Vector{ResolvedLocator}
end

function select!(
    sm::SolidModel,
    registry::LayerRegistry,
    stack::SourceStack,
    locators::Vector{ResolvedLocator}
)
    bbox_cache = Dict{Int32, NTuple{6, Float64}}()
    selections = Selection[]
    for rl in locators
        rl.meta isa Union{Tag, Port} || continue
        push!(selections, _select_surface!(sm, registry, rl, bbox_cache))
    end
    return append!(selections, _select_ccs!(sm, registry, stack, locators, bbox_cache))
end

function _entity_rtree(entity_tags, bbox_cache::Dict{Int32, NTuple{6, Float64}})
    tree = SpatialIndexing.RTree{Float64, 3}(Int32)
    isempty(entity_tags) && return tree
    function convertel(tag)
        bbox = get!(bbox_cache, tag) do
            result = SolidModels.gmsh.model.getBoundingBox(2, Int(tag))
            return convert(NTuple{6, Float64}, Tuple(result))
        end
        rect = SpatialIndexing.Rect((bbox[1:3]...,), (bbox[4:6]...,))
        return SpatialIndexing.SpatialElem(rect, nothing, tag)
    end
    SpatialIndexing.load!(tree, collect(entity_tags); convertel)
    return tree
end

# Return the tag of the coplanar entity in the tree containing the locator, or 0 if none.
function _containing_entity_tag(rl::ResolvedLocator, entity_rtree; tol=_stp_float(1nm))
    x, y, z = rl.r
    query = SpatialIndexing.Rect((x - tol, y - tol, z - tol), (x + tol, y + tol, z + tol))
    candidates = SpatialIndexing.intersects_with(entity_rtree, query)
    found_tag = Int32(0)
    count = 0
    for candidate in candidates
        tag = candidate.val
        zmin = candidate.mbr.low[3]
        zmax = candidate.mbr.high[3]
        coplanar = (abs(zmax - zmin) < tol && abs(zmin - z) < tol)
        coplanar || continue
        inside_count = SolidModels.gmsh.model.isInside(2, Int(tag), [x, y, z])
        if inside_count > 0
            count += 1
            found_tag = tag
        end
    end
    if count > 1
        error(
            "locator $(rl.meta) at $(rl.r) matched " *
            "$count entities; expected exactly 1 on a fragmented plane"
        )
    end
    return found_tag
end

function _layer_entity_tags(sm::SolidModel, registry::LayerRegistry, layer::Symbol)
    haskey(registry, layer) || return Set{Int32}()
    state = registry[layer]
    state.dim == 2 || return Set{Int32}()
    tags = Set{Int32}()
    for name in state.pgs
        union!(tags, SolidModels.entitytags(sm[name, 2]))
    end
    return tags
end

# Select the single finalized entity on the locator's layer that contains it and add it as a
# PG under that layer. The entity also belongs to a layer PG, so deduplication will isolate it
# to its own sub-PG and remove this one
function _select_surface!(
    sm::SolidModel,
    registry::LayerRegistry,
    rl::ResolvedLocator,
    bbox_cache::Dict{Int32, NTuple{6, Float64}}
)
    lm = rl.meta
    tags = _layer_entity_tags(sm, registry, lm.layer)
    isempty(tags) &&
        throw(ArgumentError("locator with metadata $lm references an unrealized 2D layer"))
    entity_tag = _containing_entity_tag(rl, _entity_rtree(tags, bbox_cache))
    iszero(entity_tag) && throw(
        ArgumentError(
            "locator with metadata $lm failed to select any entities in layer $(lm.layer)"
        )
    )
    pg_name = "__" * bytes2hex(sha1(repr(lm)))[1:16]
    sm[pg_name] = [(Int32(2), entity_tag)]
    push!(registry[lm.layer].pgs, pg_name)
    return Selection([entity_tag], [rl])
end

# Select every connected component of the METAL source layers as a PG under `:METAL_CC` and
# attach the terminal and ground locators lying on it.
function _select_ccs!(
    sm::SolidModel,
    registry::LayerRegistry,
    stack::SourceStack,
    locators::Vector{ResolvedLocator},
    bbox_cache::Dict{Int32, NTuple{6, Float64}}
)
    metal_pg_names = String[]
    for (layer_name, state) in registry
        source_layer = get(stack.layers, layer_name, nothing)
        isnothing(source_layer) && continue
        (source_layer.material == METAL && state.dim == 2) || continue
        append!(metal_pg_names, state.pgs)
    end
    isempty(metal_pg_names) && return Selection[]

    ccs = SolidModels.connected_components(sm, metal_pg_names)
    cc_names = ["METAL_CC__" * pghash(cc) for cc in ccs]
    for (cc_name, cc) in zip(cc_names, ccs)
        sm[cc_name] = cc
    end
    registry[:METAL_CC] = LayerState(cc_names, 2)

    selections = [Selection(Int32[tag for (_, tag) in cc], ResolvedLocator[]) for cc in ccs]
    tag_to_cc = Dict{Int32, Int}(tag => i for (i, cc) in enumerate(ccs) for (_, tag) in cc)
    entity_rtree = _entity_rtree(keys(tag_to_cc), bbox_cache)
    for rl in locators
        rl.meta isa Union{Terminal, Ground} || continue
        entity_tag = _containing_entity_tag(rl, entity_rtree)
        if iszero(entity_tag)
            @warn "$(rl.meta) at $(rl.r) did not match any metal connected component"
        else
            push!(selections[tag_to_cc[entity_tag]].locators, rl)
        end
    end
    for (cc_name, sel) in zip(cc_names, selections)
        isempty(sel.locators) && @warn "Metal connected component '$cc_name' has no " *
              "Terminal or Ground locator. Did you forget a Ground locator?"
    end
    return selections
end
