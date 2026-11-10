# Included by the four-process worker after initialization. These expectations
# are calculated from integer values, independently of native CHAR signedness.
@testset "portable byte reductions rank=$rank" begin
    fixtures=(UInt8[0 255 200; 127 128 100; 128 127 250; 255 0 255],
              Int8[-128 127 -56; -1 0 100; 0 -1 -6; 127 -128 -1])
    for values in fixtures
        T=eltype(values)
        for (op,combine) in ((W.SUM,+),(W.MIN,min),(W.MAX,max))
            answer(rows) = T[reduce(combine,Int64.(values[rows,col])) % T for col in axes(values,2)]
            # Nonzero offsets ensure widening does not accidentally reduce or
            # overwrite storage outside the caller's selected region.
            source=vcat(T[7],values[rank+1,:],T[9]); original=copy(source)
            destination=fill(T(11),5)
            s=W.Buffer(source;offset=1,count=3)
            r=W.Buffer(destination;offset=1,count=3)
            @test W.Extensions.Allreduce!(s,r,op,g)===r
            @test destination==vcat(T[11],answer(1:4),T[11])
            for root in 0:3
                fill!(destination,11)
                @test W.Extensions.Reduce!(s,r,op,g;root)===r
                @test destination==(rank==root ? vcat(T[11],answer(1:4),T[11]) : fill(T(11),5))
                # Exercise the optional non-root receive buffer as well.
                target=rank==root ? r : nothing
                @test W.Extensions.Reduce!(s,target,op,g;root)===target
                rank==root && (@test destination[2:4]==answer(1:4))
            end
            fill!(destination,11)
            W.Extensions.Scan!(s,r,op,g)
            @test destination==vcat(T[11],answer(1:rank+1),T[11])
            fill!(destination,11)
            W.Extensions.Exscan!(s,r,op,g)
            @test destination==(rank==0 ? fill(T(11),5) : vcat(T[11],answer(1:rank),T[11]))
            @test source==original
            for f in (W.Extensions.Allreduce!,W.Extensions.Scan!,W.Extensions.Exscan!)
                empty=T[]; @test f(T[],empty,op,g)===empty
            end
            empty=T[]; @test W.Extensions.Reduce!(T[],empty,op,g;root=3)===empty
        end
    end
end
