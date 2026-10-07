# Shared helpers for the single-shot SolidModel benchmarks.

using Dates, FileIO, JSON, Logging, SHA
using DeviceLayout, DeviceLayout.SolidModels
import Gmsh: gmsh

"""
    environment_info() -> Dict

Versions and hardware that a result depends on: Julia, DeviceLayout (git SHA when run from a
checkout), Gmsh, CPU model, thread counts.
"""
function environment_info()
    # Read gmsh options after `SolidModel` has set them, so the recorded values are the ones
    # the benchmark actually ran with.
    iszero(gmsh.is_initialized()) && SolidModel("environment_info")
    dl_dir = pkgdir(DeviceLayout)
    sha = try
        strip(read(`git -C $dl_dir rev-parse HEAD`, String))
    catch
        "unknown"
    end
    return Dict(
        "timestamp" => Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SSZ"),
        "julia_version" => string(VERSION),
        "julia_threads" => Threads.nthreads(),
        "devicelayout_version" => string(pkgversion(DeviceLayout)),
        "devicelayout_sha" => sha,
        "gmsh_version" => gmsh.option.get_string("General.Version"),
        "gmsh_num_threads" => gmsh.option.get_number("General.NumThreads"),
        "occ_parallel" => gmsh.option.get_number("Geometry.OCCParallel"),
        "cpu_model" => Sys.cpu_info()[1].model,
        "cpu_count" => Sys.CPU_THREADS,
        "total_memory_bytes" => Sys.total_memory(),
        "os" => string(Sys.KERNEL)
    )
end

short_sha(env) = first(env["devicelayout_sha"], 8)

function default_output_path(name)
    env = environment_info()
    stamp = Dates.format(now(UTC), dateformat"yyyymmdd-HHMMSS")
    return joinpath(@__DIR__, "results", "$name-$(short_sha(env))-$stamp.json")
end

"""
    RecordingLogger(inner)

Logger that records every message with a timestamp and forwards it to `inner`. Used to
capture `render!(...; verbose=true)` output for per-operation timings.

Install it with `global_logger` *before* `plan`: a `Schematic`'s logger tees to whatever
`current_logger()` is when the schematic is planned, so a logger installed later with
`with_logger` never sees the schematic render messages.
"""
struct RecordingLogger <: AbstractLogger
    inner::AbstractLogger
    t0::Float64
    records::Vector{Dict{String, Any}}
end
RecordingLogger(inner) = RecordingLogger(inner, time(), Dict{String, Any}[])
Logging.min_enabled_level(l::RecordingLogger) = Logging.min_enabled_level(l.inner)
Logging.shouldlog(l::RecordingLogger, args...) = Logging.shouldlog(l.inner, args...)
Logging.catch_exceptions(l::RecordingLogger) = Logging.catch_exceptions(l.inner)
function Logging.handle_message(l::RecordingLogger, level, message, args...; kwargs...)
    push!(
        l.records,
        Dict("t" => time() - l.t0, "level" => string(level), "message" => string(message))
    )
    return Logging.handle_message(l.inner, level, message, args...; kwargs...)
end

"""
    operation_timings(records) -> Vector{Dict}

Extract `(phase, name, seconds)` entries from verbose `render!` log records. Phases follow the
`render!:` marker messages; entries are the `[x s]   name: ...` result lines and the
`[x s]   fragmented dimensions [d1, d2]` lines.
"""
function operation_timings(records)
    ops = Dict{String, Any}[]
    phase = "unknown"
    for r in records
        full_msg = r["message"]
        # Timed messages start with an `[x s]` label
        t = match(r"^\[\s*([\d.]+) s\]\s+(.*)$", full_msg)
        seconds = isnothing(t) ? nothing : parse(Float64, t[1])
        msg = isnothing(t) ? full_msg : t[2]
        if startswith(msg, "render!:")
            phase = if contains(msg, "rendering entities")
                "groups"
            elseif contains(msg, "unioning")
                "auto_union"
            elseif contains(msg, "postrendering operations")
                "postrender"
            else
                "render"
            end
            isnothing(seconds) || push!(
                ops,
                Dict("phase" => phase, "name" => "total", "seconds" => seconds)
            )
            continue
        end
        isnothing(seconds) && continue
        m = match(r"^fragmented dimensions (\[[\d, ]+\])$", msg)
        if !isnothing(m)
            push!(
                ops,
                Dict("phase" => "fragment", "name" => m[1], "seconds" => seconds)
            )
            continue
        end
        m = match(r"^([^:]+): ", msg)
        if !isnothing(m)
            push!(ops, Dict("phase" => phase, "name" => m[1], "seconds" => seconds))
        end
    end
    return ops
end

"""
    geometry_summary(sm::SolidModel) -> Dict

Entity counts by dimension, physical groups (name, dimension, entity count, total mass), and
the model bounding box.
"""
function geometry_summary(sm::SolidModel)
    gmsh.model.set_current(SolidModels.name(sm))
    entities = Dict("dim$d" => length(gmsh.model.get_entities(d)) for d = 0:3)
    groups = Dict{String, Any}[]
    for (dim, tag) in gmsh.model.get_physical_groups()
        tags = gmsh.model.get_entities_for_physical_group(dim, tag)
        mass = dim == 0 ? 0.0 : sum(gmsh.model.occ.get_mass(dim, t) for t in tags; init=0.0)
        push!(
            groups,
            Dict(
                "name" => gmsh.model.get_physical_name(dim, tag),
                "dim" => dim,
                "entities" => length(tags),
                "mass" => mass
            )
        )
    end
    sort!(groups, by=g -> (g["dim"], g["name"]))
    return Dict(
        "entities" => entities,
        "physical_groups" => groups,
        "bounding_box" => collect(gmsh.model.get_bounding_box(-1, -1))
    )
end

"""
    solidmodel_fingerprint(sm::SolidModel) -> String

SHA-256 over a tag-independent description of the geometry: for each dimension, the sorted
list of rounded (mass, center of mass) per entity, plus the same per physical group keyed by
name. Points contribute rounded coordinates. Two renders of the same design should agree even
if OCC assigns entity tags in a different order.
"""
function solidmodel_fingerprint(sm::SolidModel; mass_sigdigits=8, coord_digits=4)
    gmsh.model.set_current(SolidModels.name(sm))
    describe(dim, tag) =
        if dim == 0
            round.(gmsh.model.get_value(0, tag, Float64[]), digits=coord_digits)
        else
            (
                round(gmsh.model.occ.get_mass(dim, tag), sigdigits=mass_sigdigits),
                round.(gmsh.model.occ.get_center_of_mass(dim, tag), digits=coord_digits)...
            )
        end
    io = IOBuffer()
    for d = 0:3
        descs = sort!([describe(d, t) for (_, t) in gmsh.model.get_entities(d)])
        println(io, "dim $d: ", length(descs))
        foreach(x -> println(io, x), descs)
    end
    groups = sort!([
        (gmsh.model.get_physical_name(d, t), d, t) for
        (d, t) in gmsh.model.get_physical_groups()
    ])
    for (gname, d, t) in groups
        descs = sort!([
            describe(d, e) for e in gmsh.model.get_entities_for_physical_group(d, t)
        ])
        println(io, "group $gname dim $d: ", length(descs))
        foreach(x -> println(io, x), descs)
    end
    return bytes2hex(sha256(take!(io)))
end

"""
    mesh_summary() -> Dict

Node and element counts (by element type name) for the current gmsh model, plus min/mean and a
10-bin histogram of `minSICN` and `gamma` quality over the 3D elements.
"""
function mesh_summary()
    out = Dict{String, Any}("nodes" => length(gmsh.model.mesh.get_nodes()[1]))
    elements = Dict{String, Int}()
    tags3d = UInt[]
    for dim = 1:3
        types, tags, _ = gmsh.model.mesh.get_elements(dim)
        for (ty, tg) in zip(types, tags)
            elements[gmsh.model.mesh.get_element_properties(ty)[1]] = length(tg)
            dim == 3 && append!(tags3d, tg)
        end
    end
    out["elements"] = elements
    out["elements_3d"] = length(tags3d)
    for metric in ("minSICN", "gamma")
        q = gmsh.model.mesh.get_element_qualities(tags3d, metric)
        edges = range(0, 1, length=11)
        hist = [
            count(x -> lo <= x < hi, q) for
            (lo, hi) in zip(edges[1:(end - 1)], edges[2:end])
        ]
        hist[end] += count(==(1.0), q)
        out[metric] =
            Dict("min" => minimum(q), "mean" => sum(q) / length(q), "histogram" => hist)
    end
    return out
end

"""
    parse_benchmark_args(args) -> Dict

Command-line options shared by the single-shot benchmark scripts:
`--out=PATH --scales=1.0,0.5 --order=1 --skip-mesh --save-geometry`.
"""
function parse_benchmark_args(args)
    opts = Dict{String, Any}(
        "out" => nothing,
        "scales" => [1.0],
        "order" => 1,
        "skip-mesh" => false,
        "save-geometry" => false
    )
    for a in args
        if a == "--skip-mesh"
            opts["skip-mesh"] = true
        elseif a == "--save-geometry"
            opts["save-geometry"] = true
        elseif startswith(a, "--out=")
            opts["out"] = a[7:end]
        elseif startswith(a, "--scales=")
            opts["scales"] = parse.(Float64, split(a[10:end], ','))
        elseif startswith(a, "--order=")
            opts["order"] = parse(Int, a[9:end])
        else
            error("Unknown argument $a")
        end
    end
    return opts
end

"""
    run_solidmodel_benchmark(name, setup, opts) -> Dict

Time `setup()` (which must return `(schematic_or_cs, target, artwork_or_nothing)`), render
the result to a fresh `SolidModel` with `verbose=true`, then mesh at each of `opts["scales"]`
with element order `opts["order"]`, recording timings, entity/mesh statistics, peak RSS, and
fingerprints. Writes JSON to `opts["out"]` (default under `results/`) and returns the dict.
"""
function run_solidmodel_benchmark(name, setup, opts)
    results = Dict{String, Any}("benchmark" => name, "environment" => environment_info())
    phases = Dict{String, Any}()
    results["phases"] = phases
    workdir = mktempdir()
    log = RecordingLogger(global_logger())
    global_logger(log)

    t = @elapsed cs, target, artwork = setup()
    phases["setup"] = Dict("seconds" => t, "maxrss_bytes" => Sys.maxrss())
    isnothing(artwork) ||
        (results["artwork_fingerprint"] = Cells.geometry_fingerprint(artwork))

    sm = SolidModel("$(name)_benchmark"; overwrite=true)
    SolidModels.gmsh.option.set_number("General.Verbosity", 2)
    n_setup_records = length(log.records)
    t = @elapsed render!(sm, cs, target; verbose=true)
    render_records = log.records[(n_setup_records + 1):end]
    phases["render"] = Dict(
        "seconds" => t,
        "maxrss_bytes" => Sys.maxrss(),
        "log" => render_records,
        "operations" => operation_timings(render_records)
    )
    results["geometry"] = geometry_summary(sm)
    results["geometry_fingerprint"] = solidmodel_fingerprint(sm)
    if opts["save-geometry"]
        path = joinpath(workdir, "$name.brep")
        t = @elapsed save(path, sm)
        results["brep"] = Dict(
            "seconds" => t,
            "bytes" => filesize(path),
            "sha256" => bytes2hex(open(sha256, path))
        )
    end

    if !opts["skip-mesh"]
        SolidModels.mesh_order(opts["order"])
        SolidModels.mesh_grading_default(0.75)
        meshes = Dict{String, Any}[]
        for s in opts["scales"]
            SolidModels.mesh_scale(s)
            gmsh.model.mesh.clear()
            entry = Dict{String, Any}("scale" => s, "order" => opts["order"])
            for dim = 1:3
                entry["generate_$(dim)d_seconds"] = @elapsed gmsh.model.mesh.generate(dim)
            end
            entry["maxrss_bytes"] = Sys.maxrss()
            merge!(entry, mesh_summary())
            path = joinpath(workdir, "$name.msh2")
            entry["save_seconds"] = @elapsed save(path, sm)
            entry["msh2_bytes"] = filesize(path)
            push!(meshes, entry)
            println(
                stderr,
                "mesh scale=$s: ",
                JSON.json(filter(p -> p.first != "scale", entry))
            )
        end
        results["meshes"] = meshes
    end

    results["total_seconds"] =
        phases["setup"]["seconds"] +
        phases["render"]["seconds"] +
        (
            haskey(results, "meshes") ?
            sum(sum(m["generate_$(d)d_seconds"] for d = 1:3) for m in results["meshes"]) :
            0.0
        )

    out = something(opts["out"], default_output_path(name))
    mkpath(dirname(out))
    open(out, "w") do io
        return JSON.print(io, results, 2)
    end
    println("Wrote $out")
    return results
end
