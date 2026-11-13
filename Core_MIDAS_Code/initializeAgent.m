function newAgent = initializeAgent(agentParameters, utilityVariables, modelParameters, age, gender, location, varargin)

knowledgeShareFrac = min(1,max(0,agentParameters.knowledgeShareFracMean + randn() * agentParameters.knowledgeShareFracSD));
shareCostThreshold = min(1,max(0,agentParameters.shareCostThresholdMean + randn() * agentParameters.shareCostThresholdSD));
incomeShareFraction = min(1,max(0,agentParameters.incomeShareFractionMean + randn() * agentParameters.incomeShareFractionSD));
wealth = max(0,agentParameters.wealthMean + randn() * agentParameters.wealthSD);
numBestLocation = max(1,round(agentParameters.bestLocationMean + randn() * agentParameters.bestLocationSD));
numBestPortfolio = max(1,round(agentParameters.bestPortfolioMean + randn() * agentParameters.bestPortfolioSD));
numBestAspirations = numBestPortfolio; %Set number of best aspirations equal to number of best portfolios
numBestFidelity = numBestPortfolio; %keep track of fidelity length for each best portfolio

numRandomLocation = max(1,round(agentParameters.randomLocationMean + randn() * agentParameters.randomLocationSD));
numRandomPortfolio = max(1,round(agentParameters.randomPortfolioMean + randn() * agentParameters.randomPortfolioSD));
numPeriodsEvaluate = max(1,round(agentParameters.numPeriodsEvaluateMean + randn() * agentParameters.numPeriodsEvaluateSD));
numPeriodsMemory = max(1,round(agentParameters.numPeriodsMemoryMean + randn() * agentParameters.numPeriodsMemorySD));
pInteract = min(1,max(0,agentParameters.interactMean + randn() * agentParameters.interactSD));
pMeetNew = min(1,max(0,agentParameters.meetNewMean + randn() * agentParameters.meetNewSD));
pAddFitElement = min(1,max(0,agentParameters.probAddFitElementMean + randn() * agentParameters.probAddFitElementSD));
pRandomLearn = min(1,max(0,agentParameters.randomLearnMean + randn() * agentParameters.randomLearnSD));
countRandomLearn = min(1,max(0,round(agentParameters.randomLearnCountMean + randn() * agentParameters.randomLearnCountSD)));
pChoose = min(1,max(0,agentParameters.chooseMean + randn() * agentParameters.chooseSD));
pBackCast = min(1,max(0,agentParameters.backCastMean + randn() * agentParameters.backCastSD));
rValue = max(0,agentParameters.rValueMean + randn() * agentParameters.rValueSD);
discountRate = max(0, agentParameters.discountRateMean + randn() * agentParameters.discountRateSD);
prospectLoss = -max(0, agentParameters.prospectLossMean + randn() * agentParameters.prospectLossSD);
pGetLayer_informed = min(1,max(0,agentParameters.informedExpectedProbJoinLayerMean + randn() * agentParameters.informedExpectedProbJoinLayerSD));
pGetLayer_uninformed = min(1,max(0,agentParameters.uninformedMaxExpectedProbJoinLayerMean + randn() * agentParameters.uninformedMaxExpectedProbJoinLayerSD));
fDecay = min(1,max(0,agentParameters.expectationDecayMean + randn() * agentParameters.expectationDecaySD));

%bList has elements corresponding to each kind of utility layer present
bList = max(0, agentParameters.bListMean + randn(utilityVariables.numForms,1) * agentParameters.bListSD);

if(~isempty(varargin))
    newAgent = varargin{1};
else
    newAgent = Agent(Inf, location);
end


% STAGGERED DISTRESS COOLDOWN (2026-09-11).
%
% Agent.m defaults lastDistressMoveT to -9999, so every agent's cooldown is
% clear from the first timestep. postSpin then turns true for the whole
% population simultaneously, and every agent meeting the shortfall condition
% fires in the SAME quarter. distressCooldownQuarters = 4 equals the annual
% cycle, so each of them becomes eligible again in precisely that quarter the
% following year: the cohort stays phase-locked for the rest of the run.
%
% Observed in the 2026-09-11 trace: cooldownOK for 10 of 10 traced agents at
% t = 11 and again at t = 15, with 721 of 1642 agents moving in that single
% quarter. The trigger itself was correct -- every firing agent had a genuine
% shortfall above threshold -- but the TIMING was an artefact, set by when
% spinup happened to end rather than by anything agricultural. Changing
% spinupTime moved the spike.
%
% Drawing the initial value across one cooldown window ending at the end of
% spinup spreads first eligibility over timesteps spinupTime+1 .. spinupTime+cd
% instead of concentrating it on spinupTime+1. There is no reason for every
% household in the Grand Sud to become able to move on the same day, and the
% annual totals are unaffected -- only their distribution within the year.
%
% Newborns are created through this same function; for them the value lies far
% in the past by the time they reach ageDecision, so cooldownOK is true on
% their first eligible quarter exactly as with -9999. The draw is
% unconditional so that runs with and without the distress overlay consume the
% same random stream and stay comparable.
cdQ = 4;
if isfield(modelParameters, 'distressCooldownQuarters')
    cdQ = max(1, round(modelParameters.distressCooldownQuarters));
end
spinQ = 0;
if isfield(modelParameters, 'spinupTime')
    spinQ = modelParameters.spinupTime;
end
newAgent.lastDistressMoveT = spinQ + 1 - cdQ + randi([0, cdQ - 1]);

newAgent.accessCodesPaid = agentParameters.init_accessCodesPaid;
newAgent.knowsIncomeLocation = agentParameters.init_knowsIncomeLocation;
newAgent.scratch = sparse(agentParameters.init_incomeLayersHistory(:));
newAgent.incomeLayersHistory = agentParameters.init_incomeLayersHistory;
newAgent.overlap = agentParameters.init_incomeLayersHistory;
newAgent.expectedProbOpening = agentParameters.init_expectedProbOpening;
newAgent.heardOpening = agentParameters.init_knowsIncomeLocation;
newAgent.personalIncomeHistory = zeros(size(agentParameters.init_incomeLayersHistory,3),1);
newAgent.netIncomeHistory      = zeros(size(agentParameters.init_incomeLayersHistory,3),1);
newAgent.timeProbOpeningUpdated = zeros(size(agentParameters.init_expectedProbOpening));
newAgent.currentSharedIn = 0;

newAgent.knowledgeShareFrac = knowledgeShareFrac;
newAgent.shareCostThreshold = shareCostThreshold;
newAgent.incomeShareFraction = incomeShareFraction;
newAgent.wealth = wealth;
newAgent.wealthHistory = cell(size(modelParameters.timeSteps,1));
% Livestock/grain buffer (see Agent.m, midasMainLoop.m buffer block).
% Always born with zero buffer. The starter livestock/grain endowment is
% granted later, the first time the agent takes up farming (occupies an
% agricultural layer and pays the small-farm cost) -- see the farm-entry
% grant in midasMainLoop.m -- not at birth.
newAgent.buffer = 0;
newAgent.farmBufferGranted = false;
newAgent.nonAgBufferGranted = false;
newAgent.parentID = 0;
newAgent.children = [];
newAgent.bufferHistory = cell(size(modelParameters.timeSteps,1));
newAgent.agIncomeYTD = 0;   % annual ag-income accumulator (see Agent.m)
newAgent.lastShortfall = 0; % unmet year-end consumption shortfall (Variant F; see Agent.m)
% Livelihood attachment: tendency to stay in the current field of work,
% heterogeneous across agents, U(0,1). See Agent.m and choosePortfolio.m.
newAgent.livelihoodAttachment = rand();
% Recency-weighted layer experience (EMA; see Agent.m) -- starts empty.
newAgent.recentExperience = zeros(size(utilityVariables.utilityLayerFunctions,1),1);
newAgent.realizedUtility = 0;
newAgent.numBestLocation = numBestLocation;
newAgent.numBestPortfolio = numBestPortfolio;

newAgent.numRandomLocation = numRandomLocation;
newAgent.numRandomPortfolio = numRandomPortfolio;
newAgent.bestPortfolios = cell(size(utilityVariables.utilityHistory,1),numBestPortfolio);
newAgent.bestAspirations = cell(size(utilityVariables.utilityHistory,1), numBestAspirations);
newAgent.bestFidelity = cell(size(utilityVariables.utilityHistory,1), numBestFidelity);
newAgent.bestPortfolioValues = zeros(size(utilityVariables.utilityHistory,1),numBestPortfolio);
newAgent.consideredPortfolios = [];
newAgent.training = false(size(utilityVariables.utilityLayerFunctions,1),1);
newAgent.experience = zeros(size(utilityVariables.utilityLayerFunctions,1),1);
% Per-agent trace arrays, allocated only when modelParameters.agentTraceOn.
% Left empty otherwise: nothing in the model reads them, and every agent
% created over a 100-year run pays for the allocation. See readParameters.m.
% (newAgent.wealthHistory above is always allocated -- checkDistressTrigger
% reads it, so it is model state rather than diagnostics.)
if isfield(modelParameters, 'agentTraceOn') && modelParameters.agentTraceOn
    newAgent.consideredHistory = cell(size(modelParameters.timeSteps,1));
    newAgent.agentPortfolioHistory = cell(size(modelParameters.timeSteps,1));
    newAgent.agentAspirationHistory = cell(size(modelParameters.timeSteps,1));
end
newAgent.pInteract = pInteract;
newAgent.pMeetNew = pMeetNew;
newAgent.pAddFitElement = pAddFitElement;
newAgent.pRandomLearn = pRandomLearn;
newAgent.countRandomLearn = countRandomLearn;
newAgent.pChoose = pChoose;
newAgent.pBackCast = pBackCast;
newAgent.fDecay = fDecay;
newAgent.pGetLayer_informed = pGetLayer_informed;
newAgent.pGetLayer_uninformed = pGetLayer_uninformed;
newAgent.numPeriodsEvaluate = numPeriodsEvaluate;
newAgent.numPeriodsMemory = numPeriodsMemory;
newAgent.discountRate = discountRate;
newAgent.rValue = rValue;
newAgent.bList = bList;
newAgent.prospectLoss = prospectLoss;
newAgent.age = age;
newAgent.gender = gender;
end