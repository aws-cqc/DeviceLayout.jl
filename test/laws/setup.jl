# GeomLaws — shared setup for property-based geometry laws.

@testsnippet LawsSetup begin
    using Supposition
    using Supposition: Data
    using Random
    using DeviceLayout: Polygons
    include("lawslib.jl")
end
