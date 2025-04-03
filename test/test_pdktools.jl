@testset "PDK Tools" begin
    SchematicDrivenLayout.generate_pdk("MyPDK"; dir=tdir, user="testuser")
    pdkpath = joinpath(tdir, "MyPDK")
    using Pkg
    Pkg.develop(path=pdkpath)
    using MyPDK
    SchematicDrivenLayout.generate_component_package("MyComponents", MyPDK)
    comppkg = joinpath(pdkpath, "components", "MyComponents")
    SchematicDrivenLayout.generate_component_definition(
        "MyComposite",
        MyPDK,
        joinpath(comppkg, "src", "MyComposites.jl");
        composite=true
    )
    @test isfile(joinpath(comppkg, "src", "MyComposites.jl"))
    @test isfile(joinpath(comppkg, "test", "runtests.jl"))
    Pkg.develop(path=comppkg)
    Pkg.rm("MyComponents")
    Pkg.rm("MyPDK")
end
