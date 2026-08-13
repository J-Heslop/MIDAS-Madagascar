function output = run_oracle_test(attachOn)
% run_oracle_test  --  single local run with the ORACLE distress trigger
%
% Runs ONE short MIDAS simulation over the calibration period with the
% distress overlay set to the ORACLE trigger (distressTriggerCode = 7):
% agents are forced to migrate when their location has had TWO consecutive
% years with agYF below oracleAgYFThreshold -- i.e. the trigger conditions
% on the climate forcing itself, bypassing ALL agent state.
%
% Purpose (diagnostic, not production): this is the upper bound on what any
% agent-state trigger (Variants A-F) can achieve. It tests the downstream
% pipeline -- distress-mode choosePortfolio -> migration flows -> detrended
% kere metrics -- in isolation:
%
%   * If even the oracle produces no first-vs-continuation compounding in
%     the detrended metrics, the bottleneck is DOWNSTREAM (background churn
%     dilution, destination congestion, or the metric itself) and no
%     further agent-state engineering can fix it.
%   * If it does, compare Variant F's firing rate/timing against the
%     oracle's to see how much headroom remains.
%
% Compare outputs.distressMigrations (kere vs non-kere years, detrended)
% against a clean baseline run. The oracle fires ONLY in continuation years
% by construction, so the cascade shape is mechanically present at the
% trigger; what survives into the flows is the pipeline's transmission.
%
% CONFIGURATION MATCHING (2026-07-28) -- IMPORTANT
% Until now this script overrode only five parameters, so it inherited the
% readParameters.m defaults for everything else. Three of those defaults
% differ from what run_buffer_trace.m sets, which meant the oracle ran in a
% materially different economy from the trigger diagnostics it is supposed
% to bound:
%
%   livelihoodAttachmentEnabled   default FALSE   vs buffer trace TRUE
%   subsistence_costs             default 0.30    vs buffer trace 1.75
%   bufferEnabled                 default FALSE   vs buffer trace TRUE
%
% The attachment default mattered most: the ceiling this script measures is
% set by background migration churn, and attachment is the mechanism that
% suppresses that churn. Measuring the ceiling with it disabled understates
% the ceiling. subsistence_costs at the 0.30 default also lets agents
% accumulate wealth without bound, which changes migration behaviour
% throughout. All three are now set explicitly below.
%
% Usage:
%   cd <MIDAS project root>
%   output = run_oracle_test;          % attachment ON  (matches buffer trace)
%   output = run_oracle_test(false);   % attachment OFF (churn upper bound)
%
% Run BOTH. The gap between the two cascade ratios separates how much of the
% ceiling is churn dilution from how much is structural -- and evidences
% whether the livelihood-attachment work is doing its job.
%
% Each run saves to Outputs/oracle_test.mat (attachment on) or
% Outputs/oracle_test_noattach.mat (off), with the struct named `output` so
% trigger_budget.jl picks it up without further handling.

if nargin < 1 || isempty(attachOn)
    attachOn = true;    % default: match run_buffer_trace.m
end

addpath('./Core_MIDAS_Code');
addpath('./Application_Specific_MIDAS_Code');

if ~exist('./Outputs', 'dir'); mkdir('./Outputs'); end

% Deterministic so re-runs are comparable while iterating.
rng(1);

names = { ...
    'modelParameters.distressMigrationEnabled'; ... % overlay on
    'modelParameters.distressTriggerCode';      ... % 7 = ORACLE
    'modelParameters.oracleAgYFThreshold';      ... % agYF below this = drought year
    'modelParameters.numAgents';                ... % modest for a fast local run
    'modelParameters.droughtScaleFactor';       ... % strong-ish so droughts register in agYF
    'modelParameters.bufferEnabled';            ... % MATCH run_buffer_trace.m (default false)
    'agentParameters.subsistence_costs';        ... % MATCH run_buffer_trace.m (default 0.30)
    'modelParameters.livelihoodAttachmentEnabled'; ... % MATCH run_buffer_trace.m (default false)
    'modelParameters.livelihoodAttachmentScale';   ... % max fractional NPV penalty
    };
values = [ 1; 7; 0.8; 1500; 0.30; 1; 1.75; double(attachOn); 0.5 ];

inputs = table(names, values, 'VariableNames', {'parameterNames', 'parameterValues'});

if attachOn
    outFile = './Outputs/oracle_test.mat';
else
    outFile = './Outputs/oracle_test_noattach.mat';
end

if attachOn; attachLabel = 'ON'; else; attachLabel = 'OFF'; end

fprintf('Running oracle-trigger test (single local run, ~a few minutes)...\n');
fprintf('  livelihood attachment: %s   |   subsistence_costs: 1.75   |   buffer: on\n', ...
        attachLabel);
output = midasMainLoop(inputs, 'oracle_test');

% Save so the Julia diagnostics can read it. Named `output` deliberately --
% running this without assigning leaves the struct in `ans`, and saving that
% writes a top-level variable of the wrong name.
save(outFile, 'output');
fprintf('\nSaved results to %s\n', outFile);

% Quick console peek: distress moves per year, southern regions (19-21).
if isfield(output, 'distressMigrations')
    dm   = output.distressMigrations;   % nLoc x timeSteps
    cyc  = 4;    % modelParameters.cycleLength default -- keep in sync
    spin = 10;   % modelParameters.spinupTime default  -- keep in sync
    % Timestep -> calendar year using the same spinup-aware mapping as
    % agYFYearIndex (BUGFIX 2026-07-14: the first version omitted the
    % spinup offset, so printed years ran ~2.5 years late).
    nYears = floor((size(dm, 2) - spin) / cyc);
    annual = zeros(1, nYears);
    for iy = 1:nYears
        t0 = spin + (iy - 1) * cyc + 1;
        annual(iy) = sum(sum(dm(19:21, t0:t0+cyc-1)));
    end
    fprintf('\nSouthern distress moves per year (oracle should fire ONLY in continuation drought years):\n');
    for iy = 1:nYears
        if annual(iy) > 0
            fprintf('  year %d : %d\n', 1984 + iy, annual(iy));
        end
    end
    if all(annual == 0)
        warning(['Oracle never fired. Check droughtScaleFactor / oracleAgYFThreshold ' ...
                 '(agYF may never drop below threshold two years running at this alpha).']);
    end
else
    warning('No distressMigrations output found.');
end
end
