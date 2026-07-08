classdef Agent < handle
    
   properties 
       %agent properties
       id
       location
       matrixLocation
       visX
       visY
       wealth
       wealthHistory
       realizedUtility
       age
       gender
       TOD
       DOB
       trapped
       consecutiveFIYears   % counter of consecutive years food-insecure
                            % (wealth_end < wealth_start). Used by variant
                            % A (distressTriggerCode == 1) of the distress
                            % overlay: trigger when >= distressN.
                            % Decremented (floor 0) on non-FI years.
       quartersBelowWealthThreshold  % counter of consecutive quarters with
                            % wealth < distressWealthThreshold. Used by
                            % variant B (distressTriggerCode == 2):
                            % trigger when >= distressN_quarters.
                            % Decremented (floor 0) on quarters above
                            % threshold.
       lastDistressMoveT    % timestep of the agent's most recent
                            % distress-triggered move (set in
                            % midasMainLoop.m). Used by variant E
                            % (distressTriggerCode == 5) to enforce a
                            % re-fire cooldown, since the income-shock
                            % condition can stay true for several
                            % quarters after a failed harvest.
       buffer               % livestock/grain asset stock, in food-
                            % equivalent (= wealth) units. Accrued from
                            % agricultural surplus, grows slowly, dies in
                            % drought, and is liquidated (at a drought-
                            % dependent conversion rate) to cover
                            % consumption shortfalls. See the buffer block
                            % in midasMainLoop.m and Variant F in
                            % checkDistressTrigger.m. Only meaningful when
                            % modelParameters.bufferEnabled is true.
       bufferHistory        % cell array: year-end buffer level per
                            % timestep (parallels wealthHistory).
       farmBufferGranted    % logical: whether this agent has already
                            % received its one-time starter livestock/grain
                            % endowment (granted the first time it occupies
                            % an agricultural layer -- i.e. takes up farming
                            % and pays the small-farm cost -- not at birth).
       agIncomeYTD          % running total of realised AGRICULTURAL income
                            % this cycle-year (incl. the herd productivity
                            % multiplier). Accumulated each quarter and
                            % read+reset at year-end by the buffer block in
                            % midasMainLoop.m: for ag agents the annual
                            % consumption gap is measured in FOOD terms
                            % (ag income vs subsistence), not as wealth
                            % decline, so that accumulated cash wealth
                            % cannot mask a failed harvest. Only maintained
                            % when modelParameters.bufferEnabled is true.

       %agent accumulated data
       network
       myIndexInNetwork
       accessCodesPaid
       bestPortfolios
       bestAspirations
       consideredPortfolios
       consideredHistory
       bestFidelity
       bestPortfolioValues
       knowsIncomeLocation
       incomeLayersHistory
       training
       experience
       scratch;
       overlap
       heardOpening
       expectedProbOpening
       timeProbOpeningUpdated
       %incomeLayersTest
       currentPortfolio
       currentAspiration
       currentFidelity
       firstPortfolio
       agentPortfolioHistory
       agentAspirationHistory
       personalIncomeHistory
       currentSharedIn
       lastIntendedShareIn
       moveHistory

       %agent preferences
       incomeShareFraction
       shareCostThreshold
       knowledgeShareFrac
       pInteract
       pMeetNew
       pAddFitElement
       pChoose
       pBackCast
       fDecay
       pGetLayer_informed
       pGetLayer_uninformed
       pRandomLearn
       countRandomLearn
       numBestLocation
       numBestPortfolio
       numRandomLocation
       numRandomPortfolio
       numPeriodsEvaluate
       numPeriodsMemory
       discountRate
       rValue
       bList
       prospectLoss
   end
   
   events
      %none at the moment
   end
   
   methods 
       %basic constructor
      function A = Agent(id, location)
         A.id = id;
         A.location = location;
         A.network = [];
         A.TOD = -9999;  %TOD is 'time of death'
         A.DOB = -9999;  %DOB is 'date of birth'
         A.trapped = 0;
         A.consecutiveFIYears = 0;
         A.quartersBelowWealthThreshold = 0;
         A.lastDistressMoveT = -9999;
         A.buffer = 0;
         A.farmBufferGranted = false;
         A.agIncomeYTD = 0;
      end %
      
      %as written presently, most agent actions are coded as model
      %subroutines with input agents, as opposed to agent member functions
      
      %since there are no child classes that inherit Agent, there isn't
      %really much of a need, and this structure makes it easier to plug
      %and play different routines
     
   end % methods
   
end % classdef