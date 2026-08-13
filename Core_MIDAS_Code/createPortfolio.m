function [portfolioSets] = createPortfolio(portfolio, layers, constraints, prereqs,pAdd, agentTraining, agentExperience, utilityCosts, utilityDuration, numPeriodsEvaluate, selectable, currentUtilities, agentWealth, pBackCast, accesscodes, modelParameters)
%createPortfolio draws a random portfolio of utility layers that fit the current time constraint

%NOTE - MAKE FUNCTION FOR TIME USE AND APPLY TO FORECASTING

%Steps:
%1. If a portfolio is not specified as part of argument, create one at
%random. This is done in one of two ways: backcasting (selecting portfolio
%layers at random and then filling in any pre-reqs for aspirations) or forecasting
%(selecting only selectable layers and then seeing what aspirations could
%be enabled by these). Which of these is followed depends on the parameter
%pBackCast and a random draw. The output is a n x 3 matrix that tracks
%different stages of portfolios over the evaluation periods. The first row
%represents the near-term high-fidelity portfolio, last row represents the
%long-term aspiration, and middle rows represent any intermediate
%portfolios. Columns represent (1) the selected portfolio layers, (2) the
%time duration for each, and (3) a flag of high- vs low-fidelity
%portfolios.

%Algorithm for backcasting:
%1. Build portfolio by selecting layers at random until time is filled up.
%2. Check if there are any aspirational elements to portfolio
%3. If there are aspirational elements in portfolio, fill out high-fidelity portfolio with prereqs that are selectable
%4. With time remaining, fill out remaining high-fidelity portfolio with other selectable layers
%5. If there are prereqs, set high-fidelity portfolio duration to max prereq duration or agent evaluation period, whichever is shorter
%6. Check if agent wealth + income accumulated during high-fidelity part would be enough to afford aspirational element
    %6a. If not enough resources, remove any layers that have "expired"
    %(e.g. school) and replace with other selectable income-generating
    %layers as a medium portfolio. Figure out how many time periods would
    %be required to accumulate sufficient resources to afford aspiration.
    %6b. If sufficient resources are accumulated before period evaluation ends,
    %set medium term duration to this time period (extra time to accumulate resources)
%7. if there are no prereqs, set high-fidelity portfolio to max duration
%of portfolio layer or agent evaluation period, whichever is shorter
%8. Return portfolio, duration, and aspiration flag


%Algorithm for forecasting:
%1a. Identify currently selectable layers, and build portfolio using only
%these layers until time is filled up or there are no more selectable
%layers.
%1b. Check if agent already has educational training, in which case, remove
%education.
%2. Check which aspirations are enabled by selectable layers
%3. If more than one aspiration, pick one at random to be the future
%aspiration associated with this portfolio.
%4. Figure out high-fidelity duration by taking the max prereq duration or
%agent evaluation period, whichever is shorter.
%5. Return portfolio layers, duration, and aspiration flag


%To-DO:
%1) Figure out whether to account for income constraints in both
%backcasting and forecasting


%start with all the time in the world
timeRemaining = ones(1, size(constraints,2)-1);  %will be as long as the cycle defined for layers
aspiration = false(1,size(constraints,1)); %Initialize blank column array of aspirations
portfolioPrereqs = []; %Initialize blank array of potential prereqs for portfolio aspiration
highfidelityDuration = numPeriodsEvaluate; %Initialize duration of high-fidelity portion to be equal to agent's evaluation period
accumulatingDuration = 0; %initialize time for an accumulating portfolio (i.e. to accumulate enough financial resources) 
[i,j,s] = find(prereqs); %Indices of layers that are prerequisites, where j are requirements
portfolioSets = [];
medTermFlag = false; %Flag to indicate if we need to create medium term portfolios

%First check if portfolio is specified. If not, create one at random (original code)
if isempty(portfolio)
   
    %initialize an empty portfolio
    portfolio = false(1,size(constraints,1));
    
    %BackCasting process (i.e. see if there are any aspirations then fill
    %in high-fidelity portion with pre-reqs)
    if rand() < pBackCast
        %while we still have time left and layers that fit, OR portfolio is
        %empty
        
        while(sum(timeRemaining) > 0 && ~isempty(layers))
    
            %draw one of those layers at random and remove it from the set
            randomDraw = ceil(rand()*length(layers));
    
            nextElement = layers(randomDraw);
            layers(randomDraw) = [];
            
            if(~portfolio(nextElement))  %if this one isn't already in the portfolio (e.g., it got drawn in as a prereq in a previous iteration)
            %make a temporary portfolio for consideration

                tempPortfolio = portfolio;
                tempPortfolio(nextElement) = true;
                
                timeUse = timeCalc(constraints, tempPortfolio, modelParameters);

                timeExceedance = sum(sum(timeUse > 1)) > 0;

                %test whether to add it to the portfolio, if it fits
                if(~timeExceedance && rand() < pAdd)
                    portfolio = tempPortfolio;
                    %remove any that are OBVIOUSLY over the limit, though this won't
                    %catch any that have other time constraints tied to prereqs
                    timeRemaining = 1 - timeUse;
                    layers(sum(constraints(layers,2:end) > timeRemaining,2) > 0) = [];
                end
            end
            if ~any(portfolio)
                %disp('Empty portfolio')
            end
        end

        %Now check if portfolio has any aspirational elements
        samplePortfolio = portfolio';
        aspirations = samplePortfolio & ~selectable & ~agentTraining;
    
        %If any elements are aspirations, pick one at random and figure out prereqs
        if any(aspirations)
            indAspiration = find(aspirations);
            samplePortfolio(aspirations) = false;

            %Select one aspiration at random
            if length(indAspiration) > 1
                indAspiration = datasample(indAspiration,1);
            end
            aspiration(1,indAspiration) = true;
            
    
            %Add a selectable prereq to portfolio    
            portfolioPrereqs = j(i==indAspiration);
            portfolioPrereqs(portfolioPrereqs == indAspiration) = []; %remove own layer from aspiration's prereqs
            %Check if any prereqs and pick one at random to add
            if any(selectable(portfolioPrereqs))
            %if any(portfolioPrereqs)
                indPrereq = datasample(portfolioPrereqs,1);
                samplePortfolio(indPrereq) = true;
                duration = min(max(utilityDuration(indPrereq,1) - agentExperience(indPrereq,1),0),min(utilityDuration(samplePortfolio,2) - agentTraining(samplePortfolio))); %Minimum time durations for pre-reqs, accounting for any experience already accumulated. Note that some layers can be prereqs even if sufficient training is amassed (due to costs), hence max of training needed and 0
            end
            
            %If time is exceeded, remove layers one by one    
            timeRemaining = 1 - sum(constraints(samplePortfolio,2:end),1); 
            while any(sum(timeRemaining,1) < 0)  
                tempLayers = find(samplePortfolio);

                tempLayers(ismember(tempLayers,portfolioPrereqs)) = [];
                if length(tempLayers) > 1
                    samplePortfolio(datasample(tempLayers,1)) = false;
                else
                    samplePortfolio(tempLayers) = false;
                end
                timeUse = timeCalc(constraints, samplePortfolio, modelParameters);
                timeRemaining = 1 - timeUse;    
            end

            %Now, if time still remains and selectable layers are still available, keep filling portfolio    
            selectableLayers = selectable & ~samplePortfolio;
            while sum(timeRemaining) > 0 && any(selectableLayers)
                tempLayers = find(selectableLayers,1);
                if length(tempLayers) > 1
                    indexS = datasample(tempLayers,1); 
                else
                    indexS = tempLayers;
                end
                samplePortfolio(indexS) = true;    
  
                timeUse = timeCalc(constraints, samplePortfolio, modelParameters);              
                timeRemaining = 1 - timeUse;    

                selectableLayers(indexS) = false;    
            end
        end
        %Now, figure out duration, based on time needed to get sufficiently trained.
        %Guard: if all layers were aspirational and removed, samplePortfolio may be
        %all-false, making utilityDuration(samplePortfolio,2) an empty 0x1 vector.
        %min() of a 0x1 vector returns 0x1 (not a scalar), which breaks downstream
        %arithmetic.  Fall back to numPeriodsEvaluate in that case.
        if ~any(samplePortfolio)
            highfidelityDuration = numPeriodsEvaluate;
        elseif any(portfolioPrereqs) && (duration < numPeriodsEvaluate)
            highfidelityDuration = min(duration, min(utilityDuration(samplePortfolio,2) - agentTraining(samplePortfolio)));
        else
            %If no prereqs, set highFidelity duration to max time allowed in portfolio
            highfidelityDuration = min(numPeriodsEvaluate, min(utilityDuration(samplePortfolio,2) - agentTraining(samplePortfolio)));
        end

        portfolioSets(1,:) = [samplePortfolio' highfidelityDuration 1];

        %If highfidelityDuration < numPeriodsEvaluate, check if agent can afford aspiration after completing prereqs
        newIncome = 0;
        %Average income across all seasons
        for indexT = 1:size(constraints(:,2:end),2)
            newIncome = newIncome + (samplePortfolio' * currentUtilities(:,:,indexT)') .* 1/size(constraints(:,2:end),2);
        end
        newTraining = agentExperience + samplePortfolio .* highfidelityDuration;
        agentResources = agentWealth + newIncome * highfidelityDuration;
        
        %If agent doesn't have aspirations but needs to fill out planning
        %horizon, OR has aspirations but can't afford them after initial
        %training, set medium term high-fidelity portfolio
        % BUGFIX 2026-07-28: aspiration affordability test.
        %
        % WAS: agentResources < utilityCosts(indAspiration)
        %
        % utilityCosts is utilityAccessCosts, an (nCostTypes x 2) array
        % indexed by COST TYPE -- three types here (educationCost,
        % largeFarmCost, smallFarmCost), so six elements. Column 1 holds the
        % type CODE (1,2,3); column 2 holds the amount. indAspiration is a
        % LAYER index (1..nLayers). Indexing one by the other read the wrong
        % table: for the aspirations that actually occur in this
        % configuration -- unskilled2 (layer 2) and skilled (layer 3) -- it
        % returned the integers 2 and 3 from column 1, not a cost. Agents
        % were therefore tested against "wealth < 2" and "wealth < 3", which
        % almost always passed, so medTermFlag was effectively never set and
        % the medium-term planning branch below (accumulate resources towards
        % an aspiration you cannot yet afford) has been dead code.
        %
        % It only crashed on 2026-07-28 because the new spatial mask made
        % restricted layers (vanilla = 9, industrial_crop = 10) into
        % aspirations, indexing past the six available elements.
        %
        % NOW: resolve the layer's cost TYPE(s) via accesscodes, then read
        % the amount from column 2 -- the same lookup selectableFlag.m uses.
        % indAspiration is scalar by this point (narrowed at line ~122).
        %
        % BEHAVIOURAL CHANGE: this activates the medium-term planning path.
        % Agents with unaffordable aspirations will now build interim
        % portfolios and accumulate towards them instead of proceeding as
        % though the aspiration were already affordable. Expect migration and
        % occupational dynamics to shift; compare against a pre-fix baseline.
        % GUARD: indAspiration is assigned only inside the `if any(aspirations)`
        % block above (which closes at ~line 169), so it may not exist here.
        % The original relied on && short-circuiting to avoid touching it;
        % keep that protection explicitly.
        aspirationCost = 0;
        if any(aspirations) && ~isempty(accesscodes)
            aspirationCost = sum(utilityCosts(accesscodes(:, indAspiration, 1) > 0, 2));
        end

        if any(aspirations) && agentResources < aspirationCost
            medTermFlag = true;
        elseif ~any(aspirations) && (highfidelityDuration < numPeriodsEvaluate)
            medTermFlag = true;
        end
        if medTermFlag == true
            %Re-assess which layers are selectable after high-fidelity duration
            tempPortfolio = samplePortfolio;

            % BUGFIX 2026-07-28 -- THE SPATIAL LEAK, finally located.
            % selectableFlag checks prerequisites, duration and cost only; it
            % has no knowledge of location. Recomputing here DISCARDED the
            % location-masked `selectable` the caller passed in, and the
            % top-up loop below then added any layer that fit the agent's
            % remaining time. That is why masking `selectable` at all four
            % call sites changed nothing: the mask was thrown away inside
            % this function.
            % It selects vanilla and not the rice layers because of the time
            % profiles -- vanilla needs only Q3+Q4 at half time, so it fits
            % almost any spare slot, whereas rice needs Q1+Q2+Q4 and collides
            % with whatever the agent already does. Hence 90% of vanilla
            % occupancy outside Sava|Analanjirofo while rice stayed correctly
            % confined.
            % `selectable` is the caller's location-filtered set; intersecting
            % with it restores the constraint without changing the
            % prerequisite/duration/cost logic.
            selectableLayers = selectableFlag(prereqs, accesscodes, utilityCosts, agentTraining, newTraining, tempPortfolio, agentResources, utilityDuration(:,2)) ...
                               & selectable;
            tempPortfolio(~selectableLayers) = false;

            timeUse = timeCalc(constraints, tempPortfolio, modelParameters);
            timeRemaining = 1 - timeUse;
            %Re-iterate to identify any additional selectable layers that agent can deploy

            while sum(timeRemaining) > 0 && any(selectableLayers)    
                indexS = datasample(find(selectableLayers,1),1);    
                tempPortfolio(indexS) = true; 
                timeUse = timeCalc(constraints, tempPortfolio, modelParameters);
                timeRemaining = 1 - timeUse;    
                selectableLayers(indexS) = false;    
            end

            %Set medium Duration as minimum of (i) time required to acquire enough resources for aspiration, or remaining time left that agent has in their time horizon
            % BUGFIX 2026-07-28 (same branch, three faults):
            %  (a) utilityCosts(indAspiration) repeated the cost-type/layer
            %      index confusion fixed above -- use aspirationCost, which
            %      resolves the layer's cost type via accesscodes.
            %  (b) The result could be NEGATIVE. If agentResources already
            %      exceeds the cost the numerator is negative, giving a
            %      portfolio chunk with negative duration. choosePortfolio.m
            %      then computes endDuration < startDuration, sets
            %      startDuration = endDuration + 1 <= 0, and indexes
            %      currentPortfolioValue(0:end) -- "Array indices must be
            %      positive integers". That is the 1998 crash.
            %  (c) newIncome can be zero or negative (agents in deficit),
            %      making the division Inf or NaN.
            % None of this ever surfaced because medTermFlag was unreachable
            % until the affordability test was corrected.
            if any(aspirations) && newIncome > 0
                needed = max(0, aspirationCost - agentResources);
                accumulatingDuration = min(ceil(needed / newIncome), ...
                                           numPeriodsEvaluate - highfidelityDuration);
            else
                accumulatingDuration = numPeriodsEvaluate - highfidelityDuration;
            end
            accumulatingDuration = max(0, accumulatingDuration);   % durations cannot be negative
            portfolioSets = [portfolioSets; [tempPortfolio' accumulatingDuration 1]];

        end

        %Time left to dream about aspirations. Clamped at 0 for the same
        %reason as above -- a negative chunk duration corrupts the
        %startDuration walk in choosePortfolio.
        aspirationDuration = max(0, numPeriodsEvaluate - highfidelityDuration - accumulatingDuration);
        portfolioSets = [portfolioSets; [aspiration aspirationDuration 0]];


    %Forecasting process
    else
        %Find selectable layers. If there are none (e.g. agent is in debt),
        %choose least costly layer
        selectableLayers = find(selectable);
        if isempty(selectableLayers)
            test = 'No selectable layers'
            [minValue,selectableLayers] = min(utilityCosts);
        end

        %Build portfolio based on currently selectable layers
        while(sum(timeRemaining) > 0 && any(selectableLayers))
            selectableInd = ceil(rand()*length(selectableLayers));
            nextElement = selectableLayers(selectableInd);
            selectableLayers(selectableInd) = [];
            if(~portfolio(nextElement))  %if this one isn't already in the portfolio
            %make a temporary portfolio for consideration
                tempPortfolio = portfolio;
                tempPortfolio(nextElement) = true;
        
                timeUse = timeCalc(constraints, tempPortfolio, modelParameters);
                timeExceedance = sum(sum(timeUse > 1)) > 0;

                %Add to portfolio if time is not exceeded
                if(~timeExceedance)
                    portfolio(nextElement) = true;
                    %remove any that are OBVIOUSLY over the limit, though this won't
                    %catch any that have other time constraints tied to prereqs
                    timeUse = timeCalc(constraints, portfolio, modelParameters);
                    timeRemaining = 1 - timeUse;
                    layers(sum(constraints(layers,2:end) > timeRemaining,2) > 0) = [];
                end

            end
        end

        %Figure out high-fidelity duration based on maximum of the layers' minimum
        %durations
        duration = max(min(utilityDuration(portfolio',1) - agentExperience(portfolio,1)),0); %Array of minimum time durations for pre-reqs, accounting for experience accumulated
        highfidelityDuration = min([max(duration) numPeriodsEvaluate]);
        portfolioSets = [portfolio highfidelityDuration 1];
        %Now find a random aspiration (if any) that is enabled by selectable
        %portfolio
        potentialAspirations = false(1, size(constraints,1));
        selectedLayers = find(portfolio);
        numLayers = length(selectedLayers);
        for indexI = 1:1:numLayers
            potentialAspirations(find(prereqs(:,selectedLayers(indexI)))') = true;
            
        end
        indAspiration = find(potentialAspirations);
        
        %While there are still potential aspirations, but none has been
        %selected yet
        while ~isempty(indAspiration) && all(~(aspiration))
            %Select one aspiration at random
            indexA = ceil(rand() * length(indAspiration));
            nextAspiration = indAspiration(indexA);

            %Check for prereqs here
            %portfolioPrereqs = j(i == nextAspiration)
            %portfolioPrereqs(portfolioPrereqs == nextAspiration) = []

            %If aspiration is not already in portfolio
            if ~portfolio(nextAspiration)
                aspiration(1, nextAspiration) = true;
            else
                indAspiration(indexA) = [];
            end
           
        end

        
        % If there are no aspirations to choose from (e.g. agent has
        % already achieved all the training they need), then set
        % high-fidelty duration to numPeriodsEvaluate
        if all(~aspiration)
            highfidelityDuration = numPeriodsEvaluate;
            portfolioSets = [portfolio highfidelityDuration 1];
        end
        
        aspirationDuration = numPeriodsEvaluate - highfidelityDuration;
        portfolioSets = [portfolioSets; [aspiration aspirationDuration 0]];
    end
    
        
%If portfolio layers are already specified    
else
    portfolio = logical(portfolio(1:size(constraints,1))');

    %Find selectable layers. If there are none (e.g. agent is in debt), choose least costly layer
    selectableLayers = find(selectable);
    if isempty(selectableLayers)
        test = 'No selectable layers'
        [minValue,selectableLayers] = min(utilityCosts);
    end

    %Build portfolio based on currently selectable layers
    while(sum(timeRemaining) > 0 && any(selectableLayers))
        selectableInd = ceil(rand()*length(selectableLayers));
        nextElement = selectableLayers(selectableInd);
        selectableLayers(selectableInd) = [];
        if(~portfolio(nextElement))  %if this one isn't already in the portfolio
            %make a temporary portfolio for consideration
            tempPortfolio = portfolio;
            tempPortfolio(nextElement) = true;
            timeUse = timeCalc(constraints, tempPortfolio, modelParameters);    
            timeExceedance = sum(sum(timeUse > 1)) > 0;

            %Add to portfolio if time is not exceeded
            if(~timeExceedance)
                portfolio(nextElement) = true;
                timeUse = timeCalc(constraints, portfolio, modelParameters);
                %remove any that are OBVIOUSLY over the limit, though this won't
                %catch any that have other time constraints tied to prereqs
                timeRemaining = 1 - timeUse;
                layers(sum(constraints(layers,2:end) > timeRemaining,2) > 0) = [];
            end

        end
    end

    %Figure out high-fidelity duration based on maximum of the layers' minimum durations
    %duration = max(min(utilityDuration(portfolio,1) - agentExperience(portfolio,1)),0); %Array of minimum time durations for pre-reqs, accounting for experience accumulated
    %highfidelityDuration = min([max(duration) numPeriodsEvaluate]);
    highfidelityDuration = numPeriodsEvaluate;
    portfolioSets = [portfolio' highfidelityDuration 1];
    %Now find a random aspiration (if any) that is enabled by selectable portfolio
    potentialAspirations = false(1, size(constraints,1));
    selectedLayers = find(portfolio);
    numLayers = length(selectedLayers);
    for indexI = 1:1:numLayers
        potentialAspirations(find(prereqs(:,selectedLayers(indexI)),1)) = true;
    end

    indAspiration = find(potentialAspirations);
        
    %While there are still potential aspirations, but none has been selected yet
    while ~isempty(indAspiration) && all(~(aspiration))
        %Select one aspiration at random
        indexA = ceil(rand() * length(indAspiration));
        nextAspiration = indAspiration(indexA);

        %Check for prereqs here
        portfolioPrereqs = j(i == nextAspiration);
        portfolioPrereqs(portfolioPrereqs== nextAspiration) = [];
            
        %If aspiration is not already in portfolio, but all prereqs are
        if ~portfolio(nextAspiration) && all(portfolio(portfolioPrereqs))
            aspiration(1, nextAspiration) = true;
        else
            indAspiration(indexA) = [];
        end
           
    end
        
    % If there are no aspirations to choose from (e.g. agent has
    % already achieved all the training they need), then set
    % high-fidelty duration to numPeriodsEvaluate
    if all(~aspiration)
        highfidelityDuration = numPeriodsEvaluate;
    end
        
    aspirationDuration = numPeriodsEvaluate - highfidelityDuration;
    portfolioSets = [portfolioSets; [aspiration aspirationDuration 0]];    


end


%Test for empty portfolios
if isempty(portfolio)
    %test = 'empty portfolio in createPortfolio'
end
end










