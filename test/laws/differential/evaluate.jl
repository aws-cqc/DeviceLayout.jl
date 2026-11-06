# Evaluate differential cases in the current DeviceLayout worktree.
#
#   julia --project=<worktree> test/laws/differential/evaluate.jl <rundir> <label>
#
# Reads <rundir>/inputs/cases.txt, applies each case's operation with whichever
# clipping kernel this worktree links, and appends results to
# <rundir>/outputs/<label>/results.txt with a manifest identifying the worktree,
# kernel library, and Julia version. Cases already present in the results file are
# skipped, so an interrupted or hung run can be resumed. Only this file and
# exchange.jl are loaded here; everything else in test/laws/ belongs to the comparison
# step and is never run against the kernel under test.

using DeviceLayout
using DeviceLayout: Polygons
const Clipper = DeviceLayout.Clipper
include(joinpath(@__DIR__, "exchange.jl"))

const FILL_RULES = Dict(
    "positive" => Clipper.PolyFillTypePositive,
    "negative" => Clipper.PolyFillTypeNegative,
    "evenodd" => Clipper.PolyFillTypeEvenOdd,
    "nonzero" => Clipper.PolyFillTypeNonZero
)
const JOIN_TYPES = Dict(
    "miter" => Clipper.JoinTypeMiter,
    "square" => Clipper.JoinTypeSquare,
    "round" => Clipper.JoinTypeRound
)
const CLIP_TYPES = Dict(
    "union" => Clipper.ClipTypeUnion,
    "intersection" => Clipper.ClipTypeIntersection,
    "difference" => Clipper.ClipTypeDifference,
    "xor" => Clipper.ClipTypeXor
)
const PAIR_OPS = Dict(
    "union" => union2d,
    "intersect" => intersect2d,
    "difference" => difference2d,
    "xor" => xor2d
)

# Tree contours in traversal order with hole flags; keyhole cutting is a separate
# operation (`keyhole`), so trees are compared as trees.
function tree_contours(cp::ClippedPolygon)
    contours, holes = Polygon[], Union{Nothing, Bool}[]
    walk(n) =
        for c in Clipper.children(n)
            push!(contours, Polygon(copy(Clipper.contour(c))))
            push!(holes, Clipper.ishole(c))
            walk(c)
        end
    walk(cp.tree)
    return contours, holes
end
function plain_contours(polys::AbstractVector{<:Polygon})
    return Polygon[Polygon(copy(p.p)) for p in polys],
    Union{Nothing, Bool}[nothing for _ in polys]
end
function iterator_contours(cps)
    contours, holes = Polygon[], Union{Nothing, Bool}[]
    for cp in cps
        c, h = tree_contours(cp)
        append!(contours, c)
        append!(holes, h)
    end
    return contours, holes
end

coordtype(c::DiffCase) = eltype(first(c.operands).p).parameters[1]
typed(c::DiffCase) = convert(Vector{Polygon{coordtype(c)}}, c.operands)
param(c::DiffCase, k) = c.params[k]
intparam(c::DiffCase, k) = parse(Int, c.params[k])

function evaluate_case(c::DiffCase)
    ops = typed(c)
    T = coordtype(c)
    if haskey(PAIR_OPS, c.op)
        return tree_contours(PAIR_OPS[c.op]([ops[1]], [ops[2]]))
    elseif c.op == "union_set"
        return tree_contours(union2d(ops))
    elseif c.op == "fill"
        ns = intparam(c, "nsubject")
        return tree_contours(
            clip(
                Clipper.ClipTypeUnion,
                ops[1:ns],
                ops[(ns + 1):end];
                pfs=FILL_RULES[param(c, "pfs")],
                pfc=FILL_RULES[param(c, "pfc")]
            )
        )
    elseif c.op == "offset"
        δ = parse(T, param(c, "delta"))
        return plain_contours(offset(ops, δ; j=JOIN_TYPES[param(c, "join")]))
    elseif c.op == "tiled"
        ns = intparam(c, "nsubject")
        tile = parse(T, param(c, "tile"))
        return iterator_contours(
            Polygons.clip_tiled(
                CLIP_TYPES[param(c, "clip")],
                ops[1:ns],
                ops[(ns + 1):end],
                tile
            )
        )
    elseif c.op == "keyhole"
        outer, hole = ops
        return plain_contours(to_polygons(difference2d([outer], [hole])))
    else
        error("unknown operation $(c.op)")
    end
end

function run_case(c::DiffCase)
    t0 = time_ns()
    try
        contours, holes = evaluate_case(c)
        return DiffResult(c.id, "ok", (time_ns() - t0) / 1e6, "", contours, holes)
    catch err
        msg = sprint(showerror, err)
        return DiffResult(
            c.id,
            "error",
            (time_ns() - t0) / 1e6,
            first(msg, 500),
            Polygon[],
            Union{Nothing, Bool}[]
        )
    end
end

# DeviceLayout binds `libcclipper` itself when it carries its own Clipper wrapper; a
# Clipper.jl backend is identified by the versions of the loaded packages instead.
function kernel_library()
    isdefined(DeviceLayout, :libcclipper) && return string(DeviceLayout.libcclipper)
    names = ("Clipper", "cclipper2_jll", "Clipper2_jll")
    ids = filter(id -> id.name in names, collect(keys(Base.loaded_modules)))
    return join(
        sort(["$(id.name) $(pkgversion(Base.loaded_modules[id]))" for id in ids]),
        ", "
    )
end

function main(args)
    length(args) == 2 || error("usage: evaluate.jl <rundir> <label>")
    rundir, label = args
    cases = read_cases(joinpath(rundir, "inputs", "cases.txt"))
    outdir = joinpath(rundir, "outputs", label)
    mkpath(outdir)
    outpath = joinpath(outdir, "results.txt")
    done = Set(keys(read_results(outpath)))
    worktree = pkgdir(DeviceLayout)
    write_manifest(
        joinpath(outdir, "manifest.toml"),
        Dict(
            "label" => label,
            "worktree" => worktree,
            "git_head" => git_head(worktree),
            "devicelayout_version" => string(pkgversion(DeviceLayout)),
            "kernel_library" => kernel_library(),
            "julia_version" => string(VERSION),
            "started" => string(Base.Libc.strftime("%Y-%m-%dT%H:%M:%S", time())),
            "cases" => length(cases),
            "resumed_from" => length(done)
        )
    )
    n = 0
    open(outpath, "a") do io
        for c in cases
            c.id in done && continue
            write_result(io, run_case(c))
            n += 1
            n % 1000 == 0 && println(stderr, "$label: $n cases evaluated")
        end
    end
    return println(stderr, "$label: $n cases evaluated, $(length(done)) resumed → $outpath")
end

isinteractive() || main(ARGS)
