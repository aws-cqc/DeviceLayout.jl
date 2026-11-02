# Generate differential cases from the law generators.
#
#   julia --project=<worktree> -e 'using TestEnv; TestEnv.activate(); \
#       include("test/laws/differential/generate.jl")' -- <rundir> [options]
#
# Options:
#   --seed N            RNG seed (default 20260908)
#   --cases N           examples drawn per generator family (default 200)
#   --corpus FILE.gds   also draw operands from a harvested corpus (see harvest.jl)
#   --corpus-cases N    corpus polygons used (default 500)
#   --max-vertices N    skip corpus polygons with more vertices (default 300)
#
# Writes <rundir>/inputs/cases.txt and <rundir>/inputs/manifest.toml. Every case
# carries the tolerance (in lattice units) at which the two kernels' regions must
# agree; the tolerances are the ones calibrated for the laws in test/laws/, so a
# disagreement beyond them is a finding rather than expected rounding.

include(joinpath(@__DIR__, "lawslib_env.jl"))
using FileIO

# ---------------------------------------------------------------------------------
# Case construction
# ---------------------------------------------------------------------------------
struct CaseSpec
    family::String
    op::String
    params::Dict{String, String}
    operands::Vector{Polygon}
end
CaseSpec(family, op, operands; kwargs...) = CaseSpec(
    family,
    op,
    Dict{String, String}(string(k) => string(v) for (k, v) in kwargs),
    Polygon[operands...]
)

const BOOLEAN_OPS = ("union", "intersect", "difference", "xor")
delta_string(δ::Integer) = string(δ)
delta_string(δ::AbstractFloat) = repr(δ)
rev(p::Polygon) = Polygon(reverse(p.p))
scale_of(A::Polygon) = maximum(p -> max(abs(p.x), abs(p.y)), A.p)

boolean_cases(family, A, B, tol) = [CaseSpec(family, op, [A, B]; tol) for op in BOOLEAN_OPS]

function fill_cases(family, A, B, tol)
    return [
        CaseSpec(family, "fill", [A, B]; tol, nsubject=2, pfs="evenodd", pfc="positive"),
        CaseSpec(
            family,
            "fill",
            [rev(A), rev(B)];
            tol,
            nsubject=2,
            pfs="negative",
            pfc="positive"
        ),
        CaseSpec(family, "fill", [A, B]; tol, nsubject=1, pfs="positive", pfc="negative")
    ]
end
mixed_fill_case(family, A, B, C, tol) =
    CaseSpec(family, "fill", [A, B, C]; tol, nsubject=2, pfs="evenodd", pfc="positive")

offset_case(family, A, δ, join) =
    CaseSpec(family, "offset", [A]; tol=2, delta=delta_string(δ), join)

# Each family draws from one law generator and emits the cases below per example.
# Tolerances follow test_boolean.jl / test_offset.jl: rectilinear integer inputs are
# exact, stars within 1, perturbed pairs within kfm + 2, offsets within 2.
const FAMILIES = [
    "int_pair" =>
        () -> begin
            A, B = example(int_pair)
            vcat(boolean_cases("int_pair", A, B, 1), fill_cases("int_pair", A, B, 1))
        end,
    "int_rectilinear_pair" =>
        () -> begin
            A, B = example(int_rectilinear_pair)
            vcat(
                boolean_cases("int_rectilinear_pair", A, B, 0),
                fill_cases("int_rectilinear_pair", A, B, 0)
            )
        end,
    "float_star_pair" =>
        () -> begin
            A, B = example(float_star_pair)
            vcat(
                boolean_cases("float_star_pair", A, B, 1),
                fill_cases("float_star_pair", A, B, 1)
            )
        end,
    "float_perturbed_pair" =>
        () -> begin
            A, B, kfm = example(float_perturbed_pair)
            [
                CaseSpec("float_perturbed_pair", op, [A, B]; tol=kfm + 2, kfm) for
                op in BOOLEAN_OPS
            ]
        end,
    "int_rectilinear_triple" =>
        () -> begin
            A, B, C = example(int_rectilinear_triple)
            [mixed_fill_case("int_rectilinear_triple", A, B, C, 0)]
        end,
    # Mixed fill rules are within 2, not 1: a kernel may normalize the two rules in
    # two passes (`_normalize_clip_fill`), and two independently rounded intersection
    # vertices can sit √2 apart diagonally.
    "int_triple" => () -> begin
        A, B, C = example(int_triple)
        [mixed_fill_case("int_triple", A, B, C, 2)]
    end,
    "float_triple" => () -> begin
        A, B, C = example(float_triple)
        [mixed_fill_case("float_triple", A, B, C, 2)]
    end,
    "int_polygon_set" =>
        () -> begin
            polys = example(int_polygon_set)
            [CaseSpec("int_polygon_set", "union_set", polys; tol=1)]
        end,
    "float_polygon_set" =>
        () -> begin
            polys = example(float_polygon_set)
            cases = [CaseSpec("float_polygon_set", "union_set", polys; tol=1)]
            if length(polys) >= 2
                a = polys[1:cld(end, 2)]
                b = polys[(cld(end, 2) + 1):end]
                tile = example(Data.SampledFrom([7.0, 15.0, 40.0]))
                for clip in ("union", "difference")
                    push!(
                        cases,
                        CaseSpec(
                            "float_polygon_set",
                            "tiled",
                            vcat(a, b);
                            tol=1,
                            nsubject=length(a),
                            clip,
                            tile=repr(tile)
                        )
                    )
                end
            end
            cases
        end,
    "int_offset" =>
        () -> begin
            A = example(int_thick_polygon)
            δ = example(Data.Integers(1, 6)) * example(Data.SampledFrom([1, -1]))
            [offset_case("int_offset", A, δ, j) for j in ("miter", "square", "round")]
        end,
    "int_rectilinear_offset" =>
        () -> begin
            A = example(int_rectilinear_polygon)
            δ = example(Data.Integers(1, 6)) * example(Data.SampledFrom([1, -1]))
            [
                offset_case("int_rectilinear_offset", A, δ, j) for
                j in ("miter", "square", "round")
            ]
        end,
    # Round joins are excluded on the float lattice: their 1 nm default arc tolerance is
    # some 10⁶ lattice units, far beyond the case tolerance, so two kernels' arcs differ
    # by more than the classes allow. The laws cover them (O3, O6, O8).
    "float_offset" =>
        () -> begin
            A = example(float_polygon)
            δ =
                example(Data.SampledFrom([0.05, 0.2])) *
                example(Data.SampledFrom([1, -1])) *
                scale_of(A)
            [offset_case("float_offset", A, δ, j) for j in ("miter", "square")]
        end,
    "int_holed" =>
        () -> begin
            outer, hole = contour_polygons(example(int_holed_polygon))
            # The tree stores the hole clockwise; `keyhole` reverses its operand itself.
            hole = rev(hole)
            fouter = Polygon(Point{Float64}.(outer.p))
            fhole = Polygon(Point{Float64}.(hole.p))
            [
                CaseSpec("int_holed", "keyhole", [outer, hole]; tol=1),
                CaseSpec("float_holed", "keyhole", [fouter, fhole]; tol=1)
            ]
        end
]

# ---------------------------------------------------------------------------------
# Corpus operands: real-design polygons with a constructed partner, mirroring the
# degenerate-pair generator (overlap, shared bounding-box edge, vertex touch,
# collinear split, sliver, fm-perturbed vertex) so that every case has a partner of
# known relationship to the operand.
# ---------------------------------------------------------------------------------
function corpus_partner(P::Polygon{Float64}, kind, kfm)
    lo = Point(minimum(p -> p.x, P.p), minimum(p -> p.y, P.p))
    hi = Point(maximum(p -> p.x, P.p), maximum(p -> p.y, P.p))
    w, h = hi.x - lo.x, hi.y - lo.y
    n = length(P.p)
    if kind == :overlap
        return P + Point(w / 3, h / 7), 1
    elseif kind == :shared_edge
        return P + Point(w, 0.0), 1
    elseif kind == :vertex_touch
        return P + Point(w, h), 1
    elseif kind == :collinear
        a, c = P.p[1], P.p[2]
        return Polygon(vcat(P.p[1:1], [(a + c) / 2], P.p[2:end])), 1
    elseif kind == :sliver
        a, c = P.p[1], P.p[2]
        d = c - a
        nrm = Point(-d.y, d.x) / hypot(d.x, d.y) * (kfm / Polygons.SCALE)
        return Polygon([a, c, c + nrm, a + nrm]), kfm + 2
    else
        pts = copy(P.p)
        pts[1] = pts[1] + Point(kfm / Polygons.SCALE, 0.0)
        return Polygon(pts), kfm + 2
    end
end
const CORPUS_KINDS =
    (:overlap, :shared_edge, :vertex_touch, :collinear, :sliver, :perturbed)

function corpus_cases(P::Polygon{Float64}, index)
    cases = CaseSpec[]
    push!(cases, CaseSpec("corpus", "union_set", [P]; tol=0, corpus_index=index))
    for kind in CORPUS_KINDS
        kfm = example(Data.SampledFrom([1, 2, 10, 1_000_000]))
        B, tol = corpus_partner(P, kind, kfm)
        valid_polygon(B) || continue
        for op in BOOLEAN_OPS
            push!(
                cases,
                CaseSpec(
                    "corpus",
                    op,
                    [P, B];
                    tol,
                    kind,
                    kfm=(kind in (:sliver, :perturbed) ? kfm : 0),
                    corpus_index=index
                )
            )
        end
    end
    lo = Point(minimum(p -> p.x, P.p), minimum(p -> p.y, P.p))
    hi = Point(maximum(p -> p.x, P.p), maximum(p -> p.y, P.p))
    δ = 0.1 * min(hi.x - lo.x, hi.y - lo.y)
    for j in ("miter", "square"), s in (1, -1)
        c = offset_case("corpus", P, s * δ, j)
        c.params["corpus_index"] = string(index)
        push!(cases, c)
    end
    return cases
end

# Corpus coordinates are Float64 microns, as harvest.jl wrote them.
function load_corpus(path)
    cells = load(path)
    length(cells) == 1 || error("corpus GDS must contain exactly one flat cell")
    c = only(values(cells))
    isempty(c.refs) || error("corpus GDS must be flat")
    microns(p::Point) =
        Point(Unitful.ustrip(Unitful.μm, p.x), Unitful.ustrip(Unitful.μm, p.y))
    return Polygon{Float64}[Polygon(microns.(p.p)) for p in elements(c)]
end

# ---------------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------------
function parse_args(args)
    opts = Dict{String, Any}(
        "seed" => 20260908,
        "cases" => 200,
        "corpus" => nothing,
        "corpus-cases" => 500,
        "max-vertices" => 300
    )
    positional = String[]
    i = 1
    while i <= length(args)
        a = args[i]
        if startswith(a, "--")
            key = a[3:end]
            haskey(opts, key) || error("unknown option $a")
            val = args[i + 1]
            opts[key] = key == "corpus" ? val : parse(Int, val)
            i += 2
        else
            push!(positional, a)
            i += 1
        end
    end
    length(positional) == 1 || error("usage: generate.jl <rundir> [options]")
    return positional[1], opts
end

function main(args)
    rundir, opts = parse_args(args)
    indir = joinpath(rundir, "inputs")
    mkpath(indir)
    Random.seed!(opts["seed"])
    counts = Dict{String, Int}()
    skipped_corpus = 0
    ncorpus = 0
    open(joinpath(indir, "cases.txt"), "w") do io
        k = 0
        emit(spec) = begin
            k += 1
            id = string(spec.family, "-", spec.op, "-", lpad(k, 7, '0'))
            write_case(io, DiffCase(id, spec.family, spec.op, spec.params, spec.operands))
            counts[spec.family * "/" * spec.op] =
                get(counts, spec.family * "/" * spec.op, 0) + 1
        end
        for (family, draw) in FAMILIES, _ = 1:opts["cases"]
            foreach(emit, draw())
        end
        if !isnothing(opts["corpus"])
            polys = load_corpus(opts["corpus"])
            ncorpus = length(polys)
            order = randperm(length(polys))
            used = 0
            for i in order
                used >= opts["corpus-cases"] && break
                P = polys[i]
                if length(P.p) > opts["max-vertices"] || !valid_polygon(P)
                    skipped_corpus += 1
                    continue
                end
                foreach(emit, corpus_cases(P, i))
                used += 1
            end
        end
        return println(stderr, "$k cases → $(joinpath(indir, "cases.txt"))")
    end
    return write_manifest(
        joinpath(indir, "manifest.toml"),
        Dict(
            "seed" => opts["seed"],
            "cases_per_family" => opts["cases"],
            "corpus" => something(opts["corpus"], ""),
            "corpus_polygons" => ncorpus,
            "corpus_skipped" => skipped_corpus,
            "harness_git_head" => git_head(@__DIR__),
            "supposition_version" => string(pkgversion(Supposition)),
            "julia_version" => string(VERSION),
            "counts" => counts
        )
    )
end

isinteractive() || main(ARGS)
