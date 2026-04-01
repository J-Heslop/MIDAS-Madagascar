function [ utilityLayerFunctions, utilityHistory, utilityAccessCosts, utilityTimeConstraints, utilityDuration, utilityAccessCodesMat, utilityPrereqs, utilityBaseLayers, utilityForms, incomeForms, nExpected, hardSlotCountYN ] = createUtilityLayers(locations, modelParameters, demographicVariables )
%createUtilityLayers builds all utility layer arrays from a CSV definition file.
%
% The CSV path is set by modelParameters.utilityLayersFile.
% Each row in the CSV defines one utility layer. See Data/utility_layers_v1.csv
% for column definitions and an example configuration.
%
% To switch utility configurations, change modelParameters.utilityLayersFile
% in readParameters.m - no changes to this file are needed.

%% -----------------------------------------------------------------------
%% 1. READ LAYER DEFINITIONS FROM CSV
%% -----------------------------------------------------------------------

layerDefs = readtable(modelParameters.utilityLayersFile, 'TextType', 'string');
nLayers   = height(layerDefs);
nLoc      = size(locations, 1);
leadTime  = modelParameters.spinupTime;
timeSteps = modelParameters.numCycles * modelParameters.cycleLength;

% Build named index struct so layers can be referenced by name rather than
% by magic numbers.  e.g. L.vanilla returns the integer column index for
% the vanilla layer, which can then be used in utilityBaseLayers(:, L.vanilla, :)
L = struct(); %#ok<NASGU>
for iL = 1:nLayers
    L.(char(layerDefs.name(iL))) = iL;
end

%% -----------------------------------------------------------------------
%% 2. UTILITY LAYER FUNCTIONS
%% -----------------------------------------------------------------------
% All layers use the same density-dependent function:
%   utility = base * (m * nExpected) / ((n_actual - m*nExpected)*k + m*nExpected)
% Income falls as more agents compete for the same layer.

utilityLayerFunctions = cell(nLayers, 1);
for iL = 1:nLayers
    utilityLayerFunctions{iL,1} = @(k,m,nExpected,n_actual,base) ...
        base * (m * nExpected) / (max(1, n_actual - m * nExpected) * k + m * nExpected);
end

%% -----------------------------------------------------------------------
%% 3. UTILITY HISTORY (pre-allocated; filled during simulation)
%% -----------------------------------------------------------------------

utilityHistory = zeros(nLoc, nLayers, timeSteps + leadTime);

%% -----------------------------------------------------------------------
%% 4. BASE LAYER PARAMETERS FROM TABLE
%% -----------------------------------------------------------------------

mean_utility_by_layer = layerDefs.mean_utility;

timeQs   = [layerDefs.timeQ1, layerDefs.timeQ2, layerDefs.timeQ3, layerDefs.timeQ4];
incomeQs = [layerDefs.incomeQ1, layerDefs.incomeQ2, layerDefs.incomeQ3, layerDefs.incomeQ4];

utilityDuration = [layerDefs.duration_min, layerDefs.duration_max];

%% -----------------------------------------------------------------------
%% 5. UTILITY BASE LAYERS  (locations x layers x time)
%% -----------------------------------------------------------------------

utilityBaseLayers = zeros(nLoc, nLayers, timeSteps + leadTime);

% Quarterly share: how annual income is distributed across the 4 quarters.
% Rows where income sums to zero (e.g. school) become NaN -> replace with 0.
quarterShare = incomeQs ./ sum(incomeQs, 2);
quarterShare(isnan(quarterShare)) = 0;

% Fill the simulation period (after spinup) cycle by cycle.
% To add SPEI drought modulation later, replace mean_utility_by_layer(iL)
% with a time-varying value indexed by iCyc.
for iL = 1:nLayers
    for iCyc = 1:(timeSteps / modelParameters.cycleLength)
        tStart = leadTime + (iCyc - 1) * modelParameters.cycleLength + 1;
        for iQ = 1:modelParameters.cycleLength
            utilityBaseLayers(:, iL, tStart + iQ - 1) = ...
                mean_utility_by_layer(iL) * quarterShare(iL, iQ);
        end
    end
end

% Fill the spinup period by repeating the first cycle backwards in time.
for iT = leadTime:-1:1
    utilityBaseLayers(:,:,iT) = utilityBaseLayers(:,:,iT + modelParameters.cycleLength);
end

% --- Spatial restrictions ---
% Layers with restrict_to ~= 'ALL' are zeroed out for all excluded regions.
% Uses NAME_2 (district name) from the locations table.
% Multiple regions are pipe-separated in the CSV, e.g. 'Sava|Analanjirofo'.
% Spelling must match the shapefile NAME_2 field exactly.
% Determine which location name field to use for spatial restrictions.
% Prefer source_NAME_2 (requires regenerating the map .mat after levelName
% was set to 'NAME_' in readParameters.m).  Fall back to source_ADM2_FR
% (always present in the shapefile).  Restrict-to values in the CSV must
% match the chosen field's values exactly.
if ismember('source_NAME_2', locations.Properties.VariableNames)
    locNameField = 'source_NAME_2';
elseif ismember('source_ADM2_FR', locations.Properties.VariableNames)
    locNameField = 'source_ADM2_FR';
elseif ismember('source_ADM1_FR', locations.Properties.VariableNames)
    locNameField = 'source_ADM1_FR';
else
    % Last resort — use whatever the first source_ field is
    srcFields = locations.Properties.VariableNames( ...
        startsWith(locations.Properties.VariableNames, 'source_'));
    locNameField = srcFields{1};
    warning('createUtilityLayers: could not find a region name field. Using %s for spatial restrictions.', locNameField);
end

locNameVec = string(locations.(locNameField));

restrictTo = layerDefs.restrict_to;
for iL = 1:nLayers
    if restrictTo(iL) ~= "ALL"
        regions = strsplit(restrictTo(iL), '|');
        allowedRows = ismember(locNameVec, regions);
        if ~any(allowedRows)
            warning('createUtilityLayers: layer "%s" restrict_to="%s" matched 0 locations in field "%s". Layer will be unavailable everywhere. Check spelling.', ...
                char(layerDefs.name(iL)), char(restrictTo(iL)), locNameField);
        end
        utilityBaseLayers(~allowedRows, iL, :) = 0;
    end
end

%% -----------------------------------------------------------------------
%% 6. ACCESS COSTS
%% -----------------------------------------------------------------------
% access_cost_param in the CSV names a field in modelParameters
% (e.g. 'smallFarmCost', 'largeFarmCost', 'educationCost').
% Leave blank for layers with free entry.

accessCostParams = fillmissing(layerDefs.access_cost_param,'constant',"");
uniqueParams     = unique(accessCostParams(accessCostParams ~= ""));
nCostTypes       = length(uniqueParams);

if nCostTypes > 0
    utilityAccessCosts = zeros(nCostTypes, 2);
    for iC = 1:nCostTypes
        utilityAccessCosts(iC, 1) = iC;
        utilityAccessCosts(iC, 2) = modelParameters.(char(uniqueParams(iC)));
    end

    utilityAccessCodesMat = zeros(nCostTypes, nLayers, nLoc);
    for iL = 1:nLayers
        if accessCostParams(iL) ~= ""
            costIdx = find(uniqueParams == accessCostParams(iL));
            utilityAccessCodesMat(costIdx, iL, :) = 1;
        end
    end
else
    utilityAccessCosts    = zeros(0, 2);
    utilityAccessCodesMat = zeros(0, nLayers, nLoc);
end

%% -----------------------------------------------------------------------
%% 7. EXPECTED OCCUPANCY AND HARD SLOTS
%% -----------------------------------------------------------------------

locationProb        = demographicVariables.locationLikelihood;
locationProb(2:end) = locationProb(2:end) - locationProb(1:end-1);
numAgentsModel      = locationProb * modelParameters.numAgents;

nExpected = zeros(nLoc, nLayers);
for iL = 1:nLayers
    nExpected(:, iL) = floor(numAgentsModel * layerDefs.nExpected_frac(iL));
end

hardSlotCountYN = false(nLoc, nLayers);
for iL = 1:nLayers
    if layerDefs.hard_slot(iL)
        hardSlotCountYN(:, iL) = true;
    end
end

%% -----------------------------------------------------------------------
%% 8. UTILITY FORMS
%% -----------------------------------------------------------------------
% 1 = income (default for all layers).  Other values correspond to
% elements in the agent's B-list for heterogeneous preferences.

utilityForms = layerDefs.utility_form;
incomeForms  = utilityForms == 1;

%% -----------------------------------------------------------------------
%% 9. TIME CONSTRAINTS
%% -----------------------------------------------------------------------

utilityTimeConstraints = [(1:nLayers)', timeQs];

%% -----------------------------------------------------------------------
%% 10. PREREQUISITES
%% -----------------------------------------------------------------------
% prereq column holds the name of a required layer, or is empty.
% Convention: utilityPrereqs(this_layer, required_layer) = 1

utilityPrereqs = zeros(nLayers, nLayers);
prereqCol = fillmissing(layerDefs.prereq,'constant',"");
for iL = 1:nLayers
    if prereqCol(iL) ~= ""
        prereqIdx = L.(char(prereqCol(iL)));
        utilityPrereqs(iL, prereqIdx) = 1;
    end
end

% Each layer implicitly requires itself (MIDAS convention).
utilityPrereqs = utilityPrereqs + eye(nLayers);

% Adjust nExpected upward to account for prerequisite chains:
% an agent occupying layer X is also counted against all X's prerequisites.
tempExpected = zeros(size(nExpected));
for iL = 1:nLayers
    tempExpected(:, iL) = sum(nExpected(:, utilityPrereqs(:, iL) > 0), 2);
end
nExpected = tempExpected;

utilityPrereqs = sparse(utilityPrereqs);

end
