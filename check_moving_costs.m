function check_moving_costs()
% check_moving_costs  --  seconds-long verification of the distance-cost fix
%
% WHY THIS EXISTS
% The quantities that had to be verified after the 2026-08-09 cache fix --
% does movingCostPerMile survive readParameters, and does it produce a
% non-zero cost matrix -- are all settled at WORLD-BUILD time, before the
% first timestep. Running a full agent trace to see them costs an hour;
% this costs seconds, because it stops before any agents are simulated.
%
% WHAT IT TESTS
%   1. THE CLOBBER. createMapFromSHP.m used a bare load() of the cached map,
%      which dropped a saved mapParameters struct over the live one and
%      discarded every override and Monte Carlo draw. This sets a sentinel
%      value, runs the map load, and checks the value survived.
%   2. THE GEOMETRY. Distances must be in MILES. If mapParameters.r1 is
%      empty, createNetwork leaves them as raw pixel indices, every pair
%      falls below minDistForCost, and migration is free with no warning.
%   3. THE COST SURFACE. The actual movingCosts matrix createMovingCosts
%      returns, at the shortest, median and longest real region pairs.
%
% Usage:
%   cd <MIDAS project root>
%   check_moving_costs

addpath('./Core_MIDAS_Code');
addpath('./Application_Specific_MIDAS_Code');

SENTINEL = 8;   % mid-range of the revised MC design (2-15)

inputs = table({'mapParameters.movingCostPerMile'}, SENTINEL, ...
               'VariableNames', {'parameterNames','parameterValues'});

[~, ~, ~, mapParameters] = readParameters(inputs);

fprintf('\n=== 1. OVERRIDE SURVIVES readParameters ===\n');
report(mapParameters.movingCostPerMile == SENTINEL, ...
       sprintf('movingCostPerMile = %g (expected %g)', ...
               mapParameters.movingCostPerMile, SENTINEL));

% --- the map load: this is where the clobber used to happen -------------
[locations, ~, ~, mapParameters] = createMapFromSHP(mapParameters);

fprintf('\n=== 2. OVERRIDE SURVIVES THE MAP CACHE (the actual fix) ===\n');
report(mapParameters.movingCostPerMile == SENTINEL, ...
       sprintf('movingCostPerMile = %g after createMapFromSHP (expected %g)', ...
               mapParameters.movingCostPerMile, SENTINEL));
report(~isempty(mapParameters.r1), 'r1 present (needed to convert pixels to miles)');
fprintf('  band: minDistForCost = %g, maxDistForCost = %g\n', ...
        mapParameters.minDistForCost, mapParameters.maxDistForCost);

% --- distances, replicating createNetwork.m lines 26-44 ------------------
locations = sortrows(locations, 'matrixID');
[listX, listY] = ind2sub([mapParameters.sizeX mapParameters.sizeY], locations.LocationIndex);
if ~isempty(mapParameters.r1)
    aveLatitude   = mapParameters.r1(2) + mapParameters.sizeX / mapParameters.density / 2;
    longDegToMile = cos(aveLatitude * mapParameters.degToRad);
    listX = listX / mapParameters.density * mapParameters.milesPerDeg;
    listY = listY / mapParameters.density * mapParameters.milesPerDeg * longDegToMile;
end
D = squareform(pdist([listX listY]));
offD = D(~eye(size(D)));

fprintf('\n=== 3. DISTANCES ARE IN MILES ===\n');
fprintf('  min %.0f   median %.0f   max %.0f\n', min(offD), median(offD), max(offD));
report(max(offD) > 300 && max(offD) < 1500, ...
       'plausible for Madagascar (expect roughly 40-860 between region centroids)');

% --- the cost surface ----------------------------------------------------
movingCosts = createMovingCosts(locations, D, mapParameters);
offC = movingCosts(~eye(size(movingCosts)));

fprintf('\n=== 4. COST SURFACE ===\n');
fprintf('  min %.2f   median %.2f   max %.2f\n', min(offC), median(offC), max(offC));
report(max(offC) > 0, 'costs are NON-ZERO -- this is the headline check');
report(mean(offC == 0) < 0.10, ...
       sprintf('%.0f%% of pairs are free (was 100%% before the fix)', 100*mean(offC == 0)));

% Cost at the shortest, median and longest real pairs, against income.
fprintf('\n  cost by distance (annual agent income is roughly 10-25):\n');
q = [0 25 50 75 100];
for k = 1:numel(q)
    dq = prctile(offD, q(k));
    [~, idx] = min(abs(offD - dq));
    fprintf('    p%-3d  %5.0f mi  ->  cost %6.2f\n', q(k), dq, offC(idx));
end

fprintf(['\nIf check 4 passes, launch the 200-run HPC set. The full agent trace\n' ...
         'is still worth running for churn and distress share, but those inform\n' ...
         'the limitations section rather than gate the launch.\n\n']);
end

% =========================================================================
function report(ok, msg)
if ok
    fprintf(2 - 1, '  [PASS] %s\n', msg);
else
    fprintf(2, '  [FAIL] %s\n', msg);
end
end
