#!/bin/bash
#SBATCH --job-name=MIDAS_sfdomain
#SBATCH -p ht
#SBATCH --qos=ht
#SBATCH --array=1-15
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=20
#SBATCH --mem=60G
#SBATCH --time=48:00:00
#SBATCH --output=logs/midas_sfdomain_%A_%a.out
#SBATCH --error=logs/midas_sfdomain_%A_%a.err
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=f.heslop@uea.ac.uk

# ============================================================
# MIDAS Madagascar -- DISTRESS SHORTFALL, FULL DOMAIN SWEEP
#
# WHAT THIS IS FOR
# distressShortfallFrac became a BOUNDED fraction of the agent's own food
# requirement on 2026-09-06 (see the note at the lastShortfall assignment in
# midasMainLoop.m). Because it is now bounded [0,1], this sweep can cover the
# WHOLE domain. That is the point: Set 24 swept 0.10-0.60 of an unbounded
# quantity whose mass sat above the window, so a 6x nominal change moved
# firing by only 1.7x and the parameter looked inert when it was simply being
# explored in the wrong place. A bounded metric cannot have that failure mode.
#
# PRIMARY USE (2026-09-06): a WIDE CHARACTERISATION RUN of the current build.
# Every parameter other than the levers below samples its calibrated bounds,
# so 300 draws is an ENSEMBLE, not a sweep -- the input to a robustness screen
# asking which reported quantities hold their sign and magnitude across the
# parameter uncertainty, and which do not. Quantities that survive are
# reportable despite the model's known level errors; quantities that flip or
# swing by a factor of two are not, however good the story.
#
# THIS IS NOT A CALIBRATION. Do not read a preferred value off it. Any value
# that lands the forced-migration count on the observed 2-4% is absorbing the
# model's excess total mobility rather than measuring when households leave.
# What it IS for:
#   1. Does the new code run at all, and is lastShortfall inside [0,1]?
#   2. What is the SHAPE of firing against the threshold across the full
#      domain -- monotone, saturating, or flat?
#   3. Does the kere:ordinary contrast vary with it, or is the contrast
#      invariant to the parameter (which would be the informative result)?
#
# WHY ht
# 25 nodes x 24 cores = 600 CPUs, uncapped QOS, and the cluster is idle
# overnight. 15 tasks x 20 cpus = 300 CPUs leaves headroom for other users.
#
# --qos=ht IS MANDATORY AND IS NOT THE DEFAULT. Without it the job inherits
# uea-core-default and sits PENDING forever with
#     (Job's QOS not permitted to use this partition
#      (ht allows ht not uea-core-default))
# It does not fail, it does not warn, and squeue shows ST=PD with TIME 0:00 --
# indistinguishable at a glance from waiting for a node. That cost a night.
# Any other script in this directory moved from -p compute to -p ht needs the
# same line adding.
# NOTE THE MEMORY: ht nodes have 90025 MB, so the 90G used by the compute
# scripts will not schedule here. 20 concurrent calibration runs at ~1.8 GB
# is ~36 GB, so 60G is comfortable.
#
# SIZING
# 300 draws over an array of 15 gives drawsPerTask = 20, and with
# N_REALISATIONS=1 that is 20 parfor iterations on 20 workers -- one run per
# CPU, one wave, nothing queued.
#
# WALL CLOCK -- ASK FOR THE PARTITION MAXIMUM, NOT AN ESTIMATE.
# The Set 24 campaign was also one run per CPU, so all 100 draws started
# together; at its 12-hour limit only 34 had finished. That is not queueing,
# it is the run-time distribution straddling 12 hours -- roughly a third of
# calibration runs finish inside it and two thirds do not. Earlier headers in
# this directory claiming "a few hours" are contradicted by that evidence.
#
# SLURM charges actual usage, so an over-long request costs nothing when jobs
# finish early. The asymmetry is total: a run that hits the limit produces NO
# output and the whole node-hour is lost, while a run that finishes early
# simply releases the node. There is no reason to trim this.
#
# 48h is the ht maximum at the time of writing. VERIFY BEFORE SUBMITTING --
# sbatch rejects an over-long request immediately, which is a safe failure if
# you are watching but not if you have gone to bed:
#     sinfo -p ht -o "%P %l"
#
# NOTE FOR THE FULL CAMPAIGN. If a 40-year calibration run needs more than
# 12 hours, the 2085 projection horizon is 2.5x the timesteps against a
# growing population and will need substantially more than 2.5x the time.
# Size that from measured calibration times, not from an estimate.
#
# BEFORE SUBMITTING -- THREE THINGS
#
# 1. COPY BOTH CHANGED FILES. midasMainLoop.m and checkDistressTrigger.m
#    changed together. The trigger now hard-errors if
#    distressShortfallFracThresh is missing, so a stale midasMainLoop fails
#    loudly on the first agent -- good. The reverse pairing (new main loop,
#    stale trigger) would compare a fraction against a cost and fire almost
#    never, silently. preflight.sh checks both ends.
#
# 2. RUN PREFLIGHT. It now covers the units change:
#      cd ../MIDAS && bash ../Scripts/preflight.sh
#
# 3. WIDEN THE BOUND TO THE FULL DOMAIN. distressShortfallFrac is pinned at
#    [0.1, 0.1] in runMIDASExperiment_parallel and, if updatedMCParams.mat
#    carries it, the bounds file wins over the code regardless:
#
#      setMCBounds({'modelParameters.distressShortfallFrac', 0.05, 0.95})
#
#    0.05 to 0.95 rather than 0 to 1: at exactly 0 the trigger fires on any
#    shortfall at all, and at exactly 1 it can never fire, so both endpoints
#    are degenerate and waste draws on known answers.
#
# SUBMIT
#   cd /gpfs/home/<username>/Desktop/Madagascar_migration/Scripts
#   mkdir -p logs ../MIDAS/logs ../MIDAS/Outputs
#
#   sbatch --export=ALL,NUM_DRAWS=300,N_REALISATIONS=1,RUN_TAG=SFDomain,\
# LOCAL_DEMAND_COUPLING=0.25,DROUGHT_VARIABILITY=1,DISTRESS_ARM=6,EXPECTATION_ARM=4 \
#          submit_shortfall_domain_ht.sh
#
# EXPECTATION_ARM=4 is passed explicitly rather than left to the
# readParameters default. The default is 4, but the drought sweep silently
# ran arm 0 once because a stale readParameters.m was on the node, and an
# explicit value plus the echo below makes the log self-documenting.
#
# WHAT TO DO WITH THE RESULT
#   plot_distress_threshold('D:\MIDAS outputs\<folder>', 'Refresh', true)
# The console block matters more than the figure: the ratio of distress moves
# to food-insecure agent-years is an identity-bounded check (it cannot exceed
# 1), and the kere:ordinary contrast against the threshold is the shape
# question. If firing is still ~flat across the FULL domain, that is a real
# result rather than a range artefact, and it says the trigger threshold is
# not what governs distress migration in this model.
# ============================================================

set -euo pipefail

ARRAY_JOB_ID="${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID}"
TASK_ID="${SLURM_ARRAY_TASK_ID:-0}"
echo "Job ${ARRAY_JOB_ID}, task ${TASK_ID} started at $(date)"
echo "Running on node: $(hostname)"
echo "CPUs allocated: ${SLURM_CPUS_PER_TASK}"

export NUM_DRAWS="${NUM_DRAWS:-300}"
export N_REALISATIONS="${N_REALISATIONS:-1}"
export LOCAL_DEMAND_COUPLING="${LOCAL_DEMAND_COUPLING:-0.25}"
export DROUGHT_VARIABILITY="${DROUGHT_VARIABILITY:-1}"
export DISTRESS_ARM="${DISTRESS_ARM:-6}"
export AGENT_TRACE="${AGENT_TRACE:-0}"
export RUN_TAG="${RUN_TAG:-SFDomain}"
if [[ -n "${EXPECTATION_ARM:-}" ]]; then export EXPECTATION_ARM; fi

echo "Draws:                  ${NUM_DRAWS} x ${N_REALISATIONS} realisation(s)"
echo "Demand coupling:        ${LOCAL_DEMAND_COUPLING}"
echo "Drought variability:    ${DROUGHT_VARIABILITY}"
echo "Distress arm:           ${DISTRESS_ARM}"
echo "Expectation arm:        ${EXPECTATION_ARM:-<readParameters default>}"
echo "Run tag:                ${RUN_TAG}"

# distressShortfallFrac is only read by arms 6 and 106. Under any other arm
# this campaign sweeps a parameter nothing consumes and returns 300 runs that
# differ only by noise. Fail rather than discover that tomorrow.
if [[ "${DISTRESS_ARM}" != "6" ]]; then
    echo "FATAL: DISTRESS_ARM=${DISTRESS_ARM}, but distressShortfallFrac is only" >&2
    echo "       consumed by arm 6. This sweep would vary an inert parameter." >&2
    exit 1
fi

module load matlab/2024b

cd "$SLURM_SUBMIT_DIR/../MIDAS"
echo "Working directory: $(pwd)"

for f in run_calibration.m runMIDASExperiment_parallel.m \
         Application_Specific_MIDAS_Code/readParameters.m \
         Core_MIDAS_Code/midasMainLoop.m \
         Core_MIDAS_Code/checkDistressTrigger.m; do
    [[ -f "$f" ]] || { echo "MISSING: $f" >&2; exit 1; }
done

# THE UNITS PAIRING. Both directions, because only one of them fails loudly on
# its own. Cheap to check here; expensive to discover in the morning.
grep -q 'distressShortfallFracThresh' Core_MIDAS_Code/midasMainLoop.m || {
    echo "FATAL: midasMainLoop.m is a STALE COPY -- it does not publish" >&2
    echo "       distressShortfallFracThresh. Recopy it (2026-09-06 change)." >&2
    exit 1; }
grep -q 'distressShortfallFracThresh' Core_MIDAS_Code/checkDistressTrigger.m || {
    echo "FATAL: checkDistressTrigger.m is a STALE COPY -- it still reads the" >&2
    echo "       removed distressShortfallAbs and would compare a fraction" >&2
    echo "       against a cost, firing almost never and saying nothing." >&2
    exit 1; }

if [[ ! -f "Calibration Testing/updatedMCParams.mat" && ! -f "updatedMCParams.mat" ]]; then
    echo "FATAL: no updatedMCParams.mat. Every other parameter must stay at its" >&2
    echo "       calibrated bounds or this becomes an unfocused mini-calibration." >&2
    exit 1
fi

CACHE="Data/Mada Admin 2/Admin_2_lat_lon.mat"
[[ -f "$CACHE" ]] || { echo "MISSING: $CACHE -- copy the REPAIRED cache across" >&2; exit 1; }

mkdir -p Outputs logs

matlab -batch "run_calibration"

echo "Task ${TASK_ID} finished at $(date)"
