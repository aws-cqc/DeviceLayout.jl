@testitem "Deprecations" setup = [CommonTestSetup, QuietGmshSetup] begin
    # Every deprecation is asserted here, so that the rest of the suite can stay quiet by
    # calling only current spellings. `@test_deprecated` covers `Base.depwarn` sites, which
    # fire under `--depwarn=yes` (as `Pkg.test` runs) and are silent otherwise; deprecations
    # with a new behavior to opt into warn at default visibility and are checked directly.

    @testset "Reference keyword synonyms" begin
        cs = CoordinateSystem("synonyms", nm)
        canonical = sref(cs; xrefl=true, mag=2.0, rot=90°)
        for (xk, mk, rk) in zip(
            (:xreflection, :refl, :reflect, :xreflect, :xmirror, :mirror),
            (:magnification, :magnify, :zoom, :scale, :mag, :mag),
            (:rotation, :rotate, :angle, :rot, :rot, :rot)
        )
            kw = NamedTuple{(xk, mk, rk)}((true, 2.0, 90°))
            @test transformation(@test_deprecated sref(cs; kw...)) ==
                  transformation(canonical)
        end
        canonical_arr = aref(cs; dc=Point(1μm, 0μm), dr=Point(0μm, 2μm), nc=3, nr=4)
        synonym_sets = (
            (:deltacol, :deltarow, :numcols, :numrows),
            (:dcol, :drow, :numcol, :numrow),
            (:vcol, :vrow, :ncols, :nrows),
            (:colv, :rv, :ncol, :nrow),
            (:colvec, :rowvec, :col, :row),
            (:colvector, :rowvector, :nc, :nr),
            (:columnv, :dr, :nc, :nr),
            (:columnvec, :dr, :nc, :nr),
            (:columnvector, :dr, :nc, :nr)
        )
        for keys in synonym_sets
            kw = NamedTuple{keys}((Point(1μm, 0μm), Point(0μm, 2μm), 3, 4))
            arr = @test_deprecated aref(cs; kw...)
            @test (arr.deltacol, arr.deltarow, arr.col, arr.row) == (
                canonical_arr.deltacol,
                canonical_arr.deltarow,
                canonical_arr.col,
                canonical_arr.row
            )
        end
        # The canonical spelling wins over a synonym, without warning
        @test (@test_nowarn sref(cs; rot=90°, angle=0°)).rot == 90°
    end
end
