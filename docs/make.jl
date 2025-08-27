using NetworkDesignOptimization
using Documenter

DocMeta.setdocmeta!(NetworkDesignOptimization, :DocTestSetup, :(using NetworkDesignOptimization); recursive=true)

makedocs(;
    modules=[NetworkDesignOptimization],
    authors="Léo Baty and contributors",
    sitename="NetworkDesignOptimization.jl",
    format=Documenter.HTML(;
        canonical="https://BatyLeo.github.io/NetworkDesignOptimization.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/BatyLeo/NetworkDesignOptimization.jl",
    devbranch="main",
)
