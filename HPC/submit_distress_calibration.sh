#!/bin/bash
#SBATCH --job-name=MIDAS_distress
#SBATCH -p compute
#SBATCH --array=1-5
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=20
#SBATCH --mem=90G
#SBATCH --time=12:00:00
#SBATCH --output=logs/midas_distress_%A_%a.out
#SBATCH --error=logs/midas_distress_%A_%a.err
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=f.heslop@uea.ac.uk

# ============================================================
# MIDAS Madagascar -- DISTRESS-THRESHOLD CALIBRATION (100 runs)
#
# WHAT THIS IS FOR
# Identifies modelParameters.distressShortfallFrac -- the unmet share of
# annual subsistence at which a household is forced to move -- against an
# empirical target, instead of leaving it at the arbitrary 0.1 it has been
# fixed at since it was introduced.
#
# HOW THE TRIGGER WORKS (checkDistressTrigger.m, Variant F / arm 6)
#
#     distressShortfallAbs = distressShortfallFrac * annualSubsist
#     fire = cooldownOK && (agent.lastShortfall > distressShortfallAbs)
#
# lastShortfall is what remains unmet at year-end AFTER spending income and
# drawing the asset buffer down to its reproductive floor. At the current
# frac of 0.1 a household is forced to migrate if it covers less than 90% of
# the year's subsistence -- which is not destitution, and fires far too
# readily. The cooldown is four quarters, so at most one distress move per
# agent per year.
#
# WHY IT IS IDENTIFIABLE
# The SAME quantity drives the food-insecurity calibration target:
#
#     currentAgent.lastShortfall = shortfall;
#     wasInsecure = shortfall > 0;      % <- the FI metric, target 0.317
#
# FI is "shortfall > 0"; distress is "shortfall > frac * subsistence". They
# are one variable at two thresholds, so distress migration is strictly a
# subset of food insecurity and frac alone sets how deep into that
# distribution the trigger reaches. That makes it well identified by a single
# scatter, in the same way subsistence_costs is identified by FI.
#
# THE TARGET -- A CONTRAST, NOT A LEVEL
# IOM's DTM baseline mobility assessment recorded 90,219 individuals
# displaced from 20 Grand Sud municipalities over 2019-2022, three
# consecutive failed rainy seasons ending in the worst drought in forty
# years. Against a Grand Sud population near 2.8 million that is roughly 3%
# cumulative across the whole region; against the four worst-affected
# districts the assessment concentrates on, plausibly 9-18% cumulative. So
# roughly 2-4% of the affected population displaced PER YEAR at the peak of
# an extreme multi-year kere.
#
# In those same assessments 88% of respondents gave drought as the main
# reason for leaving, so distress dominating voluntary movement IS what was
# observed in a kere year. Baseline Grand Sud mobility, by contrast, is
# seasonal labour migration to Alaotra and Marovoay. The target is therefore
# the CONTRAST:
#
#     kere years      2-4% of Grand Sud agents making a distress move
#     non-kere years  close to zero
#
# Drought-associated kere years, per drought_migration_comparison.jl:
#     1991, 1992, 1997, 2016, 2017, 2018, 2021   (7 of 41 calibration years)
# 2002 and 2013 are famine years with neutral-to-positive SPEI and should NOT
# show a distress response; they are a negative control, not a target.
#
# BEFORE SUBMITTING -- WIDEN THE BOUND, OR THIS CAMPAIGN DOES NOTHING
# distressShortfallFrac is pinned at [0.1, 0.1] in runMIDASExperiment_parallel
# and, if updatedMCParams.mat carries it, the bounds file wins over the code
# regardless. Sampling it is the entire point of this campaign, so:
#
#     setMCBounds({'modelParameters.distressShortfallFrac', 0.10, 0.60})
#
# UNITS CHANGED 2026-09-06 -- THE OLD RANGE NO LONGER MEANS WHAT IT DID.
# distressShortfallFrac is now the fraction of its own food requirement an
# agent must fail to obtain, bounded [0,1] ("0.4" = moved once it got less
# than 60% of what it needed). Previously it multiplied nominal annual
# subsistence to give a COST, while the shortfall it was compared against was
# measured on the drought-INFLATED requirement and could exceed 1.0.
#
# Consequence for this campaign: 0.10-0.60 swept the lower-middle of an
# unbounded quantity. On the bounded metric the same nominal range covers a
# different and much larger share of the distribution, so the previous
# results do not carry over and the range must be re-derived rather than
# reused. Do NOT copy a value across from the Set 24 scoring.
#
# Check the printed before/after. If it reports the parameter as ADDED rather
# than CHANGED it was absent and the code range applies -- also fine.
#
# SUBMIT
#   cd /gpfs/home/<username>/Desktop/Madagascar_migration/Scripts
#   mkdir -p logs ../MIDAS/logs ../MIDAS/Outputs
#
#   sbatch --export=ALL,NUM_DRAWS=100,N_REALISATIONS=1,RUN_TAG=DistressCal,\
# LOCAL_DEMAND_COUPLING=0.25,DROUGHT_VARIABILITY=1,DISTRESS_ARM=6 \
#          submit_distress_calibration.sh
#
# NO DROUGHT_SCALE_FIXED. Deliberate: droughtScaleFactor samples from its
# bounds here rather than being pinned, so these runs also contribute a
# scatter for the drought-scale re-centring the parallel sweep is doing. One
# campaign, several re-centrings -- the other 75 parameters keep sampling
# too, so the same 100 runs give scatter over subsistence_costs and
# urbanIncomeMultiplier as well.
#
# SIZING
# 100 draws over an array of 5 gives drawsPerTask = 20, and with
# N_REALISATIONS=1 that is 20 parfor iterations on 20 workers -- all
# concurrent, nothing queued, so the wall clock is one run's not twenty.
# Calibration-horizon runs are roughly 1.8 GB each, so 20 concurrent needs
# about 36 GB; 90G is generous. Expect a few hours against the 12 requested.
#
# WHAT TO DO WITH THE RESULT
# Download Outputs_Arm6_Coupling25_DistressCal, then plot the distress-move
# rate per Grand Sud agent-year, split kere versus non-kere, against the
# sampled distressShortfallFrac. Take the value where the kere rate lands
# near 3% and the non-kere rate approaches zero. If no value satisfies both,
# that is itself the finding: the trigger cannot reproduce the observed
# concentration and the threshold is the wrong instrument.
#
# EXPECT TO HAVE TO RESCALE. Background mobility in this model already runs
# high against the census-implied rate (Section 4.7), so absolute distress
# rates may exceed 2-4% at every sampled threshold. If so, read the CONTRAST
# rather than the level: pick the frac that maximises the kere / non-kere
# ratio, and report the absolute rate as an acknowledged overestimate.
# ============================================================

set -euo pipefail

ARRAY_JOB_ID="${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID}"
TASK_ID="${SLURM_ARRAY_TASK_ID:-0}"
echo "Job ${ARRAY_JOB_ID}, task ${TASK_ID} started at $(date)"
echo "Running on node: $(hostname)"
echo "CPUs allocated: ${SLURM_CPUS_PER_TASK}"

# Variant F is the whole point -- it is the only arm that reads lastShortfall,
# and distressShortfallFrac is inert under every other arm. Fail rather than
# run 100 uninformative jobs.
export DISTRESS_ARM="${DISTRESS_ARM:-6}"
if [[ "${DISTRESS_ARM}" != "6" ]]; then
    echo "FATAL: DISTRESS_ARM=${DISTRESS_ARM}, but distressShortfallFrac is only" >&2
    echo "       read by Variant F (arm 6). This campaign would tell you nothing." >&2
    exit 1
fi

export NUM_DRAWS="${NUM_DRAWS:-100}"
export N_REALISATIONS="${N_REALISATIONS:-1}"
export RUN_TAG="${RUN_TAG:-DistressCal}"
export LOCAL_DEMAND_COUPLING="${LOCAL_DEMAND_COUPLING:-0.25}"
export DROUGHT_VARIABILITY="${DROUGHT_VARIABILITY:-1}"
export AGENT_TRACE="${AGENT_TRACE:-0}"
if [[ -n "${EXPECTATION_ARM:-}" ]]; then export EXPECTATION_ARM; fi

echo "Draws:                  ${NUM_DRAWS} x ${N_REALISATIONS} realisation(s)"
echo "Run tag:                ${RUN_TAG}"
echo "Demand coupling:        ${LOCAL_DEMAND_COUPLING}"
echo "Drought variability:    ${DROUGHT_VARIABILITY}"
echo "Distress arm:           ${DISTRESS_ARM}"
echo "Agent trace:            ${AGENT_TRACE}"
echo "Expectation arm:        ${EXPECTATION_ARM:-<readParameters default>}"

module load matlab/2024b

cd "$SLURM_SUBMIT_DIR/../MIDAS"
echo "Working directory: $(pwd)"

for f in run_calibration.m runMIDASExperiment_parallel.m \
         Application_Specific_MIDAS_Code/readParameters.m \
         Core_MIDAS_Code/checkDistressTrigger.m; do
    [[ -f "$f" ]] || { echo "MISSING: $f" >&2; exit 1; }
done

if [[ ! -f "Calibration Testing/updatedMCParams.mat" && ! -f "updatedMCParams.mat" ]]; then
    echo "FATAL: no updatedMCParams.mat. Every parameter other than the distress" >&2
    echo "       threshold should sit at its calibrated bounds." >&2
    exit 1
fi

CACHE="Data/Mada Admin 2/Admin_2_lat_lon.mat"
[[ -f "$CACHE" ]] || { echo "MISSING: $CACHE -- copy the REPAIRED cache across" >&2; exit 1; }

mkdir -p Outputs logs

matlab -batch "run_calibration"

echo "Task ${TASK_ID} finished at $(date)"
