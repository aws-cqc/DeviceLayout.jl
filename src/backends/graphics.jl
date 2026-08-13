module Graphics
using Unitful
import Unitful: Length, inch, ustrip
import Cairo

import DeviceLayout:
    bounds,
    datatype,
    default_meta_map,
    element_metadata,
    gdslayer,
    load,
    refs,
    save,
    to_polygons
import DeviceLayout: CoordinateSystem, GeometryEntity
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
    return layercolors[color_index]
end

lscale(x::Length, dpi)  = round(Int, NoUnits((x |> inch) * dpi / inch))
lscale(x::Integer, dpi) = x
lscale(x::Real, dpi)    = Int(round(x))

function canvas_size(options, w, h)
    dpi = get(options, :dpi, 72)
    dpi isa Real && dpi > 0 || throw(ArgumentError("dpi must be a positive number"))
    has_width = haskey(options, :width)
    has_height = haskey(options, :height)
    default_size = lscale(4inch, dpi)
    if has_width && has_height
        return lscale(options[:width], dpi), lscale(options[:height], dpi)
    elseif has_width
        w1 = lscale(options[:width], dpi)
        return w1, iszero(w) || iszero(h) ? w1 : Int(ceil(w1 * h / w))
    elseif has_height
        h1 = lscale(options[:height], dpi)
        return iszero(w) || iszero(h) ? h1 : Int(ceil(h1 * w / h)), h1
    end
    return (
        default_size,
        iszero(w) || iszero(h) ? default_size : Int(ceil(default_size * h / w))
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
function Base.show(
    io,
    mime::MIMETypes,
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
    bboxes = get(opt, :bboxes, false)

    surf = if mime isa MIME"image/png"
        Cairo.CairoARGBSurface(w1, h1)
    elseif mime isa MIME"image/svg+xml"
        Cairo.CairoSVGSurface(io, w1, h1)
    elseif mime isa MIME"application/pdf"
        Cairo.CairoPDFSurface(io, w1, h1)
    elseif mime isa MIME"application/postscript"
        Cairo.CairoEPSSurface(io, w1, h1)
    else
        error("unknown mime type.")
    end

    ctx = Cairo.CairoContext(surf)
    Cairo.set_source_rgba(ctx, background_color(get(opt, :background, :transparent))...)
    Cairo.rectangle(ctx, 0, 0, w1, h1)
    Cairo.fill(ctx)

    metas = default_meta_map.(element_metadata(c0))
    unique_metas = sort(unique(metas), by=meta -> (gdslayer(meta), datatype(meta)))
    trans = Translation(-bnd.ll.x, bnd.ur.y) ∘ XReflection()

    sf = iszero(w) || iszero(h) ? 1.0 : min(w1 / w, h1 / h)
    Cairo.scale(ctx, sf, sf)

    for meta in unique_metas
        Cairo.save(ctx)
        Cairo.set_source_rgba(ctx, fillcolor(opt, meta)...)
        for el in c0.elements[metas .== meta]
            tel = trans(el)
            poly!(ctx, tel)
            render_text!(ctx, tel, sf)
        end
        Cairo.fill(ctx)
        Cairo.restore(ctx)
    end

    if c0 isa Cell
        Cairo.save(ctx)
        for (t, meta) in zip(c0.texts, c0.text_metadata)
            Cairo.set_source_rgba(ctx, fillcolor(opt, default_meta_map(meta))...)
            render_text!(ctx, trans(t), sf)
        end
        Cairo.fill(ctx)
        Cairo.restore(ctx)
    end

    if bboxes
        for ref in refs(geom)
            Cairo.save(ctx)
            r = convert(Rectangle{T}, bounds(ref))
            Cairo.set_line_width(ctx, 0.5)
            Cairo.set_source_rgb(ctx, 1, 1, 0)
            Cairo.set_dash(ctx, [1.0, 1.0])
            ll = ustrip(trans(r.ll))
            ur = ustrip(trans(r.ur))
            Cairo.rectangle(ctx, ll.x, ur.y, ustrip(width(r)), ustrip(height(r)))
            Cairo.stroke(ctx)
            Cairo.restore(ctx)
        end
    end

    if mime isa MIME"image/png"
        Cairo.write_to_png(surf, io)
    else
        Cairo.finish(surf)
    end
    return io
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

function save(f::File{format"SVG"}, c0::Cell; options...)
    open(f, "w") do s
        io = stream(s)
        return show(io, MIME"image/svg+xml"(), c0; options...)
    end
end
function save(f::File{format"PDF"}, c0::Cell; options...)
    open(f, "w") do s
        io = stream(s)
        return show(io, MIME"application/pdf"(), c0; options...)
    end
end
function save(f::File{format"EPS"}, c0::Cell; options...)
    open(f, "w") do s
        io = stream(s)
        return show(io, MIME"application/postscript"(), c0; options...)
    end
end
function save(f::File{format"PNG"}, c0::Cell; options...)
    open(f, "w") do s
        io = stream(s)
        return show(io, MIME"image/png"(), c0; options...)
    end
end

end
