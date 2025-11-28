
function fragmentless(cs, postrender_ops, zmap)
    sm = SolidModel("test"; overwrite=true)
    render!(sm, cs; zmap, postrender_ops)
    # SolidModels._synchronize!(sm)
    # SolidModels.gmsh.fltk.run()

    # Extract the surface loops, and the associated tags for each volume
    # TODO: Need correct treatment of when these are vectors, i.e. separate volumes
    # making up one group.
    ext1_tag = SolidModels.dimtags(sm["ext1", 3])[1][2]
    ext2_tag = SolidModels.dimtags(sm["ext2", 3])[1][2]
    ext3_tag = SolidModels.dimtags(sm["ext3", 3])[1][2]
    ext1_shell, ext1_shell_tags = SolidModels.gmsh.model.occ.get_surface_loops(ext1_tag)
    ext2_shell, ext2_shell_tags = SolidModels.gmsh.model.occ.get_surface_loops(ext2_tag)
    ext3_shell, ext3_shell_tags = SolidModels.gmsh.model.occ.get_surface_loops(ext3_tag)

    # Loop tags give the coarse scale topology, i.e. which volumes are holes in
    # which. Now can cut the pattern from the chip surface for each.

    # In the shell loops remove the chip face tags
    chip_l1_tags = getindex.(SolidModels.dimtags(sm[:chip_l1, 2]), 2)
    chip_l2_tags = getindex.(SolidModels.dimtags(sm[:chip_l2, 2]), 2)
    filter!.(x -> x ∉ chip_l1_tags, ext1_shell_tags)
    filter!.(x -> x ∉ chip_l2_tags, ext2_shell_tags)
    filter!.(x -> x ∉ chip_l1_tags, ext3_shell_tags)
    filter!.(x -> x ∉ chip_l2_tags, ext3_shell_tags)

    # ext1_shell_tags
    # ext2_shell_tags
    # ext3_shell_tags

    # Add in the pattern and metal tags
    SolidModels._synchronize!(sm)
    SolidModels.gmsh.fltk.run()
    @show SolidModels.intersect_geom!(sm, :chip_l1, :pattern_l1, 2, 2)
    pattern_l1_bdr_dimtags = SolidModels.gmsh.model.get_boundary(
        SolidModels.dimtags(sm[:pattern_l1, 2]),
        false,
        false,
        true
    )
    SolidModels.gmsh.model.occ.embed
    sm["metal_l1"] =
        SolidModels.difference_geom!(sm, :chip_l1, :pattern_l1, 2, 2, remove_object=true)
    sm["metal_l2"] =
        SolidModels.difference_geom!(sm, :chip_l2, :pattern_l2, 2, 2, remove_object=true)

    SolidModels._synchronize!(sm)
    SolidModels.gmsh.fltk.run()
    # TODO: Fragment is still removing things, despite meshing at the end. Figure
    # out which entities are being hung on to.

    metal_l1_tags = getindex.(SolidModels.dimtags(sm[:metal_l1, 2]), 2)
    metal_l2_tags = getindex.(SolidModels.dimtags(sm[:metal_l2, 2]), 2)
    pattern_l1_tags = getindex.(SolidModels.dimtags(sm[:pattern_l1, 2]), 2)
    pattern_l2_tags = getindex.(SolidModels.dimtags(sm[:pattern_l2, 2]), 2)

    # Add the tag to outer shell first, as can use inner shell to identify set
    if length(intersect(ext1_shell_tags[1], ext3_shell_tags[2])) ==
       length(ext3_shell_tags[2])
        append!(ext3_shell_tags[2], vcat(metal_l1_tags, pattern_l1_tags))
    elseif length(intersect(ext1_shell_tags[1], ext3_shell_tags[3])) ==
           length(ext3_shell_tags[3])
        append!(ext3_shell_tags[3], vcat(metal_l1_tags, pattern_l1_tags))
    end
    if length(intersect(ext2_shell_tags[1], ext3_shell_tags[2])) ==
       length(ext3_shell_tags[2])
        append!(ext3_shell_tags[2], vcat(metal_l2_tags, pattern_l2_tags))
    elseif length(intersect(ext2_shell_tags[1], ext3_shell_tags[3])) ==
           length(ext3_shell_tags[3])
        append!(ext3_shell_tags[3], vcat(metal_l2_tags, pattern_l2_tags))
    end

    append!(ext1_shell_tags[1], vcat(metal_l1_tags, pattern_l1_tags))
    append!(ext2_shell_tags[1], vcat(metal_l2_tags, pattern_l2_tags))

    # Remove the volumes non recursively.
    SolidModels._synchronize!(sm)
    SolidModels.remove_group!(sm["ext1", 3], recursive=false, remove_entities=true)
    SolidModels.remove_group!(sm["ext2", 3], recursive=false, remove_entities=true)
    SolidModels.remove_group!(sm["ext3", 3], recursive=false, remove_entities=true)

    # Add new volumes back in based on the shell loops
    ext1_shell = SolidModels.gmsh.model.occ.add_surface_loop(ext1_shell_tags[1])
    ext2_shell = SolidModels.gmsh.model.occ.add_surface_loop(ext2_shell_tags[1])

    ext1_vtag = SolidModels.gmsh.model.occ.add_volume([ext1_shell])
    ext2_vtag = SolidModels.gmsh.model.occ.add_volume([ext2_shell])
    ext3_vtag =
        SolidModels.gmsh.model.occ.add_volume([ext3_shell[1], ext1_shell, ext2_shell])

    SolidModels._synchronize!(sm)
    return sm
end
