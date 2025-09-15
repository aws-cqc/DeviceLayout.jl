# abstract type AbstractBundle{T} <: AbstractComponent{T} end

# struct Bundle{T} <: AbstractBundle{T}
#     spine::Path{T}
#     paths::Vector{Path{T}}
# end

# paths(b::Bundle) = b.paths
# hooks(b::Bundle) = (;
#     p0 = [p0_hook(pa) for pa in paths(b)],
#     p1 = [p1_hook(pa) for pa in paths(b)],
# )


# Optimizing bundles
using Optimization
using Enzyme
using Zygote
using FiniteDiff
using ForwardDiff
using Interpolations
using LinearAlgebra

# Manual BSpline creation
p(t) = 1/6 * (1 - t)^3
q(t) = (2/3 - t^2 + 1/2 * t^3)
u(c, dt, i) = c[i, :]*p(dt) + c[i+1, :]*q(dt) + c[i+2, :]*q(1-dt) + c[i+3, :]*p(1-dt)
function bspline(c, t)
    t <= 0.0 && return u(c, t, 1)
    npoints = size(c)[1] - 2
    dt = (t % (1/(npoints-1)))*(npoints-1)
    i = Int(floor(t / (1/(npoints-1)))+1)
    i >= npoints && return u(c, dt + (i - npoints + 1), npoints-1)
    return u(c, dt, i)
end
function bspline_from_data(x)
    return t -> bspline(bspline_coefs(x), t)
end

function bspline_tangent_constraint_matrix(num_points)
    A = zeros(num_points+2, num_points+2)
    A[1, 1:3] .= [-1/2, 0.0, 1/2]
    A[end, end-2:end] .= [-1/2, 0.0, 1/2]
    for i = 2:num_points+1
        A[i, i-1:i+1] .= [1/6, 2/3, 1/6]
    end
    return A
end
bspline_rhs(points, t0, t1) = [t0; points; t1]
function bspline_coefs(rhs; A=bspline_tangent_constraint_matrix(size(rhs)[1]-2))
    return A \ rhs
end

function bspline_curvature_constraint_matrix(num_points)
    num_points = num_points + 2
    A = zeros(num_points+4, num_points+4)
    A[1, 1:3] .= [-1/2, 0.0, 1/2]
    A[end-2, end-4:end-2] .= [-1/2, 0.0, 1/2]
    for i = 2:num_points+1
        A[i, i-1:i+1] .= [1/6, 2/3, 1/6]
    end
    A[3, end-1] = -1
    A[end-4, end] = -1
    A[end-1, 1:3] .= [1, -2, 1]
    A[end, end-4:end-2] .= [1, -2, 1]
    return A
end
function bspline_curvature_rhs(points, t0, t1, κ0=0.0, κ1=0.0;
        A=bspline_curvature_constraint_matrix(size(points)[1]))
    b0 = [t0/3;
        points[1:1, :];
        0.0 0.0;
        points[2:end-1, :];
        0.0 0.0;
        points[end:end, :];
        t1/3;
        (-t0[2] * κ0 * norm(t0)) (t0[1] * κ0 * norm(t0));
        (-t1[2] * κ1* norm(t1)) (t1[1] * κ1 * norm(t1))
    ]
    return b0
end

function bspline_curvature_coefs(rhs; A=bspline_curvature_constraint_matrix(size(rhs)[1]-6))
    return (A \ rhs)[1:end-2, :]
end

const A0 = [-1/2 0.0 1/2 0.0
         1/6 2/3 1/6 0.0
         0.0 1/6 2/3 1/6
         0.0 -1/2 0.0 1/2]

b = [1.0 0.0
     0.0 0.0
     0.6 0.375
     1.0 1.0
     0.0 1.0]
db = zeros(size(b))
y = [0.0]
dy = [1.0]

function test_moment(x, _)
    b = bspline_from_data(reshape(x, (Int(size(x)[1]/2), 2)))
    return abs(b(0.5)[1] - 0.5)
end

optf = OptimizationFunction(test_moment, AutoEnzyme())
prob = OptimizationProblem(optf, reshape(b, 10), 0.0)
sol = solve(prob, Optimization.LBFGS())

function f_conformal(z, wa1, wa2)
    x = exp(-2*pi*z/wa1)
    k = (wa1/wa2)^2
    u = sqrt((x - 1)/(x-k))
    return (-wa1/(2*pi)) * (
        log((1+u) / (1-u))
        - 1/sqrt(k) * log((1+sqrt(k)*u)/(1-sqrt(k)*u))
    )
end

plot(; legend=:none, aspect_ratio=:equal)
wa1 = 3.3
w1 = 3
ws = []
for y in range((wa1 - w1)/2, wa1/2, length=10)
    z = [x + y*1im for x in -wa1:0.1:wa1]
    w = f_conformal.(z, wa1, 1*wa1/w1)
    push!(ws, w)
    plot!(real.(w),imag.(w))
end
gui()
