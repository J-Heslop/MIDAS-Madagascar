# Year-convention audit

**Date:** 2026-09-11
**Trigger:** the annual solvency block charges a whole accounting year at one
drought year's food-price inflation, when the accounting year spans two.

## The single cause

`spinupTime = 10` is not a multiple of `cycleLength = 4`. Four different
definitions of "model year" exist in the codebase, and they only agree when
spinup happens to be a whole number of cycles.

## The authoritative definition

`createUtilityLayers.m:750` lays out the yield surfaces:

```matlab
tStart = leadTime + (iCyc - 1) * modelParameters.cycleLength + 1;   % leadTime = spinupTime
```

and `:304` maps `yr = firstYear + iCyc - 1`. So the physical layout of the
drought and yield data defines:

```
model year y  occupies timesteps  spinupTime + (y-1)*cycleLength + 1  ..  spinupTime + y*cycleLength
model year y  IS calendar year    startYear + y - 1
```

Everything else must conform to this. It is already implemented, correctly, as
`agYFYearIndex` (`midasMainLoop.m:2172`).

---

## A. Sites that already use the authoritative convention

No change needed. Listed so they are not "fixed" by mistake.

| Site | What it does |
|---|---|
| `createUtilityLayers.m:750, 855` | lays out `agYF` / `utilityBaseLayers` |
| `createUtilityLayers.m:304` | `yr = firstYear + iCyc - 1` |
| `midasMainLoop.m:2172-2178` | `agYFYearIndex` — the canonical implementation |
| `midasMainLoop.m:780` | oracle yield lookup |
| `midasMainLoop.m:1159` | **quarterly** subsistence inflation (`subsistNow`) |
| `midasMainLoop.m:1352` | trace yield field |
| `midasMainLoop.m:1556` | **annual** buffer block yield (`agYFloc`) |
| `midasMainLoop.m:1794` | `calYear = startYear + iyB - 1` — correct calendar mapping |

---

## B. CHANGES MODEL BEHAVIOUR — fix first

Only these alter what the model computes. Everything in section C is labelling.

### B1. Year-end boundary — `midasMainLoop.m:1502`

```matlab
if mod(indexT, modelParameters.cycleLength) == 0        % WRONG: grid starts at t=1
```

Should start the grid at the end of spinup:

```matlab
if indexT > modelParameters.spinupTime && ...
   mod(indexT - modelParameters.spinupTime, modelParameters.cycleLength) == 0
```

**Effect.** With spinup 10, accounting years currently end at t = 12, 16, 20 …
while drought years run t = 11-14, 15-18, 19-22. Every accounting year after
the first therefore spans two drought years, but `fullCost` (`:1662`) charges
all four quarters at the *later* year's inflation. The identity the code relies
on — stated at `:1496`, that a wealth decline over the year equals annual
income falling short of annual subsistence — does not hold, because the sum of
four quarterly `subsistNow` debits (`:1159`, inflated per drought year) is not
`fullCost`.

Downstream of that: `need` → buffer drawdown → `shortfall` → `lastShortfall` →
the distress trigger. In a year when drought deepens, all are overstated; when
it eases, understated.

### B2. Annual bin index — `midasMainLoop.m:1504`

```matlab
yearIdx = indexT / modelParameters.cycleLength;         % WRONG
```

becomes `agYFYearIndex(indexT, modelParameters, nYearsTotal)`, so that
`foodInsecureCount_*`, `agentCount_*` and `bufferSum_all` (`:1846-1858`) are
binned on the same grid as the drought data that drives them.

### B3. Array sizing — `midasMainLoop.m:293`

```matlab
nYearsTotal = ceil(modelParameters.timeSteps / modelParameters.cycleLength);   % = spinup years + numCycles
```

becomes the number of model years, `(timeSteps - spinupTime) / cycleLength`,
i.e. `numCycles`.

### B4. Spinup stripping — `midasMainLoop.m:2004-2018`

```matlab
spinupYears = ceil(modelParameters.spinupTime / modelParameters.cycleLength);
firstPostSpinupYear = spinupYears + 1;
outputs.foodInsecureCount_ag = foodInsecureCount_ag(:, firstPostSpinupYear:end);
```

Delete. Under the authoritative convention year 1 *is* the first post-spinup
year, so there is nothing to strip. Stripping `ceil(10/4) = 3` columns
currently also discards the first two genuinely post-spinup quarters.

---

## C. LABELLING ONLY — outputs are misnamed, not miscomputed

### C1. Trace year column — `midasMainLoop.m:559, 1324`

```matlab
r.year = modelParameters.startYear + floor((indexT - 1) / modelParameters.cycleLength);
```

Counts spinup as real calendar time, so it runs **+2 years ahead** of the
forcing: drought applied as 2016 is reported as 2018, and a run configured to
`endYear 2025` labels its last year 2027. Replace with
`startYear + agYFYearIndex(indexT, ...) - 1`.

Only affects `agent_life_history.csv`, which came into use on 2026-09-11.

### C2. Console year — `midasMainLoop.m:1935`

```matlab
sim_timestep = indexT - modelParameters.spinupTime;
year = num2str(modelParameters.startYear + floor(sim_timestep / modelParameters.cycleLength));
```

Spinup-aware but off by one against the authoritative grid: gives year 1 only
three quarters (t = 11-13). Same replacement.

### C3. Drought figures — `make_drought_module_figure.m:164`, `make_drought_state_panel.m:118`

```matlab
years = modelParameters.startYear + (1:nSimYears);      % 1986 .. — off by one
```

Should be `startYear + (0:nSimYears-1)`, since `agYF` column 1 is `startYear`.

### C4. Plotting scripts — `Plotting/plot_layers.m:74, 95`, `Plotting/plot_population.m:41, 100, 125`

```matlab
yearAxis = startYear + (0:T-1) / cycleLength;      % treats spinup as real time
xline(startYear + spinupTime, '--k', 'Label','Spinup end');
```

The x-axis is shifted, and the "Spinup end" marker is drawn at
`startYear + 10 = 1995` — `spinupTime` is in QUARTERS, so it should be
`startYear + spinupTime/cycleLength = 1987.5`. The marker is eight years out.

### C5. Demographics index — `midasMainLoop.m:361-363`

```matlab
currentYear = startYear + max(0, indexT - spinupTime) / cycleLength;
tIdx = min(max(1, round(currentYear) - startYear + 1), ...);
```

A fourth convention: spinup-aware but rounded, so the survival/fertility year
can change mid-model-year. Needs a decision rather than a mechanical fix —
whether demographics should step on the same grid as everything else.

---

## D. Analysis scripts that compensate for the old behaviour

`plot_distress_threshold.m:427-437` and its `quarterlyToAnnual` helper were
written to work around section B, and the helper's comment documents the
two-quarter offset explicitly. Once B is fixed these become wrong in the
opposite direction and must be updated together:

```matlab
spinupYears = ceil(spinupTime / cyc);
nValid      = floor(nT / cyc) - spinupYears;
years       = startYear + (1:nValid);
```

becomes `nValid = (nT - spinupTime)/cyc` and `years = startYear + (0:nValid-1)`,
with `quarterlyToAnnual` binning from `spinupTime + 1`.

**This is the one place where fixing B without fixing D would silently produce
wrong answers rather than an error.**

---

## What changes in the results

The **half-year straddle disappears**. Currently every annual bin holds two
quarters of one drought year and two of the next, so a drought is split across
two adjacent bins — halving its apparent magnitude and contaminating its
neighbour. Removing it should *sharpen* the drought-migration relationship,
which is the measurement the paper rests on.

The **annual solvency accounting becomes self-consistent**, so food insecurity
and the distress trigger stop disagreeing about the same year.

Reported years shift. Nothing computed before this fix is comparable to
anything after it without re-running.

## Suggested order

1. B1-B4 together — they are one change and are incoherent applied singly.
2. D immediately after, in the same sitting; B without D is silently wrong.
3. C1-C4 — independent, cosmetic, safe to do any time.
4. C5 — needs a modelling decision first.
5. Add a preflight check that `agYFYearIndex` is the only year-index
   implementation in `Core_MIDAS_Code`.

A test worth adding: assert once per run that the sum of four quarterly
`subsistNow` debits equals `fullCost` for a sample agent. That identity is what
broke here, and it would have caught this immediately.
