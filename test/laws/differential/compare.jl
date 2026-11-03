# Compare two kernels' results on the same differential cases and classify every
# disagreement.
#
#   julia --project=<worktree> -t 4 --heap-size-hint=4G -e 'using TestEnv; \
#       TestEnv.activate(); include("test/laws/differential/compare.jl")' -- \
#       <rundir> <label1> <label2>
#
# <label1> is the reference kernel (Clipper1 on `main`), <label2> the candidate. The
# rational arithmetic allocates heavily; without a heap-size hint the process grows to
# tens of GB on corpus-scale runs before the collector catches up.
# Writes <rundir>/classified.tsv (one line per case), <rundir>/findings.jl (Julia
# reproducers for every case where a kernel is provably wrong), and
# <rundir>/report.md.
#
# Classes:
#   a0  outputs identical vertex for vertex
#   a1  same canonical contours (vertex order, start vertex, collinear vertices differ)
#   a2  same region, different contour decomposition (e.g. two touching outers vs
#       outer + hole)
#   d   regions differ, but every difference lies within the case tolerance of the
#       output boundaries: rounding class
#   b   regions differ beyond tolerance and the exact oracle sides with <label2>
#   c   regions differ beyond tolerance and the exact oracle sides with <label1>:
#       a regression of the candidate
#   u   regions differ beyond tolerance but the oracle is undecided at the witness:
#       a miter/square offset within the miter limit of a vertex whose join shape is
#       kernel-defined, or a witness on an operand boundary
#   i   the tolerance certificate exhausted its work budget (non-pass, unclassified)
#   v   output too large for the exact arrangement
#   e   at least one kernel raised an error
#
# The oracle evaluates the operation's exact semantics at rational witness points
# from the operands alone; it never consults either kernel.

include(joinpath(@__DIR__, "lawslib_env.jl"))

const CLASSES = ("a0", "a1", "a2", "d", "b", "c", "u", "i", "v", "e")

# ---------------------------------------------------------------------------------
# Exact oracle
# ---------------------------------------------------------------------------------
function winding_rational(q::ExactPt, v::Vector{GridPt})
    w = 0
    for i in eachindex(v)
        a, b = exact_point(v[i]), exact_point(v[mod1(i + 1, end)])
        o = cross2(sub2(b, a), sub2(q, a))
        iszero(o) &&
            all(k -> min(a[k], b[k]) <= q[k] <= max(a[k], b[k]), 1:2) &&
            return missing
        if a[2] <= q[2]
            b[2] > q[2] && o > 0 && (w += 1)
        else
            b[2] <= q[2] && o < 0 && (w -= 1)
        end
    end
    return w
end
function winding_sum(q, polys::GridRegion)
    w = 0
    for v in polys
        r = winding_rational(q, v)
        ismissing(r) && return missing
        w += r
    end
    return w
end
function fill_member(rule, w)
    ismissing(w) && return missing
    rule == "positive" && return w > 0
    rule == "negative" && return w < 0
    rule == "evenodd" && return isodd(w)
    rule == "nonzero" && return w != 0
    return error("unknown fill rule $rule")
end
boundary_distance2(q, polys::GridRegion) = minimum(
    distance2(q, exact_point(v[i]), exact_point(v[mod1(i + 1, end)])) for v in polys for
    i in eachindex(v);
    init=Exact(typemax(Int64))
)
# Floating-point distance for diagnostics and for choosing which cells to judge:
# accurate to ~1e-3 lattice units at the generated coordinate ranges, so a margin of
# 0.01 keeps the off-band selection conservative.
function boundary_distance_float(q::ExactPt, polys::GridRegion)
    qx, qy = Float64(q[1]), Float64(q[2])
    d = Inf
    for v in polys, i in eachindex(v)
        a, b = v[i], v[mod1(i + 1, end)]
        dx, dy = Float64(b[1] - a[1]), Float64(b[2] - a[2])
        ux, uy = qx - Float64(a[1]), qy - Float64(a[2])
        l = dx * dx + dy * dy
        t = l == 0 ? 0.0 : clamp((ux * dx + uy * dy) / l, 0.0, 1.0)
        d = min(d, hypot(ux - t * dx, uy - t * dy))
    end
    return d
end

lattice_delta_exact(δ::Integer) = Exact(δ)
lattice_delta_exact(δ::AbstractFloat) = Exact(δ) * Exact(BigInt(Polygons.SCALE))

# Exact membership of q in the operation's true result, or `missing` where the
# semantics do not decide it: q on an operand boundary, or within the miter limit of a
# vertex whose join shape is the kernel's own convention.
function oracle(c::DiffCase, grids::GridRegion, q::ExactPt)
    pos(polys) = fill_member("positive", winding_sum(q, polys))
    if c.op in ("union", "intersect", "difference", "xor")
        a, b = pos(grids[1:1]), pos(grids[2:2])
        (ismissing(a) || ismissing(b)) && return missing
        c.op == "union" && return a | b
        c.op == "intersect" && return a & b
        c.op == "difference" && return a & !b
        return a ⊻ b
    elseif c.op == "union_set"
        return pos(grids)
    elseif c.op == "fill"
        ns = parse(Int, c.params["nsubject"])
        s = fill_member(c.params["pfs"], winding_sum(q, grids[1:ns]))
        k = fill_member(c.params["pfc"], winding_sum(q, grids[(ns + 1):end]))
        (ismissing(s) || ismissing(k)) && return missing
        return s | k
    elseif c.op == "tiled"
        ns = parse(Int, c.params["nsubject"])
        a, b = pos(grids[1:ns]), pos(grids[(ns + 1):end])
        (ismissing(a) || ismissing(b)) && return missing
        return c.params["clip"] == "union" ? a | b : a & !b
    elseif c.op == "keyhole"
        a, b = pos(grids[1:1]), pos(grids[2:2])
        (ismissing(a) || ismissing(b)) && return missing
        return a & !b
    elseif c.op == "offset"
        T = eltype(first(c.operands).p).parameters[1]
        δ = lattice_delta_exact(parse(T, c.params["delta"]))
        a = pos(grids)
        ismissing(a) && return missing
        # Join types differ only within the miter limit (2|δ|) of the vertices where the
        # offset outline turns convexly: convex vertices of A for δ > 0, reflex vertices
        # for δ < 0. Elsewhere every join type equals the distance oracle.
        if c.params["join"] != "round"
            for v in grids, i in eachindex(v)
                o = orient_exact(v[mod1(i - 1, end)], v[i], v[mod1(i + 1, end)])
                (δ > 0 ? o > 0 : o < 0) || continue
                p = exact_point(v[i])
                distance2(q, p, p) <= (2δ)^2 && return missing
            end
        end
        d2 = boundary_distance2(q, grids)
        return δ > 0 ? (a || d2 <= δ^2) : (a && d2 >= δ^2)
    end
    return error("unknown operation $(c.op)")
end

# ---------------------------------------------------------------------------------
# Exact disagreement geometry: the same slab arrangement as `region_certificate`,
# reporting every cell where the two regions disagree, with its centroid and area.
# ---------------------------------------------------------------------------------
function disagreement_cells((edges, xs); max_work=1_000_000)
    remaining = Ref(max_work)
    cells = NamedTuple{(:q, :area, :in_x), Tuple{ExactPt, Exact, Bool}}[]
    for i = 1:(length(xs) - 1)
        spend!(remaining, 1 + length(edges)) || return nothing
        lo, hi = xs[i], xs[i + 1]
        x = (lo + hi) / 2
        active = [(height_at(e, x), e) for e in edges if e[1][1] < x < e[2][1]]
        sort!(active; by=first)
        inside = [false, false]
        for j = 1:(length(active) - 1)
            (y, e), (z, f) = active[j], active[j + 1]
            inside[1] ⊻= !iszero(e[3] & 0x01)
            inside[2] ⊻= !iszero(e[3] & 0x02)
            y == z && continue
            inside[1] != inside[2] || continue
            area =
                (hi - lo) * (
                    (height_at(f, lo) - height_at(e, lo)) +
                    (height_at(f, hi) - height_at(e, hi))
                ) / 2
            push!(cells, (q=(x, (y + z) / 2), area=area, in_x=inside[1]))
        end
    end
    return cells
end

# ---------------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------------
struct Verdict
    class::String
    area::Float64          # exact symmetric-difference area, lattice units²
    depth::Float64         # largest centroid distance to the nearest output boundary
    witness::String
    sides_1::Int           # off-band cells where the oracle sides with label1
    sides_2::Int           # ... with label2
    note::String
end
Verdict(class; area=NaN, depth=NaN, witness="", sides_1=0, sides_2=0, note="") =
    Verdict(class, area, depth, witness, sides_1, sides_2, note)

to_region(polys) = Vector{Vector{GridPt}}(togrid.(polys))

# Offline comparison can afford a larger arrangement budget than the laws.
const MAX_WORK = 10_000_000

function classify(c::DiffCase, r1::DiffResult, r2::DiffResult)
    if r1.status != "ok" || r2.status != "ok"
        return Verdict("e"; note=strip(string(r1.message, " | ", r2.message)))
    end
    X, Y = to_region(r1.contours), to_region(r2.contours)
    X == Y && return Verdict("a0"; area=0.0)
    canonical_region(X) == canonical_region(Y) && return Verdict("a1"; area=0.0)
    nvertices(X) + nvertices(Y) <= MAX_VERTICES || return Verdict("v")
    arrangement = region_arrangement(X, Y, MAX_WORK)
    isnothing(arrangement) && return Verdict("i"; note="arrangement budget")
    first(region_certificate(X, Y, 0; max_work=MAX_WORK, arrangement)) &&
        return Verdict("a2"; area=0.0)

    tol = parse(Int, c.params["tol"])
    cells = disagreement_cells(arrangement; max_work=MAX_WORK)
    isnothing(cells) && return Verdict("i"; note="disagreement sweep budget")
    area = Float64(sum(cell.area for cell in cells; init=Exact(0)))
    grids = to_region(c.operands)

    # Off-band cells (centroid farther than tol from both output boundaries) are judged
    # individually so the report can count how often each kernel is right. The
    # largest such centroid distance is a lower bound on how far apart the regions are;
    # unlike the area it distinguishes a long sliver from a deep notch.
    sides = [0, 0]
    depth = 0.0
    for cell in cells
        d = min(boundary_distance_float(cell.q, X), boundary_distance_float(cell.q, Y))
        depth = max(depth, d)
        d > tol + 0.01 || continue
        t = oracle(c, grids, cell.q)
        ismissing(t) && continue
        sides[t == cell.in_x ? 1 : 2] += 1
    end

    if tol > 0
        ok, why = region_certificate(X, Y, tol; max_work=MAX_WORK, arrangement)
        ok && return Verdict("d"; area, depth, sides_1=sides[1], sides_2=sides[2])
        why === :inconclusive &&
            return Verdict("i"; area, depth, sides_1=sides[1], sides_2=sides[2])
        q = last(why)
    else
        q = first(cells).q
    end
    t = oracle(c, grids, q)
    witness = string("(", Float64(q[1]), ", ", Float64(q[2]), ")")
    ismissing(t) &&
        return Verdict("u"; area, depth, witness, sides_1=sides[1], sides_2=sides[2])
    # A witness inside a disagreement cell is off both boundaries, so membership is
    # never missing here. Any off-band cell where the reference is right makes the
    # case a candidate regression, whichever kernel the certificate's witness favors.
    in_x = point_in_region_rational(q, X)
    class = (t == in_x || sides[1] > 0) ? "c" : "b"
    return Verdict(class; area, depth, witness, sides_1=sides[1], sides_2=sides[2])
end

function point_in_region_rational(q::ExactPt, polys::GridRegion)
    inside = false
    for v in polys
        r = point_in_polygon_rational(q, v)
        ismissing(r) && return missing
        inside ⊻= r
    end
    return inside
end

# ---------------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------------
julia_literal(p::Polygon) = string(
    "Polygon(Point{",
    coord_name(p),
    "}[",
    join(("($(repr(q.x)), $(repr(q.y)))" for q in p.p), ", "),
    "])"
)
function reproducer(io, c::DiffCase, v::Verdict, label1, label2)
    println(
        io,
        "# ",
        c.id,
        ": class ",
        v.class,
        ", tol ",
        c.params["tol"],
        ", area ",
        v.area,
        ", depth ",
        v.depth
    )
    println(
        io,
        "# witness ",
        v.witness,
        "; oracle sides with ",
        label1,
        " at ",
        v.sides_1,
        " off-band cells and with ",
        label2,
        " at ",
        v.sides_2
    )
    params = join(("$k=$(c.params[k])" for k in sort!(collect(keys(c.params)))), " ")
    println(io, "# op=", c.op, " ", params)
    for (i, p) in enumerate(c.operands)
        println(io, "operand", i, " = ", julia_literal(p))
    end
    return println(io)
end

function summarize(io, cases, verdicts, r1, r2, label1, label2, rundir)
    groups = Dict{Tuple{String, String}, Vector{Int}}()
    for (i, c) in enumerate(cases)
        push!(get!(groups, (c.family, c.op), Int[]), i)
    end
    println(io, "# Differential report: `", label1, "` vs `", label2, "`\n")
    for label in (label1, label2)
        m = read_manifest(joinpath(rundir, "outputs", label, "manifest.toml"))
        println(
            io,
            "- `",
            label,
            "`: ",
            m["worktree"],
            " @ ",
            m["git_head"][1:min(end, 10)],
            ", DeviceLayout ",
            m["devicelayout_version"],
            ", kernel `",
            basename(m["kernel_library"]),
            "`, Julia ",
            m["julia_version"]
        )
    end
    inputs = read_manifest(joinpath(rundir, "inputs", "manifest.toml"))
    println(
        io,
        "- inputs: seed ",
        inputs["seed"],
        ", ",
        inputs["cases_per_family"],
        " examples per family",
        isempty(inputs["corpus"]) ? "" :
        string(
            ", corpus ",
            inputs["corpus"],
            " (",
            inputs["corpus_polygons"],
            " polygons, ",
            inputs["corpus_skipped"],
            " skipped)"
        ),
        "\n"
    )

    println(
        io,
        "| family | op | cases | ",
        join(CLASSES, " | "),
        " | max area (b/c/u) | max depth (b/c/u) | max depth (d) |"
    )
    println(io, "|---|---|---|", repeat("---|", length(CLASSES)), "---|---|---|")
    totals = Dict(k => 0 for k in CLASSES)
    for key in sort!(collect(keys(groups)))
        idx = groups[key]
        counts = Dict(k => 0 for k in CLASSES)
        maxarea, maxdepth, maxdepth_d = 0.0, 0.0, 0.0
        for i in idx
            counts[verdicts[i].class] += 1
            totals[verdicts[i].class] += 1
            if verdicts[i].class in ("b", "c", "u")
                maxarea = max(maxarea, verdicts[i].area)
                maxdepth = max(maxdepth, verdicts[i].depth)
            elseif verdicts[i].class == "d"
                maxdepth_d = max(maxdepth_d, verdicts[i].depth)
            end
        end
        fmt(x) = x > 0 ? string(round(x; sigdigits=3)) : ""
        println(
            io,
            "| ",
            key[1],
            " | ",
            key[2],
            " | ",
            length(idx),
            " | ",
            join((counts[k] for k in CLASSES), " | "),
            " | ",
            fmt(maxarea),
            " | ",
            fmt(maxdepth),
            " | ",
            fmt(maxdepth_d),
            " |"
        )
    end
    println(
        io,
        "| **total** | | ",
        length(cases),
        " | ",
        join((totals[k] for k in CLASSES), " | "),
        " | | | |\n"
    )

    t1 = sum(r1[c.id].time_ms for c in cases)
    t2 = sum(r2[c.id].time_ms for c in cases)
    println(
        io,
        "Kernel time: `",
        label1,
        "` ",
        round(t1 / 1000; digits=1),
        " s, `",
        label2,
        "` ",
        round(t2 / 1000; digits=1),
        " s.\n"
    )

    for (class, title) in (
        ("c", "Class c — candidate regressions"),
        ("b", "Class b — reference kernel wrong"),
        ("u", "Class u — differences the oracle cannot decide"),
        ("e", "Errors"),
        ("i", "Inconclusive certificates")
    )
        idx = [i for i in eachindex(cases) if verdicts[i].class == class]
        isempty(idx) && continue
        println(io, "## ", title, " (", length(idx), ")\n")
        for i in idx[1:min(end, 40)]
            c, v = cases[i], verdicts[i]
            println(
                io,
                "- `",
                c.id,
                "` tol ",
                c.params["tol"],
                isnan(v.area) ? "" : string(", area ", round(v.area; sigdigits=4)),
                isnan(v.depth) ? "" : string(", depth ", round(v.depth; sigdigits=4)),
                isempty(v.witness) ? "" : string(", witness ", v.witness),
                (v.sides_1 + v.sides_2 > 0) ?
                string(
                    ", oracle sides ",
                    label1,
                    ":",
                    v.sides_1,
                    " ",
                    label2,
                    ":",
                    v.sides_2
                ) : "",
                isempty(v.note) ? "" : string(" — ", v.note)
            )
        end
        length(idx) > 40 && println(io, "- … ", length(idx) - 40, " more in classified.tsv")
        println(io)
    end
end

function main(args)
    length(args) == 3 || error("usage: compare.jl <rundir> <label1> <label2>")
    rundir, label1, label2 = args
    cases = read_cases(joinpath(rundir, "inputs", "cases.txt"))
    r1 = read_results(joinpath(rundir, "outputs", label1, "results.txt"))
    r2 = read_results(joinpath(rundir, "outputs", label2, "results.txt"))
    missing_ids = [c.id for c in cases if !(haskey(r1, c.id) && haskey(r2, c.id))]
    isempty(missing_ids) ||
        error("$(length(missing_ids)) cases lack results, first: $(first(missing_ids))")
    verdicts = Vector{Verdict}(undef, length(cases))
    done = Threads.Atomic{Int}(0)
    step = max(1000, length(cases) ÷ 50)
    Threads.@threads :dynamic for i in eachindex(cases)
        verdicts[i] = classify(cases[i], r1[cases[i].id], r2[cases[i].id])
        n = Threads.atomic_add!(done, 1) + 1
        # BigInt limbs are freed by finalizers, so without explicit collections the
        # process grows by roughly 0.5 GB per thousand corpus cases.
        n % 200 == 0 && GC.gc()
        n % step == 0 && println(stderr, "$n / $(length(cases)) classified")
    end
    open(joinpath(rundir, "classified.tsv"), "w") do io
        println(
            io,
            join(
                (
                    "id",
                    "family",
                    "op",
                    "tol",
                    "class",
                    "area",
                    "depth",
                    "witness",
                    "sides_$label1",
                    "sides_$label2",
                    "ms_$label1",
                    "ms_$label2",
                    "note"
                ),
                '\t'
            )
        )
        for (c, v) in zip(cases, verdicts)
            println(
                io,
                join(
                    (
                        c.id,
                        c.family,
                        c.op,
                        c.params["tol"],
                        v.class,
                        v.area,
                        v.depth,
                        v.witness,
                        v.sides_1,
                        v.sides_2,
                        r1[c.id].time_ms,
                        r2[c.id].time_ms,
                        v.note
                    ),
                    '\t'
                )
            )
        end
    end
    open(joinpath(rundir, "findings.jl"), "w") do io
        println(
            io,
            "# Reproducers for every class b/c case (",
            label1,
            " vs ",
            label2,
            ").\n"
        )
        for (c, v) in zip(cases, verdicts)
            v.class in ("b", "c") && reproducer(io, c, v, label1, label2)
        end
    end
    open(joinpath(rundir, "report.md"), "w") do io
        return summarize(io, cases, verdicts, r1, r2, label1, label2, rundir)
    end
    counts = Dict(k => count(v -> v.class == k, verdicts) for k in CLASSES)
    return println(
        stderr,
        join(("$k=$(counts[k])" for k in CLASSES), " "),
        " → ",
        joinpath(rundir, "report.md")
    )
end

isinteractive() || main(ARGS)
