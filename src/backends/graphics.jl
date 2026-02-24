module Graphics
using Unitful
import Unitful: Length, inch, ustrip
import Cairo

import DeviceLayout:
    bounds, datatype, default_meta_map, element_metadata, gdslayer, load, save, to_polygons
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

function fillcolor(options, layer)
    haskey(options, :layercolors) &&
        haskey(options[:layercolors], layer) &&
        return options[:layercolors][layer]
    haskey(layercolors, layer) && return layercolors[layer]
    return (0.0, 0.0, 0.0, 0.5)
end

lscale(x::Length)  = round(NoUnits((x |> inch) * 72 / inch))
lscale(x::Integer) = x
lscale(x::Real)    = Int(round(x))

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
    c0 = flatten(geom)
    opt = Dict{Symbol, Any}(options)
    bnd = bounds(c0)
    w, h = width(ustrip(bnd)), height(ustrip(bnd))
    w1 = haskey(opt, :width) ? lscale(opt[:width]) : 4 * 72
    h1 = haskey(opt, :height) ? lscale(opt[:height]) : 4 * 72
    bboxes = haskey(opt, :bboxes) ? opt[:bboxes] : false

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
    if mime isa MIME"image/png"
        # Transparent background
        Cairo.set_source_rgba(ctx, 0.0, 0.0, 0.0, 0.0)
        Cairo.rectangle(ctx, 0, 0, w1, h1)
        Cairo.fill(ctx)
    end

    ly = collect(gdslayers(c0))
    trans = Translation(-bnd.ll.x, bnd.ur.y) ∘ XReflection()

    sf = min(w1 / w, h1 / h)
    Cairo.scale(ctx, sf, sf)

    for l in sort(ly)
        Cairo.save(ctx)
        Cairo.set_source_rgba(ctx, fillcolor(options, l)...)
        for el in c0.elements[gdslayer.(default_meta_map.(element_metadata(c0))) .== l]
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
            Cairo.set_source_rgba(ctx, fillcolor(options, gdslayer(meta))...)
            render_text!(ctx, trans(t), sf)
        end
        Cairo.fill(ctx)
        Cairo.restore(ctx)
    end

    if bboxes
        for ref in c0.refs
            Cairo.save(ctx)
            r = convert(Rectangle{T}, bounds(ref))
            Cairo.set_line_width(ctx, 0.5)
            Cairo.set_source_rgb(ctx, 1, 1, 0)
            Cairo.set_dash(ctx, [1.0, 1.0])
            Cairo.rectangle(
                ctx,
                trans(ustrip(r.ll)).x,
                trans(ustrip(r.ur)).y,
                ustrip(width(r)),
                ustrip(height(r))
            )
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
