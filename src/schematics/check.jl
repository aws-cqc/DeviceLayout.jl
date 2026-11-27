"""
    check!(sch::Schematic; rules=[rotations_valid])

Run each design rule in `rules` on `sch`, and set `sch.checked[] = true` if they all pass.

A rule is a function `rule(sch)` that returns `true` if `sch` satisfies it and `false`
otherwise. Rules report each violation they find by logging an `@error` describing it, so that
one `check!` reports every violation from every rule rather than stopping at the first.
As with `plan`, `build!`, and `render!`, messages go to the console and to the schematic's
log file, where they are marked with the `check` stage. A rule that throws is reported the
same way, and the remaining rules still run.

If any rule fails or logs an error, `check!` throws an error after all rules have run, and
`sch.checked[]` is `false`.

By default, checks that all checkable components have an allowed global orientation
([`rotations_valid(::Schematic)`](@ref)).
"""
function check!(sch::Schematic; rules=[rotations_valid])
    # A failed check must block `build!` even if an earlier check passed
    sch.checked[] = false
    reopen_logfile(sch, :check)
    # Reset so that rerunning `check!` reports only the current violations
    delete!(sch.logger.max_level_logged, :check)
    # Also track failures directly, since a filtering logger may never pass errors on
    failed = false
    with_logger(sch.logger) do
        for rule in rules
            passed = try
                rule(sch)
            catch e
                failed = true
                @error "Design rule `$rule` threw an error" exception =
                    (e, catch_backtrace()) _group = :check
                continue
            end
            if passed !== true
                failed = true
                @error "Schematic $(name(sch.graph)) failed design rule `$rule`" _group =
                    :check
            end
        end
    end
    close_logfile(sch)
    (failed || max_level_logged(sch, :check) >= Logging.Error) && error(
        "Schematic $(name(sch.graph)) failed design rule checks. See $(sch.logger.logname) for details."
    )
    sch.checked[] = true
    return sch
end

"""
    rotations_valid(sch::Schematic)

Verifies that all checkable components in `sch` have the right orientation in the global
coordinate system.

Returns `true` if successful. Otherwise, logs an `@error` for each component with a disallowed
orientation and returns `false`.

A component of type `T` is checkable if `check_rotation(::T) = true`.
"""
function rotations_valid(sch::Schematic)
    valid = true
    for node_idx_path in find_components(check_rotation, sch.graph)
        node = sch.graph[node_idx_path]
        comp = component(node)
        θ = rotation(transformation(sch, node_idx_path...))
        allowed = allowed_rotation_angles(comp)
        if !any(ϕ -> isapprox_angle(ϕ, θ; atol=1e-6), allowed)
            valid = false
            @error """Invalid rotation: The $(typeof(comp)) $(name(comp)) in node $(node.id) \
                has global rotation $(_degrees(θ)), but it must be one of $(join(_degrees.(allowed), ", ")).""" _group =
                :check
        end
    end
    return valid
end

# Allowed rotation angles may be plain numbers (radians) or `Unitful` angles
_degrees(θ::Unitful.Quantity) = round(typeof(1.0°), θ; digits=6)
_degrees(θ) = round(rad2deg(θ); digits=6) * °

"""
    hook_styles_match(sch::Schematic)

Verifies that every pair of fused `StyledHook`s in `sch`, including inside composite components,
has matching cross sections: the same `Paths.Style` cross section and the same metadata.
Overlays may be listed in any order.

Returns `true` if successful. Otherwise, logs an `@error` for each mismatched pair of hooks and
returns `false`. A `StyledHook` whose metadata or overlay metadata is `UNDEF_META` is a
mismatch, because its layer cannot be checked. Hooks without a style (see [`hook_style`](@ref))
are not checked.

If the path for a `RouteComponent` has not yet been built, it is built here in order to ensure
correct cross sections for length-dependent styles, then discarded, so that `build!` routes it
again and reports any routing errors. A route that throws while it is built is reported, and
its hooks are not checked.

Hooks that a composite component exposes at the ends of its routes have each route's declared
style (for a taper, the style at that end). For a route whose style varies in another way, fuse
to the hook of the component at the route's end instead.
"""
hook_styles_match(sch::Schematic) = _hook_styles_match(sch, "")

# `context` names the composite components that `sch` is nested in, for error messages
function _hook_styles_match(sch::Schematic, context)
    g = sch.graph
    # A route's path is reused once built, and `build!` would then not report routing errors
    unbuilt = filter(nodes(g)) do node
        return component(node) isa RouteComponent && isempty(component(node)._path)
    end
    match = true
    unchecked = ComponentNode[]
    try
        for node in unbuilt
            try
                path(component(node))
            catch e
                match = false
                push!(unchecked, node)
                @error "Route $(node.id)$context threw an error while it was built to check its hook styles" exception =
                    (e, catch_backtrace()) _group = :check
            end
        end
        for e in Graphs.edges(g)
            n1, n2 = g[Graphs.src(e)], g[Graphs.dst(e)]
            (n1 in unchecked || n2 in unchecked) && continue
            nodehooks = get_prop(g.graph, e, :nodehooks)
            _fused_hooks_match(sch, n1 => nodehooks[n1], n2 => nodehooks[n2], context) ||
                (match = false)
        end
    finally
        foreach(node -> empty!(component(node)._path), unbuilt)
    end
    for node in nodes(g)
        component(node) isa AbstractCompositeComponent || continue
        _hook_styles_match(
            schematic(component(node)),
            " in composite $(node.id)$context"
        ) || (match = false)
    end
    return match
end

function _fused_hooks_match(sch::Schematic, (n1, hname1), (n2, hname2), context)
    h1 = hooks(sch, n1, hname1)
    xsty1 = hook_style(h1)
    isnothing(xsty1) && return true
    h2 = hooks(sch, n2, hname2)
    xsty2 = hook_style(h2)
    isnothing(xsty2) && return true
    meta1 = hook_metadata(h1)
    meta2 = hook_metadata(h2)
    problems = String[]
    !_cross_sections_match(xsty1, xsty2) && push!(problems, "styles do not match")
    if any(is_undef_meta, _overlay_metadata(xsty1)) ||
       any(is_undef_meta, _overlay_metadata(xsty2))
        push!(problems, "overlay metadata is undefined")
    end
    if is_undef_meta(meta1) || is_undef_meta(meta2)
        push!(
            problems,
            "metadata is undefined (give each styled hook the metadata of its path, " *
            "with `StyledHook(h, style, metadata)` or the `metadata` of the `Path` it comes from)"
        )
    elseif meta1 != meta2
        push!(problems, "metadata do not match")
    end
    isempty(problems) && return true
    @error "Mismatched cross sections$context where $(n1.id) => :$hname1 is fused to $(n2.id) => :$hname2: " *
           join(problems, "; ") *
           "\n  $(n1.id) => :$hname1: $(_describe(xsty1, meta1))" *
           "\n  $(n2.id) => :$hname2: $(_describe(xsty2, meta2))" _group = :check
    return false
end

_overlay_metadata(xsty) = DeviceLayout.Meta[]
_overlay_metadata(xsty::Paths.OverlayStyle) = xsty.overlay_metadata

_describe(xsty, meta) = "$xsty, $meta"
_describe(xsty::Paths.OverlayStyle, meta) =
    "$xsty, $meta, overlay metadata $(join(xsty.overlay_metadata, ", "))"

# Compare layers, since `map_metadata!` can give `UNDEF_META` another level or index
is_undef_meta(meta) = layer(meta) == layer(DeviceLayout.UNDEF_META)

# Dimensions evaluated along a varying style or given in different units carry rounding error,
# so compare them with the same tolerance `plan` uses for hook positions
_lengths_match(a, b) = isapprox(a, b; atol=1e-6 * DeviceLayout.onenanometer(a))

_cross_sections_match(xsty1::Paths.SimpleTrace, xsty2::Paths.SimpleTrace) =
    _lengths_match(xsty1.width, xsty2.width)
_cross_sections_match(xsty1::Paths.SimpleCPW, xsty2::Paths.SimpleCPW) =
    _lengths_match(xsty1.trace, xsty2.trace) && _lengths_match(xsty1.gap, xsty2.gap)
_cross_sections_match(xsty1::Paths.SimpleNoRender, xsty2::Paths.SimpleNoRender) =
    _lengths_match(xsty1.width, xsty2.width)
_cross_sections_match(xsty1::Paths.SimpleStrands, xsty2::Paths.SimpleStrands) =
    xsty1.num == xsty2.num &&
    _lengths_match(xsty1.offset, xsty2.offset) &&
    _lengths_match(xsty1.width, xsty2.width) &&
    _lengths_match(xsty1.spacing, xsty2.spacing)
_cross_sections_match(xsty1, xsty2) = (xsty1 == xsty2)

function _cross_sections_match(xsty1::Paths.OverlayStyle, xsty2::Paths.OverlayStyle)
    _cross_sections_match(xsty1.s, xsty2.s) || return false
    length(xsty1.overlay) == length(xsty2.overlay) || return false
    # The same overlays in a different order draw the same thing
    unmatched = collect(zip(xsty2.overlay, xsty2.overlay_metadata))
    for (o1, m1) in zip(xsty1.overlay, xsty1.overlay_metadata)
        idx = findfirst(((o2, m2),) -> m1 == m2 && _cross_sections_match(o1, o2), unmatched)
        isnothing(idx) && return false
        deleteat!(unmatched, idx)
    end
    return true
end
