# Loads the law definitions (generators, exact predicates, region certificates) into
# the current module outside TestItemRunner. Requires DeviceLayout's test environment
# (Supposition), e.g. `julia --project=<worktree> -e 'using TestEnv; TestEnv.activate();
# include(...)'`. Never load this in the worktree whose kernel is under evaluation:
# `evaluate.jl` stays independent of everything here.

using Test
using Random
using Unitful
using DeviceLayout
using DeviceLayout: Polygons
using Supposition
using Supposition: Data
const Clipper = DeviceLayout.Clipper
include(joinpath(@__DIR__, "..", "lawslib.jl"))
include(joinpath(@__DIR__, "exchange.jl"))
