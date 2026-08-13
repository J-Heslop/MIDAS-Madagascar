function check_projection_config()
% check_projection_config  --  seconds-long pre-flight before an HPC submission
%
% Prints what a run will ACTUALLY use, rather than what the scripts appear to
% say. Every serious defect found in this project during 2026 was a parameter
% that never reached the model: distance costs discarded by the map cache,
% endYear silently ignored because numCycles is computed before overrides are
% applied, narrowed bounds not loading. None produced an error; all produced
% plausible-looking output. This checks the things that fail silently.
%
% Run once per submission, with readParameters.m edited as intended:
%   cd <MIDAS project root>
%   check_projection_config

addpath('./Core_MIDAS_Code');
addpath('./Application_Specific_MIDAS_Code');

[~, mp, ~, mapP] = readParameters([]);

fprintf('\n================ PROJECTION PRE-FLIGHT ================\n');

% --- 1. Simulation horizon --------------------------------------------
% endYear CANNOT be overridden through the inputs table: numCycles is
% computed from it at readParameters.m:15, before the override loop runs.
% It has to be edited in the file, so it has to be checked here.
fprintf('\n1. HORIZON\n');
fprintf('   startYear   %d\n', mp.startYear);
fprintf('   endYear     %d\n', mp.endYear);
fprintf('   numCycles   %d\n', mp.numCycles);
fprintf('   timeSteps   %d   (spinup %d + %d x %d)\n', ...
        mp.timeSteps, mp.spinupTime, mp.numCycles, mp.cycleLength);
if mp.endYear >= 2085
    ok('endYear is set for PROJECTION runs');
else
    warn(sprintf('endYear is %d -- this is a CALIBRATION horizon, not a projection', mp.endYear));
end

% --- 2. Scenario -------------------------------------------------------
% sspScenario is a string, and the override loop uses num2str, so it also
% cannot come through the inputs table. Both SSPs must be submitted
% separately with this line edited.
fprintf('\n2. SCENARIO\n');
fprintf('   sspScenario %s\n', mp.sspScenario);
needed = {mp.survivalFile, mp.fertilityFile, mp.speiFile};
for k = 1:numel(needed)
    if exist(needed{k}, 'file')
        ok(needed{k});
    else
        warn(['MISSING ' needed{k}]);
    end
end
% GRMA yield surfaces, for the crops actually requested by the layer file
if exist(mp.utilityLayersFile, 'file')
    LD = readtable(mp.utilityLayersFile, 'TextType', 'string');
    crops = unique(LD.grma_crop(strlength(LD.grma_crop) > 0));
    dataDir = fileparts(mp.utilityLayersFile);
    for k = 1:numel(crops)
        f = fullfile(dataDir, sprintf('GRMA_yield_%s_%s.csv', crops(k), mp.sspScenario));
        if exist(f, 'file'); ok(f); else; warn(['MISSING ' f]); end
    end
    fprintf('   crops requested by the layer file: %s\n', strjoin(cellstr(crops), ', '));
end

% --- 3. Which parameter bounds will be sampled -------------------------
% runMIDASExperiment_parallel loads updatedMCParams.mat if it can find one,
% and otherwise falls back to fresh wide priors. The two give very different
% runs, and the only signal is a line of console output that scrolls past.
fprintf('\n3. PARAMETER BOUNDS\n');
searchPaths = { fullfile('Calibration Testing', 'updatedMCParams.mat'), ...
                'updatedMCParams.mat' };
found = '';
for k = 1:numel(searchPaths)
    if exist(searchPaths{k}, 'file') == 2; found = searchPaths{k}; break; end
end
if isempty(found)
    warn('No updatedMCParams.mat -- runs will use FRESH WIDE priors, NOT your calibration');
else
    L = load(found);
    ok(sprintf('will load NARROWED bounds from %s (%d parameters)', found, height(L.mcParams)));
    show = {'modelParameters.numAgents', 'agentParameters.subsistence_costs', ...
            'mapParameters.movingCostPerMile', 'mapParameters.minDistForCost', ...
            'mapParameters.maxDistForCost'};
    for k = 1:numel(show)
        i = find(strcmp(L.mcParams.Name, show{k}), 1);
        if isempty(i)
            fprintf('     %-42s not in design\n', show{k});
        else
            fprintf('     %-42s [%g, %g]\n', show{k}, L.mcParams.Lower(i), L.mcParams.Upper(i));
        end
    end
    % The distance-band parameters were INERT before the 2026-08-09 map-cache
    % fix, so any bounds narrowed for them came from rounds in which they had
    % no effect. Inheriting those into live runs would be worse than not
    % narrowing at all.
    for nm = {'mapParameters.minDistForCost', 'mapParameters.maxDistForCost'}
        if any(strcmp(L.mcParams.Name, nm{1}))
            warn(sprintf(['%s is still in the design. It was inert before the ' ...
                 'map-cache fix, so its narrowed bounds were fitted to noise.'], nm{1}));
        end
    end
    i = find(strcmp(L.mcParams.Name, 'mapParameters.movingCostPerMile'), 1);
    if ~isempty(i) && L.mcParams.Upper(i) <= 5
        warn(['movingCostPerMile upper bound is <= 5, which looks like the ' ...
              'pre-fix range. Distance friction will be weak.']);
    end
end

% --- 4. Distance costs actually reach the model ------------------------
fprintf('\n4. DISTANCE COSTS\n');
fprintf('   band [%g, %g] miles, movingCostPerMile default %g\n', ...
        mapP.minDistForCost, mapP.maxDistForCost, mapP.movingCostPerMile);
fprintf('   (run check_moving_costs for the full cost-surface test)\n');

fprintf('\n=======================================================\n');
fprintf('Submit only if every line above reads PASS.\n\n');
end

% =========================================================================
function ok(msg);   fprintf('   [PASS] %s\n', msg); end
function warn(msg); fprintf(2, '   [CHECK] %s\n', msg); end
