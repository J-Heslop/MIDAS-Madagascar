"""
extend_spei_projections.py
==========================
Extends the observed CEDA SPEI-6 timeseries (1981-2022) to 2085 for SSP2 and
SSP5, producing two CSV files that MIDAS loads based on modelParameters.sspScenario.

WORKFLOW
--------
This script is the second step of a two-step process:

  Step 1 (MATLAB): extract_grma_spei_stats.m
    Reads the GRMA SPEI-6 projected NetCDF files, spatially aggregates drought
    intensity and frequency to each ADM2 region, and writes
    Data/GRMA_SPEI_deltas.csv — the region-specific SPEI shift deltas at the
    2050 and 2085 time horizons for SSP2-4.5 and SSP5-8.5.

  Step 2 (this script):
    Uses those region-specific deltas to anchor the SPEI projections, combined
    with the observed per-region per-month trend from CEDA 1981-2022 data and
    resampled historical variability.

PROJECTION METHOD
-----------------
For each region × calendar month (12 months, all used — MIDAS picks the
harvest month per crop from the utility_layers_v1.csv drought_harvest_month col):

  1. Fit a linear trend to observed CEDA SPEI-6 values (1981-2022).
  2. De-trend to get the inter-annual variability pool (residuals).
  3. For 2023-2085, project as:

       SPEI(yr) = trend_at_2022
                + obs_slope × (yr - 2022)         [observed trend continues]
                + grma_delta(region, ssp, yr)      [GRMA-derived mean shift]
                + noise                            [resampled residual]

     where grma_delta is linearly interpolated between:
       yr ≤ 2022 → 0
       yr = 2050 → delta from GRMA at 2050
       yr = 2085 → delta from GRMA at 2085
     and extrapolated linearly beyond 2085 if needed.

  4. Clip to [-3.5, 2.5] (physically plausible SPEI range).

FALLBACK
--------
If Data/GRMA_SPEI_deltas.csv does not exist (i.e. extract_grma_spei_stats.m
has not yet been run), the script falls back to uniform IPCC-derived additional
drying rates (SSP2: +0.004/yr, SSP5: +0.010/yr) and prints a warning.

OUTPUTS (written to Data/)
--------------------------
  CEDA_SPEI_SSP2.csv  — 1981-2085, 22 regions, SPEI-6 all 12 months
  CEDA_SPEI_SSP5.csv  — same, SSP5-8.5 projection

Usage:
  python extend_spei_projections.py
  (run from the MIDAS-Madagascar project root)
"""

import csv
import os
import random
import sys

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------

CEDA_CSV      = os.path.join('..', 'ISF - Migration modelling consultancy',
                              'Datasets', 'CEDA_SPEI.csv')
GRMA_DELTAS   = os.path.join('.', 'Data', 'GRMA_SPEI_deltas.csv')
OUT_DIR       = os.path.join('.', 'Data')
OUT_SSP2      = os.path.join(OUT_DIR, 'CEDA_SPEI_SSP2.csv')
OUT_SSP5      = os.path.join(OUT_DIR, 'CEDA_SPEI_SSP5.csv')

OBS_START  = 1981
OBS_END    = 2022
PROJ_START = 2023
PROJ_END   = 2085

MISSING    = -999.99   # CEDA fill value
SPEI_MIN   = -3.5
SPEI_MAX   =  2.5

# Fallback rates (SPEI units/year of ADDITIONAL drying beyond observed trend).
# Only used if GRMA_SPEI_deltas.csv is absent.
FALLBACK_EXTRA = {'SSP2': 0.004, 'SSP5': 0.010}

SPEI6_PREFIX = 'madagascar_Africa_spei06'
RANDOM_SEED  = 42

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

def linreg(xs, ys):
    n = len(xs)
    sx = sum(xs); sy = sum(ys)
    sxx = sum(x*x for x in xs); sxy = sum(x*y for x, y in zip(xs, ys))
    denom = n * sxx - sx * sx
    if abs(denom) < 1e-12:
        return 0.0, sy / n
    slope     = (n * sxy - sx * sy) / denom
    intercept = (sy - slope * sx) / n
    return slope, intercept

def interp_delta(yr, d0, d50, d85):
    """Linearly interpolate GRMA delta at year yr given anchors at 2022, 2050, 2085."""
    if yr <= OBS_END:
        return 0.0
    elif yr <= 2050:
        t = (yr - OBS_END) / (2050 - OBS_END)
        return d50 * t
    elif yr <= 2085:
        t = (yr - 2050) / (2085 - 2050)
        return d50 + (d85 - d50) * t
    else:
        # Extrapolate at the 2050→2085 rate beyond 2085
        rate = (d85 - d50) / (2085 - 2050)
        return d85 + rate * (yr - 2085)

def clamp(v, lo, hi):
    return max(lo, min(hi, v))

# ---------------------------------------------------------------------------
# LOAD GRMA REGIONAL DELTAS (if available)
# ---------------------------------------------------------------------------

grma_deltas = {}   # grma_deltas[region] = {'SSP2': {2050: x, 2085: y}, 'SSP5': ...}

if os.path.exists(GRMA_DELTAS):
    print(f"Loading GRMA regional deltas from {GRMA_DELTAS} ...")
    with open(GRMA_DELTAS, newline='', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            reg = row['NAME_2']
            grma_deltas[reg] = {
                'SSP2': {2050: float(row['delta_ssp2_2050']),
                         2085: float(row['delta_ssp2_2085'])},
                'SSP5': {2050: float(row['delta_ssp5_2050']),
                         2085: float(row['delta_ssp5_2085'])},
            }
    print(f"  Loaded deltas for {len(grma_deltas)} regions.")

    # Print summary
    for ssp in ('SSP2', 'SSP5'):
        d2050 = [grma_deltas[r][ssp][2050] for r in grma_deltas]
        d2085 = [grma_deltas[r][ssp][2085] for r in grma_deltas]
        print(f"  {ssp}: mean delta 2050={sum(d2050)/len(d2050):+.4f}, "
              f"2085={sum(d2085)/len(d2085):+.4f}  "
              f"(range 2085: {min(d2085):+.4f} to {max(d2085):+.4f})")
    use_grma = True
else:
    print(f"WARNING: {GRMA_DELTAS} not found.")
    print("         Run extract_grma_spei_stats.m in MATLAB first to generate it.")
    print(f"         Falling back to uniform additional drying rates: "
          f"SSP2={FALLBACK_EXTRA['SSP2']}/yr, SSP5={FALLBACK_EXTRA['SSP5']}/yr")
    use_grma = False

# ---------------------------------------------------------------------------
# READ OBSERVED CEDA DATA
# ---------------------------------------------------------------------------

print(f"\nReading {CEDA_CSV} ...")
if not os.path.exists(CEDA_CSV):
    sys.exit(f"ERROR: cannot find {CEDA_CSV}. Run from the MIDAS-Madagascar project root.")

with open(CEDA_CSV, newline='', encoding='utf-8') as f:
    reader     = csv.reader(f)
    header_raw = next(reader)
    rows_raw   = list(reader)

regions   = [r[0] for r in rows_raw]
col_index = {name: i for i, name in enumerate(header_raw)}

# Parse observed SPEI-6 Africa into obs[region][month][year] = value
obs = {reg: {m: {} for m in range(1, 13)} for reg in regions}

for yr in range(OBS_START, OBS_END + 1):
    for mo in range(1, 13):
        col_name = f'{SPEI6_PREFIX}:{mo:02d}-{yr}'
        if col_name not in col_index:
            continue
        ci = col_index[col_name]
        for row in rows_raw:
            try:
                val = float(row[ci])
            except (ValueError, IndexError):
                val = MISSING
            obs[row[0]][mo][yr] = val

print(f"Observed data loaded for {len(regions)} regions, {OBS_START}-{OBS_END}.")

# ---------------------------------------------------------------------------
# FIT TRENDS AND GENERATE PROJECTIONS
# ---------------------------------------------------------------------------

random.seed(RANDOM_SEED)

proj = {ssp: {reg: {m: {} for m in range(1, 13)} for reg in regions}
        for ssp in ('SSP2', 'SSP5')}

for reg in regions:
    for mo in range(1, 13):
        valid = sorted((yr, v) for yr, v in obs[reg][mo].items()
                       if v != MISSING and v > -100)

        if len(valid) < 5:
            for ssp in ('SSP2', 'SSP5'):
                for yr in range(PROJ_START, PROJ_END + 1):
                    proj[ssp][reg][mo][yr] = 0.0
            continue

        xs = [p[0] for p in valid]
        ys = [p[1] for p in valid]
        slope, intercept = linreg(xs, ys)
        trend_at_2022    = slope * OBS_END + intercept
        residuals        = [y - (slope * x + intercept) for x, y in zip(xs, ys)]

        for ssp in ('SSP2', 'SSP5'):
            for yr in range(PROJ_START, PROJ_END + 1):

                # Observed trend component (per-month, per-region)
                obs_trend = slope * (yr - OBS_END)

                # GRMA regional delta component (anchored at 2050 and 2085)
                if use_grma and reg in grma_deltas:
                    d50 = grma_deltas[reg][ssp][2050]
                    d85 = grma_deltas[reg][ssp][2085]
                    grma_component = interp_delta(yr, 0.0, d50, d85)
                else:
                    # Fallback: uniform additional drying rate
                    extra = FALLBACK_EXTRA[ssp]
                    grma_component = -extra * (yr - OBS_END)

                noise = random.choice(residuals)
                raw   = trend_at_2022 + obs_trend + grma_component + noise
                proj[ssp][reg][mo][yr] = clamp(raw, SPEI_MIN, SPEI_MAX)

print("Projections computed.")

# ---------------------------------------------------------------------------
# BUILD AND WRITE OUTPUT CSVs
# ---------------------------------------------------------------------------

out_cols = []
for yr in range(OBS_START, PROJ_END + 1):
    for mo in range(1, 13):
        out_cols.append(f'{SPEI6_PREFIX}:{mo:02d}-{yr}')

print(f"Output: {len(out_cols)} columns (SPEI-6, months 1-12, years {OBS_START}-{PROJ_END})")

for ssp, out_path in (('SSP2', OUT_SSP2), ('SSP5', OUT_SSP5)):
    print(f"\nWriting {out_path} ...")
    with open(out_path, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(['name'] + out_cols)
        for reg in regions:
            row_out = [reg]
            for col in out_cols:
                _, mm_yyyy = col.split(':')
                mo_s, yr_s = mm_yyyy.split('-')
                mo = int(mo_s); yr = int(yr_s)
                val = obs[reg][mo].get(yr, MISSING) if yr <= OBS_END else proj[ssp][reg][mo][yr]
                row_out.append(f'{val:.6f}')
            writer.writerow(row_out)
    print(f"  Done: {out_path}")

print("\nFinished. CEDA_SPEI_SSP2.csv and CEDA_SPEI_SSP5.csv written to Data/.")
if use_grma:
    print("Projections anchored using GRMA region-specific SPEI-6 deltas.")
else:
    print("NOTE: Projections used fallback rates — re-run after extract_grma_spei_stats.m.")
