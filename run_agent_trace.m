function output = run_agent_trace()
% run_agent_trace  --  single local run producing the agent life-history
%
% Writes two linked CSVs to ./Outputs/ :
%
%   agent_life_history.csv   one row per traced agent-quarter
%   agent_choices.csv        one row per CANDIDATE portfolio evaluated
%
% They join on (agentID, t).
%
% PURPOSE
% To answer "is the model behaving sensibly?" using domain knowledge rather
% than code knowledge. The life history reads as a narrative -- an agent's
% forty years of location, livelihood, income, food costs, buffer and
% decisions -- so someone who knows the Grand Sud can judge it directly.
% The choice file exposes what the agent was comparing against at each
% decision, which is where the behavioural logic actually lives.
%
% Two things to check first, before reading any narrative:
%
%   1. RESIDUAL COLUMNS. wealth_resid and income_resid must be zero to
%      machine precision. Sort by abs(residual) descending; anything
%      non-zero is an accounting bug, no judgement required.
%
%   2. creditBlocked in agent_choices.csv. An agent who never moves because
%      every alternative was unaffordable is a completely different story
%      from one who stays because home is genuinely best, and no other
%      output distinguishes them.
%
% Configuration matches run_buffer_trace.m so results are comparable.
%
% Usage:
%   cd <MIDAS project root>
%   output = run_agent_trace;

addpath('./Core_MIDAS_Code');
addpath('./Application_Specific_MIDAS_Code');

if ~exist('./Outputs', 'dir'); mkdir('./Outputs'); end

rng(1);   % deterministic, so reruns are comparable while iterating

names = { ...
    'modelParameters.bufferEnabled';               ...
    'modelParameters.distressMigrationEnabled';    ...
    'modelParameters.distressTriggerCode';         ... % 6 = solvency
    'modelParameters.numAgents';                   ...
    'modelParameters.droughtScaleFactor';          ...
    'agentParameters.subsistence_costs';           ...
    'modelParameters.livelihoodAttachmentEnabled'; ...
    'modelParameters.livelihoodAttachmentScale';   ...
    'modelParameters.traceAgentLife';              ... % <- this diagnostic
    'modelParameters.traceLifeMaxAgents';          ...
    'mapParameters.movingCostPerMile';             ... % see note below
    'agentParameters.incomeShareFractionMean';     ... % 0 = remittances off
    'agentParameters.incomeShareFractionSD';       ... % must also be 0
    };

% NOTE on movingCostPerMile. Despite the name this is NOT a per-mile rate:
% createMovingCosts.m multiplies it by a beta(5,2) CDF over the
% minDistForCost..maxDistForCost band, so it is the MAXIMUM distance cost,
% approached asymptotically.
%
% CORRECTION 2026-08-09. An earlier version of this note blamed the
% readParameters default of 0 for migration being free. That was wrong, and
% setting this to 20 did NOT fix it: the 2026-08-09 trace still showed
% movingCost = 0 on all 5,440 away-from-home candidates. The real cause was
% in createMapFromSHP.m, where a bare load() of the cached map dropped a
% saved mapParameters struct over the live one, discarding every map
% parameter override and MC draw. Fixed there. Until that fix, migration was
% free in every run of this model, which is the likeliest explanation for
% agents relocating ~2.3 times a year.
%
% Now that the value reaches the model, note the SHAPE of the friction.
% Over the default 50-400 mile band, beta(5,2) is steeply convex: at
% movingCostPerMile = 20 a 100-mile move costs 0.01, 200 miles costs 1.12,
% and only beyond ~300 miles (9.03) does it approach annual income of
% 10-25. Short hops between neighbouring regions stay essentially free, so
% if churn persists after the fix, the BAND rather than the level is the
% thing to change.
% movingCostPerMile = 8 sits mid-range of the revised MC design (2-15).
values = [ 1; 1; 6; 1500; 0.30; 1.75; 1; 0.5; 1; 10; 8; 0; 0 ];

inputs = table(names, values, 'VariableNames', {'parameterNames','parameterValues'});

fprintf('Running agent life-history trace (single local run, ~a few minutes)...\n');
output = midasMainLoop(inputs, 'agent_trace');

save('./Outputs/agent_trace.mat', 'output');
fprintf('\nSaved results to ./Outputs/agent_trace.mat\n');

% ----- Immediate reconciliation check -------------------------------------
% Report the residuals here rather than leaving it to the analyst, so a
% broken run is obvious before anyone starts reading narrative.
f = './Outputs/agent_life_history.csv';
if exist(f, 'file')
    T = readtable(f);
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
else
    warning('run_agent_trace:noTrace', ...
        'No agent_life_history.csv produced. Check that traceAgentLife took effect.');
end
end
