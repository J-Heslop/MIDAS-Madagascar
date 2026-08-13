# MIDAS-Madagascar system diagram — legend & editing guide

Companion to `midas_system_diagram.mermaid`. The diagram is a full-model schematic:
core MIDAS (Bell/Cornell) plus the Madagascar extensions, with conceptual labels on
the top line of each box and the corresponding code file in italics beneath.

## How to view and edit

The diagram is plain text — you edit it by changing words, not dragging boxes.

- **Render it:** open `midas_system_diagram.mermaid` in VS Code with the *Markdown
  Preview Mermaid Support* (or *Mermaid Editor*) extension, paste it into
  <https://mermaid.live>, or drop the code block into any GitHub `.md` file.
- **Export a figure:** mermaid.live exports SVG/PNG directly (SVG is vector — ideal
  for the write-up and editable afterwards in Illustrator/Inkscape).
- **Change a box:** edit the text between the quotes. `<br/>` = line break,
  `<b>…</b>` = bold, `<i>…</i>` = italic (used for code references).
- **Add a link/influence:** add a line like `NODEA -->|"label"| NODEB`.
  Dotted influences use `-.->`.
- **Recolour:** the `classDef` blocks at the bottom set the four colour families.

## Colour key

| Colour | Meaning |
|---|---|
| Grey | Exogenous input (data fed in, not computed by the model) |
| Blue | Core MIDAS mechanism (inherited from Bell/Cornell) |
| Orange | Madagascar-specific extension (your additions) |
| Purple | Model outputs and downstream analysis |

## What each block represents

**Exogenous drivers.** Calendar-year-indexed inputs: the SPEI-6 drought signal
(CEDA historical + GRMA SSP2/SSP5 projections), WCDE survival/fertility, the 1985
GHS-POP base population, and the 22 ADM2 geography.

**World construction (`buildWorld.m`).** Turns inputs into model structures: the
income/utility layers, the drought **agricultural yield factor (agYF)** that
multiplies the agricultural layers, the demographic-rate arrays, and the
moving/remittance cost matrices.

**Agent (`Agent.m`).** Per-agent state — core MIDAS fields plus the extension
fields (buffer, `agIncomeYTD`, `lastShortfall`, recency-weighted `recentExperience`,
`livelihoodAttachment`).

**Quarterly simulation cycle (`midasMainLoop.m`).** The heart of the model, run
every quarter (`cycleLength = 4`): demography → social interaction → income
realisation → expectation formation → the `choosePortfolio` decision engine →
adopt/move → remittances. Migration is an emergent outcome of the NPV comparison,
not a rule.

**Distress-migration overlay (extension).** A parallel voluntary-migration override:
`checkDistressTrigger` fires (Variant F = income shock **and** a material food
shortfall; the oracle positive control is case 7) and routes the agent back through
`choosePortfolio` in `distressMode`, forcing a move.

**Livestock/grain buffer (extension, year-end).** A per-agent food-equivalent stock:
drought mortality (scaled by agYF), concave regrowth with rate-limited accrual,
drought-priced liquidation that finances migration, and the food-terms
food-insecurity check that sets `lastShortfall` (which in turn gates the distress
trigger).

**Outputs & analysis.** Simulation outputs feed the Julia diagnostics (chain audit,
kere metrics, PRCC, detrended drought-excess migration).

## Key feedback loops to notice

- **Drought → ag income → decision:** `agYF` depresses agricultural income, which
  reshapes expectations and the portfolio decision (the intended climate-migration
  channel).
- **Drought → buffer → distress → forced move:** `agYF` also drives buffer mortality;
  the resulting shortfall gates the distress trigger and liquidation funds the move.
- **Return-migration loop:** remittances rebuild the buffer, and restocking plus the
  fading of origin-livelihood attachment pull migrants back toward familiar work.
- **Congestion:** relocation changes local density, which feeds back into layer
  returns via `nExpected`.
