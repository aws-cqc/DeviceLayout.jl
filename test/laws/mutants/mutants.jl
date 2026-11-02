# Kernel and DeviceLayout mutants for the GeomLaws suite, applied by method
# redefinition. Each models a defect class seen in practice or a plausible neighbor
# of one. A mutant is a function that applies itself; `restore!()` undoes every mutant.
# Boolean and offset mutants wrap the internal `_clip`/`_offset` through the hooks
# below; the `interiorcuts` and halo mutants re-evaluate edited copies of the source
# text, and assert that the edit applied, so a source change that breaks one fails here
# instead of silently testing the original.
const SRC = joinpath(pkgdir(DeviceLayout), "src")
const CLIPSRC = read(joinpath(SRC, "clipping.jl"), String)
const PATHSRC = read(joinpath(SRC, "paths", "paths.jl"), String)
function extract_function(src, header)
    i = findfirst(header, src)
    isnothing(i) && error("mutant source not found: $header")
    j = findnext("\nend\n", src, last(i))
    return src[first(i):(first(j) + 3)]
end
evalsrc(mod, text) = Core.eval(mod, Meta.parse(text))
function edited(text, pairs...)
    out = replace(text, pairs...)
    out == text && error("mutant edit did not apply")
    return out
end

const CLIP_TXT = extract_function(CLIPSRC, "function _clip(\n")
const OFFSET_TXT = extract_function(CLIPSRC, "function _offset(\n")
const CUTS_TXT = extract_function(CLIPSRC, "function interiorcuts(\n")
const HALO_TXT =
    extract_function(PATHSRC, "function halo(\n    sty::Union{\n        SimpleTrace,")

evalsrc(Polygons, edited(CLIP_TXT, "function _clip(" => "function _clip_orig("))
evalsrc(Polygons, edited(OFFSET_TXT, "function _offset(" => "function _offset_orig("))

const IDENTITY_CLIP = (r, op, s, c, pfs, pfc) -> r
const MUTATE_CLIP = Ref{Any}(IDENTITY_CLIP)
const IDENTITY_OFFSET =
    (s, d, j, e, at) -> Polygons._offset_orig(s, d; j, e, arc_tolerance=at)
const MUTATE_OFFSET = Ref{Any}(IDENTITY_OFFSET)

Core.eval(
    Polygons,
    quote
        function _clip(
            op::Clipper.ClipType,
            s::AbstractVector{Polygon{T}},
            c::AbstractVector{Polygon{T}};
            pfs::Clipper.PolyFillType=Clipper.PolyFillTypePositive,
            pfc::Clipper.PolyFillType=Clipper.PolyFillTypePositive
        ) where {T <: Union{Int64, Unitful.Quantity{Int64}}}
            r = _clip_orig(op, s, c; pfs, pfc)
            return $(MUTATE_CLIP)[](r, op, s, c, pfs, pfc)
        end
        function _offset(
            s::AbstractVector{Polygon{T}},
            delta;
            j::Clipper.JoinType=Clipper.JoinTypeMiter,
            e::Clipper.EndType=Clipper.EndTypeClosedPolygon,
            arc_tolerance::Float64
        ) where {T <: Union{Int64, Unitful.Quantity{Int64}}}
            return $(MUTATE_OFFSET)[](s, delta, j, e, arc_tolerance)
        end
    end
)

area2(n) = signed_area2_exact(togrid.(Clipper.contour(n)))
function each_outer(f, node)
    for o in Clipper.children(node)
        f(o)
        foreach(h -> each_outer(f, h), Clipper.children(o))
    end
end
function each_hole(f, node)
    each_outer(node) do o
        return foreach(h -> f(h, o), Clipper.children(o))
    end
end
function near_parent(h, o; t=1)
    go = [togrid.(Clipper.contour(o))]
    return any(q -> within_boundary_distance_exact(togrid(q), go, t), Clipper.contour(h))
end
# An offset variant compiled from edited source, called through `invokelatest` because
# it is defined after the hook that calls it.
function offset_variant!(name, pairs...)
    evalsrc(
        Polygons,
        edited(OFFSET_TXT, "function _offset(" => "function $name(", pairs...)
    )
    f = Base.invokelatest(getfield, Polygons, name)
    MUTATE_OFFSET[] = (s, d, j, e, at) -> Base.invokelatest(f, s, d; j, e, arc_tolerance=at)
    return nothing
end

const MUTANTS = Dict{Symbol, Function}()

# Kernel fills a hole that has a vertex within one lattice unit of its parent (the
# Clipper2 trigger in gate report §3.6).
MUTANTS[:fill_hole_near_parent] = function ()
    MUTATE_CLIP[] = function (r, op, s, c, pfs, pfc)
        each_outer(o -> (o.children = filter(h -> !near_parent(h, o), o.children)), r.tree)
        return r
    end
end
# Kernel fills holes smaller than 5 % of their parent's area.
MUTANTS[:fill_small_holes] = function ()
    MUTATE_CLIP[] = function (r, op, s, c, pfs, pfc)
        each_outer(r.tree) do o
            return o.children = filter(h -> abs(area2(h)) >= abs(area2(o)) ÷ 20, o.children)
        end
        return r
    end
end
# Kernel drops output components smaller than 5 % of the largest (ledger L1's vanishing,
# at a scale no tolerance excuses).
MUTANTS[:drop_small_components] = function ()
    MUTATE_CLIP[] = function (r, op, s, c, pfs, pfc)
        ch = Clipper.children(r.tree)
        if length(ch) > 1
            amax = maximum(o -> abs(area2(o)), ch)
            r.tree.children = filter(o -> abs(area2(o)) >= amax ÷ 20, ch)
        end
        return r
    end
end
# Kernel returns holes with the outer orientation.
MUTANTS[:hole_orientation] = function ()
    MUTATE_CLIP[] = function (r, op, s, c, pfs, pfc)
        each_hole((h, o) -> (h.contour = reverse(h.contour)), r.tree)
        return r
    end
end
# Kernel repeats a vertex (a zero-length edge) in each outer contour.
MUTANTS[:duplicate_vertex] = function ()
    MUTATE_CLIP[] = function (r, op, s, c, pfs, pfc)
        each_outer(r.tree) do o
            return isempty(o.contour) || (o.contour = vcat(o.contour[1:1], o.contour))
        end
        return r
    end
end
# Wrong operation in a degenerate configuration: the xor of operands that share a
# vertex returns their union.
MUTANTS[:xor_touch_is_union] = function ()
    MUTATE_CLIP[] = function (r, op, s, c, pfs, pfc)
        op == Clipper.ClipTypeXor || return r
        vs = Set(q for p in s for q in p.p)
        any(q -> q in vs, (q for p in c for q in p.p)) || return r
        return Polygons._clip_orig(Clipper.ClipTypeUnion, s, c; pfs, pfc)
    end
end
# Even-odd fill for subjects where positive is asked for, which pairs of simple
# counterclockwise operands cannot distinguish.
MUTANTS[:evenodd_subjects] = function ()
    MUTATE_CLIP[] = function (r, op, s, c, pfs, pfc)
        pfs == Clipper.PolyFillTypePositive || return r
        return Polygons._clip_orig(op, s, c; pfs=Clipper.PolyFillTypeEvenOdd, pfc)
    end
end
# Offsets fill the holes they create (fronts closing around a cavity).
MUTANTS[:offset_fills_holes] = function ()
    return offset_variant!(
        :_offset_fills_holes,
        "polys = [Polygon(reinterpret(Point{T}, p)) for p in result]" =>
            "polys = filter(p -> orientation(p) == 1, " *
            "[Polygon(reinterpret(Point{T}, p)) for p in result])"
    )
end
# Erosion keeps only its largest component.
MUTANTS[:erosion_largest_only] = function ()
    MUTATE_OFFSET[] = function (s, d, j, e, at)
        out = IDENTITY_OFFSET(s, d, j, e, at)
        (Unitful.ustrip(d) < 0 && length(out) > 1) || return out
        return [out[argmax([abs(signed_area2_exact(togrid(p))) for p in out])]]
    end
end
# Miter limit 4δ instead of 2δ.
MUTANTS[:miter_limit_4] = function ()
    return offset_variant!(:_offset_miter4, "ClipperOffset(2.0" => "ClipperOffset(4.0")
end
# Floating-point round joins discretized 100 times more coarsely (1 nm → 100 nm).
MUTANTS[:float_arc_100x] = function ()
    return MUTATE_OFFSET[] =
        (s, d, j, e, at) -> IDENTITY_OFFSET(s, d, j, e, at > 1 ? 100at : at)
end
# `interiorcuts` does not register a spliced hole's edges, so a later hole's ray can
# pass through an earlier hole.
MUTANTS[:cuts_forget_spliced_holes] = function ()
    pattern =
        r"\n\s*push!\(itree, IntervalValue\(xinterval\(segment\(n0?\)\)\.\.\., n0?\)\)"
    return evalsrc(Polygons, edited(CUTS_TXT, pattern => ""))
end
# `interiorcuts` does not recurse into holes, dropping islands inside them.
MUTANTS[:cuts_drop_islands] = function ()
    return evalsrc(
        Polygons,
        edited(CUTS_TXT, "interiorcuts(hole, outpolys, userpoint)" => "nothing")
    )
end
# Trace and CPW halos widened by 0.95δ instead of δ.
MUTANTS[:halo_short] = function ()
    return evalsrc(
        Paths,
        edited(HALO_TXT, "extent(sty) + outer_delta" => "extent(sty) + 0.95 * outer_delta")
    )
end

function restore!()
    MUTATE_CLIP[] = IDENTITY_CLIP
    MUTATE_OFFSET[] = IDENTITY_OFFSET
    evalsrc(Polygons, CUTS_TXT)
    evalsrc(Paths, HALO_TXT)
    return nothing
end
