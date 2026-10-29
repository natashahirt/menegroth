# Shared settings for the ORCD Engaging runners. Sourced by setup, submit and
# the array job, so every step sees the same Julia, depot and results folder.
# Override any of these in the environment before calling the scripts.

export REPO="${REPO:-$HOME/menegroth}"
export JULIA_VERSION="${JULIA_VERSION:-1.12.4}"
# Packages and compile caches. The pool (1 TiB, not backed up) keeps them off
# the home quota; it must be the same path at setup and run time.
export JULIA_DEPOT_PATH="${JULIA_DEPOT_PATH:-$HOME/orcd/pool/julia_depot}"
export RESULTS_ROOT="${RESULTS_ROOT:-$HOME/orcd/pool/menegroth_results}"
export PATH="$HOME/.juliaup/bin:$PATH"

# Headless, single-threaded workers: one array task per core.
export SS_ENABLE_VISUALIZATION=false
export SS_ENABLE_HEAVY_PRECOMPILE_WORKLOAD=false
export JULIA_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export JULIA_PKG_PRECOMPILE_AUTO=0

# Slurm defaults. mit_normal: CPU only, 12 h limit, 96-core base limit per
# user. mit_preemptable: 48 h, may be preempted (tasks are resumable).
export PARTITION="${PARTITION:-mit_normal}"
export TIME_LIMIT="${TIME_LIMIT:-12:00:00}"
export MEM="${MEM:-8G}"
export MAX_CONCURRENT="${MAX_CONCURRENT:-96}"
# Largest array a single sbatch may carry; check `scontrol show config | grep MaxArraySize`.
export MAX_ARRAY="${MAX_ARRAY:-1000}"
# Automatic resubmission rounds for unfinished tasks (followup.sh). Each round
# can give a task another TIME_LIMIT, resuming at its next unfinished method.
export MAX_ROUNDS="${MAX_ROUNDS:-5}"
