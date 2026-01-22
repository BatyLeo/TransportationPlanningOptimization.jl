using TransportationPlanningOptimization
using Documenter
using Literate

# Generate tutorials from Literate.jl source files
tutorials_src_dir = joinpath(@__DIR__, "src", "tutorials")
tutorials_build_dir = joinpath(@__DIR__, "src", "tutorials")

for file in readdir(tutorials_src_dir)
    if endswith(file, ".jl")
        Literate.markdown(
            joinpath(tutorials_src_dir, file),
            tutorials_build_dir;
            documenter=true
        )
    end
end

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
    pages=[
        "Home" => "index.md",
        "Getting Started" => "getting_started.md",
        "Tutorials" => [
            "Basic Example" => "tutorials/basic_example.md",
        ],
        "Guides" => [
            "Cost Functions" => "guides/cost_functions.md",
            "Forbidden Constraints" => "guides/forbidden_constraints.md",
        ],
        "API Reference" => "api.md",
    ],
)

deploydocs(;
    repo="github.com/BatyLeo/TransportationPlanningOptimization.jl", devbranch="main"
)

# Remove generated tutorial.md files
for file in readdir(tutorials_build_dir)
    if endswith(file, ".md") && file != "index.md"
        rm(joinpath(tutorials_build_dir, file))
    end
end
