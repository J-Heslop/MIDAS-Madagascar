# MIDAS-Madagascar: Project Reference

**For:** Claude Project handoff
**Repository:** https://github.com/J-Heslop/MIDAS-Madagascar
**Working branch:** `Enable_time_varying_inputs` (branched from `UEA`)
**Upstream (Cornell authors):** https://github.com/earth-andrew/MIDAS-Madagascar
**Consultant:** Jack Heslop, University of East Anglia (f.heslop@uea.ac.uk)

---

## 1. Project Overview

The goal is to adapt the **MIDAS agent-based model** (developed at Cornell) to simulate climate-driven internal migration in **Madagascar**, focusing on drought impacts on southern agricultural communities. The model runs from a 1985 base year through to 2085, covering a historical calibration period (1985–2022) and two future scenarios (SSP2 and SSP5).

Two parallel extensions are being implemented:
1. **Time-varying drought** — modulate agricultural utility layers with SPEI-6 observations and projections
2. **Time-varying demography** — update survival and fertility rates over time using WCDE SSP projections

---

## 2. Repository Structure

```
MIDAS-Madagascar/
├── Core_MIDAS_Code/          # Cornell's core — edit minimally
│   ├── midasMainLoop.m       # ← MODIFIED (time-varying demography)
│   ├── buildWorld.m          # unchanged — .^ is element-wise, works on 4D
│   └── createMapFromSHP.m    # assigns matrixID = shapefile feature order
├── Application_Specific_MIDAS_Code/   # our code — edit freely
│   ├── readParameters.m      # ← MODIFIED (start/end year, SSP scenario, file paths)
│   ├── buildDemography.m     # ← MODIFIED (time-varying 4D array loading)
│   └── createUtilityLayers.m # next target — SPEI drought modulation
├── Override_Core_MIDAS_Code/
│   └── createUtilityLayers.m # override version — also needs SPEI changes
├── Data/
│   ├── survival_SSP2.csv     # ← NEW — annual mortality by age/sex, 1950–2095
│   ├── survival_SSP5.csv     # ← NEW
│   ├── fertility_SSP2.csv    # ← NEW — annual births/1000 women by age, 1950–2095
│   ├── fertility_SSP5.csv    # ← NEW
│   ├── 1985_MDG_GHSPop_totals_by_region.csv  # ← NEW — GHS-POP at ADM2 (base year)
│   ├── Mada Admin 2/Admin_2_lat_lon.shp       # shapefile — location ordering
│   └── age_specific_params.xls                # existing age preference params
├── Extract SPEI from CEDA.jl  # Julia script — debugged, extracts SPEI to ADM2 CSV
└── PROJECT_REFERENCE.md       # this file
```

---

## 3. Key Architecture Decisions

### 3.1 Simulation time: start/end year instead of numCycles

**Decision:** Replace the abstract `numCycles` parameter with `startYear` / `endYear`. `numCycles` is now derived as `endYear - startYear`.

**Why:** All input data (SPEI, WCDE demography, GHS_POP) is anchored to real calendar years. A `currentYear` variable computed inside the main loop is the single key for indexing all time-varying data consistently.

**Key formula** (in `midasMainLoop.m`):
```matlab
currentYear = modelParameters.startYear + ...
    max(0, indexT - modelParameters.spinupTime) / modelParameters.cycleLength;
tIdx = min(max(1, round(currentYear) - modelParameters.startYear + 1), ...
           size(demographicVariables.survivalRate, 4));
```
During spinup (`indexT <= spinupTime`), `currentYear` is clamped to `startYear`.

### 3.2 Time-varying demography: auto-detect from file structure

**Decision:** `buildDemography.m` checks whether the survival/fertility CSV contains a `Year` column. If yes → 4D arrays; if no → static behaviour preserved via a size-1 time dimension.

**Why:** Avoids a flag that could get out of sync with the file. The data drives the behaviour. Backward compatible with any existing static input files.

**Array shapes after change:**
- `demographicVariables.survivalRate`: `(location × age × sex × time)` — was `(location × age × sex)`
- `demographicVariables.fertilityRate`: `(location × age × time)` — was `(location × age)`

**Switching scenarios:** Change one line in `readParameters.m`:
```matlab
modelParameters.sspScenario = 'SSP2';  % or 'SSP5'
```
This automatically selects `Data/survival_SSP2.csv` and `Data/fertility_SSP2.csv`.

### 3.3 National-level demographics applied uniformly across ADM2

**Decision:** WCDE projections are national-level (Madagascar). These are applied uniformly to all 22 Admin 2 regions. No sub-national demographic variation.

**Why:** Using sub-national rates would create circularity — demographic distributions partly reflect historical migration patterns that MIDAS is endogenously modelling. The 1985 GHS-POP file provides the initial spatial distribution of agents; from that point onwards, births/deaths apply nationally.

### 3.4 Time-varying drought (NOT YET IMPLEMENTED)

**Plan:** Extend `createUtilityLayers.m` to load SPEI-6 time series (Admin 2 × time CSV from the Julia extraction script) and compute a per-location per-timestep multiplier:
```matlab
multiplier = max(0, 1 + alpha * max(0, -SPEI6(location, t)))
```
Apply to agricultural layers (layers 4 and 5) when building `utilityBaseLayers(location, layer, time)`. No changes to `midasMainLoop.m` — it already indexes `utilityBaseLayers` by `indexT` at line 51.

---

## 4. Code Changes Implemented

### `Application_Specific_MIDAS_Code/readParameters.m`

| What changed | Detail |
|---|---|
| `numCycles` | Now derived: `endYear - startYear` (100 years) |
| Added `startYear = 1985` | Base year — matches GHS-POP and CEDA SPEI coverage |
| Added `endYear = 2085` | End of projection period |
| Added `sspScenario = 'SSP2'` | Controls which demographic files are loaded |
| `survivalFile` | `'./Data/survival_SSP2.csv'` (dynamic via sspScenario) |
| `fertilityFile` | `'./Data/fertility_SSP2.csv'` (dynamic via sspScenario) |
| `popFile` | `'./Data/1985_MDG_GHSPop_totals_by_region.csv'` |
| Bug fix | Removed erroneous `* cycleLength` from `numCycles` formula |

### `Application_Specific_MIDAS_Code/buildDemography.m`

Survival loading block (lines 112–169) and fertility loading block (lines 171–223) both replaced. Key logic:
- Detects `Year` column → builds 4D/3D time-varying arrays via `interp1` over WCDE 5-year periods
- No `Year` column → existing static behaviour, reshaped to size-1 time dim
- Survival values clamped to `(0.001, 1]` to prevent `interp1` extrapolation going out of range
- Fertility values clamped to `>= 0`

### `Core_MIDAS_Code/midasMainLoop.m`

| What changed | Lines |
|---|---|
| Added `currentYear` and `tIdx` computation | After `for indexT = 1:` (lines 45–48) |
| Survival check — added `tIdx` as 4th subscript | Line 70 |
| Fertility check — added `tIdx` as 3rd subscript | Line 103 |

---

## 5. Data Files Created

All in `MIDAS-Madagascar/Data/`:

| File | Source | Format | Notes |
|---|---|---|---|
| `survival_SSP2.csv` | WCDE Age-Specific Survival Ratio | `Year, MaxAge, Male, Female` | Annual mortality prob = `1 - ratio^(1/5)` |
| `survival_SSP5.csv` | WCDE | same | |
| `fertility_SSP2.csv` | WCDE Age-Specific Fertility Rate | `Year, MinAge, MaxAge, Births` | Births per 1,000 women per year (divided by 5) |
| `fertility_SSP5.csv` | WCDE | same | |
| `1985_MDG_GHSPop_totals_by_region.csv` | GHS-POP rasters summed to ADM2 | MIDAS popFile format | Base year population for agent initialisation |

Source datasets (in `ISF - Migration modelling consultancy/Datasets/SSP demography/`):

| File | Contents |
|---|---|
| `wcde_data (3).csv` | Age-Specific Survival Ratio — SSP1–5, 1950–2100, 5-yr age groups, by sex |
| `wcde_data-age specific fertility rate.csv` | Age-Specific Fertility Rate — SSP2 & SSP5 only, 1950–2100 |
| `wcde_data-Population Size.csv` | Population by 5-yr age group — SSP2 & SSP5 |
| `wcde_data-Sex Ratio.csv` | Sex ratio by 5-yr age group — SSP2 & SSP5 |

---

## 6. Julia SPEI Extraction Script

**File:** `Extract SPEI from CEDA.jl`
**Status:** Debugged — three bugs fixed, not yet run to completion.

**What it does:** Reads CEDA SPEI NetCDF files (40 accumulation periods, 1981–2022), extracts mean SPEI per Madagascar Admin 2 region using GADM boundaries, writes to CSV at:
`ISF - Migration modelling consultancy/Datasets/CEDA_SPEI.csv`

**Bugs fixed:**
1. `produce_bool_mat` referenced `region.geom` as a global rather than accepting it as a parameter — caused wrong geometry for most regions. Fixed by adding `region_geom` as explicit 3rd argument.
2. Mean SPEI calculation used full global grid instead of masking to polygon pixels. Fixed with `masked_values = region_data_full[bool_mat]`.
3. NCDataset file handle leaked inside loop. Fixed with `close(draft_data)` before return.

**Still to do:** Run the script and verify the output CSV covers all 22 ADM2 regions.

---

## 7. Pending Work (in priority order)

### 7.1 Test the demography implementation
Run MIDAS with the new files and verify no MATLAB errors from the 4D array indexing. Key things to check:
- `buildWorld.m` applies `.^(1/cycleLength)` element-wise across all time slices — should work without changes
- `interp1` calls in `midasMainLoop.m` at lines 70 and 103 receive a 1×numAge vector (one time slice) — confirm the squeeze is implicit

### 7.2 Run SPEI extraction script
Run `Extract SPEI from CEDA.jl` to produce `CEDA_SPEI.csv`. Check all 22 regions are covered. The script targets SPEI-6 (accumulation period index to be confirmed from CEDA file metadata).

### 7.3 Implement SPEI drought modulation in createUtilityLayers.m
Target: `Application_Specific_MIDAS_Code/createUtilityLayers.m` (and the Override version).
Layers 4 and 5 (ag1 = small farm, ag2 = large farm) are the drought targets.
`climate_epsilon = 0.0` placeholder already exists.
Approach: load SPEI-6 CSV, compute `multiplier = max(0, 1 + alpha * max(0, -SPEI6))` per location per timestep, apply to ag layers when building `utilityBaseLayers`.

For future periods (post-2022): use GRMA SPEI-6 statistics to delta-shift or resample from historical distribution. GRMA files are at:
`ISF - Migration modelling consultancy/GRMA datasets/link/data/spei6/`
- `stats_SPEI6_baseline.nc`
- `stats_SPEI6_median_ssp245_2050.nc`
- `stats_SPEI6_median_ssp245_2085.nc`
- `stats_SPEI6_median_ssp585_2050.nc`
- `stats_SPEI6_median_ssp585_2085.nc`

### 7.4 Calibration
Once both extensions are running: calibrate `alpha` (drought sensitivity) against historical migration data. MIDAS currently has `modelParameters.numAgents = 85` (toy/testing value — increase for production runs).

### 7.5 Add vanilla and subsistence utility layers
Current layers: unskilled1, unskilled2, skilled, ag1 (small farm), ag2 (large farm), school.
Planned: replace ag1/ag2 with subsistence (rice/maize aggregate) and cash crop (vanilla) layers to better reflect Madagascar's southern agricultural economy.

---

## 8. MIDAS Architecture Notes

- **`utilityBaseLayers(location, layer, time)`** — pre-computed 3D array. Already indexed by `indexT` at `midasMainLoop.m` line 51. Natural integration point for drought.
- **`mapParameters.levelID = '_PCODE'`** — MIDAS identifies regions by fields containing `_PCODE` in the shapefile. Population CSV must use `ADM2_PCODE` column.
- **`matrixID`** — location index (1–22) assigned as the sequential order of features in the shapefile. Set in `createMapFromSHP.m`.
- **`modelParameters.cycleLength = 4`** — quarterly timesteps. Annual rates in demographic files are converted to per-timestep by `buildWorld.m` using `.^(1/cycleLength)`.
- **`modelParameters.spinupTime = 10`** — 10 quarterly timesteps (2.5 years) of spinup before agents make migration decisions.

---

## 9. Key External Datasets

| Dataset | Location | Used for |
|---|---|---|
| CEDA SPEI | Downloaded locally; NetCDF files | Historical drought signal 1981–2022 |
| GRMA SPEI-6 | `ISF.../GRMA datasets/link/data/spei6/` | Future drought (SSP2/SSP5) statistics |
| WCDE demography | `ISF.../Datasets/SSP demography/` | Survival & fertility projections |
| GHS-POP | Summed to ADM2; in `Data/` | 1985 base population |
| GADM Admin 2 | `MDG_GADM_2.gpkg` (used by Julia script) | Region boundaries for SPEI extraction |
| CNRE Archetypes | `ISF.../Write-up/CNRE_Archetypes.docx` | 7 livelihood archetypes for parameter heterogeneity |
