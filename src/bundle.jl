struct Bundle{I,J}
    orders::Vector{Order{I}}
    origin::NetworkNode{J}
    destination::NetworkNode{J}
end
