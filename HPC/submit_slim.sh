#!/bin/bash
#SBATCH --job-name=MIDAS_slim
#SBATCH -p compute
#SBATCH --array=1-8%8
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=64G
#SBATCH --time=12:00:00
#SBATCH --output=logs/midas_slim_%A_%a.out
#SBATCH --error=logs/midas_slim_%A_%a.err
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=f.heslop@uea.ac.uk

# ============================================================
# MIDAS Madagascar -- strip never-read per-agent histories from projection
# output files (see slimRunOutputs.m for what is dropped and why).
#
# WHY BATCH AND NOT AN INTERACTIVE LOGIN NODE
#   - a 7 GB -v7.3 file expands well beyond 7 GB in RAM, and login nodes are
#     shared and memory-capped; the job would be killed, or would degrade the
#     node for everyone else
#   - ~200 files per scenario at minutes each is many hours of held connection
#   - every file is independent, so the work shards perfectly across an array
#
# RESOURCES. cpus-per-task=2 because this is I/O and single-threaded save/load,
# not compute -- requesting 20 cores would queue longer for no gain. 64G is a
# guess at the in-RAM expansion of a 7 GB HDF5 file; run inspectRunSize.m on
# ONE file first and raise this if the reported total exceeds ~40 GB.
#
# --array=1-8%8 rather than more, because 8 concurrent tasks each streaming
# 7 GB in and writing back out is already substantial filesystem load. More
# shards would finish sooner in principle and slower in practice.
#
# USAGE -- three passes, in this order. Do not skip to the third.
#
# 1. DRY RUN. Reports the reduction per file, writes nothing.
#      sbatch --export=ALL,SLIM_DIR=Outputs_SSP2 submit_slim.sh
#
# 2. WRITE, KEEPING ORIGINALS. Produces *_slim.mat alongside. Open one in
#    Julia and confirm matread returns the fields the analysis scripts use
#    before going any further.
#      sbatch --export=ALL,SLIM_DIR=Outputs_SSP2,SLIM_APPLY=1 submit_slim.sh
#
# 3. WRITE AND DELETE. Only after step 2 has been verified in Julia AND the
#    agent-level exemplars have been copied off and checksummed.
#      sbatch --export=ALL,SLIM_DIR=Outputs_SSP2,SLIM_APPLY=1,SLIM_DELETE=1,SLIM_KEEP_INTACT=0 \
#             submit_slim.sh
#
# SLIM_KEEP_INTACT defaults to 2 and leaves the first N files untouched as
# agent-level exemplars. Set it to 0 only once verified copies exist elsewhere.
# Note that the first N files in directory order are all from task 1, i.e. a
# handful of parameter draws sharing one RNG lineage -- if you want exemplars
# that span the design, copy them off by name instead:
#     ls Outputs_SSP2/MC_Run_T*_D001_R1_*.mat | sed -n '1~2p' | head -10
#
# The deletion is irreversible and agentSummary is the only per-agent record
# in the output; aggregates cannot be disaggregated back to individuals.
# ============================================================

set -euo pipefail

ARRAY_JOB_ID="${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID}"
TASK_ID="${SLURM_ARRAY_TASK_ID:-0}"
echo "Job ${ARRAY_JOB_ID}, task ${TASK_ID} started at $(date)"
echo "Running on node: $(hostname)"

: "${SLIM_DIR:?SLIM_DIR not set -- pass --export=ALL,SLIM_DIR=Outputs_SSP2}"
export SLIM_DIR
export SLIM_APPLY="${SLIM_APPLY:-0}"
export SLIM_DELETE="${SLIM_DELETE:-0}"
export SLIM_KEEP_INTACT="${SLIM_KEEP_INTACT:-2}"

echo "Directory:     ${SLIM_DIR}"
echo "Apply:         ${SLIM_APPLY}"
echo "Delete:        ${SLIM_DELETE}"
echo "Keep intact:   ${SLIM_KEEP_INTACT}"

module load matlab/2024b

cd "$SLURM_SUBMIT_DIR/../MIDAS"
echo "Working directory: $(pwd)"

for f in run_slim.m slimRunOutputs.m; do
    [[ -f "$f" ]] || { echo "MISSING: $f" >&2; exit 1; }
done
[[ -d "$SLIM_DIR" ]] || { echo "MISSING directory: $SLIM_DIR" >&2; exit 1; }

matlab -batch "run_slim"

echo "Task ${TASK_ID} finished at $(date)"
