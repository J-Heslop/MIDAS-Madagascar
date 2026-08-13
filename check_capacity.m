function check_capacity()
% check_capacity  --  inspect the layer capacity / hard-slot arrays
%
% DIAGNOSTIC ONLY. Runs readParameters + buildWorld and stops -- no agent
% loop, no simulation, so it returns in the time buildWorld takes (map and
% demography setup) rather than the several minutes a full run needs.
%
% Answers three questions:
%
%  Q1  Is hardSlotCountYN really (nLoc x nLayers)? createUtilityLayers.m:736
%      does hardSlotCountYN(spatiallyRestricted) = true, indexing it with an
%      (nLoc x nLayers) logical. If the array is actually (nLayers x 1) that
%      write is doing linear indexing into the wrong shape and the spatial
%      restrictions are being applied to arbitrary entries.
%
%  Q2  Has the prerequisite rewrite zeroed capacity for no-prereq layers?
%      createUtilityLayers.m:771-777 (and midasMainLoop.m:208-212) rebuild
%      nExpected from prerequisite sums into a zeros() array, discarding the
%      values set just above. Layers with no prereq -- unskilled1, school,
%      maize, cassava, rice_*, vanilla, industrial_crop -- should therefore
%      come back as 0 EVERYWHERE. That is currently harmless because
%      hard_slot = 0 in the CSV means capacity is never consulted, but it
%      will make every hard-slotted layer unavailable nationally the moment
%      the census work turns hard slots on.
%
%  Q3  Is vanilla actually blocked in the southern regions? The occupancy
%      readout showed ~11k agent-timesteps of vanilla in regions 19-21,
%      which restrict_to = "Sava|Analanjirofo" should prevent.
%
% Usage:
%   cd <MIDAS project root>
%   check_capacity

addpath('./Core_MIDAS_Code');
addpath('./Application_Specific_MIDAS_Code');

% Mirror run_buffer_trace.m so we inspect the configuration actually in use.
names = { ...
    'modelParameters.bufferEnabled'; ...
    'modelParameters.distressMigrationEnabled'; ...
    'modelParameters.distressTriggerCode'; ...
    'modelParameters.numAgents'; ...
    'modelParameters.droughtScaleFactor'; ...
    'agentParameters.subsistence_costs'; ...
    'modelParameters.livelihoodAttachmentEnabled'; ...
    'modelParameters.livelihoodAttachmentScale'; ...
    };
values = [ 1; 1; 6; 1500; 0.30; 1.75; 1; 0.5 ];
inputs = table(names, values, 'VariableNames', {'parameterNames','parameterValues'});

fprintf('Building world (no simulation)...\n');
[~, ~, modelParameters, ~, ~, uv, mv, ~] = ...
    buildWorld_wrapper(inputs);

nLoc    = size(mv.locations, 1);
% nExpectedFrac is (nLoc x nLayers) since the per-region capacity change --
% numel() would give nLoc*nLayers and corrupt every index below.
nLayers = size(uv.nExpectedFrac, 2);

% Layer names, in CSV row order.
LD = readtable(modelParameters.utilityLayersFile, 'TextType', 'string');
layerNames = string(LD.name);

fprintf('\nnLoc = %d, nLayers = %d\n', nLoc, nLayers);

% ---- Q1: shape of hardSlotCountYN --------------------------------------
fprintf('\n=== Q1  hardSlotCountYN ===\n');
fprintf('  size  : %s\n', mat2str(size(uv.hardSlotCountYN)));
fprintf('  class : %s\n', class(uv.hardSlotCountYN));
if isequal(size(uv.hardSlotCountYN), [nLoc nLayers])
    fprintf('  OK -- (nLoc x nLayers) as createUtilityLayers.m:736 assumes.\n');
else
    fprintf(2, '  *** WRONG SHAPE. Line 736 writes into this with an (nLoc x nLayers)\n');
    fprintf(2, '  *** logical mask -- so spatial restrictions are landing on the wrong\n');
    fprintf(2, '  *** entries via linear indexing. This is a second, separate bug.\n');
end
fprintf('  size of nExpected           : %s\n', mat2str(size(uv.nExpected)));
fprintf('  size of spatiallyRestricted : %s\n', mat2str(size(uv.spatiallyRestricted)));

% ---- Q2: has the prereq rewrite zeroed no-prereq layers? ---------------
fprintf('\n=== Q2  capacity by layer ===\n');
fprintf('  frac columns are now PER REGION, so min/max show the census spread.\n');
fprintf('  %-18s %-10s %12s %10s %10s\n', 'layer', 'has prereq', 'max nExpect', 'frac min', 'frac max');
for iL = 1:nLayers
    hasPre = full(any(uv.utilityPrereqs(:, iL) > 0));
    fprintf('  %-18s %-10s %12.0f %10.4f %10.4f\n', char(layerNames(iL)), ...
        tfstr(hasPre), full(max(uv.nExpected(:, iL))), ...
        min(uv.nExpectedFrac(:, iL)), max(uv.nExpectedFrac(:, iL)));
end

% Which regions actually received a census override? A region still sitting
% at the flat CSV default is one whose name did not match.
fprintf('\n  --- per-region capacity for the hard-slotted non-farm layers ---\n');
defaults = double(LD.nExpected_frac)';
nfIdx = find(ismember(layerNames, ["unskilled1","unskilled2","skilled"]))';
nameCol2 = '';
for c = ["source_NAME_2","source_ADM2_FR","source_ADM1_FR"]
    if ismember(c, string(mv.locations.Properties.VariableNames)); nameCol2 = char(c); break; end
end
fprintf('  %-4s %-24s', 'loc', 'model name');
for iL = nfIdx; fprintf(' %11s', char(layerNames(iL))); end
fprintf('   %s\n', 'override?');
nUnmatched = 0;
for iLoc = 1:nLoc
    nm = '?';
    if ~isempty(nameCol2); nm = char(string(mv.locations.(nameCol2)(iLoc))); end
    isDefault = all(abs(uv.nExpectedFrac(iLoc, nfIdx) - defaults(nfIdx)) < 1e-9);
    if isDefault; nUnmatched = nUnmatched + 1; end
    fprintf('  %-4d %-24s', iLoc, nm);
    for iL = nfIdx; fprintf(' %11.4f', uv.nExpectedFrac(iLoc, iL)); end
    fprintf('   %s\n', char(string(~isDefault)));
end
if nUnmatched > 0
    fprintf(2, '\n  *** %d location(s) still on the flat CSV default -- their names did\n', nUnmatched);
    fprintf(2, '  *** not match any row in nonag_capacity_by_region.csv. The model names\n');
    fprintf(2, '  *** printed above are the ones to reconcile against the census file.\n');
end
zeroNoPre = arrayfun(@(iL) ~full(any(uv.utilityPrereqs(:,iL)>0)) && ...
                           full(all(uv.nExpected(:,iL)==0)), 1:nLayers);
if any(zeroNoPre)
    fprintf(2, '\n  *** CONFIRMED: %d no-prereq layer(s) have capacity 0 at EVERY location.\n', sum(zeroNoPre));
    fprintf(2, '  *** Harmless now (hard_slot = 0 everywhere, so capacity is never read),\n');
    fprintf(2, '  *** but setting hard_slot = 1 on any of them makes it unavailable\n');
    fprintf(2, '  *** nationally. Must be fixed before the census hard-slot work.\n');
else
    fprintf('\n  No no-prereq layer is uniformly zero -- the rewrite is not the problem.\n');
end

% ---- Q3: is vanilla blocked in the south? -------------------------------
fprintf('\n=== Q3  vanilla in the southern regions ===\n');
iVan = find(layerNames == "vanilla", 1);
south = [19 20 21];
if isempty(iVan)
    fprintf('  no layer named "vanilla" found.\n');
else
    fprintf('  vanilla is layer index %d (restrict_to = %s)\n', iVan, char(LD.restrict_to(iVan)));
    nameCol = '';
    for c = ["source_NAME_2","source_ADM2_FR","source_ADM1_FR"]
        if ismember(c, string(mv.locations.Properties.VariableNames)); nameCol = char(c); break; end
    end
    fprintf('  %-4s %-22s %14s %14s %12s\n', 'loc', 'name', 'restricted?', 'hardSlot?', 'nExpected');
    for iLoc = south
        nm = '?';
        if ~isempty(nameCol); nm = char(string(mv.locations.(nameCol)(iLoc))); end
        r = full(uv.spatiallyRestricted(iLoc, iVan));
        h = full(uv.hardSlotCountYN(iLoc, iVan));
        fprintf('  %-4d %-22s %14s %14s %12.0f\n', iLoc, nm, tfstr(r), tfstr(h), ...
                full(uv.nExpected(iLoc, iVan)));
    end
    % Every layer, southern regions -- shows whether ANY restriction is
    % binding down here, not just vanilla's.
    fprintf('\n  --- all layers, southern regions: restricted / hardSlot / nExpected ---\n');
    fprintf('  %-18s', 'layer');
    for iLoc = south; fprintf('   loc%-2d', iLoc); end
    fprintf('\n');
    for iL = 1:nLayers
        fprintf('  %-18s', char(layerNames(iL)));
        for iLoc = south
            fprintf('  %s/%s/%-4.0f', ...
                tfchar(uv.spatiallyRestricted(iLoc,iL)), ...
                tfchar(uv.hardSlotCountYN(iLoc,iL)), ...
                full(uv.nExpected(iLoc,iL)));
        end
        fprintf('\n');
    end
    fprintf('\n  Expected if working: restricted = true, hardSlot = true, nExpected = 0\n');
    fprintf('  -> hasOpenSlots = (count < 0 AND true) OR false = FALSE = blocked.\n');
    fprintf('  If hardSlot reads false here, vanilla is selectable in the south and\n');
    fprintf('  that is where the 11k agent-timesteps came from.\n');
end

fprintf('\nDone. No simulation was run.\n');
end

% -------------------------------------------------------------------------
function s = tfstr(x)
% 'true'/'false' from anything logical-ish, including SPARSE logicals --
% string() refuses those, which is what broke the first version.
if logical(full(x)); s = 'true'; else; s = 'false'; end
end

% -------------------------------------------------------------------------
function s = tfchar(x)
% Single-character form for the compact grid: T / F
if logical(full(x)); s = 'T'; else; s = 'F'; end
end

% -------------------------------------------------------------------------
function varargout = buildWorld_wrapper(inputs)
% readParameters + buildWorld, matching midasMainLoop.m lines 12-13.
[agentParameters, modelParameters, networkParameters, mapParameters] = readParameters(inputs);
[a, b, mp, ap, mpar, uv, mv, dv] = ...
    buildWorld(modelParameters, mapParameters, agentParameters, networkParameters);
varargout = {a, b, mp, ap, mpar, uv, mv, dv};
end
