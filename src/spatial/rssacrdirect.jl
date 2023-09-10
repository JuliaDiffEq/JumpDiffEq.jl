# site chosen with RSSACR, rx or hop chosen with Direct

############################ RSSACRDirect ###################################
const MINJUMPRATE = 2.0^exponent(1e-12)

#NOTE state vector u is a matrix. u[i,j] is species i, site j
mutable struct RSSACRDirectJumpAggregation{T, BD, M, RNG, J, RX, HOP, DEPGR,
    VJMAP, JVMAP, SS, U <: PriorityTable, S, F1, F2} <:
               AbstractSSAJumpAggregator{T, S, F1, F2, RNG}
    next_jump::SpatialJump{J}
    prev_jump::SpatialJump{J}
    next_jump_time::T
    end_time::T
    bracket_data::BD
    u_low_high::LowHigh{M} # species bracketing
    rx_rates::LowHigh{RX}
    hop_rates::LowHigh{HOP}
    site_rates::LowHigh{Vector{T}}
    save_positions::Tuple{Bool, Bool}
    rng::RNG
    dep_gr::DEPGR #dep graph is same for each site
    vartojumps_map::VJMAP #vartojumps_map is same for each site
    jumptovars_map::JVMAP #jumptovars_map is same for each site
    spatial_system::SS
    numspecies::Int #number of species
    rt::U
    rates::F1 # legacy, not used
    affects!::F2 # legacy, not used
end

function RSSACRDirectJumpAggregation(nj::SpatialJump{J}, njt::T, et::T, bd::BD,
    u_low_high::LowHigh{M}, rx_rates::LowHigh{RX},
    hop_rates::LowHigh{HOP}, site_rates::LowHigh{Vector{T}},
    sps::Tuple{Bool, Bool}, rng::RNG, spatial_system::SS;
    num_specs, minrate = convert(T, MINJUMPRATE),
    vartojumps_map = nothing, jumptovars_map = nothing,
    dep_graph = nothing,
    kwargs...) where {J, T, BD, RX, HOP, RNG, SS, M}

    # a dependency graph is needed
    if dep_graph === nothing
        dg = make_dependency_graph(num_specs, rx_rates.low.ma_jumps)
    else
        dg = dep_graph
        # make sure each jump depends on itself
        add_self_dependencies!(dg)
    end

    # a species-to-reactions graph is needed
    if vartojumps_map === nothing
        vtoj_map = var_to_jumps_map(num_specs, rx_rates.low.ma_jumps)
    else
        vtoj_map = vartojumps_map
    end

    if jumptovars_map === nothing
        jtov_map = jump_to_vars_map(rx_rates.low.ma_jumps)
    else
        jtov_map = jumptovars_map
    end

    # mapping from jump rate to group id
    minexponent = exponent(minrate)

    # use the largest power of two that is <= the passed in minrate
    minrate = 2.0^minexponent
    ratetogroup = rate -> priortogid(rate, minexponent)

    # construct an empty initial priority table -- we'll reset this in init
    rt = PriorityTable(ratetogroup, zeros(T, 1), minrate, 2 * minrate)

    RSSACRDirectJumpAggregation{T, BD, M, RNG, J, RX, HOP, typeof(dg), typeof(vtoj_map), typeof(jtov_map), SS, typeof(rt), Nothing, Nothing, Nothing}(
            nj, nj, njt, et, bd, u_low_high, rx_rates, hop_rates, site_rates, sps, rng, dg, vtoj_map, jtov_map, spatial_system, num_specs, rt, nothing, nothing)
end

############################# Required Functions ##############################
# creating the JumpAggregation structure (function wrapper-based constant jumps)
function aggregate(aggregator::RSSACRDirect, starting_state, p, t, end_time,
    constant_jumps, ma_jumps, save_positions, rng; hopping_constants,
    spatial_system, bracket_data = nothing, kwargs...)
    T = typeof(end_time)
    num_species = size(starting_state, 1)
    majumps = ma_jumps
    if majumps === nothing
        majumps = MassActionJump(Vector{T}(),
            Vector{Vector{Pair{Int, Int}}}(),
            Vector{Vector{Pair{Int, Int}}}())
    end

    next_jump = SpatialJump{Int}(typemax(Int), typemax(Int), typemax(Int)) #a placeholder
    next_jump_time = typemax(T)
    rx_rates = LowHigh(RxRates(num_sites(spatial_system), majumps),
        RxRates(num_sites(spatial_system), majumps);
        do_copy = false) # do not copy ma_jumps
    hop_rates = LowHigh(HopRates(hopping_constants, spatial_system),
        HopRates(hopping_constants, spatial_system);
        do_copy = false) # do not copy hopping_constants
    site_rates = LowHigh(zeros(T, num_sites(spatial_system)))
    bd = (bracket_data === nothing) ? BracketData{T, eltype(starting_state)}() :
         bracket_data
    u_low_high = LowHigh(starting_state)

    RSSACRDirectJumpAggregation(next_jump, next_jump_time, end_time, bd, u_low_high,
        rx_rates, hop_rates,
        site_rates, save_positions, rng, spatial_system;
        num_specs = num_species, kwargs...)
end

# set up a new simulation and calculate the first jump / jump time
function initialize!(p::RSSACRDirectJumpAggregation, integrator, u, params, t)
    p.end_time = integrator.sol.prob.tspan[2]
    fill_rates_and_get_times!(p, integrator, t)
    generate_jumps!(p, integrator, u, params, t)
    nothing
end

# calculate the next jump / jump time
function generate_jumps!(p::RSSACRDirectJumpAggregation, integrator, u, params, t)
    @unpack rng, rt, site_rates, rx_rates, hop_rates, spatial_system = p
    time_delta = zero(t)
    site = zero(eltype(u))
    while true
        site = sample(rt, site_rates.high, rng)
        time_delta += randexp(rng)
        accept_jump(rx_rates, hop_rates, site_rates, u, site, spatial_system, rng) && break
    end
    p.next_jump_time = t + time_delta / groupsum(rt)
    p.next_jump = sample_jump_direct(rx_rates.high, hop_rates.high, site, spatial_system, rng)
    nothing
end

# execute one jump, changing the system state
function execute_jumps!(p::RSSACRDirectJumpAggregation, integrator, u, params, t,
    affects!)
    update_state!(p, integrator)
    update_dependent_rates!(p, integrator, t)
    nothing
end

######################## SSA specific helper routines ########################
# Return true if site is accepted.
function accept_jump(rx_rates, hop_rates, site_rates, u, site, spatial_system, rng)
    acceptance_threshold = rand(rng) * site_rates.high[site]
    if acceptance_threshold < site_rates.low[site]
        return true
    else
        site_rate = recompute_site_hop_rate(hop_rates.low, u, site, spatial_system) +
                    recompute_site_rx_rate(rx_rates.low, u, site)
        return acceptance_threshold < site_rate
    end
end

"""
    fill_rates_and_get_times!(aggregation::RSSACRDirectJumpAggregation, u, t)

reset all stucts, reevaluate all rates, repopulate the priority table
"""
function fill_rates_and_get_times!(aggregation::RSSACRDirectJumpAggregation, integrator, t)
    @unpack bracket_data, u_low_high, spatial_system, rx_rates, hop_rates, site_rates, rt = aggregation
    u = integrator.u
    update_u_brackets!(u_low_high::LowHigh, bracket_data, u::AbstractMatrix)

    reset!(rx_rates)
    reset!(hop_rates)
    reset!(site_rates)

    rxs = 1:num_rxs(rx_rates.low)
    species = 1:(aggregation.numspecies)

    for site in 1:num_sites(spatial_system)
        update_rx_rates!(rx_rates, rxs, u_low_high, integrator, site)
        update_hop_rates!(hop_rates, species, u_low_high, site, spatial_system)
        site_rates[site] = total_site_rate(rx_rates, hop_rates, site)
    end

    # setup PriorityTable
    reset!(rt)
    for (pid, priority) in enumerate(site_rates.high)
        insert!(rt, pid, priority)
    end
    nothing
end

"""
    update_dependent_rates!(p, integrator, t)

recalculate jump rates for jumps that depend on the just executed jump (p.prev_jump)
"""
function update_dependent_rates!(p::RSSACRDirectJumpAggregation,
    integrator,
    t)
    @unpack rx_rates, hop_rates, site_rates, u_low_high, bracket_data, vartojumps_map, jumptovars_map, spatial_system = p

    u = integrator.u
    site_rates = p.site_rates
    jump = p.prev_jump

    if is_hop(p, jump)
        species_to_update = jump.jidx
        sites_to_update = (jump.src, jump.dst)
    else
        species_to_update = jumptovars_map[reaction_id_from_jump(p, jump)]
        sites_to_update = jump.src
    end

    for site in sites_to_update, species in species_to_update
        if is_outside_brackets(u_low_high, u, species, site)
            update_u_brackets!(u_low_high, bracket_data, u, species, site)
            update_rx_rates!(rx_rates,
                vartojumps_map[species],
                u_low_high,
                integrator,
                site)
            update_hop_rates!(hop_rates, species, u_low_high, site, spatial_system)

            oldrate = site_rates.high[site]
            site_rates[site] = total_site_rate(p.rx_rates, p.hop_rates, site)
            update!(p.rt, site, oldrate, site_rates.high[site])
        end
    end
end

"""
    num_constant_rate_jumps(aggregator::RSSACRDirectJumpAggregation)

number of constant rate jumps
"""
num_constant_rate_jumps(aggregator::RSSACRDirectJumpAggregation) = 0