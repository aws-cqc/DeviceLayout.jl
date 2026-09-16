# Compare two benchmark result files written by `run_qpu17.jl` / `run_single_transmon.jl`.
#
#   julia --project=benchmark benchmark/solidmodel/compare.jl base.json head.json [--threshold=0.10]
#
# Prints a markdown report: environment, geometry identity (fingerprints, entity counts,
# per-group entity counts and masses, mesh counts), then timings with relative deltas.
# Exits with status 1 if any timing regresses by more than `threshold` (fraction) or if the
# geometry differs, so it can gate a CI job. Two runs at the same commit on the same machine
# form a determinism check: every "geometry identity" row should read `same`.

using JSON, Printf

function load(path)
    r = JSON.parsefile(path)
    return r
end

fmt_s(x) = @sprintf("%.1f s", x)
fmt_pct(x) = @sprintf("%+.1f%%", 100x)
fmt_mb(x) = @sprintf("%.0f MB", x / 2^20)

function delta_row(name, a, b; fmt=fmt_s, threshold=Inf)
    rel = (b - a) / a
    flag = rel > threshold ? " ⚠" : ""
    return "| $name | $(fmt(a)) | $(fmt(b)) | $(fmt_pct(rel))$flag |", rel > threshold
end

function identity_row(name, a, b)
    same = a == b
    return "| $name | $(same ? "same" : "**differs**: `$a` → `$b`") |", !same
end

function main(args)
    threshold = 0.10
    files = String[]
    for a in args
        if startswith(a, "--threshold=")
            threshold = parse(Float64, a[13:end])
        else
            push!(files, a)
        end
    end
    length(files) == 2 || error("usage: compare.jl base.json head.json [--threshold=0.10]")
    base, head = load.(files)
    base["benchmark"] == head["benchmark"] ||
        error("different benchmarks: $(base["benchmark"]) vs $(head["benchmark"])")
    regressed = false
    differs = false

    println("# $(base["benchmark"]) — comparison\n")
    println("| | base | head |\n|---|---|---|")
    for k in (
        "devicelayout_sha",
        "devicelayout_version",
        "julia_version",
        "gmsh_version",
        "cpu_model",
        "cpu_count",
        "gmsh_num_threads",
        "timestamp"
    )
        println("| $k | $(base["environment"][k]) | $(head["environment"][k]) |")
    end

    println("\n## Geometry identity\n")
    println("| quantity | result |\n|---|---|")
    for (label, key) in (
        ("artwork fingerprint", "artwork_fingerprint"),
        ("SolidModel fingerprint", "geometry_fingerprint")
    )
        (haskey(base, key) && haskey(head, key)) || continue
        row, d = identity_row(label, base[key], head[key])
        println(row)
        differs |= d
    end
    if haskey(base, "brep") && haskey(head, "brep")
        row, d = identity_row("BREP sha256", base["brep"]["sha256"], head["brep"]["sha256"])
        println(row)
        differs |= d
    end
    for d = 0:3
        row, dd = identity_row(
            "dim-$d entities",
            base["geometry"]["entities"]["dim$d"],
            head["geometry"]["entities"]["dim$d"]
        )
        println(row)
        differs |= dd
    end
    groups(r) = Dict((g["name"], g["dim"]) => g for g in r["geometry"]["physical_groups"])
    gb, gh = groups(base), groups(head)
    for k in sort!(collect(union(keys(gb), keys(gh))))
        a, b = get(gb, k, nothing), get(gh, k, nothing)
        if isnothing(a) || isnothing(b)
            println(
                "| group `$(k[1])` (dim $(k[2])) | **differs**: present only in $(isnothing(a) ? "head" : "base") |"
            )
            differs = true
            continue
        end
        if a["entities"] != b["entities"] || !isapprox(a["mass"], b["mass"]; rtol=1e-9)
            println(
                "| group `$(k[1])` (dim $(k[2])) | **differs**: $(a["entities"]) entities, mass $(a["mass"]) → $(b["entities"]) entities, mass $(b["mass"]) |"
            )
            differs = true
        end
    end
    if haskey(base, "meshes") && haskey(head, "meshes")
        for (ma, mb) in zip(base["meshes"], head["meshes"])
            ma["scale"] == mb["scale"] || continue
            for k in ("nodes", "elements_3d")
                row, d = identity_row("mesh scale $(ma["scale"]) $k", ma[k], mb[k])
                println(row)
                differs |= d
            end
            for metric in ("minSICN", "gamma")
                row, d = identity_row(
                    "mesh scale $(ma["scale"]) min $metric",
                    round(ma[metric]["min"], sigdigits=6),
                    round(mb[metric]["min"], sigdigits=6)
                )
                println(row)
                differs |= d
            end
        end
    end

    println("\n## Timings\n")
    println("| phase | base | head | Δ |\n|---|---|---|---|")
    for (label, key) in (("setup (plan + artwork)", "setup"), ("render", "render"))
        row, r = delta_row(
            label,
            base["phases"][key]["seconds"],
            head["phases"][key]["seconds"];
            threshold
        )
        println(row)
        regressed |= r
    end
    # Per-phase totals from the verbose render log.
    function phase_totals(r)
        tot = Dict{String, Float64}()
        for op in r["phases"]["render"]["operations"]
            op["name"] == "total" && continue
            tot[op["phase"]] = get(tot, op["phase"], 0.0) + op["seconds"]
        end
        return tot
    end
    tb, th = phase_totals(base), phase_totals(head)
    for phase in ("groups", "auto_union", "postrender", "fragment")
        (haskey(tb, phase) && haskey(th, phase)) || continue
        row, r = delta_row("  render: $phase", tb[phase], th[phase]; threshold)
        println(row)
        regressed |= r
    end
    if haskey(base, "meshes") && haskey(head, "meshes")
        for (ma, mb) in zip(base["meshes"], head["meshes"])
            ma["scale"] == mb["scale"] || continue
            for d = 1:3
                k = "generate_$(d)d_seconds"
                row, r =
                    delta_row("mesh scale $(ma["scale"]): $(d)D", ma[k], mb[k]; threshold)
                println(row)
                regressed |= r
            end
        end
    end
    row, _ = delta_row(
        "peak RSS after render",
        base["phases"]["render"]["maxrss_bytes"],
        head["phases"]["render"]["maxrss_bytes"];
        fmt=fmt_mb
    )
    println(row)

    # Slowest individual operations in head, with their base counterparts, for triage.
    println("\n## Slowest render operations (head)\n")
    println("| phase | operation | base | head |\n|---|---|---|---|")
    # Operations are matched by (phase, name, occurrence), since a destination group like
    # `metal` is typically the target of several postrender operations.
    function keyed(ops)
        seen = Dict{Tuple{String, String}, Int}()
        return map(ops) do op
            k = (op["phase"], op["name"])
            seen[k] = get(seen, k, 0) + 1
            return (k..., seen[k]) => op
        end
    end
    ops_b = Dict(keyed(base["phases"]["render"]["operations"]))
    ops_h = keyed(head["phases"]["render"]["operations"])
    order = sortperm(ops_h, by=kv -> -kv.second["seconds"])
    for i in order[1:min(15, end)]
        k, op = ops_h[i]
        op["name"] == "total" && continue
        b = haskey(ops_b, k) ? fmt_s(ops_b[k]["seconds"]) : "—"
        println("| $(op["phase"]) | `$(op["name"])` | $b | $(fmt_s(op["seconds"])) |")
    end

    println()
    differs && println("**Geometry differs between base and head.**")
    regressed && println("**Timing regression above $(fmt_pct(threshold)) detected.**")
    (differs || regressed) && exit(1)
    return nothing
end

main(ARGS)
