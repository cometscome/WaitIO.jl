#!/usr/bin/env bash
set -euo pipefail
# Use the site's MPI C compiler after loading its MPI and WaitIO modules.
: "${WAITIO_INC:?Installed WaitIO include directory}"
: "${REFERENCE_LIBWAITIO:?Absolute path of the installed core library}"
: "${REFERENCE_LIBWAITIO_MPI:?Absolute path of the installed collective library}"
compiler=${MPICC:-mpicc}
"$compiler" -std=gnu99 -O0 -g -Wall -Wextra -I"$WAITIO_INC" \
  "$(dirname "$0")/reference.c" -Wl,--no-as-needed \
  "$REFERENCE_LIBWAITIO_MPI" "$REFERENCE_LIBWAITIO" \
  -Wl,-rpath,"$(dirname "$REFERENCE_LIBWAITIO")" -ldl -o "${1:?Output executable path}"
