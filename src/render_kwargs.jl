# Keywords declared by the method that runs the check never reach it, so they need no entry.
# The names are not specific to the destination, so a built-in flag passed to a target that
# ignores it does not warn.
mutable struct _RenderKwargNames
    # Each set is replaced rather than mutated, so `render!` reads them without the lock
    @atomic known::Set{Symbol}
    # Not `maxlog`: the file sink of a schematic's log ignores it, and the check runs per entity
    @atomic warned::Set{Symbol}
end
const _RENDER_KWARG_NAMES = _RenderKwargNames(
    Set{Symbol}([
        # Entity conversion (`to_polygons`, `SolidModels.to_primitives`)
        :atol,
        :rtol,
        :Δθ,
        :rounded,
        # Forwarded to each entity when rendering to a `Cell`
        :map_meta,
        :memoized_cells,
        # Flags of the built-in `OptionalStyle`s, set by targets
        :simulation,
        :artwork,
        :solidmodel
    ]),
    Set{Symbol}()
)
# `OptionalStyle`s register their flags, and geometry may be built on several threads
const _RENDER_KWARGS_LOCK = ReentrantLock()

"""
    DeviceLayout.register_render_kwarg!(s::Symbol)

Declare `s` a valid keyword argument for `render!`, so that passing it does not warn.

`render!` warns about each keyword argument it does not recognize, once per session and once
per render of a `Schematic`.
Constructing an [`OptionalStyle`](@ref) registers its flag automatically. Call this for a
custom option read some other way, for example by a `to_polygons` method for your own style.

A package that constructs an `OptionalStyle` at top level should call this for the flag in
its `__init__`, because registrations made while precompiling are not kept.
"""
function register_render_kwarg!(s::Symbol)
    s in (@atomic _RENDER_KWARG_NAMES.known) && return nothing
    @lock _RENDER_KWARGS_LOCK begin
        known = @atomic _RENDER_KWARG_NAMES.known
        @atomic _RENDER_KWARG_NAMES.known = push!(copy(known), s)
    end
    return nothing
end

function warn_unknown_render_kwargs(kwargs, caller=:render!)
    _all_known_or_warned(kwargs) && return nothing
    unknown = @lock _RENDER_KWARGS_LOCK begin
        warned = @atomic _RENDER_KWARG_NAMES.warned
        new = setdiff(keys(kwargs), @atomic(_RENDER_KWARG_NAMES.known), warned)
        isempty(new) || @atomic _RENDER_KWARG_NAMES.warned = union(warned, new)
        new
    end
    for k in unknown
        @warn "`$caller` does not recognize the keyword argument `$k`, which may have no effect. Check the spelling, or register a custom rendering option with `DeviceLayout.register_render_kwarg!(:$k)`."
    end
    return nothing
end

# Called by each `Schematic` render, so that every schematic's log and `strict=:warn` see the
# warning
function reset_render_kwarg_warnings!()
    @lock _RENDER_KWARGS_LOCK begin
        @atomic _RENDER_KWARG_NAMES.warned = Set{Symbol}()
    end
    return nothing
end

function _all_known_or_warned(kwargs)
    known = @atomic _RENDER_KWARG_NAMES.known
    warned = @atomic _RENDER_KWARG_NAMES.warned
    for k in keys(kwargs)
        (k in known || k in warned) || return false
    end
    return true
end
