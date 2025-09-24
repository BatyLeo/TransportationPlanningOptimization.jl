using CSV
using DataFrames

data = DataFrame(CSV.File("data/outbound/parsed/parsed_volumes.csv"))

filtered_data =
    filter(row -> row.usine == 459 && row.destinationFinale == 336 && row.model == 1, data)
sort!(filtered_data, [:annee, :semaine])
CSV.write("filtered_data.csv", filtered_data)
