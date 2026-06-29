function portfolioData = formExpectation(fullHistory, currentT, agent, modelParameters)
%FORMEXPECTATION  Dispatcher for the four expectation-formation arms.
%
%   portfolioData = formExpectation(fullHistory, currentT, agent, modelParameters)
%
%   Constructs the agent's expected per-period income time path of shape
%   [numLayers x agent.numPeriodsEvaluate] from the per-layer income
%   history of the agent's currently-evaluated location. The mechanism
%   that converts past observations into future expectation is selected
%   by modelParameters.expectationArm:
%
%     0 -- BASELINE: original MIDAS behaviour. Random sampling of complete
%          past cycles, uniformly across the entire agent history, stitched
%          end-to-end. Stochastic per evaluation call. No recency weighting.
%
%     1 -- ADAPTIVE EXPECTATIONS (P-1). Weighted mean of past cycles where
%          weights decay exponentially with cycle age (Cagan 1956 textbook
%          form). The deterministic mean cycle is then repeated to fill
%          the evaluation horizon. Each future period gets the weighted-mean
%          income for the corresponding cycle position (e.g., future Q2
%          gets the weighted mean of all past Q2 observations).
%          New parameter: modelParameters.expectationDecayRate (lambda).
%
%     2 -- WINDOWED RANDOM SAMPLING (P-2). Same stochastic stitching logic
%          as baseline, but the sampling pool is restricted to the most
%          recent agent.numPeriodsMemory quarters of history. Activates
%          the previously-dead numPeriodsMemory parameter.
%
%     3 -- NAIVE FORECAST (P-3). The agent assumes the future will look
%          like the most recent complete cycle. The last cycleLength
%          quarters of fullHistory are repeated to fill the evaluation
%          horizon. Deterministic, no new parameters.
%
%     4 -- ADAPTIVE WITH STOCHASTIC SHOCKS (P-4). Combines P-1's
%          recency-weighted deterministic mean with random shocks drawn
%          from the residuals of recent observations within
%          modelParameters.expectationShockWindow quarters. Preserves
%          MIDAS's expectation-variance behaviour but anchors it to
%          recent conditions rather than full-history sampling.
%          New parameters: expectationDecayRate, expectationShockWindow.
%
%   Inputs:
%     fullHistory      [numLayers x currentT] historical income, NaN in
%                      cells the agent hasn't personally observed.
%     currentT         current simulation timestep.
%     agent            agent struct (uses numPeriodsEvaluate and
%                      numPeriodsMemory).
%     modelParameters  uses expectationArm, expectationDecayRate,
%                      expectationShockWindow, cycleLength.
%
%   Output:
%     portfolioData    [numLayers x numPeriodsEvaluate] expected income
%                      time path. Any remaining NaNs are handled by the
%                      blank-fill logic in choosePortfolio.m.

arm = 0;
if isfield(modelParameters, 'expectationArm')
    arm = modelParameters.expectationArm;
end

switch arm
    case 0
        portfolioData = formExpectation_baseline(fullHistory, currentT, agent, modelParameters);
    case 1
        portfolioData = formExpectation_p1(fullHistory, currentT, agent, modelParameters);
    case 2
        portfolioData = formExpectation_p2(fullHistory, currentT, agent, modelParameters);
    case 3
        portfolioData = formExpectation_p3(fullHistory, currentT, agent, modelParameters);
    case 4
        portfolioData = formExpectation_p4(fullHistory, currentT, agent, modelParameters);
    otherwise
        % Unknown arm -- warn once, fall back to baseline.
        persistent warned;
        if isempty(warned)
            warning('formExpectation:unknownArm', ...
                'Unknown expectationArm=%d. Falling back to baseline.', arm);
            warned = true;
        end
        portfolioData = formExpectation_baseline(fullHistory, currentT, agent, modelParameters);
end
end % formExpectation


% =========================================================================
% ARM 0 -- BASELINE: original MIDAS sampling logic
% =========================================================================
function pData = formExpectation_baseline(fullHistory, currentT, agent, modelParameters)
numLayers = size(fullHistory, 1);
cycleLen  = modelParameters.cycleLength;
nEval     = agent.numPeriodsEvaluate;

completeCycles = floor(nEval / cycleLen);
extraPeriods   = mod(nEval, cycleLen);

pData = NaN * ones(numLayers, nEval);

startingPoints = currentT+1:-cycleLen:1;
startingPoints(1) = [];
startingPoints(startingPoints < cycleLen) = [];

if isempty(startingPoints)
    return;
end

startSamples = startingPoints(ceil(rand(completeCycles,1) * length(startingPoints)));
for indexI = 1:completeCycles
    pData(:, (indexI-1)*cycleLen+1:indexI*cycleLen) = ...
        fullHistory(:, startSamples(indexI):startSamples(indexI)+cycleLen-1);
end
if extraPeriods > 0
    endSample = startingPoints(ceil(rand() * length(startingPoints)));
    pData(:, end-extraPeriods+1:end) = fullHistory(:, endSample+1:endSample+extraPeriods);
end
end % formExpectation_baseline


% =========================================================================
% ARM 1 -- ADAPTIVE EXPECTATIONS: exp-decay weighted mean, deterministic
% =========================================================================
function pData = formExpectation_p1(fullHistory, currentT, agent, modelParameters)
numLayers = size(fullHistory, 1);
cycleLen  = modelParameters.cycleLength;
nEval     = agent.numPeriodsEvaluate;
lambda    = modelParameters.expectationDecayRate;

pData = NaN * ones(numLayers, nEval);

nPastCycles = floor(currentT / cycleLen);
if nPastCycles == 0
    return;
end

% Reshape past observations to [numLayers x cycleLen x nPastCycles]
pastCycles = reshape(fullHistory(:, 1:nPastCycles*cycleLen), ...
                     numLayers, cycleLen, nPastCycles);

% Cycle weights: most recent cycle gets weight 1, decaying back.
cycleAges = (nPastCycles-1):-1:0;     % age 0 = most recent
weights   = exp(-lambda * cycleAges); % [1 x nPastCycles]

% Compute weighted mean per (layer, quarter-of-cycle), skipping NaNs.
meanCycle = NaN * ones(numLayers, cycleLen);
for L = 1:numLayers
    for q = 1:cycleLen
        obs = squeeze(pastCycles(L, q, :));   % [nPastCycles x 1]
        validMask = ~isnan(obs);
        if any(validMask)
            w = weights(validMask)';
            meanCycle(L, q) = sum(obs(validMask) .* w) / sum(w);
        end
    end
end

% Fill evaluation horizon by repeating the mean cycle (deterministic).
for q = 1:nEval
    cycleQuarter = mod(q-1, cycleLen) + 1;
    pData(:, q) = meanCycle(:, cycleQuarter);
end
end % formExpectation_p1


% =========================================================================
% ARM 2 -- WINDOWED RANDOM SAMPLING: same as baseline but bounded
% =========================================================================
function pData = formExpectation_p2(fullHistory, currentT, agent, modelParameters)
numLayers = size(fullHistory, 1);
cycleLen  = modelParameters.cycleLength;
nEval     = agent.numPeriodsEvaluate;
windowQ   = agent.numPeriodsMemory;

completeCycles = floor(nEval / cycleLen);
extraPeriods   = mod(nEval, cycleLen);

pData = NaN * ones(numLayers, nEval);

% Bound starting points to the recent window.
earliestT = max(1, currentT - windowQ + 1);
startingPoints = currentT+1:-cycleLen:earliestT;
startingPoints(1) = [];
startingPoints(startingPoints < cycleLen) = [];

% Fallback: if the window is so tight nothing remains, expand to full history.
if isempty(startingPoints)
    startingPoints = currentT+1:-cycleLen:1;
    startingPoints(1) = [];
    startingPoints(startingPoints < cycleLen) = [];
end
if isempty(startingPoints)
    return;
end

startSamples = startingPoints(ceil(rand(completeCycles,1) * length(startingPoints)));
for indexI = 1:completeCycles
    pData(:, (indexI-1)*cycleLen+1:indexI*cycleLen) = ...
        fullHistory(:, startSamples(indexI):startSamples(indexI)+cycleLen-1);
end
if extraPeriods > 0
    endSample = startingPoints(ceil(rand() * length(startingPoints)));
    pData(:, end-extraPeriods+1:end) = fullHistory(:, endSample+1:endSample+extraPeriods);
end
end % formExpectation_p2


% =========================================================================
% ARM 3 -- NAIVE FORECAST: most recent cycle repeated forward
% =========================================================================
function pData = formExpectation_p3(fullHistory, currentT, agent, modelParameters)
numLayers = size(fullHistory, 1);
cycleLen  = modelParameters.cycleLength;
nEval     = agent.numPeriodsEvaluate;

pData = NaN * ones(numLayers, nEval);

lastCycleStart = currentT - cycleLen + 1;
if lastCycleStart < 1
    return;  % not enough history; let blank-fill in choosePortfolio handle it
end

lastCycle = fullHistory(:, lastCycleStart:currentT);   % [numLayers x cycleLen]

for q = 1:nEval
    cycleQuarter = mod(q-1, cycleLen) + 1;
    pData(:, q) = lastCycle(:, cycleQuarter);
end
end % formExpectation_p3


% =========================================================================
% ARM 4 -- ADAPTIVE + STOCHASTIC SHOCKS: weighted mean + sampled residuals
% =========================================================================
function pData = formExpectation_p4(fullHistory, currentT, agent, modelParameters)
numLayers = size(fullHistory, 1);
cycleLen  = modelParameters.cycleLength;
nEval     = agent.numPeriodsEvaluate;
lambda    = modelParameters.expectationDecayRate;
shockQ    = modelParameters.expectationShockWindow;

pData = NaN * ones(numLayers, nEval);

nPastCycles = floor(currentT / cycleLen);
if nPastCycles == 0
    return;
end

% Weighted mean cycle (same computation as P-1).
pastCycles = reshape(fullHistory(:, 1:nPastCycles*cycleLen), ...
                     numLayers, cycleLen, nPastCycles);
cycleAges = (nPastCycles-1):-1:0;
weights   = exp(-lambda * cycleAges);

meanCycle = NaN * ones(numLayers, cycleLen);
for L = 1:numLayers
    for q = 1:cycleLen
        obs = squeeze(pastCycles(L, q, :));
        validMask = ~isnan(obs);
        if any(validMask)
            w = weights(validMask)';
            meanCycle(L, q) = sum(obs(validMask) .* w) / sum(w);
        end
    end
end

% Identify recent cycles for shock draws.
nShockCycles = floor(shockQ / cycleLen);
nShockCycles = min(nShockCycles, nPastCycles);
if nShockCycles < 1
    % Fall back to pure mean (P-1) behaviour.
    for q = 1:nEval
        cycleQuarter = mod(q-1, cycleLen) + 1;
        pData(:, q) = meanCycle(:, cycleQuarter);
    end
    return;
end

recentCycles = pastCycles(:, :, nPastCycles-nShockCycles+1:nPastCycles);
% Residuals: recent - weighted mean.
residuals = recentCycles - repmat(meanCycle, [1 1 nShockCycles]);

% Fill evaluation horizon: weighted mean + random shock from residuals.
for q = 1:nEval
    cycleQuarter = mod(q-1, cycleLen) + 1;
    rndCycle = ceil(rand() * nShockCycles);
    shock = residuals(:, cycleQuarter, rndCycle);
    pData(:, q) = meanCycle(:, cycleQuarter) + shock;
end
end % formExpectation_p4
