
module DXF
# Experimental dxf export
# Presently commented out for a branch with no PyCall dependency
# To be rebuilt without PyCall

# Requires ezdxf in the Python environment PyCall uses
# You can install it in Julia's internal conda (at least on Windows) with:
#   ```
#   julia> using PyCall
#   julia> pyimport_conda("ezdxf", "ezdxf", "conda-forge")
#   ```

# ezdxf tutorials: https://ezdxf.readthedocs.io/en/stable/tutorials
# dxf internals: https://ezdxf.readthedocs.io/en/stable/dxfinternals
# dxf reference: http://help.autodesk.com/view/OARX/2018/ENU/?guid=GUID-235B22E0-A567-4CF6-92D3-38A2306D73F3

# Version 0: Get polygons in right format then just call out to ezdxf
# Two possible directions: use more of ezdxf, or just
# start implementing the important subset to remove dependency
# using PyCall
import DeviceLayout: save, flatten, points
import DeviceLayout.Cells: Cell
import Unitful: ustrip, μm
import FileIO: File, @format_str, filename

# const ezdxf = PyNULL()

# function __init__()
#     # Have to do this when module is loaded
#     copy!(ezdxf, pyimport_conda("ezdxf", "ezdxf", "conda-forge"))
# end

# export dxfsave

####### Example from ezdxf README
####### Only changes: Rewrite Python dictionaries in Julia syntax
####### Single quotes were also replaced with double quotes
####### That is, `{'color':2}` became `Dict("color" => 2)`, etc
# function ezdxf_example()

#     # Create a new DXF document.
#     doc = ezdxf.new(dxfversion="R2010")

#     # Create new table entries (layers, linetypes, text styles, ...).
#     doc.layers.new("TEXTLAYER", dxfattribs=Dict("color" => 2))

#     # DXF entities (LINE, TEXT, ...) reside in a layout (modelspace,
#     # paperspace layout or block definition).
#     msp = doc.modelspace()

#     # Add entities to a layout by factory methods: layout.add_...()
#     msp.add_line((0, 0), (10, 0), dxfattribs=Dict("color" => 7))
#     msp.add_text(
#         "Test",
#         dxfattribs=Dict(
#             "layer" => "TEXTLAYER"
#         )).set_pos((0, 0.2), align="CENTER")

#     # Save DXF document.
#     doc.saveas("test.dxf")
# end

# # Simple implementation: Flatten cell, then add every polygon in the appropriate layer
# # (Really, cell references should become block references,
# # there might be more DXF attributes in the metadata...)
# function save(file::File{format"DXF"}, c::Cell)
#     doc = ezdxf.new()
#     msp = doc.modelspace()
#     cflat = flatten(c)
#     layers = []
#     for el in cflat.elements
#         meta = el.meta
#         # just assume we have units for now...
#         points = [ustrip.(μm, (point.x, point.y)) for point in el.polygon.p]
#         polyline = msp.add_lwpolyline(points, dxfattribs=Dict("layer" => meta.layer))
#         polyline.closed = true
#     end

#     doc.saveas(filename(file))
# end
"""
    save(file::File{format"DXF"}, c::Cell, python::String)

Export a `Cell` to a DXF file. Uses the `ezdxf` program in Python, and requires
the python executable path that has that package installed
(could simply be `python`, or `/Users/user/.julia/conda/3/bin/python`).
Generates a Python script and runs it, to avoid PyCall dependency.
"""
function save(file::File{format"DXF"}, c::Cell, python::String)
    #TODO convert Cell to DXF BLOCK. Just flattens for now.
    cflat = flatten(c)
    mktemp() do path, f
        println(f, "import ezdxf")
        println(f, "doc = ezdxf.new()")
        println(f, "msp = doc.modelspace()")
        for (poly, meta) in zip(cflat.elements, cflat.element_metadata)
            pts = [ustrip.(μm, (point.x, point.y)) for point in points(poly)]
            #TODO work with units properly. Just strips µm right now.
            println(
                f,
                "polyline = msp.add_lwpolyline($(pts),
         dxfattribs={\"layer\": \"$(meta.layer)\"})"
            )
            println(f, "polyline.closed = True")
        end
        println(f, "doc.saveas(\"$(escape_string(filename(file)))\")")
        close(f)
        @show path
        @show f
        return run(`$python $path`)
    end
end

end
