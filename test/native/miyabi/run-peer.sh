#!/bin/bash
set -eo pipefail
role=${1:?}
cd "${PBS_O_WORKDIR:?}"
exec > "peer-$role.log" 2>&1
trap 'rc=$?; printf "shell_exit_code=%s\n" "$rc"; printf "%s\n" "$rc" > "exit-$role.txt"' EXIT
date -Is
hostname
module purge
if [[ "$role" == g ]]; then
  module load nvidia/24.9 nv-hpcx/24.9 julia/1.12.6
  export WAITIO_PBID=1
else
  module load intel/2023.2.0 impi/2021.10.0
  : "${WAITIO_JULIA_C_BIN:?Set WAITIO_JULIA_C_BIN to the Julia 1.12.6 x86_64 bin directory}"
  [[ -x "$WAITIO_JULIA_C_BIN/julia" ]] || { echo "Julia executable not found: $WAITIO_JULIA_C_BIN/julia" >&2; exit 1; }
  export PATH="$WAITIO_JULIA_C_BIN:$PATH"
  export WAITIO_PBID=0
fi
julia --startup-file=no -e 'VERSION == v"1.12.6" || error("The object test requires Julia 1.12.6 on both systems")'
export WAITIO_DIR=/work/share/waitio-rt/opt/waitio
export WAITIO_LIB="$WAITIO_DIR/lib" WAITIO_INC="$WAITIO_DIR/include"
export LD_LIBRARY_PATH="$WAITIO_LIB:/usr/ofed/lib:${LD_LIBRARY_PATH:-}"
export PATH="$WAITIO_DIR/bin:$PATH"
export JULIA_DEPOT_PATH="$PWD/depot-$role:$PWD/depot-shared:"
export JULIA_LOAD_PATH='@:@stdlib'
export JULIA_PKG_OFFLINE=true JULIA_NUM_THREADS=1 OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1
export CC=/no-c-compiler CXX=/no-cxx-compiler MPICC=/no-mpi-compiler
export WAITIO_NPB=2 WAITIO_COMM_TYPE=socket WAITIO_HOST_POSTFIX=-ib
package="$PWD/source"
[[ -f "$package/Manifest.toml" ]] || { echo "Instantiate the shared project before submitting jobs" >&2; exit 1; }
[[ ! -e "config-$role.toml" ]] || { echo "Use a fresh run directory" >&2; exit 1; }
# Both architectures use this exact project; only configuration and depot differ.
sha256sum "$package/Project.toml" "$package/Manifest.toml" > "project-before-$role.sha256"
julia --startup-file=no --project="$package" configure.jl "$role"
export WAITIO_JL_CONFIG="$PWD/config-$role.toml"
# Publishing readiness after configure.jl prevents a fast job from reading a
# missing or partially written capabilities file from the other architecture.
printf '%s\n' "$(hostname)" > "ready-$role.tmp"
mv "ready-$role.tmp" "ready-$role"
bash "$package/test/native/miyabi/wait-peer.sh" "$role" "${WAITIO_PEER_TIMEOUT:-600}"
julia --startup-file=no --project="$package" "$package/test/native/miyabi/shared-config.jl" "$role"
WAITIO_MASTER_HOST=$(cat ready-c)
export WAITIO_MASTER_HOST
export WAITIO_MASTER_PORT=20770
if [[ "$role" == g ]]; then
  timeout --kill-after=10s 360s mpirun -np 1 julia --startup-file=no --project="$package" highlevel.jl > "highlevel-$role.log" 2>&1
else
  timeout --kill-after=10s 360s mpiexec.hydra -np 1 julia --startup-file=no --project="$package" highlevel.jl > "highlevel-$role.log" 2>&1
fi
export WAITIO_MASTER_PORT=20870
if [[ "$role" == g ]]; then
  timeout --kill-after=10s 360s mpirun -np 1 julia --startup-file=no --project="$package" "$package/test/native/miyabi/objects.jl" > "objects-$role.log" 2>&1
else
  timeout --kill-after=10s 360s mpiexec.hydra -np 1 julia --startup-file=no --project="$package" "$package/test/native/miyabi/objects.jl" > "objects-$role.log" 2>&1
fi
export WAITIO_MASTER_PORT=20970
if [[ "$role" == g ]]; then
  timeout --kill-after=10s 360s mpirun -np 1 julia --startup-file=no --project="$package" "$package/test/native/miyabi/collectives.jl" > "collectives-$role.log" 2>&1
else
  timeout --kill-after=10s 360s mpiexec.hydra -np 1 julia --startup-file=no --project="$package" "$package/test/native/miyabi/collectives.jl" > "collectives-$role.log" 2>&1
fi
printf 'job_completed=yes\n'
sha256sum --check "project-before-$role.sha256"
date -Is
