using Pkg, UUIDs
using PkgTemplates

"""
    generate_pdk(name="MyPDK"; dir=pwd(), template=get_template("PDK.jlt"), kwargs...)

Generates a PDK package named `name` in the parent directory `dir` based on `template`.

Additional keyword arguments are forwarded to [`PkgTemplates.Template`](https://juliaci.github.io/PkgTemplates.jl/stable/user/#PkgTemplates.Template).

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
    # Create package template
    t = Template(;
        dir=dir,
        plugins=[
            !License,
            !CompatHelper,
            !TagBot,
            !GitHubActions,
            !Dependabot,
            SrcDir(; file=template),
            Documenter{NoDeploy}(),
            Git(
                ignore=[
                    "components/*/Manifest.toml",
                    "components/*/docs/Manifest.toml",
                    "components/*/docs/build/"
                ]
            )
        ],
        kwargs...
    )

    # Generate package from template, but don't automatically precompile (no deps yet)
    without_precompile() do
        return t(name)
    end

    # Upper-bound the PDK package by major version and add deps.
    update_package_toml!(joinpath(dir, name), ["DeviceLayout"])

    # Create components directory
    mkdir(joinpath(dir, name, "components"))

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

function without_precompile(f)
    pc = get(ENV, "JULIA_PKG_PRECOMPILE_AUTO", nothing) # Original setting
    ENV["JULIA_PKG_PRECOMPILE_AUTO"] = 0 # Zero => don't precompile, any other setting => do
    try
        f()
    finally
        if isnothing(pc)
            delete!(ENV, "JULIA_PKG_PRECOMPILE_AUTO") # Restore default behavior
        else
            ENV["JULIA_PKG_PRECOMPILE_AUTO"] = pc # Restore original setting
        end
    end
end

function update_package_toml!(path, add_pkgs, dev_paths=[]; set_unit_pref=true, compat=true)
    compat_dict = Dict{String, String}()
    PkgTemplates.with_project(path) do
        # Use Pkg to make sure manifest is immediately usable without needing resolve or dev
        without_precompile() do
            Pkg.add(add_pkgs)
            for path in dev_paths
                Pkg.develop(path=path)
            end
        end
        if compat # Add versions to dict, we'll write to TOML later ourselves
            for (name, uuid) in pairs(Pkg.project().dependencies)
                v = Pkg.dependencies()[uuid].version # Could be v"x.y.z-DEV" etc
                compat_dict[name] = join([v.major, v.minor, v.patch], ".") # Just "x.y.z"
            end
        end
    end
    !(set_unit_pref || compat) && return
    # Write remaining project info manually
    pkgtoml = Pkg.TOML.parsefile(joinpath(path, "Project.toml"))
    if set_unit_pref # Set unit preference to current environment's value
        # Edit the TOML directly, no need to precompile anything
        pkgtoml["preferences"] = merge(
            get(pkgtoml, "preferences", Dict()),
            Dict("DeviceLayout" => Dict("units" => DeviceLayout.unit_preference))
        )
    end
    if compat
        # Usually `add` automatically adds compat if active env is a package
        # But we have to do it manually for some reason
        # We'll write it to Project.toml directly rather than use Pkg.compat
        # Because we know currently used versions are valid and can avoid slow checks
        pkgtoml["compat"] = merge(get(pkgtoml, "compat", Dict()), compat_dict)
    end
    open(joinpath(path, "Project.toml"), "w") do io # Write back to file
        return Pkg.TOML.print(io, pkgtoml)
    end
end

"""
    generate_component_package(name::AbstractString, pdk::Module, compname="MyComp";
        composite=false,
        template=get_template(composite ? "CompositeComponent.jlt" : "Component.jlt", pdk=pdk)
        docs_template=get_template("Component.mdt", pdk=pdk),
        kwargs...
    )

Generates a new component package named `name` in the components directory of `pdk`.

Adds `pdk` and `DeviceLayout` as dependencies and sets non-inclusive upper bounds of the
next major versions.
Creates a definition for a `Component` type named `compname` in the main module file, using
a template for standard components or for composite components depending on the keyword
argument `composite`.
If the `template` keyword is not
explicitly used, then if the PDK defines a `Component.jlt` or `CompositeComponent.jlt`
template in a `templates` folder at the package root, that will be used; otherwise,
the built-in DeviceLayout templates are used.
The source file generated in this way should not be `include`d from the PDK source files,
since it is an independent package even if it is tracked in the same Git repository.

Also generates documentation based on `docs_template`.

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
    docs_template=get_template("Component.mdt", pdk=pdk),
    kwargs...
)
    # Is PDK dev'd or not?
    if !(Pkg.project().name == string(pdk)) # (or the active project, that works too)
        pdk_pkginfo = Pkg.dependencies()[Pkg.project().dependencies[string(pdk)]]
        pdk_pkginfo.is_tracking_path || error(
            "$pdk must be the active project or you must run `using Pkg; Pkg.develop(\"$pdk\")` before generating a component package."
        )
    end

    # Create package template
    t = Template(;
        dir=pdk.COMPONENTS_DIR,
        plugins=[
            !Git,
            !License,
            !CompatHelper,
            !TagBot,
            !GitHubActions,
            !Dependabot,
            SrcDir(; file=template),
            Documenter{NoDeploy}(index_md=docs_template, devbranch="broken") # https://github.com/JuliaCI/PkgTemplates.jl/issues/463
        ],
        kwargs...
    )

    # Generate package from template, but don't automatically precompile (no deps yet)
    without_precompile() do
        return t(name)
    end

    # Make src/docs template replacements manually
    # (because we can't dynamically redefine PkgTemplates.user_view methods)
    # (well, we could, but this way avoids both eval tricks and piracy)
    write_from_template(
        joinpath(pdk.COMPONENTS_DIR, name, "src", name * ".jl"),
        template,
        string(pdk),
        name,
        compname
    )
    write_from_template(
        joinpath(pdk.COMPONENTS_DIR, name, "docs", "src", "index.md"),
        docs_template,
        string(pdk),
        name,
        compname
    )

    # upper-bound the PDK package by major version and add deps.
    update_package_toml!(
        joinpath(pdk.COMPONENTS_DIR, name),
        ["DeviceLayout"],
        [pkgdir(pdk)] # dev pdk
    )
    # Same thing for docs
    update_package_toml!(
        joinpath(pdk.COMPONENTS_DIR, name, "docs"),
        ["DeviceLayout", "FileIO"], # add FileIO for convenience
        [pkgdir(pdk)], # dev pdk (component package is already dev'd)
        compat=false
    )

    return nothing
end

function write_from_template(filepath, template, pdkname, pkgname, compname)
    open(template, "r") do io
        template = read(io, String)
        str = replace(
            template,
            "{{{pdkname}}}" => pdkname,
            "{{{PKG}}}" => pkgname,
            "{{{compname}}}" => compname
        )
        open(filepath, "w") do io
            return write(io, str)
        end
    end
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
a component. That file can then be `include`d from the file defining the root package module.

The built-in template defines a module because it's also used for package generation,
but it is not necessary for every component in a package to be in its own module.
"""
function generate_component_definition(
    compname::AbstractString,
    pdk::Module,
    filepath;
    composite=false,
    template=get_template(composite ? "CompositeComponent.jlt" : "Component.jlt", pdk=pdk)
)
    return write_from_template(filepath, template, string(pdk), compname * "s", compname)
end
