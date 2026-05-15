#!/bin/bash
#SBATCH --job-name=MIDAS_calib
#SBATCH -p compute
#SBATCH --array=1-50%20
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=20
#SBATCH --mem=100G
#SBATCH --time=12:00:00
#SBATCH --output=logs/midas_calib_%A_%a.out
#SBATCH --error=logs/midas_calib_%A_%a.err
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=f.heslop@uea.ac.uk

# ============================================================
# MIDAS Madagascar - Calibration MC Run (SLURM array)
# UEA Hali HPC  |  Each array task: 1 node, 20 parallel workers
#
# Default sized for 1000 total runs as 50 array tasks x 20 runs each.
# %20 in --array caps simultaneous running tasks at 20 (cluster-friendly;
# adjust if you have a different fair-share allowance).
#
# To resize the campaign:
#   - Change the array bound (e.g. --array=1-100%20 for 100 tasks)
#   - Edit numTotalRuns in run_calibration.m to match the new target
#
# Usage:
#   cd /gpfs/home/<username>/Desktop/Madagascar_migration/Scripts
#   mkdir -p ../MIDAS/logs ../MIDAS/Outputs
#   sbatch submit_calibration.sh
#
# Mail-type set to END,FAIL only -- BEGIN would email 50 times per submit.
# ============================================================

set -euo pipefail

ARRAY_JOB_ID="${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID}"
TASK_ID="${SLURM_ARRAY_TASK_ID:-0}"
echo "Job ${ARRAY_JOB_ID}, task ${TASK_ID} started at $(date)"
echo "Running on node: $(hostname)"
echo "CPUs allocated: $SLURM_CPUS_PER_TASK"

# Load MATLAB module
module load matlab/2024b

# Run from the MIDAS project root (sibling of Scripts/)
cd "$SLURM_SUBMIT_DIR/../MIDAS"
echo "Working directory: $(pwd)"

# Sanity checks before launching MATLAB
if [ ! -f "runMIDASExperiment_parallel.m" ]; then
    echo "ERROR: runMIDASExperiment_parallel.m not found in $(pwd)"
    exit 1
fi
mkdir -p logs Outputs

# Launch MATLAB via -batch with a single-token script name.
# The body lives in run_calibration.m at the MIDAS project root.
# (Previously this was a multi-line inline -batch '...' block, which the
# Hali MATLAB module wrapper was silently stripping — see job 2576195.
# Single-token argument avoids that.)
if [ ! -f "run_calibration.m" ]; then
    echo "ERROR: run_calibration.m not found in $(pwd)"
    exit 1
fi

matlab -nodisplay -nosplash -batch "run_calibration"

echo "Job ${ARRAY_JOB_ID}, task ${TASK_ID} finished at $(date)"
