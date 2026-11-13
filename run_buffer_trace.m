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

% ===================== POST-RUN DIAGNOSTIC BLOCK =========================
% Three questions this trace exists to answer, printed together so a single
% run settles all of them and the answers are in the console log rather than
% only inside a CSV.

fprintf('\n=========== DIAGNOSTICS ===========\n');

% (1) DEMOGRAPHY. Initial ages were drawn UNIFORMLY on [0 100] until
% 2026-08-26 because the population file carried no age columns, giving a 15+
% share of 0.85 against 0.53 observed for Madagascar in 1985. If the fix is
% live this should read ~0.53 and stay roughly flat; ~0.78 means the old
% uniform draw is still in force.
if isfield(output, 'agentCount_pop') && isfield(output, 'agentCount_all')
    pop = sum(output.agentCount_pop, 1);
    wa  = sum(output.agentCount_all, 1);
    ok  = pop > 0;
    share = wa(ok) ./ pop(ok);
    fprintf('\n1. WORKING-AGE SHARE (target ~0.53 at start; 0.85 = uniform-age bug)\n');
    fprintf('   first year %.4f   mid-run %.4f   last %.4f   min %.4f  max %.4f\n', ...
            share(1), share(round(end/2)), share(end), min(share), max(share));
else
    fprintf('\n1. WORKING-AGE SHARE: agentCount_pop/all not present.\n');
end

% (2) CREDIT-CONSTRAINT SIGN -- QUESTION CLOSED 2026-09-13.
%
% This asked how much of the trapped population was an artefact of the credit
% test's sign: the test blocked a move unless post-move wealth was at least
% +creditMultiplier*collateral (a positive cash RESERVE), while its own comment
% described a borrowing ALLOWANCE, which compares against the negative of the
% same quantity.
%
% Both are gone. The affordability test is now plain liquidity -- a move is
% blocked only if it would leave the agent in debt -- so the threshold is zero,
% the two signs coincide, and no agent can be trapped by the sign alone.
% trappedBySignHistory is emitted as all-zeros by design.
%
% This block is kept because it is the only thing that would flag a MIXED
% analysis: a non-zero value means the output predates the change and its
% trapped series is not comparable with current runs.
if isfield(output, 'trappedBySignHistory') && isfield(output, 'trappedHistory')
    tAll  = sum(output.trappedHistory(:));
    tSign = sum(output.trappedBySignHistory(:));
    fprintf('\n2. CREDIT SIGN (retired -- expect 0)\n');
    if tSign > 0
        fprintf(2, ['   WARNING: trappedBySignHistory = %d over %d trapped ' ...
                    'agent-steps (%.3f).\n'], tSign, tAll, tSign / max(tAll,1));
        fprintf(2, ['   This output PREDATES the 2026-09-13 switch to a plain ' ...
                    'liquidity\n   constraint. Its trapped series is not ' ...
                    'comparable with current runs.\n']);
    elseif tAll > 0
        fprintf('   trapped agent-steps %d, sign-dependent 0 as expected.\n', tAll);
    else
        fprintf('   no trapped agent-steps recorded.\n');
    end
else
    fprintf('\n2. CREDIT SIGN: trappedBySignHistory absent -- is choosePortfolio.m current?\n');
end

% (3) DROUGHT VARIABILITY. createUtilityLayers prints the Markov window
% directly; this restates the switch so both appear in one place.
fprintf('\n3. DROUGHT VARIABILITY: see the "drought Markov variability applied"\n');
fprintf('   line above -- expect "years 2023-%d" for this horizon.\n', ...
        modelParametersUsed_endYear());

% Save the whole output so these can be re-checked without re-running.
save('./Outputs/buffer_trace_output.mat', 'output', 'inputs', '-v7.3');
fprintf('\nFull output saved to Outputs/buffer_trace_output.mat\n');

end

function y = modelParametersUsed_endYear()
% The horizon actually used, read the same way readParameters reads it, so the
% printed expectation matches the run rather than a hard-coded guess.
    y = str2double(getenv('MIDAS_END_YEAR'));
    if isnan(y); y = 2025; end
end
