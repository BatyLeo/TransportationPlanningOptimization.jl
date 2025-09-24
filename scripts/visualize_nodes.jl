using CSV, DataFrames, GLMakie
using Tyler
using Tyler.TileProviders
using Tyler.MapTiles
using Tyler.Extents

data_dir = joinpath(@__DIR__, "..", "data", "outbound", "parsed")
nodes_file = joinpath(data_dir, "parsed_nodes.csv")

nodes_df = CSV.read(nodes_file, DataFrame)
valid_nodes = filter(
    row ->
        row.Latitude <= 90 &&
            row.Longitude <= 180 &&
            row.Latitude >= -90 &&
            row.Longitude >= -180,
    nodes_df,
)

type_counts = combine(groupby(valid_nodes, :TypeNode), nrow => :count)
println(type_counts)

min_lon = minimum(valid_nodes.Longitude)
min_lat = minimum(valid_nodes.Latitude)
max_lon = maximum(valid_nodes.Longitude)
max_lat = maximum(valid_nodes.Latitude)

lat_range = max_lat - min_lat
lon_range = max_lon - min_lon

extent = Rect2f(min_lon, min_lat, lon_range, lat_range)

provider = TileProviders.OpenStreetMap(:Mapnik)
m = Tyler.Map(extent; provider);

for row in eachrow(valid_nodes)
    lon = row.Longitude
    lat = row.Latitude
    color = :red
    if row.TypeNode == "CO"
        color = :blue
    elseif row.TypeNode == "PO"
        color = :green
    elseif row.TypeNode == "ZG"
        color = :orange
    elseif row.TypeNode == "PC"
        color = :purple
    end
    pts = Point2f(MapTiles.project((lon, lat), MapTiles.wgs84, MapTiles.web_mercator))

    scatter!(m.axis, pts; color=color, markersize=10, alpha=0.7)
end

m
