%% diagnose_column9.m
% Quick diagnostics to check:
%   1. Whether column 9 (vanilla) really equals the sum of other columns
%   2. Whether vanilla spatial restriction is working
%   3. Whether agents are holding single vs multi-layer portfolios
%
% Run from the MIDAS-Madagascar root directory.

outputDir = 'C:/Users/Jack/OneDrive - University of East Anglia/Documents/GitHub/MIDAS-Madagascar/Outputs/';
files = dir(fullfile(outputDir, 'test_series*.mat'));
[~, idx] = max([files.datenum]);
load(fullfile(outputDir, files(idx).name), 'input', 'output');

layerNames = {'unskilled1','unskilled2','skilled','school', ...
              'rice_north','rice_south','maize','cassava','vanilla','industrial_crop'};

T = size(output.countAgentsPerLayer, 3);

%% --- CHECK 1: Is column 9 actually equal to sum of others? ---
% Sum across all locations to get national totals per layer per timestep
national = squeeze(sum(output.countAgentsPerLayer, 1));  % [10 x T]

% At terminal timestep:
termCounts = national(:, end);
sumOfOthers = sum(termCounts([1:8,10]));  % sum of all layers except vanilla

fprintf('=== TERMINAL TIMESTEP LAYER COUNTS ===\n');
for iL = 1:10
    fprintf('  Layer %2d %-18s : %d\n', iL, layerNames{iL}, termCounts(iL));
end
fprintf('  Sum of non-vanilla layers  : %d\n', sumOfOthers);
fprintf('  Vanilla (column 9)         : %d\n', termCounts(9));
fprintf('  Ratio vanilla/sum-of-others: %.3f\n', termCounts(9)/max(1,sumOfOthers));
fprintf('  (ratio == 1.0 would confirm exact equality)\n\n');

%% --- CHECK 2: Is vanilla restricted to correct regions? ---
% Look at which locations have non-zero vanilla agents
fprintf('=== VANILLA AGENTS BY REGION (terminal timestep) ===\n');
if ismember('source_ADM2_FR', output.locations.Properties.VariableNames)
    locField = 'source_ADM2_FR';
elseif ismember('source_NAME_2', output.locations.Properties.VariableNames)
    locField = 'source_NAME_2';
else
    locField = '';
    fprintf('WARNING: Could not find region name field in locations table.\n');
    fprintf('Available fields: %s\n', strjoin(output.locations.Properties.VariableNames, ', '));
end

vanillaByRegion = output.countAgentsPerLayer(:, 9, end);  % [22 x 1]
if ~isempty(locField)
    locNames = string(output.locations.(locField));
    for iR = 1:length(locNames)
        if vanillaByRegion(iR) > 0
            fprintf('  %-30s  %d vanilla agents\n', locNames(iR), vanillaByRegion(iR));
        end
    end
    nRegionsWithVanilla = sum(vanillaByRegion > 0);
    fprintf('  %d of %d regions have vanilla agents.\n', nRegionsWithVanilla, length(locNames));
    if nRegionsWithVanilla > 2
        fprintf('  WARNING: Vanilla should only appear in Sava and Analanjirofo!\n');
        fprintf('  Spatial restriction may not be working correctly.\n');
    end
else
    fprintf('  Cannot check by region — no name field found.\n');
    fprintf('  Vanilla counts by row index:\n');
    for iR = 1:length(vanillaByRegion)
        if vanillaByRegion(iR) > 0
            fprintf('    Row %2d: %d agents\n', iR, vanillaByRegion(iR));
        end
    end
end

%% --- CHECK 3: Are agents in single or multi-layer portfolios? ---
% Look at the sum across layers for each agent-location-time cell.
% If sum > 1 for a location, some agents have multi-layer portfolios.
fprintf('\n=== PORTFOLIO SIZE CHECK (terminal timestep) ===\n');
layersPerLocation = sum(output.countAgentsPerLayer(:,:,end), 2);  % sum across layers
totalAgents       = height(output.agentSummary);
fprintf('  Total layer-occupancy slots filled: %d\n', sum(layersPerLocation));
fprintf('  Total living agents at end: %d (approx)\n', sum(output.agentSummary.TOD < 0));
fprintf('  Ratio (>1 means some agents hold multiple layers): %.2f\n', ...
    sum(layersPerLocation) / max(1, sum(output.agentSummary.TOD < 0)));

%% --- CHECK 4: Sample a few agent portfolios ---
fprintf('\n=== SAMPLE AGENT PORTFOLIOS (first 10 agents) ===\n');
for iA = 1:min(10, height(output.agentSummary))
    cp = output.agentSummary.currentPortfolio{iA};
    if ~isempty(cp)
        activeLayers = find(logical(cp(1, 1:min(10,end))));
        names = strjoin(layerNames(activeLayers), ', ');
    else
        names = '(empty)';
    end
    fprintf('  Agent %4d: [%s]\n', iA, names);
end

%% --- CHECK 5: What fields exist in the locations table? ---
fprintf('\n=== LOCATIONS TABLE FIELDS ===\n');
fprintf('%s\n', strjoin(output.locations.Properties.VariableNames, ', '));
