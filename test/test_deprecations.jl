@testitem "Deprecations" setup = [CommonTestSetup, QuietGmshSetup] begin
    # Every deprecation is asserted here, so that the rest of the suite can stay quiet by
    # calling only current spellings. `@test_deprecated` covers `Base.depwarn` sites, which
    # fire under `--depwarn=yes` (as `Pkg.test` runs) and are silent otherwise; deprecations
    # with a new behavior to opt into warn at default visibility and are checked directly.
end
