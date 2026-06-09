"""
    adapted_grid(f, anchors;
        max_recursions::Real = 7, max_change = 5°, rand_factor::Real = 0.05,
        grid_step = 1.0μm)

Computes a resampled `grid` given anchor points so that `f.(grid)` is sufficiently
smooth. The method used is to create an initial grid around the anchor points and refine
intervals. When an interval becomes "straight enough" it is no longer divided.
Adapted from a contribution to PlotUtils.jl from Kristoffer Carlsson.

  - `max_recursions`: how many times each interval is allowed to be refined.
  - `max_change`: specifies acceptable change between evaluations of `f` on subsequent grid
    points, as estimated by the derivative times the distance between grid points.
    Typically, `f` is the angle of a path in the plane, so this is often an angle threshold.
    This condition is approximately valid in the end result, but may be weakly violated.
    This condition may be grossly violated if `max_recursions` is too low.
  - `rand_factor`: between anchor points, `adapted_grid` will wiggle initial grid points
    a bit to prevent aliasing. The wiggling is sampled uniformly from the interval:
    `[-rand_factor, rand_factor]`, times the distance between three grid points
    (e.g. `i+1` and `i-1`). A random number generator is given a fixed seed every time
    `adapted_grid` is called, so the rendered results are deterministic.
  - `grid_step`: Step size for initial grid points. If you set this to be larger than
    the maximum anchor point, then the lowest resolution consistent with `max_change` is used
    (unless `f` has some fast variations that the algorithm might miss).
"""
function adapted_grid end

adapted_grid(f, anchors::Tuple{S, T}; kwargs...) where {S <: Coordinate, T <: Coordinate} =
    adapted_grid(f, StaticArrays.SVector(anchors); kwargs...)

adapted_grid(
    f,
    anchors::AbstractVector{T};
    max_recursions::Real=7,
    max_change=5°,
    rand_factor::Real=0.05,
    grid_step::Coordinate=1.0 * Unitful.ContextUnits(
        ifelse(T <: Length, Unitful.μm, Unitful.NoUnits),
        Unitful.unit(Unitful.upreferred(zero(T)))
    ),
    kwargs...
) where {T <: Coordinate} =
    assemble_grids(f, anchors, max_recursions, max_change, rand_factor, grid_step)

function assemble_grids(
    f,
    anchors::AbstractVector,
    max_recursions,
    max_change,
    rand_factor,
    grid_step
)
    dimension(eltype(f(anchors[1]))) != dimension(max_change) &&
        throw(ArgumentError("max_change must have dimensions of f($(anchors[1]))"))
    g =
        i -> begin
            # Want a range that specially excludes the last point; use linspace with npts.
            @inbounds npts =
                Int(ceil(NoUnits((anchors[i + 1] - anchors[i]) / grid_step))) - 1
            npts = ifelse(npts < 5, 5, ifelse(iseven(npts), npts + 1, npts))
            @inbounds grid = make_grid(
                f,
                range(anchors[i], stop=anchors[i + 1], length=npts),
                max_recursions,
                max_change,
                rand_factor
            )
            grid[1:(end - 1)]
        end
    grid = vcat(g.(1:(length(anchors) - 1))...)
    return push!(grid, anchors[end])
end

function make_grid(f, initial_grid, max_recursions, max_change, rand_factor)
    # Initial argument checks
    max_recursions >= 0 || throw(ArgumentError("max_recursions must be >= 0"))
    rand_factor >= 0 || throw(ArgumentError("rand_factor must be >= 0"))
    n_points = length(initial_grid)
    if !(isodd(n_points) && n_points >= 3)
        throw(ArgumentError("n_points be an odd number >= 3"))
    end
    !issorted(initial_grid) && throw(ArgumentError("initial grid must be sorted."))

    # Initial number of points
    n_intervals = div(n_points, 2)
    xs = collect(initial_grid)

    if !iszero(rand_factor)
        rng = MersenneTwister(1337)
        for i = 2:(length(xs) - 1)
            xs[i] += rand_factor * 2 * (rand(rng) - 0.5) * (xs[i + 1] - xs[i - 1])
        end
    end

    n_tot_refinements = zeros(Int, n_intervals)
    while true
        results = zeros(typeof(f(initial_grid[1])), n_intervals)
        active = Vector{Bool}(undef, n_intervals)
        # derivs = [ForwardDiff.derivative(f, xs[i]) for i in 1:(2*n_intervals + 1)]

        for interval = 1:n_intervals
            p = 2 * interval
            tot_w = 0.0

            # Do a small convolution
            for (q, w) in ((-1, 0.25), (0, 0.5), (1, 0.25))
                interval == 1 && q == -1 && continue
                interval == n_intervals && q == 1 && continue
                tot_w += w
                i = p + q

                results[interval] +=
                    abs(ForwardDiff.derivative(f, xs[i]) * (xs[i + 1] - xs[i - 1]) / 2) * w
            end
            results[interval] /= tot_w

            # Only consider intervals that have not been refined too much and have a high enough curvature
            active[interval] =
                n_tot_refinements[interval] < max_recursions &&
                results[interval] > max_change
        end

        if all(x -> x >= max_recursions, n_tot_refinements[active])
            break
        end

        n_target_refinements = div(n_intervals, 2)
        interval_candidates = collect(1:n_intervals)[active]
        n_refinements = min(n_target_refinements, length(interval_candidates))
        perm = sortperm(results[active])
        intervals_to_refine =
            sort(interval_candidates[perm[(length(perm) - n_refinements + 1):end]])
        n_intervals_to_refine = length(intervals_to_refine)
        n_new_points = 2 * length(intervals_to_refine)

        # Do division of the intervals
        new_xs = similar(xs, n_points + n_new_points)
        new_tot_refinements =
            similar(n_tot_refinements, n_intervals + n_intervals_to_refine)
        k = 0
        kk = 0
        for i = 1:n_points
            if iseven(i) # This is a point in an interval
                interval = div(i, 2)
                if interval in intervals_to_refine
                    # The refined interval will become two intervals in the next round.
                    # Both new intervals take on the old intervals refinement number + 1.
                    kk += 1
                    new_tot_refinements[interval - 1 + kk] = n_tot_refinements[interval] + 1
                    new_tot_refinements[interval + kk] = n_tot_refinements[interval] + 1

                    # Insert new x taken between i and i-1 of interval.
                    k += 1
                    new_xs[i - 1 + k] = (xs[i] + xs[i - 1]) / 2

                    # Insert old x
                    new_xs[i + k] = xs[i]

                    # Insert new x taken between i and i+1 of interval.
                    new_xs[i + 1 + k] = (xs[i + 1] + xs[i]) / 2

                    # Increment k again since we added two new points
                    k += 1
                else
                    # Just keep the old x and refinement count to maintain the interval
                    new_tot_refinements[interval + kk] = n_tot_refinements[interval]
                    new_xs[i + k] = xs[i]
                end
            else
                new_xs[i + k] = xs[i]
            end
        end

        xs = new_xs
        n_tot_refinements = new_tot_refinements
        n_points = n_points + n_new_points
        n_intervals = div(n_points, 2)
    end

    return xs
end

"""
    discretize_curve(f, ddf, tolerance; rtol=nothing, t_scale=1.0)

Given a curve `f` and its second derivative `ddf`, discretize a curve into piecewise linear segments with an approximate absolute tolerance.

If `rtol` is provided, the effective tolerance at each step is `max(tolerance, rtol / curvature)`, i.e. `rtol * radius_of_curvature`. This allows coarser discretization on gentle curves while preserving accuracy on tight ones.

`t_scale` converts parameter-space steps to arclength for the kernel's chord-height formula. When `ddf` has curvature units (1/length), pass `t_scale = pathlength(curve)`.
"""
function discretize_curve(f, ddf, tolerance; rtol=nothing, t_scale=1.0)
    ts = discretization_grid(ddf, tolerance; rtol=rtol, t_scale=t_scale)
    return f.(ts)
end

function discretize_curve(s::Paths.Segment, tolerance; rtol=nothing)
    return s.(discretization_grid(s, tolerance; rtol=rtol) * pathlength(s))
end

function discretize_curve(s::Paths.BSpline, tolerance; rtol=nothing)
    return s.r.(discretization_grid(s, tolerance; rtol=rtol))
end

function discretization_grid(s::Paths.Segment, tolerance; rtol=nothing)
    l = pathlength(s)
    return discretization_grid(
        t -> Paths.signed_curvature(s, t * l),
        tolerance;
        t_scale=l,
        rtol=rtol
    )
end

# ConstantOffset segments are parameterized by the base curve's arclength, but
# the actual arclength per unit parameter is |1 - offset * κ_base(t)|. The generic
# Segment method uses pathlength(s) as t_scale, which equals the *base* curve's
# length, not the offset curve's actual arclength. This underestimates t_scale for
# outer offsets and overestimates for inner offsets, causing the chord-height tolerance
# to be violated.
# TODO: For varying base curvature, a single t_scale is an approximation. A fully
# correct approach would incorporate local curve speed into the marching kernel.
function discretization_grid(s::Paths.ConstantOffset, tolerance; rtol=nothing)
    l = pathlength(s)
    # Use the maximum curve speed at the endpoints as t_scale. This is conservative:
    # it may produce slightly more points than necessary, but never exceeds tolerance.
    # (Exact for constant-curvature base curves like Turn.)
    κ_base_start = Paths.signed_curvature(s.seg, zero(l))
    κ_base_end = Paths.signed_curvature(s.seg, l)
    max_speed = max(abs(1 - s.offset * κ_base_start), abs(1 - s.offset * κ_base_end))
    actual_l = l * max_speed
    return discretization_grid(
        t -> Paths.signed_curvature(s, t * l),
        tolerance;
        t_scale=actual_l,
        rtol=rtol
    )
end

# True curvature κ(t) = |r'×r''|/|r'|³ for a 2D BSpline interpolation r.
# Returns a scalar with units 1/length, matching the marching kernel's
# `cc` contract.
function _bspline_curvature(r, t)
    g = Paths.Interpolations.gradient(r, t)[1]
    h = Paths.Interpolations.hessian(r, t)[1]
    return abs(g.x * h.y - g.y * h.x) / (g.x^2 + g.y^2)^(3 // 2)
end

function discretization_grid(s::Paths.BSpline, tolerance; rtol=nothing)
    # Use true curvature κ = |r'×r''|/|r'|³ (units: 1/length) as the kernel's
    # `cc`, so the kernel's rtol/cc formula is dimensionally correct.
    # `t_scale = pathlength(s)` because true curvature is parameterization-free;
    # the kernel converts `t`-steps to length-steps via `t_scale`. Under the
    # standard ds/dt ≈ L approximation (BSplines are not arclength-
    # parameterized) this algebraically matches Hessian-based step size.
    l = pathlength(s)
    return discretization_grid(
        t -> _bspline_curvature(s.r, t),
        tolerance;
        t_scale=l,
        rtol=rtol
    )
end

# Discretize using marching algorithm based on Hessian or curvature
function discretization_grid(
    ddf,
    tolerance,
    bnds::Tuple{Float64, Float64}=(0.0, 1.0);
    t_scale=1.0,
    rtol=nothing
)
    dt = 0.01 * bnds[2]
    ts = zeros(100)
    ts[1] = bnds[1]
    t = bnds[1]
    i = 1
    cc = norm(ddf(t))
    while t < bnds[2]
        i = i + 1
        i > length(ts) && resize!(ts, 2 * length(ts))
        t = ts[i - 1]
        # Effective tolerance: use rtol * radius_of_curvature when it exceeds atol.
        # cc has units (curvature, e.g., rad/μm) so compare with zero(cc), not `0`.
        eff_tol = (!isnothing(rtol) && !iszero(cc)) ? max(tolerance, rtol / cc) : tolerance
        # Set dt based on distance from chord assuming constant curvature
        # TODO: This "is curvature near zero?" guard over-refines SHORT, TIGHT arcs. The
        # threshold scales as 1/t_scale^2, so for a short arc (small pathlength → small
        # t_scale) it can exceed the actual curvature `cc` even when the arc is sharply
        # curved — the adaptive `dt` update is then skipped and the initial fixed
        # dt = 0.01*bnds[2] (≈100 steps) is used instead, producing ~10× more points than
        # necessary (e.g. a 30°/2μm fillet gets ~101 points vs ~10 from circular_arc).
        # Surfaced by the rounding unification (small fillets now discretize here instead
        # of via circular_arc). A correct fix must be t_scale-INDEPENDENT, but cannot be a
        # blanket `!iszero(cc)`: that breaks VARIABLE-curvature curves (BSplines/offsets)
        # whose endpoints sample cc≈0, causing the marcher to leap over a curved middle in
        # a single step. The real fix likely splits constant-curvature arcs (one sample is
        # exact → unbounded sagitta step OK) from variable-curvature curves (need a
        # max-step ceiling so the middle is sampled). Touches the whole path-rendering
        # pipeline, so it is intentionally NOT bundled with the rounding unification.
        if cc >= 100 * 8 * eff_tol / (bnds[2]^2 * t_scale^2) # Update dt if curvature is not near zero
            dt = uconvert(NoUnits, sqrt(8 * eff_tol / cc) / t_scale)
        end
        if t + dt >= bnds[2]
            dt = bnds[2] - t
        end
        # Check that curvature didn't increase too much (decrease is fine)
        # Rare but may happen near inflection points
        cc_next = norm(ddf(t + dt))
        eff_tol_next =
            (!isnothing(rtol) && !iszero(cc_next)) ? max(tolerance, rtol / cc_next) :
            tolerance
        if (t_scale * dt)^2 * (cc_next - cc) / 24 > eff_tol_next
            dt = uconvert(NoUnits, sqrt(8 * eff_tol_next / cc_next) / t_scale)
            cc_next = norm(ddf(t + dt))
        end
        cc = cc_next
        ts[i] = min(bnds[2], t + dt)
        t = ts[i]
    end
    # Make sure last two points aren't unnecessarily close together
    if ts[i - 1] > (ts[i] + ts[i - 2]) / 2
        ts[i - 1] = (ts[i] + ts[i - 2]) / 2
    end
    return ts[1:i]
end
