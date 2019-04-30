
using ..JuliaRL.FeatureCreators
import ..build_algorithm_dict
using Flux

"""
    Agent for learning online in the four rooms environment.
"""
mutable struct NNFourRoomsContAgent{O, P<:Resampling.AbstractPolicy} <: JuliaRL.AbstractAgent
    μ::P
    ER::ExperienceReplay
    WER::WeightedExperienceReplay
    opt::O
    gvf::GVF
    training_gap::Int64
    buffer_size::Int64
    batch_size::Int64
    warm_up::Int64
    algo_dict::Dict{String, Resampling.LearningUpdate}
    sample_dict::Dict{String, String}
    value_dict::Dict{String, Flux.Chain}
    counter::Int64
    state_t::Tuple{Array{Float64, 1}, Bool}
    action_t::Int64
    function TCFourRoomsContAgent(μ::P, gvf::GVF, opt::O,
                                  training_gap, buffer_size, batch_size,
                                  warm_up, parsed, env_size; max_is_ratio=1.0, rng=Random.GLOBAL_RNG) where {P<:Resampling.AbstractPolicy, O}

        # build tile coder....
        algo_dict, sample_dict, value_type_dict = build_algorithm_dict(parsed; max_is=max_is_ratio)
        value_dict = Dict{String, Array{Resampling.SparseLayer, 1}}()
        init_func=(dims...)->glorot_uniform(rng, dims...)
        for key in keys(algo_dict)
            if value_type_dict[key] == "State"
                value_dict[key] = Chain(Dense(2, 10; init=init_func), Dense(10, 10; init=init_func), Dense(10, 1; init=init_func))
            else
                value_dict[key] = Chain(Dense(2, 10; init=init_func), Dense(10, 10; init=init_func), Dense(10, 4; init=init_func))
            end
        end
        er_names = [:s_t, :s_tp1, :a_t, :r, :γ_tp1, :terminal, :mu_t, :pi_t, :ρ]
        state_type = Array{Int64, 1}
        er_types = [state_type, state_type, Int64, Float64, Float64, Bool, Float64, Float64, Float64]
        ER = ExperienceReplay(buffer_size, er_types; column_names=er_names)
        WER = WeightedExperienceReplay(buffer_size, er_types; column_names=er_names)
        new{P}(μ, ER, WER, tilecoder, gvf, training_gap, buffer_size, batch_size, warm_up,
               algo_dict, sample_dict, value_dict, warm_up, ([0.0,0.0], false), 0, α_arr)
    end
end

JuliaRL.get_action(agent::TCFourRoomsContAgent, s; rng=Random.GLOBAL_RNG) =
    StatsBase.sample(rng, agent.μ, s[1])

function JuliaRL.start!(agent::TCFourRoomsContAgent, env_s_tp1; rng=Random.GLOBAL_RNG, kwargs...)
    agent.counter = agent.warm_up
    agent.state_t = env_s_tp1
    agent.action_t = JuliaRL.get_action(agent, env_s_tp1; rng=rng)
    return agent.action_t
end

function JuliaRL.step!(agent::TCFourRoomsContAgent, env_s_tp1, r, terminal; rng=Random.GLOBAL_RNG, kwargs...)

    # After taking action at timestep t
    μ_prob = get(agent.μ, agent.state_t[1], agent.action_t, nothing, nothing, nothing)
    c, γ, π_prob = get(agent.gvf, agent.state_t, agent.action_t, env_s_tp1, nothing, nothing)

    experience = (agent.state_t[1]./11.0,
                  env_s_tp1[1]./11.0,
                  agent.action_t, c, γ, terminal, μ_prob, π_prob, π_prob/μ_prob)

    add!(agent.ER, experience)
    add!(agent.WER, experience, π_prob/μ_prob)

    if agent.counter == 0
        agent.counter = agent.training_gap
        train_value_functions(agent; rng=rng)
    end
    agent.counter -= 1

    agent.state_t = env_s_tp1
    agent.action_t = JuliaRL.get_action(agent, agent.state_t; rng=rng)
    return agent.action_t
end

function train_value_functions(agent::TCFourRoomsContAgent; rng=Random.GLOBAL_RNG)

    α_arr = agent.α_arr

    samp_er = sample(agent.ER, agent.batch_size; rng=rng)
    samp_wer = sample(agent.WER, agent.batch_size; rng=rng)

    action_tp1_er = [StatsBase.sample(rng, agent.μ, s) for s in samp_er[:s_tp1]]
    action_tp1_wer = [StatsBase.sample(rng, agent.μ, s) for s in samp_wer[:s_tp1]]
    # action_tp1 = StatsBase.sample(rng, [1, 2], StatsBase.weights(π), batch_size)

    arg_er = (samp_er[:ρ], samp_er[:s_t], samp_er[:s_tp1],
              samp_er[:r], samp_er[:γ_tp1], samp_er[:terminal],
              samp_er[:a_t], action_tp1_er, agent.gvf.policy)

    # println("ER:", samp_er[:s_t])

    arg_wer = (ones(length(samp_wer[:ρ])), samp_wer[:s_t], samp_wer[:s_tp1],
               samp_wer[:r], samp_wer[:γ_tp1], samp_wer[:terminal],
               samp_er[:a_t], action_tp1_wer, agent.gvf.policy)
    # println("WER:", samp_wer[:s_t])


    # opt = Descent(α)
    for key in keys(agent.algo_dict)
        if agent.sample_dict[key] == "IR"
            corr_term = 1.0
            if key == "BCIR"
                corr_term = Resampling.total(agent.WER)/size(agent.WER)[1]
            end
            update!(agent.value_dict[key][α_idx], agent.opt, agent.algo_dict[key], arg_wer...; corr_term=corr_term)
        elseif agent.sample_dict[key] == "ER"
            update!(agent.value_dict[key][α_idx], agent.opt, agent.algo_dict[key], arg_er...;)
        elseif agent.sample_dict[key] == "Optimal"
            samp_opt = agent.ER.buffer
            arg_opt = (samp_opt[:ρ], samp_opt[:s_t], samp_opt[:s_tp1],
                       samp_opt[:r], samp_opt[:γ_tp1], samp_opt[:terminal])
            update!(agent.value_dict[key][α_idx], opt, agent.algo_dict[key], arg_opt...;)
        end
    end
end


function predict(agent::TCFourRoomsContAgent, key, α_idx, eval_states::Array{Array{Float64, 1}, 1})
    # states = [create_features(agent.tilecoder, eval_state./11.0) for eval_state in eval_states]
    return agent.value_dict[key].(states)
end


function predict!(agent::TCFourRoomsContAgent, eval_states::Array{Array{Float64, 1}, 1}, predict_dict::Dict{String, Array{Array{Float64, 1}}})
    states = [create_features(agent.tilecoder, eval_state./11.0) for eval_state in eval_states]
    if length(keys(predict_dict)) == 0
        for key in keys(agent.value_dict)
            predict_dict[key] = [zeros(length(eval_states)) for i in 1:length(agent.α_arr)]
        end
    end
    for key in keys(agent.value_dict)
        for α_idx in 1:length(agent.α_arr)
            predict_dict[key][α_idx] .= agent.value_dict[key][α_idx].(states)
        end
    end
end
