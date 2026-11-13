function [agentList, aliveList, modelParameters, agentParameters, mapParameters, utilityVariables, mapVariables, demographicVariables] = buildWorld(modelParameters, mapParameters, agentParameters, networkParameters)

%create a map based on the defined administrative structure in mapParameters
if(isempty(mapParameters.filePath))
    [locations, map, borders] = createMap( modelParameters, mapParameters);
else
    [locations, map, borders, mapParameters] = createMapFromSHP( mapParameters);
end

%define remittance costs based on these locations
[remittanceFee, remittanceRate ] = createRemittanceCosts(locations, modelParameters.remitRate);

%establish population density and likelihood of agent locations
[locationLikelihood, genderLikelihood, ageLikelihood, survivalRate, fertilityRate, ageDiscountRateFactor, agePointsPopulation, agePointsSurvival, agePointsFertility, agePointsPref] = buildDemography(modelParameters, locations);

%survival and fertility rates are generated annually and must be recalibrated for current
%timestep
survivalRate = survivalRate.^(1/modelParameters.cycleLength);
fertilityRate = 1 - ((1-fertilityRate).^(1/modelParameters.cycleLength));

demographicVariables.locationLikelihood = locationLikelihood;
demographicVariables.genderLikelihood = genderLikelihood;
demographicVariables.ageLikelihood = ageLikelihood;
demographicVariables.survivalRate = survivalRate;
demographicVariables.fertilityRate = fertilityRate;
demographicVariables.agePointsPopulation = agePointsPopulation;
demographicVariables.agePointsSurvival = agePointsSurvival;
demographicVariables.agePointsFertility = agePointsFertility;
demographicVariables.agePointsPref = agePointsPref;
demographicVariables.ageDiscountRateFactor = ageDiscountRateFactor;


%create utility layers from the set of layers and functions defined in
%createUtilityLayers.m.  Utility is city-specific, not agent-specific, and
%history is stored in one place only, utilityHistory.  Individual agents
%have a sparse matrix of memory with 1s corresponding to utility values
%they experienced or learned.  This structure allows an arbitrarily large
%landscape with an arbitrarily large number of agents, without wasting
%memory
% droughtStates is the 17th output, requested so it can be exported with the
% run rather than regenerated: from 2023 it is a per-run Markov draw, and
% without it no projection-period analysis can distinguish a drought year
% from a normal one.
[utilityLayerFunctions, utilityHistory, utilityAccessCosts, utilityTimeConstraints, utilityDuration, utilityAccessCodesMat, utilityPrereqs, utilityBaseLayers, utilityForms, incomeForms, nExpected, hardSlotCountYN, localOnly, nExpectedFrac, spatiallyRestricted, agYF, droughtStates] = createUtilityLayers(locations, modelParameters, demographicVariables);
utilityVariables.numForms = max(utilityForms);
utilityVariables.utilityLayerFunctions = utilityLayerFunctions;
utilityVariables.utilityHistory = utilityHistory;
utilityVariables.utilityAccessCosts = utilityAccessCosts;
utilityVariables.utilityDuration = utilityDuration;
utilityVariables.utilityTimeConstraints = utilityTimeConstraints;
utilityVariables.utilityAccessCodesMat = utilityAccessCodesMat;
utilityVariables.utilityBaseLayers = utilityBaseLayers;
utilityVariables.utilityForms = utilityForms;
utilityVariables.incomeForms = incomeForms;
utilityVariables.utilityPrereqs = utilityPrereqs;
utilityVariables.nExpected = nExpected;
utilityVariables.nExpectedFrac = nExpectedFrac;               % (nLayers x 1) capacity fraction of local population
utilityVariables.spatiallyRestricted = spatiallyRestricted;   % (nLoc x nLayers) true = layer unavailable here
utilityVariables.agYF = agYF;                                 % (nLoc x nSimYears) mean available-ag drought yield factor; drives buffer mortality, food-price spike, livestock conversion
utilityVariables.droughtStates = droughtStates;               % (nLoc x nSimYears) 1 = drought year; exported with the run by midasMainLoop
utilityVariables.hardSlotCountYN = hardSlotCountYN;
utilityVariables.hasOpenSlots = false(size(hardSlotCountYN));
utilityVariables.localOnly = logical(localOnly);  % flags agricultural (location-tied) layers


%create agents and randomly allocate them to 'cities' - the term we use
%here for the lowest administrative level
accessCodesPaid = false(size(utilityAccessCosts,1),1);
knowsIncomeLocation = sparse(size(locations,1),size(utilityBaseLayers,2));
incomeLayersHistory = (false(size(utilityBaseLayers)));
expectedProbOpening = zeros(size(knowsIncomeLocation));

agentParameters.init_accessCodesPaid = accessCodesPaid;
agentParameters.init_knowsIncomeLocation = knowsIncomeLocation;
agentParameters.init_incomeLayersHistory = incomeLayersHistory;
agentParameters.init_expectedProbOpening = expectedProbOpening;

%make the list all at once
agentList = repmat(initializeAgent(agentParameters, utilityVariables, modelParameters, 1, 1, 1),1, networkParameters.agentPreAllocation);

%make each element a pointer to a different placeholder object
for indexI = 1:networkParameters.agentPreAllocation
   agentList(indexI) =  initializeAgent(agentParameters, utilityVariables, modelParameters, 1, 1, 1);
end
%create agents, assigning agent-specific properties as appropriate from
%input data
for indexI = 1:modelParameters.numAgents
    %likelihood variables are ordered by matrixID, lowest to highest
    temp = find(locationLikelihood > rand()); %note the 'greater than' test
    locationID = temp(1);
    
    %generate gender, based on location
    gender = 2 - (genderLikelihood(locationID) < rand());  %note the 'less than' test; codes 1 for male, 2 for female
    
    %generate age, based on location and gender.  Extra 0 ensures bounding
    %below
    if(agePointsPopulation(1) == 0) 
        age = interp1([ageLikelihood(locationID,:,gender)],[agePointsPopulation],rand());
    else
        age = interp1([0 ageLikelihood(locationID,:,gender)],[0 agePointsPopulation],rand());
    end
    
    %currentAgent = initializeAgent(agentParameters, utilityVariables, modelParameters, age, gender, locations(locationID,1).cityID, agentList(indexI));
    currentAgent = initializeAgent(agentParameters, utilityVariables, modelParameters, age, gender, locations(locationID,1).cityID);

    % FOUNDING-POPULATION WEALTH (2026-08-27). initializeAgent draws wealth
    % from agentParameters.wealthMean/SD, which are zero, so every agent used
    % to begin with nothing and immediately went 10-20 into debt paying layer
    % access costs (smallFarmCost 10, educationCost 5). Traced agents were
    % 100% in deficit in year one with a median of -17.
    %
    % The founding cohort is now endowed from N(initialWealthMean,
    % initialWealthSD), representing households that already hold assets in
    % 1985 rather than arriving with none. Applied HERE and not in
    % initializeAgent because that function also creates newborns, and
    % endowing every birth would inject wealth into the economy continuously
    % for a century.
    %
    % NOTE: this therefore addresses the INITIALISATION artefact only. Agents
    % born during the run still start at zero, so as the founding cohort dies
    % out the zero-start behaviour returns -- by the 2085 horizon essentially
    % the whole population is born in-model. See the note in readParameters.m.
    if isfield(agentParameters, 'initialWealthMean')
        currentAgent.wealth = max(0, agentParameters.initialWealthMean + ...
                                     randn() * agentParameters.initialWealthSD);
    end

    currentAgent.matrixLocation = locations(locationID,:).matrixID;
    currentAgent.moveHistory = [0 currentAgent.matrixLocation];
    % Allocated only when tracing: cell(timeSteps,1) per agent is 410 cells x
    % ~19,000 agents even before anything is written into them.
    if isfield(modelParameters, 'agentTraceOn') && modelParameters.agentTraceOn
        currentAgent.consideredHistory = cell(modelParameters.timeSteps, 1);
    end
    currentAgent.DOB = 0;
    currentAgent.id = agentParameters.currentID;
    agentParameters.currentID = indexI + 1;    
    agentList(indexI) = currentAgent;
end

aliveList = sparse([agentList.TOD] < 0 & [agentList.DOB] >= 0);

%Agents' 'location' is simply the city they are in, for all computational purposes,
%but for the purposes of visualization, we spread them around.  
cityMap = map(:,:,end);
for indexI = 1:size(locations,1)
   locationMapIndex = find(cityMap == locations(indexI,1).cityID); 
   locationAgents = agentList([agentList(:).location] == locations(indexI,1).cityID);
   if(isempty(locationMapIndex))
       %this particular city is either sub-pixel size or shares all pixels with other cities and lost each one
       %SO, just set visLocation to the established location of the city
       %centroid
       visLocation = locations.LocationIndex(indexI);
       [locationX, locationY] = ind2sub([mapParameters.sizeX mapParameters.sizeY],visLocation);
       for indexJ = 1:length(locationAgents)
           locationAgents(indexJ).visX = locationX + rand() - 0.5;
           locationAgents(indexJ).visY = locationY + rand() - 0.5;
           
           locationAgents(indexJ).moveHistory = [locationAgents(indexJ).moveHistory locationAgents(indexJ).visX locationAgents(indexJ).visY]; 
       end
   else
       [locationX, locationY] = ind2sub([mapParameters.sizeX mapParameters.sizeY],locationMapIndex);
       for indexJ = 1:length(locationAgents)
           visLocation = randperm(length(locationMapIndex),1);
           locationAgents(indexJ).visX = locationX(visLocation) + rand() - 0.5;
           locationAgents(indexJ).visY = locationY(visLocation) + rand() - 0.5;
           
           locationAgents(indexJ).moveHistory = [locationAgents(indexJ).moveHistory locationAgents(indexJ).visX locationAgents(indexJ).visY];
       end
   end
end

%Assign initial income portfolios to agents
[ agentList ] = assignInitialLayers( agentList, utilityVariables,modelParameters.spinupTime, modelParameters );

for indexA = 1:height(agentList)
    currentAgent = agentList(indexA);
    if isfield(modelParameters, 'agentTraceOn') && modelParameters.agentTraceOn
        for indexT = 1:modelParameters.spinupTime
            currentAgent.consideredHistory{indexT} = currentAgent.currentPortfolio;
            currentAgent.agentPortfolioHistory{indexT} = currentAgent.currentPortfolio;
        end
    end
end


%construct a network among agents according to parameters specified in
%networkParameters.  Any change in network structure should modify/replace
%the createNetwork function
[network, distanceMatrix ] = createNetwork(locations, mapParameters, agentList, networkParameters, aliveList);


%create the set of moving costs, now that we have a distance matrix made
[movingCosts ] = createMovingCosts(locations, distanceMatrix, mapParameters);


%package everything up

mapVariables.map = map;
mapVariables.locations = locations;
mapVariables.borders = borders;
mapVariables.network = network;
mapVariables.distanceMatrix = distanceMatrix;
mapVariables.remittanceFee = remittanceFee;
mapVariables.remittanceRate = remittanceRate;
mapVariables.movingCosts = movingCosts;


%visualize the map
if(modelParameters.visualizeYN)
    mapVariables.indexT = 0;
    mapVariables.cycleLength = modelParameters.cycleLength;
    [mapHandle] = visualizeMap(agentList, mapVariables, mapParameters, modelParameters);
            set(gcf,'Position',mapParameters.position)
        drawnow();
    mapVariables.mapHandle = mapHandle;
end

%Any other miscellaneous world-building operations

modelParameters.cyclesPerTimeStep = 1 / modelParameters.cycleLength;