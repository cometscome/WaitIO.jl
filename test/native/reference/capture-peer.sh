#!/bin/sh
# Redirect inside the MPI process: Fujitsu MPI may otherwise route stdout only
# to the scheduler output, bypassing the launcher's stdout redirection.
: "${WAITIO_REFERENCE_PEER_OUTPUT:?Missing per-process output path}"
exec "$@" > "$WAITIO_REFERENCE_PEER_OUTPUT" 2>&1
