#!/usr/bin/env julia

using Pkg

if ARGS == ["--help"]
    println("Usage: julia --project=. scripts/test.jl [--full | name-pattern ...]")
    println("With no arguments, run the full suite; otherwise filter test-item names.")
elseif isempty(ARGS) || ARGS == ["--full"]
    # Pkg.test() supplies the CI-like temporary test environment for the full suite.
    Pkg.test()
elseif any(startswith(arg, "--") for arg in ARGS)
    error("Usage: julia --project=. scripts/test.jl [--full | name-pattern ...]")
else
    # TestEnv keeps targeted tests from modifying the checkout's project files.
    using TestEnv
    TestEnv.activate()

    using TestItemRunner
    import DeviceLayout

    patterns = ARGS
    TestItemRunner.run_tests(
        pkgdir(DeviceLayout);
        filter=ti -> any(pattern -> occursin(pattern, ti.name), patterns)
    )
end
