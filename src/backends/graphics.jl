module Graphics
using Unitful
import Unitful: Length, inch, unit, ustrip
import Cairo
using JSON
using SHA

import DeviceLayout:
    bounds,
    datatype,
    default_meta_map,
    elements,
    element_metadata,
    findbox,
    gdslayer,
    layerindex,
    layername,
    level,
    load,
    name,
    refs,
    save,
    save_render,
    to_polygons
import DeviceLayout: CoordinateSystem, GDSMeta, GeometryEntity, Meta
using ..Points
using ..Transformations
import ..Rectangles: Rectangle, width, height
import ..Polygons: Polygon, points
using ..Cells
import ..Texts: Text
import ..Align: LeftEdge, RightEdge, XCenter, TopEdge, BottomEdge, YCenter

import FileIO: File, @format_str, stream

using ColorSchemes
using Preferences

# Available color schemes -- Glasbey themes for categorical data
const LIGHT_MODE_SCHEME = :glasbey_bw_minc_20_maxl_70_n256  # Good for light backgrounds
const DARK_MODE_SCHEME = :glasbey_bw_minc_20_minl_30_n256   # Good for dark backgrounds

# Preference key for color theme
const COLOR_THEME_PREF = "color_theme"

"""
    get_color_scheme()

Get the current color scheme based on user preferences.
Returns either `:glasbey_bw_minc_20_maxl_70_n256` (light theme) or
`:glasbey_bw_minc_20_minl_30_n256` (dark theme).

The default is light theme.
"""
function get_color_scheme()
    scheme_name = @load_preference(COLOR_THEME_PREF, "light")
    return scheme_name == "dark" ? DARK_MODE_SCHEME : LIGHT_MODE_SCHEME
end

"""
    set_theme!(theme::String)

Set the color scheme for graphics based on background lightness (`"light"` or `"dark"`).

Light theme uses `:glasbey_bw_minc_20_maxl_70_n256` (avoids light colors, good for light backgrounds).

Dark theme uses `:glasbey_bw_minc_20_minl_30_n256` (avoids dark colors, good for dark backgrounds).
"""
function set_theme!(theme::String)
    if theme ∉ ["light", "dark"]
        error("Theme must be 'light' or 'dark', got: '$theme'")
    end
    @set_preferences!(COLOR_THEME_PREF => theme)
    for i = 0:255
        layercolors[i] = lcolor(i)
    end
    @info "Color scheme set for '$theme' theme."
end

# Generate layer color with transparency
lcolor(l, scheme) = (
    colorschemes[scheme][l + 1].r,
    colorschemes[scheme][l + 1].g,
    colorschemes[scheme][l + 1].b,
    0.5
)

# Use preference-based color scheme
lcolor(l) = lcolor(l, get_color_scheme())

# Initialize layercolors with the preferred scheme
const layercolors = Dict([(i => lcolor(i)) for i = 0:255]...)

function fillcolor(options, meta)
    layer = gdslayer(meta)
    if haskey(options, :layercolors)
        colors = options[:layercolors]
        haskey(colors, meta) && return colors[meta]
        haskey(colors, layer) && return colors[layer]
    end
    color_index = mod(layer + 31 * datatype(meta), length(layercolors))
    return get(layercolors, color_index, (0.0, 0.0, 0.0, 0.5)) # Fallback in case `layercolors` was given non-consecutive keys
end

const DEFAULT_RENDER_DPI = 72
const DEFAULT_RENDER_MAX_DIMENSION = 4inch

lscale(x::Length, dpi)  = round(Int, NoUnits((x |> inch) * dpi / inch))
lscale(x::Integer, dpi) = x
lscale(x::Real, dpi)    = Int(round(x))

function canvas_size(options, w, h)
    dpi = get(options, :dpi, DEFAULT_RENDER_DPI)
    dpi isa Real && dpi > 0 || throw(ArgumentError("dpi must be a positive number"))
    has_width = haskey(options, :width)
    has_height = haskey(options, :height)
    default_size = lscale(DEFAULT_RENDER_MAX_DIMENSION, dpi)
    if has_width && has_height
        return lscale(options[:width], dpi), lscale(options[:height], dpi)
    elseif has_width
        w1 = lscale(options[:width], dpi)
        return w1, iszero(w) || iszero(h) ? w1 : Int(ceil(w1 * h / w))
    elseif has_height
        h1 = lscale(options[:height], dpi)
        return iszero(w) || iszero(h) ? h1 : Int(ceil(h1 * w / h)), h1
    end
    # Fallback to default with max dimension capped at default_size, preserving aspect ratio
    if w > h
        return (
            default_size,
            iszero(w) || iszero(h) ? default_size : Int(ceil(default_size * h / w))
        )
    end
    return (
        iszero(w) || iszero(h) ? default_size : Int(ceil(default_size * w / h)),
        default_size
    )
end

function background_color(background)
    isnothing(background) && return (0.0, 0.0, 0.0, 0.0)
    background === :transparent && return (0.0, 0.0, 0.0, 0.0)
    background === :white && return (1.0, 1.0, 1.0, 1.0)
    background === :black && return (0.0, 0.0, 0.0, 1.0)
    if background isa Tuple && length(background) in (3, 4)
        all(x -> x isa Real && 0 <= x <= 1, background) ||
            throw(ArgumentError("background color components must be between 0 and 1"))
        length(background) == 3 && return (background..., 1.0)
        return background
    end
    throw(
        ArgumentError(
            "background must be :transparent, :white, :black, nothing, or an RGB(A) tuple"
        )
    )
end

MIMETypes = Union{
    MIME"image/png",
    MIME"image/svg+xml",
    MIME"application/pdf",
    MIME"application/postscript"
}

const RENDER_MANIFEST_SCHEMA_VERSION = "0.1"

"""
    RenderInfo

Machine-readable provenance for one graphics render. Coordinates in `viewport` use
`geometry["unit"]`; the layout-to-canvas matrix output uses `canvas["unit"]` (`px` for PNG
and SVG, `pt` for PDF and EPS). Its fields are a mutable JSON-shaped snapshot; changing them
does not rewrite the saved manifest.
"""
struct RenderInfo
    geometry::Dict{String, Any}
    viewport::Dict{String, Any}
    canvas::Dict{String, Any}
    layout_to_canvas::Dict{String, Any}
    metadata_selection::String
    selected_metadata::Vector{Dict{String, Any}}
    metadata_mapping::Vector{Dict{String, Any}}
    resolved_colors::Vector{Dict{String, Any}}
    background::Dict{String, Any}
    render_options::Dict{String, Any}
end

"""
    RenderArtifact

Paths, hash, format, and [`RenderInfo`](@ref) for an image and its render manifest.
Paths are absolute; the manifest stores the image path relative to the manifest directory.
"""
struct RenderArtifact
    image_path::String
    manifest_path::String
    image_sha256::String
    format::String
    info::RenderInfo
end

struct GraphicsRenderPlan{T, F, E, M, R}
    flattened::F
    viewport::Rectangle{T}
    canvas_width::Int
    canvas_height::Int
    scale::Float64
    content_width::Float64
    content_height::Float64
    view_elements::E
    view_metadata::M
    selected_metadata::Vector{GDSMeta}
    colors::Dict{GDSMeta, NTuple{4, Float64}}
    background::NTuple{4, Float64}
    reference_boxes::R
    options::Dict{Symbol, Any}
end

_rgba(color) = Tuple(Float64.(color))
_meta_sort_key(meta::GDSMeta) = (gdslayer(meta), datatype(meta))

function prepare_graphics_render(
    geom::Union{Cell{T}, CoordinateSystem{T}};
    options...
) where {T}
    opt = Dict{Symbol, Any}(options)
    c0 = flatten(geom; metadata_filter=get(opt, :metadata_filter, nothing))
    viewport = get(opt, :bbox, nothing)
    if !isnothing(viewport) && !(viewport isa Rectangle)
        throw(ArgumentError("bbox must be a Rectangle or nothing"))
    end
    bnd = isnothing(viewport) ? bounds(c0) : convert(Rectangle{T}, viewport)
    w, h = width(ustrip(bnd)), height(ustrip(bnd))
    !isnothing(viewport) &&
        (w <= 0 || h <= 0) &&
        throw(ArgumentError("bbox must have positive width and height"))
    w1, h1 = canvas_size(opt, w, h)
    w1 > 0 && h1 > 0 || throw(ArgumentError("render dimensions must be positive"))
    sf = iszero(w) || iszero(h) ? 1.0 : min(w1 / w, h1 / h)

    view_idx = isempty(elements(c0)) ? Int[] : findbox(bnd, elements(c0); intersects=true)
    view_elements = elements(c0)[view_idx]
    view_metas = default_meta_map.(element_metadata(c0)[view_idx])
    all_metas = default_meta_map.(element_metadata(c0))
    if c0 isa Cell
        append!(all_metas, default_meta_map.(c0.text_metadata))
    end
    unique_metas = sort(unique(all_metas); by=_meta_sort_key)
    colors = Dict{GDSMeta, NTuple{4, Float64}}(
        meta => _rgba(fillcolor(opt, meta)) for meta in unique_metas
    )
    boxes =
        get(opt, :bboxes, false) ? convert.(Rectangle{T}, bounds.(refs(geom))) :
        Rectangle{T}[]

    return GraphicsRenderPlan(
        c0,
        bnd,
        w1,
        h1,
        Float64(sf),
        Float64(sf * w),
        Float64(sf * h),
        view_elements,
        view_metas,
        unique_metas,
        colors,
        _rgba(background_color(get(opt, :background, :transparent))),
        boxes,
        opt
    )
end

function _surface(io, mime::MIMETypes, width, height)
    mime isa MIME"image/png" && return Cairo.CairoARGBSurface(width, height)
    mime isa MIME"image/svg+xml" && return Cairo.CairoSVGSurface(io, width, height)
    mime isa MIME"application/pdf" && return Cairo.CairoPDFSurface(io, width, height)
    mime isa MIME"application/postscript" && return Cairo.CairoEPSSurface(io, width, height)
    return error("unknown mime type")
end

function write_graphics(io, mime::MIMETypes, plan::GraphicsRenderPlan)
    surf = _surface(io, mime, plan.canvas_width, plan.canvas_height)
    ctx = Cairo.CairoContext(surf)
    Cairo.set_source_rgba(ctx, plan.background...)
    Cairo.rectangle(ctx, 0, 0, plan.canvas_width, plan.canvas_height)
    Cairo.fill(ctx)

    # The viewport is top-left anchored. Clip before scaling so geometry crossing the
    # viewport cannot paint into unused canvas space when the aspect ratios differ.
    Cairo.rectangle(ctx, 0, 0, plan.content_width, plan.content_height)
    Cairo.clip(ctx)
    Cairo.scale(ctx, plan.scale, plan.scale)
    trans = Translation(-plan.viewport.ll.x, plan.viewport.ur.y) ∘ XReflection()

    drawn_metas = sort(unique(plan.view_metadata); by=_meta_sort_key)
    for meta in drawn_metas
        Cairo.save(ctx)
        Cairo.set_source_rgba(ctx, plan.colors[meta]...)
        for el in plan.view_elements[plan.view_metadata .== meta]
            tel = trans(el)
            poly!(ctx, tel)
            render_text!(ctx, tel, plan.scale)
        end
        Cairo.fill(ctx)
        Cairo.restore(ctx)
    end

    if plan.flattened isa Cell
        Cairo.save(ctx)
        for (text, meta) in zip(plan.flattened.texts, plan.flattened.text_metadata)
            mapped_meta = default_meta_map(meta)
            Cairo.set_source_rgba(ctx, plan.colors[mapped_meta]...)
            render_text!(ctx, trans(text), plan.scale)
        end
        Cairo.fill(ctx)
        Cairo.restore(ctx)
    end

    for box in plan.reference_boxes
        Cairo.save(ctx)
        Cairo.set_line_width(ctx, 0.5)
        Cairo.set_source_rgb(ctx, 1, 1, 0)
        Cairo.set_dash(ctx, [1.0, 1.0])
        ll = ustrip(trans(box.ll))
        ur = ustrip(trans(box.ur))
        Cairo.rectangle(ctx, ll.x, ur.y, ustrip(width(box)), ustrip(height(box)))
        Cairo.stroke(ctx)
        Cairo.restore(ctx)
    end

    if mime isa MIME"image/png"
        Cairo.write_to_png(surf, io)
    else
        Cairo.finish(surf)
    end
    return io
end

function Base.show(
    io,
    mime::MIMETypes,
    geom::Union{Cell{T}, CoordinateSystem{T}};
    options...
) where {T}
    plan = prepare_graphics_render(geom; options...)
    return write_graphics(io, mime, plan)
end

function poly!(cr::Cairo.CairoContext, pts)
    Cairo.move_to(cr, pts[1].x, pts[1].y)
    for i = 2:length(pts)
        Cairo.line_to(cr, pts[i].x, pts[i].y)
    end
    return Cairo.close_path(cr)
end

poly!(cr::Cairo.CairoContext, p::Polygon) = poly!(cr, ustrip(points(p)))
poly!(cr::Cairo.CairoContext, ps::Vector{<:Polygon}) = poly!.(Ref(cr), ps)
poly!(cr::Cairo.CairoContext, ent::GeometryEntity) = poly!(cr, to_polygons(ent))

function render_text!(ctx, t::GeometryEntity, sf) end

alignstr(::LeftEdge) = "left"
alignstr(::XCenter) = "center"
alignstr(::RightEdge) = "right"
alignstr(::TopEdge) = "top"
alignstr(::YCenter) = "center"
alignstr(::BottomEdge) = "bottom"

function render_text!(ctx, t::Text, sf)
    fontsize = Int(round(iszero(t.width) ? 12 * t.mag : (ustrip(t.width) * sf * t.mag)))
    pos = ustrip(t.origin)
    Cairo.set_font_face(ctx, "Serif $fontsize")
    return Cairo.text(
        ctx,
        pos.x,
        pos.y,
        t.text;
        halign=alignstr(t.xalign),
        valign=alignstr(t.yalign),
        angle=-t.rot * 180 / pi
    )
end

function _save_graphics(f::File, mime::MIMETypes, geom; options...)
    plan = prepare_graphics_render(geom; options...)
    return open(f, "w") do s
        return write_graphics(stream(s), mime, plan)
    end
end

save(f::File{format"SVG"}, c0::Cell; options...) =
    _save_graphics(f, MIME"image/svg+xml"(), c0; options...)
save(f::File{format"PDF"}, c0::Cell; options...) =
    _save_graphics(f, MIME"application/pdf"(), c0; options...)
save(f::File{format"EPS"}, c0::Cell; options...) =
    _save_graphics(f, MIME"application/postscript"(), c0; options...)
save(f::File{format"PNG"}, c0::Cell; options...) =
    _save_graphics(f, MIME"image/png"(), c0; options...)

function _graphics_format(path::AbstractString)
    ext = lowercase(splitext(path)[2])
    ext == ".png" && return "png", MIME"image/png"()
    ext == ".svg" && return "svg", MIME"image/svg+xml"()
    ext == ".pdf" && return "pdf", MIME"application/pdf"()
    ext == ".eps" && return "eps", MIME"application/postscript"()
    throw(ArgumentError("render image path must end in .png, .svg, .pdf, or .eps"))
end

_default_manifest_path(image_path::AbstractString) =
    splitext(image_path)[1] * ".render.json"

function _metadata_record(meta::GDSMeta)
    return Dict{String, Any}(
        "type" => "GDSMeta",
        "layer" => gdslayer(meta),
        "datatype" => datatype(meta)
    )
end

function _metadata_record(meta::Meta)
    return Dict{String, Any}(
        "type" => String(nameof(typeof(meta))),
        "layer" => layername(meta),
        "level" => level(meta),
        "index" => layerindex(meta)
    )
end

function _mapping_sort_key(mapping::Pair)
    source, target = mapping
    return (
        String(nameof(typeof(source))),
        layername(source),
        level(source),
        layerindex(source),
        gdslayer(target),
        datatype(target)
    )
end

function _mapping_records(mappings, selected_metadata)
    selected = Set(selected_metadata)
    filtered = unique(mapping for mapping in mappings if mapping.second in selected)
    sort!(filtered; by=_mapping_sort_key)
    return [
        Dict{String, Any}(
            "source" => _metadata_record(mapping.first),
            "target" => _metadata_record(mapping.second)
        ) for mapping in filtered
    ]
end

_coordinate_unit(x::Length) = string(unit(x))
_coordinate_unit(x::Real) = "unitless"

function _dimension_request(options, key, canvas_unit)
    haskey(options, key) || return nothing
    value = options[key]
    if value isa Length
        return Dict{String, Any}(
            "value" => Float64(ustrip(value)),
            "unit" => string(unit(value))
        )
    end
    return Dict{String, Any}("value" => Float64(value), "unit" => canvas_unit)
end

function _background_request(options)
    value = get(options, :background, :transparent)
    isnothing(value) && return "transparent"
    value isa Symbol && return String(value)
    return collect(Float64.(value))
end

_manifest_value(value::Length) =
    Dict{String, Any}("value" => Float64(ustrip(value)), "unit" => string(unit(value)))
_manifest_value(value::Symbol) = String(value)
_manifest_value(value::Union{Nothing, Bool, AbstractString}) = value
_manifest_value(value::Real) =
    isfinite(value) ? (value isa Integer ? value : Float64(value)) : string(value)
_manifest_value(value::NamedTuple) = Dict{String, Any}(
    String(key) => _manifest_value(entry) for (key, entry) in pairs(value)
)
_manifest_value(value::Union{Tuple, AbstractVector}) = _manifest_value.(collect(value))
_manifest_value(value) =
    Dict{String, Any}("type" => String(nameof(typeof(value))), "repr" => repr(value))

function _geometry_manifest(plan, manifest_source, rendered_fingerprint)
    geometry = Dict{String, Any}(
        "type" => String(nameof(typeof(manifest_source))),
        "name" => name(manifest_source),
        "unit" => _coordinate_unit(plan.viewport.ll.x)
    )
    if !isnothing(rendered_fingerprint)
        geometry["rendered_cell_fingerprint"] = Dict{String, Any}(
            "algorithm" => "DeviceLayout.Cells.geometry_fingerprint",
            "sha256" => rendered_fingerprint
        )
    end
    return geometry
end

function _layout_to_canvas_manifest(plan, canvas_unit)
    bnd = ustrip(plan.viewport)
    xmin, ymin = Float64(bnd.ll.x), Float64(bnd.ll.y)
    xmax, ymax = Float64(bnd.ur.x), Float64(bnd.ur.y)
    sf = plan.scale
    invertible = !iszero(sf)
    matrix = [[sf, 0.0, -sf * xmin], [0.0, -sf, sf * ymax], [0.0, 0.0, 1.0]]
    inverse =
        invertible ? [[1 / sf, 0.0, xmin], [0.0, -1 / sf, ymax], [0.0, 0.0, 1.0]] : nothing
    return Dict{String, Any}(
        "matrix" => matrix,
        "output_unit" => canvas_unit,
        "inverse" => inverse,
        "invertible" => invertible,
        "anchoring" => "top-left",
        "content_rect" => Dict{String, Any}(
            "xmin" => 0.0,
            "ymin" => 0.0,
            "xmax" => plan.content_width,
            "ymax" => plan.content_height,
            "unit" => canvas_unit
        )
    )
end

function _metadata_manifest(plan, mappings)
    selected_metadata = _metadata_record.(plan.selected_metadata)
    resolved_colors = [
        Dict{String, Any}(
            "metadata" => _metadata_record(meta),
            "rgba" => collect(plan.colors[meta])
        ) for meta in plan.selected_metadata
    ]
    return selected_metadata,
    _mapping_records(mappings, plan.selected_metadata),
    resolved_colors
end

function _render_options_manifest(plan, geometry_render_options, canvas_unit)
    render_options = Dict{String, Any}(
        "width" => _dimension_request(plan.options, :width, canvas_unit),
        "height" => _dimension_request(plan.options, :height, canvas_unit),
        "dpi" => Float64(get(plan.options, :dpi, DEFAULT_RENDER_DPI)),
        "bboxes" => get(plan.options, :bboxes, false),
        "bbox_requested" => !isnothing(get(plan.options, :bbox, nothing))
    )
    if !haskey(plan.options, :width) && !haskey(plan.options, :height)
        render_options["default_max_dimension"] =
            _manifest_value(DEFAULT_RENDER_MAX_DIMENSION)
    end
    if !isnothing(geometry_render_options)
        render_options["geometry_render_options"] = _manifest_value(geometry_render_options)
    end
    return render_options
end

function _render_info(
    plan,
    manifest_source,
    mappings,
    rendered_fingerprint,
    geometry_render_options,
    format
)
    bnd = ustrip(plan.viewport)
    geometry_unit = _coordinate_unit(plan.viewport.ll.x)
    canvas_unit = format in ("pdf", "eps") ? "pt" : "px"
    selected_metadata, metadata_mapping, resolved_colors =
        _metadata_manifest(plan, mappings)
    return RenderInfo(
        _geometry_manifest(plan, manifest_source, rendered_fingerprint),
        Dict{String, Any}(
            "xmin" => Float64(bnd.ll.x),
            "ymin" => Float64(bnd.ll.y),
            "xmax" => Float64(bnd.ur.x),
            "ymax" => Float64(bnd.ur.y),
            "unit" => geometry_unit
        ),
        Dict{String, Any}(
            "width" => plan.canvas_width,
            "height" => plan.canvas_height,
            "unit" => canvas_unit
        ),
        _layout_to_canvas_manifest(plan, canvas_unit),
        isnothing(get(plan.options, :metadata_filter, nothing)) ? "all" : "filtered",
        selected_metadata,
        metadata_mapping,
        resolved_colors,
        Dict{String, Any}(
            "requested" => _background_request(plan.options),
            "rgba" => collect(plan.background)
        ),
        _render_options_manifest(plan, geometry_render_options, canvas_unit)
    )
end

function _manifest_dict(artifact::RenderArtifact)
    info = artifact.info
    return Dict{String, Any}(
        "schema_version" => RENDER_MANIFEST_SCHEMA_VERSION,
        "image" => relpath(artifact.image_path, dirname(artifact.manifest_path)),
        "image_sha256" => artifact.image_sha256,
        "format" => artifact.format,
        "geometry" => info.geometry,
        "viewport" => info.viewport,
        "canvas" => info.canvas,
        "layout_to_canvas" => info.layout_to_canvas,
        "metadata_selection" => info.metadata_selection,
        "selected_metadata" => info.selected_metadata,
        "metadata_mapping" => info.metadata_mapping,
        "resolved_colors" => info.resolved_colors,
        "background" => info.background,
        "render_options" => info.render_options
    )
end

function _write_manifest_temp(directory, manifest)
    tmp_path, io = mktemp(directory)
    succeeded = false
    try
        JSON.json(io, manifest; pretty=true)
        write(io, '\n')
        close(io)
        # mktemp uses a private mode; published artifacts follow ordinary file output.
        chmod(tmp_path, 0o644)
        succeeded = true
        return tmp_path
    finally
        isopen(io) && close(io)
        !succeeded && isfile(tmp_path) && rm(tmp_path; force=true)
    end
end

function _save_render(
    image_path::AbstractString,
    rendered_geom::Union{Cell, CoordinateSystem},
    manifest_source=rendered_geom,
    mappings=Pair{Meta, GDSMeta}[];
    manifest_path=nothing,
    rendered_fingerprint=rendered_geom isa Cell ?
                         Cells.geometry_fingerprint(rendered_geom) : nothing,
    geometry_render_options=nothing,
    options...
)
    image_abs = abspath(image_path)
    manifest_abs = abspath(
        isnothing(manifest_path) ? _default_manifest_path(image_path) : manifest_path
    )
    image_abs == manifest_abs &&
        throw(ArgumentError("manifest_path must differ from image_path"))
    isdir(dirname(image_abs)) ||
        throw(ArgumentError("image output directory does not exist: $(dirname(image_abs))"))
    isdir(dirname(manifest_abs)) || throw(
        ArgumentError("manifest output directory does not exist: $(dirname(manifest_abs))")
    )
    isdir(image_abs) && throw(ArgumentError("image_path cannot be a directory"))
    isdir(manifest_abs) && throw(ArgumentError("manifest_path cannot be a directory"))
    format, mime = _graphics_format(image_abs)
    plan = prepare_graphics_render(rendered_geom; options...)

    image_tmp, image_io = mktemp(dirname(image_abs))
    manifest_tmp = nothing
    try
        write_graphics(image_io, mime, plan)
        close(image_io)
        # Match the permissions of ordinary file output rather than mktemp's 0600 mode.
        chmod(image_tmp, 0o644)
        image_sha256 = open(SHA.sha256, image_tmp) |> bytes2hex
        info = _render_info(
            plan,
            manifest_source,
            mappings,
            rendered_fingerprint,
            geometry_render_options,
            format
        )
        artifact = RenderArtifact(image_abs, manifest_abs, image_sha256, format, info)
        manifest_tmp = _write_manifest_temp(dirname(manifest_abs), _manifest_dict(artifact))

        # Remove the old sidecar before replacing the image. A publication failure can
        # leave an image without a manifest, but never a stale manifest paired with it.
        isfile(manifest_abs) && rm(manifest_abs; force=true)
        mv(image_tmp, image_abs; force=true)
        image_tmp = nothing
        mv(manifest_tmp, manifest_abs; force=true)
        manifest_tmp = nothing
        return artifact
    finally
        isopen(image_io) && close(image_io)
        !isnothing(image_tmp) && isfile(image_tmp) && rm(image_tmp; force=true)
        !isnothing(manifest_tmp) && isfile(manifest_tmp) && rm(manifest_tmp; force=true)
    end
end

function _validate_public_render_options(options)
    for key in (:rendered_fingerprint, :geometry_render_options)
        haskey(options, key) &&
            throw(ArgumentError("$key is reserved for internal render provenance"))
    end
end

function save_render(
    image_path::AbstractString,
    geom::Union{Cell, CoordinateSystem};
    manifest_path=nothing,
    options...
)
    _validate_public_render_options(options)
    return _save_render(image_path, geom; manifest_path=manifest_path, options...)
end

end
