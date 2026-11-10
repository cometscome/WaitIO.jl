struct WaitIOError <: Exception
    operation::Symbol
    code::Int
    context::String
end
Base.showerror(io::IO, e::WaitIOError) = print(io, e.operation, " returned ", e.code,
    isempty(e.context) ? "" : ": " * e.context)

struct UnsupportedFeatureError <: Exception
    feature::Symbol
end
Base.showerror(io::IO, e::UnsupportedFeatureError) = print(io, "loaded WaitIO library does not provide ", e.feature)

struct PendingRequestsError <: Exception
    count::Int
end
Base.showerror(io::IO, e::PendingRequestsError) = print(io,
    e.count, " requests still own native storage; complete them before Finalize")

function _check(operation::Symbol, code::Integer; context="")
    code == 0 || throw(WaitIOError(operation, Int(code), context))
    nothing
end

function _cint(x::Integer)
    typemin(Cint) <= x <= typemax(Cint) || throw(ArgumentError("value does not fit C int: $x"))
    Cint(x)
end
function _count(x::Integer)
    x >= 0 || throw(ArgumentError("count must be nonnegative"))
    _cint(x)
end
