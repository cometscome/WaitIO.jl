# Check every wrapper against the independently recorded header contract using
# Julia callbacks. This checks widths, order, values, and returns, not native ABI
# conformance to a newly installed C library (that requires a native site test).
using TOML
const CONTRACT=TOML.parsefile(joinpath(@__DIR__,"contract.toml"))["function"]
contract_type(t)=occursin('*',t) || t in ("waitio_group_t","WAITIO_MPI_Comm") ? Ptr{Cvoid} :
    t=="void" ? Cvoid : t=="size_t" ? Csize_t : t=="waitio_tag_t" ? Culong : t=="unsigned int" ? Cuint : Cint
const observed=Ref{Any}(nothing)
const result_pointer=Ptr{Cvoid}(UInt(0x1234))
for (id,f) in enumerate(CONTRACT)
    name=Symbol("contract_",f["name"])
    result=contract_type(f["result"]); types=contract_type.(f["arguments"])
    args=[Symbol(:a,i) for i in eachindex(types)]
    typed=[:($(args[i])::$(types[i])) for i in eachindex(types)]
    answer=result==Cvoid ? :(nothing) : result<:Ptr ? :(result_pointer) : :(Cint($(-1000-id)))
    @eval function $name($(typed...))
        observed[]=($(args...),)
        $answer
    end
    @eval contract_pointer(::Val{$(QuoteNode(Symbol(f["name"])))})=@cfunction($name,$result,$(Expr(:tuple,types...)))
end
@testset "80 native API wrappers via Julia callbacks" begin
    @test Set(Symbol(f["name"]) for f in CONTRACT)==Set(keys(W.API.SIGNATURES))
    saved=W._library[]
    try
        pointers=Dict(Symbol(f["name"])=>contract_pointer(Val(Symbol(f["name"]))) for f in CONTRACT)
        W._library[]=W.LibraryState(W.LibraryConfig(),C_NULL,C_NULL,pointers,Dict(),Dict())
        for (id,f) in enumerate(CONTRACT)
            @testset "$(f["name"])" begin
                storage=[zeros(UInt8,32) for _ in f["arguments"]]
                args=map(enumerate(f["arguments"])) do (i,t)
                    T=contract_type(t)
                    T<:Ptr ? Ptr{Cvoid}(pointer(storage[i])) : T==Cint ? Cint(-101-17i) : typemax(T)-T(i)
                end
                observed[]=nothing
                actual=GC.@preserve storage getfield(W.API,Symbol(f["name"]))(args...)
                expected=f["result"]=="int" ? Cint(-1000-id) : f["result"]=="void" ? nothing : result_pointer
                @test actual===expected
                @test observed[]===Tuple(args)
            end
        end
    finally
        W._library[]=saved
    end
end
