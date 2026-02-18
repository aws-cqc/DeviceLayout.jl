using Unitful
import Unitful: °, rad
export °, rad

import Preferences: @load_preference, @set_preferences!, load_preference, set_preferences!

module PreferNanometers
import Unitful
syms = (:fm, :pm, :nm, :μm, :mm, :cm, :dm, :m)
for s in syms
    eval(:(const $s = Unitful.ContextUnits(Unitful.$s, Unitful.nm)))
    eval(Expr(:export, s))
end
const UPREFERRED = nm
@doc """
    const PreferNanometers.UPREFERRED = $nm

Constant for DeviceLayout.jl compiled with `units = "PreferNanometers"` in `LocalPreferences.toml`.

Default value if no preference specified. Other options are `PreferMicrons` and `NoUnits`.
""" UPREFERRED
export UPREFERRED
end

module PreferMicrons
import Unitful
syms = (:fm, :pm, :nm, :μm, :mm, :cm, :dm, :m)
for s in syms
    eval(:(const $s = Unitful.ContextUnits(Unitful.$s, Unitful.μm)))
    eval(Expr(:export, s))
end
const UPREFERRED = μm
@doc """
    const PreferMicrons.UPREFERRED = $μm

Constant for DeviceLayout.jl compiled with `units = "PreferMicrons"` in `LocalPreferences.toml`.

Other options are `PreferNanometers` (the default) and `NoUnits`.
""" UPREFERRED
export UPREFERRED
end

module PreferNoUnits
import Unitful
syms = (:fm, :pm, :nm, :μm, :mm, :cm, :dm, :m)
for s in syms
    eval(:(const $s = Unitful.$s))
    eval(Expr(:export, s))
end
const UPREFERRED = Unitful.NoUnits
@doc """
    const UPREFERRED = Unitful.NoUnits

Constant for DeviceLayout.jl compiled with `units = "NoUnits"` in LocalPreferences.toml.

Other options are `PreferNanometers` (the default) and `PreferMicrons`.
""" UPREFERRED
export UPREFERRED
end

function ForwardDiff.derivative(f, x::Unitful.Length)
    ux = Unitful.ustrip(x)
    ox = one(ux)
    T = typeof(ForwardDiff.Tag(nothing, typeof(ux)))
    r = f(Unitful.unit(x) * ForwardDiff.Dual{T}(ux, ox)) ./ oneunit(x)
    return ForwardDiff.extract_derivative(T, r)
end

ForwardDiff.extract_derivative(::Type{T}, x::Quantity) where {T} =
    ForwardDiff.extract_derivative(T, Unitful.ustrip(x)) * Unitful.unit(x)

const unit_preference = @load_preference("units", "PreferNanometers")

@static if unit_preference == "PreferMicrons"
    using .PreferMicrons
    const PreferredUnits = PreferMicrons
elseif unit_preference == "PreferNanometers"
    using .PreferNanometers
    const PreferredUnits = PreferNanometers
else # unit_preference == "NoUnits"
    using .PreferNoUnits
    const PreferredUnits = PreferNoUnits
end
@doc """
    module PreferredUnits

Module exporting `fm, pm, nm, μm, mm, cm, dm, m`.

Mixed unit operations with these imports will be converted based on the unit
preference set by [`DeviceLayout.set_unit_preference!`](@ref) (default `nm`).
""" PreferredUnits

onemicron(v::T) where {T <: Unitful.Length} =
    one(T) * Unitful.ContextUnits(Unitful.μm, Unitful.unit(Unitful.upreferred(v)))
onemicron(T::Type{<:Unitful.Length}) =
    one(T) * Unitful.ContextUnits(Unitful.μm, Unitful.upreferred(Unitful.unit(T)))
onemicron(T::Type{<:Real}) = one(T)
onemicron(v::Real) = one(v)

onenanometer(v::T) where {T <: Unitful.Length} =
    one(T) * Unitful.ContextUnits(Unitful.nm, Unitful.unit(Unitful.upreferred(v)))
onenanometer(T::Type{<:Unitful.Length}) =
    one(T) * Unitful.ContextUnits(Unitful.nm, Unitful.upreferred(Unitful.unit(T)))
onenanometer(T::Type{<:Real}) = 1e-3 * one(T)
onenanometer(v::Real) = 1e-3 * one(v)

"""
    set_unit_preference!(pref::String; local_only=true)

Set the unit preference. `pref` must be one of "NoUnits", "PreferMicrons", or "PreferNanometers".

If `local_only` is `true`, add the preference to `LocalPreferences.toml`. Otherwise, add it to `Project.toml`.

Because this preference is used at compile time, Julia must be restarted for a change to take effect.
"""
function set_unit_preference!(pref::String; local_only=true)
    allowed_unit_prefs = ["NoUnits", "PreferMicrons", "PreferNanometers"]
    if !(pref in allowed_unit_prefs)
        throw(
            ArgumentError(
                """Unit preference must be one of "NoUnits", "PreferMicrons", or "PreferNanometers" """
            )
        )
    end
    if local_only
        @set_preferences!("units" => pref)
    else
        set_preferences!(DeviceLayout, "units" => pref; export_prefs=true, force=true)
    end
    if @load_preference("units", "PreferNanometers") != unit_preference
        @info(
            "New unit preference set; restart your Julia session for this change to take effect!"
        )
    else
        @info "Unit preference set to currently compiled setting; no Julia restart required."
    end
end
