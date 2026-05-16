"""
apply_observed_drought.py
=========================
Produces Data/observed_spei_harvest.csv, a region x crop-year table of raw
SPEI-6 values at each MIDAS crop's harvest month for the observation
period 1985-2022.

This file is consumed by createUtilityLayers.m at MATLAB runtime. The
yield-factor perturbation is applied IN MATLAB, not here, so that
modelParameters.droughtScaleFactor can be a calibration parameter:

    yield_factor = clip( GRMA_baseline + droughtScaleFactor * SPEI6,
                         drought_min_yield, 1.0 )

This is the same one-liner the existing Markov-chain projection logic
uses, just sourced from observed SPEI for 1985-2022 instead of sampled
SPEI for 2023+. The calibration learns the right droughtScaleFactor from
observed migration responses to observed droughts, and that learned
value carries through to the projection period unchanged.

Inputs
------
  ISF/.../CEDA_SPEI.csv             rows = 22 regions, cols = SPEI03/06 monthly 1981-2022
  Data/utility_layers_v1.csv        grma_crop, drought_harvest_month, drought_min_yield

Output
------
  Data/observed_spei_harvest.csv
      Columns:  NAME_2, rice_north_y1985 ... rice_north_y2022,
                        rice_south_y1985 ... rice_south_y2022,
                        maize_y1985      ... maize_y2022,
                        cassava_y1985    ... cassava_y2022
      Rows:     22 regions, in shapefile / model order
      Values:   raw SPEI-6 at that layer's harvest month for that year
                Missing months (early 1981 cannot have a 6-month accumulation)
                are recorded as 0.0 (climatology = no perturbation), which
                lets MATLAB skip the perturbation cleanly.

Each MIDAS ag layer gets its own column even when two layers share the
same GRMA crop, because rice_north and rice_south have different harvest
months (April vs June). MATLAB looks up by layer name.

Diagnostics
-----------
Prints a per-layer, per-region summary of SPEI-6 for known kere drought
years in the south so the operator can sanity-check before re-running
calibration.
"""

import os
import re
import csv

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR     = os.path.dirname(os.path.abspath(__file__))
CEDA_SPEI_CSV  = ("C:\\Users\\Jack\\OneDrive - University of East Anglia\\"
                  "ISF - Migration modelling consultancy\\Datasets\\CEDA_SPEI.csv")
DATA_DIR       = os.path.join(SCRIPT_DIR, 'Data')
UTILITY_LAYERS = os.path.join(DATA_DIR, 'utility_layers_v1.csv')
OUTPUT_CSV     = os.path.join(DATA_DIR, 'observed_spei_harvest.csv')

OBS_FIRST_YEAR = 1985
OBS_LAST_YEAR  = 2022

SPEI6_PREFIX   = 'madagascar_spei06'
SPEI_MISSING   = -50.0          # values <= this are sentinels (-999.99 in source)
SPEI_FILL      = 0.0            # what to write for missing months (climatology)

DIAGNOSTIC_YEARS   = [1991, 1997, 2002, 2013, 2016, 2018, 2021]
DIAGNOSTIC_REGIONS = ['Androy', 'Anosy', 'Atsimo-Andrefana']


# ---------------------------------------------------------------------------
# Loaders
# ---------------------------------------------------------------------------
def load_ceda_spei6():
    """Return {region: {(year, month): spei6}}, dropping -999.99 sentinels."""
    spei = {}
    with open(CEDA_SPEI_CSV, newline='') as f:
        reader = csv.reader(f)
        header = next(reader)

        col_to_date = {}
        pat = re.compile(rf'^{re.escape(SPEI6_PREFIX)}:(\d\d)-(\d{{4}})$')
        for i, h in enumerate(header):
            m = pat.match(h)
            if m:
                col_to_date[i] = (int(m.group(2)), int(m.group(1)))  # (year, month)

        if not col_to_date:
            raise RuntimeError(f'No SPEI-6 columns matched prefix "{SPEI6_PREFIX}" '
                               f'in {CEDA_SPEI_CSV}')

        for row in reader:
            region = row[0].strip()
            entries = {}
            for i, ym in col_to_date.items():
                v = row[i].strip()
                try:
                    val = float(v)
                except ValueError:
                    continue
                if val <= SPEI_MISSING:
                    continue
                entries[ym] = val
            spei[region] = entries

    print(f'Loaded SPEI-6 for {len(spei)} regions, {len(col_to_date)} monthly cells per region.')
    return spei


def load_utility_layers():
    """Return list of (layer_name, harvest_month) for every ag layer with a grma_crop.

    Each ag layer gets its own column in the output, even when two layers share
    the same GRMA crop, because their harvest months may differ (rice_north
    April vs rice_south June)."""
    layers = []
    region_order = None
    with open(UTILITY_LAYERS, newline='', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        for row in reader:
            crop = (row.get('grma_crop') or '').strip().strip('"').lower()
            if not crop:
                continue
            try:
                hm = int(row['drought_harvest_month'])
            except (TypeError, ValueError):
                continue
            layers.append((row['name'], crop, hm))
    return layers


def load_region_order_from_grma():
    """Pick up the 22-region shapefile order from any GRMA CSV.

    This guarantees the output CSV's row order matches what
    createUtilityLayers.m expects when iterating locations."""
    grma_any = os.path.join(DATA_DIR, 'GRMA_yield_rice_SSP5.csv')
    regions = []
    with open(grma_any, newline='') as f:
        reader = csv.DictReader(f)
        for row in reader:
            regions.append(row['NAME_2'].strip())
    return regions


# ---------------------------------------------------------------------------
# Build output
# ---------------------------------------------------------------------------
def build_table(spei, layers, region_order):
    """Return (header_row, [data_rows])."""
    header = ['NAME_2']
    for layer_name, _crop, _hm in layers:
        for y in range(OBS_FIRST_YEAR, OBS_LAST_YEAR + 1):
            header.append(f'{layer_name}_y{y}')

    rows = []
    for region in region_order:
        row = [region]
        for layer_name, crop, hm in layers:
            for y in range(OBS_FIRST_YEAR, OBS_LAST_YEAR + 1):
                val = spei.get(region, {}).get((y, hm))
                if val is None:
                    val = SPEI_FILL
                row.append(f'{val:.6f}')
        rows.append(row)
    return header, rows


def write_output(header, rows):
    with open(OUTPUT_CSV, 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)
    print(f'Wrote {OUTPUT_CSV} ({len(rows)} regions x {len(header)-1} cells per region)')


# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------
def print_diagnostics(spei, layers):
    print('\n' + '=' * 72)
    print('DIAGNOSTIC: SPEI-6 at harvest month, southern regions, kere years.')
    print('Negative values = drought; values < -1 conventionally moderate,')
    print('< -1.5 severe, < -2 extreme.')
    print('=' * 72)
    for layer_name, crop, hm in layers:
        print(f'\n  Layer: {layer_name} (crop={crop}, harvest_month={hm})')
        for region in DIAGNOSTIC_REGIONS:
            samples = []
            for y in DIAGNOSTIC_YEARS:
                v = spei.get(region, {}).get((y, hm))
                if v is None:
                    continue
                tag = ''
                if v < -1.5:
                    tag = '  <-- severe drought'
                elif v < -1.0:
                    tag = '  <-- drought'
                samples.append(f'      {y}: SPEI6={v:+.2f}{tag}')
            if samples:
                print(f'    {region}:')
                print('\n'.join(samples))


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
def main():
    spei         = load_ceda_spei6()
    layers       = load_utility_layers()
    region_order = load_region_order_from_grma()

    print(f'\nAg layers found: {[L[0] for L in layers]}')
    print(f'Region order (from GRMA CSV): {region_order[:3]} ... {region_order[-3:]}')

    header, rows = build_table(spei, layers, region_order)
    write_output(header, rows)
    print_diagnostics(spei, layers)

    print('\nDone. Now run MIDAS calibration; createUtilityLayers.m will read')
    print(f'  {os.path.basename(OUTPUT_CSV)}')
    print('and apply yieldFactor += droughtScaleFactor * SPEI6 per year.')


if __name__ == '__main__':
    main()
