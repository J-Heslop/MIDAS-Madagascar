%% plot_population.m
% Plots total agent population, deaths, and births over the MIDAS run.
%
% USAGE:
%   Run from the MIDAS-Madagascar root directory. The script will prompt
%   you to select an output .mat file, or auto-load the most recent one.
%
% WHAT'S IN THE OUTPUT:
%   Deaths per timestep  — reconstructed from agentSummary.TOD
%   Births per timestep  — NOTE: DOB is not exported to agentSummary by
%                          default in MIDAS. Total births over the run are
%                          shown, but cannot be disaggregated by timestep
%                          without a model modification (see bottom of file).
%   Total alive          — initial population minus cumulative deaths,
%                          plus total births distributed as a flat offset
%                          (approximate; see note below).
%
% -------------------------------------------------------------------------

clear; clc;

%% 1. Load output file

outputDir = 'C:/Users/Jack/OneDrive - University of East Anglia/Documents/GitHub/MIDAS-Madagascar/Outputs/';
files = dir(fullfile(outputDir, 'test_series*.mat'));
if isempty(files)
    error('No test_series*.mat files found in %s', outputDir);
end
[~, idx] = max([files.datenum]);
fname = fullfile(outputDir, files(idx).name);
fprintf('Loading: %s\n', fname);
load(fname,'output');

%% 2. Time axis configuration — must match readParameters.m
startYear   = 1985;
cycleLength = 4;     % quarters per year
spinupTime  = 10;    % spinup in QUARTERS (= 2.5 years) — readParameters.m comment confirms this
spinupSteps = spinupTime;  % already in quarters; do NOT multiply by cycleLength

T = size(output.countAgentsPerLayer, 3);
yearAxis   = startYear + (0:T-1) / cycleLength;
postSpinup = spinupSteps+1 : T;

%% 3. Derive population statistics from agentSummary
% ---------------------------------------------------------------
% agentSummary has one row per agent (initial + born during run).
% TOD = timestep of death; -9999 means still alive at end of run.
% DOB = timestep of birth for born agents; NOT exported to agentSummary
%       (initial agents had DOB = -9999, meaning "before simulation").

TOD = output.agentSummary.TOD;   % vector of length = total agents ever
numAgentsEver    = length(TOD);
numInitialAgents = sum(sum(output.countAgentsPerLayer(:,:,1)));
numBornInRun     = numAgentsEver - numInitialAgents;

fprintf('\n--- POPULATION OVERVIEW ---\n');
fprintf('Initial agents:         %d\n', numInitialAgents);
fprintf('Agents born during run: %d\n', numBornInRun);
fprintf('Total agents ever:      %d\n', numAgentsEver);
fprintf('Agents alive at end:    %d\n', sum(TOD < 0));
fprintf('Agents who died:        %d\n', sum(TOD > 0));

%% 4. Deaths per timestep
% ---------------------------------------------------------------
% Bin TOD values into timestep buckets. Agents with TOD <= 0 are excluded
% (TOD = -9999 means alive at end; TOD = 0 should not occur normally).
deathsPerStep = histcounts(TOD(TOD > 0), 0.5 : T+0.5);   % [1 x T]

%% 5. Approximate total alive population per timestep
% ---------------------------------------------------------------
% Exact alive count requires knowing each born agent's DOB (not saved).
% This approximation: start with numInitialAgents, subtract cumulative
% deaths, and add total births as a ramp over the post-spinup period.
%
% This is approximate. For exact tracking, see the note at the bottom
% of this file.

cumDeaths    = cumsum(deathsPerStep);
birthsPerStep = zeros(1, T);

if numBornInRun > 0
    % Distribute total births evenly across post-spinup period as best estimate
    % (Replace this with real DOB data if you add DOB to agentSummary)
    birthsPerStep(spinupSteps+1 : end) = numBornInRun / length(postSpinup);
end

cumBirths = cumsum(birthsPerStep);
aliveApprox = numInitialAgents - cumDeaths + cumBirths;

%% 6. PLOT — Population over time
% ---------------------------------------------------------------
fig = figure('Name','Population Over Time','NumberTitle','off', ...
             'Position', [100 100 900 500]);

% Panel 1: Total alive population
subplot(2,1,1);
plot(yearAxis(postSpinup), aliveApprox(postSpinup), 'k-', 'LineWidth', 2, ...
     'DisplayName', 'Total alive (approx)');
hold on;
xline(startYear + spinupTime, '--', 'Color', [0.5 0.5 0.5], ...
      'Label','Spinup end', 'LabelHorizontalAlignment','right');
hold off;
ylabel('Number of agents');
title('Total agent population over time');
legend('Location','best');
grid on;
xlim([yearAxis(postSpinup(1)) yearAxis(end)]);

if numBornInRun > 0
    annotation('textbox', [0.15 0.88 0.5 0.04], ...
        'String', sprintf('Note: births (%d total) distributed evenly — add DOB to agentSummary for exact tracking', numBornInRun), ...
        'FitBoxToText','on', 'BackgroundColor','#FFFBCC', 'EdgeColor','#CCAA00', ...
        'FontSize', 8, 'Interpreter','none');
end

% Panel 2: Births and deaths per quarter
subplot(2,1,2);
hold on;
bar(yearAxis(postSpinup), deathsPerStep(postSpinup), 'FaceColor', [0.8 0.2 0.2], ...
    'EdgeColor','none', 'DisplayName','Deaths per quarter');
if numBornInRun > 0
    plot(yearAxis(postSpinup), birthsPerStep(postSpinup), 'b-', 'LineWidth', 1.5, ...
         'DisplayName', sprintf('Births (uniform approx, %d total)', numBornInRun));
end
xline(startYear + spinupTime, '--', 'Color', [0.5 0.5 0.5]);
hold off;
xlabel('Year');
ylabel('Agents per quarter');
title('Deaths (and approximate births) per quarter');
legend('Location','best');
grid on;
xlim([yearAxis(postSpinup(1)) yearAxis(end)]);

sgtitle(sprintf('Madagascar MIDAS — Population dynamics (%d–%d)', ...
    round(yearAxis(postSpinup(1))), round(yearAxis(end))), 'FontSize', 13);

%% 7. Save figure
savePath = fullfile('./Plotting/', 'population_plot.png');
exportgraphics(fig, savePath, 'Resolution', 150);
fprintf('\nFigure saved to: %s\n', savePath);

%% ---------------------------------------------------------------
%  NOTE: How to get exact births per timestep
%  ---------------------------------------------------------------
%  DOB (date of birth) is set on each born agent in midasMainLoop.m but
%  is not currently exported to agentSummary. To enable it, add one line
%  in midasMainLoop.m after the other agentSummary assignments (~line 431):
%
%      agentSummary.DOB = [agentList(:).DOB]';
%
%  Then births per timestep becomes:
%      DOB = output.agentSummary.DOB;
%      birthsPerStep = histcounts(DOB(DOB > 0), 0.5 : T+0.5);
%      aliveExact    = numInitialAgents - cumsum(deathsPerStep) + cumsum(birthsPerStep);
%
%  Initial agents hav