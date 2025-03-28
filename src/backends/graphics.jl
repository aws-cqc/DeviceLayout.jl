module Graphics
using Unitful
import Unitful: Length, inch, ustrip
import Cairo

import DeviceLayout: bounds, datatype, gdslayer, load, save
using ..Points
using ..Transformations
import ..Rectangles: Rectangle, width, height
import ..Polygons: Polygon, points
using ..Cells

import FileIO: File, @format_str, stream

using ColorSchemes

using ColorSchemes
# Glasbey color scheme for categorical data (version avoiding greys and light colors)
lcolor(l, scheme=:glasbey_bw_minc_20_maxl_70_n256) = # Make transparent
    (
        colorschemes[scheme][l + 1].r,
        colorschemes[scheme][l + 1].g,
        colorschemes[scheme][l + 1].b,
        0.5
    )
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
function Base.show(io, mime::MIMETypes, c0::Cell{T}; options...) where {T}
    opt = Dict{Symbol, Any}(options)
    bnd = ustrip(bounds(c0))
    w, h = width(bnd), height(bnd)
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

    ly = collect(layers(c0))
    trans = Translation(-bnd.ll.x, bnd.ur.y) ∘ XReflection()

    sf = min(w1 / w, h1 / h)
    Cairo.scale(ctx, sf, sf)

    for l in sort(ly)
        Cairo.save(ctx)
        Cairo.set_source_rgba(ctx, fillcolor(options, l)...)
        for p in c0.elements[gdslayer.(c0.element_metadata) .== l]
            poly!(ctx, trans.(ustrip(points(p))))
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
