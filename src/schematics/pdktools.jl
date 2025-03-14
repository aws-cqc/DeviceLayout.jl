using Pkg, UUIDs
using LocalRegistry, PkgTemplates

"""
    generate_pdk(name="MyPDK"; dir=pwd())

Generates a PDK package named `name` in the parent directory `dir`.

The PDK package can be registered in your private registry `MyRegistry` as follows
using the `LocalRegistry` package. First, make sure you are on a branch of the
`MyRegistry` registry in `~/.julia/registries/MyRegistry`. Then add the `LocalRegistry`
package to your active environment and run:

```julia
using LocalRegistry
register(
    "MyPDK";
    registry="MyRegistry",
    push=false,
    repo="git@ssh.example.com:path/to/MyPDK.jl.git" # or however you usually get your repo
)
```

You will need to push the changes and make a pull request for your branch.

For more information about creating and using a local registry,
see [the LocalRegistry README](https://github.com/GunnarFarneback/LocalRegistry.jl?tab=readme-ov-file#localregistry).
"""
function generate_pdk(name="MyPDK"; dir=pwd(), template=get_template("PDK.jlt"), kwargs...)
    # Get UUID and major version for DeviceLayout
    projtoml = Pkg.TOML.parsefile(joinpath(pkgdir(@__MODULE__), "Project.toml"))
    dl_uuid = projtoml["uuid"]
    dl_major = VersionNumber(projtoml["version"]).major

    # Create package template
    t = Template(;
        dir=dir,
        plugins=[
            !License,
            !CompatHelper,
            !TagBot,
            !GitHubActions,
            !Dependabot,
            SrcDir(; file=template)
        ],
        julia=VersionNumber(projtoml["compat"]["julia"]),
        kwargs...
    )

    # Generate package from template, but don't automatically precompile (no deps yet)
    pc = get(ENV, "JULIA_PKG_PRECOMPILE_AUTO", nothing) # original setting to restore later
    ENV["JULIA_PKG_PRECOMPILE_AUTO"] = 0
    t(name)
    if !isnothing(pc) # restore old setting if it was explicit
        ENV["JULIA_PKG_PRECOMPILE_AUTO"] = pc
    else # delete key so default is used again
        delete!(ENV, "JULIA_PKG_PRECOMPILE_AUTO")
    end

    # Upper-bound the PDK package by major version and add deps.
    pdkpath = joinpath(dir, name)
    pdktoml = Pkg.TOML.parsefile(joinpath(pdkpath, "Project.toml"))
    pdktoml["compat"]["DeviceLayout"] = "$(Int64(dl_major))"
    pdktoml["deps"] = Dict("DeviceLayout" => "$(dl_uuid)")
    if !haskey(pdktoml, "preferences")
        pdktoml["preferences"] = Dict{String, Any}()
    end
    pdktoml["preferences"]["DeviceLayout"] =
        Dict("units" => "$(DeviceLayout.unit_preference)")

    open(joinpath(pdkpath, "Project.toml"), "w") do io
        return Pkg.TOML.print(io, pdktoml)
    end

    # Create components directory
    mkdir(joinpath(pdkpath, "components"))

    return
end

"""
    get_template(template; pdk=nothing)

Get the full path to the most appropriate template with the filename `template`.

If `pdk` is not `nothing`, and the file named `template` exists in the `templates`
folder at the PDK package root, then that template will be used. Otherwise, the
built-in DeviceLayout.jl template will be used.
"""
function get_template(template; pdk=nothing)
    if !isnothing(pdk) # If the PDK has its own template, use that
        template_path = joinpath(pkgdir(pdk), "templates", template)
        isfile(template_path) && return template_path
    end # Otherwise, use the built-in template
    return joinpath(pkgdir(@__MODULE__), "templates", template)
end

"""
    generate_component_package(name::AbstractString, pdk::Module,
        compname="MyComp"; composite=false,
        template=get_template(composite ? "CompositeComponent.jlt" : "Component.jlt", pdk=pdk))

Generates a new component package named `name` in the components directory of `pdk`.

Adds `pdk` and `DeviceLayout` as dependencies and sets non-inclusive upper bounds of the
next major versions.
Creates a template for a `Component` type named `compname` in the main module file, using
a template for standard components or for composite components depending on the keyword
argument `composite`.

Uses a template at the file path `template` for standard components or for composite components
depending on the keyword argument `composite`. If the `template` keyword is not
explicitly used, then if the PDK defines a `Component.jlt` or `CompositeComponent.jlt`
template in a `templates` folder at the package root, that will be used; otherwise,
the built-in DeviceLayout templates are used.

The component package can be registered in your private registry `MyRegistry`
as follows using the `LocalRegistry` package. First,
make sure you are on a branch of the `MyRegistry` registry in
`~/.julia/registries/MyRegistry`. Then add the `LocalRegistry` package to your active
environment and run:

```julia
using LocalRegistry
register(
    name;
    registry="MyRegistry",
    push=false,
    repo="git@ssh.example.com:path/to/MyPDK.jl.git" # or however you usually get your repo
)
```

You will need to push the changes and make a pull request for your branch.

For more information about creating and using a local registry,
see [the LocalRegistry README](https://github.com/GunnarFarneback/LocalRegistry.jl?tab=readme-ov-file#localregistry).
"""
function generate_component_package(
    name::AbstractString,
    pdk::Module,
    compname="MyComp";
    composite=false,
    template=get_template(composite ? "CompositeComponent.jlt" : "Component.jlt", pdk=pdk),
    kwargs...
)
    # Get UUID and major version for DeviceLayout
    projtoml = Pkg.TOML.parsefile(joinpath(pkgdir(@__MODULE__), "Project.toml"))
    dl_uuid = projtoml["uuid"]
    dl_major = VersionNumber(projtoml["version"]).major

    # get UUID for PDK
    pdk_uuid = projtoml["deps"][string(pdk)]
    # is dev'd or not?
    pdk_pkginfo = Pkg.dependencies()[UUID(pdk_uuid)]
    pdk_pkginfo.is_tracking_path || error(
        "you must run `import Pkg; Pkg.dev(\"$pdk\")` before generating a component package."
    )
    # get major version of PDK
    pdk_major = pdk_pkginfo.version.major

    # Allow component template to use provided names
    user_view(::SrcDir, ::Template, ::AbstractString) =
        Dict{String, Any}("pdkname" => pdk, "compname" => compname)

    # Create package template
    t = Template(;
        dir=joinpath(pdk.COMPONENTS_DIR),
        plugins=[
            !Git,
            !License,
            !CompatHelper,
            !TagBot,
            !GitHubActions,
            !Dependabot,
            SrcDir(; file=template)
        ],
        julia=VersionNumber(projtoml["compat"]["julia"]),
        kwargs...
    )

    # Generate package from template, but don't automatically precompile (no deps yet)
    pc = get(ENV, "JULIA_PKG_PRECOMPILE_AUTO", nothing) # original setting to restore later
    ENV["JULIA_PKG_PRECOMPILE_AUTO"] = 0
    t(name)
    if !isnothing(pc) # restore old setting if it was explicit
        ENV["JULIA_PKG_PRECOMPILE_AUTO"] = pc
    else # delete key so default is used again
        delete!(ENV, "JULIA_PKG_PRECOMPILE_AUTO")
    end

    # upper-bound the PDK package by major version and add deps.
    componentpath = joinpath(pdk.COMPONENTS_DIR, name)
    pdktoml = Pkg.TOML.parsefile(joinpath(componentpath, "Project.toml"))
    pdktoml["compat"]["DeviceLayout"] = "$(Int64(dl_major))"
    pdktoml["compat"][string(pdk)] = "$(Int64(pdk_major))"
    pdktoml["deps"] = Dict("DeviceLayout" => "$(dl_uuid)", string(pdk) => "$(pdk_uuid)")
    if !haskey(pdktoml, "preferences")
        pdktoml["preferences"] = Dict{String, Any}()
    end
    pdktoml["preferences"]["DeviceLayout"] =
        Dict("units" => "$(DeviceLayout.unit_preference)")

    open(joinpath(componentpath, "Project.toml"), "w") do io
        return Pkg.TOML.print(io, pdktoml)
    end

    return nothing
end

"""
    generate_component_definition(compname, pdk::Module, filepath; composite=false,
        template=get_template(composite ? "CompositeComponent.jlt" : "Component.jlt", pdk=pdk))

Generates a file defining the component type `compname` at `filepath` based on `template`.

Uses a template at the file path `template` for standard components or for composite components
depending on the keyword argument `composite`. If the `template` keyword is not
explicitly used, then if the PDK defines a `Component.jlt` or `CompositeComponent.jlt`
template in a `templates` folder at the package root, that will be used; otherwise,
the built-in DeviceLayout templates are used.

For generating a new component package, see `generate_component_package`.
Closely related components that should always be versioned together can be defined in
the same package, in which case this method can be used to generate only the file defining
a component. The built-in template defines a module, but it is not necessary for
every component to be in its own module.
"""
function generate_component_definition(
    compname::AbstractString,
    pdk::Module,
    filepath;
    composite=false,
    template=get_template(composite ? "CompositeComponent.jlt" : "Component.jlt", pdk=pdk)
)
    open(template, "r") do io
        template = read(io, String)
        str = replace(
            template,
            "{{{compname}}}" => compname,
            "{{{pdkname}}}" => string(pdk),
            "{{{PKG}}}" => compname * "s"
        )
        open(filepath, "w") do io
            return write(io, str)
        end
    end
end
