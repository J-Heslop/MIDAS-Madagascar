"""
generate_grma_yield_timeseries.py
==================================
Converts GRMA crop yield loss projections (3 anchor points: baseline 2025,
SSP-2050, SSP-2085) into continuous annual yield-factor timeseries covering
1985-2085, for use by MIDAS createUtilityLayers.m.

Methodology
-----------
For each region × crop × scenario:
  - 1985-2025 : flat at the GRMA baseline value  (current observed conditions)
  - 2025-2050 : linear interpolation baseline → SSP-2050
  - 2050-2085 : linear interpolation SSP-2050 → SSP-2085

Values stored are YIELD FACTORS (0-1), i.e.  1 - yield_loss_fraction.
A value of 1.0 means no drought loss; 0.70 means 30% average yield loss.

Inter-annual variability (SPEI-based) is intentionally excluded here and will
be added as a separate model component once calibration is complete.

Outputs
-------
  Data/GRMA_yield_rice_SSP2.csv
  Data/GRMA_yield_rice_SSP5.csv
  Data/GRMA_yield_maize_SSP2.csv
  Data/GRMA_yield_maize_SSP5.csv
  Data/GRMA_yield_cassava_SSP2.csv
  Data/GRMA_yield_cassava_SSP5.csv

Format: rows = 22 ADM2 regions, columns = NAME_2 then y1985..y2085.

Source data
-----------
GRMA Madagascar (2026).  Rapport Méthodologique, Janvier 2026.
AXA Climate / Artelia Madagascar / BRGM.
Crop-specific Drought Index (CsDI) zonal statistics extracted by Jack Heslop.
"""

import os
import csv
import numpy as np

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
INPUT_DIR   = "C:\\Users\\Jack\\OneDrive - University of East Anglia\\ISF - Migration modelling consultancy\\GRMA datasets\\crop yield loss projections\\"

OUTPUT_DIR  = os.path.join(SCRIPT_DIR, 'Data')

# GRMA input file name templates (in INPUT_DIR)
FILE_TEMPLATE = 'test{crop} - {ssp} - {year}.csv'

CROPS    = ['Rice', 'Maize', 'Cassava']       # Peanut/Livestock: no MIDAS layer
SCENARIOS = ['SSP2', 'SSP5']
ANCHORS  = {
    'Baseline': 2025,
    'SSP2':     {'2050': 2050, '2085': 2085},
    'SSP5':     {'2050': 2050, '2085': 2085},
}

FIRST_YEAR = 1985
LAST_YEAR  = 2085
YEARS      = list(range(FIRST_YEAR, LAST_YEAR + 1))

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def read_grma_csv(path):
    """Return {NAME_2: mean_loss_fraction} from a GRMA zonal stats CSV."""
    data = {}
    with open(path, newline='', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            name = row['NAME_2'].strip()
            val  = float(row['_mean'])
            data[name] = val
    return data


def interpolate_series(baseline_val, ssp50_val, ssp85_val, years):
    """
    Build a loss-fraction timeseries for one region × crop × scenario.

    Anchor points (loss fractions):
      Year 2025: baseline_val
      Year 2050: ssp50_val
      Year 2085: ssp85_val

    Pre-2025: flat at baseline_val.
    2025-2050: linear.
    2050-2085: linear.
    """
    series = np.empty(len(years))
    for i, yr in enumerate(years):
        if yr <= 2025:
            loss = baseline_val
        elif yr <= 2050:
            t = (yr - 2025) / (2050 - 2025)
            loss = baseline_val + t * (ssp50_val - baseline_val)
        else:
            t = (yr - 2050) / (2085 - 2050)
            loss = ssp50_val + t * (ssp85_val - ssp50_val)
        series[i] = loss
    # Yield factor = 1 - loss, clamped to [0, 1]
    yield_factor = np.clip(1.0 - series, 0.0, 1.0)
    return yield_factor


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    # Load baseline once (shared across scenarios)
    baseline = {}
    for crop in CROPS:
        path = os.path.join(INPUT_DIR, FILE_TEMPLATE.format(
            crop=crop, ssp='Baseline', year='2025'))
        baseline[crop] = read_grma_csv(path)
        print(f'  Loaded baseline for {crop}: {len(baseline[crop])} regions')

    # Get the canonical region list from one file (consistent ordering)
    with open(os.path.join(INPUT_DIR,
              FILE_TEMPLATE.format(crop='Rice', ssp='Baseline', year='2025')),
              newline='', encoding='utf-8') as f:
        regions = [row['NAME_2'].strip() for row in csv.DictReader(f)]

    print(f'\nRegions ({len(regions)}): {regions}\n')

    for ssp in SCENARIOS:
        for crop in CROPS:
            # Load SSP anchor points
            path50 = os.path.join(INPUT_DIR,
                FILE_TEMPLATE.format(crop=crop, ssp=ssp, year='2050'))
            path85 = os.path.join(INPUT_DIR,
                FILE_TEMPLATE.format(crop=crop, ssp=ssp, year='2085'))

            ssp50 = read_grma_csv(path50)
            ssp85 = read_grma_csv(path85)

            # Build output rows
            header = ['NAME_2'] + [f'y{yr}' for yr in YEARS]
            rows   = [header]

            for region in regions:
                b_val   = baseline[crop][region]
                s50_val = ssp50[region]
                s85_val = ssp85[region]

                yf = interpolate_series(b_val, s50_val, s85_val, YEARS)

                row = [region] + [f'{v:.6f}' for v in yf]
                rows.append(row)

            # Write output
            out_name = f'GRMA_yield_{crop.lower()}_{ssp}.csv'
            out_path = os.path.join(OUTPUT_DIR, out_name)
            with open(out_path, 'w', newline='', encoding='utf-8') as f:
                writer = csv.writer(f)
                writer.writerows(rows)

            # Summary stats
            final_col = [float(rows[i][-1]) for i in range(1, len(rows))]
            print(f'  {out_name}: yield_factor at 2085 '
                  f'mean={np.mean(final_col):.3f}  '
                  f'min={np.min(final_col):.3f}  '
                  f'max={np.max(final_col):.3f}')

    print('\nDone. Files written to', OUTPUT_DIR)


if __name__ == '__main__':
    main()
