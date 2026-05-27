#!/bin/bash
#SBATCH --job-name=MIDAS_calib
#SBATCH -p compute
#SBATCH --array=1-200%40
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=20
#SBATCH --mem=100G
#SBATCH --time=18:00:00
#SBATCH --output=logs/midas_calib_%A_%a.out
#SBATCH --error=logs/midas_calib_%A_%a.err
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=f.heslop@uea.ac.uk

# ============================================================
# MIDAS Madagascar - Calibration MC Run (SLURM array)
# UEA Hali HPC  |  Each array task: 1 node, 20 parallel workers
#
# MULTI-REALISATION campaign sizing (must stay consistent with
# run_calibration.m's numTotalDraws and nRealisations):
#   numTotalDraws = 1000, nRealisations = 3  ->  3000 total runs
#   Split as 200 array tasks x (5 draws x 3 realisations) = 15 iterations/task.
#
# The 15 iterations per task run in parallel on the 20 workers (one wave),
# so each task stays within the wall-clock. KEEP
#   (numTotalDraws / nTasks) * nRealisations  <=  cpus-per-task (20)
# when resizing, or the parfor will queue iterations and risk a timeout.
#
# %40 caps simultaneous running tasks at 40. With ~8 h per task and 40
# concurrent, 200 tasks complete in ceil(200/40)=5 waves ~= 40 h -- well
# within a 3-day window. Lower the %N if your fair-share allowance is
# smaller; raise it if you have headroom and want it finished sooner.
#
# To resize the campaign:
#   - Set numTotalDraws and nRealisations in run_calibration.m
#   - Set --array=1-N%K here so N = numTotalDraws / drawsPerTask
#   - Re-check the wall-clock constraint above
#
# Usage:
#   cd /gpfs/home/<username>/Desktop/Madagascar_migration/Scripts
#   mkdir -p ../MIDAS/logs ../MIDAS/Outputs
#   sbatch submit_calibration_batch.sh
#
# Mail-type set to END,FAIL only -- BEGIN would email once per task.
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

# Sanity che