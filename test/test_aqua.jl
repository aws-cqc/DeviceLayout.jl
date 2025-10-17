@testitem "Aqua tests" begin
    using Aqua, DeviceLayout
    # Everything but stdlib should have compat versions
    Aqua.test_deps_compat(
        DeviceLayout,
        ignore=[:Dates, :LinearAlgebra, :Logging, :Random, :UUIDs],
        check_extras=(; ignore=[:Test])
    )
    # We define ForwardDiff.extract_derivative with Unitful.Quantity; ignore that one
    Aqua.test_piracies(
        DeviceLayout,
        treat_as_own=[DeviceLayout.ForwardDiff.extract_derivative]
    )
    Aqua.test_stale_deps(DeviceLayout)
    Aqua.test_undefined_exports(DeviceLayout) # This also checks exports from submodules
    # Be careful about ambiguities when defining GeometryEntityStyle, since we define for convenience
    # (T::Type{<:GeometryEntityStyle})(x::GeometryEntity, args...; kwargs...) = styled(x, T(args...; kwargs...))
    # A style whose first field is a GeometryEntity would be genuinely ambiguous
    # And otherwise you might have to define an inner constructor where the first arg isn't ::Any
    Aqua.test_ambiguities(DeviceLayout)
end
