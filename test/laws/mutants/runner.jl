# In-process runner for the :geomlaws test items, so that mutants applied by method
# redefinition are seen without re-precompiling DeviceLayout. Each test item's body is
# evaluated in a fresh module that imports every binding of one shared `LawsEnv`,
# sharing its compiled code, as TestItemRunner gives each item its own module.
# Shrinking is disabled: only detection matters here.
using Test, Supposition, Random, Unitful, DeviceLayout
using DeviceLayout: Polygons, Paths
import Clipper
Supposition.shrink!(::Supposition.TestState) = nothing

module LawsEnv
using Test, Preferences, DeviceLayout, LinearAlgebra, Unitful, FileIO, Logging
import Unitful: s, °, DimensionError
import Clipper
import Unitful: pm, nm, μm, mm, cm, m
using Supposition
using Supposition: Data
using Random
using DeviceLayout: Polygons
include(joinpath(@__DIR__, "..", "lawslib.jl"))
end
using .LawsEnv:
    togrid, signed_area2_exact, within_boundary_distance_exact, tree_nodes, GEOMLAWS_SEED

const LAW_FILES =
    joinpath.(
        @__DIR__,
        "..",
        [
            "test_boolean.jl",
            "test_offset.jl",
            "test_transform.jl",
            "test_ledger.jl",
            "test_fixtures.jl",
            "test_oracle_regressions.jl"
        ]
    )

function testitems(file)
    ex = Meta.parseall(read(file, String); filename=file)
    items = Tuple{String, Expr}[]
    for a in ex.args
        (a isa Expr && a.head == :macrocall && a.args[1] == Symbol("@testitem")) || continue
        push!(items, (a.args[3], a.args[end]))
    end
    return items
end

function item_module()
    M = Module(gensym("item"))
    Core.eval(
        M,
        quote
            using Test, Preferences, DeviceLayout, LinearAlgebra, Unitful, FileIO, Logging
            import Unitful: s, °, DimensionError
            import Clipper
            import Unitful: pm, nm, μm, mm, cm, m
            using Supposition
            using Supposition: Data
            using Random
            using DeviceLayout: Polygons
        end
    )
    for n in names(LawsEnv; all=true)
        (n in (:eval, :include, :LawsEnv) || startswith(string(n), "#")) && continue
        Core.eval(M, Expr(:import, Expr(:(:), Expr(:., :Main, :LawsEnv), Expr(:., n))))
    end
    return M
end

# One row per generative check, budget testset, or non-passing `@test`:
# (item, description, status).
function collect_rows!(rows, item, ts)
    for r in ts.results
        if r isa Supposition.SuppositionReport
            res = Supposition.results(r)
            st = res.ispass ? :pass : res.isbroken ? :broken : res.iserror ? :error : :fail
            push!(rows, (item, r.description, st))
        elseif r isa Test.DefaultTestSet
            if occursin(" valid / ", r.description)
                ok = all(x -> x isa Test.Pass, r.results)
                push!(rows, (item, r.description, ok ? :budget_ok : :budget_fail))
            else
                collect_rows!(rows, item, r)
            end
        elseif r isa Test.Broken
            push!(rows, (item, "@test", :broken))
        elseif r isa Test.Fail
            push!(rows, (item, "@test", :fail))
        elseif r isa Test.Error
            push!(rows, (item, "@test", :error))
        end
    end
    return rows
end

# Runs every :geomlaws item in `files`, sending test output to `log`.
function run_laws(; files=LAW_FILES, log=tempname())
    rows = Any[]
    open(log, "w") do io
        redirect_stdio(; stdout=io, stderr=io) do
            for f in files, (name, body) in testitems(f)
                M = item_module()
                ts = Test.DefaultTestSet(name)
                Test.@with_testset ts begin
                    try
                        Core.eval(M, body)
                    catch e
                        push!(
                            rows,
                            (name, "threw " * first(sprint(showerror, e), 200), :error)
                        )
                    end
                end
                collect_rows!(rows, name, ts)
            end
        end
    end
    return rows
end

# Failing checks as "B5 partition_exact"-style labels.
function failing_checks(rows)
    labels = String[]
    for (item, desc, st) in rows
        st in (:fail, :error, :budget_fail) || continue
        law = first(split(replace(item, "GeomLaws " => ""), ":"))
        check = first(split(desc, ":"))
        push!(labels, law * " " * check)
    end
    return unique(labels)
end
