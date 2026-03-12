#!/usr/bin/env bash
# Optional entrypoint: write Gurobi license from env to file, then run the main process.
# Set GRB_LICENSE_CONTENTS (e.g. from AWS Secrets Manager) to provide a license at runtime
# without baking it into the image. If unset, this script does nothing and execs the CMD.

set -e
if [ -n "${GRB_LICENSE_CONTENTS}" ]; then
  mkdir -p /opt/gurobi
  echo "${GRB_LICENSE_CONTENTS}" > /opt/gurobi/gurobi.lic
  export GRB_LICENSE_FILE=/opt/gurobi/gurobi.lic
fi
exec "$@"
