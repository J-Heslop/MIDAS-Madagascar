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
    % The four food-insecurity drivers are shown together because the
    % subsistence range was identified CONDITIONAL on the other three. Reading
    % subsistence alone tells you nothing about whether that conditioning still
    % holds; reading all four side by side does.
    show = {'modelParameters.numAgents', 'agentParameters.subsistence_costs', ...
            'modelParameters.droughtScaleFactor', ...
            'agentParameters.incomeShareFractionMean', ...
            'modelParameters.distressShortfallFrac', ...
            'mapParameters.movingCostPerMile', 'mapParameters.minDistForCost', ...
            'mapParameters.maxDistForCost'};
    % THESE ARE THE BOUNDS ON DISK, NOT NECESSARILY THE ONES SAMPLED.
    % runMIDASExperiment_parallel overrides five of them AFTER loading this
    % file (the declaredFixed and declaredRange blocks). So a stale-looking
    % interval below is expected for those five and is not a fault; what would
    % be a fault is the runner's blocks going missing, which preflight.sh
    % checks. Marked inline so the two are never read as contradicting.
    declared = {'agentParameters.subsistence_costs', ...
                'agentParameters.incomeShareFractionMean', ...
                'modelParameters.distressShortfallFrac'};
    for k = 1:numel(show)
        i = find(strcmp(L.mcParams.Name, show{k}), 1);
        tag = '';
        if ismember(show{k}, declared)
            tag = '   <- OVERRIDDEN by the runner; this is the on-disk value';
        end
        if isempty(i)
            fprintf('     %-42s not in design%s\n', show{k}, tag);
        else
            fprintf('     %-42s [%g, %g]%s\n', show{k}, ...
                    L.mcParams.Lower(i), L.mcParams.Upper(i), tag);
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

% --- 5. The four drought channels --------------------------------------
% Every one of these can be silently switched off -- by an unset environment
% variable, by a calibration round narrowing it to zero, or by a default that
% was never revisited. A channel at zero is not a smaller effect, it is a
% different model, and the methods section claims all four are active. The
% localDemandCoupling case cost a whole calibration round before it was
% noticed, so they are all reported together here.
fprintf('\n5. DROUGHT CHANNELS (methods claims all four are active)\n');
chan = { ...
    'crop yield factor',        'droughtScaleFactor',  'scales the yield perturbation'; ...
    'local demand coupling',    'localDemandCoupling', 'drought -> non-farm income'; ...
    'food-price response',      'phiFood',             'drought -> subsistence cost'; ...
    'livestock terms of trade', 'phiLv',               'drought -> buffer sale value'};
anyOff = false;
for k = 1:size(chan, 1)
    f = chan{k, 2};
    if isfield(mp, f)
        v = mp.(f);
        if v == 0
            warn(sprintf('%-24s %-22s = 0  DISABLED (%s)', chan{k,1}, f, chan{k,3}));
            anyOff = true;
        else
            ok(sprintf('%-24s %-22s = %g  (%s)', chan{k,1}, f, v, chan{k,3}));
        end
    else
        warn(sprintf('%-24s %-22s NOT SET', chan{k,1}, f));
        anyOff = true;
    end
end
% --- Does the drought forcing actually REACH the projection period? -------
% The channel check above passes as long as droughtScaleFactor is non-zero.
% That is necessary but nowhere near sufficient, and the gap is what sank the
% Set 21 campaign: droughtScaleFactor was 0.05-0.40 and reported healthy, but
% it multiplies OBSERVED SPEI, and observed_spei_harvest.csv stops at 2022.
% With droughtVariabilityOn = false the Markov chain that should take over
% never ran, so 2023-2085 had no drought events at all -- only the smooth GRMA
% mean-yield decline. Every national series went flat after 2023 and nobody
% noticed until the ensemble was plotted.
%
% A scale factor with nothing to scale is worse than a zero, because it looks
% fine in every summary.
OBS_LAST_YEAR = 2022;
fprintf('\n5b. DROUGHT FORCING REACHES THE RUN HORIZON\n');
varOn = isfield(mp, 'droughtVariabilityOn') && mp.droughtVariabilityOn;
endY  = isfield(mp, 'endYear') * mp.endYear;
if endY > OBS_LAST_YEAR
    if varOn
        ok(sprintf('endYear %d > observed record (%d); Markov variability ON', ...
                   endY, OBS_LAST_YEAR));
    else
        warn(sprintf(['endYear %d > observed record (%d) but droughtVariabilityOn ' ...
                      '= FALSE.\n      Years %d-%d will have NO drought events, only ' ...
                      'the smooth GRMA mean-yield trend.\n      Set DROUGHT_VARIABILITY=1.'], ...
                      endY, OBS_LAST_YEAR, OBS_LAST_YEAR + 1, endY));
        anyOff = true;
    end
else
    ok(sprintf('endYear %d is within the observed SPEI record (to %d)', ...
               endY, OBS_LAST_YEAR));
end

% The environment variable overrides the parameter at run time, so report what
% it will resolve to rather than only what readParameters holds.
envK = getenv('LOCAL_DEMAND_COUPLING');
if isempty(envK)
    fprintf('   LOCAL_DEMAND_COUPLING unset -> falls back to the parameter above\n');
else
    fprintf('   LOCAL_DEMAND_COUPLING = "%s" -> OVERRIDES the parameter above\n', envK);
end
if anyOff
    warn('At least one drought channel is off. Fix it, or correct the methods text.');
end

% --- 6. What the sampler will actually use -----------------------------
% A parameter whose narrowed bounds have collapsed to a point is FIXED, and
% the collapse is silent. Worth seeing before submitting, because it is how a
% mechanism gets disabled without anyone choosing to disable it.
fprintf('\n6. FIXED PARAMETERS IN THE NARROWED BOUNDS\n');
if isempty(found)
    fprintf('   (no updatedMCParams.mat -- fresh wide priors, nothing fixed)\n');
else
    L2 = load(found);
    fixedIdx = find(L2.mcParams.Upper - L2.mcParams.Lower <= 1e-9);
    if isempty(fixedIdx)
        ok('no parameter has collapsed to a point');
    else
        fprintf('   %d parameters are fixed:\n', numel(fixedIdx));
        for k = fixedIdx(:)'
            nm = L2.mcParams.Name{k};
            val = L2.mcParams.Lower(k);
            % Switches fixed at 1, and control settings, are expected. A
            % behavioural coefficient pinned at zero is not.
            isSwitch = any(contains(lower(nm), {'arm', 'enabled', 'code'}));
            if val == 0 && ~isSwitch
                warn(sprintf('%-52s = 0   <-- mechanism off?', nm));
            else
                fprintf('     %-52s = %g\n', nm, val);
            end
        end
    end
end

fprintf('\n=======================================================\n');
fprintf('Submit only if every line above reads PASS.\n\n');
end

% =========================================================================
function ok(msg);   fprintf('   [PASS] %s\n', msg); end
function warn(msg); fprintf(2, '   [CHECK] %s\n', msg); end
