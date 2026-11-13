# utility_layers_v2.csv — design note

**Status: NOT WIRED IN. Do not point the model at this file yet.**
`modelParameters.utilityLayersFile` still reads `utility_layers_v1.csv`. This file
exists so the rice restructure is captured while the reasoning is fresh, not
because it is ready to run. Several values below are placeholders and are marked
as such. Running it as-is would produce a model whose rice sector is parameterised
by guesswork.

Drafted 2026-09-13.

---

## 1. What changed

`rice_north` and `rice_south` are replaced by `rice_rainfed` and `rice_irrigated`.
Layer count stays at **10**, so `countAgentsPerLayer` keeps its shape and only the
names change in the analysis scripts. Every other layer is byte-identical to v1.

The old split was geographic; the new split is by **water-supply security**, which
is what actually determines drought exposure. That is the quantity the model cares
about, so it is the one the layers should encode.

### Why the old split was wrong

`rice_north` and `rice_south` were identical in every column except `restrict_to`,
`drought_min_yield` (0.30 vs 0.20) and `drought_harvest_month` (4 vs 6). Between
them they covered only 14 of 22 regions. Eight regions had no rice at all:

- Androy, Anosy, Atsimo-Andrefana — the Grand Sud, defensible (semi-arid)
- Atsinanana — east-coast rainfed swidden rice country, an omission
- Boeny, Menabe, Betsiboka, Melaky — excluded on the reasoning that irrigated rice
  is drought-resistant, so it should not sit in a drought-sensitive layer

That last reasoning is sound but **`restrict_to` cannot express it**. The model has
no per-region drought sensitivity: `droughtScaleFactor` is global across layers
(see the deliberate note at `createUtilityLayers.m:224`), and per-layer variation
comes only from the SPEI sampling month and `drought_min_yield`. So excluding a
region does not say "rice here is drought-resistant", it says "there is no rice
livelihood here at all" — which is false for Marovoay and, applied consistently,
would also have to exclude Lac Alaotra, which v1 *includes* as fully rainfed.

A separate `rice_irrigated` layer with a high yield floor is the only way to state
the intended claim.

---

## 2. Value provenance

Every non-inherited value, and what it rests on. **Nothing marked PLACEHOLDER
should survive into a production run.**

| field | rice_rainfed | rice_irrigated | basis |
|---|---|---|---|
| `localOnly` | 1 | 1 | **EVIDENCED.** Malagasy farms are "mainly of a family-type"; irrigated paddy is owner-operated smallholder, not estate wage labour. At Lac Alaotra the average household rice field is 2–3 ha. Both layers are therefore agricultural, keep ag status and keep a `subsistence_fraction`. Contrast `industrial_crop` (sisal estate labour), which is manually excluded from `agLayerIdx`. |
| `hard_slot` | 0 | **1** | **DERIVED.** Equipped irrigated area is physically finite — c. 1.5 M ha gravity-irrigable nationally, 72% equipped. You cannot create paddy by wanting it, which is exactly what a hard slot expresses. NB this is the **first agricultural layer to carry a hard slot**; all others are 0. It will move the ag-participation series checked against the FAOSTAT 0.76 target. |
| `nExpected_frac` | 0.1 | 0.10 | **PLACEHOLDER (irrigated).** Must be derived from equipped irrigated area as a share of regional arable area before use. Reference point: Alaotra has c. 100,000 ha of rice plain of which c. 30,000 ha is irrigated. Rainfed 0.1 is inherited from v1. |
| `mean_utility` | 8 | 22 | **DERIVED, conservative.** Ratio 2.75 anchored on measured median yields — 1.72 t/ha irrigated vs 0.62 t/ha rainfed (ratio 2.77) — with the pair's area-weighted mean held near v1's 10. **This under-states the income gap**: irrigated households also farm larger areas (Alaotra 2–3 ha/household against a national 0.12–0.86 ha per active worker), so the income ratio exceeds the yield ratio. Treat 22 as a floor, not an estimate. |
| `drought_min_yield` | 0.20 | 0.75 | Rainfed 0.20 **INHERITED** (the more exposed of v1's two floors). Irrigated 0.75 is a **PLACEHOLDER**. Deliberately not drought-*immune*: Malagasy irrigation is gravity-fed from rivers and reservoirs whose flow is itself drought-sensitive, so a high floor is more defensible than removing `grma_crop`. The number itself is unsourced. |
| `access_cost_param` | `smallFarmCost` | `irrigatedFarmCost` | **PLACEHOLDER value (30), REASONED structure.** See §2a — it must be its own parameter, not a reused one. Added to `readParameters.m`, inert until v2 is active. |
| `restrict_to` | 17 regions | Alaotra-Mangoro, Boeny | See §3. |
| `drought_harvest_month` | 5 | 5 | **PLACEHOLDER, and a known regression.** See §4. |
| `grma_crop` | rice | rice | Inherited. Both read `GRMA_yield_rice_SSP*.csv`, so the secular trend is shared and only the floor differs. |

### 2a. Access costs are SHARED BY PARAMETER NAME — a trap

`createUtilityLayers.m:876-893` builds **one access code per unique
`access_cost_param` string**. `choosePortfolio.m:569` then cancels any code the
agent has already paid:

```matlab
accessCostCodes(agent.accessCodesPaid) = false;
```

So **layers naming the same cost parameter are entered free once any one of them
has been paid for.** The cost attaches to the code, not the layer.

Where this is intended and good: `school` and `skilled` both name `educationCost`,
so an agent pays for education once and does not pay again on entering skilled
work. Paid codes also accumulate into `creditCollateral`
(`choosePortfolio.m:593`), so education permanently raises borrowing capacity —
self-investment unlocking credit, which is coherent.

Where it is a live modelling assumption: `smallFarmCost` is shared by every crop
layer, so **switching crops costs nothing** once an agent has entered any crop.

This is defensible, and the intended reading is an ASSET-TRANSFER one: the
household sells the cassava plot and buys an equivalent smallholding elsewhere,
so the net entry cost is zero. Malagasy evidence supports the premise — there is
an active rural land market, smallholder transactions are secured through
*petits papiers* (semi-formal private deeds), and roughly 1.37 M *certificats
fonciers* had been issued through 546 communal land offices by 2022.

Two caveats, both of which make agents slightly MORE mobile than that story:

1. **The code cannot distinguish switching from accumulating.** An agent already
   holding cassava that *adds* maize pays nothing extra, having sold nothing —
   it now farms two plots for one payment. Feasible, not hypothetical: cassava
   `[0.5,0.5,0.5,0.5]` plus maize `[0.5,0,0,0.5]` saturates Q1 and Q4 exactly.
2. **Collateral never decays.** `creditCollateral` sums the access costs of all
   codes ever paid (`choosePortfolio.m:593`) and codes are only ever set true
   (line 1011). An agent that liquidated everything still borrows against assets
   it no longer holds.

**Bounded, though.** With `creditMultiplier = 0.3` the reserve test is
`postMoveWealth < 0.3 * creditCollateral`. A typical agent holding only
`smallFarmCost` has collateral 10, i.e. a threshold of 3.0 against a founding
wealth of 55; an agent that had paid every code (5+10+20+30 = 65) reaches 19.5.
Real, but not a headline-moving bias. **Recommendation: document, do not change.**

**Malagasy wrinkle for the methods text.** Those land rights rest on *social
acknowledgment*, and the *petits papiers* system is inherently local — selling in
Androy and buying in Boeny, where the household has no standing, is harder than a
shared access code implies. The separately-charged moving cost partially stands in
for that friction. Rice land specifically is recognised as *family property*,
typically inherited rather than freely traded, so buying into an Alaotra paddy as
an incomer is harder than `irrigatedFarmCost` alone suggests — which is an
argument that the hard slot on `rice_irrigated` represents a real allocation
constraint rather than a capacity fudge.

Where it was an outright error in the first draft of this file: `rice_irrigated`
was given `largeFarmCost` to avoid adding a parameter, which silently shared a
code with `vanilla` — a Sava vanilla grower would have entered Alaotra paddy for
nothing. Corrected to a dedicated `irrigatedFarmCost`. **Rule: distinct
livelihoods need distinct cost parameters even when the amounts coincide.**

---

## 3. Region assignment

**`rice_irrigated` — Alaotra-Mangoro, Boeny.** Deliberately conservative: only the
two documented national granaries. Lac Alaotra (Alaotra-Mangoro) is the largest
rice area in the country, c. 100,000 ha of plain with c. 30,000 ha irrigated,
yields c. 25% above the national average. Marovoay (Boeny) is the second granary,
irrigated from the Ankarafantsika catchment.

**Candidates deliberately NOT included, pending sourcing: Menabe, Betsiboka,
Melaky.** I could not establish their irrigation systems from accessible sources
and have not guessed. Menabe in particular (Dabara schemes on the Morondava) is a
plausible addition that someone should check properly.

**`rice_rainfed` — 17 regions**, i.e. all except the Grand Sud (Androy, Anosy,
Atsimo-Andrefana) and the arid west (Menabe, Melaky).

Two notes on that list:

- **Alaotra-Mangoro and Boeny appear in BOTH layers.** Intentional. Those regions
  contain equipped perimeters *and* rainfed rice outside them; agents choose.
- **The Grand Sud remains rice-free, exactly as in v1.** This is continuity, not a
  new judgement — changing the study region's livelihood set would be a substantive
  model change smuggled in under a refactor. Note that Anosy is arguably mixed (the
  humid south-east coast, plus Mandrare valley schemes) and could be revisited, but
  deliberately is not revisited here.

**`restrict_to` is load-bearing and nothing else will do its job.** The GRMA yield
surface does *not* encode suitability — it is a drought-loss factor relative to each
region's own baseline. Androy reads 0.892 for rice, *higher* than Vakinankaratra's
0.875 and Haute Matsiatra's 0.704. An unrestricted rainfed rice layer would make
rice one of the better livelihoods in the Grand Sud. `restrict_to` is the only
mechanism in the model carrying agro-climatic suitability.

---

## 4. Known regression: the harvest-month collapse

v1 carried a real physical distinction — northern rice sampled SPEI-6 at month 4
(Nov–Apr window), southern at month 6 (Jan–Jun). Collapsing north/south into one
rainfed layer **loses that growing-season difference**, and 5 is a midpoint, not a
measurement.

Three ways out, in increasing cost:

1. Accept it, and say so in the methods.
2. Three rice layers — `rice_rainfed_north`, `rice_rainfed_south`, `rice_irrigated`
   — preserving both the season split and the water-security split. Takes
   `nLayers` to 11, so `countAgentsPerLayer` changes shape and every hard-coded
   layer index downstream needs updating.
3. Pick the month empirically from the GRMA Kc curve for rice.

Option 2 is the honest one if the season difference matters to the results; it was
not chosen here only because the requested restructure was two layers.

---

## 5. Steps required before this file can be used

1. **Resolve every PLACEHOLDER in §2** — irrigated `nExpected_frac`,
   `drought_min_yield`, and the harvest months.
2. ~~Regenerate the SPEI file.~~ **DONE — `Data/observed_spei_harvest_v2.csv`.**
   22 regions × 152 cells (4 ag layers × 38 years, 1985–2022), columns
   `rice_rainfed_y*`, `rice_irrigated_y*`, `maize_y*`, `cassava_y*`.

   This was necessary because the SPEI lookup keys on *layer name*
   (`createUtilityLayers.m:382`, `sprintf('%s_y%d', layerName, yr)`), and the v1
   file carries `rice_north_y*` / `rice_south_y*`. With v2 those lookups would
   miss **silently** — bare `continue` at line 384, no warning — leaving the rice
   layers with **no drought perturbation at all**, which would look like a
   plausible result rather than a failure.

   `apply_observed_drought.py` now takes `--layers` and `--out` (defaults
   unchanged, so the v1 route still works):

   ```
   python apply_observed_drought.py --layers Data/utility_layers_v2.csv \
                                    --out    Data/observed_spei_harvest_v2.csv
   ```

   Point `createUtilityLayers.m` at this file when v2 goes live — it currently
   hard-codes `observed_spei_harvest.csv` at line 350.

   **NOTE:** `rice_rainfed_y*` and `rice_irrigated_y*` are currently *identical*,
   because both layers carry `drought_harvest_month = 5`. The two layers are
   therefore distinguished in the drought response **only** by
   `drought_min_yield` (0.20 vs 0.75). That is defensible — the water-security
   difference is about how far yield can fall, not about when the crop is
   exposed — but if the irrigated harvest month is later revised (off-season
   *vary aloha* cropping would justify it), the file must be regenerated.
3. **Update the analysis scripts' hard-coded layer lists.** `LAYER_NAMES` in
   `explore_projections.jl` (which now hard-errors on a length or order mismatch —
   good), and the raw indices in `chain_audit.jl` (`AG_LAYER_IDS = [7, 8]`,
   `UNSK_LAYER_IDS = [1, 2]`) and `drought_response.jl`.
4. **Full recalibration.** The livelihood structure is what the parameters were
   identified against, so bounds from the current campaign do not transfer.
   Projections run under v1 are not comparable with projections run under v2.

---

## 6. Deliberately left alone

**`industrial_crop` is unchanged in v2**, so the diff stays scoped to rice. It has
its own outstanding problem: it is described as sisal estate *wage labour* and is
manually excluded from `agLayerIdx` and `agIncomeMask` on that basis, yet it pays
in a single quarter (`incomeQ = [0,0,1,0]`) while requiring labour in two
(`timeQ = [0,0.5,0.5,0]`) — a harvest profile on a wage-labour layer, leaving Q2
work unremunerated. If v2 is ever adopted, the one-line fix is `incomeQ =
[1,1,1,1]` plus `localOnly = 0`, which also makes the name-based exclusions in
`midasMainLoop.m` unnecessary. For reporting under v1, `industrial_crop` is pooled
with `unskilled1` — see `LAYER_REPORT` in `explore_projections.jl`.

---

## 7. Caveat for the methods text

"Irrigated" here means **secure water supply**, not the Malagasy statistical
category. National statistics describe roughly 80% of rice land as irrigated,
because that category includes all lowland flooded paddy (*rizières irriguées*) as
against upland rainfed (*riz pluvial*) — most of which is rain- and river-dependent
without controlled supply. Our `rice_irrigated` covers only formally equipped
perimeters, so `rice_rainfed` contains a great deal of land that official
statistics would count as irrigated. Anyone comparing the model's layer shares to
national rice statistics will find a mismatch, and the paper should say so before a
reviewer does.

---

## 8. Sources

- [Lac Alaotra: area, irrigated share, yields; Marovoay as second granary](https://www.madamagazine.com/en/das-korn-des-lebens-reisanbau-auf-madagaskar/)
- [Alaotra farm sizes, large-farm stratum, seasonal labour migration to Alaotra and Marovoay](http://www.cfnpp.cornell.edu/images/wp112.pdf)
- [Irrigated vs rainfed median yields (1.72 vs 0.62 t/ha); eastern rainfed swidden rice](https://sri.ciifad.cornell.edu/countries/madagascar/)
- [Family-type farms; irrigated sector as 57% of the rural economy; 1.5 M ha gravity-irrigable, 72% equipped](https://www.fao.org/in-action/water-for-poverty-in-africa/countries/madagascar/background/en/)
- [Marovoay irrigation from the Ankarafantsika catchment](https://www.fao.org/in-action/afr100/country-profiles/madagascar/en)
- [Alaotra-Mangoro irrigation resilience programme](https://www.adaptation-fund.org/project/madagascar-promoting-climate-resilience-in-the-rice-sector/)
- [Land reform, *certificats fonciers* and *guichets fonciers*; customary *tompontany* rights; rice land as family property](https://www.foncier-developpement.fr/wp-content/uploads/03-06-Burnod-236_paper.pdf)
- [Active rural land market; *petits papiers* securing transactions through social acknowledgment](https://www.sciencedirect.com/science/article/abs/pii/S0264837716310651)
- [Status of land governance in Madagascar (World Bank)](https://thedocs.worldbank.org/en/doc/a91b90185037e5f11e9f99a989ac11dd-0050062013/related/Final-Synthesis-Report.pdf)

## 9. Not represented, and worth a "further work" line

There is documented **seasonal labour migration into Alaotra and Marovoay during
the lean period**, with sending households relying on agricultural wages to bridge
the gap. That is a real, drought-responsive mobility channel and the model has no
representation of it — the irrigated regions pull agents only as a place to farm,
never as a place to work someone else's paddy. For a paper about drought and
internal migration this is a likely first question from a reviewer.
