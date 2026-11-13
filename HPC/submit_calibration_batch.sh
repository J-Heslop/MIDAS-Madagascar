#!/bin/bash
#SBATCH --job-name=MIDAS_calib
#SBATCH -p compute
#SBATCH --array=1-50%25
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=20
#SBATCH --mem=100G
#SBATCH --time=24:00:00
#SBATCH --output=logs/midas_calib_%A_%a.out
#SBATCH --error=logs/midas_calib_%A_%a.err
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=f.heslop@uea.ac.uk

# ============================================================
# MIDAS Madagascar -- CALIBRATION MC campaign (SLURM array)
#
# REWRITTEN 2026-09-11. The previous version of this file was TRUNCATED at
# "# Sanity che" and never invoked MATLAB at all: it loaded the module, cd'd,
# echoed three lines and exited 0. Tasks reported success and produced no
# output. If you have a calibration set that looks empty, that is why -- check
# for MC*.mat before trusting any Set produced with the old script.
#
# SUBMIT FROM Scripts/, which is the sibling of MIDAS/:
#   cd /gpfs/home/<username>/Desktop/Madagascar_migration/Scripts
#   mkdir -p logs ../MIDAS/logs ../MIDAS/Outputs
#   sbatch --export=ALL,MIDAS_SSP=SSP2,LOCAL_DEMAND_COUPLING=0.25,\
# DROUGHT_VARIABILITY=1,DISTRESS_ARM=6 submit_calibration_batch.sh
#
# NOTE on the log directory: SLURM resolves --output relative to the directory
# sbatch is INVOKED from (Scripts/), not the one this script later cd's into.
# It will not create it, and a missing one fails the task silently because the
# error log cannot be written either. Create both.
#
# ---------------------------------------------------------- sizing
# run_calibration.m reads:
#   numTotalDraws   default 1000, overridden by NUM_DRAWS
#   nRealisations   default 1,    overridden by N_REALISATIONS
#   drawsPerTask  = ceil(numTotalDraws / SLURM_ARRAY_TASK_COUNT)
# and runs drawsPerTask * nRealisations parfor iterations per task.
#
# KEEP  drawsPerTask * nRealisations <= cpus-per-task (20)  or the parfor
# queues a second wave and the task risks the wall clock.
#
#   1000 draws / 50 tasks = 20 draws/task x 1 realisation = 20 iterations. OK.
#   To use 2 realisations, halve the draws per task: --array=1-100%25 with
#   N_REALISATIONS=2 gives 10 x 2 = 20. Multi-realisation averages seed noise
#   before buildNextRound scores a parameter set, which is worth having if the
#   scatter looks noisy -- at twice the node-hours.
#
# MEMORY: a calibration run to 2025 is ~1.8 GB (vs ~12 GB for a projection to
# 2085, which is why that campaign uses a different script). 20 concurrent
# iterations ~ 36 GB, so 100G has headroom. AGENT_TRACE must stay 0: it was
# 99.96% of every Set 21 output file and nothing in the calibration reads it.
#
# WALL CLOCK: 24 h. %25 caps concurrency at 25, so 50 tasks complete in two
# waves. Lower %N if your fair-share is tight.
# ============================================================

set -euo pipefail

ARRAY_JOB_ID="${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID}"
TASK_ID="${SLURM_ARRAY_TASK_ID:-0}"
echo "Job ${ARRAY_JOB_ID}, task ${TASK_ID} started at $(date)"
echo "Running on node: $(hostname)"
echo "CPUs allocated: ${SLURM_CPUS_PER_TASK}"

# ---------------------------------------------------------- configuration
# Scenario. Calibration runs the historical period, where the observed SPEI
# record drives the drought forcing, but the GRMA secular yield surface is
# still scenario-specific -- so the choice is recorded rather than defaulted
# silently. Unset falls back to readParameters' SSP5.
export MIDAS_SSP="${MIDAS_SSP:-SSP2}"

# endYear is NOT set here: readParameters defaults to 2025, the calibration
# horizon. Setting MIDAS_END_YEAR would make this a projection campaign.

# Non-farm income falls with the local agricultural deficit. Without it the
# non-farm layers act as a drought-immune absorber.
export LOCAL_DEMAND_COUPLING="${LOCAL_DEMAND_COUPLING:-0.25}"

# Projection-period drought variability. Irrelevant below 2023 but exported so
# the log records the regime, and so the same script works if the horizon moves.
export DROUGHT_VARIABILITY="${DROUGHT_VARIABILITY:-1}"

# Distress overlay arm. 6 = solvency (lastShortfall > distressShortfallFrac).
# Arms 1-5 and 106 are retired; see checkDistressTrigger.m.
export DISTRESS_ARM="${DISTRESS_ARM:-6}"

# Per-agent trace OFF for production. See the memory note above.
export AGENT_TRACE="${AGENT_TRACE:-0}"

# Campaign size. Unset uses run_calibration.m's own defaults.
if [[ -n "${NUM_DRAWS:-}" ]];      then export NUM_DRAWS;      fi
if [[ -n "${N_REALISATIONS:-}" ]]; then export N_REALISATIONS; fi

# Expectation-formation rule. Unset uses the readParameters default (arm 4);
# run_calibration.m hard-errors if it ever resolves to 0 unasked, because arm 0
# leaves agents nearly blind to recent drought.
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

# Run from the MIDAS project root (sibling of Scripts/)
cd "$SLURM_SUBMIT_DIR/../MIDAS"
echo "Working directory: $(pwd)"

# Pre-flight is NOT run here. Run it yourself before submitting:
#     cd <MIDAS project root> && bash HPC/preflight.sh
# It was gated in-job briefly and blocked submission, which is the wrong
# trade: a check that stops you working costs more than the failure mode
# it guards against.

for f in run_calibration.m runMIDASExperiment_parallel.m \
         Application_Specific_MIDAS_Code/readParameters.m; do
    [[ -f "$f" ]] || { echo "MISSING: $f" >&2; exit 1; }
done
if [[ ! -f "Calibration Testing/updatedMCParams.mat" && ! -f "updatedMCParams.mat" ]]; then
    echo "WARNING: no updatedMCParams.mat -- the run will use FRESH WIDE priors," >&2
    echo "         not your calibrated bounds. Check this is intended." >&2
fi
mkdir -p Outputs logs

# -batch runs headless, returns non-zero on error and needs no explicit exit,
# so a MATLAB failure fails the SLURM task instead of reporting success. This
# line is what the truncated version was missing.
matlab -batch "run_calibration"

echo "Task ${TASK_ID} finished at $(date)"
