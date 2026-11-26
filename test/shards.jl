# Splits the test suite across CI jobs. With `DL_TEST_SHARD="k/n"` set, only the test items
# in the k-th of n shards run; without it, everything runs.
#
# Most of the suite's time is compilation specific to each test item, so splitting the suite
# across jobs cuts wall time nearly in proportion. Whole files go to one shard because
# test items in the same file exercise the same code, so splitting a file would compile that
# code in several jobs.
#
# The weights only affect balance, never which test items run: a file missing from the
# table gets the median weight. Rebalance when one shard's job becomes clearly slower than
# the others.

# Seconds per file: the mean of full-suite `Pkg.test` runs on Julia 1.10, 1.11 and 1.12,
# measured on an aarch64 workstation, so CI runners may not split exactly as evenly.
# To regenerate, add `verbose=true` to `@run_package_tests` in runtests.jl and run the full
# suite with `Pkg.test()`: the summary lists the time of each file.
const TEST_FILE_SECONDS = Dict(
    "laws/test_boolean.jl" => 86,
    "laws/test_fixtures.jl" => 6,
    "laws/test_ledger.jl" => 9,
    "laws/test_offset.jl" => 47,
    "laws/test_oracle_regressions.jl" => 6,
    "laws/test_transform.jl" => 19,
    "test_align.jl" => 2,
    "test_aqua.jl" => 13,
    "test_autorouter_internals.jl" => 20,
    "test_bspline.jl" => 54,
    "test_channels.jl" => 45,
    "test_clipping.jl" => 62,
    "test_conformal_render.jl" => 91,
    "test_connected_components.jl" => 8,
    "test_coordinate_systems.jl" => 38,
    "test_corner_rounding.jl" => 27,
    "test_curve_recovery.jl" => 34,
    "test_deprecations.jl" => 17,
    "test_design_velocity.jl" => 58,
    "test_entity.jl" => 38,
    "test_examples.jl" => 215,
    "test_intersection.jl" => 14,
    "test_parameter_set.jl" => 38,
    "test_pathstyles.jl" => 52,
    "test_pdktools.jl" => 92,
    "test_pointinpoly.jl" => 18,
    "test_port_connectivity.jl" => 1,
    "test_postrender.jl" => 27,
    "test_render.jl" => 81,
    "test_routes.jl" => 2,
    "test_rtol.jl" => 14,
    "test_schematic_solidmodel.jl" => 96,
    "test_schematicdriven.jl" => 83,
    "test_self_termination.jl" => 12,
    "test_shapes.jl" => 52,
    "test_show.jl" => 10,
    "test_size_fields.jl" => 5,
    "test_solidmodel.jl" => 113,
    "test_solidmodel_import.jl" => 27,
    "test_solidmodels_experimental.jl" => 68,
    "test_texts.jl" => 5,
    "tests.jl" => 64
)

"""
    shard_assignment(n)

Map each file under `test/` that defines test items, by its path relative to `test/`, to one
of `n` shards.
"""
function shard_assignment(n)
    files = String[]
    for (root, _, names) in walkdir(@__DIR__), name in names
        path = joinpath(root, name)
        if endswith(name, ".jl") && occursin(r"^\s*@testitem"m, read(path, String))
            push!(files, relpath(path, @__DIR__))
        end
    end
    weights = sort!(collect(values(TEST_FILE_SECONDS)))
    median_weight = weights[cld(length(weights), 2)]
    weight(file) = get(TEST_FILE_SECONDS, file, median_weight)

    # Heaviest file first onto the least-loaded shard. Ties are broken by name, so that every
    # job computes the same assignment.
    load = zeros(n)
    assignment = Dict{String, Int}()
    for file in sort!(files; by=file -> (-weight(file), file))
        k = argmin(load)
        assignment[file] = k
        load[k] += weight(file)
    end
    return assignment
end

"""
    shard_filter()

Return a test item filter that selects the shard named by `ENV["DL_TEST_SHARD"]`, or every
test item if it is unset.
"""
function shard_filter()
    spec = get(ENV, "DL_TEST_SHARD", "")
    isempty(spec) && return ti -> true
    m = match(r"^(\d+)/(\d+)$", spec)
    k, n = isnothing(m) ? (0, 0) : parse.(Int, (m[1], m[2]))
    1 <= k <= n || error("DL_TEST_SHARD must be \"k/n\" with 1 ≤ k ≤ n, got \"$spec\"")
    assignment = shard_assignment(n)
    # A test item outside `test/` runs in the first shard rather than in none
    return ti -> get(assignment, relpath(ti.filename, @__DIR__), 1) == k
end
