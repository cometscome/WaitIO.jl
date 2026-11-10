#!/bin/bash
set -euo pipefail
role=${1:?Usage: run-oa.sh o|a}
trap 'rc=$?; printf "%s\n" "$rc" > "exit-$role.txt"' EXIT
exec > "launcher-$role.log" 2>&1
date -Is
hostname
module purge
if [[ "$role" == o ]]; then
    module load fj/1.2.43 fjmpi/1.2.43 waitio/1.0
    rank=0; peer=1; peer_role=a; variant=a64fx
    julia_bin="$PWD/julia-1.12.6/bin/julia"
else
    [[ "$role" == a ]]
    module load intel/2023.0.0 impi/2021.8.0 waitio/1.0
    rank=1; peer=0; peer_role=o; variant=intel
    : "${WAITIO_JULIA_A_BIN:?Set the Aquarius Julia 1.12.6 bin directory}"
    julia_bin="$WAITIO_JULIA_A_BIN/julia"
fi
export WAITIO_LIB=/work/share/waitio-rt/opt/waitio/lib
export WAITIO_INC=/work/share/waitio-rt/opt/waitio/include
export LD_LIBRARY_PATH="$WAITIO_LIB:/usr/ofed/lib:${LD_LIBRARY_PATH:-}"
export JULIA_LOAD_PATH='@:@stdlib'
export JULIA_DEPOT_PATH="$PWD/depot-$role:$PWD/depot-shared:"
export JULIA_NUM_THREADS=1 OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 JULIA_PKG_OFFLINE=true
export JULIA_CPU_TARGET=generic
export CC=/no-c-compiler CXX=/no-cxx-compiler MPICC=/no-mpi-compiler
export WAITIO_NPB=2 WAITIO_COMM_TYPE=socket WAITIO_PBID=$rank
export WAITIO_MASTER_PORT=7480 COUPLER_JOB_ID=71 WAITIO_HOST_POSTFIX=-tofu1
unset WAITIO_JL_CONFIG WAITIO_JL_LIBWAITIO WAITIO_JL_LIBWAITIO_MPI WAITIO_JL_INCLUDE_DIR WAITIO_JL_ABI_PROFILE
project="$PWD/source"
[[ -f "$project/Manifest.toml" && ! -e "config-$rank.toml" ]]
sha256sum "$project/Project.toml" "$project/Manifest.toml" > "before-$role.sha256"
"$julia_bin" --startup-file=no --project="$project" -e '
    using WaitIO, Test
    @test VERSION==v"1.12.6"
    WaitIO.use_system_library(library_dir=ENV["WAITIO_LIB"],include_dir=ENV["WAITIO_INC"],
        variant=ARGS[1],config_file="config-$(ENV["WAITIO_PBID"]).toml")
    println("missing_symbols=", sort!([string(k) for (k,v) in WaitIO.capabilities() if !v]))
    @test WaitIO.check_library(require=[:core]).abi["known_library_pair"]
    @test !WaitIO.Initialized()
    println("setup_PASS rank=",ENV["WAITIO_PBID"])
' "$variant"
export WAITIO_JL_CONFIG="$PWD/config-$rank.toml"
hostname > "ready-$rank.tmp"
mv "ready-$rank.tmp" "ready-$rank"
deadline=$((SECONDS+300))
until [[ -s "ready-$peer" ]]; do
    [[ ! -f "exit-$peer_role.txt" ]] || { echo 'Peer exited before rendezvous' >&2; exit 1; }
    (( SECONDS < deadline )) || { echo 'Peer readiness timeout' >&2; exit 1; }
    sleep 1
done
"$julia_bin" --startup-file=no --project="$project" "$project/test/native/wisteria/config-oa.jl" "$rank"
export WAITIO_MASTER_HOST=$(cat ready-0)
export PATH="$WAITIO_DIR/bin:$PATH"
if [[ "$role" == o ]]; then
    timeout 30s waitio-serv-a64fx -m "$WAITIO_MASTER_HOST"
else
    discovered=$(timeout 60s waitio-serv-intel -c)
    [[ "$discovered" == "$WAITIO_MASTER_HOST" ]] || { echo 'Site service returned a different master' >&2; exit 1; }
fi
sha256sum "config-$rank.toml" >> "before-$role.sha256"
if [[ "$role" == o ]]; then
    timeout --kill-after=10s 300s mpiexec -n 1 "$julia_bin" --startup-file=no --project="$project" \
        "$project/test/native/wisteria/peer.jl" > "peer-$rank.log" 2>&1 &
    comm_pid=$!
    # Native clients may fail immediately if the slower master has not bound its socket.
    # Publish readiness only after the actual listening socket exists on this node.
    listen_port=$((WAITIO_MASTER_PORT + COUPLER_JOB_ID))
    deadline=$((SECONDS+240))
    until ss -lnt | awk '{print $4}' | grep -q ":$listen_port$"; do
        kill -0 "$comm_pid" 2>/dev/null || { wait "$comm_pid"; exit 1; }
        if (( SECONDS >= deadline )); then
            kill "$comm_pid" 2>/dev/null || true
            wait "$comm_pid" || true
            echo 'Master socket startup timeout' >&2
            exit 1
        fi
        sleep 1
    done
    printf '%s\n' "$listen_port" > listening.tmp
    mv listening.tmp listening
    wait "$comm_pid"
else
    deadline=$((SECONDS+300))
    until [[ -s listening ]]; do
        [[ ! -f exit-o.txt ]] || { echo 'Odyssey exited before listening' >&2; exit 1; }
        (( SECONDS < deadline )) || { echo 'Master readiness timeout' >&2; exit 1; }
        sleep 1
    done
    timeout --kill-after=10s 300s mpiexec.hydra -np 1 "$julia_bin" --startup-file=no --project="$project" \
        "$project/test/native/wisteria/peer.jl" > "peer-$rank.log" 2>&1
fi
sha256sum --check "before-$role.sha256"
printf 'job_completed=yes\n'
date -Is
