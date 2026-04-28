module TransportationPlanningOptimizationGurobiExt

using TransportationPlanningOptimization: TransportationPlanningOptimization
using Gurobi: Gurobi

const GRB_ENV = Ref{Gurobi.Env}()

function __init__()
    GRB_ENV[] = Gurobi.Env()
    return nothing
end

function TransportationPlanningOptimization.gurobi_optimizer()
    return Gurobi.Optimizer(GRB_ENV[])
end

end
