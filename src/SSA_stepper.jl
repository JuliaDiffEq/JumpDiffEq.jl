# Integrator specifically for SSA
# Built to have 0-overhead stepping

struct SSAStepper <: DiffEqBase.DEAlgorithm end

mutable struct SSAIntegrator{F,uType,tType,P,S,CB,SA,OPT,TS} <: DiffEqBase.DEIntegrator{SSAStepper,Nothing,uType,tType}
    f::F
    u::uType
    t::tType
    tprev::tType
    p::P
    sol::S
    i::Int
    tstop::tType
    cb::CB
    saveat::SA
    save_everystep::Bool
    save_end::Bool
    cur_saveat::Int
    opts::OPT
    tstops::TS
    tstops_idx::Int
    u_modified::Bool
    keep_stepping::Bool          # false if should terminate a simulation
end

(integrator::SSAIntegrator)(t) = copy(integrator.u)
(integrator::SSAIntegrator)(out,t) = (out .= integrator.u)

function DiffEqBase.u_modified!(integrator::SSAIntegrator,bool::Bool)
    integrator.u_modified = bool
end

function DiffEqBase.__solve(jump_prob::JumpProblem,
                         alg::SSAStepper;
                         kwargs...)
    integrator = init(jump_prob,alg;kwargs...)
    solve!(integrator)
    integrator.sol
end

function DiffEqBase.solve!(integrator)

    end_time = integrator.sol.prob.tspan[2]
    while should_continue_solve(integrator) # It stops before adding a tstop over
        step!(integrator)
    end    
    integrator.t = end_time

    if integrator.saveat !== nothing && !isempty(integrator.saveat)
        # Split to help prediction
        while integrator.cur_saveat <= length(integrator.saveat) &&
           integrator.saveat[integrator.cur_saveat] < integrator.t

            push!(integrator.sol.t,integrator.saveat[integrator.cur_saveat])
            push!(integrator.sol.u,copy(integrator.u))
            integrator.cur_saveat += 1

        end
    end

    if integrator.save_end && integrator.sol.t[end] != end_time
        push!(integrator.sol.t,end_time)
        push!(integrator.sol.u,copy(integrator.u))
    end

    DiffEqBase.finalize!(integrator.opts.callback, integrator.u, integrator.t, integrator)
end

function DiffEqBase.__init(jump_prob::JumpProblem,
                         alg::SSAStepper;
                         save_start = true,
                         save_end = true,
                         seed = nothing,
                         alias_jump = Threads.threadid() == 1,
                         saveat = nothing,
                         callback = nothing,
                         tstops = eltype(jump_prob.prob.tspan)[],
                         numsteps_hint=100)
    if !(jump_prob.prob isa DiscreteProblem)
        error("SSAStepper only supports DiscreteProblems.")
    end
    @assert isempty(jump_prob.jump_callback.continuous_callbacks)
    if alias_jump
      cb = jump_prob.jump_callback.discrete_callbacks[end]
      if seed !== nothing
          Random.seed!(cb.condition.rng,seed)
      end
    else
      cb = deepcopy(jump_prob.jump_callback.discrete_callbacks[end])
      if seed === nothing
          Random.seed!(cb.condition.rng,seed_multiplier()*rand(UInt64))
      else
          Random.seed!(cb.condition.rng,seed)
      end
    end

    opts = (callback = CallbackSet(callback),)
    prob = jump_prob.prob

    if save_start
        t = [prob.tspan[1]]
        u = [copy(prob.u0)]
    else
        t = typeof(prob.tspan[1])[]
        u = typeof(prob.u0)[]
    end


    sol = DiffEqBase.build_solution(prob,alg,t,u,dense=false,
                         calculate_error = false,
                         destats = DiffEqBase.DEStats(0),
                         interp = DiffEqBase.ConstantInterpolation(t,u))
    save_everystep = any(cb.save_positions)

    if typeof(saveat) <: Number
        _saveat = prob.tspan[1]:saveat:prob.tspan[2]
    else
        _saveat = saveat
    end

   if _saveat !== nothing && !isempty(_saveat) && _saveat[1] == prob.tspan[1]
       cur_saveat = 2
   else
       cur_saveat = 1
   end

   if _saveat !== nothing && !isempty(_saveat)
     sizehint!(u,length(_saveat)+1)
     sizehint!(t,length(_saveat)+1)
   elseif save_everystep
     sizehint!(u,numsteps_hint)
     sizehint!(t,numsteps_hint)
   else
     sizehint!(u,save_start+save_end)
     sizehint!(t,save_start+save_end)
   end

    integrator = SSAIntegrator(prob.f,copy(prob.u0),prob.tspan[1],prob.tspan[1],prob.p,
                               sol,1,prob.tspan[1],
                               cb,_saveat,save_everystep,save_end,cur_saveat,
                               opts,tstops,1,false,true)
    cb.initialize(cb,integrator.u,prob.tspan[1],integrator)
    DiffEqBase.initialize!(opts.callback,integrator.u,prob.tspan[1],integrator)
    integrator
end

function DiffEqBase.add_tstop!(integrator::SSAIntegrator,tstop)
    if tstop > integrator.t
        future_tstops = @view integrator.tstops[integrator.tstops_idx:end]
        insert_index = integrator.tstops_idx + searchsortedfirst(future_tstops, tstop) - 1
        Base.insert!(integrator.tstops, insert_index, tstop) 
    end
end

# The Jump aggregators should not register the next jump through add_tstop! for SSAIntegrator
# such that we can achieve maximum performance
@inline function register_next_jump_time!(integrator::SSAIntegrator, p::AbstractSSAJumpAggregator, t)
    integrator.tstop = p.next_jump_time
    nothing
end

function DiffEqBase.step!(integrator::SSAIntegrator)
    integrator.tprev = integrator.t
    next_jump_time = integrator.tstop > integrator.t ? integrator.tstop : typemax(integrator.tstop)

    doaffect = false
    if !isempty(integrator.tstops) &&
        integrator.tstops_idx <= length(integrator.tstops) &&
        integrator.tstops[integrator.tstops_idx] < next_jump_time

        integrator.t = integrator.tstops[integrator.tstops_idx]
        integrator.tstops_idx += 1
    else
        integrator.t = integrator.tstop
        doaffect = true # delay effect until after saveat
    end

    @inbounds if integrator.saveat !== nothing && !isempty(integrator.saveat)
        # Split to help prediction
        while integrator.cur_saveat < length(integrator.saveat) &&
           integrator.saveat[integrator.cur_saveat] < integrator.t

            saved = true
            push!(integrator.sol.t,integrator.saveat[integrator.cur_saveat])
            push!(integrator.sol.u,copy(integrator.u))
            integrator.cur_saveat += 1
        end
    end

    # FP error means the new time may equal the old if the next jump time is 
    # sufficiently small, hence we add this check to execute jumps until
    # this is no longer true.
    while integrator.t == integrator.tstop
        doaffect && integrator.cb.affect!(integrator)
    end

    if !(typeof(integrator.opts.callback.discrete_callbacks)<:Tuple{})
        discrete_modified,saved_in_cb = DiffEqBase.apply_discrete_callback!(integrator,integrator.opts.callback.discrete_callbacks...)
    else
        saved_in_cb = false
    end

    !saved_in_cb && savevalues!(integrator)

    nothing
end

function DiffEqBase.savevalues!(integrator::SSAIntegrator,force=false)
    saved, savedexactly = false, false

    # No saveat in here since it would only use previous values,
    # so in the specific case of SSAStepper it's already handled

    if integrator.save_everystep || force
        saved = true
        savedexactly = true
        push!(integrator.sol.t,integrator.t)
        push!(integrator.sol.u,copy(integrator.u))
    end

    saved, savedexactly
end

function should_continue_solve(integrator::SSAIntegrator)
    end_time = integrator.sol.prob.tspan[2]    

    # we continue the solve if there is a tstop between now and end_time
    has_tstop = !isempty(integrator.tstops) &&
        integrator.tstops_idx <= length(integrator.tstops) &&
        integrator.tstops[integrator.tstops_idx] < end_time

    # we continue the solve if there will be a jump between now and end_time
    has_jump = integrator.t < integrator.tstop < end_time

    integrator.keep_stepping && (has_jump || has_tstop)
end

function reset_aggregated_jumps!(integrator::SSAIntegrator,uprev = nothing)
     reset_aggregated_jumps!(integrator,uprev,integrator.cb)
     nothing
end

function DiffEqBase.terminate!(integrator::SSAIntegrator, retcode = :Terminated)
    integrator.keep_stepping = false
    integrator.sol = DiffEqBase.solution_new_retcode(integrator.sol, retcode)
    nothing
end

export SSAStepper

