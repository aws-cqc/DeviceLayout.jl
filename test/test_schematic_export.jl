@testitem "Schematic YAML export" setup = [CommonTestSetup] begin
    using .SchematicDrivenLayout
    using YAML
    import DeviceLayout: uparse

    # Load YAML scalars back into comparable Julia values. Unit-suffixed plain
    # scalars (the ParameterSet YAML dialect) parse as strings.
    uq(x::AbstractString) = uparse(x)
    uq(x) = x
    pt(v) = Point(uq(v[1]), uq(v[2]))
    byid(list, id) = only(filter(entry -> entry["id"] == id, list))
    edge_between(edges, a, b) = only(filter(e -> Set(e["nodes"]) == Set(Any[a, b]), edges))
    load_yml(dir, file) = YAML.load_file(joinpath(dir, file); dicttype=Dict{String, Any})

    @compdef struct ExportLeaf <: Component
        name = "leaf"
        w = 20μm
    end
    SchematicDrivenLayout.hooks(c::ExportLeaf) = (;
        east=HandedPointHook(Point(c.w / 2, zero(c.w)), 180°, true),
        west=PointHook(Point(-c.w / 2, zero(c.w)), 0°)
    )
    SchematicDrivenLayout._geometry!(cs::CoordinateSystem, c::ExportLeaf) =
        place!(cs, centered(Rectangle(c.w, c.w)), SemanticMeta(:metal))

    @compdef struct ExportMid <: CompositeComponent
        name = "mid"
        w = 20μm
    end
    SchematicDrivenLayout._build_subcomponents(c::ExportMid) =
        (; inner=ExportLeaf(name="inner", w=c.w))
    function SchematicDrivenLayout._graph!(
        g::SchematicGraph,
        ::ExportMid,
        subcomponents::NamedTuple
    )
        add_node!(g, subcomponents.inner)
        return g
    end
    SchematicDrivenLayout.map_hooks(::Type{ExportMid}) =
        Dict{Pair{Int, Symbol}, Symbol}((1 => :east) => :east, (1 => :west) => :west)

    @compdef struct ExportOuter <: CompositeComponent
        name = "outer"
        w = 20μm
    end
    SchematicDrivenLayout._build_subcomponents(c::ExportOuter) =
        (; mid=ExportMid(name="mid", w=c.w))
    function SchematicDrivenLayout._graph!(
        g::SchematicGraph,
        ::ExportOuter,
        subcomponents::NamedTuple
    )
        add_node!(g, subcomponents.mid)
        return g
    end
    SchematicDrivenLayout.map_hooks(::Type{ExportOuter}) =
        Dict{Pair{Int, Symbol}, Symbol}((1 => :east) => :east, (1 => :west) => :west)

    @testset "Full bundle" begin
        g = SchematicGraph("export_chip")
        left = add_node!(g, ExportLeaf(name="left"); role="anchor")
        outer = fuse!(g, left => :east, ExportOuter(name="outer") => :west)

        # Path node with a component attached partway along it, which stores a
        # generated additional hook on the path's vertex.
        pa = Path(nm)
        straight!(pa, 100μm, Paths.SimpleTrace(10μm))
        pan = add_node!(g, pa)
        fuse!(g, outer => :east, pan => :p0)
        attached = attach!(g, pan, ExportLeaf(name="attached") => :west, 50μm)

        # The same component instance in two nodes gets two distinct node IDs.
        shared_comp = ExportLeaf(name="shared", w=30μm)
        shared1 = fuse!(g, pan => :p1, shared_comp => :west)
        shared2 = fuse!(g, shared1 => :east, shared_comp => :west)

        # Fusing at a bare Hook records it as an additional hook on the node.
        extra_hook = PointHook(Point(0μm, 10μm), -90°)
        extra = fuse!(g, left => extra_hook, ExportLeaf(name="extra") => :west)

        # An edge that plan ignores but the topology still records.
        fuse!(g, extra => :east, shared2 => :east; PLAN_SKIPS_EDGE => true)

        rnode = route!(
            g,
            Paths.BSplineRouting(),
            left => :west,
            shared2 => :east,
            Paths.CPW(10μm, 6μm),
            GDSMeta();
            waypoints=[Point(-50μm, 50μm)]
        )

        sch = plan(g; log_dir=nothing)
        dir = joinpath(tdir, "export_bundle")
        @test save_schematic(dir, sch) == dir
        @test isfile(joinpath(dir, "topology.yml"))
        @test isfile(joinpath(dir, "parameters.yml"))
        @test isfile(joinpath(dir, "floorplan.yml"))

        @testset "topology.yml" begin
            topo = load_yml(dir, "topology.yml")
            @test topo["schema_version"] == "1"
            @test topo["name"] == "export_chip"
            @test topo["parameters"] == "parameters.yml"
            @test topo["floorplan"] == "floorplan.yml"

            ids = [n["id"] for n in topo["nodes"]]
            @test ids == [n.id for n in nodes(g)]
            @test allunique(ids)
            @test shared1.id != shared2.id

            left_entry = byid(topo["nodes"], left.id)
            @test left_entry["component"]["type"] == "ExportLeaf"
            @test left_entry["component"]["module"] isa String
            @test !isempty(left_entry["component"]["module"])
            @test left_entry["component"]["name"] == "left"
            @test left_entry["component"]["params"] == "components.$(left.id)"
            @test left_entry["properties"] == Dict{String, Any}("role" => "anchor")
            # The bare-Hook fuse! hook, exported with resolved geometry.
            add_hooks = left_entry["additional_hooks"]
            @test length(add_hooks) == 1
            hook_entry = only(values(add_hooks))
            @test hook_entry["kind"] == "PointHook"
            @test pt(hook_entry["point"]) ≈ extra_hook.p
            @test uq(hook_entry["direction"]) ≈ -90°

            # attach! records a handed hook on the path node.
            pan_entry = byid(topo["nodes"], pan.id)
            @test pan_entry["component"]["type"] == "Path"
            @test pan_entry["component"]["module"] == "DeviceLayout.Paths"
            pan_hook = only(values(pan_entry["additional_hooks"]))
            @test pan_hook["kind"] == "HandedPointHook"
            @test pan_hook["handedness"] in ("right", "left")
            @test pt(pan_hook["point"]) ≈ Point(50μm, 0μm)

            # Composite subgraphs recurse, with parameter addresses nesting
            # below the parent node's namespace.
            outer_entry = byid(topo["nodes"], outer.id)
            @test outer_entry["component"]["type"] == "ExportOuter"
            mid_entry = only(outer_entry["subgraph"]["nodes"])
            @test mid_entry["id"] == "mid"
            @test mid_entry["component"]["params"] == "components.$(outer.id).mid"
            @test isempty(outer_entry["subgraph"]["edges"])
            inner_entry = only(mid_entry["subgraph"]["nodes"])
            @test inner_entry["id"] == "inner"
            @test inner_entry["component"]["type"] == "ExportLeaf"
            @test inner_entry["component"]["params"] == "components.$(outer.id).mid.inner"
            @test !haskey(inner_entry, "subgraph")

            edges = topo["edges"]
            fused = edge_between(edges, left.id, outer.id)
            @test fused["nodes"] == Any[left.id, outer.id]
            @test fused["hooks"] == Any["east", "west"]
            skipped = edge_between(edges, extra.id, shared2.id)
            @test skipped["properties"]["plan_skips_edge"] == true
            # Route endpoints are ordinary edges using the route's hook names.
            route_p0 = edge_between(edges, left.id, rnode.id)
            @test route_p0["hooks"][findfirst(==(rnode.id), route_p0["nodes"])] == "p0"
            route_p1 = edge_between(edges, shared2.id, rnode.id)
            @test route_p1["hooks"][findfirst(==(rnode.id), route_p1["nodes"])] == "p1"
        end

        @testset "parameters.yml" begin
            ps = ParameterSet(joinpath(dir, "parameters.yml"))
            @test resolve(ps, "components.$(left.id).w") == 20μm
            @test resolve(ps, "components.$(outer.id).mid.inner.w") == 20μm
            # Both nodes sharing one component instance have their own entry.
            @test resolve(ps, "components.$(shared1.id).w") == 30μm
            @test resolve(ps, "components.$(shared2.id).w") == 30μm

            topo = load_yml(dir, "topology.yml")
            @test resolve(ps, "bundle.design_id") == "export_chip"
            @test resolve(ps, "bundle.source_fingerprint") ==
                  topo["bundle"]["source_fingerprint"]
        end

        @testset "floorplan.yml" begin
            fp = load_yml(dir, "floorplan.yml")
            @test fp["schema_version"] == "1"
            @test fp["topology"] == "topology.yml"
            @test fp["name"] == "export_chip"
            @test fp["coordinate_type"] == "nm"

            entry = byid(fp["nodes"], shared1.id)
            trans_entry = entry["transformation"]
            @test pt(trans_entry["origin"]) ≈ origin(sch, shared1)
            @test uq(trans_entry["rotation"]) ≈ 0°
            @test trans_entry["xrefl"] == false
            @test trans_entry["mag"] == 1
            live_hooks = hooks(sch, shared1)
            @test pt(entry["hooks"]["east"]["point"]) ≈ live_hooks.east.p
            @test uq(entry["hooks"]["east"]["direction"]) ≈ in_direction(live_hooks.east)
            @test entry["hooks"]["east"]["kind"] == "HandedPointHook"
            rect = bounds(sch, shared1)
            @test pt(entry["bounds"]["ll"]) ≈ rect.ll
            @test pt(entry["bounds"]["ur"]) ≈ rect.ur

            # The identity-placed root node still gets an explicit zero origin.
            root_entry = byid(fp["nodes"], left.id)
            @test pt(root_entry["transformation"]["origin"]) ≈ Point(0nm, 0nm)

            # Resolved route geometry matches the planned route.
            rentry = byid(fp["routes"], rnode.id)
            r = component(rnode).r
            @test pt(rentry["p0"]) ≈ r.p0
            @test pt(rentry["p1"]) ≈ r.p1
            @test uq(rentry["α0"]) ≈ r.α0
            @test uq(rentry["α1"]) ≈ r.α1
            @test rentry["rule_type"] == "BSplineRouting"
            @test length(rentry["waypoints"]) == 1
            @test pt(only(rentry["waypoints"])) ≈ only(r.waypoints)
            @test !haskey(rentry, "waydirs")

            # Composite-internal nodes are addressed by node-ID path.
            nested = fp["nested_nodes"]
            @test Set(Tuple(e["path"]) for e in nested) ==
                  Set([(outer.id, "mid"), (outer.id, "mid", "inner")])
            inner_fp = only(filter(e -> length(e["path"]) == 3, nested))
            outer_idx = findfirst(==(outer), nodes(g))
            inner_path = SchematicDrivenLayout.getpath(g, outer_idx, 1, 1)
            @test pt(inner_fp["transformation"]["origin"]) ≈ origin(sch, inner_path...)
            trans = transformation(sch, (outer_idx, 1, 1))
            live_inner_east = trans(hooks(component(last(inner_path))).east)
            @test pt(inner_fp["hooks"]["east"]["point"]) ≈ live_inner_east.p
            @test uq(inner_fp["hooks"]["east"]["direction"]) ≈ in_direction(live_inner_east)
            inner_rect = bounds(sch, inner_path...)
            @test pt(inner_fp["bounds"]["ll"]) ≈ inner_rect.ll
            @test pt(inner_fp["bounds"]["ur"]) ≈ inner_rect.ur
        end

        @testset "Bundle identity" begin
            topo = load_yml(dir, "topology.yml")
            fp = load_yml(dir, "floorplan.yml")
            params = load_yml(dir, "parameters.yml")
            for data in (topo, fp, params)
                @test data["bundle"]["design_id"] == "export_chip"
                @test data["bundle"]["generator"] ==
                      "DeviceLayout v$(pkgversion(DeviceLayout))"
                @test startswith(data["bundle"]["source_fingerprint"], "sha256:")
                @test data["bundle"]["source_fingerprint"] ==
                      topo["bundle"]["source_fingerprint"]
                @test !isempty(data["bundle"]["generated_at"])
            end
        end

        @testset "Fingerprint determinism" begin
            # Identical graph state fingerprints identically across exports,
            # even though timestamps differ.
            dir_a = save_schematic(joinpath(tdir, "export_bundle_a"), g)
            dir_b = save_schematic(joinpath(tdir, "export_bundle_b"), g)
            topo_a = load_yml(dir_a, "topology.yml")
            topo_b = load_yml(dir_b, "topology.yml")
            @test topo_a["bundle"]["source_fingerprint"] ==
                  topo_b["bundle"]["source_fingerprint"]
        end
    end

    @testset "Stable identities after node removal" begin
        g = SchematicGraph("removal")
        a = add_node!(g, ExportLeaf(name="a"))
        b = fuse!(g, a => :east, ExportLeaf(name="b") => :west)
        c = fuse!(g, b => :east, ExportLeaf(name="c") => :west)
        rem_node!(g, b)
        dir = save_schematic(joinpath(tdir, "removal_bundle"), g)
        topo = load_yml(dir, "topology.yml")
        # Node IDs, not integer indices, identify nodes, so the export matches
        # the live graph even after rem_node!'s swap-with-last reindexing.
        @test [n["id"] for n in topo["nodes"]] == [n.id for n in nodes(g)]
        @test Set(n["id"] for n in topo["nodes"]) == Set([a.id, c.id])
        @test isempty(topo["edges"])
    end

    @testset "Graph-only export for a plan-failing graph" begin
        g = SchematicGraph("failing")
        n1 = add_node!(g, ExportLeaf(name="a"))
        fuse!(g, n1 => :bogus, ExportLeaf(name="b") => :west)
        @test_throws Exception plan(g; log_dir=nothing)
        dir = save_schematic(joinpath(tdir, "failing_bundle"), g)
        @test isfile(joinpath(dir, "topology.yml"))
        @test isfile(joinpath(dir, "parameters.yml"))
        @test !isfile(joinpath(dir, "floorplan.yml"))
        topo = load_yml(dir, "topology.yml")
        @test !haskey(topo, "floorplan")
        @test topo["parameters"] == "parameters.yml"
    end
end
