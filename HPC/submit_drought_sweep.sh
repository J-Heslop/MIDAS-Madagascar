#!/bin/bash
#SBATCH --job-name=MIDAS_dsweep
#SBATCH -p compute
#SBATCH --array=1-1
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=20
#SBATCH --mem=90G
#SBATCH --time=12:00:00
#SBATCH --output=logs/midas_dsweep_%A_%a.out
#SBATCH --error=logs/midas_dsweep_%A_%a.err
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=f.heslop@uea.ac.uk

# ============================================================
# MIDAS Madagascar -- DROUGHT SCALE SWEEP
#
# WHAT THIS IS FOR
# Re-centres modelParameters.droughtScaleFactor after the region-name fix,
# without a full calibration round. Everything else stays at its calibrated
# narrowed bounds and keeps sampling, so each sweep point returns a spread
# rather than a single point and you can see whether the scale factor moves
# the targets by more than parameter noise does.
#
# WHY IT IS NEEDED
# Atsimo-Andrefana -- 5.6% of national population, but 54% of the Grand Sud --
# ran with yieldFactor = 1 flat for 1985-2085 in every campaign to date.
# ADM2_FR is a 15-character DBF field and truncated the name, so the GRMA
# surfaces, the observed SPEI record, the Markov parameters and the
# correlation matrix all failed to match it. It should have had mean agYF
# 0.614 over 1985-2022 with 17 of 38 years below 0.6 -- worse than Androy.
# Vatovavy Fitovinany was also unforced but is wet-east and barely affected
# (0.868, 2 years below 0.6).
#
# The old cassava floor of 0.5 sat above the GRMA baseline in the dry west
# (Atsimo-Andrefana 0.575, Menabe 0.616) and so clamped those regions upward
# as well. Both errors suppressed drought impact, so the calibration had to
# recover the missing southern migration and food insecurity from the twenty
# regions that were forced. Expect droughtScaleFactor to be biased HIGH.
#
# SUBMIT ONCE PER SWEEP POINT. Six points across the ORIGINAL prior, not the
# narrowed bound -- the narrowed bound is the thing under suspicion:
#
#   cd /gpfs/home/<username>/Desktop/Madagascar_migration/Scripts
#   mkdir -p logs ../MIDAS/logs ../MIDAS/Outputs
#
#   for S in 0.05 0.12 0.19 0.26 0.33 0.40; do
#     sbatch --export=ALL,DROUGHT_SCALE_FIXED=$S,NUM_DRAWS=16,N_REALISATIONS=1,\
# LOCAL_DEMAND_COUPLING=0.25,DROUGHT_VARIABILITY=1,DISTRESS_ARM=6 \
#            --job-name=dsweep_$S submit_drought_sweep.sh
#   done
#
# Each writes to its own ./Outputs_..._DScale###/ folder (DScale050 for 0.05,
# DScale400 for 0.40 -- three digits, because two would collide 0.05 with
# 0.5).
#
# NO MIDAS_END_YEAR. Deliberate: the runs go to the readParameters default
# (2025) and buildNextRound caps its census metrics at 2018 exactly as it did
# for the previous round. Scoring to a different horizon would confound "the
# fix changed the answer" with "the scoring window changed the answer", and
# the whole point is to isolate the first. For the same reason, do NOT touch
# FI_BURNIN_YEAR = 2000 in buildNextRound.m before this sweep is scored --
# revisit it afterwards.
#
# SIZING
# 16 draws x 1 realisation = 16 parfor iterations on 20 workers, so all run
# concurrently in a single array task. Calibration-horizon runs are roughly
# 1.8 GB each (against ~12 GB at the 2085 projection horizon), so 16
# concurrent needs about 29 GB; 90G is generous. Expect a few hours, not the
# 12 requested -- SLURM charges actual use.
#
# The six submissions are independent and will queue together, so the whole
# sweep is one batch of wall clock rather than six.
#
# WHAT TO DO WITH THE RESULT
# Download each DScale### folder, then run buildNextRound with results_set
# pointed at it (it reads D:/MIDAS outputs/<results_set>/MC*.mat). Compare
# each sweep point against the three targets: the 2018 RGPH OD matrices, the
# urban/rural fraction, and food insecurity at 3.8/12 = 0.317 of agricultural
# timesteps. Pick the scale value that lands FI nearest target without
# degrading the OD fit.
#
# CAVEAT TO STATE IN THE METHODS. This re-centres the one parameter known to
# be contaminated. If the missing forcing was also absorbed by migration cost
# or utility variance, those stay wrong and the re-centred value partly
# inherits their error. It is a defensible correction, not a substitute for
# recalibration, and should be described as such.
# ============================================================

set -euo pipefail

ARRAY_JOB_ID="${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID}"
TASK_ID="${SLURM_ARRAY_TASK_ID:-0}"
echo "Job ${ARRAY_JOB_ID}, task ${TASK_ID} started at $(date)"
echo "Running on node: $(hostname)"
echo "CPUs allocated: ${SLURM_CPUS_PER_TASK}"

# Fail fast if the sweep value was not passed. Without it every submission
# would run the narrowed bounds unchanged and write to the same folder --
# six identical batches wearing six different names.
: "${DROUGHT_SCALE_FIXED:?DROUGHT_SCALE_FIXED not set -- pass --export=ALL,DROUGHT_SCALE_FIXED=0.19}"
export DROUGHT_SCALE_FIXED

export NUM_DRAWS="${NUM_DRAWS:-16}"
export N_REALISATIONS="${N_REALISATIONS:-1}"
export LOCAL_DEMAND_COUPLING="${LOCAL_DEMAND_COUPLING:-0.25}"
export DROUGHT_VARIABILITY="${DROUGHT_VARIABILITY:-1}"
export DISTRESS_ARM="${DISTRESS_ARM:-6}"
export AGENT_TRACE="${AGENT_TRACE:-0}"

# Expectation-formation rule (formExpectation.m arms 0-4). Left unset the
# runner uses the readParameters.m default; an invalid value is now a hard
# error rather than a silent reset to arm 0. Echoed below so every log
# records which decision rule produced the campaign -- arm 0 samples the
# agent's whole history uniformly and is close to blind to recent drought.
if [[ -n "${EXPECTATION_ARM:-}" ]]; then export EXPECTATION_ARM; fi

echo "Drought scale (pinned): ${DROUGHT_SCALE_FIXED}"
echo "Draws:                  ${NUM_DRAWS} x ${N_REALISATIONS} realisation(s)"
echo "Demand coupling:        ${LOCAL_DEMAND_COUPLING}"
echo "Drought variability:    ${DROUGHT_VARIABILITY}"
echo "Distress arm:           ${DISTRESS_ARM}"
echo "Agent trace:            ${AGENT_TRACE}"
echo "Expectation arm:        ${EXPECTATION_ARM:-<readParameters default>}"

module load matlab/2024b

cd "$SLURM_SUBMIT_DIR/../MIDAS"
echo "Working directory: $(pwd)"

for f in run_calibration.m runMIDASExperiment_parallel.m \
         Application_Specific_MIDAS_Code/readParameters.m; do
    [[ -f "$f" ]] || { echo "MISSING: $f" >&2; exit 1; }
done

# The sweep is meaningless without the calibrated bounds -- the whole design
# is "hold everything else at its calibrated value". Fresh wide priors would
# turn this into a tiny unfocused calibration round instead.
if [[ ! -f "Calibration Testing/updatedMCParams.mat" && ! -f "updatedMCParams.mat" ]]; then
    echo "FATAL: no updatedMCParams.mat. The sweep needs the calibrated bounds" >&2
    echo "       for every parameter other than droughtScaleFactor." >&2
    exit 1
fi

# The repaired geometry cache is the point of the exercise. Without it
# createMapFromSHP rejects the truncated cache, falls through to rebuild, and
# dies in vec2mtx on MATLAB 2024b -- so check it is here and is the repaired
# copy before spending a node on it.
CACHE="Data/Mada Admin 2/Admin_2_lat_lon.mat"
[[ -f "$CACHE" ]] || { echo "MISSING: $CACHE -- copy the REPAIRED cache across" >&2; exit 1; }

mkdir -p Outputs logs

matlab -batch "run_calibration"

echo "Task ${TASK_ID} finished at $(date)"
