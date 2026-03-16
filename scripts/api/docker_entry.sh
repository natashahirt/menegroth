#!/usr/bin/env bash
# Optional entrypoint: write Gurobi license from env to file, then run the main process.
# Set GRB_LICENSE_CONTENTS (e.g. from AWS Secrets Manager) to provide a license at runtime
# without baking it into the image. If unset, this script does nothing and execs the CMD.
# JULIA_DEPOT_PATH must match the build (so runtime reuses precompiled cache).
export JULIA_DEPOT_PATH="${JULIA_DEPOT_PATH:-/app/.julia}"
export JULIA_CPU_TARGET="${JULIA_CPU_TARGET:-generic}"
export JULIA_PKG_PRECOMPILE_AUTO="${JULIA_PKG_PRECOMPILE_AUTO:-0}"
# Use all available cores for threading (MIP feasibility, NLP, foundations, slabs, Asap).
export JULIA_NUM_THREADS="${JULIA_NUM_THREADS:-auto}"

set -e
if [ -n "${GRB_LICENSE_CONTENTS}" ]; then
  mkdir -p /opt/gurobi
  echo "${GRB_LICENSE_CONTENTS}" > /opt/gurobi/gurobi.lic
  export GRB_LICENSE_FILE=/opt/gurobi/gurobi.lic
fi
exec "$@"
