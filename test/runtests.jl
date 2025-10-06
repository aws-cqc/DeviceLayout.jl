using Test
using Preferences
using DeviceLayout, Unitful, FileIO, Logging
import Unitful: s, °, DimensionError
import Clipper
import ForwardDiff

const pm2μm = DeviceLayout.PreferMicrons.pm
const nm2μm = DeviceLayout.PreferMicrons.nm
const μm2μm = DeviceLayout.PreferMicrons.μm
const mm2μm = DeviceLayout.PreferMicrons.mm
const cm2μm = DeviceLayout.PreferMicrons.cm
const m2μm = DeviceLayout.PreferMicrons.m

const nm2nm = DeviceLayout.PreferNanometers.nm
const μm2nm = DeviceLayout.PreferNanometers.μm
const cm2nm = DeviceLayout.PreferNanometers.cm
const m2nm = DeviceLayout.PreferNanometers.m

import Unitful: pm, nm, μm, mm, cm, m

p(x, y) = Point(x, y)
const tdir = mktempdir()

include("tests.jl")
include("test_align.jl")
include("test_bspline.jl")
include("test_clipping.jl")
include("test_coordinate_systems.jl")
include("test_entity.jl")
include("test_intersection.jl")
include("test_shapes.jl")
include("test_routes.jl")
include("test_channels.jl")
include("test_texts.jl")
include("test_pointinpoly.jl")
include("test_solidmodel.jl")

@testset "Schematic-Driven Layout" begin
    include("test_schematicdriven.jl")
end

include("test_pdktools.jl")

@testset "ExamplePDK" begin
    include("../examples/DemoQPU17/DemoQPU17.jl")
    @time "Total" schematic, artwork = DemoQPU17.qpu17_demo(dir=tdir)
    # Single transmon example file requires CSV, JSON, JSONSchema, DataFrames
    # Just test the components
    using .SchematicDrivenLayout
    q = SchematicDrivenLayout.ExamplePDK.Transmons.ExampleRectangleTransmon()
    rr = SchematicDrivenLayout.ExamplePDK.ReadoutResonators.ExampleClawedMeanderReadout()
    @test geometry(q) isa CoordinateSystem{typeof(1.0DeviceLayout.nm)}
    @test geometry(rr) isa CoordinateSystem{typeof(1.0DeviceLayout.nm)}
    @test issubset([:readout, :xy, :z], keys(hooks(q)))
    @test abs(hooks(rr).qubit.p.y - hooks(rr).feedline.p.y) ≈ rr.total_height
end

using Aqua
@testset "Aqua tests" begin
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

rm(tdir, recursive=true)
