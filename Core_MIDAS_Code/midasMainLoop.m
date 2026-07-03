function [outputs] = midasMainLoop(inputs, runName)
%runMigrationModel.m main time loop of migration model

% FIX agent WEALTH HISTORY TO 1-DIMENSIONAL ARRAY


close all;

tic;

outputs = [];
[agentParameters, modelParameters, networkParameters, mapParameters] = readParameters(inputs);
[agentList, aliveList, modelParameters, agentParameters, mapParameters, utilityVariables, mapVariables, demographicVariables] = buildWorld(modelParameters, mapParameters, agentParameters, networkParameters);
    
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
    bfFloor       = getParamOr(modelParameters, 'bufferFloor',       1.0);
    bfCap         = getParamOr(modelParameters, 'bufferCap',         50);
    bfRef         = getParamOr(modelParameters, 'bufferRef',         10);
    bfLambdaProd  = getParamOr(modelParameters, 'lambdaProd',        0.2);
    bfPhiFood     = getParamOr(modelParameters, 'phiFood',           1.0);
    bfPhiLv       = getParamOr(modelParameters, 'phiLv',             0.75);
    % Per-agent mask of agricultural income layers (income-form AND local-only)
    agIncomeMask  = (utilityVariables.incomeForms(:)' & utilityVariables.localOnly(:)');
    nSimYearsBuf  = size(utilityVariables.agYF, 2);
end

nYearsTotal = ceil(modelParameters.timeSteps / modelParameters.cycleLength);
foodInsecureCount_ag  = zeros(numLocations, nYearsTotal);
foodInsecureCount_all = zeros(numLocations, nYearsTotal);
agentCount_ag         = zeros(numLocations, nYearsTotal);
agentCount_all        = zeros(numLocations, nYearsTotal);
% Buffer trackers (year-end, per location). Summed then divided by the
% agent count for a mean-buffer output; mortality-driven loss is the
% year-on-year drop. Zero everywhere when bufferEnabled is false.
bufferSum_all         = zeros(numLocations, nYearsTotal);
%wealthHistory = zeros(modelParameters.numAgents,modelParameters.timeSteps);

%create a list of shared layers, for use in choosing new link
agentLayers = zeros(length(agentList),size(utilityVariables.utilityLayerFunctions,1));
agentLayers(:) = vertcat(agentList.currentPortfolio);

agentLocations = ones(1,length(agentList));
agentLocations(aliveList) = [agentList(aliveList).matrixLocation];

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
        locCounts = accumarray(agentLocations(aliveList)', 1, [numLocations 1]);
        newNExpected = floor(locCounts * utilityVariables.nExpectedFrac');   % (nLoc x nLayers)
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
                
                newBaby = assignInitialLayers(newBaby, utilityVariables, indexT, modelParameters);
                
                mapVariables.network(newBaby.id, currentAgent.id) = 1;
                mapVariables.network(currentAgent.id, newBaby.id) = 1;
                aliveList(newBaby.id) = true;
                                
                %update this line in the array used to choose new links
                agentLayers(newBaby.id,:) = newBaby.currentPortfolio;
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

        isDistress = postSpin && ageOK && ...
                     checkDistressTrigger(currentAgent, modelParameters, indexT);

        isStandard = postSpin && ageOK && rand() < currentAgent.pChoose;

        if isDistress || isStandard
            [currentAgent, moved] = choosePortfolio(currentAgent, utilityVariables, indexT, modelParameters, mapParameters, demographicVariables, mapVariables, isDistress);
            currentAgent.agentPortfolioHistory{indexT} = currentAgent.currentPortfolio;
            currentAgent.agentAspirationHistory{indexT} = currentAgent.currentAspiration;
            currentAgent.consideredHistory{indexT} = currentAgent.consideredPortfolios;
            if(~isempty(moved))
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
       
        
    end %for indexA = 1:currentRandOrder
    
    
    if (mod(indexT, modelParameters.incomeInterval) == 0)
        
        %construct the current counts of the number of agents occupying
        %each layer
        agentCityIndex = [livingAgents(:).matrixLocation]';
        for indexA = 1:length(livingAgents)
            currentPortfolio = logical(livingAgents(indexA).currentPortfolio(1,1:size(utilityVariables.utilityHistory,2)));
            countAgentsPerLayer(agentCityIndex(indexA), currentPortfolio, indexT) = countAgentsPerLayer(agentCityIndex(indexA), currentPortfolio, indexT) + 1;
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
            %find out how much the current agent made, from each layer, and
            %update their knowledge
            
            newIncome = sum(utilityVariables.utilityHistory(currentAgent.matrixLocation,currentPortfolio(utilityVariables.incomeForms(currentPortfolio)), indexT));

            % --- Buffer productive-input effect (§2.5b) ---
            % Livestock is a productive input to farming (traction, manure,
            % milk), so the agricultural portion of income scales with the
            % herd. Losing the herd depresses ag income even in a good-rain
            % year (a second ratchet on continuation/post-kere years), and a
            % migrant whose remittance-fed buffer has rebuilt sees home
            % agriculture become attractive again -> return migration.
            if bufferOn && bfLambdaProd > 0
                agIncomeThisT = sum(utilityVariables.utilityHistory( ...
                    currentAgent.matrixLocation, ...
                    agIncomeMask & currentPortfolio, indexT));
                prodMult  = 1 + bfLambdaProd * min(1, currentAgent.buffer / bfRef);
                newIncome = newIncome + (prodMult - 1) * agIncomeThisT;
            end


            %add in any income that has been shared in to the agent, to
            %include in sharing-out decision-making
            newIncome = newIncome + currentAgent.currentSharedIn;
            currentAgent.currentSharedIn = 0;
            currentAgent.personalIncomeHistory(indexT) = newIncome;
            
            currentAgent.incomeLayersHistory(currentAgent.matrixLocation,currentPortfolio,indexT) = true;
            currentAgent.knowsIncomeLocation(currentAgent.matrixLocation, currentPortfolio) = true;
            
            
            %estimate the gross intention of sharing out across network
            amountToShare = newIncome * currentAgent.incomeShareFraction;
            networkStrengths = mapVariables.network(currentAgent.id, [currentAgent.network(:).id]);

            potentialAmounts = (networkStrengths ./ sum(networkStrengths)) * amountToShare;
            
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

            % --- Buffer food-price spike (§3, expenditure side) ---
            % Food gets dearer in drought (entitlement failure): the effective
            % subsistence cost rises with local drought severity. This deepens
            % wealth decline for ALL agents in an affected region (including
            % non-farm households), a direct route to the food-insecurity link.
            subsistNow = agentParameters.subsistence_costs;
            if bufferOn && bfPhiFood > 0
                iyBuf = agYFYearIndex(indexT, modelParameters, nSimYearsBuf);
                agYFnow = utilityVariables.agYF(currentAgent.matrixLocation, iyBuf);
                subsistNow = subsistNow * (1 + bfPhiFood * (1 - agYFnow));
            end
            currentAgent.wealth = currentAgent.wealth + netIncome - subsistNow;
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
                        buf     = currentAgent.buffer;

                        % (i) Drought mortality: herd/store dies in proportion
                        %     to local drought severity (climate -> asset, one link).
                        buf = buf * (1 - bfMortMax * (1 - agYFloc));

                        % (ii) Slow, concave biological growth (capped): a
                        %      near-empty buffer rebuilds slowly -> the fast-
                        %      crash / slow-recovery asymmetry.
                        buf = min(bfCap, buf * (1 + bfGrowthRate));

                        % (iii) Consumption gap this year (wealth decline).
                        %       wealthEndVal already reflects the drought food-
                        %       price spike, so the gap embeds terms-of-trade on
                        %       the expenditure side.
                        gap = max(0, wealthStartVal - wealthEndVal);

                        if gap > 0
                            % Liquidate buffer above the reproductive floor to
                            % cover the gap, at a drought-depressed conversion
                            % rate (terms-of-trade, asset side). Below the floor
                            % the household defends breeding stock (asset
                            % smoothing) and consumption crashes -> FI fires.
                            convFac  = max(0.05, 1 - bfPhiLv * (1 - agYFloc));
                            sellable = max(0, buf - bfFloor);
                            food     = min(gap, sellable * convFac);
                            buf      = buf - food / convFac;
                            currentAgent.wealth = currentAgent.wealth + food;
                            shortfall = gap - food;
                        else
                            % Surplus year: agri-pastoralists divert a share of
                            % the surplus into the buffer (precautionary saving
                            % by default). Non-ag agents keep their cash.
                            shortfall = 0;
                            if isAgAgent
                                store = bfAccrualFrac * (wealthEndVal - wealthStartVal);
                                store = min(store, max(0, bfCap - buf));
                                buf   = buf + store;
                                currentAgent.wealth = currentAgent.wealth - store;
                            end
                        end

                        currentAgent.buffer = buf;
                        wealthEndVal = currentAgent.wealth;           % buffer moved wealth
                        currentAgent.wealthHistory{indexT} = currentAgent.wealth;
                        currentAgent.bufferHistory{indexT} = buf;

                        % FI is now unmet consumption AFTER drawing the buffer.
                        wasInsecure = shortfall > 0;
                    else
                        wasInsecure = (wealthEndVal < wealthStartVal);
                    end

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
% Mean livestock/grain buffer per location-year (post-spinup). Zero
% everywhere when bufferEnabled is false. The year-on-year drop in a
% drought year is the mortality signal; the level is the absorption state.
outputs.bufferMean             = bufferSum_all(:, firstPostSpinupYear:end) ./ ...
                                 max(1, agentCount_all(:, firstPostSpinupYear:end));
outputs.aspirationHistory = aspirationHistory;

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

