module TestMessages
export TrainingBatch
struct TrainingBatch{T}
    label::String
    coordinates::Matrix{T}
    metadata::Dict{Symbol,Any}
end
end
