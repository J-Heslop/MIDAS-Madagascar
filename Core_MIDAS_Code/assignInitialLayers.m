function [ agentList ] = assignInitialLayers( agentList, utilityVariables, currentT, modelParameters, applyCapacity )
%assignInitialLayers initializes who is doing what at the start of the
%simulation
%
%   applyCapacity (optional, default FALSE) -- mask the assigned portfolio by
%   utilityVariables.hasOpenSlots, so the agent cannot enter a layer that is
%   already at its census capacity.
%
%   CAPACITY BYPASS (found 2026-08-12). This function is called from two
%   places: buildWorld, for the starting population, and midasMainLoop, for
%   every agent BORN during the run. It honours spatial restrictions (via
%   `selectable` and `locallyAvailable`) but never consulted hasOpenSlots, so
%   births walked straight past the hard-slot mechanism. With population
%   growing from ~1800 to ~4400 over a run, that is thousands of unchecked
%   entries, and it is why urban occupancy kept climbing to 4-6x capacity even
%   after live slot accounting was added to the choosePortfolio path.
%
%   The flag is needed because the two call sites differ: buildWorld.m:57
%   initialises hasOpenSlots to ALL FALSE, so masking the starting population
%   would leave every agent with an empty portfolio. Only the birth call site
%   passes true.

if nargin < 5 || isempty(applyCapacity)
    applyCapacity = false;
end

numLayers = size(utilityVariables.utilityDuration,1);

for indexA = 1:length(agentList)
    currentAgent = agentList(indexA);
   %some basic temporary code to initialize layers.  ideally this initial
   %distribution is informed by census data or other.  note that layers
   %that agents' access code profile should be updated to capture their
   %respective initial state, though i haven't done that here.
   %currentAgent.currentPortfolio = randperm(length(utilityVariables.utilityLayerFunctions),ceil(length(utilityVariables.utilityLayerFunctions)*rand()));

   
   currentAgent.currentPortfolio = false(size(utilityVariables.utilityLayerFunctions,1),1); 
   currentAgent.currentAspiration = false(size(utilityVariables.utilityLayerFunctions,1),1);
   % BUGFIX 2026-07-28 (spatial leak). `selectable` is passed to
   % createPortfolio as argument 11, and its backcasting TOP-UP loop
   % (createPortfolio.m:153-168) fills any leftover time by drawing from
   % `selectable` alone -- that loop applies no location filter whatever.
   % The opening draw uses the spatially-correct `layers` argument, so an
   % agent's PRIMARY livelihood was always valid; the spare-time filler was
   % not. Vanilla leaked into all 22 regions this way (90% of its recorded
   % occupancy was outside its restrict_to set of Sava|Analanjirofo), while
   % the rice layers did not, because vanilla is the only restricted layer
   % cheap enough in time (Q3+Q4 only) to fit as a filler.
   % Filtering `selectable` at source is the fix: createPortfolio has no
   % knowledge of location and cannot do it internally.
   selectable = ~utilityVariables.spatiallyRestricted(currentAgent.matrixLocation,:)';

   %randomly assign a couple of the initial base layers
   %portfolioSet = createPortfolio([], find(utilityVariables.utilityBaseLayers(currentAgent.matrixLocation,:,1) ~= -9999),utilityVariables.utilityTimeConstraints, utilityVariables.utilityPrereqs, currentAgent.pAddFitElement, currentAgent.training, currentAgent.experience, utilityVariables.utilityAccessCosts, utilityVariables.utilityDuration, currentAgent.numPeriodsEvaluate, selectable, utilityVariables.utilityHistory(1,:,:), currentAgent.wealth, currentAgent.pBackCast, utilityVariables.utilityAccessCodesMat);
   % Only offer layers that are spatially available at this agent's location.
   % A layer is unavailable at this location if utilityBaseLayers = 0 AND
   % the slot is hard-capped (nExpected = 0 + hardSlotCountYN = true),
   % which is how createUtilityLayers marks spatially restricted layers.
   % Using utilityBaseLayers > 0 at t=1 (first spinup step) as a proxy.
   locallyAvailable = selectable & (utilityVariables.utilityBaseLayers(currentAgent.matrixLocation,:,1)' > 0);
   portfolioSet = createPortfolio([],find(locallyAvailable),utilityVariables.utilityTimeConstraints, utilityVariables.utilityPrereqs, currentAgent.pAddFitElement, currentAgent.training, currentAgent.experience, utilityVariables.utilityAccessCosts, utilityVariables.utilityDuration, currentAgent.numPeriodsEvaluate, selectable, utilityVariables.utilityHistory(1,:,:), currentAgent.wealth, currentAgent.pBackCast, utilityVariables.utilityAccessCodesMat, modelParameters);

   % BUGFIX 2026-07-28 -- THE VANILLA LEAK.
   % This line used to keep only columns 1:numLayers, discarding the DURATION
   % and FIDELITY columns that createPortfolio returns. Every consumer of
   % currentPortfolio assumes the shape [layers, duration, fidelity]:
   % trainingTracker.m:90 writes the high-fidelity duration to
   % currentPortfolio(1, end-1), and choosePortfolio.m:218 appends the two
   % columns if they are missing.
   %
   % With them stripped, `end-1` at trainingTracker:90 resolved to column
   % numLayers-1 = 9 -- vanilla -- so the duration was written into a LAYER
   % slot. Any non-zero duration reads as true, and every agent acquired
   % vanilla wherever they were standing. That is the whole story: layer 9
   % only because it is numLayers-1, all 22 regions because no location
   % logic is involved, rice untouched because 5 and 6 are never end-1, and
   % immune to every mask because no selection code was ever consulted.
   % Lines 93-98 of trainingTracker read the same wrong column.
   %
   % Keeping the columns makes the portfolio the shape the rest of the model
   % already expects. choosePortfolio:207 tests for their absence before
   % appending, so it will not double-append.
   nLayersHere = size(utilityVariables.utilityHistory,2);
   currentAgent.currentPortfolio = [double(logical(portfolioSet(1,1:nLayersHere))), ...
                                    portfolioSet(1, nLayersHere+1), ...
                                    portfolioSet(1, nLayersHere+2)];

   % --- ACQUISITION-POINT TRACE (diagnostic, 2026-07-28) ---
   % The count-time trace flags violations at the agent's location at the END
   % of t=1, i.e. AFTER the first migration round (~1000 moves). So it cannot
   % distinguish "acquired a layer it should never have had" from "acquired it
   % legitimately, then moved". Check here, at the point of construction,
   % where matrixLocation is definitely the location the portfolio was built
   % for. If this is silent but the count-time trace still fires, the layers
   % are travelling with migrating agents and the problem is that portfolios
   % are not re-masked on arrival -- a different bug entirely.
   if indexA <= 40
       restrictedHere = utilityVariables.spatiallyRestricted(currentAgent.matrixLocation, :);
       badNow = currentAgent.currentPortfolio(1,1:numLayers) & restrictedHere;
       if any(badNow)
           fprintf(['INIT-VIOLATION (pre-trainingTracker): agent=%d loc=%d layers=%s | ' ...
                    'selectable(those)=%s locallyAvailable(those)=%s base(those)=%s\n'], ...
                    currentAgent.id, currentAgent.matrixLocation, ...
                    mat2str(find(badNow)), ...
                    mat2str(selectable(find(badNow))'), ...
                    mat2str(locallyAvailable(find(badNow))'), ...
                    mat2str(utilityVariables.utilityBaseLayers(currentAgent.matrixLocation, find(badNow), 1)));
       end
       preTTportfolio = currentAgent.currentPortfolio(1,1:numLayers);
   end
   if portfolioSet(end,end) == 0
       currentAgent.currentAspiration = logical(portfolioSet(end,1:size(utilityVariables.utilityHistory,2)));
   end
   
   currentAgent.currentFidelity = portfolioSet(1,end-1);
   
   % logical() is required here. currentPortfolio is now [layers, duration,
   % fidelity], and a row holding a numeric duration is double throughout --
   % MATLAB cannot mix logical and numeric in one array. Indexing
   % utilityAccessCodesMat with a double 0/1 vector is numeric indexing, and
   % 0 is not a valid index. Every other consumer already wraps in logical()
   % (midasMainLoop:514, choosePortfolio, trainingTracker:82); this was the
   % one site that relied on the portfolio arriving as a bare logical.
   currentAgent.accessCodesPaid(any(utilityVariables.utilityAccessCodesMat(:,logical(currentAgent.currentPortfolio(1,1:numLayers))', currentAgent.matrixLocation),2)) = true;
   
   currentAgent.firstPortfolio = currentAgent.currentPortfolio;
   currentAgent = trainingTracker(currentAgent, utilityVariables);

   % POST-trainingTracker check. trainingTracker rewrites currentPortfolio --
   % either from the aspiration at its line 45, or in the else branch below
   % that -- and it is the LAST thing to touch the portfolio during
   % initialisation. The earlier check sits before this call, which is why it
   % stayed silent while the count-time trace fired. If this one prints and
   % the pre-check did not, trainingTracker introduced the restricted layer.
   if indexA <= 40
       badAfter = currentAgent.currentPortfolio(1,1:numLayers) & ...
                  utilityVariables.spatiallyRestricted(currentAgent.matrixLocation, :);
       if any(badAfter)
           fprintf(['INIT-VIOLATION (POST-trainingTracker): agent=%d loc=%d layers=%s | ' ...
                    'portfolio before tT=%s after=%s aspiration=%s\n'], ...
                    currentAgent.id, currentAgent.matrixLocation, mat2str(find(badAfter)), ...
                    mat2str(find(preTTportfolio)), ...
                    mat2str(find(currentAgent.currentPortfolio(1,1:numLayers))), ...
                    mat2str(find(currentAgent.currentAspiration(1,1:numLayers))));
       end
   end
   % BELOW WORKING AGE -> NO LIVELIHOOD (2026-08-12).
   %
   % Agents under modelParameters.ageDecision previously received a full
   % livelihood portfolio at birth, so a zero-year-old could occupy a
   % capacity-limited `skilled` place. ageDecision gated whether an agent
   % could RE-CHOOSE, not whether it held a livelihood to begin with.
   %
   % Rationale for gating here rather than setting ageDecision = 0 and
   % reframing every agent as an adult: age is read by four other pieces of
   % machinery that are indexed on ACTUAL age. Survival is interpolated from
   % a grid starting at 0, where the death probability is 0.0413 against
   % 0.0067 at age 14, so an agent entering at nominal age 0 would face
   % infant mortality; the discount-rate scaling in choosePortfolio.m:118 is
   % likewise interpolated on an age grid starting at 0. Reframing would also
   % remove the ~15-year lag between a birth and a new worker, which is the
   % mechanism by which the SSP age structure feeds through to labour supply.
   % Keeping ageDecision at 15 preserves all of that, and 15 is the standard
   % ILO working-age threshold used by the FAOSTAT employment series that
   % agFrac_nat_run is calibrated against.
   %
   % The layer columns are zeroed but the duration and fidelity columns are
   % preserved -- stripping them is what caused the 2026-07-28 vanilla leak
   % (see the note above).
   ageDecisionHere = 15;
   if isfield(modelParameters, 'ageDecision')
       ageDecisionHere = modelParameters.ageDecision;
   end
   if currentAgent.age < ageDecisionHere
       nLayersHere2 = size(utilityVariables.utilityHistory, 2);
       currentAgent.currentPortfolio(1, 1:nLayersHere2) = 0;
       currentAgent.accessCodesPaid(:) = false;
   end

   % CAPACITY MASK. Applied LAST, after trainingTracker, because that is the
   % final thing to rewrite currentPortfolio during initialisation -- masking
   % any earlier would be undone. Mirrors the mask in choosePortfolio, so a
   % newly born agent faces the same capacity constraint as one choosing a
   % livelihood. No incumbency exemption applies here: a new agent holds
   % nothing yet, so there is no position to protect.
   if applyCapacity && ~isempty(utilityVariables.hasOpenSlots)
       nL = size(utilityVariables.hasOpenSlots, 2);
       openHere = utilityVariables.hasOpenSlots(currentAgent.matrixLocation, :);
       currentAgent.currentPortfolio(1, 1:nL) = ...
           double(logical(currentAgent.currentPortfolio(1, 1:nL)) & openHere);
       % Keep accessCodesPaid consistent with the masked portfolio: an agent
       % that did not get the layer should not be recorded as having paid to
       % enter it.
       currentAgent.accessCodesPaid(:) = false;
       heldNow = logical(currentAgent.currentPortfolio(1, 1:numLayers))';
       if any(heldNow)
           currentAgent.accessCodesPaid(any(utilityVariables.utilityAccessCodesMat( ...
               :, heldNow, currentAgent.matrixLocation), 2)) = true;
       end
   end

   currentAgent.agentPortfolioHistory{currentT} = currentAgent.currentPortfolio;
   currentAgent.agentAspirationHistory{currentT} = currentAgent.currentAspiration;
end

