function output = run_agent_trace(varargin)
% run_agent_trace  --  single local run producing the agent life-history
%
%   run_agent_trace                              % midpoint of the calibrated bounds
%   run_agent_trace('Mode','draw','Seed',7)      % one random draw from them
%   run_agent_trace('NumAgents',1500)            % smaller run, faster, see caveat
%
% Writes two linked CSVs to ./Outputs/ :
%
%   agent_life_history.csv   one row per traced agent-quarter
%   agent_choices.csv        one row per CANDIDATE portfolio evaluated
%
% They join on (agentID, t). Feed the first to wealth_decomposition.
%
% PURPOSE
% To answer "is the model behaving sensibly?" using domain knowledge rather
% than code knowledge. The life history reads as a narrative -- an agent's
% location, livelihood, income, food costs, buffer and decisions -- so someone
% who knows the Grand Sud can judge it directly. The choice file exposes what
% the agent was comparing against at each decision, which is where the
% behavioural logic actually lives.
%
% PARAMETERS COME FROM updatedMCParams.mat
% This script used to carry its own hard-coded parameter vector. That vector
% drifted: it still held subsistence_costs = 1.75 after the calibration moved
% to 2.0-2.6, and it set incomeShareFractionMean = 0, which switched
% remittances off entirely. A decomposition run on those inputs would have
% reported the transfer channel as zero and understated the subsistence drain,
% and nothing in the output would have said so.
%
% Reading the bounds file instead means the trace describes the configuration
% actually being published, and inherits any change to it automatically. Only
% the parameters that CANNOT come from there are set here, and each is listed
% and justified below.
%
% MIDPOINT, NOT A DRAW, BY DEFAULT
% A diagnostic needs to be reproducible and to sit somewhere interpretable in
% the parameter space, so the default takes the midpoint of every bound.
% Declared-fixed parameters have lower == upper, so they are unaffected either
% way. Use Mode 'draw' to sample one member of the ensemble instead -- useful
% for checking that a finding is not an artefact of the centre.
%
% Midpoints ignore any correlation between parameters, so the resulting vector
% is representative rather than optimal. That is the right trade for tracing
% mechanism; it would be the wrong one for scoring fit.
%
% TWO THINGS TO CHECK FIRST, before reading any narrative:
%
%   1. RESIDUAL COLUMNS. wealth_resid and income_resid must be zero to machine
%      precision. Anything non-zero is an accounting bug, no judgement needed.
%
%   2. creditBlocked in agent_choices.csv. An agent who never moves because
%      every alternative was unaffordable is a completely different story from
%      one who stays because home is genuinely best, and no other output
%      distinguishes them.
%
% HORIZON. Set by readParameters from MIDAS_END_YEAR, default 2025. Running to
% 2085 works, but the traced cohort is registered once at the start and never
% replenished (agentLifeTrace 'register' only fills up to maxAgents), so the
% sample dies out: in a 40-year run, ten agents registered in 1987 were down
% to one by 2027. A projection-horizon trace needs the registration changed
% first, or it returns an almost empty projection period.

p = inputParser;
p.addParameter('Mode', 'midpoint', @(x) any(strcmpi(x, {'midpoint','draw'})));
p.addParameter('Seed', 1, @isnumeric);
p.addParameter('NumAgents', [], @(x) isempty(x) || (isscalar(x) && x > 0));
p.addParameter('MaxTracedAgents', 10, @(x) isscalar(x) && x > 0);
p.addParameter('BoundsPath', '', @(x) ischar(x) || isstring(x));
% SMOKE TEST. A full trace takes hours, almost all of it writing per-agent
% narrative, and an instrumentation fault is only visible once it finishes.
% Smoke mode cuts the POPULATION so the accounting can be validated in
% minutes. Network operations are roughly quadratic in population, so this is
% where nearly all the time goes.
%
% IT DOES NOT SHORTEN THE HORIZON, deliberately. An earlier version set
% endYear to 1993 and crashed in createPortfolio: with endYear below 2023 the
% projection-period Markov block builds a backwards cycle range ("years
% 2023-1992, cycles 39-8"), leaving several arrays degenerate, and
% `aspirations` then arrives at createPortfolio.m:233 as a matrix rather than
% a vector so the && cannot reduce it. Agent count does not change any array
% shape; the horizon changes several. A smoke test that needs its own
% debugging is worse than no smoke test.
%
% This validates the ACCOUNTING only -- both agent loops, the id-indexed
% carriers, births, deaths, moves, access costs and the identity check. The
% sample is far too small to say anything about the model.
p.addParameter('Smoke', false, @islogical);
p.addParameter('SmokeAgents', 1500, @(x) isscalar(x) && x > 0);
% Timesteps between life-trace checkpoints. The trace is now written to disk
% periodically rather than only at the end, so the accounting can be validated
% on a partial file minutes into a run that takes hours. 0 disables.
p.addParameter('FlushEvery', 8, @(x) isscalar(x) && x >= 0);
p.parse(varargin{:});
opt = p.Results;

if opt.Smoke && isempty(opt.NumAgents)
    opt.NumAgents = opt.SmokeAgents;
end
if opt.Smoke
    fprintf(['[SMOKE] %d agents, full horizon. Validates the ACCOUNTING only --\n' ...
             '        the sample is too small to say anything about the model.\n'], ...
            opt.NumAgents);
end

addpath('./Core_MIDAS_Code');
addpath('./Application_Specific_MIDAS_Code');
if ~exist('./Outputs', 'dir'); mkdir('./Outputs'); end

rng(opt.Seed);   % deterministic, so reruns are comparable while iterating

% ---------------------------------------------------------------- bounds
% Same search order as runMIDASExperiment_parallel, so the trace cannot end up
% describing a different bounds file from the campaign.
if isempty(opt.BoundsPath)
    candidates = { fullfile('Calibration Testing', 'updatedMCParams.mat'), ...
                   'updatedMCParams.mat' };
    boundsPath = '';
    for k = 1:numel(candidates)
        if exist(candidates{k}, 'file') == 2; boundsPath = candidates{k}; break; end
    end
    if isempty(boundsPath)
        error('run_agent_trace:noBounds', ...
              ['No updatedMCParams.mat found in: %s\nThe trace now takes its ' ...
               'parameters from the calibrated bounds rather than carrying its ' ...
               'own copy. Run from the MIDAS project root.'], ...
              strjoin(candidates, ' | '));
    end
else
    boundsPath = char(opt.BoundsPath);
end
L = load(boundsPath);
if ~isfield(L, 'mcParams')
    error('run_agent_trace:noVar', '%s has no mcParams variable.', boundsPath);
end
mcParams = L.mcParams;
fprintf('Parameters from %s (%d entries), mode "%s".\n', ...
        boundsPath, height(mcParams), lower(opt.Mode));

% ---------------------------------------------------------------- resolve
names  = mcParams.Name;
values = nan(height(mcParams), 1);
useMid = strcmpi(opt.Mode, 'midpoint');
for k = 1:height(mcParams)
    lo = mcParams.Lower(k); hi = mcParams.Upper(k);
    if useMid
        values(k) = (lo + hi) / 2;
    else
        values(k) = lo + (hi - lo) * rand();
    end
    if mcParams.RoundYN(k); values(k) = round(values(k)); end
end

% ------------------------------------------------- expectation arm
% updatedMCParams.mat carries expectationArm = 0, because every calibration
% round to date was run that way. The CAMPAIGN does not use that value:
% run_calibration.m reads the readParameters default (arm 4) and hard-errors
% if the arm ever resolves to 0 without being asked for explicitly, because
% under arm 0 agents sample their whole history uniformly and are close to
% blind to recent drought.
%
% Taking the bounds value here would make the trace describe a different model
% from the one being published -- and the difference is precisely the drought
% responsiveness the wealth trajectory is being interrogated for. Mirror
% run_calibration instead.
mpDefaults = [];
try
    [~, mpDefaults] = readParameters([]);
catch err
    warning('run_agent_trace:noDefaults', ...
            ['Could not read the readParameters defaults (%s). Falling back to ' ...
             'the bounds-file expectationArm, which is probably 0 -- check the ' ...
             '"readParameters: expectationArm" line below before trusting the ' ...
             'trace.'], err.message);
end
if ~isempty(mpDefaults) && isfield(mpDefaults, 'expectationArm')
    iArm = find(strcmp(names, 'modelParameters.expectationArm'), 1);
    defaultArm = mpDefaults.expectationArm;
    if isempty(iArm)
        names(end+1)  = {'modelParameters.expectationArm'}; %#ok<AGROW>
        values(end+1) = defaultArm;                         %#ok<AGROW>
        fprintf('[Arm] expectationArm set to the readParameters default, %d.\n', ...
                defaultArm);
    elseif values(iArm) ~= defaultArm
        fprintf(['[Arm] expectationArm %g from the bounds file OVERRIDDEN with the\n' ...
                 '      readParameters default %d, matching the campaign.\n'], ...
                values(iArm), defaultArm);
        values(iArm) = defaultArm;
    end
    if defaultArm == 0
        error('run_agent_trace:armZero', ...
              ['expectationArm resolved to 0. Agents then sample their whole ' ...
               'history uniformly and are nearly blind to recent drought, so a ' ...
               'trace run this way says little about the drought response.\n' ...
               'Check readParameters.m -- the intended default is 4.']);
    end
end

% ------------------------------------------------- trace-only parameters
% These are not calibration targets and are absent from the bounds file by
% design, so they are the only values this script sets itself.
%
%   traceAgentLife      switches the diagnostic on. Off in every production
%                       run: agentLifeTrace keeps persistent state and is
%                       single-threaded, so it must never enter the parfor
%                       campaign.
%   traceLifeMaxAgents  size of the traced cohort. Ten keeps the CSV readable
%                       as a narrative; the decomposition is an accounting
%                       identity and holds for any sample size.
traceOnly = { 'modelParameters.traceAgentLife',     1; ...
              'modelParameters.traceLifeMaxAgents', opt.MaxTracedAgents; ...
              'modelParameters.traceFlushEvery',    opt.FlushEvery };
for k = 1:size(traceOnly, 1)
    iX = find(strcmp(names, traceOnly{k,1}), 1);
    if isempty(iX)
        names(end+1)  = traceOnly(k,1); %#ok<AGROW>
        values(end+1) = traceOnly{k,2}; %#ok<AGROW>
    else
        values(iX) = traceOnly{k,2};
    end
end

% ------------------------------------------------- optional agent-count cap
% Network operations are effectively quadratic in population, so the
% calibrated 3082-5848 makes a local trace slow. Capping is legitimate for
% reading mechanism but it is NOT the published configuration: fewer agents
% means sparser networks, which changes remittance flows and therefore the
% wealth trajectory being diagnosed. Announced loudly rather than defaulted,
% because a quiet cap here would make the trace disagree with the campaign for
% a reason nobody could see in the output.
if ~isempty(opt.NumAgents)
    iN = find(strcmp(names, 'modelParameters.numAgents'), 1);
    if ~isempty(iN)
        fprintf(2, ['[CAP] numAgents %d -> %d for runtime. Networks will be ' ...
                    'sparser than the\n      calibrated configuration, so ' ...
                    'remittance flows and the wealth path\n      will differ ' ...
                    'from the campaign. Diagnostic only.\n'], ...
                round(values(iN)), round(opt.NumAgents));
        values(iN) = round(opt.NumAgents);
    end
end

% ---------------------------------------------------------------- report
% Print the values that drive the wealth decomposition, so the trace output is
% self-describing and cannot be mistaken for a different configuration.
fprintf('\n=== Parameters driving the wealth accounting ===\n');
show = { 'modelParameters.numAgents', ...
         'modelParameters.expectationArm', ...
         'agentParameters.subsistence_costs', ...
         'agentParameters.incomeShareFractionMean', ...
         'agentParameters.incomeShareFractionSD', ...
         'modelParameters.distressShortfallFrac', ...
         'modelParameters.droughtScaleFactor', ...
         'modelParameters.distressTriggerCode', ...
         'modelParameters.bufferEnabled', ...
         'mapParameters.movingCostPerMile' };
for k = 1:numel(show)
    iS = find(strcmp(names, show{k}), 1);
    if isempty(iS)
        fprintf('  %-44s NOT IN BOUNDS (model default applies)\n', show{k});
    else
        fprintf('  %-44s %g\n', show{k}, values(iS));
    end
end

% NOTE on movingCostPerMile. Despite the name this is NOT a per-mile rate:
% createMovingCosts.m multiplies it by a beta(5,2) CDF over the
% minDistForCost..maxDistForCost band, so it is the MAXIMUM distance cost,
% approached asymptotically. Over the default band beta(5,2) is steeply
% convex, so short hops between neighbouring regions stay nearly free and only
% moves beyond roughly 300 miles approach annual income. If churn persists,
% the BAND rather than the level is the thing to change.
%
% The value only reaches the model at all since the 2026-08-09 fix to
% createMapFromSHP.m, where a bare load() of the cached map dropped the live
% mapParameters struct and discarded every map override and MC draw.

inputs = table(names, values, 'VariableNames', {'parameterNames','parameterValues'});

fprintf('\nRunning agent life-history trace (single local run)...\n');
output = midasMainLoop(inputs, 'agent_trace');

save('./Outputs/agent_trace.mat', 'output');
fprintf('\nSaved results to ./Outputs/agent_trace.mat\n');

% ----- Immediate reconciliation check -------------------------------------
% Report the residuals here rather than leaving it to the analyst, so a broken
% run is obvious before anyone starts reading narrative.
f = './Outputs/agent_life_history.csv';
if exist(f, 'file')
    if exist('readSummaryCsv', 'file') == 2
        T = readSummaryCsv(f);
    else
        T = readtable(f, 'Delimiter', ',', 'ReadVariableNames', true, ...
                         'VariableNamingRule', 'preserve');
    end
    fprintf('\n=== RECONCILIATION CHECK ===\n');
    fprintf('  rows: %d   agents: %d   years: %d-%d\n', ...
        height(T), numel(unique(T.agentID)), min(T.year), max(T.year));
    for fld = ["wealth_resid", "income_resid"]
        if ismember(fld, string(T.Properties.VariableNames))
            v = abs(T.(char(fld)));
            v = v(~isnan(v));
            nBad = sum(v > 1e-9);
            if nBad == 0
                fprintf('  %-14s OK   (max |residual| = %.3g)\n', fld, max([v; 0]));
            else
                fprintf(2, '  %-14s %d of %d rows non-zero, max |residual| = %.6g\n', ...
                    fld, nBad, numel(v), max(v));
                fprintf(2, '     -> accounting error. Sort the CSV by this column.\n');
            end
        end
    end
    fprintf('\nNext: wealth_decomposition(''./Outputs'')\n');
else
    warning('run_agent_trace:noTrace', ...
        'No agent_life_history.csv produced. Check that traceAgentLife took effect.');
end
end
