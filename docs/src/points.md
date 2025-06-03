```@meta
DocTestSetup = quote
    using Unitful, DeviceLayout
    using Unitful: °
end
```

# Points

Points live in a Cartesian coordinate system with `Real` or `Unitful.Length` coordinates:

```jldoctest
julia> Point(1, 1)
2-element Point{Int64} with indices SOneTo(2):
 1
 1

julia> Point(1.0, 1.0)
2-element Point{Float64} with indices SOneTo(2):
 1.0
 1.0

julia> Point(1.0u"μm", 1.0u"μm")
2-element Point{Quantity{Float64, 𝐋, Unitful.FreeUnits{(μm,), 𝐋, nothing}}} with indices SOneTo(2):
 1.0 μm
 1.0 μm
```

If a point has `Real` coordinates, the absence of a unit is interpreted to mean
`μm` whenever the geometry is saved to a GDS format, but until then it is just
considered to be a pure number. Therefore you cannot mix and match `Real` and
`Length` coordinates:

```jldoctest
julia> Point(1.0u"μm", 1.0)
ERROR: Cannot use `Point` with this combination of types.
```

You can add Points together or scale them:

```jldoctest
julia> 3 * Point(1, 1) + Point(1, 2)
2-element Point{Int64} with indices SOneTo(2):
 4
 5
```

You can also do affine transformations by composing any number of `Translation`
and `Rotation`s, which will return a callable object representing the
transformation. You can type the following Unicode symbols with `\degree` and
`\circ` tab-completions in the Julia REPL or in VS Code with the [Julia extension](https://www.julia-vscode.org/docs/stable/).

```jldoctest
julia> aff = Rotation(90°) ∘ Translation(Point(1, 2))
AffineMap([0.0 -1.0; 1.0 0.0], (-2.0,1.0))

julia> aff(Point(0, 0))
2-element Point{Float64} with indices SOneTo(2):
 -2.0
  1.0
```

## API

```@docs
    DeviceLayout.PointTypes
    DeviceLayout.Coordinate
    Points.Point
    Points.getx
    Points.gety
    Points.lowerleft(::AbstractArray{Point{T}}) where T
    Points.upperright(::AbstractArray{Point{T}}) where T
```

## Implementation details

Points are implemented using the abstract type `FieldVector`
from [StaticArrays.jl](https://github.com/JuliaArrays/StaticArrays.jl).
This permits a fast, efficient representation of
coordinates in the plane. Additionally, unlike `Tuple` objects, we can
add points together, simplifying many function definitions.
