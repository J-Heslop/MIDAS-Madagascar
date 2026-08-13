function output = run_buffer_trace()
% run_buffer_trace  --  single local run that logs per-agent buffer mechanics
%
% Runs ONE short MIDAS simulation over the calibration period (1985-2025, so
% the 2016-2018 kere cascade is included) with the livestock buffer and
% Variant F enabled, and the buffer agent-trace switched on. For a small
% sample of southern agents it logs the year-end buffer update step by step:
%
%   buf_start -> after_mortality -> after_growth -> (drawdown | accrual) -> buf_end
%
% alongside the local drought state (agYF), wealth before/after, annual ag
% income, and whether the farm-entry endowment has been granted. Output goes
% to Outputs/buffer_trace.csv (open in Excel / read with the Julia snippet in
% the chat) so we can eyeball whether the mechanics behave as designed --
% something 200-run composites hide.
%
% Usage:
%   cd <MIDAS project root>
%   output = run_buffer_trace;
%
% Edit the overrides below to change agent count, drought strength, etc.

addpath('./Core_MIDAS_Code');
addpath('./Application_Specific_MIDAS_Code');

if ~exist('./Outputs', 'dir'); mkdir('./Outputs'); end

% Deterministic so re-runs are comparable while iterating.
rng(1);

% Scalar parameter overrides (readParameters applies these via eval; it only
% handles scalars, so the string/vector trace params - traceRegions,
% traceBufferFile - come from their readParameters.m defaults).
names = { ...
    'modelParameters.bufferEnabled';            ... % buffer on
    'modelParameters.distressMigrationEnabled'; ... % overlay on
    'modelParameters.distressTriggerCode';      ... % Variant F
    'modelParameters.traceBuffer';              ... % logging on
    'modelParameters.numAgents';                ... % modest for a fast local run
    'modelParameters.droughtScaleFactor';       ... % strong-ish so drought is visible in the trace
    'modelParameters.traceMaxAgents';           ... % how many southern ag agents to follow
    'agentParameters.subsistence_costs';        ... % SEE NOTE below
    'modelParameters.livelihoodAttachmentEnabled'; ... % attachment on (agents still flip if they drew low attachment ~ U(0,1))
    'modelParameters.livelihoodAttachmentScale';   ... % max fractional NPV penalty at full attachment / zero familiarity
    };
% NOTE on subsistence_costs: the default (0.3/quarter = 1.2/yr) is far below
% agent income (~5-17/yr), so wealth accumulates without bound, no drought
% ever causes a consumption shortfall, and the buffer is never drawn down
% (drawdown = 0 in the first trace). This value must be a large fraction of
% income for shortfalls -- and hence the buffer, FI, and distress triggers --
% to activate at all; in production it comes from calibration (range 0.1-10).
% 1.75/quarter (=7/yr) is a rough guess to make the surplus near zero so we
% can see the buffer bite. Tune it up/down and watch the drawdown column.
values = [ 1; 1; 6; 1; 1500; 0.30; 200; 1.75; 1; 0.5 ];

inputs = table(names, values, 'VariableNames', {'parameterNames', 'parameterValues'});

fprintf('Running buffer trace (this is a single local run, ~a few minutes)...\n');
output = midasMainLoop(inputs, 'buffer_trace');

% Quick console peek at the first traced agent through the cascade years.
if isfield(output, 'bufferTrace') && ~isempty(output.bufferTrace)
    T = array2table(output.bufferTrace, 'VariableNames', output.bufferTraceHeader);
    ids = unique(T.agentID);
    a1  = T(T.agentID == ids(1), :);
    fprintf('\n--- Trace for agent %d (first followed southern farmer) ---\n', ids(1));
    show = a1(a1.year >= 2013 & a1.year <= 2021, ...
              {'year','agYF','buf_start','after_mortality','after_growth', ...
               'gap','drawdown','accrual','buf_end','ag_income'});
    disp(show);
    fprintf('Full trace (%d agents) in Outputs/buffer_trace.csv\n', numel(ids));
else
    warning('No buffer trace produced -- check that bufferEnabled/traceBuffer took effect.');
end

% --- Distress-migration summary: did Variant F fire, and when? ---
% distressMigrations is nLoc x timeSteps (subset of outMigrations tagged as
% overlay-triggered in midasMainLoop). Aggregate to calendar years using the
% same timestep->year mapping as agYFYearIndex (spinup clamped to year 1).
if isfield(output, 'distressMigrations') && ~isempty(output.distressMigrations)
    dm   = output.distressMigrations;
    cyc  = 4;    % modelParameters.cycleLength default -- keep in sync
    spin = 10;   % modelParameters.spinupTime default  -- keep in sync
    nY   = floor((size(dm, 2) - spin) / cyc);
    southY = zeros(1, nY);
    allY   = zeros(1, nY);
    for iy = 1:nY
        t0 = spin + (iy - 1) * cyc + 1;
        southY(iy) = sum(sum(dm(19:21, t0:t0+cyc-1)));
        allY(iy)   = sum(sum(dm(:,     t0:t0+cyc-1)));
    end
    fprintf('\n--- Distress moves (trigger variant %d) ---\n', values(3));
    fprintf('Total post-spinup: %d nationally, %d from southern regions (19-21)\n', ...
            sum(allY), sum(southY));
    for iy = find(southY > 0)
        fprintf('  year %d : %3d southern distress moves\n', 1984 + iy, southY(iy));
    end
    if sum(allY) == 0
        fprintf(['  NONE fired. Check the income-shock condition (needs %d+ years of\n' ...
                 '  income history + cooldown) and that lastShortfall is being set\n' ...
                 '  at year-end (requires bufferEnabled for Variant F).\n'], 3);
    end
else
    fprintf('No distressMigrations field in output.\n');
end
end
