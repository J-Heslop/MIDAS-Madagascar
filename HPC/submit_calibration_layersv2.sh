#!/bin/bash
#SBATCH --job-name=MIDAS_calib_L2
#SBATCH -p ht
#SBATCH --qos=ht
#SBATCH --array=1-25%25
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=20
#SBATCH --mem=80G
#SBATCH --time=48:00:00
#SBATCH --output=logs/midas_calib_L2_%A_%a.out
#SBATCH --error=logs/midas_calib_L2_%A_%a.err
#SBATCH --mail-type=START,END,FAIL
#SBATCH --mail-user=f.heslop@uea.ac.uk

# ============================================================
# MIDAS Madagascar -- CALIBRATION on the utility_layers_v2 LIVELIHOOD SET
#
# v2 replaces rice_north/rice_south with rice_rainfed/rice_irrigated. See
# Data/utility_layers_v2_DESIGN.md for the reasoning, the provenance of every
# value, and the list of values still marked PLACEHOLDER.
#
# RUNS ALONGSIDE THE v1 PROJECTION CAMPAIGN, DELIBERATELY.
# Everything that differs between the two is passed in the ENVIRONMENT, so
# this submission cannot disturb a projection task that has not yet started.
# Nothing in the repository needs editing to switch between them. Specifically:
#   MIDAS_LAYERS=v2  ->  readParameters picks Data/utility_layers_v2.csv
#                    ->  createUtilityLayers derives observed_spei_harvest_v2.csv
#                                        and spei6_corr_shared_v2.csv
#                    ->  readParameters derives drought_markov_params_v2.csv
#                    ->  runMIDASExperiment_parallel suffixes the output folder
#                        with "LayersV2"
#
# OUTPUT FOLDER
#   ./Outputs_Arm6_ExpArm4_LayersV2_Coupling25_Buffer.../
# Confirm the exact name from the "outputs -> ..." line in the first .out log
# before pointing any analysis at it.
#
# SUBMIT FROM Scripts/, the sibling of MIDAS/:
#   cd /gpfs/home/<username>/Desktop/Madagascar_migration/Scripts
#   mkdir -p logs ../MIDAS/logs ../MIDAS/Outputs
#   sbatch --export=ALL,MIDAS_LAYERS=v2,MIDAS_SSP=SSP2,LOCAL_DEMAND_COUPLING=0.25,\
# DROUGHT_VARIABILITY=1,DISTRESS_ARM=6 submit_calibration_layersv2.sh
#
# NO SPACES anywhere in the --export list.
#
# ---------------------------------------------------------- sizing
# Identical to submit_calibration_batch_v2.sh: NUM_DRAWS=500 over --array=1-25
# gives 20 draws/task x 1 realisation = 20 parfor iterations on 20 workers, one
# wave. A calibration run to 2025 is ~1.8 GB, so 20 concurrent ~36 GB inside
# the 80 G request. AGENT_TRACE stays 0.
#
# ---------------------------------------------------------- bounds
# PREFLIGHT_BOUNDS is NOT set to strict. This is a calibration campaign: it
# exists to widen the priors and re-identify against a livelihood structure the
# current bounds were never fitted to. The v1 bounds in updatedMCParams are a
# starting point, not a constraint, and should NOT be treated as settled for
# this layer set.
#
# EXPECT THE FIT TO BE WORSE THAN v1 AT FIRST. The parameters were identified
# against v1's livelihoods; rice_irrigated additionally introduces the first
# hard_slot on an agricultural layer, which will move the ag-participation
# series relative to the FAOSTAT 0.76 target.
# ============================================================

set -euo pipefail

ARRAY_JOB_ID="${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID}"
TASK_ID="${SLURM_ARRAY_TASK_ID:-0}"
echo "Job ${ARRAY_JOB_ID}, task ${TASK_ID} started at $(date)"
echo "Running on node: $(hostname)"
echo "CPUs allocated: ${SLURM_CPUS_PER_TASK}"

# ---------------------------------------------------------- configuration
# THE POINT OF THIS SCRIPT. Fail fast rather than defaulting: a v2 submission
# that silently ran v1 would be indistinguishable from a v1 run in its outputs,
# since both layer sets have 10 layers and the run files carry counts, not names.
export MIDAS_LAYERS="${MIDAS_LAYERS:-v2}"
if [[ "${MIDAS_LAYERS}" == "v1" ]]; then
    echo "ERROR: MIDAS_LAYERS=v1 passed to the v2 submit script. Use" >&2
    echo "       submit_calibration_batch_v2.sh for a v1 calibration." >&2
    exit 1
fi

export MIDAS_SSP="${MIDAS_SSP:-SSP2}"
export LOCAL_DEMAND_COUPLING="${LOCAL_DEMAND_COUPLING:-0.25}"
export DROUGHT_VARIABILITY="${DROUGHT_VARIABILITY:-1}"
export DISTRESS_ARM="${DISTRESS_ARM:-6}"
export AGENT_TRACE="${AGENT_TRACE:-0}"
export NUM_DRAWS="${NUM_DRAWS:-500}"
if [[ -n "${N_REALISATIONS:-}" ]];  then export N_REALISATIONS;  fi
if [[ -n "${EXPECTATION_ARM:-}" ]]; then export EXPECTATION_ARM; fi

echo "Layer set:           ${MIDAS_LAYERS}"
echo "Scenario:            ${MIDAS_SSP}"
echo "End year:            <readParameters default, 2025 = calibration>"
echo "Demand coupling:     ${LOCAL_DEMAND_COUPLING}"
echo "Drought variability: ${DROUGHT_VARIABILITY}"
echo "Distress arm:        ${DISTRESS_ARM}"
echo "Agent trace:         ${AGENT_TRACE}"
echo "Expectation arm:     ${EXPECTATION_ARM:-<readParameters default>}"
echo "Draws:               ${NUM_DRAWS}"
echo "Realisations:        ${N_REALISATIONS:-<run_calibration default>}"

module load matlab/2024b

# CODE TREE IS SELECTABLE (2026-09-13) -- default preserves the old behaviour.
#
# Point this at a SEPARATE TREE while a v1 campaign is still running. The layer
# changes are gated behind MIDAS_LAYERS, but several changes made alongside them
# are NOT -- agentParameters.initialWealthMean (25 -> 55) and the affordability
# test in choosePortfolio.m (reserve -> plain liquidity) apply unconditionally.
# MATLAB reads those .m files when each task STARTS, so overwriting them in a
# tree with queued tasks would leave one campaign split across two models, with
# nothing in the output files to show which task ran which.
#
#   cp -a MIDAS MIDAS_v2          # on the cluster, once
#   rsync the changed files into MIDAS_v2 ONLY
#   sbatch --export=ALL,MIDAS_ROOT=$HOME/Desktop/Madagascar_migration/MIDAS_v2,...
#
# Once the v1 projection campaign has finished there is no reason to keep the
# trees apart; drop MIDAS_ROOT and the default applies again.
MIDAS_ROOT="${MIDAS_ROOT:-$SLURM_SUBMIT_DIR/../MIDAS}"
if [[ ! -d "$MIDAS_ROOT" ]]; then
    echo "ERROR: MIDAS_ROOT does not exist: $MIDAS_ROOT" >&2
    exit 1
fi
cd "$MIDAS_ROOT"
echo "Code tree:         $(pwd)"

# Pre-flight is NOT run here. Run it yourself before submitting:
#     cd <MIDAS project root> && bash HPC/preflight.sh

for f in run_calibration.m runMIDASExperiment_parallel.m \
         Application_Specific_MIDAS_Code/readParameters.m; do
    [[ -f "$f" ]] || { echo "ERROR: $f not found in $(pwd)" >&2; exit 1; }
done

# THE v2 DATA CHAIN. Every one of these is keyed by LAYER NAME, and the model
# now hard-errors on a mismatch rather than running half-forced -- but failing
# here costs seconds instead of a queue slot and a node allocation.
for f in "Data/utility_layers_v2.csv" \
         "Data/observed_spei_harvest_v2.csv" \
         "Data/drought_markov_params_v2.csv" \
         "Data/spei6_corr_shared_v2.csv"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: missing $f" >&2
        echo "  Regenerate the v2 derived data before submitting:" >&2
        echo "    python apply_observed_drought.py --layers Data/utility_layers_v2.csv \\" >&2
        echo "                                     --out    Data/observed_spei_harvest_v2.csv" >&2
        echo "    python derive_drought_markov_params.py --layers Data/utility_layers_v2.csv \\" >&2
        echo "           --obs Data/observed_spei_harvest_v2.csv --suffix _v2" >&2
        exit 1
    fi
done
echo "v2 data chain present: layers, observed SPEI, Markov params, shared correlation."

if [[ ! -f "Calibration Testing/updatedMCParams.mat" && ! -f "updatedMCParams.mat" ]]; then
    echo "WARNING: no updatedMCParams.mat -- the run will use FRESH WIDE priors." >&2
fi
mkdir -p logs Outputs

matlab -nodisplay -nosplash -batch "run_calibration"

echo "Job ${ARRAY_JOB_ID}, task ${TASK_ID} finished at $(date)"
