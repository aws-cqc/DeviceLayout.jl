@testitem "PDK Tools" setup = [CommonTestSetup] begin
    # PDK
    SchematicDrivenLayout.generate_pdk("MyPDK"; dir=tdir, user="testuser")
    pdkpath = joinpath(tdir, "MyPDK")
    using Pkg
    Pkg.develop(path=pdkpath)
    using MyPDK
    pdktoml = Pkg.TOML.parsefile(joinpath(pkgdir(MyPDK), "Project.toml"))
    @test VersionNumber(pdktoml["compat"]["DeviceLayout"]).major == 1
    @test pdktoml["preferences"]["DeviceLayout"]["units"] == DeviceLayout.unit_preference

    # Component package
    SchematicDrivenLayout.without_precompile() do
        SchematicDrivenLayout.generate_component_package("MyComps", MyPDK, user="testuser")
        @test ENV["JULIA_PKG_PRECOMPILE_AUTO"] == "0" # Environment variable is not changed
    end
    @test !haskey(ENV, "JULIA_PKG_PRECOMPILE_AUTO") # Temporary env var was removed
    comppkg = joinpath(pdkpath, "components", "MyComps")
    @test isfile(joinpath(comppkg, "test", "runtests.jl")) # Package template includes tests
    Pkg.develop(path=comppkg)

    # Component file
    SchematicDrivenLayout.generate_component_definition(
        "MyComposite",
        MyPDK,
        joinpath(comppkg, "src", "MyComposites.jl");
        composite=true
    )
    @test isfile(joinpath(comppkg, "src", "MyComposites.jl")) # File was generated
    Pkg.rm("MyComps")
    Pkg.rm("MyPDK")
end
