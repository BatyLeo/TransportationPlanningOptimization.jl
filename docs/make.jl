using TransportationPlanningOptimization
using Documenter

DocMeta.setdocmeta!(
    TransportationPlanningOptimization,
    :DocTestSetup,
    :(using TransportationPlanningOptimization);
    recursive=true,
)

makedocs(;
    modules=[TransportationPlanningOptimization],
    authors="Léo Baty and contributors",
    sitename="TransportationPlanningOptimization.jl",
    format=Documenter.HTML(;
        canonical="https://BatyLeo.github.io/TransportationPlanningOptimization.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=["Home" => "index.md"],
)

deploydocs(;
    repo="github.com/BatyLeo/TransportationPlanningOptimization.jl", devbranch="main"
)
