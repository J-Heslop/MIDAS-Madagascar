#!/bin/bash
#SBATCH --job-name=MIDAS_proj
#SBATCH -p compute
#SBATCH --array=1-25%25
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=20
#SBATCH --mem=180G
#SBATCH --time=5-00:00:00
#SBATCH --output=logs/midas_proj_%A_%a.out
#SBATCH --error=logs/midas_proj_%A_%a.err
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=f.heslop@uea.ac.uk

# ============================================================
# MIDAS Madagascar -- PROJECTION runs to 2085 (SLURM array)
#
# Adapted from submit_calibration_batch.sh, which was truncated mid-file and
# never invoked MATLAB at all -- it loaded the module, changed directory,
# echoed three lines and exited successfully. Jobs "completed" and produced
# nothing. Check any calibration set produced with that copy actually has
# MC*.mat output before trusting it.
#
# SUBMIT ONCE PER SCENARIO. Scenario and horizon come from the environment,
# not from edits to readParameters.m, so both can run from the SAME codebase
# at the same time:
#
#   cd /gpfs/home/<username>/Desktop/Madagascar_migration/Scripts
#   mkdir -p logs ../MIDAS/logs ../MIDAS/Outputs
#
# NOTE on the log directory. SLURM resolves --output relative to the directory
# sbatch is INVOKED from (Scripts/), not the one this script later cd's into
# (MIDAS/). It does not create the folder, and a missing one fails the job
# immediately -- usually with no message, because the error log cannot be
# written either. The calibration script instructed only ../MIDAS/logs, which
# is the wrong side of the cd. Creating both costs nothing and removes the
# ambiguity.
#
#   sbatch --export=ALL,MIDAS_SSP=SSP2,MIDAS_END_YEAR=2085,LOCAL_DEMAND_COUPLING=0.25,DROUGHT_VARIABILITY=1,DISTRESS_ARM=6 \
#          --job-name=MIDAS_SSP2 submit_projection_batch.sh
#
#   sbatch --export=ALL,MIDAS_SSP=SSP5,MIDAS_END_YEAR=2085,LOCAL_DEMAND_COUPLING=0.25,DROUGHT_VARIABILITY=1,DISTRESS_ARM=6 \
#          --job-name=MIDAS_SSP5 submit_projection_batch.sh
#
# SIZING. Iterations per task = ceil(NUM_DRAWS / array size) * N_REALISATIONS,
# and that number must stay under about 14 to fit 180G at ~12 GB per
# projection run.
#
#   NUM_DRAWS=50, N_REALISATIONS=2, --array=1-25  <- DEFAULT, set below
#       ceil(50/25) = 2 draws/task x 2 = 4 iterations ~ 48 GB. 100 runs/scenario.
#
# Do NOT use --array=1-10: that is 10 draws/task x 2 = 20 iterations, fills all
# 20 workers at ~240 GB, and OOMs.
#
# THESE ARE EXPORTED BY THIS SCRIPT, not edited into run_calibration.m.
# CORRECTED 2026-09-12. This header previously instructed "set numTotalDraws =
# 50 and nRealisations = 2 in run_calibration.m" while the script itself
# exported neither, and run_calibration.m's own defaults are 1000 and 1. A
# submission that followed the header without editing that file would have run
# ceil(1000/25) = 40 concurrent iterations at ~12 GB -- roughly 480 GB against
# the 180 GB request, i.e. exactly the OOM described further down. The values
# now travel with the submission.
#
# Editing run_calibration.m or readParameters.m between submissions would NOT
# be safe: %N throttling means tasks start over many hours and MATLAB reads
# those files when each task begins, so an edit made for the second scenario
# would silently switch any task of the first that had not yet started. This
# is why every lever is passed in the environment.
#
# REVISED 2026-08-19 from --array=1-10 (10 concurrent runs), which was killed
# by OOM and then by the wall clock. Memory per run is dominated by three
# per-agent per-timestep cell arrays written at midasMainLoop.m:691-693
# (agentPortfolioHistory, agentAspirationHistory, consideredHistory). Their
# cost scales as agents x timesteps, and projections raise BOTH: 410 timesteps
# instead of 170, and SSP population growth of roughly 5x over 100 years
# instead of 1.8x over 40. Estimated per run:
#
#     calibration 2025, numAgents high   ~1.8 GB
#     projection  2085, numAgents high   ~12  GB
#
# Ten concurrent runs therefore needed well over the 100 GB limit; four need
# roughly 48 GB. Each task also does 40% of the previous work, so the wall
# clock falls with it. Total runs per scenario are unchanged.
#
# IF TASKS STILL TIME OUT the next lever is numAgents (currently narrowed to
# 3082-5848). Network operations are effectively quadratic in population, so
# capping it cuts time faster than it cuts memory -- but it means projections
# run at a different population scale from the calibration, which has to be
# stated in the methods.
#
# WALL CLOCK AND MEMORY. 5 days (5-00:00:00) and 180G, raised 2026-08-19 after
# the 48h/100G attempt was OOM-killed and then timed out. SLURM's day-hour
# format is D-HH:MM:SS, so "5-00:00:00" is five days; "120:00:00" also works on
# most builds but the dashed form is unambiguous.
#
# The two limits interact: an OOM-killed step leaves the node swapping, which
# is why that attempt hit BOTH. Raising memory alone would probably have been
# enough, but headroom on the wall clock costs nothing if the job finishes
# early -- SLURM charges actual use, not the request. The risk of a long
# request is queue priority, not waste.
#
# If your partition caps below 5 days, raise --array further (fewer draws per
# task) rather than trimming the horizon. Check the cap with:
#     sinfo -p compute -o "%P %l %m"          (partition, max time, max memory)
# ============================================================

set -euo pipefail

ARRAY_JOB_ID="${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID}"
TASK_ID="${SLURM_ARRAY_TASK_ID:-0}"
echo "Job ${ARRAY_JOB_ID}, task ${TASK_ID} started at $(date)"
echo "Running on node: $(hostname)"
echo "CPUs allocated: ${SLURM_CPUS_PER_TASK}"

# Fail fast if the scenario was not passed. Defaulting here would reproduce
# the LOCAL_DEMAND_COUPLING problem: a forgotten variable silently producing
# a different model than intended, discovered only after the campaign.
: "${MIDAS_SSP:?MIDAS_SSP not set -- pass --export=ALL,MIDAS_SSP=SSP2 or SSP5}"
: "${MIDAS_END_YEAR:?MIDAS_END_YEAR not set -- pass --export=ALL,MIDAS_END_YEAR=2085}"
export MIDAS_SSP MIDAS_END_YEAR
export LOCAL_DEMAND_COUPLING="${LOCAL_DEMAND_COUPLING:-0.25}"

# Projection-period drought variability. Set 21 ran with this OFF because
# readParameters.m hard-coded droughtVariabilityOn = false, so from 2023 --
# where the observed ERA5 SPEI record ends -- there were no drought events at
# all, only the smooth GRMA mean-yield decline. Exported explicitly here so
# the log records which regime produced the campaign rather than leaving it
# to a default in a file nobody re-reads.
export DROUGHT_VARIABILITY="${DROUGHT_VARIABILITY:-1}"

# Distress overlay. Only appended by runMIDASExperiment_parallel.m when the
# name is ABSENT from updatedMCParams.mat, so the bounds file wins if it
# carries distressMigrationEnabled/distressTriggerCode. Exported anyway so
# the "[Distress overlay] Running ARM n" log line agrees with what runs.
export DISTRESS_ARM="${DISTRESS_ARM:-6}"

# Per-agent trace recording. OFF for production ensembles: it was 99.96% of
# every Set 21 output file (7-8 GB each, 1.2 TB per scenario, against ~3 MB
# without it) and nothing in the analysis reads it. Turn on only for a small
# diagnostic batch when a question genuinely needs agent-level trajectories:
#   sbatch --export=ALL,...,AGENT_TRACE=1 --array=1-5%5 submit_projection_batch.sh
export AGENT_TRACE="${AGENT_TRACE:-0}"

# CAMPAIGN SIZE. See the sizing block in the header. Exported rather than left
# to run_calibration.m's defaults (1000 draws, 1 realisation), which would put
# 40 concurrent 12 GB runs on a 180 GB node.
export NUM_DRAWS="${NUM_DRAWS:-50}"
export N_REALISATIONS="${N_REALISATIONS:-2}"

# Projection campaigns must run the DECLARED bounds, not whatever the last
# calibration round left behind, so the preflight bounds checks are assertions
# here. A calibration campaign deliberately widens them and does not set this.
#
# NOTE: this script does NOT invoke preflight.sh -- the in-job gate was removed
# deliberately. Exporting this only has an effect if you run preflight yourself
# in the same shell, which is the intended use:
#     cd <MIDAS project root> && PREFLIGHT_BOUNDS=strict bash HPC/preflight.sh
export PREFLIGHT_BOUNDS=strict

# Expectation-formation rule (formExpectation.m arms 0-4). Left unset the
# runner uses the readParameters.m default; an invalid value is now a hard
# error rather than a silent reset to arm 0. Echoed below so every log
# records which decision rule produced the campaign -- arm 0 samples the
# agent's whole history uniformly and is close to blind to recent drought.
if [[ -n "${EXPECTATION_ARM:-}" ]]; then export EXPECTATION_ARM; fi

echo "Scenario:            ${MIDAS_SSP}"
echo "End year:            ${MIDAS_END_YEAR}"
echo "Demand coupling:     ${LOCAL_DEMAND_COUPLING}"
echo "Drought variability: ${DROUGHT_VARIABILITY}  (Markov chain from 2023)"
echo "Distress arm:        ${DISTRESS_ARM}"
echo "Agent trace:         ${AGENT_TRACE}"
echo "Expectation arm:     ${EXPECTATION_ARM:-<readParameters default>}"
echo "Draws:               ${NUM_DRAWS}"
echo "Realisations:        ${N_REALISATIONS}"
if [[ "${AGENT_TRACE}" == "1" ]]; then
    echo "  WARNING: agent tracing ON -- expect ~7 GB per run, not ~3 MB." >&2
fi

module load matlab/2024b

# Run from the MIDAS project root (sibling of Scripts/)
cd "$SLURM_SUBMIT_DIR/../MIDAS"
echo "Working directory: $(pwd)"

# Sanity checks before burning a node-day on a misconfigured run.
for f in run_calibration.m runMIDASExperiment_parallel.m \
         Application_Specific_MIDAS_Code/readParameters.m; do
    [[ -f "$f" ]] || { echo "MISSING: $f" >&2; exit 1; }
done
if [[ ! -f "Calibration Testing/updatedMCParams.mat" && ! -f "updatedMCParams.mat" ]]; then
    echo "WARNING: no updatedMCParams.mat -- the run will use FRESH WIDE priors," >&2
    echo "         not your calibrated bounds. Check this is intended." >&2
fi
mkdir -p Outputs logs

# -batch runs headless, returns a non-zero exit code on error, and does not
# need an explicit exit -- so a MATLAB failure fails the SLURM task instead of
# reporting success.
matlab -batch "run_calibration"

echo "Task ${TASK_ID} finished at $(date)"
