%% plot_layers.m
% Plots the number of agents in each utility layer throughout the MIDAS run.
%
% USAGE:
%   Run from the MIDAS-Madagascar root directory. Auto-loads the most
%   recent test_series*.mat output file.
%
% PLOTS PRODUCED:
%   1. Line plot  — agents per layer (national total) over time
%   2. Stacked area — share of agents per layer over time
%   3. Bar chart  — layer distribution at start, midpoint, and end
%   4. Heatmap    — agents per layer per region at terminal time
%
% NOTE ON COUNTING:
%   countAgentsPerLayer(loc, layer, t) increments once per layer an agent
%   holds. Agents with multi-layer portfolios are counted once per layer.
%   The total across all layers therefore exceeds the number of living
%   agents when agents hold more than one layer. The plots show absolute
%   counts per layer (not proportions of population) to avoid this ambiguity.
%
% -------------------------------------------------------------------------

clear; clc;

%% 1. Load output file
outputDir = './Outputs/';
files = dir(fullfile(outputDir, 'test_series*.mat'));
if isempty(files)
    error('No test_series*.mat files found in %s', outputDir);
end
[~, idx] = max([files.datenum]);
fname = fullfile(outputDir, files(idx).name);
fprintf('Loading: %s\n', fname);
load(fname, 'input', 'output');

%% 2. Configuration — match readParameters.m and utility_layers_v1.csv
startYear   = 1985;
cycleLength = 4;     % quarters per year
spinupTime  = 10;    % spinup in QUARTERS (= 2.5 years) — readParameters.m comment confirms this
spinupSteps = spinupTime;  % already in quarters; do NOT multiply by cycleLength

% Layer names — ORDER must match utility_layers_v1.csv
layerNames = { ...
    'Unskilled 1', ...
    'Unskilled 2', ...
    'Skilled', ...
    'School', ...
    'Rice (North)', ...
    'Rice (South)', ...
    'Maize', ...
    'Cassava', ...
    'Vanilla', ...
    'Industrial Crop' };

nLayers = size(output.countAgentsPerLayer, 2);
if nLayers ~= length(layerNames)
    warning('Layer count in output (%d) differs from layerNames list (%d). Updating labels.', ...
        nLayers, length(layerNames));
    layerNames = arrayfun(@(i) sprintf('Layer %d', i), 1:nLayers, 'UniformOutput', false);
end

% Location labels
if ismember('source_NAME_2', output.locations.Properties.VariableNames)
    locNames = string(output.locations.source_NAME_2);
elseif ismember('source_ADM2_FR', output.locations.Properties.VariableNames)
    locNames = string(output.locations.source_ADM2_FR);
else
    nLocs = size(output.countAgentsPerLayer, 1);
    locNames = string((1:nLocs)');
end
nLocs = length(locNames);

T          = size(output.countAgentsPerLayer, 3);
yearAxis   = startYear + (0:T-1) / cycleLength;
postSpinup = spinupSteps+1 : T;

numAgents = height(output.agentSummary);
fprintf('Loaded: %d locations, %d layers, %d time steps, %d initial agents\n', ...
    nLocs, nLayers, T, input.agentParameters.numAgents);

%% 3. Collapse across locations → national totals per layer per timestep
% Shape: [nLayers x T]
nationalPerLayer = squeeze(sum(output.countAgentsPerLayer, 1));  % sum over locations

%% 4. PLOT 1 — Line plot: agents per layer over time
cm = lines(nLayers);

fig1 = figure('Name','Agents per Layer (lines)','NumberTitle','off', ...
              'Position',[100 100 950 500]);
hold on;
for iL = 1:nLayers
    plot(yearAxis(postSpinup), nationalPerLayer(iL, postSpinup), ...
        'Color', cm(iL,:), 'LineWidth', 1.8, 'DisplayName', layerNames{iL});
end
xline(startYear + spinupTime, '--k', 'Label','Spinup end', ...
      'LabelHorizontalAlignment','right', 'HandleVisibility','off');
hold off;
xlabel('Year');
ylabel('Number of agents (layer-occupancy count)');
title('Agents per livelihood layer — national total');
legend('Location','eastoutside', 'Interpreter','none');
grid on;
xlim([yearAxis(postSpinup(1)) yearAxis(end)]);

savePath1 = './Plotting/layers_lines.png';
exportgraphics(fig1, savePath1, 'Resolution', 150);
fprintf('Saved: %s\n', savePath1);

%% 5. PLOT 2 — Stacked area: proportional share per layer
% Normalise by total layer-occupancy at each step (not by numAgents,
% since agents may hold multiple layers).
totalOccupancy = sum(nationalPerLayer, 1);   % [1 x T]
totalOccupancy(totalOccupancy == 0) = 1;     % avoid divide by zero at t=0
sharePerLayer  = nationalPerLayer ./ totalOccupancy * 100;  % [nLayers x T]

fig2 = figure('Name','Layer Share (stacked area)','NumberTitle','off', ...
              'Position',[100 100 950 500]);
area(yearAxis(postSpinup), sharePerLayer(:, postSpinup)', 'LineWidth', 0.5);
colororder(cm);
xlabel('Year');
ylabel('% of total layer-occupancy');
title('Share of each livelihood layer over time');
legend(layerNames, 'Location','eastoutside', 'Interpreter','none');
xlim([yearAxis(postSpinup(1)) yearAxis(end)]);
ylim([0 100]);
grid on;

savePath2 = './Plotting/layers_stacked.png';
exportgraphics(fig2, savePath2, 'Resolution', 150);
fprintf('Saved: %s\n', savePath2);

%% 6. PLOT 3 — Bar chart: distribution at start, midpoint, and end
snapshots = [postSpinup(1), ...
             postSpinup(round(end/2)), ...
             postSpinup(end)];
snapLabels = arrayfun(@(t) sprintf('%.0f', yearAxis(t)), snapshots, 'UniformOutput', false);

Y = nationalPerLayer(:, snapshots)';   % [3 x nLayers]

fig3 = figure('Name','Layer Snapshots','NumberTitle','off', ...
              'Position',[100 100 900 420]);
b = bar(Y, 'grouped');
for iL = 1:nLayers
    b(iL).FaceColor = cm(iL,:);
end
set(gca, 'XTickLabel', snapLabels, 'XTick', 1:3);
xlabel('Year');
ylabel('Agents (layer-occupancy count)');
title('Layer distribution at three points in time');
legend(layerNames, 'Location','eastoutside', 'Interpreter','none');
grid on;

savePath3 = './Plotting/layers_snapshots.png';
exportgraphics(fig3, savePath3, 'Resolution', 150);
fprintf('Saved: %s\n', savePath3);

%% 7. PLOT 4 — Heatmap: agents per layer per region at terminal time
terminalSlice = squeeze(output.countAgentsPerLayer(:, :, end));  % [nLocs x nLayers]

fig4 = figure('Name','Terminal Layer-Region Heatmap','NumberTitle','off', ...
              'Position',[100 100 800 700]);
imagesc(terminalSlice);
colormap(parula);
cb = colorbar;
cb.Label.String = 'Agents (layer-occupancy count)';
set(gca, 'XTick', 1:nLayers, 'XTickLabel', layerNames, 'XTickLabelRotation', 35, ...
         'YTick', 1:nLocs, 'YTickLabel', locNames, 'FontSize', 9);
xlabel('Layer');
ylabel('Region');
title(sprintf('Agents per layer per region — terminal year (%.0f)', yearAxis(end)));
grid off;

savePath4 = './Plotting/layers_regional_heatmap.png';
exportgraphics(fig4, savePath4, 'Resolution', 150);
fprintf('Saved: %s\n', savePath4);

%% 8. Console summary of terminal layer distribution
fprintf('\n--- TERMINAL LAYER COUNTS (%.0f) ---\n', yearAxis(end));
termNational = nationalPerLayer(:, end);
for iL = 1:nLayers
    fprintf('  %-18s  %5d\n', layerNames{iL}, termNational(iL));
end

%% 9. Optional: plot a single region's layer history
%
% Uncomment and edit regionName to plot one district over time:
%
%   regionName = "Sava";
%   rIdx = find(locNames == regionName, 1);
%   if isempty(rIdx)
%       warning('Region "%s" not found.', regionName);
%   else
%       figure('Name', sprintf('Layers — %s', regionName));
%       hold on;
%       for iL = 1:nLayers
%           plot(yearAxis(postSpinup), squeeze(output.countAgentsPerLayer(rIdx, iL, postSpinup)), ...
%               'Color', cm(iL,:), 'LineWidth', 1.5, 'DisplayName', layerNames{iL});
%       end
%       hold off;
%       xlabel('Year'); ylabel('Agents (layer-occupancy)');
%       title(sprintf('Livelihood layers — %s', regionName));
%       legend('Location','eastoutside','Interpreter','none');
%       grid on;
%   end
