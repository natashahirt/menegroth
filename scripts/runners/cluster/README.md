# Flat-plate study on ORCD Engaging

Slurm array runners for the flat-plate method comparison. Each array element runs one task from `experiments.jl` and writes its own files, so tasks can fail, be preempted or be resubmitted independently.

## Experiments

| Name | What one task runs | Tasks |
| --- | --- | --- |
| `smoke` | 20 ft heatmap cell and 16 ft 3-story building, ACI Min and DDM | 2 |
| `r1_heatmap` | one bay × live load × regime; 9 methods × flat plate and flat slab; 3-story building, middle floor | 656 |
| `e7_punching` | one square bay × live load × punching variant (columns only, studs only, studs then thickness, thickness only); core methods | 160 |
| `e5_sensitivity` | one base case × one changed assumption (cap, deflection limit, studs, continuous columns, FEA post-processing) | 12 |
| `r3_building` | one span × stories × concrete × regime; whole-building carbon cascade | 54 |

The grids are at the top of `experiments.jl`. Changing a grid needs a new `RUN_TAG`, because array indices map to positions in the task list.

## First time

```bash
git clone --recurse-submodules <repo> ~/menegroth    # or set REPO
salloc -p mit_normal -c 4 --mem=16G -t 2:00:00
bash ~/menegroth/scripts/runners/cluster/setup_engaging.sh
exit
```

Rerun the setup after any `git pull` that changes package code, so the compile caches match.

## Running

```bash
cd ~/menegroth
bash scripts/runners/cluster/submit.sh --list          # task counts
bash scripts/runners/cluster/submit.sh smoke test1     # check the setup first
bash scripts/runners/cluster/submit.sh r1_heatmap run1
bash scripts/runners/cluster/submit.sh r3_building run1
```

- Results go to `$RESULTS_ROOT/<RUN_TAG>/<experiment>/`. Each task writes four files: `<id>.csv` (one row per design), `<id>_columns.csv`, `<id>_slabs.csv`, and `<id>_failures.csv` if any designs failed.
- The tables join on `run_id`. Each task also writes `<id>.task.json` (Slurm ids, host, load and wall time) and the git provenance in `<id>.csv.meta.json`.
- Tasks checkpoint one method at a time (`parts/`). A task stopped by the 12 h limit, preemption or a node failure resumes at its next unfinished method.
- A follow-up job runs after the arrays end. It merges results into `<RUN_TAG>/<experiment>.csv` (and the matching `_columns`, `_slabs` and `_failures` files) and writes `<experiment>_missing.tsv`. If any tasks are unfinished, it submits a new `mit_normal` array for just those, plus another follow-up, for up to `MAX_ROUNDS` rounds (default 5). This needs `sbatch` to work from compute nodes.
- Tasks that raised an exception get `<id>.error` and are not retried automatically, because rerunning won't fix them. After fixing the cause, run `ONLY_MISSING=1 INCLUDE_ERRORED=1 bash scripts/runners/cluster/submit.sh <experiment> <RUN_TAG>`.
- Logs: `logs/slurm/`. A failed task also leaves `<id>.error` with the stack trace.

Defaults in `env.sh`: `mit_normal`, 12 h, 8 GB, 1 core, at most 96 tasks at once (the partition's per-user core limit). Override them in the environment.

## Before a real run

- Commit and push the code the cluster runs. `submit.sh` warns if the tree is dirty, and every result records `git_sha` and `git_dirty`.
- Without a Gurobi license on the nodes, column sizing falls back to HiGHS. `<id>.task.json` records the `GRB_LICENSE_FILE` setting each task saw.
- Check `scontrol show config | grep MaxArraySize`. `submit.sh` splits experiments into arrays of `MAX_ARRAY` tasks (default 1000).
