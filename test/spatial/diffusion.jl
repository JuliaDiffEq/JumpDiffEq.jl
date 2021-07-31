using DiffEqJump, DiffEqBase
using Test
using LinearAlgebra
using LightGraphs

function get_mean_sol(jump_prob, Nsims, saveat)
    sol = solve(jump_prob, SSAStepper(), saveat = saveat).u
    for i in 1:Nsims-1
        sol += solve(jump_prob, SSAStepper(), saveat = saveat).u
    end
    sol/Nsims
end

# assume sites are labeled from 1 to num_sites(spatial_system)
function discrete_laplacian_from_spatial_system(spatial_system, hopping_rate)
    sites = 1:DiffEqJump.num_sites(spatial_system)
    laplacian = zeros(length(sites), length(sites))
    for site in sites
        laplacian[site,site] = -DiffEqJump.num_neighbors(spatial_system, site)
        for nb in DiffEqJump.neighbors(spatial_system, site)
            laplacian[site, nb] = 1
        end
    end
    laplacian .*= hopping_rate
    laplacian
end

# problem setup
majumps = JumpSet(nothing)
tf = 0.5
u0 = [100]
num_species = 1

domain_size = 1.0 #μ-meter
linear_size = 5
diffusivity = 0.1
dim = 2
dims = Tuple([linear_size for i in 1:dim])
num_nodes = prod(dims)

# Starting state setup
starting_state = zeros(Int, length(u0), num_nodes)
center_node = trunc(Int,(num_nodes+1)/2)
starting_state[:,center_node] = copy(u0)
tspan = (0.0, tf)
prob = DiscreteProblem(starting_state,tspan, [])

hopping_rate = diffusivity * (linear_size/domain_size)^2
hopping_constants = [hopping_rate for i in starting_state]

# analytic solution
lap = discrete_laplacian_from_spatial_system(LightGraphs.grid(dims), hopping_rate)
evals, B = eigen(lap) # lap == B*diagm(evals)*B'
Bt = B'
analytic_solution(t) = B*diagm(ℯ.^(t*evals))*Bt * reshape(prob.u0, num_nodes, 1)

alg = NSM()
num_time_points = 10
Nsims = 10000
rel_tol = 0.01
times = 0.0:tf/num_time_points:tf

grids = [DiffEqJump.CartesianGridRej(dims), DiffEqJump.CartesianGridIter(dims), LightGraphs.grid(dims)]
jump_problems = JumpProblem[JumpProblem(prob, alg, majumps, hopping_constants=hopping_constants, spatial_system = grid, save_positions=(false,false)) for grid in grids]
# setup flattenned jump prob
graph = LightGraphs.grid(dims)
push!(jump_problems, JumpProblem(prob, NRM(), majumps, hopping_constants=hopping_constants, spatial_system = graph, save_positions=(false,false)))
# hop rates of form L_{s,i,j}
hopping_constants = Vector{Matrix{Float64}}(undef, num_nodes)
for site in 1:num_nodes
    hopping_constants[site] = hopping_rate*ones(num_species, DiffEqJump.num_neighbors(graph, site))
end
push!(jump_problems, JumpProblem(prob, alg, majumps, hopping_constants=hopping_constants, spatial_system=graph, save_positions=(false,false)))
for spatial_jump_prob in jump_problems
    mean_sol = get_mean_sol(spatial_jump_prob, Nsims, tf/num_time_points)

    for (i,t) in enumerate(times)
        local diff = analytic_solution(t) - reshape(mean_sol[i], num_nodes, 1)
        @test abs(sum(diff[1:center_node])/sum(analytic_solution(t)[1:center_node])) < rel_tol
    end
end

# testing non-uniform hopping rates
dims = (2,2)
num_nodes = prod(dims)
grid = LightGraphs.grid(dims)
hopping_constants = Vector{Matrix{Float64}}(undef, prod(dims))
for site in 1:prod(dims)
    hopping_constants[site] = ones(1, DiffEqJump.num_neighbors(grid, site))
end
fill!(hopping_constants[1], 0.0)
hopping_constants[2][2] = 0.0
hopping_constants[3][2] = 0.0

starting_state = 25*ones(Int, length(u0), num_nodes)
tspan = (0.0, 10.0)
prob = DiscreteProblem(starting_state,tspan, [])

jp=JumpProblem(prob, alg, majumps, hopping_constants=hopping_constants, spatial_system = grid, save_positions=(false,false))
sol = solve(jp, SSAStepper())

@test sol.u[end][1,1] == sum(sol.u[end])
