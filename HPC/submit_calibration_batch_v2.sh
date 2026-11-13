#!/bin/bash
#SBATCH --job-name=MIDAS_calib
#SBATCH -p ht
#SBATCH --qos=ht
#SBATCH --array=1-25%25
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=20
#SBATCH --mem=80G
#SBATCH --time=48:00:00
#SBATCH --output=logs/midas_calib_%A_%a.out
#SBATCH --error=logs/midas_calib_%A_%a.err
#SBATCH --mail-type=START,END,FAIL
#SBATCH --mail-user=f.heslop@uea.ac.uk

# ============================================================
# MIDAS Madagascar -- CALIBRATION MC campaign, ht partition
#
# SUBMIT FROM Scripts/, the sibling of MIDAS/:
#   cd /gpfs/home/<username>/Desktop/Madagascar_migration/Scripts
#   mkdir -p logs ../MIDAS/logs ../MIDAS/Outputs
#   sbatch --export=ALL,MIDAS_SSP=SSP2,LOCAL_DEMAND_COUPLING=0.25,\
# DROUGHT_VARIABILITY=1,DISTRESS_ARM=6 submit_calibration_batch_v2.sh
#
# NUM_DRAWS defaults to 500 in this script, matching --array=1-25. Override it
# only together with the array size (see sizing below).
#
# SLURM resolves --output relative to where sbatch is INVOKED (Scripts/), not
# where this script later cd's to. It will not create the directory, and a
# missing one fails the task with no message, because the error log cannot be
# written either. Create both.
#
# ---------------------------------------------------------- sizing
# run_calibration.m computes drawsPerTask = ceil(NUM_DRAWS / array size) and
# runs drawsPerTask * N_REALISATIONS parfor iterations per task.
#
# KEEP  drawsPerTask * N_REALISATIONS <= cpus-per-task (20)  or the parfor
# queues a second wave and the task risks the 48 h wall clock.
#
#   NUM_DRAWS=500,  --array=1-25  -> 20 draws/task x 1 = 20 iterations. OK.  <- default
#   NUM_DRAWS=1000, --array=1-25  -> 40 draws/task x 1 = 40 -> TWO waves.
#   NUM_DRAWS=1000, --array=1-50  -> 20 draws/task x 1 = 20 iterations. OK.
#
# N_REALISATIONS=2 averages seed noise before buildNextRound scores a parameter
# set. Worth having if the scatter looks noisy, at twice the node-hours; halve
# the draws per task to stay within 20 iterations.
#
# MEMORY: a calibration run to 2025 is ~1.8 GB (a projection to 2085 is ~12 GB,
# which is why that campaign uses a different script and the compute
# partition). 20 concurrent iterations ~ 36 GB, comfortably inside 80 G.
# AGENT_TRACE must stay 0 -- it was 99.96% of every Set 21 output file and
# nothing in the calibration reads it.
#
# ---------------------------------------------------------- bounds
# This script does NOT set PREFLIGHT_BOUNDS=strict, deliberately.
#
# The preflight bounds checks assert the declared values (subsistence
# [2.0, 2.6] and the rest) because a PROJECTION campaign must not drift off
# them. A calibration campaign exists to widen the priors and re-identify, so
# asserting them would make this script unsubmittable. The values are still
# PRINTED into the log, so the campaign records what it sampled -- they are
# just not a failure condition here.
# ============================================================

set -euo pipefail

ARRAY_JOB_ID="${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID}"
TASK_ID="${SLURM_ARRAY_TASK_ID:-0}"
echo "Job ${ARRAY_JOB_ID}, task ${TASK_ID} started at $(date)"
echo "Running on node: $(hostname)"
echo "CPUs allocated: ${SLURM_CPUS_PER_TASK}"

# ---------------------------------------------------------- configuration
# Calibration runs the historical period. endYear is NOT set: readParameters
# defaults to 2025. Setting MIDAS_END_YEAR would make this a projection run.
export MIDAS_SSP="${MIDAS_SSP:-SSP2}"
export LOCAL_DEMAND_COUPLING="${LOCAL_DEMAND_COUPLING:-0.25}"
export DROUGHT_VARIABILITY="${DROUGHT_VARIABILITY:-1}"
export DISTRESS_ARM="${DISTRESS_ARM:-6}"
export AGENT_TRACE="${AGENT_TRACE:-0}"
# 500 draws is the DEFAULT here, not run_calibration.m's 1000, because it is
# the value that matches --array=1-25: 500/25 = 20 draws/task x 1 realisation =
# 20 parfor iterations, exactly the 20 workers, one wave. Falling back to 1000
# would give 40 iterations per task and queue a second wave, which is a
# wall-clock risk that would only show up after hours of running. If you raise
# the array to 1-50, NUM_DRAWS=1000 is the matching value.
export NUM_DRAWS="${NUM_DRAWS:-500}"
if [[ -n "${N_REALISATIONS:-}" ]];  then export N_REALISATIONS;  fi
if [[ -n "${EXPECTATION_ARM:-}" ]]; then export EXPECTATION_ARM; fi

echo "Scenario:            ${MIDAS_SSP}"
echo "End year:            <readParameters default, 2025 = calibration>"
echo "Demand coupling:     ${LOCAL_DEMAND_COUPLING}"
echo "Drought variability: ${DROUGHT_VARIABILITY}"
echo "Distress arm:        ${DISTRESS_ARM}"
echo "Agent trace:         ${AGENT_TRACE}"
echo "Expectation arm:     ${EXPECTATION_ARM:-<readParameters default>}"
echo "Draws:               ${NUM_DRAWS:-<run_calibration default>}"
echo "Realisations:        ${N_REALISATIONS:-<run_calibration default>}"

module load matlab/2024b

cd "$SLURM_SUBMIT_DIR/../MIDAS"
echo "Working directory: $(pwd)"

# Pre-flight is NOT run here. Run it yourself before submitting:
#     cd <MIDAS project root> && bash HPC/preflight.sh
# It was gated in-job briefly and blocked submission, which is the wrong
# trade: a check that stops you working costs more than the failure mode
# it guards against.

for f in run_calibration.m runMIDASExperiment_parallel.m \
         Application_Specific_MIDAS_Code/readParameters.m; do
    [[ -f "$f" ]] || { echo "ERROR: $f not found in $(pwd)" >&2; exit 1; }
done
if [[ ! -f "Calibration Testing/updatedMCParams.mat" && ! -f "updatedMCParams.mat" ]]; then
    echo "WARNING: no updatedMCParams.mat -- the run will use FRESH WIDE priors," >&2
    echo "         not your calibrated bounds. Check this is intended." >&2
fi
mkdir -p logs Outputs

# -batch runs headless, returns non-zero on error and needs no explicit exit,
# so a MATLAB failure fails the SLURM task rather than reporting success.
matlab -nodisplay -nosplash -batch "run_calibration"

echo "Job ${ARRAY_JOB_ID}, task ${TASK_ID} finished at $(date)"

# NO TRAILING 'EOF'. The previous version ended with a bare EOF left over from
# a heredoc; under `set -e` bash tried to execute it, failed with "command not
# found", and the task exited 127 -- so every task reported FAILED even after
# MATLAB had completed normally.
