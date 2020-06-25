using DiffEqJump, DiffEqBase
using Plots, BenchmarkTools

doplot = false
dobenchmark = false
doanimation = true

function plot_solution(sol)
    println("Plotting")
    labels = vcat([["A $i", "B $i", "C $i"] for i in 1:num_nodes]...)
    trajectories = [hcat(sol.u...)[i,:] for i in 1:length(spatial_jump_prob.prob.u0)]
    plot1 = plot(sol.t, trajectories[1], label = labels[1])
    for i in 2:3
        plot!(plot1, sol.t, trajectories[i], label = labels[i])
    end
    title!("A + B <--> C RDME")
    xaxis!("time")
    yaxis!("number")
    plot1
end

# ABC model A + B <--> C
reactstoch = [
    [1 => 1, 2 => 1],
    [3 => 1],
]
netstoch = [
    [1 => -1, 2 => -1, 3 => 1],
    [1 => 1, 2 => 1, 3 => -1]
]
spec_to_dep_jumps = [[1],[1],[2]]
jump_to_dep_specs = [[1,2,3],[1,2,3]]
rates = [0.1, 1.]
majumps = MassActionJump(rates, reactstoch, netstoch)
prob = DiscreteProblem([500,500,0],(0.0,0.25), rates)

# Graph setup
domain_size = 1.0 #μ-meter
num_sites_per_edge = 32
diffusivity = 0.1
hopping_rate = diffusivity * (num_sites_per_edge/domain_size)^2
dimension = 2
connectivity_list = connectivity_list_from_box(num_sites_per_edge, dimension)
num_nodes = length(connectivity_list)

diff_rates_for_edge = [hopping_rate for species in 1:length(prob.u0)]
diff_rates = [[diff_rates_for_edge for j in 1:length(connectivity_list[i])] for i in 1:num_nodes]

# Starting state setup
starting_state = zeros(Integer, num_nodes*length(prob.u0))
# starting_state[1 : length(prob.u0)] = copy(prob.u0)
center_node = coordinates_to_node(trunc(Integer,num_sites_per_edge/2),trunc(Integer,num_sites_per_edge/2),num_sites_per_edge)
center_node_first_species_index = to_spatial_spec(center_node, 1, length(prob.u0))
starting_state[center_node_first_species_index : center_node_first_species_index + length(prob.u0) - 1] = copy(prob.u0)


if doplot
    # Solving
    alg = RSSACR()
    println("Solving with $alg")
    jump_prob = JumpProblem(prob, alg, majumps, save_positions=(false,false), vartojumps_map=spec_to_dep_jumps, jumptovars_map=jump_to_dep_specs)
    spatial_jump_prob = to_spatial_jump_prob(connectivity_list, diff_rates, jump_prob, starting_state = starting_state)
    sol = solve(spatial_jump_prob, SSAStepper(), saveat = prob.tspan[2]/50)
    # Plotting
    plt = plot_solution(sol)
    display(plt)
end

function benchmark_n_times(jump_prob, n)
    solve(jump_prob, SSAStepper())
    times = zeros(n)
    for i in 1:n
        times[i] = @elapsed solve(jump_prob, SSAStepper())
    end
    times
end

if dobenchmark
    # these constants can be pplayed with:
    rates = [1., 10.]
    diffusivity = 1.
    num_sites_per_edge = 32
    prob = DiscreteProblem([500,500,0],(0.0,0.25), rates)

    majumps = MassActionJump(rates, reactstoch, netstoch)
    domain_size = 1.0 #μ-meter
    hopping_rate = diffusivity * (num_sites_per_edge/domain_size)^2
    dimension = 2
    connectivity_list = connectivity_list_from_box(num_sites_per_edge, dimension)
    num_nodes = length(connectivity_list)

    diff_rates_for_edge = [hopping_rate for species in 1:length(prob.u0)]
    diff_rates = [[diff_rates_for_edge for j in 1:length(connectivity_list[i])] for i in 1:num_nodes]

    # Starting state setup
    starting_state = zeros(Integer, num_nodes*length(prob.u0))
    # starting_state[1 : length(prob.u0)] = copy(prob.u0)
    center_node = coordinates_to_node(trunc(Integer,num_sites_per_edge/2),trunc(Integer,num_sites_per_edge/2),num_sites_per_edge)
    center_node_first_species_index = to_spatial_spec(center_node, 1, length(prob.u0))
    starting_state[center_node_first_species_index : center_node_first_species_index + length(prob.u0) - 1] = copy(prob.u0)

    for alg in [RSSACR(), DirectCR(), NRM()]
        short_label = "$alg"[1:end-2]
        spatial_jump_prob = to_spatial_jump_prob(connectivity_list, diff_rates, majumps, prob, alg; starting_state = starting_state)
        println("Solving with $(spatial_jump_prob.aggregator)")
        solve(jump_prob, SSAStepper())
        # times = benchmark_n_times(spatial_jump_prob, 5)
        # median_time = median(times)
        # println("Solving the problem took $median_time seconds.")
        @btime solve($spatial_jump_prob, $(SSAStepper()))
        println("Animating...")
        sol=solve(jump_prob, SSAStepper(), saveat = prob.tspan[2]/20.)
        animate_2d(sol, species_labels = ["A", "B", "C"], title = "A + B <--> C", fps = 2)
    end
end

# Make animation
if doanimation
    alg = RSSACR()
    println("Setting up...")
    spatial_jump_prob = to_spatial_jump_prob(connectivity_list, diff_rates, majumps, prob, alg, starting_state = starting_state)
    println("Solving...")
    sol = solve(spatial_jump_prob, SSAStepper(), saveat = prob.tspan[2]/200)
    println("Animating...")
    anim=animate_2d(sol, num_sites_per_edge, species_labels = ["A", "B", "C"], title = "A + B <--> C", verbose = true)
    fps = 15
    path = joinpath(@__DIR__, "test", "spatial")
    gif(anim, "$(path)anim_$(length(sol.u))frames_$(fps)fps.gif", fps = fps)
end
