function [outputs] = midasMainLoop(inputs, runName)
%runMigrationModel.m main time loop of migration model

% FIX agent WEALTH HISTORY TO 1-DIMENSIONAL ARRAY


close all;

tic;

outputs = [];
[agentParameters, modelParameters, networkParameters, mapParameters] = readParameters(inputs);
[agentList, aliveList, modelParameters, agentParameters, mapParameters, utilityVariables, mapVariables, demographicVariables] = buildWorld(modelParameters, mapParameters, agentParameters, networkParameters);

% Agent life-history diagnostic. No-op unless modelParameters.traceAgentLife
% is true. Uses persistent state, so single-threaded local runs only --
% never the parfor calibration campaign.
agentLifeTrace('init', modelParameters, utilityVariables);
    
numLocations = size(mapVariables.locations,1);
numLayers = size(utilityVariables.utilityLayerFunctions,1);

sizeArray = size(utilityVariables.utilityHistory);

%create any other outcome variables of interest
countAgentsPerLayer = zeros(numLocations, numLayers, modelParameters.timeSteps);
averageExpectedOpening = countAgentsPerLayer;
averageWealth = zeros(modelParameters.timeSteps ,1);
migrations = zeros(modelParameters.timeSteps,1);
outMigrations = zeros(numLocations, modelParameters.timeSteps);
inMigrations = zeros(numLocations, modelParameters.timeSteps);
distressMigrations = zeros(numLocations, modelParameters.timeSteps);  % out-migrations triggered by the distress overlay (subset of outMigrations)
migrationMatrix = zeros(numLocations,numLocations,modelParameters.timeSteps);
portfolioHistory = cell(numLocations, modelParameters.timeSteps);
trappedHistory = zeros(length(agentList),modelParameters.timeSteps);
aspirationHistory = zeros(numLayers, modelParameters.timeSteps);
% Food insecurity tracker (ANNUAL aggregation, not per-timestep).
% Rows = locations, cols = YEARS (not timesteps). Separate counts for ag
% and all agents.
%
% Why annual: ag layers in MIDAS only generate income in their harvest
% quarter (rice Q2, maize Q1, cassava/vanilla Q4, industrial_crop Q3).
% A per-timestep "netIncome < subsistence_costs" check therefore flagged
% subsistence farmers as food-insecure in the 3/4 of timesteps with zero
% income, even though the annual harvest covered subsistence with room
% to spare -- producing a structural ~75% food-insecurity floor that was
% an artefact of the time aggregation, not a real model behaviour.
%
% We now check at year-end (every cycleLength timesteps): if the agent's
% wealth declined over the year, their annual income did not cover their
% annual subsistence consumption and they are flagged food-insecure for
% that year. This is equivalent to the original conceptual definition
% (annual_netIncome < annual_subsistence) and aligns with how Harvey et
% al. (2014) measured months of food insufficiency per year.
agLayerIdx = find(utilityVariables.localOnly);  % indices of agricultural (local-only) layers

% WAGE-LABOUR EXCLUSION (2026-08-09). agLayerIdx determines isAgAgent, which
% in turn gates (a) the farm-entry starter endowment, (b) whether an agent
% gets the full livestock buffer or the smaller non-ag store, and (c) the
% agentCount_ag / foodInsecureCount_ag calibration metrics.
%
% localOnly is doing double duty: it marks a layer as locally produced (so it
% escapes the urban capacity caps and the urbanIncomeMultiplier) AND it is
% read here as "this agent is an agro-pastoral household". Those are not the
% same claim. industrial_crop represents sisal ESTATE LABOUR -- the Grand Sud
% estates predominantly employ wage workers rather than smallholders -- so an
% agent in it is not accruing a herd from farm surplus and should fall
% through to the non-ag store (bufferNonAgScale): a wage labourer with a few
% goats, not a herd.
%
% Excluded by NAME from the layer CSV rather than by index, so layer
% reordering cannot silently re-point the exclusion at the wrong livelihood.
% NB this also removes those agents from foodInsecureRate_ag, which is a
% calibration target -- intended, since the metric should describe farming
% households, but it will shift that target's value.
wageLabourLayers = ["industrial_crop"];
if isfield(modelParameters, 'utilityLayersFile') && exist(modelParameters.utilityLayersFile, 'file')
    LDwage = readtable(modelParameters.utilityLayersFile, 'TextType', 'string');
    for iW = 1:numel(wageLabourLayers)
        iL = find(string(LDwage.name) == wageLabourLayers(iW), 1);
        if ~isempty(iL)
            agLayerIdx = agLayerIdx(agLayerIdx ~= iL);
        else
            % Warn loudly rather than lapsing silently. If utilityLayersFile
            % is swapped for a configuration that renames or drops this
            % layer, the wage-labour assumption would otherwise disappear
            % without trace and every such agent would quietly regain a herd.
            warning('midasMainLoop:wageLayerMissing', ...
                ['Wage-labour layer "%s" not found in %s. The agro-pastoral ' ...
                 'buffer exclusion is NOT in effect for it.'], ...
                wageLabourLayers(iW), modelParameters.utilityLayersFile);
        end
    end
    fprintf('midasMainLoop: agro-pastoral buffer EXCLUDES wage-labour layer(s): %s\n', ...
            strjoin(cellstr(wageLabourLayers), ', '));
end

% --- Livestock/grain buffer configuration (see readParameters.m,
%     createUtilityLayers.m agYF export, and checkDistressTrigger.m Variant F).
%     All gated by modelParameters.bufferEnabled; when false the block is a
%     no-op and behaviour is byte-for-byte legacy. Parameters are read once
%     here into locals for speed. ---
bufferOn = isfield(modelParameters, 'bufferEnabled') && modelParameters.bufferEnabled;
if bufferOn
    bfAccrualFrac = getParamOr(modelParameters, 'bufferAccrualFrac', 0.4);
    bfGrowthRate  = getParamOr(modelParameters, 'bufferGrowthRate',  0.12);
    bfMortMax     = getParamOr(modelParameters, 'bufferMortalityMax',0.3);
    bfLambdaProd  = getParamOr(modelParameters, 'lambdaProd',        0.2);
    bfPhiFood     = getParamOr(modelParameters, 'phiFood',           1.0);
    bfPhiLv       = getParamOr(modelParameters, 'phiLv',             0.75);

    % Buffer sizes are given in YEARS OF FOOD; convert to absolute food-
    % equivalent units using annual subsistence = cycleLength * subsistence_costs.
    annualSubsist = modelParameters.cycleLength * agentParameters.subsistence_costs;
    bfCap   = getParamOr(modelParameters, 'bufferCapYears',   1.0) * annualSubsist;
    bfFloor = getParamOr(modelParameters, 'bufferFloorYears', 0.2) * annualSubsist;
    bfFloor = min(bfFloor, 0.9 * bfCap);                            % floor must sit below the ceiling
    % BUG FIX 2026-07-08: checkDistressTrigger.m (Variant F) reads the
    % ABSOLUTE floor from modelParameters.bufferFloor, but after the
    % years-of-food refactor only bufferFloorYears was defined -- so the
    % trigger silently fell back to 0 and Variant F could NEVER fire.
    % Publish the derived absolute value so the trigger sees the same
    % floor used here.
    modelParameters.bufferFloor = bfFloor;

    % Variant F materiality threshold, in ABSOLUTE food-equivalent units
    % (fraction of annual subsistence; see readParameters.m). Published for
    % checkDistressTrigger case 6 -- same pattern as bufferFloor above, and
    % for the same reason: annualSubsist is only known here.
    modelParameters.distressShortfallAbs = ...
        getParamOr(modelParameters, 'distressShortfallFrac', 0.1) * annualSubsist;
    bfInit  = getParamOr(modelParameters, 'bufferInitYears',  0.5) * annualSubsist;
    bfInit  = min(bfInit, bfCap);                                    % never seed above the ceiling
    bfRef   = getParamOr(modelParameters, 'bufferRefFrac',    0.5) * bfCap;

    % Annual accrual rate limit (fraction of cap per year). Herd/store
    % reconstitution is biological (~3-4 yr), not a one-boom-year purchase;
    % without this cap the post-drought rebound year refills the buffer
    % instantly and erases the depletion memory. Fixed, not calibrated.
    bfAccrualCap = getParamOr(modelParameters, 'bufferAccrualCapFrac', 0.25) * bfCap;

    % Share of releasable stock consumed DIRECTLY rather than sold (Sen's
    % direct vs exchange entitlement). Directly-eaten stock meets subsistence
    % at un-inflated cost; the rest is sold into a collapsed market to buy
    % food at spiked prices. Anchored below 0.5 because livestock SALES funded
    % >56% of cash food expenditure in the 2013-14 southwestern Madagascar
    % crop failure -- the exchange channel dominates in the field data.
    bfDirectFrac = getParamOr(modelParameters, 'bufferDirectFrac', 0.35);

    % Size of the non-ag household's non-livestock store (grain, small stock,
    % petty savings) relative to the farm buffer. Applies to cap, floor,
    % accrual cap and starter endowment.
    bfNonAgScale = getParamOr(modelParameters, 'bufferNonAgScale', 0.3);

    % Per-agent mask of agricultural income layers (income-form AND local-only)
    agIncomeMask  = (utilityVariables.incomeForms(:)' & utilityVariables.localOnly(:)');

    % WAGE-LABOUR EXCLUSION (2026-08-09), second half. The block at the top of
    % this file removed the wage-labour layers from agLayerIdx, which governs
    % buffer ELIGIBILITY (does this agent get a herd-sized store or the small
    % non-ag one). This removes them from agIncomeMask, which governs buffer
    % ACCRUAL (which income streams feed the store). Both are needed and they
    % are separate variables: an agent cropping cassava AND labouring on a
    % sisal estate is still agro-pastoral and keeps the full buffer, but only
    % the cassava income should build the herd. Wages are consumed, not
    % converted into cattle. The layer list is defined once at the top of the
    % file so the two exclusions cannot drift apart.
    if isfield(modelParameters, 'utilityLayersFile') && ...
       exist(modelParameters.utilityLayersFile, 'file')
        LDmask = readtable(modelParameters.utilityLayersFile, 'TextType', 'string');
        for iW = 1:numel(wageLabourLayers)
            iL = find(string(LDmask.name) == wageLabourLayers(iW), 1);
            if ~isempty(iL) && iL <= numel(agIncomeMask)
                agIncomeMask(iL) = false;
            end
        end
        fprintf('midasMainLoop: buffer ACCRUAL excludes wage-labour layer(s): %s\n', ...
                strjoin(cellstr(wageLabourLayers), ', '));
    end
    nSimYearsBuf  = size(utilityVariables.agYF, 2);
end

% --- Minimum baseline for the net-income distress trigger ----------------
% Variant F tests a RATIO of net incomes. Net income is gross minus
% subsistence, so for a household living close to the line the denominator
% is near zero and the ratio explodes -- a trivial absolute change reads as
% a catastrophic proportional one. Counterfactual scans on the July traces
% showed exactly this: firing rates in NORMAL years rose from 1.8% to ~14%
% purely from that leverage, swamping the drought contrast.
%
% Agents whose baseline net income falls below this floor are therefore
% excluded from the trigger. They are chronically unable to meet subsistence
% -- a poverty condition rather than a drought shock -- and the trigger is
% meant to detect the shock. Expressed as a fraction of annual subsistence so
% it tracks the calibrated subsistence cost. Published here (rather than in
% readParameters) because annualSubsist needs cycleLength and
% subsistence_costs together. LIMITATION: chronically destitute households
% are thus invisible to the distress overlay -- a known simplification, and a
% candidate for further development.
modelParameters.distressMinBaseline = ...
    getParamOr(modelParameters, 'distressMinBaselineFrac', 0.1) * ...
    modelParameters.cycleLength * agentParameters.subsistence_costs;

% --- Livelihood-attachment recency tracking (see choosePortfolio.m) ---
% When attachment is enabled, each agent's recentExperience EMA is decayed
% and replenished every quarter in the income loop below. Zero overhead
% when the master switch is off.
attachTrackOn = isfield(modelParameters, 'livelihoodAttachmentEnabled') && ...
                modelParameters.livelihoodAttachmentEnabled;
if attachTrackOn
    attachDecay = getParamOr(modelParameters, 'attachmentRecencyDecay', 0.94);
end

% --- Buffer agent-trace (diagnostic; gated, off by default) ---
bufferTraceOn = bufferOn && isfield(modelParameters, 'traceBuffer') && modelParameters.traceBuffer;
if bufferTraceOn
    traceRegions   = getParamOr(modelParameters, 'traceRegions', [19 20 21]);
    traceMaxAgents = getParamOr(modelParameters, 'traceMaxAgents', 15);
    traceIDs       = [];        % agent ids being followed (first ag agents seen in traceRegions)
    bufferTrace    = zeros(0, 16);   % preallocated columns; see header at write-out
    % Distress-trace QA (same traced agents): one row per quarter logging
    % each Variant F trigger condition, so we can see exactly why an
    % agent did or didn't fire into forced migration. Written alongside
    % the buffer trace as <traceBufferFile>_distress.csv.
    distressTrace  = zeros(0, 13);
end

nYearsTotal = ceil(modelParameters.timeSteps / modelParameters.cycleLength);
foodInsecureCount_ag  = zeros(numLocations, nYearsTotal);
foodInsecureCount_all = zeros(numLocations, nYearsTotal);
agentCount_ag         = zeros(numLocations, nYearsTotal);
agentCount_all        = zeros(numLocations, nYearsTotal);
% All-ages headcount (see the note at the counting block). agentCount_all is
% working-age only; this is every living agent, used as the per-capita
% denominator for migration rates.
agentCount_pop        = zeros(numLocations, nYearsTotal);
% Buffer trackers (year-end, per location). Summed then divided by the
% agent count for a mean-buffer output; mortality-driven loss is the
% year-on-year drop. Zero everywhere when bufferEnabled is false.
bufferSum_all         = zeros(numLocations, nYearsTotal);
%wealthHistory = zeros(modelParameters.numAgents,modelParameters.timeSteps);

%create a list of shared layers, for use in choosing new link
% currentPortfolio is [layers, duration, fidelity] (numLayers+2 wide) from
% initialisation onwards -- see assignInitialLayers.m. Take the layer columns
% only; vertcat of the full rows gives numLayers+2 columns and the assignment
% into an (nAgents x numLayers) array fails on element count.
nLayersAL = size(utilityVariables.utilityLayerFunctions,1);
agentLayers = zeros(length(agentList), nLayersAL);
allPortfolios = vertcat(agentList.currentPortfolio);
agentLayers(:) = allPortfolios(:, 1:nLayersAL);

agentLocations = ones(1,length(agentList));
agentLocations(aliveList) = [agentList(aliveList).matrixLocation];

warnedNaNWealth = false;   % one-shot flag for the non-finite-wealth safety net
warnedNaNIncome = false;   % one-shot flag for the non-finite-income guard

for indexT = 1:modelParameters.timeSteps

    % Compute current calendar year and demographic array index.
    % During spinup (indexT <= spinupTime) the model uses startYear demographics.
    % After spinup, currentYear advances at 1/cycleLength years per timestep.
    currentYear = modelParameters.startYear + ...
        max(0, indexT - modelParameters.spinupTime) / modelParameters.cycleLength;
    tIdx = min( max(1, round(currentYear) - modelParameters.startYear + 1), ...
                size(demographicVariables.survivalRate, 4) );

    % --- Dynamic layer capacity (nExpected) ------------------------------
    % nExpected_frac is defined as the FRACTION of the local population a
    % layer can absorb, but the original implementation froze the absolute
    % capacity at the initial (1985) population. With ~3x population
    % growth over the calibration period (and more by 2085), that anchors
    % every market layer into mechanically deepening congestion decay,
    % manufacturing a secular income decline and migration trend unrelated
    % to climate -- and one that differs between SSP scenarios purely
    % through their population paths. When modelParameters.dynamicNExpected
    % is true, capacity is recomputed each timestep from the CURRENT
    % regional agent population, preserving constant-fraction semantics.
    % Spatially restricted (location, layer) pairs keep capacity 0, and the
    % prerequisite-chain adjustment mirrors createUtilityLayers.m section 10.
    % Set the flag false to reproduce legacy (static-capacity) runs.
    if isfield(modelParameters, 'dynamicNExpected') && modelParameters.dynamicNExpected
        % WORKING-AGE DENOMINATOR (2026-08-13). This counted EVERY living
        % agent, dependants included. The census fractions in
        % nonag_capacity_by_region.csv are shares of total population, so the
        % product gave the right number of urban RESIDENTS -- but only
        % working-age agents can now hold a livelihood, so those places were
        % being filled from a workforce roughly 63% the size of the base they
        % were computed on. Off-farm capacity was therefore about 1.6 times
        % more available, per worker, than the census implies.
        %
        % Counting only working-age agents makes the fraction a share of the
        % WORKFORCE, which is the quantity the capacity actually rations. This
        % raises agricultural participation, the direction needed to close the
        % gap against the ILO/FAOSTAT employment share.
        % NB livingAgents is not assigned until later in this timestep, so the
        % alive set is taken from agentList/agentLocations directly, matching
        % the indexing the original line used.
        ageAlive   = [agentList(aliveList).age];
        locsAlive  = agentLocations(aliveList);
        workingAge = ageAlive >= modelParameters.ageDecision;
        if any(workingAge)
            locCounts = accumarray(locsAlive(workingAge)', 1, [numLocations 1]);
        else
            % Degenerate case (e.g. an all-dependant population during a very
            % short spin-up): fall back to the whole alive set rather than
            % returning zero capacity everywhere.
            locCounts = accumarray(locsAlive', 1, [numLocations 1]);
        end

        % LEVEL SCALING. The census gives the regional PATTERN of off-farm
        % opportunity, which is well grounded, but the national LEVEL it
        % implies need not reproduce the observed agricultural employment
        % share once it is filtered through the model's livelihood structure.
        % nonAgCapacityScale multiplies every capacity fraction uniformly, so
        % the pattern is preserved while the level is calibrated against the
        % ILO/FAOSTAT share (agFrac_nat_data in buildNextRound.m). A value
        % below one shifts agents into agriculture. Default 1 leaves the
        % census level untouched.
        capScale = getParamOr(modelParameters, 'nonAgCapacityScale', 1.0);
        % nExpectedFrac is now (nLoc x nLayers) -- per-region capacity from the
        % 2018 census urban/rural split -- so this is an ELEMENTWISE product
        % with implicit expansion of locCounts, not the old outer product
        % against a (nLayers x 1) vector.
        newNExpected = floor(locCounts .* utilityVariables.nExpectedFrac .* capScale);  % (nLoc x nLayers)
        newNExpected(utilityVariables.spatiallyRestricted) = 0;
        tempNExpected = zeros(size(newNExpected));
        for indexL = 1:numLayers
            tempNExpected(:, indexL) = sum(newNExpected(:, utilityVariables.utilityPrereqs(:, indexL) > 0), 2);
        end
        utilityVariables.nExpected = tempNExpected;
    end

    %update the social network links ... cap any that swelled above 1 in
    %the last loop, and allow all to decay to no less than 0
    mapVariables.network(mapVariables.network ~= 0) = min(1,mapVariables.network(mapVariables.network ~= 0));
    mapVariables.network(mapVariables.network ~= 0) = max(0,mapVariables.network(mapVariables.network ~= 0) - networkParameters.decayPerStep);
        
    livingAgents = agentList(aliveList);
    currentRandOrder = randperm(length(livingAgents));

    % ---- LIVE SLOT ACCOUNTING (2026-08-12) -----------------------------
    % hasOpenSlots used to be recomputed ONCE per timestep, at the very end
    % (see the assignment after the income block), from a census taken after
    % every agent had already chosen. So every agent deciding in timestep T
    % saw the same stale snapshot from T-1: when one place opened in a layer,
    % an unlimited number of agents could take it, because the count did not
    % move until they had all committed.
    %
    % The consequence was measurable and graded by how well the layer paid.
    % Against the census capacities in nonag_capacity_by_region.csv, occupancy
    % ran at:
    %     skilled     6.52x capacity   (15 income per unit time)
    %     unskilled2  4.14x            (10)
    %     unskilled1  1.69x            ( 5)
    %     school      0.29x            ( 0)
    % Total urban capacity is 17.2% of population, matching the ~19% census
    % target, but the realised urban share was 0.43 -- roughly 2.4x too high.
    % For a rural-to-urban migration model that inflates the destination
    % sink, and therefore the headline flows, by construction.
    %
    % liveCount tracks occupancy AS AGENTS COMMIT. It is seeded from the
    % previous timestep's census, then adjusted whenever an agent changes
    % location or portfolio, and hasOpenSlots is recomputed from it. Agents
    % keep layers they already hold (see the incumbency exemption in
    % choosePortfolio.m) so this constrains hiring, not tenure.
    %
    % CONCEPTUAL COST, stated plainly: capacity now goes to whoever is
    % processed first, so the allocation is first-come-first-served within a
    % randomised agent order rather than to whoever values it most. That is a
    % lottery, not a labour market. It is defensible -- currentRandOrder is
    % reshuffled every timestep, so no agent is systematically advantaged, and
    % rationing by queue is a fair description of informal urban hiring -- but
    % it is a different allocation rule from vanilla MIDAS and must be stated
    % in the methods. Set enforceSlotsLive = false to recover the old
    % behaviour for comparison.
    enforceSlotsLive = getParamOr(modelParameters, 'enforceSlotsLive', true);
    if enforceSlotsLive
        if indexT > 1
            liveCount = countAgentsPerLayer(:, :, indexT - 1);
        else
            liveCount = zeros(numLocations, numLayers);
        end
        utilityVariables.hasOpenSlots = ...
            (liveCount < utilityVariables.nExpected & utilityVariables.hardSlotCountYN) | ...
            ~utilityVariables.hardSlotCountYN;
        if indexT == 1
            fprintf(['midasMainLoop: live slot accounting ENABLED -- layer capacity ' ...
                     'binds within the timestep.\n']);
        end
    end

    %Update average utilities for aspirational portfolios
    utilityVariables.aspirations = aspirationalPortfolio(utilityVariables.utilityBaseLayers(:,:,indexT), modelParameters.samplePortfolios, utilityVariables.utilityPrereqs, utilityVariables.utilityTimeConstraints);
    %update agent age, information and preferences, looping across agents
    for indexA = 1:length(currentRandOrder)
        
        currentAgent = livingAgents(currentRandOrder(indexA));
        currentPortfolio = logical(currentAgent.currentPortfolio(1,1:size(utilityVariables.utilityHistory,2)));
        
        %age the agent
        currentAgent.age = currentAgent.age + modelParameters.cyclesPerTimeStep;

        %draw number to see if agent survives to this timestep
        agentSurvives = rand() < interp1([demographicVariables.agePointsSurvival], [demographicVariables.survivalRate(currentAgent.matrixLocation,:,currentAgent.gender,tIdx)], currentAgent.age);

        if(~agentSurvives)

            %don't delete the agent, because we get into a re-indexing
            %nightmare.  just mark it dead, and force all network links to
            %0
            mapVariables.network(currentAgent.id, [currentAgent.network(:).id]) = 0;
            mapVariables.network([currentAgent.network(:).id],currentAgent.id) = 0;
            currentAgent.TOD = indexT;
            aliveList(currentAgent.id) = false;

            % Final row for a traced agent, so the life history ends with an
            % explicit cause rather than simply stopping. Without this, death
            % is indistinguishable from the trace running out at the horizon.
            if agentLifeTrace('enabled') && agentLifeTrace('isTraced', currentAgent.id)
                rD = struct();
                rD.t          = indexT;
                rD.year       = modelParameters.startYear + floor((indexT - 1) / modelParameters.cycleLength);
                rD.quarter    = mod(indexT - 1, modelParameters.cycleLength) + 1;
                rD.agentID    = currentAgent.id;
                rD.age        = currentAgent.age;      % years -- see note at the life row
                rD.tenure_q   = indexT - currentAgent.DOB;
                rD.loc        = currentAgent.matrixLocation;
                rD.inSouth    = double(ismember(currentAgent.matrixLocation, agentLifeTrace('regions')));
                rD.TOD        = indexT;
                rD.exitReason = "died";
                rD.wealth_end = currentAgent.wealth;
                rD.buffer     = currentAgent.buffer;
                agentLifeTrace('life', rD);
            end
            continue;
        end
        
        %update any age-specific agent parameters
 
        %agent expectations on openings are all updated based on how old
        %they are, with formula p = f(t) * A + (1 - f(t)) * B * rand(); f(t) =
        %f_init * (1 - d) ^ t ... A is the best case expectation with new
        %information, and B is the best case expectation in the absence of
        %any information.  As information gets older, expectation shifts
        %from based in A to mostly B
        temp_f =  (1 - currentAgent.fDecay).^(indexT - currentAgent.timeProbOpeningUpdated);
        currentAgent.expectedProbOpening = currentAgent.pGetLayer_informed * currentAgent.heardOpening .* temp_f + currentAgent.pGetLayer_uninformed * rand(size(temp_f)) .* (1 - temp_f);
        
        
        %agent gets updated knowledge of any openings available in layers
        %that it occupies
        currentAgent.heardOpening(currentAgent.matrixLocation,currentPortfolio) = utilityVariables.hasOpenSlots(currentAgent.matrixLocation,currentPortfolio);
        currentAgent.timeProbOpeningUpdated(currentAgent.matrixLocation,currentPortfolio) = indexT;
 
        %draw number to see if (for female agents) agent gives birth
        if(currentAgent.gender == 2 && currentAgent.age >= modelParameters.ageDecision)
            agentGivesBirth = rand() < interp1(demographicVariables.agePointsFertility, demographicVariables.fertilityRate(currentAgent.matrixLocation,:,tIdx), currentAgent.age);
            if(agentGivesBirth)
                gender = 2 - (rand() > 0.5);  %let it be equally likely to be 1 or 2
                age = 0;
                
                %newBaby = initializeAgent(agentParameters, utilityVariables, age, gender, currentAgent.location, agentList(agentParameters.currentID));
                newBaby = initializeAgent(agentParameters, utilityVariables, modelParameters, age, gender, currentAgent.location);
                newBaby.id = agentParameters.currentID;
                agentList(agentParameters.currentID) = newBaby;
                agentParameters.currentID = agentParameters.currentID + 1;
                newBaby.matrixLocation = currentAgent.matrixLocation;
                newBaby.DOB = indexT;
                newBaby.moveHistory = [indexT currentAgent.matrixLocation currentAgent.visX currentAgent.visY];
                newBaby.visX = currentAgent.visX;
                newBaby.visY = currentAgent.visY;
                
                newBaby.network = currentAgent;
                newBaby.myIndexInNetwork(1) = length(currentAgent.network)+1;
                currentAgent.network(end+1) = newBaby;
                currentAgent.myIndexInNetwork(end+1) = 1;
                currentAgent.lastIntendedShareIn(end+1) = 0;
                
                % applyCapacity = true: births must respect layer capacity.
                % Without it, every agent born during the run entered
                % capacity-limited layers unchecked -- thousands of entries
                % over a run with this much demographic growth, and the reason
                % urban occupancy still ran at 4-6x capacity after live slot
                % accounting was added to the choosePortfolio path.
                newBaby = assignInitialLayers(newBaby, utilityVariables, indexT, modelParameters, true);

                % Charge the newborn's places against the live count, so the
                % births in this timestep compete for the same slots as the
                % agents choosing in it.
                if enforceSlotsLive
                    nSlotL = size(utilityVariables.hasOpenSlots, 2);
                    babyPort = logical(newBaby.currentPortfolio(1, 1:nSlotL));
                    if any(babyPort)
                        liveCount(newBaby.matrixLocation, babyPort) = ...
                            liveCount(newBaby.matrixLocation, babyPort) + 1;
                        utilityVariables.hasOpenSlots = ...
                            (liveCount < utilityVariables.nExpected & utilityVariables.hardSlotCountYN) | ...
                            ~utilityVariables.hardSlotCountYN;
                    end
                end
                
                mapVariables.network(newBaby.id, currentAgent.id) = 1;
                mapVariables.network(currentAgent.id, newBaby.id) = 1;
                aliveList(newBaby.id) = true;
                                
                %update this line in the array used to choose new links
                % Layer columns only -- currentPortfolio carries a trailing
                % duration and fidelity pair (see assignInitialLayers.m).
                agentLayers(newBaby.id,:) = newBaby.currentPortfolio(1, 1:size(agentLayers,2));
                agentLocations(newBaby.id) = newBaby.matrixLocation;
                
            end
        end
        
        %draw number to see if agent meets a new agent
        if(rand() < currentAgent.pMeetNew)
            %%the next bit of code sets up input to the application-specific
            %%function that generates likelihoods for new links.  may need to be
            %%adjusted depending on application
            
            %the REASON it isn't totally exported to an
            %application-specific function is that passing the large
            %network matrix around can be costly
            
            %create a list of 'shared weighted connections' with other agents;
            connectionsWeight = mapVariables.network(currentAgent.id,1:length(agentList))*mapVariables.network(1:length(agentList), 1:length(agentList));
            %connectionsWeight = mapVariables.network(currentAgent.id,[livingAgents.id])*mapVariables.network([livingAgents.id], [livingAgents.id]);
            
            %make a list of existing connections and dead agents, who
            %should not have any weight in the calculations
            currentConnections = mapVariables.network(currentAgent.id,:) > 0;
            %currentConnections2 = mapVariables.network(currentAgent.id,:) > 0;
            %currentConnections([agentList.TOD] > 0 | [agentList.DOB] < 0) = true;
            %currentConnections2(~aliveList) = true;
            
           
            currentConnections(currentAgent.id) = true;
            
            %create a list of distances to other agents, based on their location
            distanceWeight = mapVariables.distanceMatrix(currentAgent.matrixLocation,agentLocations);

            
            %create a list of shared layers (in same location) using
            %agentLayers            
            sameLocation = agentLocations == currentAgent.matrixLocation;
            layerWeight = sparse(ones(sum(sameLocation),1),find(sameLocation), currentPortfolio * agentLayers(sameLocation,:)', 1, length(agentList));

            %identify the new network link using the appropriate function for this
            %simulation
            newAgentConnection = chooseNewLink(networkParameters, connectionsWeight, distanceWeight, layerWeight, currentConnections, aliveList);
            connectedAgent = agentList((newAgentConnection));
            
            %now update all network parameters
            strength = rand();
            mapVariables.network(currentAgent.id, connectedAgent.id) = strength;
            mapVariables.network(connectedAgent.id, currentAgent.id) = strength;
            
            currentAgentNetworkSize = length(currentAgent.network);
            partnerAgentNetworkSize = length(connectedAgent.network);
            currentAgent.myIndexInNetwork(currentAgentNetworkSize+1) = partnerAgentNetworkSize+1;
            connectedAgent.myIndexInNetwork(partnerAgentNetworkSize+1) = currentAgentNetworkSize+1;
            currentAgent.lastIntendedShareIn(end+1) = 0;
            connectedAgent.lastIntendedShareIn(end+1) = 0;
            currentAgent.network(end+1) = connectedAgent;
            connectedAgent.network(end+1) = currentAgent;
            
        end
        
        %draw number to see if agent has social interaction with existing
        %network
        if(rand() < currentAgent.pInteract && currentAgent.age >= modelParameters.ageLearn)
            if(~isempty(currentAgent.network))
                
                %can't talk to dead people
                potentialPartners = currentAgent.network([currentAgent.network.TOD] < 0);
                if(~isempty(potentialPartners))
                    %choose an agent in social network and exchange
                    
                    %have to name currentAgent and partner as outputs of the
                    %function, otherwise MATLAB simply creates a copy of them
                    %inside the function to do writing, and doesn't write to
                    %the original
                    partner = potentialPartners(randperm(length(potentialPartners),1));
                    
                    [currentAgent, partner] = interact(currentAgent, partner, indexT);
                    
                    
                    
                    currentAgent.knowsIncomeLocation = any(currentAgent.incomeLayersHistory,3);
                    partner.knowsIncomeLocation = any(partner.incomeLayersHistory,3);
                    
                    mapVariables.network(currentAgent.id, partner.id) = mapVariables.network(currentAgent.id, partner.id) + networkParameters.interactBump;
                    mapVariables.network(partner.id, currentAgent.id) = mapVariables.network(partner.id, currentAgent.id) + networkParameters.interactBump;
                end
            end
        end
        
        %draw number to see if agent learns anything randomly new about
        %income in the world around it
        if(rand() < currentAgent.pRandomLearn && currentAgent.age >= modelParameters.ageLearn)
            currentAgent.incomeLayersHistory(randperm(prod([sizeArray(1:2) indexT]),currentAgent.countRandomLearn)) = true;
            temp = randperm(prod(size(utilityVariables.hasOpenSlots)), currentAgent.countRandomLearn);
            currentAgent.heardOpening(temp) = utilityVariables.hasOpenSlots(temp);
            currentAgent.timeProbOpeningUpdated(temp) = indexT;
        end
        clear temp;
       
        %draw number to see if agent updates preferences on where to
        %be/what to do
        %% 

        % --- Decision trigger -------------------------------------------
        % Two reasons the agent may evaluate a portfolio change this cycle:
        %   (a) standard probabilistic trigger (pChoose) -- voluntary,
        %       improvement-seeking deliberation
        %   (b) distress-migration overlay (see Sections 4.4 / 5.1 of
        %       the paper) -- forced move triggered by one of four
        %       variants dispatched via checkDistressTrigger.m:
        %         1 = consecutive food-insecure years (Variant A)
        %         2 = wealth threshold + duration (Variant B)
        %         3 = cumulative wealth shortfall (Variant C)
        %         4 = stochastic depth-dependent (Variant D)
        %       This represents asset-liquidation distress migration that
        %       MIDAS's expected-income-NPV decision rule cannot otherwise
        %       generate, because wealth depletion in the standard rule
        %       traps agents rather than driving them to move.
        ageOK   = currentAgent.age >= modelParameters.ageDecision;
        postSpin = indexT > modelParameters.spinupTime;

        % Oracle trigger (arm 7) conditions on the exogenous forcing
        % itself: pass this-year and last-year agYF at the agent's
        % current location. Empty for all other arms (unused).
        oracleYF = [];
        if isfield(modelParameters, 'distressTriggerCode') && ...
           modelParameters.distressTriggerCode == 7
            iyO = agYFYearIndex(indexT, modelParameters, size(utilityVariables.agYF, 2));
            oracleYF = [utilityVariables.agYF(currentAgent.matrixLocation, iyO), ...
                        utilityVariables.agYF(currentAgent.matrixLocation, max(1, iyO - 1))];
        end

        % Distress-trace QA: for traced agents (same set the buffer trace
        % follows), request the per-condition diagnostics so each quarter
        % logs WHY the agent did or didn't fire (see append below the
        % decision block). Non-traced agents keep the short-circuited
        % single-output call.
        movedToLoc = 0;
        locAtDecision = currentAgent.matrixLocation;   % (distress trace) origin --
                        % matrixLocation is overwritten by a move before the
                        % trace row is appended, so capture it here
        traceThisAgent = bufferTraceOn && ismember(currentAgent.id, traceIDs);
        if traceThisAgent
            [distressFire, distressDiag] = ...
                checkDistressTrigger(currentAgent, modelParameters, indexT, oracleYF);
            isDistress = postSpin && ageOK && distressFire;
        else
            isDistress = postSpin && ageOK && ...
                         checkDistressTrigger(currentAgent, modelParameters, indexT, oracleYF);
        end

        isStandard = postSpin && ageOK && rand() < currentAgent.pChoose;

        if isDistress || isStandard
            % Capture pre-decision state so the live slot count can be
            % adjusted by the DIFFERENCE the decision makes. Recording only
            % the new portfolio would double-count agents who keep what they
            % already had.
            % Width taken from hasOpenSlots itself, so the portfolio slice
            % cannot drift out of step with the array being masked.
            nSlotLayers  = size(utilityVariables.hasOpenSlots, 2);
            slotPrevLoc  = currentAgent.matrixLocation;
            slotPrevPort = logical(currentAgent.currentPortfolio(1, 1:nSlotLayers));

            [currentAgent, moved] = choosePortfolio(currentAgent, utilityVariables, indexT, modelParameters, mapParameters, demographicVariables, mapVariables, isDistress);

            if enforceSlotsLive
                slotNewLoc  = currentAgent.matrixLocation;
                slotNewPort = logical(currentAgent.currentPortfolio(1, 1:nSlotLayers));
                if slotNewLoc ~= slotPrevLoc || any(slotNewPort ~= slotPrevPort)
                    liveCount(slotPrevLoc, slotPrevPort) = ...
                        max(0, liveCount(slotPrevLoc, slotPrevPort) - 1);
                    liveCount(slotNewLoc, slotNewPort) = ...
                        liveCount(slotNewLoc, slotNewPort) + 1;
                    utilityVariables.hasOpenSlots = ...
                        (liveCount < utilityVariables.nExpected & utilityVariables.hardSlotCountYN) | ...
                        ~utilityVariables.hardSlotCountYN;
                end
            end

            currentAgent.agentPortfolioHistory{indexT} = currentAgent.currentPortfolio;
            currentAgent.agentAspirationHistory{indexT} = currentAgent.currentAspiration;
            currentAgent.consideredHistory{indexT} = currentAgent.consideredPortfolios;
            if(~isempty(moved))
                movedToLoc = moved(2);   % (distress trace) destination
                migrations(indexT) = migrations(indexT) + 1;
                inMigrations(moved(2), indexT) = inMigrations(moved(2), indexT) + 1;
                outMigrations(moved(1), indexT) = outMigrations(moved(1), indexT) + 1;
                migrationMatrix(moved(1),moved(2),indexT) = migrationMatrix(moved(1),moved(2),indexT) + 1;
                currentAgent.moveHistory = [currentAgent.moveHistory; indexT currentAgent.matrixLocation currentAgent.visX currentAgent.visY];

                if isDistress
                    % Tag this as a distress-driven move and reset the
                    % counter associated with the active trigger variant,
                    % so the same agent isn't re-triggered immediately
                    % at the next cycle. (Variants 3 and 4 have no
                    % counter -- C reads wealthHistory on the fly, D
                    % is purely instantaneous. We still reset the A and
                    % B counters defensively, in case the agent was
                    % carrying both signals.)
                    distressMigrations(moved(1), indexT) = distressMigrations(moved(1), indexT) + 1;
                    currentAgent.consecutiveFIYears = 0;
                    currentAgent.quartersBelowWealthThreshold = 0;
                    currentAgent.lastShortfall = 0;   % Variant F: don't re-fire on the pre-move shortfall
                    % Timestamp for the Variant E re-fire cooldown (see
                    % checkDistressTrigger.m case 5). Set for all variants;
                    % only variant E reads it.
                    currentAgent.lastDistressMoveT = indexT;
                end
            end

            %update these line in the arrays used to choose new links
            agentLayers(currentAgent.id,:) = currentAgent.currentPortfolio(1,1:size(utilityVariables.utilityHistory,2));

            agentLocations(currentAgent.id) = currentAgent.matrixLocation;
        end

        % --- Distress-trace row (QA; traced agents, every post-spinup
        %     quarter, whether or not anything fired) ---
        if bufferTraceOn && postSpin && traceThisAgent
            distressTrace(end+1, :) = [ indexT, floor(currentYear), ...
                currentAgent.id, locAtDecision, ...
                distressDiag.lastYearIncome, distressDiag.baselineIncome, ...
                distressDiag.dropThreshold, double(distressDiag.incomeShock), ...
                distressDiag.lastShortfall, double(distressDiag.historyOK), ...
                double(distressDiag.cooldownOK), double(isDistress), ...
                movedToLoc ]; %#ok<AGROW>
        end

    end %for indexA = 1:currentRandOrder
    
    
    if (mod(indexT, modelParameters.incomeInterval) == 0)
        
        %construct the current counts of the number of agents occupying
        %each layer
        agentCityIndex = [livingAgents(:).matrixLocation]';
        for indexA = 1:length(livingAgents)
            currentPortfolio = logical(livingAgents(indexA).currentPortfolio(1,1:size(utilityVariables.utilityHistory,2)));
            countAgentsPerLayer(agentCityIndex(indexA), currentPortfolio, indexT) = countAgentsPerLayer(agentCityIndex(indexA), currentPortfolio, indexT) + 1;

            % --- SPATIAL-RESTRICTION VIOLATION TRACE (diagnostic, 2026-07-28) ---
            % vanilla is confined to Sava|Analanjirofo yet appears in all 22
            % regions, while rice_north/rice_south -- same mechanism -- are
            % correctly confined. Two hypotheses about the route have already
            % been wrong, so record the facts instead of inferring them:
            % WHEN the violation first appears (t = 1 means initialisation;
            % later means a runtime path), WHERE, and WHICH layer. Reports the
            % first 25 only. Delete this block once the route is found.
            viol = currentPortfolio(:)' & utilityVariables.spatiallyRestricted(agentCityIndex(indexA), :);
            if any(viol)
                if ~exist('violCount', 'var'); violCount = 0; end
                if violCount < 25
                    violLayers = find(viol);
                    for vL = violLayers
                        violCount = violCount + 1;
                        fprintf(['VIOLATION %2d: t=%d agent=%d loc=%d layer=%d ' ...
                                 'hasOpenSlots=%d nExpected=%g\n'], ...
                                 violCount, indexT, livingAgents(indexA).id, ...
                                 agentCityIndex(indexA), vL, ...
                                 utilityVariables.hasOpenSlots(agentCityIndex(indexA), vL), ...
                                 utilityVariables.nExpected(agentCityIndex(indexA), vL));
                        if violCount >= 25; break; end
                    end
                end
            end
        end
        
        %add income layer to history
        utilityVariables = updateHistory(utilityVariables, modelParameters, indexT, countAgentsPerLayer);
        
        %income functions are of the form f(k,m,nExpected,n_actual, base)
        % - note that this may change depending on the simulation - 
        %be sure that whatever your income functions are, the cellfun input
        %matches appropriately
%         for indexL = 1:numLayers
%             utilityVariables.utilityHistory(:,indexL, indexT) = arrayfun(utilityVariables.utilityLayerFunctions{indexL}, ...
%                 mapVariables.locations.locationX, ...
%                 mapVariables.locations.locationY, ...
%                 ones(numLocations,1)*indexT, ...
%                 countAgentsPerLayer(:,indexL, indexT), ...
%                 utilityVariables.utilityBaseLayers(:,indexL,indexT));
%         end
        
        %make payments and transfers as appropriate to all agents, and
        %update knowledge
        for indexA = 1:length(livingAgents)
            currentAgent = livingAgents(indexA);
            currentPortfolio = logical(currentAgent.currentPortfolio(1,1:size(utilityVariables.utilityHistory,2)));

            % Recency-weighted livelihood experience (EMA): decays each
            % quarter, replenished by the layers currently practiced.
            % Layers abandoned years ago fade (half-life ~3 yrs at decay
            % 0.94), so the attachment familiarity in choosePortfolio
            % binds to the agent's RECENT field of work.
            if attachTrackOn
                currentAgent.recentExperience = attachDecay * currentAgent.recentExperience + ...
                                                double(currentPortfolio(:));
            end
            %find out how much the current agent made, from each layer, and
            %update their knowledge
            
            % BUGFIX 2026-07-28 -- agent income was selecting the wrong layers.
            %
            % WAS: utilityHistory(loc, currentPortfolio(incomeForms(currentPortfolio)), indexT)
            %
            % That indexes currentPortfolio BY THE VALUES of incomeForms at the
            % held layers, rather than intersecting the two masks. For a
            % portfolio of layers 1, 2 and 7 it evaluates
            % incomeForms([1 2 7]) -> [1 1 1], then currentPortfolio([1 1 1]),
            % which selects positions 1-3. Income was therefore drawn from
            % near-arbitrary layers -- whichever ones the 0/1 flags happened to
            % point at -- not from the layers the agent actually works.
            %
            % agIncomeYTD (line ~617) has always used the correct form,
            % `agIncomeMask & currentPortfolio`, which is why the agricultural
            % income in the buffer trace looked sane (median 6.39) while the
            % annual total feeding the solvency test came out at ~0.015 and the
            % consumption gap was positive in 100% of agent-years.
            %
            % This is pre-existing, but the solvency redesign made the model
            % depend on personalIncomeHistory, so it only became load-bearing
            % now. Matching line 617's masking.
            %
            % BEHAVIOURAL SCOPE: this alters every agent's income in every
            % quarter. Expect wealth, migration flows and the calibration
            % targets all to move. It is the largest single behavioural change
            % in this batch despite being two lines.
            incomeLayers = currentPortfolio & utilityVariables.incomeForms(:)';
            newIncome = sum(utilityVariables.utilityHistory(currentAgent.matrixLocation, incomeLayers, indexT));

            % GUARD (2026-07-21): distress-move quarters can produce NaN
            % layer income (root cause under investigation -- distress
            % traces show a NaN spell starting at every distress-move
            % quarter, likely a 0/0 in layer utility at the arrival
            % location). One NaN quarter poisons the agent's trailing
            % income window for ~4 quarters (silently disabling the
            % Variant E/F income-shock evaluation) and contaminates
            % agIncomeYTD and the food-terms gap. Treat as zero income
            % for the quarter; warn once so the root cause stays visible.
            if ~isfinite(newIncome)
                if ~warnedNaNIncome
                    warning('midasMainLoop:nanIncome', ...
                        ['Non-finite layer income for agent %d at t=%d ' ...
                         '(loc %d) -- treated as 0 this quarter. Check ' ...
                         'utilityHistory at that location/timestep.'], ...
                        currentAgent.id, indexT, currentAgent.matrixLocation);
                    warnedNaNIncome = true;
                end
                newIncome = 0;
            end

            % --- Buffer productive-input effect (§2.5b) ---
            % Livestock is a productive input to farming (traction, manure,
            % milk), so the agricultural portion of income scales with the
            % herd. Losing the herd depresses ag income even in a good-rain
            % year (a second ratchet on continuation/post-kere years), and a
            % migrant whose remittance-fed buffer has rebuilt sees home
            % agriculture become attractive again -> return migration.
            if bufferOn
                agIncomeThisT = sum(utilityVariables.utilityHistory( ...
                    currentAgent.matrixLocation, ...
                    agIncomeMask & currentPortfolio, indexT));
                if ~isfinite(agIncomeThisT)   % same NaN family as newIncome guard above
                    agIncomeThisT = 0;
                end
                if bfLambdaProd > 0
                    prodMult  = 1 + bfLambdaProd * min(1, currentAgent.buffer / bfRef);
                    newIncome = newIncome + (prodMult - 1) * agIncomeThisT;
                    agIncomeThisT = prodMult * agIncomeThisT;
                end
                % Accumulate realised agricultural income (incl. the herd
                % multiplier) for the year. Read and reset at year-end:
                % the ag-agent consumption gap is measured in FOOD terms
                % (annual ag income vs annual subsistence), making the
                % buffer the first-line absorber of a failed harvest.
                currentAgent.agIncomeYTD = currentAgent.agIncomeYTD + agIncomeThisT;
            end


            %add in any income that has been shared in to the agent, to
            %include in sharing-out decision-making
            % Captured for the life trace before the reset below, so the
            % income reconciliation can account for it. The first version of
            % that check compared newIncome against the RAW layer sum only,
            % which left the herd bonus and shared-in remittances showing as
            % a one-sided residual -- a diagnostic artefact, not a model bug.
            sharedInThisQ = currentAgent.currentSharedIn;
            rawLayerIncome = newIncome;   % after the herd bonus, before sharing-in

            newIncome = newIncome + currentAgent.currentSharedIn;

            % FINAL-VALUE GUARD (2026-07-23): the layer-sum guard above
            % never triggered yet NaN still reached personalIncomeHistory
            % at distress-move quarters, so the corruption enters BETWEEN
            % the layer sum and this write -- via currentSharedIn or the
            % herd-productivity term (if agent.buffer is itself NaN then
            % (prodMult-1)*0 = NaN). Guard the final value and name the
            % culprit so the next trace pinpoints the source.
            if ~isfinite(newIncome)
                if ~warnedNaNIncome
                    warning('midasMainLoop:nanIncome', ...
                        ['Non-finite FINAL income for agent %d at t=%d (loc %d): ' ...
                         'sharedIn=%g, buffer=%g -- treated as 0 this quarter.'], ...
                        currentAgent.id, indexT, currentAgent.matrixLocation, ...
                        currentAgent.currentSharedIn, currentAgent.buffer);
                    warnedNaNIncome = true;
                end
                newIncome = 0;
            end
            currentAgent.currentSharedIn = 0;
            currentAgent.personalIncomeHistory(indexT) = newIncome;
            
            currentAgent.incomeLayersHistory(currentAgent.matrixLocation,currentPortfolio,indexT) = true;
            currentAgent.knowsIncomeLocation(currentAgent.matrixLocation, currentPortfolio) = true;
            
            
            % Wealth entering this quarter -- captured before any of the
            % quarter's arithmetic, so the life-trace residual below is a
            % genuine reconciliation rather than a tautology.
            wealthBeforeQ = currentAgent.wealth;

            % --- Subsistence cost for this quarter (moved up 2026-07-28) ---
            % Computed here rather than after the sharing block because
            % sharing is now assessed on SURPLUS, which needs it. Food gets
            % dearer in drought (entitlement failure): the effective
            % subsistence cost rises with local drought severity, and applies
            % to ALL agents in an affected region including non-farm
            % households. This is the only drought channel that reaches
            % agents who are not farming.
            subsistNow = agentParameters.subsistence_costs;
            if bufferOn && bfPhiFood > 0
                iyBuf = agYFYearIndex(indexT, modelParameters, nSimYearsBuf);
                agYFnow = utilityVariables.agYF(currentAgent.matrixLocation, iyBuf);
                subsistNow = subsistNow * (1 + bfPhiFood * (1 - agYFnow));
            end

            % DEPENDANTS DO NOT CONSUME DIRECTLY (2026-08-12).
            %
            % Agents below ageDecision hold no livelihood (see
            % assignInitialLayers.m) and so earn nothing. Charging them full
            % subsistence anyway would have them reach working age at roughly
            % -149 wealth after 60 quarters at a calibrated subsistence of
            % ~2.5, and since wealth gates the credit constraint, every new
            % entrant to the workforce would arrive credit-blocked out of
            % access costs and moves. That artefact would distort the labour
            % market far more than the capacity problem this change set out to
            % fix.
            %
            % A dependant's consumption is borne by its household. MIDAS has
            % no household structure -- an absence already recorded as a
            % limitation -- so the coherent representation is that dependants
            % are economically inert: no income, no consumption, not counted
            % in the employment or food-security metrics. They age, migrate
            % with nobody, may die on the age-appropriate mortality schedule,
            % and enter the workforce at ageDecision. That is the demographic
            % pipeline, with the ~15-year lag between a birth and a new worker
            % preserved.
            %
            % CONSEQUENCE FOR INTERPRETATION: subsistence_costs is now the
            % consumption requirement of a working-age agent INCLUDING its
            % share of dependants, not of one individual. That is defensible
            % because the parameter is calibrated against observed food
            % insecurity -- the fitted value absorbs whatever dependency
            % burden reproduces the Harvey et al. rate -- but it must be
            % stated that way in the methods, and the calibrated range has to
            % be re-derived rather than carried over.
            if currentAgent.age < modelParameters.ageDecision
                subsistNow = 0;
            end

            % SURPLUS SHARING (2026-07-28). Was:
            %     amountToShare = newIncome * incomeShareFraction
            % i.e. a flat fraction of GROSS income with no check that the
            % sender could feed themselves. On the traced figures that meant
            % an agent earning 10.25 a year shared 4.1 and was then short of
            % the 7.0 they needed to eat -- households remitting themselves
            % into deficit, which is neither observed behaviour nor
            % defensible in the write-up. Sharing now comes out of what is
            % left after subsistence, so a household in deficit sends
            % nothing. The network structure, tie-strength weighting and the
            % migration motive are all unchanged.
            % NB this does NOT need-test the RECIPIENT: transfers are still
            % split across all network ties in proportion to tie strength,
            % regardless of who is in distress. That remains a simplification
            % worth naming in the limitations.
            shareableSurplus = max(0, newIncome - subsistNow);
            amountToShare = shareableSurplus * currentAgent.incomeShareFraction;
            networkStrengths = mapVariables.network(currentAgent.id, [currentAgent.network(:).id]);

            % GUARD (2026-07-13): if every link has decayed to zero
            % strength, the share split below is 0/0 = NaN -- and since
            % NaN .* false is still NaN in MATLAB, the NaN survived the
            % feasibility mask, poisoned netIncome, and corrupted the
            % agent's wealth PERMANENTLY (observed as NaN wealth in
            % buffer traces; also poisons the averageWealth output and
            % Variant B/C/D distress state). Economically: an agent with
            % no functioning network ties shares nothing this quarter.
            % The amountToShare check also stops any upstream NaN/Inf
            % income from entering the transfer arithmetic.
            strengthSum = sum(networkStrengths);
            if ~isfinite(strengthSum) || strengthSum <= 0 || ~isfinite(amountToShare)
                potentialAmounts = zeros(size(networkStrengths));
            else
                potentialAmounts = (networkStrengths ./ strengthSum) * amountToShare;
            end
            
            %calculate costs associated with those shares
            remittanceFee = mapVariables.remittanceFee(currentAgent.matrixLocation, [currentAgent.network(:).matrixLocation]);
            remittanceRate = mapVariables.remittanceRate(currentAgent.matrixLocation, [currentAgent.network(:).matrixLocation]);
            remittanceCost = remittanceFee + remittanceRate / 100 .* potentialAmounts;
            
            %discard any potential transfers that exceed agent's threshold
            %for costs (i.e., agent stops making transfers if the
            %transaction costs are too much of the overall cost)
            feasibleTransfers = remittanceCost ./ potentialAmounts < currentAgent.shareCostThreshold;
            actualAmounts = (potentialAmounts - remittanceCost) .* feasibleTransfers;
            actualPayments = potentialAmounts .* feasibleTransfers;
            
            %share across network and keep the rest
            for indexN = 1:size(currentAgent.network,2)
                currentConnection = currentAgent.network(indexN);
                try
                currentConnection.lastIntendedShareIn(currentAgent.myIndexInNetwork(indexN)) = potentialAmounts(indexN);
                catch
                    f=1;
                end
                if(actualAmounts(indexN) > 0)
                    
                    %income shared in is held separate until that agent
                    %comes around to their own income loop
                    currentConnection.currentSharedIn = currentConnection.currentSharedIn + actualAmounts(indexN);
                    
                    mapVariables.network(currentAgent.id, currentConnection.id) = mapVariables.network(currentAgent.id, currentConnection.id) + networkParameters.shareBump;
                    mapVariables.network(currentConnection.id, currentAgent.id) = mapVariables.network(currentConnection.id, currentAgent.id) + networkParameters.shareBump;
                    
                end
            end
            netIncome = newIncome - sum(actualPayments);

            % subsistNow is now computed BEFORE the sharing block above, since
            % sharing is assessed on surplus. Do not recompute it here.
            currentAgent.wealth = currentAgent.wealth + netIncome - subsistNow;

            % --- Net income for the distress trigger (Variant F) ----------
            % REDESIGN 2026-07-28. The income-shock test used to read
            % personalIncomeHistory, i.e. GROSS income. That is the wrong
            % quantity: in a kere the damage falls substantially on the
            % EXPENDITURE side (food prices; FEWS NET recorded cassava at
            % +70-211% and maize at +103% over five-year averages in
            % 2021-22), so a household can hold its income and still be
            % unable to eat. Measured on gross income the trigger fired at
            % 1.9% in drought years against 1.75% in normal years -- it
            % could not see the drought at all.
            %
            % subsistNow above already carries the drought-scaled food cost
            % and applies to EVERY agent, farming or not, which is the only
            % drought channel reaching the ~80% of agents who are not
            % farmers. Agricultural agents take both this and the harvest
            % loss -- that compounding is intended, and is how Grand Sud
            % agro-pastoral households actually experience entitlement
            % failure.
            %
            % Remittances (sum(actualPayments)) are EXCLUDED: sharing-out is
            % a fixed fraction of gross income (line ~595) with no check that
            % the sender can cover their own subsistence, so netIncome would
            % mix hardship with a modelling artefact.
            %
            % CAUTION: the drought signal in this series comes from the
            % food-price spike, which is gated behind bufferOn && bfPhiFood
            % above. With bufferEnabled = false, subsistNow is a constant and
            % this series carries NO drought signal -- Variant F will be
            % inert. Run with bufferEnabled = true.
            currentAgent.netIncomeHistory(indexT) = newIncome - subsistNow;

            % ================= AGENT LIFE-HISTORY TRACE =================
            % One row per traced agent-quarter. No-op unless
            % modelParameters.traceAgentLife is true.
            %
            % The RESIDUAL columns are the point of this: each is a
            % quantity that must be zero to machine precision if the
            % accounting is right. Sorting the output by |residual| surfaces
            % an arithmetic error immediately, rather than depending on a
            % reader noticing a number looks wrong. Three of the four bugs
            % found on 2026-07-28 were accounting errors of exactly this
            % kind (income drawn from the wrong layers, a duration written
            % into a layer column, a portfolio trimmed to the wrong width).
            if agentLifeTrace('enabled')
                isAgNow = any(agIncomeMask & currentPortfolio);
                % Register southern ag agents on first sight, up to the cap.
                if ~agentLifeTrace('isTraced', currentAgent.id) && isAgNow && ...
                   ismember(currentAgent.matrixLocation, agentLifeTrace('regions'))
                    agentLifeTrace('register', currentAgent.id);
                end
                if agentLifeTrace('isTraced', currentAgent.id)
                    r = struct();
                    r.t          = indexT;
                    r.year       = modelParameters.startYear + floor((indexT - 1) / modelParameters.cycleLength);
                    r.quarter    = mod(indexT - 1, modelParameters.cycleLength) + 1;
                    r.agentID    = currentAgent.id;
                    % TRACE FIX (2026-08-09). This was indexT - DOB, which is
                    % NOT age: buildWorld.m:103 sets DOB = 0 for every agent
                    % present at initialisation, so for them the column was
                    % simply the timestep index and rose to 146 in a 170-step
                    % run. Only agents BORN in-simulation (newBaby.DOB =
                    % indexT) had a true age, and even then in quarters rather
                    % than years. currentAgent.age is the model's own age
                    % variable, in years (incremented by cyclesPerTimeStep =
                    % 1/cycleLength each step), and is what ageDecision,
                    % ageLearn and the fertility test all compare against.
                    % Diagnostic output only -- no model behaviour depends on
                    % this line. Tenure is kept separately because it is the
                    % right denominator for "quarters observed".
                    r.age        = currentAgent.age;
                    r.tenure_q   = indexT - currentAgent.DOB;
                    r.loc        = currentAgent.matrixLocation;
                    r.isAg       = double(isAgNow);
                    r.attachment = currentAgent.livelihoodAttachment;

                    % Portfolio, human-readable and as a count
                    r.layers     = agentLifeTrace('layerstring', currentPortfolio);
                    r.nLayers    = sum(currentPortfolio);

                    % Regional drought state
                    if bufferOn
                        iyL = agYFYearIndex(indexT, modelParameters, nSimYearsBuf);
                        r.agYF = utilityVariables.agYF(currentAgent.matrixLocation, iyL);
                    else
                        r.agYF = 1;
                    end
                    r.subsistBase = agentParameters.subsistence_costs;
                    r.subsistNow  = subsistNow;
                    r.inflator    = subsistNow / max(agentParameters.subsistence_costs, eps);

                    % Income and transfers
                    r.grossIncome = newIncome;
                    r.sharedOut   = sum(actualPayments);
                    r.netIncome   = netIncome;
                    r.agIncomeYTD = currentAgent.agIncomeYTD;

                    % Wealth, with the reconciliation residual
                    r.wealth_start   = wealthBeforeQ;
                    r.wealth_end     = currentAgent.wealth;
                    r.wealth_expect  = wealthBeforeQ + netIncome - subsistNow;
                    r.wealth_resid   = currentAgent.wealth - r.wealth_expect;

                    % Income reconciliation. newIncome legitimately contains
                    % three components, so all three must appear here or the
                    % residual measures the omission rather than an error:
                    %   (a) raw income from the layers held
                    %   (b) the herd productivity bonus, (prodMult-1)*agIncome
                    %   (c) remittances shared in from the network
                    r.layerIncome = full(sum(utilityVariables.utilityHistory( ...
                        currentAgent.matrixLocation, incomeLayers, indexT)));
                    r.prodBonus   = rawLayerIncome - r.layerIncome;   % (b)
                    r.sharedIn    = sharedInThisQ;                    % (c)
                    r.income_expect = r.layerIncome + r.prodBonus + r.sharedIn;
                    r.income_resid  = newIncome - r.income_expect;

                    % Survival / exit. A traced agent stops appearing when it
                    % dies (drops out of livingAgents), so TOD distinguishes
                    % death from the trace simply ending at the run horizon.
                    r.TOD      = currentAgent.TOD;
                    r.inSouth  = double(ismember(currentAgent.matrixLocation, agentLifeTrace('regions')));

                    r.buffer      = currentAgent.buffer;
                    r.lastShortfall = currentAgent.lastShortfall;
                    r.trapped     = double(currentAgent.trapped);

                    agentLifeTrace('life', r);
                end
            end

            % Safety net (should be unreachable now the sharing guard is
            % in): never let NaN/Inf wealth persist. Restore the last
            % finite wealth rather than zeroing -- wealth = 0 would
            % register as a large wealth CHANGE (a fake FI event for a
            % rich agent, debt forgiveness for an indebted one) and
            % distort the FI calibration target. Warn once per run so a
            % NEW corruption source announces itself instead of being
            % silently absorbed.
            if ~isfinite(currentAgent.wealth)
                prevW = 0;
                for pw = indexT-1:-1:max(1, indexT-8)
                    if pw <= length(currentAgent.wealthHistory) && ...
                       ~isempty(currentAgent.wealthHistory{pw}) && ...
                       isfinite(currentAgent.wealthHistory{pw})
                        prevW = currentAgent.wealthHistory{pw};
                        break;
                    end
                end
                currentAgent.wealth = prevW;
                if ~warnedNaNWealth
                    warning('midasMainLoop:nanWealth', ...
                        ['Non-finite wealth for agent %d at t=%d despite the ' ...
                         'sharing guard -- restored last finite value. A new ' ...
                         'NaN source exists upstream; investigate.'], ...
                        currentAgent.id, indexT);
                    warnedNaNWealth = true;
                end
            end
            currentAgent.wealthHistory{indexT} = currentAgent.wealth;

            % --- Wealth-threshold quarter counter (Variant B / distress) ---
            % Updated every quarter (not just at year-end) because Variant B
            % counts consecutive quarters below the threshold. We update
            % the counter regardless of which variant is active so the
            % state is always coherent; checkDistressTrigger gates on
            % whether to actually use it.
            if isfield(modelParameters, 'distressWealthThreshold')
                if currentAgent.wealth < modelParameters.distressWealthThreshold
                    currentAgent.quartersBelowWealthThreshold = ...
                        currentAgent.quartersBelowWealthThreshold + 1;
                else
                    currentAgent.quartersBelowWealthThreshold = ...
                        max(0, currentAgent.quartersBelowWealthThreshold - 1);
                end
            end

            % --- Food insecurity tracking (ANNUAL, at year-end only) ---
            % We only check at year-end (every cycleLength timesteps),
            % comparing the agent's current wealth to its wealth at the
            % end of the previous year. wealthHistory{T-cycleLength} is
            % the previous year-end wealth; if it's empty the agent
            % didn't exist a full year ago and we skip them.
            %
            % wealth_end < wealth_start <=> annual netIncome < annual
            % subsistence consumption, because the per-timestep wealth
            % accumulator already nets income against subsistence each
            % step. So a wealth decline over the year IS the annual
            % equivalent of the original "netIncome < subsistence_costs"
            % check -- without the harvest-cycle artefact.
            if mod(indexT, modelParameters.cycleLength) == 0
                prevYearEndIdx = indexT - modelParameters.cycleLength;
                yearIdx        = indexT / modelParameters.cycleLength;
                loc            = currentAgent.matrixLocation;
                isAgAgent      = any(currentPortfolio(agLayerIdx));

                % --- Farm-entry starter endowment (§2.1) ---
                % The first time an agent is farming, it acquires a starter
                % livestock/grain stock (bought with the small-farm entry it
                % just paid for). One-time, capped, and independent of the
                % annual dynamics below. Represents "people buy livestock to
                % help with the harvest" -- so the buffer is tied to taking up
                % farming, not to birth.
                % NON-AG STARTER STOCK (2026-07-28): non-farming households also
                % hold a small non-livestock store, granted at bfNonAgScale of
                % the farm endowment, so they absorb a first bad year too. They
                % receive it once, on the same one-time basis.
                if bufferOn && ~currentAgent.farmBufferGranted
                    if isAgAgent
                        currentAgent.buffer = max(currentAgent.buffer, bfInit);
                        currentAgent.farmBufferGranted = true;
                    else
                        currentAgent.buffer = max(currentAgent.buffer, bfInit * bfNonAgScale);
                        currentAgent.farmBufferGranted = true;
                    end
                end

                havePrevWealth = (prevYearEndIdx >= 1) && ...
                                 (prevYearEndIdx <= length(currentAgent.wealthHistory)) && ...
                                 ~isempty(currentAgent.wealthHistory{prevYearEndIdx});

                if havePrevWealth
                    wealthStartVal = currentAgent.wealthHistory{prevYearEndIdx};
                    wealthEndVal   = currentAgent.wealth;

                    if bufferOn
                        % --- Annual livestock/grain buffer dynamics (§2.1-2.4) ---
                        iyB     = agYFYearIndex(indexT, modelParameters, nSimYearsBuf);
                        agYFloc = utilityVariables.agYF(loc, iyB);
                        bufStart = currentAgent.buffer;   % (trace) level entering the year
                        buf     = bufStart;

                        % PER-AGENT STOCK SIZE (2026-07-28). Ag agents hold the
                        % full livestock/grain buffer. Non-ag households hold a
                        % smaller non-livestock store (grain, small stock, petty
                        % savings), scaled by bfNonAgScale -- they absorb a
                        % first bad year but empty sooner. Keeping the herd
                        % itself ag-only is deliberate: the pastoral share is
                        % being corrected separately via layer hard slots, not
                        % by giving everyone cattle.
                        if isAgAgent
                            aCap = bfCap;  aFloor = bfFloor;  aAccrualCap = bfAccrualCap;
                        else
                            aCap        = bfCap        * bfNonAgScale;
                            aFloor      = bfFloor      * bfNonAgScale;
                            aAccrualCap = bfAccrualCap * bfNonAgScale;
                        end

                        % (i) Drought mortality: herd/store dies in proportion
                        %     to local drought severity (climate -> asset, one link).
                        buf = buf * (1 - bfMortMax * (1 - agYFloc));
                        bufAfterMort = buf;               % (trace)

                        % (ii) Slow, concave biological growth (capped): a
                        %      near-empty buffer rebuilds slowly -> the fast-
                        %      crash / slow-recovery asymmetry.
                        buf = min(aCap, buf * (1 + bfGrowthRate));
                        bufAfterGrow = buf;               % (trace)

                        % (iii) SOLVENCY THIS YEAR (REDESIGN 2026-07-28).
                        %   A household is in distress when its way of life is
                        %   no longer viable: it cannot meet the year's
                        %   subsistence requirement from income plus the stock
                        %   it can release without eating its breeding animals.
                        %   Resources are consumed in the documented coping
                        %   order -- income first, then stock down to the
                        %   reproductive floor, then distress. WEALTH IS
                        %   DELIBERATELY EXCLUDED: only 7% of rural Malagasy
                        %   adults have bank access (Findex), and the field
                        %   literature is explicit that livestock IS the
                        %   savings mechanism "in the absence of banks". A
                        %   separate cash stock would double-count the buffer
                        %   and model a vehicle these households do not have.
                        %
                        %   ENTITLEMENT SPLIT (Sen). Owning food is not the
                        %   same as being able to buy it. A share bfDirectFrac
                        %   of releasable stock is consumed DIRECTLY -- eaten,
                        %   not traded -- so it meets the requirement at
                        %   UN-INFLATED cost. The remainder must be sold into a
                        %   collapsed market to buy grain at spiked prices, and
                        %   carries both penalties. Field data supports the
                        %   exchange channel dominating: livestock sales funded
                        %   >56% of cash food expenditure in the 2013-14 crop
                        %   failure, hence bfDirectFrac well below 0.5.
                        %
                        %   The multi-year response is EMERGENT, not imposed:
                        %   year one the stock covers most of the requirement;
                        %   year two it sits at the floor and the full inflated
                        %   requirement lands on income alone. No window or
                        %   drop-fraction parameter is involved.
                        inflator = 1 + bfPhiFood * (1 - agYFloc);
                        convFac  = max(0.05, 1 - bfPhiLv * (1 - agYFloc));

                        % TOTAL income this year (all layers + shared-in), not
                        % agricultural income alone: the food-price shock hits
                        % every household regardless of livelihood, so the
                        % resources meeting it must be counted the same way.
                        incQ0        = max(1, indexT - modelParameters.cycleLength + 1);
                        annualIncome = sum(currentAgent.personalIncomeHistory(incQ0:indexT));

                        % Releasable stock: everything above the reproductive
                        % floor. Below it the household defends breeding stock.
                        sellable = max(0, buf - aFloor);

                        % ORDER OF RESOURCES: income is spent first. Stock is
                        % only released once income cannot meet the bill -- a
                        % household that can afford food does not eat its herd.
                        % DEPENDANTS (2026-08-12). The quarterly wealth debit
                        % already sets subsistNow = 0 below working age, but
                        % this annual solvency block builds its requirement
                        % from annualSubsist directly, so without the same
                        % gate a dependant would face a full annual bill
                        % against zero income: it would drain whatever store
                        % it held and carry a permanent shortfall. The
                        % shortfall never triggers anything, because distress
                        % migration is gated on ageOK, but it is incoherent
                        % accounting and would corrupt the buffer statistics.
                        % Zero requirement gives need = 0 and agSurplus = 0,
                        % so a dependant neither draws down nor accrues.
                        subsistThisAgent = annualSubsist;
                        if currentAgent.age < modelParameters.ageDecision
                            subsistThisAgent = 0;
                        end
                        fullCost  = subsistThisAgent * inflator;
                        need      = max(0, fullCost - annualIncome);
                        agSurplus = annualIncome - fullCost;

                        gap        = need;   % (trace) cash shortfall before drawdown
                        directUsed = 0;
                        food       = 0;
                        drawFood   = 0;      % (trace) total stock released
                        accrStore  = 0;      % (trace)

                        if need > 0
                            % Channel 1 -- DIRECT CONSUMPTION. Stock eaten
                            % rather than traded meets the requirement at
                            % un-inflated cost, so each unit released removes
                            % `inflator` of cash need. This is the entitlement
                            % advantage of owning your food.
                            directUsed = min(bfDirectFrac * sellable, need / inflator);
                            need       = need - directUsed * inflator;

                            % Channel 2 -- EXCHANGE. The rest must be sold into
                            % a collapsed market (convFac) to buy grain that has
                            % itself risen in price: both penalties apply.
                            exchAvail = max(0, sellable - directUsed);
                            food      = min(need, exchAvail * convFac);
                            need      = need - food;

                            buf = buf - directUsed - food / convFac;
                            currentAgent.wealth = currentAgent.wealth + food;

                            % Unmet after the stock is drawn to its floor. This
                            % is the distress condition: the household cannot
                            % eat without breaking into its breeding animals.
                            shortfall = need;
                            drawFood  = directUsed + food;
                        else
                            % Surplus year: agri-pastoralists divert a share of
                            % the AGRICULTURAL surplus into the buffer
                            % (precautionary saving by default). Non-ag agents
                            % keep their cash.
                            %
                            % RATE-LIMITED ACCRUAL (2026-07-08): annual accrual
                            % is capped at bfAccrualCap. Herds are rebuilt
                            % biologically over ~3-4 years, not repurchased in
                            % a single boom year. Without this cap the post-
                            % drought REBOUND year (chain audit: +4-5% above
                            % trend) refills the buffer to its ceiling in one
                            % step, erasing the multi-year depletion memory
                            % that produces first-vs-continuation cascade
                            % compounding -- i.e. it destroys exactly what the
                            % buffer exists to provide.
                            % ACCRUAL NOW APPLIES TO ALL AGENTS (2026-07-28).
                            % Non-ag households hold a smaller non-livestock
                            % store (grain, small stock, petty savings) scaled
                            % by bfNonAgScale, so they too absorb a first bad
                            % year rather than breaking immediately. Their
                            % smaller store empties sooner, which is the
                            % intended difference.
                            shortfall = 0;
                            if agSurplus > 0
                                store = bfAccrualFrac * agSurplus;
                                store = min(store, aAccrualCap);
                                store = min(store, max(0, aCap - buf));
                                buf   = buf + store;
                                currentAgent.wealth = currentAgent.wealth - store;
                                accrStore = store;        % (trace)
                            end
                        end

                        currentAgent.buffer = buf;
                        wealthEndVal = currentAgent.wealth;           % buffer moved wealth
                        currentAgent.wealthHistory{indexT} = currentAgent.wealth;
                        currentAgent.bufferHistory{indexT} = buf;

                        % Record the unmet shortfall for the Variant F
                        % trigger (checkDistressTrigger case 6): positive
                        % only when the food gap exceeded what the buffer
                        % above its floor could cover. Refreshed every
                        % year-end; reset defensively on a distress move.
                        currentAgent.lastShortfall = shortfall;

                        % FI is now unmet consumption AFTER drawing the buffer.
                        wasInsecure = shortfall > 0;

                        % --- Agent trace logging ---
                        if bufferTraceOn && ismember(loc, traceRegions)
                            if ~ismember(currentAgent.id, traceIDs) && ...
                               numel(traceIDs) < traceMaxAgents && isAgAgent
                                traceIDs(end+1) = currentAgent.id; %#ok<AGROW>
                            end
                            if ismember(currentAgent.id, traceIDs)
                                % annual realised AG income (incl. herd
                                % multiplier) -- the same quantity the food-
                                % terms gap is computed from. (Previously this
                                % summed personalIncomeHistory, i.e. TOTAL
                                % income incl. non-ag and shared-in.)
                                agInc = currentAgent.agIncomeYTD;
                                calYear = modelParameters.startYear + iyB - 1;
                                bufferTrace(end+1, :) = [ calYear, currentAgent.id, loc, ...
                                    double(isAgAgent), agYFloc, bufStart, bufAfterMort, ...
                                    bufAfterGrow, gap, drawFood, accrStore, buf, ...
                                    wealthStartVal, currentAgent.wealth, agInc, ...
                                    double(currentAgent.farmBufferGranted) ]; %#ok<AGROW>
                            end
                        end
                    else
                        wasInsecure = (wealthEndVal < wealthStartVal);
                    end

                    % WORKING-AGE RESTRICTION (2026-08-12).
                    %
                    % These counters previously incremented for EVERY living
                    % agent, children included. That mattered in two ways once
                    % sub-decision-age agents stopped holding livelihoods
                    % (see assignInitialLayers.m):
                    %
                    %   agFrac_nat_run = agentCount_ag / agentCount_all is
                    %   scored against the FAOSTAT employment-in-agriculture
                    %   share, an ILO 15+ concept. Counting under-15s in the
                    %   denominator compared a whole-population ratio against
                    %   a labour-force one -- and with roughly 40% of
                    %   Madagascar's population under 15 that is a large
                    %   mismatch. Since children now hold no agricultural
                    %   layer they would have left the numerator while
                    %   remaining in the denominator, pushing the metric
                    %   further below its 0.64 target.
                    %
                    %   foodInsecureRate_* would have counted children as
                    %   food-insecure households: zero income by construction,
                    %   full subsistence charged, no household to depend on
                    %   because MIDAS has no household structure. That is an
                    %   artefact of the agent representation, not a finding
                    %   about Madagascar, and it would have swamped the
                    %   Harvey et al. comparison.
                    %
                    % Both metrics now describe the working-age population,
                    % matching the sources they are calibrated against.
                    % Dependants are still simulated -- they age, migrate with
                    % nobody, die, and consume -- they are simply not counted
                    % as employment or food-security units.
                    % All-ages headcount, kept SEPARATELY. agentCount_all is
                    % now a working-age series, but buildNextRound.m divides
                    % model migration by it to form a per-capita rate and
                    % compares that against census migration divided by TOTAL
                    % census population. Restricting one side and not the
                    % other would shrink the model denominator by roughly the
                    % under-15 share and bias every level-based migration
                    % error metric, silently. Migration counts are all-ages
                    % events, so they need an all-ages denominator.
                    agentCount_pop(loc, yearIdx) = agentCount_pop(loc, yearIdx) + 1;

                    countsAgeOK = currentAgent.age >= modelParameters.ageDecision;
                    if countsAgeOK
                        agentCount_all(loc, yearIdx) = agentCount_all(loc, yearIdx) + 1;
                        bufferSum_all(loc, yearIdx) = bufferSum_all(loc, yearIdx) + currentAgent.buffer;
                        if wasInsecure
                            foodInsecureCount_all(loc, yearIdx) = foodInsecureCount_all(loc, yearIdx) + 1;
                        end
                        if isAgAgent
                            agentCount_ag(loc, yearIdx) = agentCount_ag(loc, yearIdx) + 1;
                            if wasInsecure
                                foodInsecureCount_ag(loc, yearIdx) = foodInsecureCount_ag(loc, yearIdx) + 1;
                            end
                        end
                    end

                    % Update consecutive-FI counter used by the distress-
                    % migration overlay. Strict consecutive interpretation
                    % would reset to 0 on any non-FI year; we use
                    % decrement-by-1 (floor at 0) so that one good year
                    % doesn't fully restore an agent that has been food-
                    % insecure for several years -- more consistent with
                    % the empirical kere recovery pattern.
                    if wasInsecure
                        currentAgent.consecutiveFIYears = currentAgent.consecutiveFIYears + 1;
                    else
                        currentAgent.consecutiveFIYears = max(0, currentAgent.consecutiveFIYears - 1);
                    end
                end

                % Reset the annual ag-income accumulator at year-end for
                % ALL agents (including those without a full prior year of
                % wealth history, for whom the buffer block above was
                % skipped) so next year's food-terms gap starts clean.
                if bufferOn
                    currentAgent.agIncomeYTD = 0;
                end
            end
        end
    end %if (mod(indexT, modelParameters.incomeInterval) == 0)
    
    %ANY ACTIONS NECESSARY FOR NEXT TIMESTEP, TO OCCUR AFTER INCOME UPDATED
    %update the system-wide record of whether a layer has open slots or not
    utilityVariables.hasOpenSlots = countAgentsPerLayer(:,:,indexT) < utilityVariables.nExpected & utilityVariables.hardSlotCountYN | ~utilityVariables.hardSlotCountYN;

    %update our time path of trapped agents
    trappedHistory([agentList(:).trapped] > 0,indexT) = 1;
    %Count number of agents with aspiration for each layer in time T
   
    if (modelParameters.visualizeYN & mod(indexT, modelParameters.visualizeInterval) == 0)
        
        mapVariables.indexT = indexT;
        mapVariables.cycleLength = modelParameters.cycleLength;
        %visualize the map
        [mapHandle] = visualizeMap(livingAgents, mapVariables, mapParameters, modelParameters);
            set(gcf,'Position',mapParameters.position)
        drawnow();
        fprintf([runName ' - Map updated.\n']);
        if(modelParameters.saveImg)
           print('-dpng','-painters','-r100', [mapParameters.saveDirectory modelParameters.shortName num2str(10000+indexT) '.png']); 
           fprintf([runName ' - Map saved.\n']);                
        end

    end
    
    averageWealth(indexT) = mean([livingAgents(:).wealth],'omitnan');
    temp = reshape(cell2mat({livingAgents.expectedProbOpening}), size(livingAgents(1).expectedProbOpening, 1), size(livingAgents(1).expectedProbOpening,2), length(livingAgents));
    averageExpectedOpening(:,:,indexT) = mean(temp,3);
    clear temp;

    %%%%
    %averageExpectedOpening(:,:,indexT) = 0;
    numLivingAgents = length(livingAgents);
    if(numLivingAgents > 0)
        for indexI = 1:length(livingAgents)
            averageExpectedOpening(:,:,indexT) = averageExpectedOpening(:,:,indexT) + livingAgents(indexI).expectedProbOpening;        
        end
        averageExpectedOpening(:,:,indexT) = averageExpectedOpening(:,:,indexT) / indexI;
    end
    %%%%
    
    if(modelParameters.listTimeStepYN) % indexT = 15
        % fprintf([runName ' - Time step ' num2str(indexT) ' of ' num2str(modelParameters.timeSteps) ' - ' num2str(migrations(indexT)) ' migrations across ' num2str(numLivingAgents) ' total agents.\n']);
        if indexT <= modelParameters.spinupTime 
            fprintf([runName ' - ' modelParameters.sspScenario ': initialisation step ' num2str(indexT) ' of ' num2str(modelParameters.spinupTime) '.\n']);
        else 
            sim_timestep = indexT-modelParameters.spinupTime ;
            year = num2str(modelParameters.startYear + floor(sim_timestep /modelParameters.cycleLength));
            quarter = num2str(mod(sim_timestep-1,modelParameters.cycleLength)+1);
            fprintf([runName ' - ' modelParameters.sspScenario ': ' year '-Q' quarter ' of ' num2str(modelParameters.endYear) ' - ' num2str(migrations(indexT)) ' migrations across ' num2str(numLivingAgents) ' total agents.\n']);
        end 
    end
    
    %%update portfolioHistory
    for indexJ = 1:numLocations
       portfolioHistory{indexJ, indexT} = {(agentList([agentList.matrixLocation] == indexJ).currentPortfolio)};
    end
end %for indexT = 1:modelParameters.timeSteps

%prepare outputs
outputs.averageWealth = averageWealth;
outputs.countAgentsPerLayer = countAgentsPerLayer;
outputs.migrations = migrations;
agentLifeTrace('flush');

outputs.locations = mapVariables.locations;
outputs.inMigrations = inMigrations;
outputs.outMigrations = outMigrations;
outputs.distressMigrations = distressMigrations;
outputs.migrationMatrix = migrationMatrix;
outputs.averageExpectedOpening = averageExpectedOpening;
outputs.utilityHistory = utilityVariables.utilityHistory;
outputs.portfolioHistory = portfolioHistory;
outputs.trappedHistory = trappedHistory;
% Food insecurity: fraction of agent-YEARS where wealth declined (annual
% income failed to cover annual subsistence), post-spinup, per location.
% Year-indexed arrays (nLocations x nYearsTotal). Strip the spinup
% portion: any year that ends entirely within or partially overlapping
% the spinup period is dropped, leaving only fully post-spinup years.
spinupYears = ceil(modelParameters.spinupTime / modelParameters.cycleLength);
firstPostSpinupYear = spinupYears + 1;
if firstPostSpinupYear > size(foodInsecureCount_ag, 2)
    firstPostSpinupYear = size(foodInsecureCount_ag, 2);   % degenerate guard
end
outputs.foodInsecureCount_ag   = foodInsecureCount_ag(:,  firstPostSpinupYear:end);
outputs.foodInsecureCount_all  = foodInsecureCount_all(:, firstPostSpinupYear:end);
outputs.agentCount_ag          = agentCount_ag(:,         firstPostSpinupYear:end);
outputs.agentCount_all         = agentCount_all(:,        firstPostSpinupYear:end);
outputs.agentCount_pop         = agentCount_pop(:,        firstPostSpinupYear:end);
% Mean livestock/grain buffer per location-year (post-spinup). Zero
% everywhere when bufferEnabled is false. The year-on-year drop in a
% drought year is the mortality signal; the level is the absorption state.
outputs.bufferMean             = bufferSum_all(:, firstPostSpinupYear:end) ./ ...
                                 max(1, agentCount_all(:, firstPostSpinupYear:end));
outputs.aspirationHistory = aspirationHistory;

% --- Buffer agent-trace write-out (diagnostic) ---
if bufferTraceOn
    traceHdr = {'year','agentID','loc','isAg','agYF','buf_start', ...
                'after_mortality','after_growth','gap','drawdown','accrual', ...
                'buf_end','wealth_start','wealth_end','ag_income','farmGranted'};
    outputs.bufferTrace       = bufferTrace;
    outputs.bufferTraceHeader = traceHdr;

    % Distress-trace: one row per traced agent per post-spinup quarter.
    % Columns: quarter timestep; calendar year; agent id; location;
    % trailing-year income; own baseline (mean of prior window years);
    % firing threshold (dropFrac x baseline); income-shock flag; last
    % year-end unmet shortfall; history-sufficient flag; cooldown-clear
    % flag; fired flag; destination location (0 = no move this quarter).
    distressHdr = {'quarter','year','agentID','loc','lastYearIncome', ...
                   'baselineIncome','dropThreshold','incomeShock', ...
                   'lastShortfall','historyOK','cooldownOK','fired','movedTo'};
    outputs.distressTrace       = distressTrace;
    outputs.distressTraceHeader = distressHdr;
    if isfield(modelParameters, 'traceBufferFile') && ~isempty(modelParameters.traceBufferFile)
        try
            dFile = strrep(modelParameters.traceBufferFile, '.csv', '_distress.csv');
            writetable(array2table(distressTrace, 'VariableNames', distressHdr), dFile);
            fprintf('%s - distress trace (%d rows) written to %s\n', ...
                    runName, size(distressTrace, 1), dFile);
        catch traceErr
            warning('midasMainLoop: could not write distress trace: %s', traceErr.message);
        end
    end
    if isfield(modelParameters, 'traceBufferFile') && ~isempty(modelParameters.traceBufferFile)
        try
            traceTbl = array2table(bufferTrace, 'VariableNames', traceHdr);
            writetable(traceTbl, modelParameters.traceBufferFile);
            fprintf('%s - buffer trace (%d rows, %d agents) written to %s\n', ...
                    runName, size(bufferTrace,1), numel(unique(bufferTrace(:,2))), ...
                    modelParameters.traceBufferFile);
        catch traceErr
            warning('midasMainLoop: could not write buffer trace: %s', traceErr.message);
        end
    end
end

agentList = agentList(1:agentParameters.currentID-1);
agentSummary = table([agentList(:).id]','VariableNames',{'id'});
agentSummary.wealth = [agentList(:).wealth]';
agentSummary.location = [agentList(:).location]';
agentSummary.pInteract = [agentList(:).pInteract]';
agentSummary.pChoose = [agentList(:).pChoose]';
agentSummary.pRandomLearn = [agentList(:).pRandomLearn]';
agentSummary.countRandomLearn = [agentList(:).countRandomLearn]';
agentSummary.numBestLocation = [agentList(:).numBestLocation]';
agentSummary.numBestPortfolio = [agentList(:).numBestPortfolio]';
agentSummary.numRandomLocation = [agentList(:).numRandomLocation]';
agentSummary.numRandomPortfolio = [agentList(:).numRandomPortfolio]';
agentSummary.numPeriodsEvaluate = [agentList(:).numPeriodsEvaluate]';
agentSummary.numPeriodsMemory = [agentList(:).numPeriodsMemory]';
agentSummary.discountRate = [agentList(:).discountRate]';
agentSummary.rValue = [agentList(:).rValue]';
agentSummary.bList = [agentList(:).bList]';
agentSummary.TOD = [agentList(:).TOD]';
agentSummary.trapped = [agentList(:).trapped]';
%agentSummary.wealthHistory = [agentList(:).wealthHistory]';



tempCurrentPortfolio = cell(length(agentList),1);
tempFirstPortfolio = cell(length(agentList),1);
tempPortfolioHistory = cell(length(agentList),1);
tempAspirationHistory = cell(length(agentList),1);
tempWealthHistory = cell(length(agentList),1);
tempNetwork = cell(length(agentList),1);
tempMove = cell(length(agentList),1);
tempAccess = cell(length(agentList),1);
tempConsideredHistory = cell(length(agentList),1);
tempTraining = cell(length(agentList),1);
tempExperience = cell(length(agentList),1);

for indexI = 1:length(agentList)
    tempCurrentPortfolio{indexI} = agentList(indexI).currentPortfolio;
    tempFirstPortfolio{indexI} = agentList(indexI).firstPortfolio;
    tempPortfolioHistory{indexI} = agentList(indexI).agentPortfolioHistory;
    tempAspirationHistory{indexI} = agentList(indexI).agentAspirationHistory;
    tempConsideredHistory{indexI} = agentList(indexI).consideredHistory;
    tempTraining{indexI} = agentList(indexI).training;
    tempExperience{indexI} = agentList(indexI).experience;
    tempWealthHistory{indexI} = agentList(indexI).wealthHistory;
    try
    tempNetwork{indexI} = [agentList(indexI).network(:).id];
    catch
        f=1;
    end
    tempMove{indexI} = [agentList(indexI).moveHistory];
    tempAccess{indexI} = [agentList(indexI).accessCodesPaid];
end
agentSummary.currentPortfolio = tempCurrentPortfolio;
agentSummary.firstPortfolio = tempFirstPortfolio;
agentSummary.portfolioHistory = tempPortfolioHistory;
agentSummary.aspirationHistory = tempAspirationHistory;
agentSummary.consideredHistory = tempConsideredHistory;
agentSummary.network = tempNetwork;
agentSummary.moveHistory = tempMove;
agentSummary.accessCodes = tempAccess;
agentSummary.training = tempTraining;
agentSummary.experience = tempExperience;
agentSummary.wealthHistory = tempWealthHistory;

outputs.agentSummary = agentSummary;

for indexI = length(agentList):-1:1
    delete(agentList(indexI));
end
clear agentList;
clear mapVariables;
clear utilityVariables;
clear *Parameters;
%pack;

fprintf([runName '- completed.\n']);

toc;
end

% =========================================================================
% Local helpers for the livestock/grain buffer (see the buffer block above).
% =========================================================================
function v = getParamOr(s, name, default)
% Return s.(name) if present, else default. Keeps the buffer defaults in
% one place so a run that omits a buffer parameter still behaves sensibly.
    if isfield(s, name)
        v = s.(name);
    else
        v = default;
    end
end

function iy = agYFYearIndex(indexT, modelParameters, nSimYears)
% Map a timestep to its column in agYF (nLoc x nSimYears). agYF is filled
% in createUtilityLayers.m starting at tStart = leadTime + (iCyc-1)*cycleLength+1
% with leadTime = spinupTime, so the inverse for a post-spinup timestep is
% iCyc = floor((indexT - spinupTime - 1)/cycleLength) + 1. During spinup we
% clamp to year 1 (the spinup period repeats the first cycle's yields).
    iy = floor((indexT - modelParameters.spinupTime - 1) / modelParameters.cycleLength) + 1;
    iy = min(max(iy, 1), nSimYears);
end

