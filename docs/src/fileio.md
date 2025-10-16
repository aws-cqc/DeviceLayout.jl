```@meta
DocTestSetup = quote
    using Unitful, DeviceLayout, FileIO
    using Unitful: °
end
```

To save or load patterns in any format, make sure you are `using FileIO`.

## Saving patterns

This package can load/save patterns in the GDSII format for use with e-beam lithography
systems. In the future it may be useful to implement machine-specific pattern formats to
force fracturing or dosing in an explicit manner.

```@docs
    DeviceLayout.save
```

Using the [Cairo graphics library](https://cairographics.org), it is possible to save
cells into SVG, PDF, and EPS vector graphics formats, or into the PNG raster graphic
format. This enables patterns to be displayed in web browsers, publications, presentations,
and so on. You can save a cell to a graphics file by, e.g. `save("/path/to/file.svg", mycell)`.

Possible keyword arguments include:

  - `width`: Specifies the width parameter. A unitless number will give the width in pixels,
    72dpi. You can also give a length in any unit using a `Unitful.Quantity`, e.g. `u"4inch"` if
    you had previously done `using Unitful`.
  - `height`: Specifies the height parameter. A unitless number will give the width in pixels,
    72dpi. You can also give a length in any unit using a `Unitful.Quantity`. The aspect ratio
    of the output is always preserved so specify either `width` or `height`.
  - `layercolors`: Should be a dictionary with `Int` keys for layers and RGBA tuples as values.
    For example, (1.0, 0.0, 0.0, 0.5) is red with 50% opacity.
  - `bboxes`: Specifies whether to draw bounding boxes around the bounds of cell arrays or
    cell references (true/false).

## Loading patterns

```@docs
    DeviceLayout.load
```
