function [ agent, moved ] = choosePortfolio( agent, utilityVariables, currentT, modelParameters, mapParameters, demographicVariables, mapVariables, distressMode )
%choosePortfolio.m is the main engine for agents to select an income
%portfolio (and possibly, to move)
%
%distressMode (optional, default false) -- when true, the agent is being
%routed through this function by the distress-migration overlay (see
%midasMainLoop.m). In that case the function:
%   (a) excludes the agent's current location from the candidate set,
%       so the returned best location is guaranteed to be different and
%       the agent will move (provided at least one other candidate
%       exists);
%   (b) skips the affordability check, allowing portfolios whose moving +
%       access costs would push the agent into debt to remain in the
%       candidate set. This represents the empirical reality that distress
%       migration is typically funded by liquidating household assets
%       (livestock, grain stores) rather than from accumulated cash
%       savings, which MIDAS does not model explicitly. Since 2026-09-13
%       this is the ONLY route by which an agent moves into debt.
if nargin < 8
    distressMode = false;
end

%function takes an agent, as well as the current timestep and a number of
%model environment variables.  The only one of these that is written to
%(and thus copied) is the agent itself

%this is a goal-seeking algorithm, but is not an optimization algorithm.
%finding the *best* portfolio of income options in a particular place,
%subject to an overall time constraint and evaluated via a non-linear
%utility function, can be handled by a quadratic knapsack problem in
%polynomial time.  however, this is impractical for an engine that will be
%run millions of times within a single simulation.

%instead of this, the algorithm captures some aspects of goal-seeking
%behavior in a way that is computationally affordable.  

%agents hold on to m 'best portfolios' in each location that they evaluate,
%and use the highest of these as the marker for the potential income
%achievable in that location.  these markers are then used to identify
%which are the 'best locations'

%with these values held in memory, the algorithm is structured as follows:

%1) choose z different locations to compare, where z includes the current
%location, x 'best locations', and y random locations

%2) within each location, choose p different portfolios to compare, where p
%includes m 'best portfolios' and n random portfolios.  if this location is
%the current location, then one of the m best portfolios is the current
%portfolio

%3) for each portfolio, construct an estimated time path of income, based
%on known history for those income layers in that location.  where
%possible, use full cycles of data (i.e., a full year at a time), and when
%filling in gaps, use the same time period for as many layers as possible.
%This is to maximize impacts of patterns over time and correlations across
%layers in the decision (as would matter in seasonal migration, or income
%diversification, respectively).

%4) add in the expected costs to the agent of accessing this layer, as well
%as moving, and build in the expected sharing in of resources from across
%their network (based on most recent intended share in, and expected
%network distances)

%5) compare all portfolios using a net-present value (with discounting) of
%the expected utility (using agent-specific risk coefficient), and choose
%the best one

%6) adopt the best portfolio, moving to new location if appropriate

%algorithm begins below

%as of now, the agent has not decided to move
moved = [];

%choose a set of locations to evaluate - the current location, some other
%good locations from past searches, and a few random new ones.  note that
%matrixLocation is the identifier for the location's index in the location
%vector, so that it can be used directly to index selected locations
currentLocation = agent.matrixLocation;
[sortedLocations,sortedIndex] = sortrows(agent.bestPortfolioValues,-1);
sortedIndex = sortedIndex(sortedLocations > 0);
bestLocations = sortedIndex(1:min(length(sortedIndex),agent.numBestLocation));
otherRandomLocations = find(any(agent.knowsIncomeLocation,2));
randomLocations = otherRandomLocations(randperm(length(otherRandomLocations),min(length(otherRandomLocations),agent.numRandomLocation)));
if distressMode
    % Exclude current location from candidate set so the agent is forced
    % to move (unless there are literally no other candidates, in which
    % case fall back to standard behaviour rather than crash).
    locationList = [bestLocations; randomLocations];
    locationList = locationList(locationList ~= currentLocation);
    if isempty(locationList)
        locationList = [currentLocation; bestLocations; randomLocations];
    end
else
    locationList = [currentLocation; bestLocations; randomLocations];
end

%remove duplicates
[bSort,iSort] = sort(locationList);
locationList = locationList(iSort([true; diff(bSort)>0]),:);

%make note of the total number of portfolios we expect to evaluate in each
%location
totalNumPortfolios = agent.numBestPortfolio + agent.numRandomPortfolio;

%since we will try to match historical data to the appropriate season,
%create labels for what part of the cycle our historical data and our
%evaluation period are
periodInCycleData = mod(1:currentT,modelParameters.cycleLength);

% SEASONAL ALIGNMENT OF THE FORECAST (fixed 2026-09-11).
%
% These labels are matched against each other at the history-sampling step
% below, so that a blank slot in the forecast is filled from a historical
% period in the SAME season. periodInCycleData is right: historical timestep t
% carries season mod(t, cycleLength).
%
% This line previously read mod(1:numPeriodsEvaluate, cycleLength), which
% labels evaluation period 1 as season 1 ALWAYS, whatever quarter the agent is
% actually in. Evaluation period 1 is the CURRENT quarter, whose season is
% mod(currentT, cycleLength), so the forecast was filled from history that was
% phase-shifted by mod(currentT, cycleLength) -- correct in one quarter of
% four, and up to two quarters out of phase in the others.
%
% Layer income is deliberately lumpy (maize Q1, rice Q2, sisal Q3, cassava and
% vanilla Q4), so a two-quarter shift inverts the forecast: agents expected
% the harvest when there was none and none when there was. The decision then
% depended on WHICH QUARTER the agent happened to evaluate in rather than on
% conditions, which is what produced migration counts alternating by a factor
% of ~6 between adjacent quarters, and Q1/Q3 patterning together (even shifts
% preserve the semi-annual phase of the income profile, odd shifts break it).
%
% Evaluation period 1 is taken as the current quarter, not the next one:
% choosePortfolio runs before the income loop in the same timestep, and the
% access and moving costs are charged to period 1, so the portfolio chosen
% here earns in this quarter.
periodInCycleEvaluation = mod(currentT + (0:agent.numPeriodsEvaluate-1), ...
                              modelParameters.cycleLength);

%set up the discount and risk factors

%this next line builds in a scaling (in practice) of the discount rate
%based on age.  note that this doesn't modify the underlying discount rate,
%but instead scales it based on any input data.  possibly change
discountAgeScaling = interp1(demographicVariables.agePointsPref, demographicVariables.ageDiscountRateFactor, agent.age);

discountFactor = 1./((1+agent.discountRate * discountAgeScaling).^(0:agent.numPeriodsEvaluate-1)');
riskCoeff = 1 - agent.rValue;

% One-shot flag for the non-finite portfolio-value diagnostic below. Declared
% here rather than at the point of use: MATLAB wants persistent declarations
% at function scope, not nested inside a conditional in a loop.
persistent warnedNonFinite

%initialize vectors to hold the best-case portfolios and values for each
%location
locationValue = NaN*ones(length(locationList),1);
locationPortfolio = cell(length(locationList),1);
locationAspiration = cell(length(locationList),1);
locationFidelity = cell(length(locationList),1);
locationAccessCodes = cell(length(locationList),1);
locationMovingCosts = zeros(length(locationList),1);

% ------------------------------------------------------------------------
% ASPIRATION vs ABILITY (2026-09-11)
%
% locationValue holds the best AFFORDABLE option at each location; the new
% array below holds the best option regardless of affordability. Separating
% them is what lets an agent be classified as wanting to move but unable to,
% rather than being silently converted into something else.
%
% THE BEHAVIOUR THIS REPLACES. Previously a location with no affordable option
% was given -Inf, and every location could end up at -Inf for an indebted
% agent. sort() then returned them in natural order, the tie-break at the
% selection step tested locationValue(1) == locationValue(2) -- true, because
% -Inf == -Inf -- and the agent was sent to a UNIFORMLY RANDOM location, paying
% a moving cost the credit test had just ruled unaffordable. Insolvency
% produced random walking rather than immobility, which inflated churn,
% deepened the debt that caused it, and diluted any drought signal in the
% migration series with uniform noise.
locationValueAll  = NaN*ones(length(locationList),1);  % best option, ignoring cost
% RETIRED 2026-09-13 along with the credit test (see the affordability block
% below). Asked whether a blocked location would have been reachable under a
% borrowing allowance rather than a positive-reserve test. With the threshold
% now zero the two are the same test, so this stays false for every agent and
% trappedBySignHistory is emitted as all-zeros -- kept as an output only so
% run_buffer_trace.m and any saved analysis do not fail on a missing field.
signFreeableAnywhere = false;

% Value of doing exactly what the agent already does: stay put, keep the
% current portfolio, pay nothing. The mobility classification is defined
% relative to this. Guaranteed to be populated in non-distress mode because
% the home location is always in locationList (see above) and the current
% portfolio is always injected as a candidate there.
statusQuoValue = -Inf;
consideredPortfolioSet = []; %List of portfolios considered by agent across all locations in this time step

%Update agent pre-requisites, with special function for education (to
%account for minimum number of years needed)
agent = trainingTracker(agent, utilityVariables, modelParameters);

% --- Livelihood attachment (gated; off = legacy) ---------------------
% Agents have a heterogeneous tendency to stay in their current field of
% work (agent.livelihoodAttachment ~ U(0,1), set at creation). When
% enabled, each candidate portfolio's NPV is penalised in proportion to
% how UNFAMILIAR its layers are -- the fraction of active layers in
% which the agent has no prior experience (and which are not in its
% current portfolio). A fully familiar portfolio (the current one, or a
% relocation continuing the same livelihood) carries no penalty, so
% attachment does not block "move but keep farming" -- the empirically
% dominant Grand-Sud pathway. The penalty scales with |NPV| so it is
% sign-safe for negative utility values.
%
% Attachment stays ACTIVE in distressMode: the current location is
% excluded from the candidate set there, so the penalty cannot veto the
% forced move itself -- it only steers WHERE the agent goes and WHAT it
% does, biasing displaced agents toward destinations where they can
% continue their livelihood (the observed kere pattern: displaced
% southern farmers keep farming at the destination).
nUL = size(utilityVariables.utilityHistory, 2);
attachOn = isfield(modelParameters, 'livelihoodAttachmentEnabled') && ...
           modelParameters.livelihoodAttachmentEnabled;
if attachOn
    attachPenalty = modelParameters.livelihoodAttachmentScale * agent.livelihoodAttachment;
    % RECENCY-WEIGHTED familiarity (2026-07-14; replaces the lifetime
    % "ever worked" binary). agent.recentExperience is an exponential
    % moving average maintained every quarter in midasMainLoop: decayed
    % by attachmentRecencyDecay, replenished by currently-practiced
    % layers. Normalising by the EMA's steady state (1/(1-decay)) maps
    % continuous practice to familiarity 1; a layer abandoned ~3 years
    % ago has faded to ~0.5; never-worked layers are 0. This penalises
    % switching AWAY from the current field of work even between layers
    % the agent once knew -- the alternation-among-known-layers churn
    % that the lifetime definition left unpenalised (seen in traces).
    dec = 0.94;
    if isfield(modelParameters, 'attachmentRecencyDecay')
        dec = modelParameters.attachmentRecencyDecay;
    end
    if isempty(agent.recentExperience)
        attachOn = false;
    else
        layerFamil = min(1, agent.recentExperience(:)' * (1 - dec));
        % Fresh entrants with no practice anywhere have nothing to be
        % attached to -- skip the penalty entirely.
        if ~any(layerFamil > 0)
            attachOn = false;
        end
    end
end

%Check which layers are "selectable" based on agent prereqs
selectable = selectableFlag(utilityVariables.utilityPrereqs, utilityVariables.utilityAccessCodesMat, utilityVariables.utilityAccessCosts, agent.training, agent.experience, agent.currentPortfolio, agent.wealth, utilityVariables.utilityDuration(:,2));

%for each location, find a good income portfolio - the current portfolio
%(if this is home city), some other good portfolios from past searches, and
%a few random new ones
for indexL = 1:length(locationList)
    
    %initialize a few things - a blank logical matrix to hold the layers
    %active in each portfolio, and the moving cost that will apply to every
    %portfolio in this location
    portfolioSet = cell(totalNumPortfolios,1);
    currentPortfolio = 1;
    currentMovingCost = mapVariables.movingCosts(currentLocation, locationList(indexL));
    locationMovingCosts(indexL) = currentMovingCost;

    % BUGFIX 2026-07-28 (spatial leak). `selectable` above comes from
    % selectableFlag, which checks prerequisites, duration and cost but is
    % location-blind. createPortfolio's top-up loop (createPortfolio.m:154)
    % draws from it with no location filter, so candidate portfolios for
    % THIS location could include layers that do not exist here. Mask per
    % candidate location -- note this must be inside the loop, since the
    % available set differs between the locations being compared.
    selectableHere = selectable & ...
        ~utilityVariables.spatiallyRestricted(locationList(indexL),:)';
    
    %first portfolio is the current portfolio if this is the home city
    if(locationList(indexL) == agent.matrixLocation) %currentLocation
        firstPortfoliotest = agent.currentPortfolio;
        %Adjust for the fact that initial portfolios may not have a
        %duration or flag specified
        if size(agent.currentPortfolio(1,:),2) == size(utilityVariables.utilityHistory,2)
            agent.currentPortfolio = [(agent.currentPortfolio .* selectableHere') agent.numPeriodsEvaluate 1];
        end
        
        portfolioSet{currentPortfolio} = agent.currentPortfolio;
        currentPortfolio = currentPortfolio + 1;
    end
    
    
    %next add any previous 'best' portfolios
    for indexP = 1:agent.numBestPortfolio %other best portfolios in this location  
        nextBest = agent.bestPortfolios{locationList(indexL), indexP};
        
        if(~isempty(nextBest))
            if size(nextBest(1,:),2) == size(utilityVariables.utilityHistory,2)
                nextBest = [nextBest agent.numPeriodsEvaluate 1];
            else
                nextBest(1,1:size(utilityVariables.utilityHistory,2)) = nextBest(1,1:size(utilityVariables.utilityHistory,2));
            end

            portfolioSet{currentPortfolio} = nextBest;
            currentPortfolio = currentPortfolio + 1;
        end
        
    end
    

    %last, come up with a few random portfolios to finish
    for indexP = (currentPortfolio):totalNumPortfolios

        % BUGFIX 2026-07-28 (part 2). The `layers` argument must be spatially
        % filtered as well as `selectable`. createPortfolio derives its
        % aspirations as (samplePortfolio & ~selectable) at line 113, and
        % samplePortfolio is drawn from `layers`. With `selectable` now
        % location-masked but `layers` still unfiltered, every restricted
        % layer the agent had merely HEARD of became an "aspiration" -- which
        % then indexed utilityAccessCosts out of bounds (see note below).
        % An agent should not aspire to a livelihood that does not exist at
        % the location being evaluated.
        [nextRandom] = createPortfolio([], find(any(agent.knowsIncomeLocation(locationList(indexL),:),1) & ~utilityVariables.spatiallyRestricted(locationList(indexL),:)),utilityVariables.utilityTimeConstraints, utilityVariables.utilityPrereqs, agent.pAddFitElement, agent.training, agent.experience, utilityVariables.utilityAccessCosts, utilityVariables.utilityDuration, agent.numPeriodsEvaluate, selectableHere, utilityVariables.utilityHistory(indexL,:,currentT-4:currentT-1), agent.wealth, agent.pBackCast, utilityVariables.utilityAccessCodesMat, modelParameters);
        if(~isempty(nextRandom))
            portfolioSet{indexP} = nextRandom;   
        end
    end

    %Identify near-term portfolios in each set and weed out those that are
    %non-selectable. 
    
    nearTermPortfolios = false(totalNumPortfolios,size(utilityVariables.utilityHistory,2));
    for indexP = 1:totalNumPortfolios
        nearTermPortfolios(indexP,:) = portfolioSet{indexP}(1,1:size(utilityVariables.utilityHistory,2)) .* selectable';
        portfolioSet{indexP}(1,1:size(utilityVariables.utilityHistory,2)) = nearTermPortfolios(indexP,:);  
    end


    %find the unique portfolios described in the set.  one could just use
    %           portfolioSet = unique(portfolioSet,'rows');
    %but this is inefficient, and this particular operation is the
    %most expensive in the routine.  instead, take advantage of the fact
    %that a logical vector describes a unique binary number, sort the
    %vector of binary numbers and remove duplicates.  way faster.
    %
    %Original used bi2de (Communications Toolbox); replaced with a base-
    %MATLAB equivalent so this works on cluster MATLAB installs without
    %the toolbox. bi2de's default is right-msb (left-most bit is LSB),
    %so the equivalent is row * 2.^(0:N-1)'. For wide portfolios where
    %2^N would overflow double precision, fall back to unique(...,'rows').
    nLayerCols = size(nearTermPortfolios,2);
    if nLayerCols <= 52
        binaryPortfolio = double(nearTermPortfolios) * (2.^(0:nLayerCols-1))';
        [bSort,iSort] = sort(binaryPortfolio);
        iKeptPortfolios = iSort([true; diff(bSort)>0]);
        nearTermPortfolioSet = nearTermPortfolios(iKeptPortfolios,:);
    else
        [nearTermPortfolioSet, iKeptPortfolios] = unique(nearTermPortfolios,'rows','stable');
    end

    %identify which layers are used across any of the portfolios being
    %evaluated (so we can ignore the rest)
    usedIncomeLayers = any(nearTermPortfolioSet,1);
    
    %also identify how many complete cycles and partial cycles we are
    %needing to fill
    completeCycles = floor(agent.numPeriodsEvaluate / modelParameters.cycleLength);
    extraPeriods = mod(agent.numPeriodsEvaluate, modelParameters.cycleLength);
    
    %mark out what information our agent has - use the global stored array
    %of income  history to access all data for the layers in use, and blank out elements not known to our agent as
    %NaN
    fullHistory = utilityVariables.utilityHistory(locationList(indexL),:,1:currentT);
    availableHistory = agent.incomeLayersHistory(locationList(indexL),:,1:currentT);
    fullHistory(~availableHistory) = NaN;

    %make a blank array to hold the estimated time paths for each layer,
    %and reshape our fullHistory array to be the same 2D shape
    numUniqueLayers = size(utilityVariables.utilityHistory,2);
    fullHistory = reshape(fullHistory,numUniqueLayers,currentT);

    % --- Expectation formation (dispatched by modelParameters.expectationArm)
    % The original MIDAS behaviour (random stitching of complete past
    % cycles, uniformly sampled across the full agent history) is
    % preserved as arm 0 inside formExpectation.m. Arms 1-4 implement
    % behaviourally-grounded alternatives that weight recent history
    % more heavily and/or anchor the expectation to current conditions
    % rather than randomly-sampled past years. See formExpectation.m
    % for the per-arm logic.
    portfolioData = formExpectation(fullHistory, currentT, agent, modelParameters);
    if isempty(portfolioData) || all(isnan(portfolioData(:)))
        % Belt-and-braces: if formExpectation returned no usable
        % expectations, fall back to an all-NaN array for the
        % blank-fill logic below to populate.
        portfolioData = NaN * ones(numUniqueLayers, agent.numPeriodsEvaluate);
    end
    %now go through and fill in the blanks, trying to preserve sequence if
    %possible; and capturing as many layers per sample as possible.  we do
    %this by choosing a layer at random to look for blanks, filling in as
    %much in other layers as possible as we move through this layer, and
    %then continuing on to the next layer
    priorityList = randperm(numUniqueLayers);
    for indexB = 1:length(priorityList)
        
        %pick the layer randomly and identify blank spots
        currentLayer = priorityList(indexB);
        blankElements = find(isnan(portfolioData(currentLayer,:)));
        %while that layer isn't completely filled in, walk through the
        %blank spots and fill in
        while(~isempty(blankElements))
            
            %if the current spot is still blank (might have been filled by
            %a previous action
            if(isnan(portfolioData(currentLayer,blankElements(1))))
                
                %see if there are complete cycles that can be accessed to
                %fill this spot (and others in sequence after, as well as
                %for other layers)
                availableSamples = find(periodInCycleData == periodInCycleEvaluation(blankElements(1)));
                availableSamples(isnan(fullHistory(currentLayer,availableSamples))) = [];
                if(~isempty(availableSamples))
                    %pick one of the full cycles randomly, and use only the
                    %necessary/available amount of it
                    sampleIndex = availableSamples(randperm(length(availableSamples),1));
                    sampleSize = min([modelParameters.cycleLength, currentT - sampleIndex, agent.numPeriodsEvaluate - blankElements(1)]);
                    
                    %identify the overlap of i) available data in sample
                    %and ii) missing data in the evaluation period
                    currentSample = fullHistory(priorityList(indexB:end),sampleIndex:sampleIndex+sampleSize);
                    currentPeriod = portfolioData(priorityList(indexB:end),blankElements(1):blankElements(1)+sampleSize);
                    filledHoles = logical(isnan(currentPeriod) .* ~isnan(currentSample));
                    
                    %fill the holes and then replace the current block in
                    %the evaluation period with this more complete set
                    currentPeriod(filledHoles) = currentSample(filledHoles);
                    portfolioData(priorityList(indexB:end),blankElements(1):blankElements(1)+sampleSize) = currentPeriod;
                else
                    %we don't have full cycles so just work with individual
                    %periods.  pick from available data at random
                    sampleIndex = find(~isnan(fullHistory(currentLayer,:)));
                    
                    sampleIndex = sampleIndex(randperm(length(sampleIndex)));
                    currentNumPeriods = min(length(blankElements),length(sampleIndex));
                    
                    if(~isempty(sampleIndex))
                        %identify any additional layers that can be filled in
                        %with this sample
                        currentSample = fullHistory(priorityList(indexB:end),sampleIndex(1:currentNumPeriods));
                        %currentBlanks = blankElements(1:length(sampleIndex));
                        %currentPeriod = portfolioData(priorityList(indexB:end),blankElements(1:currentNumPeriods));
                        %filledHoles = logical(isnan(currentPeriod) .* ~isnan(currentSample));
                        
                        %fill the holes and then replace the current sample in
                        %the evaluation period with this more complete set

                        %currentPeriod(filledHoles) = currentSample(filledHoles);
                        
                        portfolioData(priorityList(indexB:end),blankElements(1:currentNumPeriods)) = currentSample;

                    else
                        %we don't know ANYTHING about this layer.  it's only here because it's a prerequisite to a layer we knew something about.
                        %in the absence of any better information, set
                        %values to 0 and move on
                        portfolioData(currentLayer, blankElements) = 0;
                        blankElements = [];
                        continue;
                    end
                end
            end
            %remove the element we just addressed from the list
            blankElements(1) = [];
        end
    end
    
    %now evaluate the different portfolios.  first initialize a few arrays
    %to store important things - the portfolio values as well as the lists
    %of access codes that would need to be paid (so we don't have to look
    %them up again)
    numPortfolios = size(nearTermPortfolioSet,1);
    portfolioValues = zeros(numPortfolios,1);
    portfolioAccessCodes = cell(numPortfolios,1);
    
    %for efficient matrix calculation of npv we need an array that includes
    %only layers in use; portfolioSet is sized to include ALL layers, so we
    %make a subset, and then apply any weightings, including UTILITY
    %WEIGHTS and EXPECTATIONS OF GETTING ACCESS
    portfolioSubSet = portfolioSet(iKeptPortfolios);
  
    
    exceedsCreditLimit = false(size(portfolioSubSet,1),1);

    % RETIRED 2026-09-13 -- kept allocated, never written.
    %
    % Added 2026-08-27 to measure a real ambiguity: the credit test of the time
    % demanded a positive cash RESERVE (+creditMultiplier * collateral) while
    % its own comment described a borrowing ALLOWANCE (-creditMultiplier *
    % collateral). Which was intended mattered, because it set how much
    % migration ran through the voluntary channel versus the distress overlay,
    % so the counterfactual was recorded rather than the code silently patched.
    %
    % The question is now moot. Both readings were replaced by a plain
    % liquidity constraint (threshold zero), under which they are the same
    % test. This stays all-false so the crows(iC).creditBlockedAllow trace
    % column keeps its shape; it will read 0 for every row.
    exceedsCreditAllowance = false(size(portfolioSubSet,1),1);

    % Is this candidate location the agent's current one, and which candidate
    % (if any) is the status quo? Set per location, before the portfolio loop.
    isHomeHere   = (locationList(indexL) == agent.matrixLocation);
    statusQuoIdx = [];

    for indexP = 1:size(portfolioSubSet,1)

        %dump all layers into a single time series with each element being
        %the sum of expected layer income in each period. 
        
        %Cycle through near-term, mid-term, and aspirational "chunks" in portfolio
        currentPortfolioValue = zeros(agent.numPeriodsEvaluate,1);%Get full portfolio set based on sorted portfolioSubSets that are retained
        focalPortfolio = portfolioSubSet{indexP};
        startDuration = 1;
        for indexK = 1:size(focalPortfolio,1)

            %Distinguish between high-fidelity and low-fidelity "chunks"

                %If some initially generated portfolios, then add time
            %dimension and high-dimensionality flag
            if length(focalPortfolio) == size(utilityVariables.utilityHistory,2) 
                focalPortfolio = [focalPortfolio agent.numPeriodsEvaluate 1];
            end
            
            if focalPortfolio(indexK,end) == 1
                endDuration = startDuration + focalPortfolio(indexK, end-1) - 1;
                currentPortfolioValue(startDuration:endDuration) = focalPortfolio(indexK,1:end-2) * portfolioData(:,startDuration:endDuration);
                startDuration = endDuration + 1;
               
            elseif startDuration < agent.numPeriodsEvaluate
                currentPortfolioValue(startDuration:end) = focalPortfolio(indexK,1:end-2) * utilityVariables.aspirations .* ones(1,agent.numPeriodsEvaluate - startDuration + 1);
            end
        end

        %add sharing in from the network
        if(~isempty(agent.network))
            %estimate the gross intention of sharing in from network
            potentialAmounts = agent.lastIntendedShareIn;
            potentialAmounts(isnan(potentialAmounts)) = 0;
            
            %calculate costs associated with those shares
            remittanceFee = mapVariables.remittanceFee(agent.matrixLocation, [agent.network(:).matrixLocation]);
            remittanceRate = mapVariables.remittanceRate(agent.matrixLocation, [agent.network(:).matrixLocation]);

            try
            remittanceCost = remittanceFee + remittanceRate / 100 .* potentialAmounts;
            catch
                f=1;
            end
            
            %discard any potential transfers that exceed agent's threshold
            %for costs (i.e., agent stops making transfers if the
            %transaction costs are too much of the overall cost)
            feasibleTransfers = remittanceCost ./ potentialAmounts < [agent.network(:).shareCostThreshold];
            actualAmounts = sum((potentialAmounts - remittanceCost) .* feasibleTransfers);
            
            %add the actual expected sharing in to each element in the time
            %series
            currentPortfolioValue = currentPortfolioValue + actualAmounts;
        end
        
        %add access costs that would need to be paid in order to access the
        %layers in this portfolio.  first identify those necessary and then
        %cancel out those that are already paid. NOTE - Only focus on costs
        %for first near-term "chunk" of portfolio

        accessCostCodes = reshape(any(utilityVariables.utilityAccessCodesMat(:,logical(portfolioSet{indexP}(1,1:end-2)),locationList(indexL)),2), size(utilityVariables.utilityAccessCodesMat, 1),1);
        accessCostCodes(agent.accessCodesPaid) = false;
        newCosts = sum(utilityVariables.utilityAccessCosts(accessCostCodes,2));
        
        %add these costs to the first element in the time series, and store
        %the list for later (in case we choose this portfolio and need to
        %actually pay them)
        currentPortfolioValue(1) = currentPortfolioValue(1) - newCosts;
        portfolioAccessCodes{indexP} = accessCostCodes;
        
        %add moving costs appropriate to this location
        currentPortfolioValue(1) = currentPortfolioValue(1) - currentMovingCost;
        
        % AFFORDABILITY: LIQUIDITY, NOT CREDITWORTHINESS (2026-09-13)
        %
        % A portfolio is out of reach if paying for it would leave the agent in
        % debt. The household funds a move and any new layer access from the
        % liquid wealth it holds; it cannot borrow against future income to do
        % so. That is the whole test.
        %
        % WHAT THIS REPLACED, AND WHY.
        % The previous test was
        %     postMoveWealth < creditMultiplier * creditCollateral
        % with creditCollateral = the sum of access costs the agent had ever
        % paid, described in its own comment as "access to credit proportional
        % to its human capital ... a proxy for self-investment".
        %
        % Two problems.
        %
        % (1) CONCEPTUAL. That is a credit-scoring construct -- a household's
        % borrowing capacity read off its history of formal-sector investment.
        % Madagascar has no meaningful formal rural consumer credit against
        % which such a score could be assessed; rural households finance
        % lumpy expenditure from their own liquid assets, from kin, or from
        % informal lenders, none of which is what creditCollateral measured.
        %
        % (2) MECHANICAL. creditCollateral >= 0, so the test as written blocked
        % a move unless the agent RETAINED a positive cash reserve afterwards.
        % It was a reserve requirement, not a borrowing allowance, and it
        % scaled the wrong way: an agent that had invested MORE in the past had
        % to hold MORE cash back in order to move. The borrowing-allowance form
        % the comment actually described was the sign-flipped version sitting
        % directly below it, which was never used to filter anything.
        %
        % Both are gone. creditMultiplier and creditCollateral no longer enter
        % the migration decision at all. The threshold is zero.
        %
        % KEEPING THE CURRENT PORTFOLIO IS UNAFFECTED -- staying put has no
        % cost, so hasCost is false and an agent already deep in debt is never
        % forced out of what it already does.
        %
        % DISTRESS MODE STILL BYPASSES THIS, unchanged: the overlay represents
        % the asset-liquidation channel that funds real-world distress
        % migration, which is not modelled explicitly. That bypass is now the
        % ONLY route by which an agent moves into debt, which is a cleaner
        % statement of the distress/voluntary split than the old graded
        % threshold allowed.
        %
        % THIS IS STILL THE CONSTRAINT THE MOBILITY TAXONOMY RESTS ON. It is
        % what empties portfolioValues, which sets locationValue to -Inf, which
        % is what makes "wanted to move, could not afford to" expressible at
        % all. Classes 2 (trapped) and 4 (constrained migrant) are unreachable
        % without it -- do not remove it outright.
        postMoveWealth = agent.wealth - currentMovingCost - newCosts;
        hasCost        = (currentMovingCost + newCosts > 0);

        if(~distressMode && and(hasCost, postMoveWealth < 0))
            exceedsCreditLimit(indexP) = true;
        end

        
        % KEEPING WHAT YOU ALREADY HAVE IS ALWAYS AFFORDABLE.
        % At the home location the candidate matching the agent's current
        % portfolio involves no move and no unpaid access codes, so hasCost is
        % false and the test above cannot have fired. Marking it explicitly
        % guarantees the status quo survives filtering, which is what makes
        % "stay put" always available and removes the all--Inf state entirely.
        %
        % This replaces a clause that (a) indexed portfolioSet with indexP,
        % which indexes the FILTERED portfolioSubSet, so it compared the wrong
        % candidate, and (b) tested `exceedsCreditLimit == true` -- the whole
        % array inside and() rather than the element -- so it only ever fired
        % when every candidate was blocked.
        if isHomeHere
            nLmask = size(utilityVariables.utilityHistory, 2);
            if all(portfolioSubSet{indexP}(1, 1:nLmask) == ...
                   agent.currentPortfolio(1, 1:nLmask))
                exceedsCreditLimit(indexP) = false;
                statusQuoIdx = indexP;
            end
        end
        %convert each element to utility using the risk coefficient, and
        %then discount all elements forward to get NPV in utility units
        
        %prospect theory hack - check!!!!
        % ANNUAL AGGREGATION BEFORE THE VALUE FUNCTION (2026-09-04).
        %
        % This previously applied the concave CRRA transform to each QUARTER
        % and then discounted and summed. With u(c) = c^(1-g)/(1-g) that
        % penalises lumpy income streams severely, and every agricultural
        % layer in this application is lumpy: quarterShare puts rice in Q2,
        % maize in Q1, cassava and vanilla in Q4, sisal labour in Q3, while
        % unskilled and skilled wage layers pay in all four quarters.
        % quarterShare is normalised, so those livelihoods have IDENTICAL
        % annual income by construction and differ only in timing -- yet at
        % the default rValue of 0.85 a single-quarter layer scored 0.31 of an
        % evenly-paid one, and 0.25 as rValue approached 1.
        %
        % Per-period concavity is the canonical intertemporal form and is not
        % wrong in general. It is wrong HERE because MIDAS applies it to
        % INCOME rather than consumption, and an agro-pastoral household
        % smooths a lumpy harvest across the year through grain stores and the
        % herd. That smoothing exists in this model -- it is the asset buffer
        % -- but choosePortfolio has no reference to it, so the decision rule
        % could not see the mechanism that makes lumpy income survivable.
        %
        % Summing to the cycle before transforming says the harvest feeds the
        % household all year, which is what the grain store is for. Two
        % livelihoods with equal annual income now score equally regardless of
        % when they pay.
        %
        % SIDE EFFECT, deliberate: this also all but removes the non-finite
        % pathway below. A quarterly zero raised to a negative exponent (any
        % agent with rValue > 1, and rValueMean is sampled up to 1.5) gives
        % Inf, and sign(0)*Inf gives NaN. Annual totals are zero only if the
        % whole portfolio earns nothing for a full year.
        %
        % Absolute values shift scale, which is harmless: portfolioValues is
        % only ever ranked (sorted here, compared across locations below) and
        % the attachment penalty is multiplicative on |v|. Nothing compares it
        % to a fixed threshold.
        cycLen = modelParameters.cycleLength;
        vQ     = currentPortfolioValue(:);
        nQ     = numel(vQ);
        nFull  = floor(nQ / cycLen);
        nRem   = nQ - nFull * cycLen;

        annualVal  = zeros(nFull + (nRem > 0), 1);
        annualDisc = zeros(size(annualVal));
        for iC = 1:nFull
            idxC = (iC - 1) * cycLen + (1:cycLen);
            annualVal(iC)  = sum(vQ(idxC));
            annualDisc(iC) = mean(discountFactor(idxC));
        end
        if nRem > 0
            % Ragged tail: numPeriodsEvaluate is drawn from a mean sampled
            % 6-24 quarters and is rarely a multiple of four. Scale the tail
            % to a full-year equivalent so it is comparable with the complete
            % cycles, then weight its discount by the fraction of the year
            % actually evaluated. Left unscaled, a 1-3 quarter tail would
            % reintroduce the same lumpiness bias at the end of the horizon.
            idxC = nFull * cycLen + (1:nRem);
            annualVal(end)  = sum(vQ(idxC)) * cycLen / nRem;
            annualDisc(end) = mean(discountFactor(idxC)) * nRem / cycLen;
        end

        vSign = sign(annualVal);
        vSign(vSign < 0) = agent.prospectLoss;
        portfolioValues(indexP) = (1/riskCoeff) * ...
            (vSign .* (abs(annualVal) .^ riskCoeff))' * annualDisc;

        % NON-FINITE DIAGNOSTIC, not a guard. Reports once per MATLAB session
        % with enough context to reproduce, so we can establish whether the
        % zero-income pathway actually fires in practice before deciding
        % whether it needs clamping. A NaN portfolio value would otherwise
        % sort unpredictably rather than failing loudly.
        if ~isfinite(portfolioValues(indexP))
            if isempty(warnedNonFinite)
                warnedNonFinite = true;
                warning('choosePortfolio:nonFiniteValue', ...
                    ['non-finite portfolio value: rValue=%.3f riskCoeff=%.3f ' ...
                     'nEval=%d minAnnual=%.4g zeros=%d. Reported once per ' ...
                     'session.'], agent.rValue, riskCoeff, nQ, ...
                     min(annualVal), sum(annualVal == 0));
            end
        end

        % --- Livelihood attachment penalty (see block near top) ---
        % familiarity = fraction of this portfolio's active layers the
        % agent has worked before; penalty grows with unfamiliarity.
        if attachOn
            layersP = logical(portfolioSubSet{indexP}(1, 1:nUL));
            if any(layersP)
                % mean recency-familiarity of this portfolio's layers
                famil = sum(layerFamil(layersP)) / sum(layersP);
                v = portfolioValues(indexP);
                portfolioValues(indexP) = v - attachPenalty * (1 - famil) * abs(v);
            end
        end
    end
    
    %exclude new portfolios that are out of reach due to credit limit

    % --- CHOICE-SET TRACE (diagnostic; no-op unless traceAgentLife) -------
    % Placed BEFORE the credit-limit deletion below, deliberately. Once
    % those rows are removed there is no way to distinguish an agent who
    % stayed put because home was genuinely best from one who stayed
    % because every alternative was unaffordable -- and no existing output
    % separates those two. Recording the flag here keeps both visible.
    if agentLifeTrace('enabled') && agentLifeTrace('isTraced', agent.id)
        nCand = numel(portfolioValues);
        if nCand > 0
            crows = repmat(struct(), 1, nCand);
            for iC = 1:nCand
                lay = logical(portfolioSubSet{iC}(1, 1:nUL));
                famC = NaN; penC = 0;
                if attachOn && any(lay)
                    famC = sum(layerFamil(lay)) / sum(lay);
                    penC = attachPenalty * (1 - famC);
                end
                crows(iC).t             = currentT;
                crows(iC).agentID       = agent.id;
                crows(iC).homeLoc       = agent.matrixLocation;
                crows(iC).candLoc       = locationList(indexL);
                crows(iC).candIdx       = iC;
                crows(iC).isHome        = double(locationList(indexL) == agent.matrixLocation);
                crows(iC).layers        = agentLifeTrace('layerstring', lay);
                crows(iC).nLayers       = sum(lay);
                crows(iC).value         = portfolioValues(iC);
                crows(iC).familiarity   = famC;
                crows(iC).attachPenFrac = penC;
                crows(iC).movingCost    = currentMovingCost;
                crows(iC).creditBlocked = double(exceedsCreditLimit(iC));
                % Counterfactual: blocked under the borrowing-allowance sign.
                % creditBlocked=1 with creditBlockedAllow=0 is a move the
                % current positive-reserve test forbids and the allowance
                % reading would permit.
                crows(iC).creditBlockedAllow = double(exceedsCreditAllowance(iC));
                crows(iC).wealth        = agent.wealth;
                crows(iC).postMoveWealth = agent.wealth - currentMovingCost;
                crows(iC).distressMode  = double(distressMode);
            end
            agentLifeTrace('choice', crows);
        end
    end

    % RETIRED 2026-09-13, with the credit test it measured.
    %
    % This asked whether a blocked option would have been reachable under the
    % borrowing-allowance sign rather than the positive-reserve sign, i.e. how
    % much of the trapped population was an artefact of that comparison. The
    % affordability threshold is now ZERO, so the two readings are the same
    % test -- postMoveWealth < 0 and postMoveWealth < -0 are identical -- and
    % the question is answered by construction: none of it.
    %
    % PINNED TO false RATHER THAN DELETED. The natural expression
    %     ~isempty(exceedsCreditAllowance) && ~all(exceedsCreditAllowance)
    % evaluates to TRUE on the now permanently all-false array, which would set
    % signFreeableAnywhere for every blocked location and mark EVERY trapped
    % agent as a sign artefact -- trappedBySignHistory would equal
    % trappedHistory exactly, and read as "100% artefact". Leaving the line in
    % place, pinned and explained, is safer than deleting it and leaving the
    % downstream consumers to be rediscovered.
    anySurvivesAllowance = false;

    % ASPIRATION: the best this location offers if cost were no object.
    % Captured BEFORE the filtering below discards unaffordable candidates,
    % because that is the whole point -- an agent is trapped when the gap
    % between this and the affordable best is what keeps them in place.
    if ~isempty(portfolioValues)
        locationValueAll(indexL) = max(portfolioValues);
    end

    % The value of doing exactly what the agent already does. Recorded here,
    % after the attachment penalty has been applied to portfolioValues, so it
    % is on the same scale as every other candidate.
    if isHomeHere && ~isempty(statusQuoIdx)
        statusQuoValue = portfolioValues(statusQuoIdx);
    end

    portfolioValues(exceedsCreditLimit) = [];
    portfolioSubSet(exceedsCreditLimit,:) = [];
    portfolioAccessCodes(exceedsCreditLimit) = [];


    if(~isempty(portfolioValues))
        % NOTE: agent.trapped is NOT set here any more. It used to be assigned
        % inside this per-location loop, so the value that survived was
        % whichever the LAST location produced rather than a statement about
        % the agent -- the reported trapped fraction was measuring the last
        % entry in locationList. Classification now happens once, after every
        % location has been evaluated.

        %sort them
        [sortedValues,indexSorted] = sort(portfolioValues,'descend');
        
        
        %save the top few to the 'best portfolio' list
        for indexB = 1:min(agent.numBestPortfolio,length(indexSorted))
            agent.bestPortfolios{locationList(indexL), indexB} = portfolioSubSet{indexSorted(indexB)};
        end
        
        %save the best for current evaluation
        locationValue(indexL) = sortedValues(1);
        locationPortfolio{indexL} = portfolioSubSet{indexSorted(1)};
        % NO (1,1:end-2) SLICE (fixed 2026-09-11).
        %
        % That idiom is correct for portfolio ROWS, which carry
        % [layers, duration, fidelity] and so need two trailing columns
        % trimmed. portfolioAccessCodes holds something different: a logical
        % COLUMN of length nCodes, built by the reshape at line 568.
        %
        % Applying the row idiom to a column made `end` in subscript position 2
        % equal size(X,2) = 1, so 1:end-2 evaluated to 1:-1 -- empty. Confirmed
        % in MATLAB: size(x(1,1:end-2)) for x = false(5,1) returns [1 0].
        %
        % locationAccessCodes was therefore ALWAYS empty, and at the payment
        % step below that meant newCosts summed to 0 and
        % accessCodesPaid(codesToPay) = true was a no-op. Consequences, all
        % silent: layer access costs were never actually debited from wealth
        % (only moving costs were); accessCodesPaid never grew beyond what
        % assignInitialLayers set, so creditCollateral was frozen at its
        % initial value for the agent's whole life; and because line 569
        % cancels already-paid codes against that frozen set, agents were
        % charged full access costs IN THE VALUATION every quarter for layers
        % they already held, biasing every comparison against their own
        % current portfolio.
        locationAccessCodes{indexL} = portfolioAccessCodes{indexSorted(1)};
    else
        % No affordable option at THIS location. -Inf excludes it from
        % selection; it does not say anything about the agent, which is
        % decided after the loop once every location has been seen.
        %
        % The reserve-vs-allowance diagnostic that used to be encoded here as
        % trapped == 2 is retained per location, and aggregated below, so
        % midasMainLoop's trappedBySignHistory keeps its meaning: an agent
        % counts if ANY location it evaluated would have been reachable under
        % a borrowing allowance but not under the reserve test.
        if anySurvivesAllowance
            signFreeableAnywhere = true;
        end
        locationValue(indexL) = -Inf;
        locationPortfolio{indexL} = agent.currentPortfolio;
        % Column, matching the shape set on the affordable path above and the
        % shape of agent.accessCodesPaid, so logical indexing behaves the same
        % way whichever branch produced it.
        locationAccessCodes{indexL} = false(size(utilityVariables.utilityAccessCodesMat, 1), 1);
    end
    agent.bestPortfolioValues(locationList(indexL)) = locationValue(indexL);
end
agent.consideredPortfolios = consideredPortfolioSet;


% ------------------------------------------------------------------------
% CHOICE AND MOBILITY CLASSIFICATION (2026-09-11)
%
% Agents are sorted into the aspiration/ability categories:
%
%   1 voluntarily immobile   nothing beats the status quo; stays, not trapped
%   2 involuntarily immobile something better exists but nothing better is
%     (TRAPPED)              affordable; stays with the current portfolio
%   3 voluntary migrant      moves, and takes the best option available
%   4 constrained migrant    moves, but the best option was unaffordable and
%                            it took the best it could pay for
%   5 distress migrant       routed by the distress overlay, which bypasses
%                            affordability entirely
%
% Selection now ranks ONLY affordable options. Unaffordable locations hold
% -Inf, and the status quo is always affordable, so the all--Inf state that
% previously sent insolvent agents to a random location cannot arise. The
% tie-break is retained for genuine ties between finite values, and is
% explicitly guarded against -Inf so it can never resurrect that behaviour.
affordableMask = isfinite(locationValue);
if ~any(affordableMask)
    % Defensive: should be unreachable in non-distress mode, since the status
    % quo is affordable by construction. Staying put is the safe resolution --
    % never a random destination.
    choice = find(locationList == currentLocation, 1);
    if isempty(choice); choice = 1; end
else
    candidateValue = locationValue;
    candidateValue(~affordableMask) = -Inf;
    [~, indexSorted] = sort(candidateValue, 'descend');

    choice = indexSorted(1);
    % Randomise among genuine ties only. isfinite() is the guard: without it,
    % -Inf == -Inf makes every blocked location a "tie".
    if(length(indexSorted) > 1 && isfinite(candidateValue(indexSorted(1))))
        if(candidateValue(indexSorted(1)) == candidateValue(indexSorted(2)))
            temp = find(candidateValue == candidateValue(indexSorted(1)));
            choice = temp(randperm(length(temp),1));
        end
    end
end

% Classify. Comparisons use a relative tolerance because these are NPVs
% accumulated over many periods, where exact equality is not meaningful.
chosenValue   = locationValue(choice);
bestAspValue  = max(locationValueAll(isfinite(locationValueAll)));
if isempty(bestAspValue); bestAspValue = -Inf; end
% Scale the tolerance from the FINITE values only. chosenValue is -Inf in the
% defensive stay-put branch, and statusQuoValue remains -Inf whenever the
% status-quo candidate was not matched in portfolioSubSet -- it is deduplicated
% by unique(...,'rows') and masked by selectableHere, so a match is likely but
% not guaranteed. abs(-Inf) would make valTol = Inf, and every comparison of
% the form "bestAsp > chosen + valTol" false, so classes 2 and 4 would never be
% recorded and the classification would silently collapse to "stayed" or
% "moved" with no trapped or constrained agents at all.
tolBasis = [chosenValue bestAspValue statusQuoValue];
tolBasis = tolBasis(isfinite(tolBasis));
if isempty(tolBasis)
    valTol = 1e-9;
else
    valTol = 1e-9 * max(1, max(abs(tolBasis)));
end

agentMoves = (locationList(choice) ~= currentLocation);
if distressMode
    agent.mobilityClass = 5;
    agent.trapped = 0;
elseif agentMoves
    % Took the best available. Constrained if something better existed that
    % the agent could not pay for.
    if bestAspValue > chosenValue + valTol
        agent.mobilityClass = 4;
    else
        agent.mobilityClass = 3;
    end
    agent.trapped = 0;
else
    % Stayed. Trapped only if a strictly better option existed somewhere and
    % was unaffordable -- an agent content where it is, is not trapped however
    % poor it is, which is the distinction the previous code could not make.
    if bestAspValue > chosenValue + valTol
        agent.mobilityClass = 2;
        % trapped = 1 ALWAYS from 2026-09-13. The value 2 used to mark an agent
        % trapped only by the sign of the credit test, which a borrowing
        % allowance would have freed. With the affordability threshold now zero
        % that distinction does not exist: a trapped agent cannot fund the move
        % from liquid wealth, full stop. signFreeableAnywhere is pinned false,
        % so this branch resolves to 1 for every agent.
        %
        % trappedHistory keys on > 0 and is therefore UNCHANGED in meaning.
        % trappedBySignHistory keys on == 2 and is now always zero.
        if signFreeableAnywhere
            agent.trapped = 2;
        else
            agent.trapped = 1;
        end
    else
        agent.mobilityClass = 1;
        agent.trapped = 0;
    end
end

bestLocation = locationList(choice);
bestPortfolio = locationPortfolio{choice};

%if the best portfolio isn't where we currently are, we have to move
if(currentLocation ~= bestLocation) 
    
    moved = agent.matrixLocation;
    %pay moving costs
    agent.wealth = agent.wealth - locationMovingCosts(choice);
    
    %update location - this includes i) the matrixLocation (which is the
    %location's index in the location vector, ii) the cityID, which is the
    %unique identifier for the city (used in mapping and in distinguishing
    %from other administrative scales), and iii) the visX and visY markers
    %used to place the agent uniquely somewhere in the appropriate
    %lowest-level unit for visualization purposes
    agent.matrixLocation = locationList(choice);

    agent.location = mapVariables.locations(agent.matrixLocation,:).cityID;

    locationMapIndex = find(mapVariables.map(:,:,end) == agent.location);
    if(isempty(locationMapIndex))
        %this particular city is either sub-pixel size or shares all pixels with other cities and lost each one
        %SO, just set visLocation to the established location of the city
        %centroid
        visLocation = mapVariables.locations.LocationIndex(agent.matrixLocation);
    else
        visLocation = locationMapIndex(randperm(length(locationMapIndex),1));
    end
    [locationX, locationY] = ind2sub([mapParameters.sizeX mapParameters.sizeY],visLocation);
    agent.visX = locationX + rand() - 0.5;
    agent.visY = locationY + rand() - 0.5;
    
    %mark the agent as having moved
    moved = [moved; agent.matrixLocation];

end

%pay any access costs necessary to make use of this layer
% `choice`, not indexSorted(1). The two differ whenever the tie-break picked a
% different location among equals, and now also whenever the defensive
% stay-put branch above set choice without sorting at all. Using indexSorted(1)
% charged the agent for the access codes of a location it did not go to, and
% recorded those codes as paid, so it could later enter layers it had never
% bought into. locationPortfolio and locationMovingCosts have always been
% indexed by `choice`; this line was the odd one out.
codesToPay = locationAccessCodes{choice};
newCosts = sum(utilityVariables.utilityAccessCosts(codesToPay,2));
agent.wealth = agent.wealth - newCosts;
agent.accessCodesPaid(codesToPay) = true;

try
%now that we've paid everything, give the new portfolio to the agent, but
%only give layers that actually have open slots ... this could be an
%unlucky agent that shows up and doesn't get what they dreamed of.
% INCUMBENCY EXEMPTION (2026-08-12).
%
% Capacity should gate HIRING, not continued employment. Previously this line
% masked the chosen portfolio by hasOpenSlots alone, so an agent already
% working a layer lost it the moment the layer was recorded as full --
% including when it was filled by other agents in the same timestep. That was
% tolerable only because slots never actually bound (occupancy ran at 1.7-6.5x
% the census capacity, see midasMainLoop's live slot accounting). Now that
% capacity binds within the timestep, masking incumbents out would evict
% agents from jobs they already hold and generate exactly the churn the fix is
% meant to remove.
%
% An agent therefore retains any layer it ALREADY held, provided it is staying
% in the same location. A move forfeits the old position: you cannot keep a
% job in a district you have left. agent.currentPortfolio is still the PRIOR
% portfolio at this point (it is overwritten a few lines below), and
% currentLocation was captured at the top of this function before
% agent.matrixLocation was reassigned, so both are the pre-decision values.
nLayersMask  = size(utilityVariables.hasOpenSlots, 2);
capacityMask = utilityVariables.hasOpenSlots(agent.matrixLocation, :);
if agent.matrixLocation == currentLocation
    retained = logical(agent.currentPortfolio(1, 1:nLayersMask));
    capacityMask = capacityMask | retained;
end
bestPortfolio(1,1:end-2) = capacityMask & bestPortfolio(1,1:end-2);
catch capErr
    % DIAGNOSTIC 2026-07-28: this bare catch silently swallowed any failure
    % of the capacity mask, handing the agent an UNMASKED portfolio with no
    % warning. If it is firing, spatially restricted and over-capacity layers
    % pass straight through, which would explain vanilla appearing in all 22
    % regions. Report it once rather than hiding it.
    persistent warnedCapMask
    if isempty(warnedCapMask)
        warning('choosePortfolio:capacityMaskFailed', ...
            ['Capacity mask (hasOpenSlots) FAILED and was skipped -- portfolio ' ...
             'handed over unmasked. size(bestPortfolio)=%s, size(hasOpenSlots)=%s. ' ...
             'Error: %s'], mat2str(size(bestPortfolio)), ...
             mat2str(size(utilityVariables.hasOpenSlots)), capErr.message);
        warnedCapMask = true;
    end
    f=1;
end

agent.currentPortfolio = bestPortfolio;

% SITE TRACE (diagnostic 2026-07-28).
badCP = agent.currentPortfolio(1,1:size(utilityVariables.utilityHistory,2)) & ...
        utilityVariables.spatiallyRestricted(agent.matrixLocation,:);
if any(badCP)
    persistent warnedCP
    if isempty(warnedCP); warnedCP = 0; end
    if warnedCP < 5
        warnedCP = warnedCP + 1;
        fprintf('SITE=choosePortfolio:629 agent=%d loc=%d layers=%s (hasOpenSlots there=%s)\n', ...
            agent.id, agent.matrixLocation, mat2str(find(badCP)), ...
            mat2str(utilityVariables.hasOpenSlots(agent.matrixLocation, find(badCP))));
    end
end

if agent.currentPortfolio(end,end) == 0
    agent.currentAspiration = agent.currentPortfolio(end,1:size(utilityVariables.utilityHistory,2));
else
    agent.currentAspiration = false(1,size(utilityVariables.utilityHistory,2));
end


end

