# Harvest a polygon corpus from rendered designs.
#
#   julia --project=<worktree> test/laws/differential/harvest.jl <out.gds> <source>...
#
# Each <source> is a GDS file, or `demo-qpu17` to render the ExamplePDK DemoQPU17
# example in this worktree. Every source is loaded, flattened, and its polygons are
# written as boundaries of one flat cell in <out.gds> (1 nm database unit, so the
# corpus is exact and readable by any GDS tool). A manifest <out>.toml records per
# polygon the source file, its SHA-256, layer/datatype, and vertex count, and the
# worktree that produced the corpus; rendering uses the clipping kernel, so a corpus
# harvested from `demo-qpu17` should be produced once and shared by every
# differential run rather than regenerated per kernel.
#
# Polygons are deduplicated by shape: translated copies (fill patterns, repeated
# components) count once, at their first position, so the corpus is not dominated by
# one repeated tile. Corpora harvested from internal designs must stay internal:
# write them outside the repository.

using DeviceLayout
using FileIO
using SHA
using TOML
using Unitful

const DEMO = "demo-qpu17"

function demo_qpu17_gds(dir)
    include(joinpath(pkgdir(DeviceLayout), "examples", "DemoQPU17", "DemoQPU17.jl"))
    Base.invokelatest(Main.DemoQPU17.qpu17_demo; dir)
    return joinpath(dir, "qpu17_demo.gds")
end

# Corpus coordinates are Float64 microns, the unitless convention of DeviceLayout's
# `Cell{Float64}` (`load(...; nounits=true)` would give the same but is broken).
microns(p::Point) = Point(Unitful.ustrip(Unitful.μm, p.x), Unitful.ustrip(Unitful.μm, p.y))

function harvest_file(path)
    cells = load(path)
    polys = Tuple{Polygon{Float64}, Int, Int}[]
    # Every cell is flattened; referenced cells therefore contribute their polygons
    # both standalone and in place, which is intended: both are real design polygons.
    for (_, c) in cells
        f = flatten(c)
        for (e, m) in zip(elements(f), element_metadata(f))
            e isa Polygon || continue
            push!(polys, (Polygon(microns.(e.p)), Int(layer(m)), Int(datatype(m))))
        end
    end
    return polys
end
layer(m::GDSMeta) = m.layer
datatype(m::GDSMeta) = m.datatype

function main(args)
    length(args) >= 2 || error("usage: harvest.jl <out.gds> <source>...")
    out, sources = args[1], args[2:end]
    corpus = Cell{Float64}("corpus")
    records = Vector{Dict{String, Any}}()
    seen = Set{Vector{Tuple{Int, Int}}}()
    # Shape key: coordinates relative to the bounding-box corner, at 1 pm.
    function shape(p::Polygon{Float64})
        x0 = minimum(q -> q.x, p.p)
        y0 = minimum(q -> q.y, p.p)
        return [(round(Int, (q.x - x0) * 1e6), round(Int, (q.y - y0) * 1e6)) for q in p.p]
    end
    tmp = mktempdir()
    for src in sources
        path = src == DEMO ? demo_qpu17_gds(tmp) : src
        digest = bytes2hex(open(sha256, path))
        polys = harvest_file(path)
        kept = 0
        for (p, l, d) in polys
            key = shape(p)
            key in seen && continue
            push!(seen, key)
            render!(corpus, p, GDSMeta(l, d))
            push!(
                records,
                Dict(
                    "index" => length(records) + 1,
                    "source" => src,
                    "layer" => l,
                    "datatype" => d,
                    "vertices" => length(p.p)
                )
            )
            kept += 1
        end
        println(stderr, "$src: $(length(polys)) polygons, $kept new")
        push!(
            records,
            Dict("source" => src, "sha256" => digest, "polygons" => length(polys))
        )
    end
    save(out, corpus; options=GDSWriterOptions(; normalize=true))
    manifest = Dict(
        "worktree" => pkgdir(DeviceLayout),
        "git_head" => readchomp(`git -C $(pkgdir(DeviceLayout)) rev-parse HEAD`),
        "devicelayout_version" => string(pkgversion(DeviceLayout)),
        "julia_version" => string(VERSION),
        "sources" => filter(r -> haskey(r, "sha256"), records),
        "polygons" => filter(r -> haskey(r, "index"), records)
    )
    open(io -> TOML.print(io, manifest), first(splitext(out)) * ".toml", "w")
    return println(stderr, "$(length(seen)) polygons → $out")
end

isinteractive() || main(ARGS)
