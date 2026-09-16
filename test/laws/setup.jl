# GeomLaws — shared setup for property-based geometry laws.
#
# The definitions live in lawslib.jl so that the differential harness
# (test/laws/differential/) can load the same generators and comparators outside
# TestItemRunner.

@testsnippet LawsSetup begin
    using Supposition
    using Supposition: Data
    using Random
    using DeviceLayout: Polygons
    include("lawslib.jl")
end
