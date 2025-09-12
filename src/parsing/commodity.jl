"""
$TYPEDEF

Commodity data structure that should be instantiated by the user's parser.
This then will be used internally to instantiate an instance with more optimized data structures.

# Fields
$TYPEDFIELDS
"""
@kwdef struct FullCommodity{I}
    origin_id::I
    destination_id::I
    size::Float64
    delivery_time_step::Int
    max_delivery_time::Int
end
