import Clipper

struct DotMatrix{S <: Coordinate, T <: AbstractCoordinateSystem{S}, M} <: Style{S}
    pixelmap::Dict{Char, T}
    pixelsize::S
    pixelspacing::S
    rounding::S
    meta::M
end
function DotMatrix(
    pixelmap::Dict{Char, X},
    pixelsize,
    pixelspacing,
    rounding,
    meta
) where {T, X <: AbstractCoordinateSystem{T}}
    M = typeof(meta)
    return DotMatrix{T, X, M}(
        pixelmap,
        convert.(Ref(T), (pixelsize, pixelspacing, rounding))...,
        meta
    )
end

"""
    DotMatrix(; pixelsize, pixelspacing=pixelsize,
                rounding=zero(pixelsize), meta::Meta=GDSMeta(0,0))

# Keyword args

  - `pixelsize`: dimension for the width/height of each pixel.
  - `pixelspacing`: dimension for the spacing between adjacent pixels. Should be ≥ pixelsize.
    Defaults to `pixelsize`.
  - `rounding`: rounding radius for sharp corners of pixels. If `pixelsize == pixelspacing`,
    individual pixels are not rounded, but rather the pixels are unioned and the entire letter
    will be rounded.
  - `meta`: layer/datatype or similar info.
"""
function DotMatrix(;
    pixelsize,
    pixelspacing=pixelsize,
    rounding=zero(pixelsize),
    meta::Meta=GDSMeta(0, 0)
)
    pixelspacing ≥ pixelsize ||
        throw(ArgumentError("pixelspacing needs to be ≥ pixelsize."))
    all(x -> x isa Length, (pixelsize, pixelspacing, rounding)) ||
        all(isreal, (pixelsize, pixelspacing, rounding)) ||
        throw(
            ArgumentError(
                "pixelsize, pixelspacing, rounding need to have the same dimensions."
            )
        )
    sz, sp, r = promote(float(pixelsize), pixelspacing, rounding)
    z = zero(sz)

    pixelmap = Dict{Char, CoordinateSystem{typeof(sz)}}()

    pixel_block1 = CoordinateSystem{typeof(sz)}(uniquename("pixel_block"))
    pixel_block2 = CoordinateSystem{typeof(sz)}(uniquename("pixel_block"))
    pixel_topleft = CoordinateSystem{typeof(sz)}(uniquename("pixel_topleft"))
    pixel_topright = CoordinateSystem{typeof(sz)}(uniquename("pixel_topright"))
    pixel_bottomright = CoordinateSystem{typeof(sz)}(uniquename("pixel_bottomright"))
    pixel_bottomleft = CoordinateSystem{typeof(sz)}(uniquename("pixel_bottomleft"))

    let
        sty = OptionalStyle(
            NoRender(),
            :simulation;
            false_style=((iszero(r) | iszero(sp - sz)) ? Plain() : Polygons.Rounded(r)),
            default=false
        )
        # sty = (iszero(r) | iszero(sp - sz)) ? Plain() : Polygons.Rounded(r)
        render!(pixel_block1, sty(Rectangle(sz, sz)), meta)
        render!(pixel_block2, sty(Rectangle(sz, sz)), meta)
        render!(
            pixel_topleft,
            sty(Polygon([Point(z, z), Point(sz, z), Point(sz, sz)])),
            meta
        )
        render!(
            pixel_topright,
            sty(Polygon([Point(z, z), Point(sz, z), Point(z, sz)])),
            meta
        )
        render!(
            pixel_bottomright,
            sty(Polygon([Point(z, z), Point(sz, sz), Point(z, sz)])),
            meta
        )
        render!(
            pixel_bottomleft,
            sty(Polygon([Point(z, sz), Point(sz, z), Point(sz, sz)])),
            meta
        )
    end

    pixelmap['█'] = pixel_block1
    pixelmap['■'] = pixel_block2
    pixelmap['◢'] = pixel_topleft
    pixelmap['◣'] = pixel_topright
    pixelmap['◤'] = pixel_bottomright
    pixelmap['◥'] = pixel_bottomleft

    return DotMatrix(pixelmap, sz, sp, rounding, meta)
end

toptype(::Type{<:CoordinateSystem}) = CoordinateSystem
toptype(::Type{<:Cell}) = Cell

default_top(::Style{T}) where {T} = CoordinateSystem{float(T)}
default_top(::DotMatrix{S, Cell{T}}) where {S, T} = Cell{float(T)}

function promotestyle(c::AbstractCoordinateSystem{S}, sty::DotMatrix{T, U}) where {S, T, U}
    toptype(typeof(c)) <: toptype(U) && return sty
    newmap = Dict{Char, typeof(c)}()
    for (k, v) in sty.pixelmap
        newmap[k] = typeof(c)(v)
    end
    return DotMatrix{S, typeof(c), typeof(sty.meta)}(
        newmap,
        sty.pixelsize,
        sty.pixelspacing,
        sty.rounding,
        sty.meta
    )
end

function renderchar!(sty::DotMatrix, c, s, existing_chars, hpos, vpos, offset, verbose)
    pixelmap, sz, sp, r = sty.pixelmap, sty.pixelsize, sty.pixelspacing, sty.rounding
    if !haskey(existing_chars, s)
        verbose &&
            println("Character '", s, "' not found. Adding to CoordSysRef dictionary.")
        if haskey(lcd, s)
            s_cs = drawchar(lcd[s], pixelmap, sp)
            if sz == sp
                # Pixels are touching, fuse then optionally style again.
                flatten!(s_cs)
                pix_ent = DeviceLayout.unstyled.(s_cs.elements)
                poly = union2d(pix_ent)
                empty!(s_cs.elements)
                empty!(s_cs.element_metadata)
                empty!(s_cs.refs)
                opt_sty = OptionalStyle(
                    NoRender(),
                    :simulation;
                    false_style=iszero(r) ? Plain() : Rounded(r),
                    default=false
                )
                render!(s_cs, styled(poly, opt_sty), sty.meta)
            end
            crs = sref(s_cs, Point(zero(sp), zero(sp)))
            push!(c.refs, crs + Point(sp * 6 * (hpos - 1), -11 * sp * (vpos - offset)))
            existing_chars[s] = crs
        else
            @warn string(
                "Cannot render '",
                s,
                "' character. Replacing with a blank character."
            )
        end
    else
        cr = existing_chars[s]
        verbose && println("Character '", s, "' already in dictionary.")
        push!(c.refs, cr + Point(sp * 6 * (hpos - 1), -11 * sp * (vpos - offset)))
    end
end

function drawchar(code::String, pixelmap::Dict{Char, T}, pixelspacing) where {T}
    c = T(uniquename("lcd"))
    return drawchar!(c, code, pixelmap, pixelspacing)
end

function drawchar!(c::AbstractCoordinateSystem, code::String, pixelmap, pixelspacing)
    idx = 1
    for row = 1:10
        for col = 1:5
            i = nextind(code, 0, idx)
            if code[i] in keys(pixelmap)
                push!(
                    c.refs,
                    sref(
                        pixelmap[code[i]],
                        Point(pixelspacing * (col - 1), pixelspacing * (10 - row))
                    )
                )
            end
            idx += 1
        end
    end
    return c
end

macro lcd_str(s)
    return :(replace($(esc(s)), r"\s+" => ""))
end

# Horizontal Pixels = 5
# Vertical Pixels = 7 (regular) + 3 (for stems)
const lcd_short = lcd"""
    .....
    .....
    .....
    """
const lcd_blank = lcd"""
    .....
    .....
    .....
    .....
    .....
    .....
    .....
    """ * lcd_short
const lcd_filled = lcd"""
   █████
   █████
   █████
   █████
   █████
   █████
   █████
   █████
   █████
   █████
   """
const lcd = Dict{Char, String}(
    'A'  => lcd"""
        ◢■■■◣
        █...█
        █...█
        █...█
        █████
        █...█
        █...█
        """ * lcd_short,
    'B'  => lcd"""
        ■■■■◣
        █...█
        █..◢◤
        █■■■.
        █..◥◣
        █...█
        ■■■■◤
        """ * lcd_short,
    'C'  => lcd"""
        ◢■■■◣
        █...█
        █....
        █....
        █....
        █...█
        ◥■■■◤
        """ * lcd_short,
    'D'  => lcd"""
        ■■■◣.
        █..◥◣
        █...█
        █...█
        █...█
        █..◢◤
        ■■■◤.
        """ * lcd_short,
    'E'  => lcd"""
        █████
        █....
        █....
        ████.
        █....
        █....
        █████
        """ * lcd_short,
    'F'  => lcd"""
        █████
        █....
        █....
        ████.
        █....
        █....
        █....
        """ * lcd_short,
    'G'  => lcd"""
        ◢■■■◣
        █...█
        █....
        █.███
        █...█
        █...█
        ◥■■■◤
        """ * lcd_short,
    'H'  => lcd"""
        █...█
        █...█
        █...█
        █████
        █...█
        █...█
        █...█
        """ * lcd_short,
    'I'  => lcd"""
        .███.
        ..█..
        ..█..
        ..█..
        ..█..
        ..█..
        .███.
        """ * lcd_short,
    'J'  => lcd"""
        ..███
        ...█.
        ...█.
        ...█.
        ...█.
        █..█.
        ◥■■◤.
        """ * lcd_short,
    'K'  => lcd"""
        █..◢■
        █.◢◤.
        █■◤..
        ■■◣..
        █.◥◣.
        █..◥◣
        █...█
        """ * lcd_short,
    'L'  => lcd"""
        █....
        █....
        █....
        █....
        █....
        █....
        █████
        """ * lcd_short,
    'M'  => lcd"""
        ■◣.◢■
        █████
        █.█.█
        █.█.█
        █...█
        █...█
        █...█
        """ * lcd_short,
    'N'  => lcd"""
        █...█
        █...█
        █■◣.█
        █.█.█
        █.◥■█
        █...█
        █...█
        """ * lcd_short,
    'O'  => lcd"""
        ◢■■■◣
        █...█
        █...█
        █...█
        █...█
        █...█
        ◥■■■◤
        """ * lcd_short,
    'P'  => lcd"""
        ■■■■◣
        █...█
        █...█
        █■■■◤
        █....
        █....
        █....
        """ * lcd_short,
    'Q'  => lcd"""
        ◢■■■◣
        █...█
        █...█
        █...█
        █.█.█
        █.◥◣.
        ◥■.◥█
        """ * lcd_short,
    'R'  => lcd"""
        ■■■■◣
        █...█
        █...█
        █■■■◤
        █.█..
        █.◥◣.
        █..◥■
        """ * lcd_short,
    'S'  => lcd"""
        ◢■■■■
        █....
        █....
        ◥■■■◣
        ....█
        ....█
        ■■■■◤
        """ * lcd_short,
    'T'  => lcd"""
        █████
        ..█..
        ..█..
        ..█..
        ..█..
        ..█..
        ..█..
        """ * lcd_short,
    'U'  => lcd"""
        █...█
        █...█
        █...█
        █...█
        █...█
        █...█
        ◥■■■◤
        """ * lcd_short,
    'V'  => lcd"""
        █...█
        █...█
        █...█
        █...█
        █...█
        ◥◣.◢◤
        .◥■◤.
        """ * lcd_short,
    'W'  => lcd"""
        █...█
        █...█
        █...█
        █.█.█
        █.█.█
        █.█.█
        ◥■■■◤
        """ * lcd_short,
    'X'  => lcd"""
        █...█
        █...█
        ◥◣.◢◤
        .■■■.
        ◢◤.◥◣
        █...█
        █...█
        """ * lcd_short,
    'Y'  => lcd"""
        █...█
        █...█
        █...█
        ◥◣.◢◤
        .◥■◤.
        ..█..
        ..█..
        """ * lcd_short,
    'Z'  => lcd"""
        █████
        ....█
        ..◢■◤
        .◢◤..
        ◢◤...
        █....
        █████
        """ * lcd_short,
    'a'  => lcd"""
        .....
        .....
        .■■■◣
        ....█
        ◢■■■█
        █...█
        ◥■■■█
        """ * lcd_short,
    'b'  => lcd"""
        █....
        █....
        █.◢■◣
        █■◤.█
        █...█
        █...█
        █■■■◤
        """ * lcd_short,
    'c'  => lcd"""
        .....
        .....
        ◢■■■.
        █....
        █....
        █...█
        ◥■■■◤
        """ * lcd_short,
    'd'  => lcd"""
        ....█
        ....█
        ◢■◣.█
        █.◥■█
        █...█
        █...█
        ◥■■■█
        """ * lcd_short,
    'e'  => lcd"""
        .....
        .....
        ◢■■■◣
        █...█
        █████
        █....
        ◥■■■.
        """ * lcd_short,
    'f'  => lcd"""
        .◢■■◣
        .█..█
        .█...
        ███..
        .█...
        .█...
        .█...
        """ * lcd_short,
    'g'  => lcd"""
        .....
        .....
        ◢■■■█
        █...█
        █...█
        █...█
        ◥■■■█
        ....█
        ....█
        .■■■◤
        """,
    'h'  => lcd"""
        █....
        █....
        █.◢■◣
        █■◤.█
        █...█
        █...█
        █...█
        """ * lcd_short,
    'i'  => lcd"""
        ..█..
        .....
        .██..
        ..█..
        ..█..
        ..█..
        .███.
        """ * lcd_short,
    'j'  => lcd"""
        ...█.
        .....
        ..██.
        ...█.
        ...█.
        █..█.
        ◥■■◤.
        """ * lcd_short,
    'k'  => lcd"""
        █....
        █....
        █.◢■.
        █■◤..
        █■◣..
        █.◥◣.
        █..◥■
        """ * lcd_short,
    'l'  => lcd"""
        .██..
        ..█..
        ..█..
        ..█..
        ..█..
        ..█..
        .███.
        """ * lcd_short,
    'm'  => lcd"""
        .....
        .....
        ■■■■◣
        █.█.█
        █.█.█
        █...█
        █...█
        """ * lcd_short,
    'n'  => lcd"""
        .....
        .....
        █.◢■◣
        █■◤.█
        █...█
        █...█
        █...█
        """ * lcd_short,
    'o'  => lcd"""
        .....
        .....
        ◢■■■◣
        █...█
        █...█
        █...█
        ◥■■■◤
        """ * lcd_short,
    'p'  => lcd"""
        .....
        .....
        █.◢■◣
        █■◤.█
        █...█
        █...█
        █■■■◤
        █....
        █....
        █....
        """,
    'q'  => lcd"""
        .....
        .....
        ◢■◣.█
        █.◥■█
        █...█
        █...█
        ◥■■■█
        ....█
        ....█
        ....█
        """,
    'r'  => lcd"""
        .....
        .....
        █.◢■◣
        █■◤.█
        █....
        █....
        █....
        """ * lcd_short,
    's'  => lcd"""
        .....
        .....
        ◢■■■.
        █....
        ◥■■■◣
        ....█
        ■■■■◤
        """ * lcd_short,
    't'  => lcd"""
        .█...
        .█...
        ███..
        .█...
        .█...
        .█..█
        .◥■■◤
        """ * lcd_short,
    'u'  => lcd"""
        .....
        .....
        █...█
        █...█
        █...█
        █.◢■█
        ◥■◤.█
        """ * lcd_short,
    'v'  => lcd"""
        .....
        .....
        █...█
        █...█
        █...█
        ◥◣.◢◤
        .◥■◤.
        """ * lcd_short,
    'w'  => lcd"""
        .....
        .....
        █...█
        █...█
        █.█.█
        █.█.█
        ◥■■■◤
        """ * lcd_short,
    'x'  => lcd"""
        .....
        .....
        █...█
        ◥◣.◢◤
        .■■■.
        ◢◤.◥◣
        █...█
        """ * lcd_short,
    'y'  => lcd"""
        .....
        .....
        █...█
        █...█
        █...█
        █...█
        ◥■■■█
        ....█
        ....█
        .■■■◤
        """,
    'z'  => lcd"""
        .....
        .....
        █████
        ....█
        ◢■■■◤
        █....
        █████
        """ * lcd_short,
    '0'  => lcd"""
        ◢■■■◣
        █...█
        █.◢■█
        █.█.█
        █■◤.█
        █...█
        ◥■■■◤
        """ * lcd_short,
    '1'  => lcd"""
        .◢█..
        .██..
        ..█..
        ..█..
        ..█..
        ..█..
        .███.
        """ * lcd_short,
    '2'  => lcd"""
        ◢■■■◣
        █...█
        ....█
        ..◢■◤
        .◢◤..
        ◢■...
        █████
        """ * lcd_short,
    '3'  => lcd"""
        █████
        ...█.
        ..■◤.
        ..◥◣.
        ...◥◣
        █...█
        ◥■■■◤
        """ * lcd_short,
    '4'  => lcd"""
        ..◢■.
        .◢■■.
        ◢◤.█.
        █..█.
        █████
        ...█.
        ...█.
        """ * lcd_short,
    '5'  => lcd"""
        █████
        █....
        ■■■■◣
        ....█
        ....█
        █...█
        ◥■■■◤
        """ * lcd_short,
    '6'  => lcd"""
        .◢■■.
        ◢◤...
        █....
        █■■■◣
        █...█
        █...█
        ◥■■■◤
        """ * lcd_short,
    '7'  => lcd"""
        █████
        ....█
        ...◢◤
        ..◢◤.
        .◢◤..
        .█...
        .█...
        """ * lcd_short,
    '8'  => lcd"""
        ◢■■■◣
        █...█
        ◥◣.◢◤
        ◢■■■◣
        █...█
        █...█
        ◥■■■◤
        """ * lcd_short,
    '9'  => lcd"""
        ◢■■■◣
        █...█
        █...█
        ◥■■■█
        ....█
        ...◢◤
        .■■◤.
        """ * lcd_short,
    '!'  => lcd"""
        ..█..
        ..█..
        ..█..
        ..█..
        .....
        .....
        ..█..
        """ * lcd_short,
    '@'  => lcd"""
        ◢■■■◣
        █...█
        ....█
        ◢■◣.█
        █.█.█
        █.█.█
        ◥■■■◤
        """ * lcd_short,
    '#'  => lcd"""
        .█.█.
        .█.█.
        █████
        .█.█.
        █████
        .█.█.
        .█.█.
        """ * lcd_short,
    '$'  => lcd"""
        ..█..
        ◢■■■■
        █.█..
        ◥■■■◣
        ..█.█
        ■■■■◤
        ..█..
        """ * lcd_short,
    '%'  => lcd"""
        ██...
        ██..█
        ...◢◤
        ..◢◤.
        .◢◤..
        ■◤.██
        ...██
        """ * lcd_short,
    '^'  => lcd"""
        .◢■◣.
        ◢◤.◥◣
        █...█
        .....
        .....
        .....
        .....
        """ * lcd_short,
    '&'  => lcd"""
        ◢■■■◣
        █...█
        ◥◣.■◤
        .◥◣..
        █.█.█
        █.◥◣.
        ◥■.█.
        """ * lcd_short,
    '*'  => lcd"""
        .....
        .....
        ■◣.◢■
        .███.
        ■◤.◥■
        .....
        .....
        """ * lcd_short,
    '('  => lcd"""
        ..◢■.
        .◢◤..
        .█...
        .█...
        .█...
        .◥◣..
        ..◥■.
        """ * lcd_short,
    ')'  => lcd"""
        .■◣..
        ..◥◣.
        ...█.
        ...█.
        ...█.
        ..◢◤.
        .■◤..
        """ * lcd_short,
    '-'  => lcd"""
        .....
        .....
        .....
        █████
        .....
        .....
        .....
        """ * lcd_short,
    '='  => lcd"""
        .....
        .....
        █████
        .....
        █████
        .....
        .....
        """ * lcd_short,
    '_'  => lcd"""
        .....
        .....
        .....
        .....
        .....
        .....
        █████
        """ * lcd_short,
    '+'  => lcd"""
        .....
        ..█..
        ..█..
        █████
        ..█..
        ..█..
        .....
        """ * lcd_short,
    '{'  => lcd"""
        ..◢■.
        ..█..
        .◢■..
        .█...
        .◥■..
        ..█..
        ..◥■.
        """ * lcd_short,
    '}'  => lcd"""
        .■◣..
        ..█..
        ..■◣.
        ...█.
        ..■◤.
        ..█..
        .■◤..
        """ * lcd_short,
    '['  => lcd"""
        .███.
        .█...
        .█...
        .█...
        .█...
        .█...
        .███.
        """ * lcd_short,
    ']'  => lcd"""
        .███.
        ...█.
        ...█.
        ...█.
        ...█.
        ...█.
        .███.
        """ * lcd_short,
    '\\' => lcd"""
        .....
        ■◣...
        ◥■◣..
        .◥■◣.
        ..◥■◣
        ...◥■
        .....
        """ * lcd_short,
    '|'  => lcd"""
        ..█..
        ..█..
        ..█..
        ..█..
        ..█..
        ..█..
        ..█..
        """ * lcd_short,
    ':'  => lcd"""
        .....
        .██..
        .██..
        .....
        .██..
        .██..
        .....
        """ * lcd_short,
    ';'  => lcd"""
        .....
        .██..
        .██..
        .....
        .██..
        .██..
        ..█..
        .■◤..
        .....
        .....
        """,
    '/'  => lcd"""
        .....
        ...◢■
        ..◢■◤
        .◢■◤.
        ◢■◤..
        ■◤...
        .....
        """ * lcd_short,
    '"'  => lcd"""
        .█.█.
        .█.█.
        .█.█.
        .....
        .....
        .....
        .....
        """ * lcd_short,
    '\'' => lcd"""
        .██..
        ..█..
        .■◤..
        .....
        .....
        .....
        .....
        """ * lcd_short,
    '`'  => lcd"""
        █◣...
        ◥■◣..
        .◥█..
        .....
        .....
        .....
        .....
        """ * lcd_short,
    '~'  => lcd"""
        .....
        .....
        ◢■◣..
        █.█.█
        ..◥■◤
        .....
        .....
        """ * lcd_short,
    '≈'  => lcd"""
    .....
    ◢■◣..
    █.█.█
    ..◥■◤
    ◢■◣..
    █.█.█
    ..◥■◤
    """ * lcd_short,
    '.'  => lcd"""
        .....
        .....
        .....
        .....
        .....
        .....
        ..█..
        """ * lcd_short,
    ','  => lcd"""
        .....
        .....
        .....
        .....
        .....
        .██..
        .██..
        ..█..
        .■◤..
        .....
        """,
    '?'  => lcd"""
        ◢■■■◣
        █...█
        ....█
        ...◢◤
        ..█◤.
        .....
        ..█..
        """ * lcd_short,
    '<'  => lcd"""
        .....
        ..◢■.
        .◢■◤.
        ◢■◤..
        ◥■◣..
        .◥■◣.
        ..◥■.
        """ * lcd_short,
    '>'  => lcd"""
        .....
        .■◣..
        .◥■◣.
        ..◥■◣
        ..◢■◤
        .◢■◤.
        .■◤..
        """ * lcd_short,
    '÷'  => lcd"""
      .....
      ..█..
      .....
      █████
      .....
      ..█..
      .....
      """ * lcd_short,
    '√'  => lcd"""
    ..███
    ..█..
    ..█..
    ..█..
    ..█..
    █.█..
    ◥■◤..
    """ * lcd_short,
    '°'  => lcd"""
      ███..
      █.█..
      ███..
      .....
      .....
      .....
      .....
      """ * lcd_short,
    'α'  => lcd"""
      .....
      .....
      ◢■◣.█
      █.◥■◤
      █..█.
      █.◢■◣
      ◥■◤.█
      """ * lcd_short,
    'β'  => lcd"""
      .....
      .....
      ◢■■◣.
      █..█.
      █■■■◣
      █...█
      █■■■◤
      █....
      █....
      █....
      """,
    'ϵ'  => lcd"""
      .....
      .....
      ◢■■■.
      █....
      █■■..
      █....
      ◥■■■.
      """ * lcd_short,
    'μ'  => lcd"""
      .....
      .....
      █...█
      █...█
      █...█
      █.◢■█
      █■◤.█
      █....
      █....
      █....
      """,
    'σ'  => lcd"""
      .....
      .....
      ◢■■■■
      █..█.
      █..◥◣
      █...█
      ◥■■■◤
      """ * lcd_short,
    'ρ'  => lcd"""
      .....
      .....
      .◢■■◣
      ◢◤..█
      █...█
      █...█
      █■■■◤
      █....
      █....
      █....
      """,
    'θ'  => lcd"""
      .....
      ◢■■■◣
      █...█
      █████
      █...█
      █...█
      ◥■■■◤
      """ * lcd_short,
    'Ω'  => lcd"""
      .....
      .....
      ◢■■■◣
      █...█
      ◥◣.◢◤
      .█.█.
      ██.██
      """ * lcd_short,
    'Σ'  => lcd"""
      █████
      █....
      ◥■◣..
      ..█..
      ◢■◤..
      █....
      █████
      """ * lcd_short,
    'π'  => lcd"""
      .....
      .....
      █████
      .█.█.
      .█.█.
      .█.█.
      ■◤.■■
      """ * lcd_short,
    'ħ'  => lcd"""
      .█...
      ■█■■.
      .█...
      .█■■◣
      .█..█
      .█..█
      .█..█
      """ * lcd_short,
    '∞'  => lcd"""
    .....
    .....
    ◢█.██
    █.█.█
    ■■.■◤
    .....
    .....
    """ * lcd_short,
    'γ'  => lcd"""
      █...█
      ◥◣.◢◤
      .█.█.
      .◥█◤.
      ..█..
      ..██.
      ..██.
      """ * lcd_short,
    'δ'  => lcd"""
      .◢■■■
      .█...
      .◥◣..
      .◢■■◣
      .█..█
      .█..█
      .◥■■◤
      """ * lcd_short,
    'Ξ'  => lcd"""
      █████
      █...█
      .....
      .███.
      .....
      █...█
      █████
      """ * lcd_short,
    'Γ'  => lcd"""
      █████
      █...█
      █...█
      █....
      █....
      █....
      █....
      """ * lcd_short,
    'ϕ'  => lcd"""
      .....
      █.◢■◣
      █.█.█
      █.█.█
      ◥■■■◤
      ..█..
      ..█..
      """ * lcd_short,
    'ω'  => lcd"""
      .....
      .....
      ◢■.■◣
      █...█
      █.█.█
      █.█.█
      ◥■■■◤
      """ * lcd_short,
    'Π'  => lcd"""
      █████
      .█.█.
      .█.█.
      .█.█.
      .█.█.
      .█.█.
      .█.█.
      """ * lcd_short,
    'χ'  => lcd"""
      .....
      .....
      ■◣..■
      .█.■◤
      .■■■.
      ◢■.█.
      █..◥■
      """ * lcd_short,
    # U+0394; \\Delta tab-complete
    'Δ' => lcd"""
     .....
     .◢█◣.
     .█.█.
     ◢█.█◣
     █...█
     █...█
     █████
     """ * lcd_short,
    # U+2206; option-J on Mac
    '∆' => lcd"""
   .....
   .◢█◣.
   .█.█.
   ◢█.█◣
   █...█
   █...█
   █████
   """ * lcd_short,
    'κ' => lcd"""
     .....
     █◣..█
     .█.◢◤
     .█■◤.
     .█■◣.
     .█.◥◣
     █◤..█
     """ * lcd_short,
    '□' => lcd"""
   .....
   █████
   █...█
   █...█
   █...█
   █████
   .....
   """ * lcd_short,
    'ν' => lcd"""
     .....
     .....
     █...█
     █..◢◤
     █.◢◤.
     ◥█◤..
     .█...
     """ * lcd_short,
    'η' => lcd"""
     .....
     .....
     █.◢■◣
     █■◤.█
     █...█
     █...█
     █...█
     ....█
     ....█
     ....█
     """,
    '░' => lcd"""
   █.█.█
   .█.█.
   █.█.█
   .█.█.
   █.█.█
   .█.█.
   █.█.█
   .█.█.
   █.█.█
   .█.█.
   """,
    '█' => lcd_filled,
    'λ' => lcd"""
     ■■◣..
     ..█..
     ..█..
     ..█..
     .◢█◣.
     ◢◤.◥◣
     █...█
     """ * lcd_short,
    'τ' => lcd"""
     .....
     .....
     █████
     ..█..
     ..█..
     ..█..
     ..◥■■
     """ * lcd_short,
    'ψ' => lcd"""
     .....
     ..█..
     █.█.█
     █.█.█
     ◥■■■◤
     ..█..
     ..█..
     """ * lcd_short,
    'Ψ' => lcd"""
     █.█.█
     █.█.█
     █.█.█
     ◥■■■◤
     ..█..
     ..█..
     .███.
     """ * lcd_short,
    'Λ' => lcd"""
     ..█..
     .◢█◣.
     .█.█.
     .█.█.
     ◢◤.◥◣
     █...█
     ██.██
     """ * lcd_short,
    'Θ' => lcd"""
     ◢■■■◣
     █...█
     █...█
     █.█.█
     █...█
     █...█
     ◥■■■◤
     """ * lcd_short,
    'Φ' => lcd"""
     █████
     ..█..
     ◢■■■◣
     █.█.█
     ◥■■■◤
     ..█..
     █████
     """ * lcd_short,
    '†' => lcd"""
   .....
   ..█..
   .███.
   ..█..
   ..█..
   ..█..
   .....
   """ * lcd_short,
    '∠' => lcd"""
   .....
   .....
   ....█
   ..◢■◤
   .◢■◤.
   ◢■...
   █████
   """ * lcd_short,
    '⟂' => lcd"""
   .....
   .....
   ..█..
   ..█..
   ..█..
   ..█..
   █████
   """ * lcd_short,
    '≡' => lcd"""
   .....
   █████
   .....
   █████
   .....
   █████
   .....
   """ * lcd_short,
    '±' => lcd"""
     ..█..
     ..█..
     █████
     ..█..
     ..█..
     .....
     █████
     """ * lcd_short,
    '∓' => lcd"""
   █████
   .....
   ..█..
   ..█..
   █████
   ..█..
   ..█..
   """ * lcd_short,
    '∇' => lcd"""
   .....
   █████
   █...█
   █...█
   ◥◣.◢◤
   .█.█.
   .◥■◤.
   """ * lcd_short,
    '∂' => lcd"""
   ..■■◣
   ....█
   ....█
   ◢■■.█
   █...█
   █...█
   ◥■■■◤
   """ * lcd_short,
    '≠' => lcd"""
   ...◢█
   ..◢█.
   █████
   ..█..
   █████
   .█◤..
   █◤...
   """ * lcd_short,
    '𝚤' => lcd"""
 ..█..
 .....
 .██..
 ..█..
 ..█..
 ..█.█
 ..■■◤
 """ * lcd_short,
    ' ' => lcd_blank
)
