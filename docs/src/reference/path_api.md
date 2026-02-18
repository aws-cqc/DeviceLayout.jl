# Path API Reference

## [Paths](@id api-paths)

```@docs
    Paths.Path
    Paths.α0
    Paths.α1
    Paths.direction
    Paths.pathlength
    Paths.p0
    Paths.p1
    Paths.style0
    Paths.style1
    Paths.discretestyle1
    Paths.contstyle1
    Paths.nextstyle
```

### [Path Manipulation](@id api-path-manipulation)

```@docs
    Paths.setp0!
    Paths.setα0!
    append!(::Path, ::Path)
    attach!(::Path{T}, ::DeviceLayout.GeometryReference{T}, ::DeviceLayout.Coordinate) where {T}
    bspline!
    corner!
    launch!
    meander!
    overlay!
    reconcile!
    Paths.round_trace_transitions!
    simplify
    simplify!
    straight!
    terminate!
    turn!
```

### [Path Intersection](@id api-path-intersection)

```@docs
    Intersect.IntersectStyle
    Intersect.AirBridge
    intersect!
```

### Path Nodes

```@docs
    Paths.Node
    Paths.previous
    Paths.next
    Paths.segment
    Paths.split(::Paths.Node, ::DeviceLayout.Coordinate)
    Paths.style
    Paths.setsegment!
    Paths.setstyle!
```

### [Path Segments](@id api-path-segments)

```@docs
    Paths.Segment
    Paths.Straight
    Paths.Turn
    Paths.Corner
    Paths.CompoundSegment
    Paths.BSpline
```

### [Path Styles](@id api-path-styles)

```@docs
    Paths.Style
    Paths.ContinuousStyle
    Paths.DiscreteStyle
    Paths.Trace
    Paths.CPW
    Paths.Taper
    Paths.Strands
    Paths.NoRender
    Paths.SimpleNoRender
    Paths.SimpleTrace
    Paths.GeneralTrace
    Paths.SimpleCPW
    Paths.GeneralCPW
    Paths.TaperTrace
    Paths.TaperCPW
    Paths.SimpleStrands
    Paths.GeneralStrands
    Paths.CompoundStyle
    Paths.DecoratedStyle
    Paths.PeriodicStyle
    Paths.pin
    Paths.translate
    Paths.undecorated
```

## [Routes](@id api-routes)

```@docs
    Paths.Route
```

### Route rules

```@docs
    Paths.RouteRule
    Paths.BSplineRouting
    Paths.StraightAnd90
    Paths.StraightAnd45
    Paths.CompoundRouteRule
    Paths.SingleChannelRouting
    Paths.RouteChannel
```

### Route drawing

```@docs
    Paths.Path(::Paths.Route, ::Paths.Style)
    Paths.route!
    Paths.reconcile!(::Paths.Path, ::Point, ::Any, ::Paths.RouteRule, ::Any, ::Any)
```

### Route inspection

```@docs
    Paths.p0(::Paths.Route)
    Paths.α0(::Paths.Route)
    Paths.p1(::Paths.Route)
    Paths.α1(::Paths.Route)
```
