# Usage: julia format.jl <action>
using Pkg
Pkg.add(name="JuliaFormatter", version="1")
using JuliaFormatter
# Directories to format (recursive); paths relative to repo root
dirs = ["src", "test", "scripts"]
if ARGS[1] == "check" # check formatting and report results; don't change code
    notformatted = [!format(joinpath(@__DIR__, "..", d); overwrite=false) for d in dirs]
    for i in findall(notformatted)
        println("Directory $(dirs[i]) not formatted correctly.\n")
    end
    any(notformatted) && exit(1)
    println("Repo formatted correctly.")
    exit(0)
elseif ARGS[1] == "format" # format code
    for d in dirs
        println("Formatting $d...")
        format(joinpath(@__DIR__, "..", d); verbose=true, format_markdown=true)
    end
else
    println("Unrecognized argument")
    exit(1)
end
