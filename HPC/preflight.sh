#!/bin/bash
# preflight.sh -- run from the MIDAS project root ON THE CLUSTER before submitting.
# Verifies that the files which silently change model behaviour are the current
# ones. Every check below corresponds to a campaign that was actually lost.
set -uo pipefail
fail=0
chk() { if eval "$2" >/dev/null 2>&1; then printf '  OK    %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fail=1; fi; }

echo "MIDAS pre-flight ($(pwd))"

# RUN FROM THE PROJECT ROOT. Every path below is relative, so from anywhere
# else -- most easily from HPC/ itself -- the file checks fail because the
# files are not there, not because they are stale. Worse, the NEGATIVE checks
# (! grep ...) PASS against a missing file, since grep finds nothing in a file
# that does not exist, so a wrong working directory produces a page of alarming
# failures mixed with meaningless passes. Fail fast and say what to do instead.
missing_root=0
for sentinel in Core_MIDAS_Code/midasMainLoop.m \
                Application_Specific_MIDAS_Code/readParameters.m \
                runMIDASExperiment_parallel.m; do
    [[ -f "$sentinel" ]] || missing_root=1
done
if [[ $missing_root -eq 1 ]]; then
    echo
    echo "  NOT IN THE PROJECT ROOT."
    echo "  This script checks paths relative to the MIDAS project root, so it"
    echo "  must be run from there:"
    echo
    if [[ "$(basename "$(pwd)")" == "HPC" ]]; then
        echo "      cd .. && bash HPC/preflight.sh"
    else
        echo "      cd <path to>/MIDAS && bash HPC/preflight.sh"
    fi
    echo
    echo "  Refusing to report on files it cannot see."
    exit 2
fi

# Every check below assumes the file exists. A negative check against a missing
# file passes, so guard the inputs rather than trusting the greps.
for required in Core_MIDAS_Code/choosePortfolio.m Core_MIDAS_Code/Agent.m \
                Core_MIDAS_Code/checkDistressTrigger.m Core_MIDAS_Code/buildWorld.m \
                Core_MIDAS_Code/formExpectation.m plot_distress_threshold.m \
                Data/utility_layers_v1.csv; do
    if [[ ! -f "$required" ]]; then
        printf '  FAIL  required file missing: %s\n' "$required"
        fail=1
    fi
done
chk "readParameters: expectationArm = 4"      "grep -qE 'modelParameters\.expectationArm *= *4' Application_Specific_MIDAS_Code/readParameters.m"
chk "choosePortfolio: annual CRRA aggregation" "grep -q 'ANNUAL AGGREGATION BEFORE THE VALUE FUNCTION' Core_MIDAS_Code/choosePortfolio.m"
chk "formExpectation: per-cycle shock draw"    "grep -q 'ONE SHOCK YEAR PER SIMULATED YEAR' Core_MIDAS_Code/formExpectation.m"
chk "midasMainLoop: outMigrationsAg output"    "grep -q 'outputs.outMigrationsAg' Core_MIDAS_Code/midasMainLoop.m"
chk "midasMainLoop: droughtStates output"      "grep -q 'outputs.droughtStates' Core_MIDAS_Code/midasMainLoop.m"
chk "buildWorld: droughtStates passthrough"    "grep -q 'utilityVariables.droughtStates' Core_MIDAS_Code/buildWorld.m"
chk "runner: expectationArm override"          "grep -q 'OVERRIDING bounds-file value' runMIDASExperiment_parallel.m"
chk "runner: RUN_TAG support"                  "grep -q 'RUN_TAG' runMIDASExperiment_parallel.m"
chk "geometry cache present"                   "test -f 'Data/Mada Admin 2/Admin_2_lat_lon.mat'"
chk "calibrated bounds present"                "test -f 'Calibration Testing/updatedMCParams.mat' -o -f updatedMCParams.mat"
chk "utility layers: cassava floor 0.25"       "grep -qE 'cassava.*0\.25' Data/utility_layers_v1.csv"

# BOUNDED FRACTIONAL SHORTFALL (2026-09-06). These two files must move
# together. midasMainLoop writes lastShortfall as a fraction of need and
# publishes distressShortfallFracThresh; checkDistressTrigger compares against
# that field and hard-errors if it is absent. A stale midasMainLoop paired with
# a current trigger fails loudly, but a current midasMainLoop paired with a
# stale trigger would compare a fraction against a cost and almost never fire,
# silently. Check both ends here so neither pairing reaches a node.
# ASPIRATION / ABILITY (2026-09-11). The single most consequential fix in this
# project. Previously, an agent with no affordable option anywhere had every
# location set to -Inf; sort() left them in natural order, the tie-break tested
# locationValue(1) == locationValue(2) -- true, since -Inf == -Inf -- and the
# agent was sent to a UNIFORMLY RANDOM location, paying a moving cost the
# credit test had just ruled unaffordable. Insolvency produced random walking
# instead of immobility. That inflated churn, deepened the debt driving it, and
# diluted the drought signal in every migration series with uniform noise.
#
# A stale choosePortfolio.m on a node reintroduces all of it silently: the run
# completes, the outputs look plausible, and nothing in any log says which
# version produced them. Check all three parts of the fix, since a partial copy
# is worse than none.
chk "choosePortfolio: aspiration/ability block"  "grep -q 'ASPIRATION vs ABILITY' Core_MIDAS_Code/choosePortfolio.m"
chk "choosePortfolio: tie-break guarded by isfinite" "grep -qE 'isfinite\(candidateValue\(indexSorted\(1\)\)\)' Core_MIDAS_Code/choosePortfolio.m"
chk "choosePortfolio: access codes paid for 'choice'" "grep -qE '^codesToPay = locationAccessCodes\{choice\};' Core_MIDAS_Code/choosePortfolio.m"
chk "choosePortfolio: no per-location trapped write" "! awk '/^ *for indexL/,/^end/' Core_MIDAS_Code/choosePortfolio.m | grep -qE 'agent\.trapped *='"
chk "Agent: mobilityClass property present"      "grep -q 'mobilityClass' Core_MIDAS_Code/Agent.m"
# STAGGERED DISTRESS COOLDOWN (2026-09-11). Without it, lastDistressMoveT
# defaults to -9999 for every agent, so the whole population becomes eligible
# in the same quarter that spinup ends and -- because the cooldown equals the
# annual cycle -- stays phase-locked there for the rest of the run. The trigger
# is correct; only the timing is an artefact of spinupTime.
chk "initializeAgent: staggered lastDistressMoveT" \
    "grep -q 'newAgent.lastDistressMoveT = spinQ + 1 - cdQ + randi' Core_MIDAS_Code/initializeAgent.m"

# SEASONAL ALIGNMENT OF THE FORECAST (2026-09-11). periodInCycleEvaluation must
# be offset by currentT. Labelled from 1 it made evaluation period 1 always
# "season 1" whatever quarter the agent was in, so the forecast was filled from
# history phase-shifted by mod(currentT,4) -- right one quarter in four. With
# lumpy layer income a two-quarter shift inverts the forecast, and national
# migration counts alternated by a factor of ~6 between adjacent quarters.
chk "choosePortfolio: forecast season offset by currentT" \
    "grep -qE 'periodInCycleEvaluation *= *mod\(currentT' Core_MIDAS_Code/choosePortfolio.m"

# ACCESS COSTS ARE ACTUALLY DEBITED (2026-09-11). locationAccessCodes was built
# with a (1,1:end-2) slice copied from the portfolio-row idiom. Applied to the
# access-code COLUMN that evaluates to 1:-1, i.e. empty, so codesToPay was
# always empty: access costs were never taken from wealth, accessCodesPaid
# never grew past initialisation, creditCollateral stayed frozen, and agents
# were charged in the valuation every quarter for layers they already held.
chk "choosePortfolio: access codes not truncated" \
    "! grep -qE 'locationAccessCodes\{indexL\} = portfolioAccessCodes\{indexSorted\(1\)\}\(1,1:end-2\)' Core_MIDAS_Code/choosePortfolio.m"

# YEAR GRID (2026-09-11). A model year is spinupTime + (y-1)*cycleLength + 1 ..
# spinupTime + y*cycleLength, per the layout of the yield data in
# createUtilityLayers.m:750. Four competing definitions existed; the ones
# anchored at t = 1 put the accounting year two quarters out of step with the
# drought year whenever spinupTime is not a multiple of cycleLength, so every
# accounting year spanned two drought years while being charged at one.
# See YEAR_CONVENTION_AUDIT.md.
chk "midasMainLoop: year-end on the spinup-anchored grid" \
    "grep -qE 'mod\(indexT - modelParameters\.spinupTime, modelParameters\.cycleLength\) == 0' Core_MIDAS_Code/midasMainLoop.m"
chk "midasMainLoop: no t=1-anchored year labels" \
    "! grep -qE 'startYear \+ floor\(\(indexT - 1\) / modelParameters\.cycleLength\)' Core_MIDAS_Code/midasMainLoop.m"
chk "midasMainLoop: spinup stripping removed" \
    "! grep -q 'firstPostSpinupYear' Core_MIDAS_Code/midasMainLoop.m"
chk "midasMainLoop: subsistence identity assertion present" \
    "grep -q 'midasMainLoop:subsistenceIdentity' Core_MIDAS_Code/midasMainLoop.m"
# The analysis script must move with the model: it used to compensate for the
# old array layout, so the old arithmetic would now drop three real model years.
chk "plot_distress_threshold: on the new grid" \
    "grep -qE 'nValid = numCycles;' plot_distress_threshold.m"
chk "midasMainLoop: exports mobilityClass"       "grep -q 'agentSummary.mobilityClass' Core_MIDAS_Code/midasMainLoop.m"

chk "midasMainLoop: fractional lastShortfall"  "grep -q 'distressShortfallFracThresh' Core_MIDAS_Code/midasMainLoop.m"
chk "midasMainLoop: distressShortfallAbs gone" "! grep -qE '^[^%]*modelParameters\.distressShortfallAbs *=' Core_MIDAS_Code/midasMainLoop.m"
chk "trigger: reads fractional threshold"      "grep -q 'distressShortfallFracThresh' Core_MIDAS_Code/checkDistressTrigger.m"
chk "trigger: hard-fails on missing threshold" "grep -q 'checkDistressTrigger:missingFracThresh' Core_MIDAS_Code/checkDistressTrigger.m"

# BOUNDS. Every sampled bound lives in updatedMCParams.mat and nowhere else.
# That file is binary, so it is checked here through the plain-text sidecar
# setMCBounds writes beside it. The sidecar is DERIVED: if it is missing or
# stale, re-run setMCBounds (with no arguments, to write it without changing
# anything) rather than editing it, because nothing reads it back and editing
# it would change nothing about what the model samples.
#
# REPORT BY DEFAULT, ASSERT ONLY ON REQUEST (2026-09-11).
#
# Everything above this point checks CODE STALENESS -- whether the tree on the
# node matches the tree the fixes were made in. That is always a failure.
# The values below are CAMPAIGN CONFIGURATION, and the right value depends on
# what is being run: a projection campaign wants subsistence pinned to the
# range identified from the ensemble, while a CALIBRATION campaign exists
# precisely to widen it and re-identify. Asserting fixed values made it
# impossible to submit a calibration run at all.
#
# So: print the values always -- the log should record what the campaign
# sampled -- but fail only when PREFLIGHT_BOUNDS=strict, which the projection
# submit script sets and the calibration one deliberately does not.
BOUNDS_MODE="${PREFLIGHT_BOUNDS:-report}"
BOUNDS_CSV=""
for c in "Calibration Testing/updatedMCParams_bounds.csv" "updatedMCParams_bounds.csv"; do
  [[ -f "$c" ]] && { BOUNDS_CSV="$c"; break; }
done
if [[ -z "$BOUNDS_CSV" ]]; then
  printf '  FAIL  bounds sidecar not found -- run setMCBounds to generate it\n'; fail=1
else
  printf '  OK    bounds sidecar: %s\n' "$BOUNDS_CSV"
  # $1 name, $2 lower, $3 upper. Compared numerically so 0.3 and 0.30 agree.
  bnd() {
    awk -F, -v n="$1" -v lo="$2" -v hi="$3" '
      NR==1{next}
      { gsub(/"/,""); if ($1==n) { found=1
          if (($2-lo)^2 < 1e-12 && ($3-hi)^2 < 1e-12) ok=1 } }
      END{ exit !(found && ok) }' "$BOUNDS_CSV"
  }
  # Print whatever the sidecar holds, so the log records what was sampled
  # regardless of mode. This is the part that is always useful.
  show_bnd() {
    awk -F, -v n="$1" '
      NR==1{next}
      { gsub(/"/,""); if ($1==n) { printf "  ----  %-42s [%s, %s]\n", $1, $2, $3; found=1 } }
      END{ if (!found) printf "  ----  %-42s ABSENT from the bounds file\n", n }' "$BOUNDS_CSV"
  }
  for nm in agentParameters.subsistence_costs \
            modelParameters.droughtScaleFactor \
            agentParameters.incomeShareFractionMean \
            modelParameters.distressShortfallFrac; do
    show_bnd "$nm"
  done

  if [[ "$BOUNDS_MODE" == "strict" ]]; then
    # Projection campaigns: these are settled and must not drift. The
    # subsistence range was identified CONDITIONAL on the other three sitting
    # where they sit, so they travel together or the identification does not
    # hold -- hence checked as a group.
    # 2.2-3.2 (2026-09-12), re-derived from the food-insecurity target after the
    # mobility-class and access-cost fixes changed the ensemble. Supersedes
    # 2.0-2.6, which came from the pre-fix ensemble and from a linear FI
    # relationship; the fit is logistic. If you are checking an OLD output set,
    # expect this to fail -- that set was sampled on the old range.
    chk "bounds: subsistence_costs [2.2, 3.2]"     "bnd agentParameters.subsistence_costs 2.2 3.2"
    chk "bounds: droughtScaleFactor [0.25, 0.42]"  "bnd modelParameters.droughtScaleFactor 0.25 0.42"
    chk "bounds: incomeShareFractionMean = 0.30"   "bnd agentParameters.incomeShareFractionMean 0.30 0.30"
    chk "bounds: distressShortfallFrac = 0.50"     "bnd modelParameters.distressShortfallFrac 0.50 0.50"
  else
    printf '  ----  bounds reported, not asserted (PREFLIGHT_BOUNDS=%s).\n' "$BOUNDS_MODE"
    printf '        Set PREFLIGHT_BOUNDS=strict to require the declared values;\n'
    printf '        a calibration campaign deliberately widens them.\n'
  fi
  # The sidecar is only evidence about the .mat if it was written from it.
  # A sidecar older than the .mat describes bounds that have since changed.
  for m in "Calibration Testing/updatedMCParams.mat" "updatedMCParams.mat"; do
    [[ -f "$m" ]] || continue
    chk "bounds sidecar is not older than the .mat" "[[ ! '$m' -nt '$BOUNDS_CSV' ]]"
    break
  done
fi

# The runner must NOT carry bounds of its own. A declaration block there would
# override the .mat after it loads, which reintroduces two sources of truth and
# silently un-pins DROUGHT_SCALE_FIXED sweeps.
chk "runner defines no bounds of its own"      "! grep -qE '^(declaredFixed|declaredRange) *=' runMIDASExperiment_parallel.m"

# DERIVED-FILE CONSISTENCY. drought_markov_params.csv and the correlation
# matrices are built at each layer's drought_harvest_month. If that column
# changes and they are not regenerated, the chain describes a different window
# from the one the model perturbs with -- silently. That is exactly how
# cassava spent the project sampling Feb-Jul while its parameters said
# otherwise. Compare the two files directly.
chk "derived drought files match the layer months" "python3 - <<'PY'
import csv,sys
lay={r['name']:r['drought_harvest_month'].strip()
     for r in csv.DictReader(open('Data/utility_layers_v1.csv'))
     if (r.get('grma_crop') or '').strip() and (r.get('drought_harvest_month') or '').strip()}
mk={}
for r in csv.DictReader(open('Data/drought_markov_params.csv')):
    mk[r['layer']]=r['harvest_month'].strip()
bad=[k for k,v in lay.items() if k not in mk or float(mk[k])!=float(v)]
if bad:
    print('STALE derived drought data for: '+', '.join(bad), file=sys.stderr)
    print('Run: python apply_observed_drought.py && python derive_drought_markov_params.py', file=sys.stderr)
    sys.exit(1)
PY"
echo
if [[ $fail -eq 0 ]]; then echo "All checks passed -- safe to submit."; else
  echo "ONE OR MORE CHECKS FAILED -- a stale file is present. Do not submit."; exit 1; fi
