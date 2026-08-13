function [agentParameters, modelParameters, networkParameters, mapParameters] = readParameters(inputs)

%All model parameters go here
modelParameters.spinupTime = 10; % in quarters, so 10 = 2.5 years
modelParameters.numAgents = 100; % Number of agents in the initial state of the model, changes through time based on demography
mapParameters.sizeX = 600;
mapParameters.sizeY = 600;
mapParameters.levelID = '_PCODE';
mapParameters.levelName = 'NAME_'; % captures NAME_1, NAME_2 from shapefile as source_NAME_1, source_NAME_2

modelParameters.cycleLength = 4;
modelParameters.startYear = 1985;
modelParameters.endYear = 2025;  % calibration period only; change to 2050 for future projections
modelParameters.sspScenario = 'SSP5';
modelParameters.numCycles = modelParameters.endYear - modelParameters.startYear; % number of years; timeSteps = spinupTime + numCycles * cycleLength

modelParameters.incomeInterval = 1;
modelParameters.visualizeYN = 0;
modelParameters.listTimeStepYN = 1;
modelParameters.visualizeInterval = 2;
modelParameters.showMovesOrNetwork = 1; %1 for recent moves, 0 for network
modelParameters.movesFadeSteps = 12;
modelParameters.edgeAlpha = 0.2;
modelParameters.ageDecision = 15;
modelParameters.ageLearn = 10;
modelParameters.utility_k = 4; %Original value: 4
modelParameters.utility_m = 1;
modelParameters.utility_noise = 0.05;
modelParameters.utility_iReturn = 0.05;
modelParameters.utility_iDiscount = 0.05;
modelParameters.utility_iYears = floor(0.5 * modelParameters.numCycles); %Check that this should be 1/2 of number of cycles
modelParameters.educationCost = 5;
modelParameters.largeFarmCost = 20;
modelParameters.smallFarmCost = 10;
modelParameters.skilledUtility = 100;
modelParameters.ag2Utility = 30;
modelParameters.unskilled1Utility = 10;
modelParameters.schoolLength = 16;
modelParameters.remitRate = 0;
modelParameters.creditMultiplier = 0.3;

% Dynamic layer capacity: when true, nExpected (the number of agents a
% layer can absorb per location before congestion decay) is recomputed
% each timestep as nExpected_frac x CURRENT regional agent population,
% instead of staying frozen at the 1985 initial population. The frozen
% version mechanically deepens congestion as the population grows ~3x
% over 1985-2025 (and further to 2085), creating a secular income decline
% and migration trend unrelated to climate that contaminates epoch-ratio
% outputs (e.g. migration 2085 vs 2025) and SSP scenario contrasts.
% Set false ONLY to reproduce legacy (pre-fix) runs. See the recompute
% block near the top of the midasMainLoop.m time loop.
modelParameters.dynamicNExpected = true;
modelParameters.normalFloodMultiplier = 1;
modelParameters.ruralUrbanTime = 0.2; %Proportion of time needed for transit between rural and urban layers of portfolio

% Urban income multiplier (calibration scaffold).
% Multiplies the mean_utility of every non-agricultural (localOnly == 0)
% layer to scale the urban/rural relative payoff balance. The within-ag
% relative incomes (rice, maize, cassava, vanilla, etc.) are anchored by
% FAO yield data and the GRMA drought modulation, but the absolute
% urban-vs-ag ratio in utility_layers_v1.csv has no empirical basis,
% so we calibrate it here as a single global multiplier. Default 1.0
% leaves the CSV values unchanged; calibrated value typically 0.5-1.5.
% Once calibration converges, bake the chosen multiplier into the CSV
% mean_utility column and remove this parameter.
modelParameters.urbanIncomeMultiplier = 1.0;
mapParameters.movingCostPerMile = 0;
% DISTANCE BAND (set from the map, 2026-08-09; was 50 and 400).
% These bound where distance cost starts accruing and where it saturates.
% They are properties of the GEOGRAPHY, not free behavioural parameters:
% centroid distances for the 22 Madagascar regions span 42-855 miles
% (nearest-neighbour moves 42-140, median pair 277). Set to 40 and 860 so
% the band covers the full realisable range -- with the linear beta(1,1)
% cost shape this makes cost proportional to distance for every possible
% move, with no dead zone at the short end and no saturation at the long.
%
% Previously both were Monte Carlo sampled (minDistForCost 0-50,
% maxDistForCost 300-700). That is specification uncertainty rather than
% parameter uncertainty: a 300-mile saturation makes over half of all
% region pairs pay an identical cost, erasing distance decay, which is not
% a hypothesis worth spending sampling budget on. They are now fixed and
% movingCostPerMile alone carries the sensitivity. See runMIDASExperiment_parallel.m.
mapParameters.minDistForCost = 40;
mapParameters.maxDistForCost = 860;
networkParameters.networkDistanceSD = 7;
networkParameters.connectionsMean = 2;
networkParameters.connectionsSD = 2;
networkParameters.agentPreAllocation = modelParameters.numAgents * 3;
networkParameters.nonZeroPreAllocation = networkParameters.agentPreAllocation * 10;
networkParameters.weightLocation = 3;
networkParameters.weightNetworkLink = 5;
networkParameters.weightSameLayer = 3;
networkParameters.distancePolynomial = 0.0002;
networkParameters.decayPerStep = 0.002;
networkParameters.interactBump = 0.01;
networkParameters.shareBump = 0.001;
mapParameters.degToRad = 0.0174533;
mapParameters.milesPerDeg = 69; %use for estimating actual distances in distance Matrix
mapParameters.density = 60; %pixels per degree Lat/Long, if using .shp input
mapParameters.colorSpacing = 20;
mapParameters.numDivisionMean = [2 8 9];
mapParameters.numDivisionSD = [0 2 1];
mapParameters.position = [300 100 600 600];
modelParameters.samplePortfolios = 100; %Number of example portfolios to create average utility for each aspirational layer
mapParameters.r1 = []; %this will be the spatial reference if we are pulling from a shape file
mapParameters.saveDirectory = './Outputs/';

mapParameters.filePath = './Data/Mada Admin 2/Admin_2_lat_lon.shp';
% Demographic files - set to [] to use random fallback while data files are being prepared.
% Restore these lines once survival_SSP2.csv, fertility_SSP2.csv, and a
% population file with male_X/female_X age columns are in the Data folder.
modelParameters.popFile       = './Data/1985_MDG_GHSPop_totals_by_region.csv';
modelParameters.survivalFile  =  ['./Data/survival_'  modelParameters.sspScenario '.csv'];
modelParameters.fertilityFile = ['./Data/fertility_' modelParameters.sspScenario '.csv'];

modelParameters.agePreferencesFile  = './Data/age_specific_params.xls';
modelParameters.utilityDataPath     = './Data';
modelParameters.utilityLayersFile   = './Data/utility_layers_v1.csv'; % swap filename to switch layer configurations

% Per-region non-farm employment capacity, as a fraction of local population.
% Derived from the 2018 census (RGPH-3, Tableau 2.2): urban_frac =
% Urbain_Total / Total_Total per region, split across the three non-farm
% layers in the proportions observed in a baseline run (unskilled1 49.3%,
% unskilled2 30.0%, skilled 20.7%). National urban share 19.3%, so ~81%
% agricultural nationally and 84-90% in the Grand Sud -- against ~20% before,
% and roughly the 95% agriculture/livestock/fishing dependence reported for
% the southern regions.
% NB the % columns in the raw census table are WITHIN-PROVINCE shares, not
% the urban/rural split, so urban_frac must be computed from the totals.
% Requires hard_slot = 1 on those layers in utilityLayersFile to bind.
% Set to '' to disable and fall back to uniform per-layer capacity.
modelParameters.nonAgCapacityFile   = './Data/nonag_capacity_by_region.csv';
% Uniform multiplier on every capacity fraction. The census file supplies the
% regional PATTERN of off-farm opportunity; this sets the national LEVEL, so
% the two can be calibrated separately against the ILO/FAOSTAT agricultural
% employment share. Below 1 pushes agents into agriculture. See the capacity
% block in midasMainLoop.m.
modelParameters.nonAgCapacityScale  = 1.0;
% SSP-specific SPEI file (retained for future inter-annual variability module).
% generate_spei_projections.py writes CEDA_SPEI_SSP2.csv and CEDA_SPEI_SSP5.csv
% to the Data/ folder.  Falls back to CEDA_SPEI.csv if SSP file not found.
modelParameters.speiFile = ['./Data/CEDA_SPEI_' modelParameters.sspScenario '.csv'];

% GRMA crop yield factor files are resolved automatically in createUtilityLayers.m
% from the grma_crop column in utility_layers_v1.csv and modelParameters.sspScenario.
% File naming convention: Data/GRMA_yield_{crop}_{SSP}.csv
% (generated by generate_grma_yield_timeseries.py)

% --- Inter-annual drought variability (Markov chain) ---
% Region- and layer-specific transition probabilities and SPEI6 distributions
% are stored in drought_markov_params.csv (generated by derive_drought_markov_params.py).
% Set droughtVariabilityOn = true to activate; false to disable (default during calibration).
%
% droughtScaleFactor controls the magnitude of annual yield perturbations.
% Perturbation in drought years = droughtScaleFactor * sampled_SPEI6
%   (SPEI6 in drought years is negative, so this subtracts from yield factor)
% A value of 0.10 means a 1-SD drought event (SPEI6 ≈ -1.0) reduces
% the annual yield factor by ~0.10 (10 percentage points).
% This is a key calibration parameter — tune once yield data become available.
modelParameters.droughtVariabilityOn = false;
modelParameters.droughtMarkovFile    = './Data/drought_markov_params.csv';
modelParameters.droughtScaleFactor   = 0.10;

% ----- Distress-migration overlay (see paper Sections 4.4 / 5.1) -----------
% When enabled, agents flagged by checkDistressTrigger are forced to
% migrate at the next quarterly cycle, regardless of the standard pChoose
% probabilistic trigger. choosePortfolio is still used to pick the
% destination, but the current location is excluded from the candidate
% set (to force a move) and the credit constraint is relaxed (to allow
% the move to proceed even when wealth is depleted, mimicking household
% asset liquidation to fund displacement). Default: disabled.
%
% Four trigger variants are dispatched via distressTriggerCode:
%   1 = Variant A: consecutive food-insecure years
%   2 = Variant B: wealth threshold + duration
%   3 = Variant C: cumulative wealth shortfall over rolling window
%   4 = Variant D: stochastic depth-dependent (per-quarter draw)
% See checkDistressTrigger.m for the dispatch logic.
modelParameters.distressMigrationEnabled = false;
modelParameters.distressTriggerCode = 1;   % default to Variant A (unused when distressMigrationEnabled = false)

% ----- Expectation-formation arm (see paper Section 4.4 discussion) ---------
% Selects how an agent forms expected per-period income for a candidate
% portfolio in choosePortfolio.m. Dispatched in formExpectation.m:
%   0 = BASELINE (current MIDAS: random stitching of complete past cycles
%       uniformly sampled across the full agent history)
%   1 = ADAPTIVE EXPECTATIONS (exp-decay weighted mean, deterministic future)
%   2 = WINDOWED RANDOM SAMPLING (baseline logic but restricted to the most
%       recent numPeriodsMemory quarters; activates that previously-dead param)
%   3 = NAIVE FORECAST (most recent complete cycle repeated forward)
%   4 = ADAPTIVE + STOCHASTIC SHOCKS (weighted mean plus residuals sampled
%       from observations within expectationShockWindow quarters)
% Default 0 preserves back-compatibility with all calibration runs to date.
modelParameters.expectationArm = 0;

% Per-variant parameters (sampled in mcParams when their arm is active).
modelParameters.expectationDecayRate    = 0.05;   % lambda for arms 1 and 4; half-life of ln(2)/lambda quarters (~14 q at 0.05)
modelParameters.expectationShockWindow  = 12;     % quarters of recent observations to pool for arm 4 residuals (3 years)

% Variant A parameters
modelParameters.distressN = 3;   % consecutive FI years to trigger (Variant A)

% Variant B parameters (also reused by C and D for the threshold)
modelParameters.distressWealthThreshold = 0.5;   % wealth value below which an agent is "in distress" (units: same as agent.wealth; subsistence_costs default = 0.3/quarter, so 0.5 = ~1.5 quarters of subsistence buffer)
modelParameters.distressN_quarters = 8;          % consecutive quarters below threshold to trigger (Variant B; 8 = 2 years)

% Variant C parameters
modelParameters.distressShortfallWindowYears = 3;     % rolling window for shortfall accumulation (Variant C)
modelParameters.distressCriticalShortfall    = 2.0;   % cumulative shortfall sum across the window to trigger (units: wealth-quarters)

% Variant D parameters
modelParameters.distressStochasticAlpha = 3.0;   % steepness of depth-to-probability response (Variant D; higher = more responsive to shortfall depth)

% Variant E parameters (income-shock trigger; see checkDistressTrigger.m case 5)
% Fires when last-year realised income < distressIncomeDropFrac x the mean
% of the preceding distressIncomeWindowYears annual incomes. Conditions on
% the INCOME link of the drought->migration chain (alive, ~-9% in kere
% years, DSF-scaled) rather than the wealth/FI link (dead) used by A-D.
% NET INCOME (2026-07-28): the shock test now reads netIncomeHistory (income
% after the drought-scaled subsistence cost, before remittances), not gross.
% On gross income it fired at 1.9% in kere years vs 1.75% in normal years --
% blind to the drought, because most of a kere's damage is on the
% expenditure side. REQUIRES bufferEnabled = true: the food-price spike that
% carries the drought into subsistNow is gated behind it.
modelParameters.distressIncomeDropFrac    = 0.6;  % fire below 60% of trailing mean
modelParameters.distressIncomeWindowYears = 3;    % trailing baseline window (years)
modelParameters.distressCooldownQuarters  = 4;    % min quarters between distress moves
% Baseline net income must exceed this fraction of annual subsistence for the
% trigger to be eligible. Net income is a small difference of two larger
% numbers, so a near-zero baseline makes the ratio test explode and fire on
% noise (observed: normal-year firing rising to ~14% purely from leverage).
% Excludes the chronically sub-subsistence, whose situation is poverty rather
% than shock. Converted to absolute units in midasMainLoop.
modelParameters.distressMinBaselineFrac   = 0.1;

% Variant F materiality threshold (2026-07-21): the year-end consumption
% shortfall must exceed this FRACTION of annual subsistence for Variant F
% to fire -- i.e. more than ~a month of the year's food needs unmet AFTER
% buffer drawdown (0.1 x 12 months = 1.2 months; cf. the 3.8-month FI
% calibration target, Harvey et al. 2014, and IPC/FEWS crisis-phase
% consumption-gap definitions). Rationale: the strict "shortfall > 0" test
% was chronically true (~70% of traced agent-quarters), so buffer size
% never gated firing and all four buffer parameters were PRCC-inert on the
% drought metrics. A materiality line makes the buffer's absorption
% capacity decide whether a bad year crosses it, restoring identifiability
% to bufferMortalityMax/CapYears. FIXED (not calibrated): it would trade
% off against subsistence_costs and weaken the best-identified parameter.
% Set 0 to recover the legacy strict->0 behaviour. Converted to absolute
% units in midasMainLoop (distressShortfallAbs).
modelParameters.distressShortfallFrac = 0.1;

% Oracle trigger (distressTriggerCode = 7; DIAGNOSTIC ONLY): fires on two
% consecutive years with agYF below this threshold at the agent's location,
% conditioning on the climate forcing itself rather than agent state. Upper
% bound for what any agent-state trigger (A-F) can achieve; tests the
% downstream pipeline (distress moves -> flows -> detrended metrics) in
% isolation. Not for production runs.
modelParameters.oracleAgYFThreshold = 0.8;

% Local demand coupling (see createUtilityLayers.m): scales non-ag layer
% base utility per location-year by 1 - kappa*(1 - mean local ag yield
% factor), so local non-farm income co-moves with the agricultural economy
% instead of acting as a drought-immune absorber. 0 = off (legacy).
% SET TO 0.25 (2026-07-28). Deliberately low, and NOT a second full-strength
% drought shock. phiFood already carries the expenditure side (food prices;
% FEWS NET recorded cassava +211% and maize +103% over five-year averages in
% 2021-22) and is the better-evidenced channel. kappa is the income side --
% wage work pays less when the local agricultural economy shrinks, which is
% also documented (reduced casual labour opportunities are a standard kere
% food-security indicator).
%
% The two are COLLINEAR: both scale with (1 - agYF), both reduce net income,
% so they add, and the PRCC will struggle to separate them. At agYF = 0.75,
% income 10 and subsistence 7, net income falls 3.0 -> 1.25 on phiFood alone,
% -> 1.75 on kappa = 0.5 alone, and -> 0.0 with both. Two full-strength
% shocks overshoot.
%
% kappa is kept because it does one thing phiFood cannot: phiFood hits every
% agent identically and so leaves the RELATIVE attractiveness of farming vs
% wage labour unchanged. Non-farm layers therefore remain a drought-immune
% harbour that agents switch into instead of migrating -- the shock absorber
% the chain audit identified. Only kappa narrows that gap. It is an
% anti-absorber term, not a second shock, hence 0.25 rather than 0.5.
modelParameters.localDemandCoupling = 0.25;

% Positive-SPEI scale (see createUtilityLayers.m observed-SPEI block):
% scales the POSITIVE SPEI yield perturbations only. 1 = symmetric
% (legacy); 0 = wet years never lift yields above the GRMA baseline.
% Proxy for asymmetric post-drought recovery (assets liquidated during
% kere), which the chain audit showed the model lacks: post-kere years
% currently carry a +4.6% above-trend income rebound that pulls
% backward-looking agents back into southern agriculture.
modelParameters.droughtPositiveSPEIScale = 1.0;

% ----- Livestock/grain buffer (see livestock_buffer_design_v1.md,
%       midasMainLoop.m buffer block, checkDistressTrigger.m Variant F) -----
% Master switch. false = exact legacy behaviour (buffer stays 0 and no
% coupling is applied). When true, agri-pastoral agents accrue a food-
% equivalent asset stock from surplus, which grows slowly, dies in drought,
% and is liquidated (at a drought-depressed rate) to cover shortfalls.
modelParameters.bufferEnabled = false;

% Buffer SIZES are expressed in YEARS OF FOOD (multiples of annual
% subsistence = cycleLength * subsistence_costs), so they stay interpretable
% and auto-scale with the calibrated subsistence cost. Converted to absolute
% food-equivalent units in midasMainLoop.m. A cap of ~1 year means the herd
% can cover a single year of total crop failure -- it absorbs the first
% drought year and is exhausted by a continuation year (the cascade driver);
% it is NOT feasible to buffer many years of failure.
modelParameters.bufferCapYears   = 1.0;   % ceiling, in years of food (CALIBRATED)
modelParameters.bufferFloorYears = 0.2;   % reproductive/asset-smoothing floor, years of food (CALIBRATED); Variant F fires below this
modelParameters.bufferInitYears  = 0.5;   % starter endowment on taking up farming, years of food (fixed)
modelParameters.bufferRefFrac    = 0.5;   % productivity gain saturates at this fraction of the cap (fixed)

% CALIBRATED rate parameters (ranges wired in runMIDASExperiment_parallel.m):
modelParameters.bufferAccrualFrac  = 0.4;   % share of surplus stored as buffer
modelParameters.bufferMortalityMax = 0.3;   % max fractional herd loss in worst drought

% ----- Entitlement split and non-ag stores (2026-07-28) -----
% bufferDirectFrac: share of releasable stock CONSUMED DIRECTLY rather than
% sold. Sen's distinction between direct and exchange entitlement -- owning
% food is not the same as being able to buy it. Directly-eaten stock meets
% subsistence at UN-INFLATED cost (you already hold the asset); the rest must
% be sold into a collapsed livestock market to buy grain at spiked prices,
% and so carries both penalties. Anchored below 0.5 because livestock SALES
% funded >56% of cash food expenditure in the 2013-14 southwestern Madagascar
% crop failure -- the exchange channel dominates in the field data. CALIBRATE.
modelParameters.bufferDirectFrac = 0.35;

% bufferNonAgScale: size of a non-farming household's non-livestock store
% (grain, small stock, petty savings) relative to the farm buffer. Applies to
% cap, floor, accrual cap and starter endowment. Non-ag households therefore
% absorb a first bad year but empty sooner -- the pastoral/non-pastoral
% difference in multi-year response. The herd itself stays ag-only; the
% pastoral SHARE is corrected separately via layer hard slots, not by giving
% every agent cattle. CALIBRATE.
modelParameters.bufferNonAgScale = 0.3;

% FIXED-from-data / definitional parameters:
modelParameters.bufferGrowthRate   = 0.12;  % annual biological growth (~3-4 yr reconstitution)
modelParameters.bufferAccrualCapFrac = 0.25; % max accrual per year, as fraction of cap: herd rebuilding is
                                             % biological (~3-4 yr), not a one-boom-year purchase. Without this
                                             % the post-drought rebound year refills the buffer instantly and
                                             % erases the depletion memory that drives cascade compounding. (fixed)

% ----- Livelihood attachment (see choosePortfolio.m) -----
% Agents have a heterogeneous tendency to stay in their current field of
% work: livelihoodAttachment ~ U(0,1) per agent at creation. When enabled,
% candidate portfolios are penalised in proportion to the fraction of their
% layers the agent has never worked (no experience, not in current
% portfolio), scaled by livelihoodAttachmentScale x the agent's own
% attachment. Relocations that CONTINUE the current livelihood carry no
% penalty (preserves the "move but keep farming" Grand-Sud pathway).
% ACTIVE in distressMode as well: the forced move itself cannot be blocked
% (current location is excluded from the candidate set), so attachment only
% steers destination/portfolio choice -- displaced farmers prefer to keep
% farming, matching the observed kere destination mix.
% Motivation: agent traces show "farmers" drifting in/out of ag layers
% year-to-year; this churn undermines any multi-year asset mechanism and
% dilutes the drought signal with background portfolio noise.
modelParameters.livelihoodAttachmentEnabled = false;  % master switch; false = exact legacy
modelParameters.livelihoodAttachmentScale   = 0.5;    % max fractional NPV penalty at full attachment
                                                      % and zero familiarity (CALIBRATED when enabled)
modelParameters.attachmentRecencyDecay      = 0.94;   % per-quarter EMA decay for recentExperience:
                                                      % familiarity half-life ~11 quarters (~3 yrs), so
                                                      % attachment binds to the agent's RECENT field of
                                                      % work rather than every layer ever touched (fixed)
modelParameters.lambdaProd         = 0.2;   % herd -> agricultural-income productivity gain (0 = off)
modelParameters.phiFood            = 1.0;   % food-price drought sensitivity (anchor: cassava x3, FEWS 2021) -- FIX from data
modelParameters.phiLv              = 0.75;  % livestock-price drought sensitivity (anchor: small ruminants -75%, FEWS 2021) -- FIX from data

% ----- Buffer agent-trace (diagnostic; see midasMainLoop.m buffer block) -----
% When traceBuffer = true, the year-end buffer update for a small sample of
% agents in traceRegions is logged step-by-step (start -> mortality -> growth
% -> drawdown/accrual -> end, plus drought state, wealth, income, farm status)
% and written to traceBufferFile as a CSV. Off by default. Use run_buffer_trace.m
% for a one-command single local run. This is for eyeballing per-agent
% mechanics that 200-run composites hide -- not for production.
modelParameters.traceBuffer     = false;
modelParameters.traceRegions    = [19 20 21];        % Androy, Anosy, Atsimo-Andrefana

% ----- Agent life-history trace (see agentLifeTrace.m) -----
% Writes agent_life_history.csv (one row per traced agent-quarter) and
% agent_choices.csv (one row per candidate portfolio evaluated), so an
% agent's forty years can be read as a narrative and any single decision
% interrogated. Both carry RESIDUAL columns that must be zero to machine
% precision if the accounting is correct -- sorting by |residual| surfaces
% arithmetic errors without requiring a reader to spot them.
% SINGLE-THREADED ONLY: agentLifeTrace uses persistent state, so this must
% stay false for the parfor calibration campaign.
modelParameters.traceAgentLife    = false;
modelParameters.traceLifeMaxAgents = 10;    % southern ag agents to follow
modelParameters.traceLifeDir      = './Outputs/';
modelParameters.traceMaxAgents  = 15;                % cap distinct agents traced (first ag agents encountered)
modelParameters.traceBufferFile = './Outputs/buffer_trace.csv';

modelParameters.saveImg = true;
modelParameters.shortName = 'Mada_toy_application';
agentParameters.currentID = 1;
agentParameters.incomeShareFractionMean = 0.4;
agentParameters.incomeShareFractionSD = 0;
agentParameters.shareCostThresholdMean = 0.3;
agentParameters.shareCostThresholdSD = 0;
agentParameters.wealthMean = 0;
agentParameters.wealthSD = 0;
agentParameters.subsistence_costs = 0.3;
agentParameters.interactMean = 0.8;
agentParameters.interactSD = 0;
agentParameters.meetNewMean = 0.1;
agentParameters.meetNewSD = 0;
agentParameters.probAddFitElementMean = 1.0;
agentParameters.probAddFitElementSD = 0;
agentParameters.randomLearnMean = 1;
agentParameters.randomLearnSD = 0;
agentParameters.randomLearnCountMean = 5;
agentParameters.randomLearnCountSD = 0;
agentParameters.chooseMean = 1.0;
agentParameters.chooseSD = 0;
agentParameters.backCastMean = 1.0;
agentParameters.backCastSD = 0;
agentParameters.knowledgeShareFracMean = 0.3;
agentParameters.knowledgeShareFracSD = 0;
agentParameters.bestLocationMean = 2;
agentParameters.bestLocationSD = 0;
agentParameters.bestPortfolioMean = 5;
agentParameters.bestPortfolioSD = 0;
agentParameters.randomLocationMean = 2;
agentParameters.randomLocationSD = 0;
agentParameters.randomPortfolioMean = 2;
agentParameters.randomPortfolioSD = 0;
agentParameters.bestPortfolioAspirationsMean = 2;
agentParameters.bestPortfolioAspirationsSD = 0;
agentParameters.numPeriodsEvaluateMean = 40;
agentParameters.numPeriodsEvaluateSD = 0;
agentParameters.numPeriodsMemoryMean = 40;
agentParameters.numPeriodsMemorySD = 0;
agentParameters.discountRateMean = 0.04;
agentParameters.discountRateSD = 0;
agentParameters.rValueMean = 0.85;
agentParameters.rValueSD = 0.2;
agentParameters.bListMean = 0.5;
agentParameters.bListSD = 0.2;
agentParameters.prospectLossMean = 2;
agentParameters.prospectLossSD = 0;
agentParameters.informedExpectedProbJoinLayerMean = 1;
agentParameters.informedExpectedProbJoinLayerSD = 0;
agentParameters.uninformedMaxExpectedProbJoinLayerMean = 0.4;
agentParameters.uninformedMaxExpectedProbJoinLayerSD = 0;
agentParameters.expectationDecayMean = 0.1;
agentParameters.expectationDecaySD = 0;

% override any input variables. 'inputs' should be a dataset with two columns,
% one with the parameter name and one with the value
if(~isempty(inputs))
   for indexI = 1:size(inputs,1)
       eval([inputs.parameterNames{indexI} ' = ' num2str(inputs.parameterValues(indexI)) ';']);
   end
end

modelParameters.timeSteps = modelParameters.spinupTime + modelParameters.numCycles * modelParameters.cycleLength;


end
