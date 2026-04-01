%% analyse_madagascar_output.m
% Interrogate MIDAS output for the Madagascar model.
%
% USAGE:
%   Run this script from the MIDAS-Madagascar root directory, or from the
%   Outputs/ folder. It will auto-detect the most recent Madagascar .mat
%   file and load it.
%
% OUTPUT STRUCT FIELDS (output.XXX):
%   averageWealth       [timeSteps x 1]          Mean agent wealth each quarter
%   countAgentsPerLayer [nLocs x nLayers x T]     Agents in each layer per location per quarter
%   utilityHistory      [nLocs x nLayers x T]     Density-adjusted utility per layer per location
%   inMigrations        [nLocs x T]               In-migration counts per location
%   outMigrations       [nLocs x T]               Out-migration counts per location
%   migrationMatrix     [nLocs x nLocs x T]       Origin-destination migration flows
%   trappedHistory      [nAgents x T]             Whether each agent was trapped
%   aspirationHistory   [? x T]                   Aspiration layer indices
%   locations           table                      Location metadata (NAME_2, matrixID, etc.)
%   agentSummary        table                      Final per-agent state
% -------------------------------------------------------------------------

clear; clc;

%% 1. Load the most recent Madagascar .mat file
% ------------------------------------------------------------------
outputDir = './Outputs/';   % adjust if running from a different folder
files = dir(fullfile(outputDir, 'test_series*.mat'));
if isempty(files)
    error('No test_series*.mat files found in %s', outputDir);
end
[~, idx] = max([files.datenum]);
fname = fullfile(outputDir, files(idx).name);
fprintf('Loading: %s\n', fname);
load(fname, 'input', 'output');

%% 2. Model configuration
% ------------------------------------------------------------------
% These must match readParameters.m
startYear   = 1985;
cycleLength = 4;      % quarters per year
spinupTime  = 10;     % spinup in CYCLES (not quarters)
spinupSteps = spinupTime * cycleLength;   % = 40 quarters

% Layer names — must match the ORDER in utility_layers_v1.csv
layerNames = {'unskilled1','unskilled2','skilled','school', ...
              'rice\_north','rice\_south','maize','cassava', ...
              'vanilla','industrial\_crop'};
nLayers = length(layerNames);

% Time axis: each time step = 1 quarter
T = size(output.countAgentsPerLayer, 3);
quarterAxis = (0:T-1) / cycleLength;           % years elapsed from startYear
yearAxis    = startYear + quarterAxis;          % calendar year

% Post-spinup indices (spinup period = first spinupSteps quarters)
postSpinup = spinupSteps+1 : T;

% Location names
if ismember('source_NAME_2', output.locations.Properties.VariableNames)
    locNames = string(output.locations.source_NAME_2);
elseif ismember('source_ADM2_FR', output.locations.Properties.VariableNames)
    locNames = string(output.locations.source_ADM2_FR);
else
    locNames = string((1:size(output.countAgentsPerLayer,1))');
end
nLocs = length(locNames);
numAgents = height(output.agentSummary);

fprintf('Run loaded: %d locations, %d layers, %d time steps (%d years), %d agents\n', ...
    nLocs, nLayers, T, T/cycleLength, numAgents);

%% 3. PLOT 1 — Agents per layer over time (national total, % of population)
% ------------------------------------------------------------------
% Collapse across all locations
agentsPerLayer = squeeze(sum(output.countAgentsPerLayer, 1)) / numAgents * 100;
% agentsPerLayer is now [nLayers x T]

figure('Name','Agents per Layer (National)', 'NumberTitle','off');
hold on;
cm = lines(nLayers);
for iL = 1:nLayers
    plot(yearAxis(postSpinup), agentsPerLayer(iL, postSpinup), ...
        'Color', cm(iL,:), 'LineWidth', 1.5, 'DisplayName', layerNames{iL});
end
xline(startYear + spinupTime, '--k', 'Spinup end', 'LabelHorizontalAlignment','right');
hold off;
xlabel('Year'); ylabel('% of agents');
title('Share of agents in each livelihood layer (national)');
legend('Location','eastoutside','Interpreter','none');
grid on;

%% 4. PLOT 2 — Layer occupancy at terminal time (bar chart)
% ------------------------------------------------------------------
terminalAgents = agentsPerLayer(:, end);

figure('Name','Terminal Layer Distribution', 'NumberTitle','off');
bar(terminalAgents);
set(gca, 'XTick', 1:nLayers, 'XTickLabel', layerNames, 'XTickLabelRotation', 40);
ylabel('% of agents');
title(sprintf('Layer distribution at end of run (%d)', round(yearAxis(end))));
grid on;

%% 5. PLOT 3 — Migration rates over time
% ------------------------------------------------------------------
% Total in- and out-migrations per quarter, as % of population
totalIn  = sum(output.inMigrations,  1) / numAgents * 100;   % [1 x T]
totalOut = sum(output.outMigrations, 1) / numAgents * 100;   % [1 x T]

figure('Name','Migration Rates', 'NumberTitle','off');
hold on;
plot(yearAxis(postSpinup), totalIn(postSpinup),  'b-', 'LineWidth',1.5, 'DisplayName','In-migration');
plot(yearAxis(postSpinup), totalOut(postSpinup), 'r-', 'LineWidth',1.5, 'DisplayName','Out-migration');
hold off;
xlabel('Year'); ylabel('% of agents migrating per quarter');
title('National migration rates over time');
legend; grid on;

%% 6. PLOT 4 — Average agent wealth over time
% ------------------------------------------------------------------
figure('Name','Average Wealth', 'NumberTitle','off');
plot(yearAxis(postSpinup), output.averageWealth(postSpinup), 'k-', 'LineWidth',1.5);
xlabel('Year'); ylabel('Mean wealth (model units)');
title('Average agent wealth over time');
grid on;

%% 7. PLOT 5 — Total population (agents) per region at terminal time
% ------------------------------------------------------------------
terminalPop = sum(output.countAgentsPerLayer(:, :, end), 2);  % sum across layers

figure('Name','Terminal Regional Population', 'NumberTitle','off');
barh(terminalPop);
set(gca, 'YTick', 1:nLocs, 'YTickLabel', locNames);
xlabel('Number of agents'); title(sprintf('Agents per region at end of run (%d)', round(yearAxis(end))));
grid on;

%% 8. PLOT 6 — Utility (income) history for a selected layer, all regions
% ------------------------------------------------------------------
% Change layerOfInterest to examine different layers (use the index from layerNames)
layerOfInterest = 5;   % 5 = rice_north. Change as needed.

utilSlice = squeeze(output.utilityHistory(:, layerOfInterest, postSpinup));
% [nLocs x postSpinupSteps]

figure('Name', sprintf('Utility: %s', layerNames{layerOfInterest}), 'NumberTitle','off');
imagesc(yearAxis(postSpinup), 1:nLocs, utilSlice);
colorbar; colormap(parula);
set(gca, 'YTick', 1:nLocs, 'YTickLabel', locNames);
xlabel('Year');
title(sprintf('Utility (density-adjusted income) — %s — all regions', layerNames{layerOfInterest}));

%% 9. SUMMARY TABLE — Final agent state
% ------------------------------------------------------------------
% agentSummary is a table with one row per agent, columns:
%   id, wealth, location, pInteract, pChoose, trapped, wealthHistory,
%   portfolioHistory, aspirationHistory, moveHistory, training, experience, ...
%
% Quick summary:
fprintf('\n--- AGENT SUMMARY (final state) ---\n');
fprintf('Total agents:        %d\n', numAgents);
fprintf('Mean final wealth:   %.2f\n', mean(output.agentSummary.wealth, 'omitnan'));
fprintf('Median final wealth: %.2f\n', median(output.agentSummary.wealth, 'omitnan'));
fprintf('Trapped agents:      %d (%.1f%%)\n', ...
    sum(output.agentSummary.trapped), ...
    sum(output.agentSummary.trapped)/numAgents*100);

% Layer counts from agentSummary.currentPortfolio
% Each cell contains a logical or index vector of layers the agent is in
fprintf('\n--- FINAL LAYER COUNTS (from agentSummary) ---\n');
finalLayerCount = zeros(nLayers,1);
for iA = 1:numAgents
    cp = output.agentSummary.currentPortfolio{iA};
    if ~isempty(cp)
        for iL = 1:length(cp)
            if cp(iL) && cp(iL) <= nLayers
                finalLayerCount(cp(iL)) = finalLayerCount(cp(iL)) + 1;
            end
        end
    end
end
for iL = 1:nLayers
    fprintf('  %-20s %4d agents (%.1f%%)\n', layerNames{iL}, finalLayerCount(iL), finalLayerCount(iL)/numAgents*100);
end

%% 10. HOW TO EXPLORE FURTHER
% ------------------------------------------------------------------
% The workspace now contains:
%
%   output.countAgentsPerLayer(loc, layer, time)  — main spatial-temporal output
%   output.utilityHistory(loc, layer, time)        — realised utility
%   output.inMigrations(loc, time)                 — in-flows per region
%   output.outMigrations(loc, time)                — out-flows per region
%   output.migrationMatrix(orig, dest, time)       — OD matrix
%   output.agentSummary                            — per-agent table
%   output.locations                               — location metadata table
%   locNames                                       — string array of district names
%   layerNames                                     — cell array of layer names
%   yearAxis                                       — [1 x T] calendar years
%
% Example: plot rice_north occupancy for Sava region only
%   savaIdx = find(locNames == "Sava");
%   figure; plot(yearAxis, squeeze(output.countAgentsPerLayer(savaIdx, 5, :)));
%
% Example: get migration matrix at a specific year
%   yr = 2030; tStep = (yr - startYear) * cycleLength + 1;
%   mm = output.migrationMatrix(:,:, tStep);
%
% Example: inspect one agent's portfolio history
%   output.agentSummary.portfolioHistory{42}
%
% Example: check average wealth of agents currently in vanilla layer
%   vanillaAgents = cellfun(@(p) any(p == 9), output.agentSummary.currentPortfolio);
%   mean(output.agentSummary.wealth(vanillaAgents))
