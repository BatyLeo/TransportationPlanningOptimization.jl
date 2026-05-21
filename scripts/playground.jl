using ShipperTransportationPlanning
using ShipperTransportationPlanning:
    read_instance,
    add_properties,
    tentative_first_fit,
    VOLUME_FACTOR,
    run_simple_heursitic,
    lower_bound!,
    lower_bound_milp_variables,
    MAX_MILP_VAR,
    milp_lower_bound!,
    exact_milp_variables,
    exact_milp_solve!,
    extract_filtered_instance,
    lower_bound_filtering!,
    greedy!,
    average_delivery!,
    slope_scaling_heuristic!,
    strategic_tactical_decomposition!,
    local_search!,
    load_plan_design_ils!,
    plant_by_plant_milp!,
    exact_milp_lns!,
    mix_greedy_and_lower_bound!,
    is_feasible,
    compute_cost,
    solution_deepcopy,
    Solution

println("\n######################################\n")
println("Launching ShipperTransportationPlanning tests")
println("\n######################################\n")

instanceName = "tiny"
timeLimit = 60

@info "Test parameters" instanceName timeLimit

#####################################################################
# 1. Read instance and solution
#####################################################################

directory = joinpath(
    Base.dirname(@__DIR__), "..", "ShipperTransportationPlanning.jl", "data"
)
println("Reading data from $directory")
println("Reading instance $instanceName")
node_file = joinpath(directory, "$(instanceName)_nodes.csv")
leg_file = joinpath(directory, "$(instanceName)_legs.csv")
com_file = joinpath(directory, "$(instanceName)_commodities.csv")
# read instance 
instance = read_instance(node_file, leg_file, com_file)
# adding properties to the instance
CAPACITIES = Int[]
instance = add_properties(instance, tentative_first_fit, CAPACITIES)

totVol = sum(sum(o.volume for o in b.orders) for b in instance.bundles)
println("Instance volume : $(round(Int, totVol / VOLUME_FACTOR)) m3")

# # read solution
# sol_file = joinpath(directory, "$(instanceName)_routes.csv")
# solution = read_solution(instance, joinpath(directory, sol_file))

println("\n######################################\n")

#####################################################################
# 2. Run all heuristics
#####################################################################

# # Linear lower bound 
# println("\n####   Lower Bound    #####\n")
# solLB = run_simple_heursitic(instance, lower_bound!)
# println("\n######################################\n")

# # Load plan design lower bound 
# println(
#     "Predicted load plan design lower bound  variables : $(lower_bound_milp_variables(instance))",
# )
# println("Maximum MILP variables authorized : $MAX_MILP_VAR")
# if lower_bound_milp_variables(instance) < MAX_MILP_VAR
#     run_simple_heursitic(instance, milp_lower_bound!)
# end
# println("\n######################################\n")

# TODO : now that this is fine, experiment on Dell
# # Exact milp lower bound 
# println("Predicted exact milp variables : $(exact_milp_variables(instance))")
# println("Maximum MILP variables authorized : $(1.5 * MAX_MILP_VAR)")
# if exact_milp_variables(instance) < 1.5 * MAX_MILP_VAR
#     run_simple_heursitic(instance, exact_milp_solve!)
# end
# println("\n######################################\n")

# return 0

# Shortest delivery
# run_simple_heursitic(instance, shortest_delivery!)
# println("\n######################################\n")

# Fully outsourced 
# run_simple_heursitic(instance, fully_outsourced!)
# println("\n######################################\n")

# # Local search on current
# println("\n###   Trying local search on current  ###\n")
# run_local_search(instance, local_search!, solution, timeLimit)
# println("\n######################################\n")

# # Load plan design ils on current 
# println("\n###   Trying load plan design LNS on current  ###\n")
# run_local_search(instance, load_plan_design_ils!, solution, timeLimit)
# println("\n######################################\n")

# # Plan by plant milp 
# run_simple_heursitic(instance, plant_by_plant_milp!)
# println("\n######################################\n")

# Average, Greedy and ILS
@info "Filtering with standard procedure"
solution_LBF = run_simple_heursitic(instance, lower_bound_filtering!)
println("Bundles filtered : $(count(x -> length(x) == 2, solution_LBF.bundlePaths))")

instanceSub = extract_filtered_instance(instance, solution_LBF)
instanceSub = add_properties(instanceSub, tentative_first_fit, CAPACITIES)

# # Greedy
# solG = run_simple_heursitic(instanceSub, greedy!)
# println("\n######################################\n")

# # Average delivery 
# run_simple_heursitic(instanceSub, average_delivery!)
# println("\n######################################\n")

# # Slope scaling 
# run_simple_heursitic(instanceSub, slope_scaling_heuristic!)
# println("\n######################################\n")

# # Inter-Intra Decomposition 
# run_simple_heursitic(instanceSub, strategic_tactical_decomposition!)
# println("\n######################################\n")

# return 0

# # Exact milp LNS 
# println("\n###   Trying exact milp LNS on current  ###\n")
# run_local_search(instance, exact_milp_lns!, solG, timeLimit)
# println("\n######################################\n")

@info "Constructing greedy, lower bound and mixed solution"
solution_Mix = Solution(instanceSub)
solution_G, solution_LB = mix_greedy_and_lower_bound!(solution_Mix, instanceSub)
feasibles = [
    is_feasible(instanceSub, sol) for sol in [solution_Mix, solution_G, solution_LB]
]
mixCost = compute_cost(instanceSub, solution_Mix)
gCost = compute_cost(instanceSub, solution_G)
lbCost = compute_cost(instanceSub, solution_LB)
@info "Mixed heuristic results" :feasible = string(feasibles) :mixed_cost = mixCost :greedy_cost =
    gCost :lower_bound_cost = lbCost

# Choosing the best solution as the starting solution
solutionSub = solution_deepcopy(solution_G, instanceSub)
choiceSolution = argmin([mixCost, gCost, lbCost])
if choiceSolution == 3
    solutionSub = solution_LB
    @info "Lower bound solution chosen"
elseif choiceSolution == 1
    solutionSub = solution_Mix
    @info "Mixed solution chosen"
else
    @info "Greedy solution chosen"
end

# Full ILS 
pertLimit = round(Int, min(180, timeLimit / 5))
lsLimit = min(2700, timeLimit)

println("\n###   Initial local search   ###\n")
local_search!(solutionSub, instanceSub; timeLimit=60)

# ILS!(
#     solutionSub,
#     instanceSub;
#     timeLimit=min(21600, 2 * timeLimit),
#     perturbTimeLimit=pertLimit,
#     lsTimeLimit=lsLimit,
#     solName="$(instanceName)",
#     timedelta=lsLimit,
# )

return 0

# Ablation study for the ILS
i = 0
for lsParams in subsets([:reintro, :consolidate])
    length(lsParams) == 2 && continue
    for pertParams in subsets([:singlePlant, :attractReduce])
        length(pertParams) == 0 && length(lsParams) == 0 && continue
        length(pertParams) == 2 && continue
        println()
        @info "Ablation test $i" lsParams pertParams
        println()
        # Copying base solution
        solutionSub = solution_deepcopy(solution_G, instanceSub)
        # Applying local search with current parameters 
        local_search!(
            solutionSub,
            instanceSub;
            timeLimit=lsLimit,
            allowReintro=(:reintro in lsParams),
            allowConsolidate=(:consolidate in lsParams),
        )
        # Applying ILS with current parameters
        ILS!(
            solutionSub,
            instanceSub;
            timeLimit=min(10800, 2 * timeLimit),
            perturbTimeLimit=pertLimit,
            lsTimeLimit=lsLimit,
            solName="$(instanceName)",
            timedelta=lsLimit,
            allowSinglePlant=(:singlePlant in pertParams),
            allowAttractReduce=(:attractReduce in pertParams),
            allowDirects=(:attractReduce in pertParams) && (:singlePlant in pertParams),
            allowReintro=(:reintro in lsParams),
            allowConsolidate=(:consolidate in lsParams),
            allowRepack=true,
        )
        i += 1
    end
end
