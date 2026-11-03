# Case and result exchange for the differential harness.
#
# The two kernels under comparison cannot be loaded into one process (each DeviceLayout
# build links one clipping library through its `Clipper` dependency), so inputs and
# outputs cross process boundaries as plain text. Coordinates are written with `repr`,
# which round-trips `Int` and `Float64` exactly, so every worktree evaluates
# bit-identical operands and `togrid` in the comparison step sees exactly what each
# kernel saw. GDS is not used for the exchange: its 32-bit database units cannot hold
# the femtometer lattice of a 100 μm polygon.
#
# This file depends only on Base and DeviceLayout's `Point`/`Polygon` so that
# `evaluate.jl` runs in any DeviceLayout worktree.

struct DiffCase
    id::String
    family::String
    op::String
    params::Dict{String, String}
    operands::Vector{Polygon}
end

# Contours of one kernel result. `holes[i]` is the tree's hole flag for a
# `ClippedPolygon` contour and `nothing` for plain polygon output (`offset`,
# `to_polygons`); the comparison uses even-odd membership over all contours either way.
struct DiffResult
    id::String
    status::String          # "ok" or "error"
    time_ms::Float64
    message::String
    contours::Vector{Polygon}
    holes::Vector{Union{Nothing, Bool}}
end

const COORD_NAMES = Dict("Int" => Int, "Float64" => Float64)
coord_name(::Type{Int}) = "Int"
coord_name(::Type{Float64}) = "Float64"
coord_name(::Type{Point{T}}) where {T} = coord_name(T)
coord_name(p::Polygon) = coord_name(eltype(p.p))

function write_coords(io, pts::Vector{<:Point})
    for p in pts
        print(io, ' ', repr(p.x), ' ', repr(p.y))
    end
    return println(io)
end

function parse_coords(::Type{T}, tokens, n) where {T}
    length(tokens) == 2n || error("expected $(2n) coordinates, got $(length(tokens))")
    return Point{T}[Point(parse(T, tokens[2i - 1]), parse(T, tokens[2i])) for i = 1:n]
end

# Case file: one `case` header line per case, followed by one `operand` line per
# operand polygon. Parameters are `key=value` tokens without whitespace.
function write_case(io, c::DiffCase)
    print(io, "case ", c.id, " family=", c.family, " op=", c.op)
    for k in sort!(collect(keys(c.params)))
        v = c.params[k]
        (occursin(' ', k) || occursin(' ', v)) &&
            error("case parameters must not contain spaces: $k=$v")
        print(io, ' ', k, '=', v)
    end
    println(io)
    for poly in c.operands
        print(io, "operand ", coord_name(poly), ' ', length(poly.p))
        write_coords(io, poly.p)
    end
end

function read_cases(path)
    cases = DiffCase[]
    current = nothing
    for line in eachline(path)
        tokens = split(line)
        isempty(tokens) && continue
        if tokens[1] == "case"
            params = Dict{String, String}()
            for t in tokens[3:end]
                k, v = split(t, '='; limit=2)
                params[k] = v
            end
            family = pop!(params, "family")
            op = pop!(params, "op")
            current = DiffCase(String(tokens[2]), family, op, params, Polygon[])
            push!(cases, current)
        elseif tokens[1] == "operand"
            T = COORD_NAMES[tokens[2]]
            n = parse(Int, tokens[3])
            push!(current.operands, Polygon(parse_coords(T, tokens[4:end], n)))
        else
            error("unexpected line in case file: $line")
        end
    end
    return cases
end

# Result file: a `result` line per case, then `contour` lines. Error messages go on
# their own `message` line so they may contain spaces. Results are appended and
# flushed per case so a kernel hang loses nothing already computed.
function write_result(io, r::DiffResult)
    println(io, "result ", r.id, ' ', r.status, ' ', repr(r.time_ms))
    isempty(r.message) || println(io, "message ", replace(r.message, '\n' => ' '))
    for (poly, hole) in zip(r.contours, r.holes)
        h = isnothing(hole) ? "-" : (hole ? "1" : "0")
        print(io, "contour ", coord_name(poly), ' ', h, ' ', length(poly.p))
        write_coords(io, poly.p)
    end
    return flush(io)
end

function read_results(path)
    results = Dict{String, DiffResult}()
    current = nothing
    isfile(path) || return results
    for line in eachline(path)
        tokens = split(line; limit=2)
        isempty(tokens) && continue
        if tokens[1] == "result"
            id, status, ms = split(tokens[2])
            current = DiffResult(
                String(id),
                String(status),
                parse(Float64, ms),
                "",
                Polygon[],
                Union{Nothing, Bool}[]
            )
            results[current.id] = current
        elseif tokens[1] == "message"
            results[current.id] = DiffResult(
                current.id,
                current.status,
                current.time_ms,
                length(tokens) > 1 ? String(tokens[2]) : "",
                current.contours,
                current.holes
            )
            current = results[current.id]
        elseif tokens[1] == "contour"
            fields = split(tokens[2])
            T = COORD_NAMES[fields[1]]
            hole = fields[2] == "-" ? nothing : fields[2] == "1"
            n = parse(Int, fields[3])
            push!(current.contours, Polygon(parse_coords(T, fields[4:end], n)))
            push!(current.holes, hole)
        else
            error("unexpected line in result file: $line")
        end
    end
    return results
end

# TOML is a standard library, so manifests are readable in every worktree.
using TOML
write_manifest(path, d::AbstractDict) = open(io -> TOML.print(io, d), path, "w")
read_manifest(path) = TOML.parsefile(path)

function git_head(dir)
    try
        return readchomp(`git -C $dir rev-parse HEAD`)
    catch
        return "unknown"
    end
end
