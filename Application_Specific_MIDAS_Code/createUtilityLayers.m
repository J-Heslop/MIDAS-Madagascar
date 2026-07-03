function [ utilityLayerFunctions, utilityHistory, utilityAccessCosts, utilityTimeConstraints, utilityDuration, utilityAccessCodesMat, utilityPrereqs, utilityBaseLayers, utilityForms, incomeForms, nExpected, hardSlotCountYN, localOnly, nExpectedFrac, spatiallyRestricted ] = createUtilityLayers(locations, modelParameters, demographicVariables )
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
% Each layer splits its yield between a SUBSISTENCE share (kept by the
% household for own consumption, immune to local market congestion) and
% a MARKET share (sold or bartered locally, subject to congestion-driven
% price/yield decay when many agents in the same place produce the same
% thing).  The split is set per-layer via the `subsistence_fraction`
% column of utility_layers_v1.csv (range 0.0 - 1.0):
%
%   subsistence_fraction = 1.0  -> all yield retained; no congestion
%   subsistence_fraction = 0.0  -> all yield to market; full congestion
%   subsistence_fraction = 0.7  -> 70% retained, 30% market-modulated
%
% This generalises the earlier binary is_subsistence flag (which is kept
% as a fallback for backward compatibility -- old CSVs with 1/0 entries
% map cleanly to fractions 1.0/0.0).
%
% Mixed utility formula:
%   utility = base*sf + base*(1 - sf) * (m*nExpected) /
%                                  (max(1, n_actual - m*nExpected)*k + m*nExpected)
%
% Empirically defensible starting values for Madagascar smallholder ag
% (FAO Madagascar profile; Harvey et al. 2014 reports ~80% retention of
% subsistence rice by surveyed households):
%   rice_north, rice_south : 0.75
%   maize                  : 0.65
%   cassava                : 0.85 (drought-tolerant subsistence fallback)
%   vanilla, industrial_crop, all urban layers : 0.0
%
% Setting subsistence_fraction below 1 for ag layers (rather than the old
% binary 1) reintroduces a partial market mechanism for the saleable
% surplus -- physically realistic, and more defensible in the methods
% section than the all-or-nothing toggle that preceded it.

if ismember('subsistence_fraction', layerDefs.Properties.VariableNames)
    subsistenceFrac = double(layerDefs.subsistence_fraction);
elseif ismember('is_subsistence', layerDefs.Properties.VariableNames)
    subsistenceFrac = double(layerDefs.is_subsistence);   % legacy 0/1 -> 0.0/1.0
else
    subsistenceFrac = zeros(nLayers, 1);                  % default: pure market
end
subsistenceFrac(isnan(subsistenceFrac)) = 0;
subsistenceFrac = max(0, min(1, subsistenceFrac));        % defensive clamp to [0, 1]

utilityLayerFunctions = cell(nLayers, 1);
for iL = 1:nLayers
    sf = subsistenceFrac(iL);
    if sf >= 1.0
        % Pure subsistence: no congestion at any agent density
        utilityLayerFunctions{iL,1} = @(k,m,nExpected,n_actual,base) base;
    elseif sf <= 0.0
        % Pure market: standard density-dependent congestion formula
        utilityLayerFunctions{iL,1} = @(k,m,nExpected,n_actual,base) ...
            base * (m * nExpected) / (max(1, n_actual - m * nExpected) * k + m * nExpected);
    else
        % Mixed: sf of yield is kept (congestion-immune); (1-sf) sold to
        % the local market (subject to standard congestion modulation).
        utilityLayerFunctions{iL,1} = @(k,m,nExpected,n_actual,base) ...
            base * sf + ...
            base * (1 - sf) * (m * nExpected) / (max(1, n_actual - m * nExpected) * k + m * nExpected);
    end
end
fprintf(['createUtilityLayers: subsistence_fraction by layer -- ' ...
         'pure-subsistence(=1): %d, pure-market(=0): %d, mixed: %d ' ...
         '(range %.2f to %.2f).\n'], ...
        sum(subsistenceFrac >= 1.0 - eps), ...
        sum(subsistenceFrac <= eps), ...
        sum(subsistenceFrac > eps & subsistenceFrac < 1.0 - eps), ...
        min(subsistenceFrac), max(subsistenceFrac));

%% -----------------------------------------------------------------------
%% 3. UTILITY HISTORY (pre-allocated; filled during simulation)
%% -----------------------------------------------------------------------

utilityHistory = zeros(nLoc, nLayers, timeSteps + leadTime);

%% -----------------------------------------------------------------------
%% 4. BASE LAYER PARAMETERS FROM TABLE
%% -----------------------------------------------------------------------

mean_utility_by_layer = layerDefs.mean_utility;

% Apply the urban income multiplier (calibration scaffold).
% Scales mean_utility for every non-agricultural (localOnly == 0) layer to
% calibrate the urban/rural relative payoff balance. See the parameter
% definition in readParameters.m for rationale. Default 1.0 = no change.
if isfield(modelParameters, 'urbanIncomeMultiplier')
    urbanRows = (layerDefs.localOnly == 0);
    mean_utility_by_layer(urbanRows) = ...
        mean_utility_by_layer(urbanRows) * modelParameters.urbanIncomeMultiplier;
end

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

% --- GRMA drought yield modulation -------------------------------------
% Agricultural layers with a grma_crop entry in utility_layers_v1.csv have
% their base utility scaled each simulation year by a pre-computed yield
% factor derived from GRMA crop-specific drought projections.
%
% Yield factors (0-1) encode mean drought loss from the GRMA Crop-specific
% Drought Index (CsDI), which combines SPEI-6, aridity index, crop water
% needs (FAO Kc/Ky), and WRI water stress.
% Source: GRMA Madagascar (2026), AXA Climate / Artelia / BRGM.
%
% Files generated by generate_grma_yield_timeseries.py:
%   Data/GRMA_yield_rice_SSP2.csv   (and SSP5 equivalent)
%   Data/GRMA_yield_maize_SSP2.csv
%   Data/GRMA_yield_cassava_SSP2.csv
%
% Format: rows = 22 ADM2 regions, columns = NAME_2, y1985, y1986 ... y2085
%
% Inter-annual variability (SPEI-based) is intentionally disabled here and
% can be layered on top once calibration is complete.  The drought_k,
% drought_min_yield and drought_harvest_month columns are retained in
% utility_layers_v1.csv for that purpose.

nSimYears = timeSteps / modelParameters.cycleLength;
firstYear = modelParameters.startYear;

% yieldFactor(iLoc, iL, iCyc): default 1.0 (no drought effect)
yieldFactor = ones(nLoc, nLayers, nSimYears);

% Data directory (same folder as utility_layers_v1.csv)
grmaDataDir = fileparts(modelParameters.utilityLayersFile);

% Resolve which location-name field the locations table carries
if ismember('source_NAME_2', locations.Properties.VariableNames)
    locNamesGrma = string(locations.source_NAME_2);
elseif ismember('source_ADM2_FR', locations.Properties.VariableNames)
    locNamesGrma = string(locations.source_ADM2_FR);
else
    srcFlds = locations.Properties.VariableNames( ...
        startsWith(locations.Properties.VariableNames, 'source_'));
    locNamesGrma = string(locations.(srcFlds{1}));
end

% Identify layers that have a grma_crop assignment
hasGrmaCol = ismember('grma_crop', layerDefs.Properties.VariableNames);
grmaLayerIdx = [];
if hasGrmaCol
    grmaLayerIdx = find(~ismissing(layerDefs.grma_crop) & layerDefs.grma_crop ~= "");
end

if ~isempty(grmaLayerIdx)
    % Load each unique crop file once and cache in a struct
    grmaCache    = struct();
    loadedCrops  = {};

    for iL = grmaLayerIdx'
        cropName = char(layerDefs.grma_crop(iL));
        if ismember(cropName, loadedCrops)
            continue;   % already loaded
        end

        % Build file path from crop name and SSP scenario (defined in utility_layers_v1.csv)
        grmaPath = fullfile(grmaDataDir, ...
            sprintf('GRMA_yield_%s_%s.csv', cropName, modelParameters.sspScenario));

        if ~exist(grmaPath, 'file')
            warning('createUtilityLayers: GRMA file not found: %s\n  Agricultural layer "%s" will run without drought modulation.', ...
                grmaPath, char(layerDefs.name(iL)));
            continue;
        end

        % Read file: col 1 = NAME_2, cols 2:end = y1985..y2085
        T = readtable(grmaPath, 'TextType', 'string');
        grmaCache.(cropName).regionNames = string(T{:, 1});
        grmaCache.(cropName).yearData    = table2array(T(:, 2:end));  % [22 x 101]
        grmaCache.(cropName).firstYear   = 1985;                      % fixed by script
        loadedCrops{end+1} = cropName; %#ok<AGROW>
    end

    % Apply yield factors layer by layer
    nGrmaApplied = 0;
    for iL = grmaLayerIdx'
        cropName = char(layerDefs.grma_crop(iL));
        if ~isfield(grmaCache, cropName)
            continue;   % file was missing or unrecognised
        end
        cd = grmaCache.(cropName);

        % Build location → GRMA-row index for this crop
        locToGrmaRow = zeros(nLoc, 1);
        for iLoc = 1:nLoc
            idx = find(cd.regionNames == locNamesGrma(iLoc), 1);
            if ~isempty(idx)
                locToGrmaRow(iLoc) = idx;
            end
        end
        validLoc = locToGrmaRow > 0;

        for iCyc = 1:nSimYears
            yr     = firstYear + iCyc - 1;
            colIdx = yr - cd.firstYear + 1;   % column index into yearData

            if colIdx < 1 || colIdx > size(cd.yearData, 2)
                continue;   % year outside CSV range: leave factor = 1.0
            end

            % Gather pre-computed yield factors for all locations
            factor = ones(nLoc, 1);
            factor(validLoc) = cd.yearData(locToGrmaRow(validLoc), colIdx);

            % Guard against any NaN/negative values from file
            factor(isnan(factor) | factor < 0) = 1.0;
            factor = min(factor, 1.0);

            yieldFactor(:, iL, iCyc) = factor;
        end
        nGrmaApplied = nGrmaApplied + 1;
    end

    fprintf('createUtilityLayers: GRMA yield modulation applied to %d layer(s) [%s scenario].\n', ...
        nGrmaApplied, modelParameters.sspScenario);
end

% --- Observed historical drought modulation (calibration period only) ----
% Loads Data/observed_spei_harvest.csv (produced by apply_observed_drought.py)
% which contains ERA5 SPEI-6 at each agricultural layer's harvest month
% for years 1985-2022. Applies the same yield perturbation the Markov
% chain uses for projection years (delta = droughtScaleFactor * SPEI6)
% but driven by OBSERVED rather than SAMPLED SPEI. Years outside
% 1985-2022 fall through to the GRMA baseline + projection-interpolation
% logic above; the Markov chain block below (still gated by
% droughtVariabilityOn) handles synthetic perturbations for 2023+.
%
% droughtScaleFactor is a calibration parameter (in mcParams) so the
% calibration learns the SPEI -> yield -> migration coupling from
% observed historical migration responses. The learned value carries
% forward unchanged into the Markov-driven projection-period drought.

obsSpeiFile = fullfile(grmaDataDir, 'observed_spei_harvest.csv');
if exist(obsSpeiFile, 'file') && isfield(modelParameters, 'droughtScaleFactor')
    OBS_FIRST_YEAR = 1985;
    OBS_LAST_YEAR  = 2022;

    OS = readtable(obsSpeiFile, 'TextType', 'string', 'VariableNamingRule', 'preserve');
    obsRegionNames = string(OS{:, 1});

    % Build location -> obs-CSV-row index using the same name field already
    % resolved for the GRMA block above (locNamesGrma).
    locToObsRow = zeros(nLoc, 1);
    for iLoc = 1:nLoc
        idx = find(obsRegionNames == locNamesGrma(iLoc), 1);
        if ~isempty(idx)
            locToObsRow(iLoc) = idx;
        end
    end
    validObsLoc = locToObsRow > 0;

    % For each ag layer with a grma_crop, look up its per-year observed
    % SPEI column and apply the perturbation onto yieldFactor.
    nObsLayers = 0;
    for iL = grmaLayerIdx'
        layerName = char(layerDefs.name(iL));
        minYld    = double(layerDefs.drought_min_yield(iL));
        if isnan(minYld); minYld = 0.0; end

        anyYearApplied = false;
        for yr = OBS_FIRST_YEAR:OBS_LAST_YEAR
            iCyc = yr - firstYear + 1;
            if iCyc < 1 || iCyc > nSimYears
                continue;   % year outside this run's simulation window
            end

            colName = sprintf('%s_y%d', layerName, yr);
            if ~ismember(colName, OS.Properties.VariableNames)
                continue;   % no observed SPEI column for this layer-year
            end
            speiVals = OS.(colName);   % nObsRows x 1

            speiPerLoc = zeros(nLoc, 1);
            speiPerLoc(validObsLoc) = speiVals(locToObsRow(validObsLoc));

            % Positive-SPEI scaling (experimental lever; default 1 = legacy).
            % The chain audit (2026-07) showed post-kere years carry a +4.6%
            % ABOVE-trend income rebound: recovery-year positive SPEI lifts
            % yields above the low GRMA baselines toward the 1.0 cap. That
            % boom pulls backward-looking agents back into southern ag just
            % when the lagged migration response would occur. Empirically,
            % post-kere recovery is slow (households have liquidated
            % livestock/seed stock), i.e. the income process is ASYMMETRIC.
            % droughtPositiveSPEIScale in [0, 1] scales only the positive
            % perturbations: 1 = symmetric (legacy), 0 = droughts subtract
            % but good years never lift yields above the GRMA baseline --
            % a one-parameter proxy for asset-recovery asymmetry, pending
            % an explicit livestock/grain-store module.
            if isfield(modelParameters, 'droughtPositiveSPEIScale') && ...
               modelParameters.droughtPositiveSPEIScale < 1
                posMask = speiPerLoc > 0;
                speiPerLoc(posMask) = modelParameters.droughtPositiveSPEIScale * speiPerLoc(posMask);
            end

            currYF = yieldFactor(:, iL, iCyc);
            currYF = currYF + modelParameters.droughtScaleFactor * speiPerLoc;
            currYF = max(minYld, min(1.0, currYF));
            yieldFactor(:, iL, iCyc) = currYF;
            anyYearApplied = true;
        end
        if anyYearApplied
            nObsLayers = nObsLayers + 1;
        end
    end

    fprintf(['createUtilityLayers: observed SPEI drought applied to %d ' ...
             'layer(s) for years %d-%d (droughtScaleFactor = %.3f).\n'], ...
             nObsLayers, OBS_FIRST_YEAR, OBS_LAST_YEAR, modelParameters.droughtScaleFactor);
else
    if ~exist(obsSpeiFile, 'file')
        fprintf('createUtilityLayers: observed_spei_harvest.csv not found at %s -- skipping observed-drought perturbation.\n', ...
                obsSpeiFile);
    end
end

% --- Inter-annual drought variability (Markov chain) ----------------------
% When modelParameters.droughtVariabilityOn == true, each agricultural
% layer's yield factor is perturbed year-by-year using a region-specific
% two-state (drought / normal) Markov chain driven by observed SPEI6
% climatology.
%
% Parameters are read from drought_markov_params.csv (one row per
% region × layer).  Each region starts in a drought/normal state drawn
% from its stationary distribution (pi_D), then transitions are simulated
% forward.  In drought years a SPEI6 value is sampled from N(mu_d, sd_d)
% and the perturbation applied is:
%
%   delta = droughtScaleFactor * SPEI6_sample   (negative; subtracts from yield)
%   yieldFactor(loc, layer, year) = clip(yieldFactor + delta, 0, 1)
%
% Normal years carry no perturbation (perturbation = 0).
%
% Tune modelParameters.droughtScaleFactor to control magnitude.
% Keep droughtVariabilityOn = false during calibration.

if isfield(modelParameters, 'droughtVariabilityOn') && modelParameters.droughtVariabilityOn

    markovFile = modelParameters.droughtMarkovFile;
    scaleFac   = modelParameters.droughtScaleFactor;

    if ~exist(markovFile, 'file')
        warning('createUtilityLayers: droughtMarkovFile not found: %s\n  Inter-annual variability skipped.', markovFile);
    elseif isempty(grmaLayerIdx)
        warning('createUtilityLayers: droughtVariabilityOn=true but no GRMA crop layers found. Skipped.');
    else
        % Load Markov parameter table
        MP = readtable(markovFile, 'TextType', 'string');

        % ----------------------------------------------------------------
        % STEP 1: Pre-generate drought state sequence (nLoc x nSimYears)
        % using one shared spatial correlation matrix (average across crop
        % layers).  All layers within the same region share the same
        % drought/normal state sequence — only the yield perturbation
        % magnitude varies by layer (different harvest month distributions
        % and Ky values).  This ensures a drought year for rice coincides
        % with a drought year for cassava in the same region.
        % ----------------------------------------------------------------

        % Use the rice_south (representative) layer to extract p_DD/p_ND/pi_D
        % for the shared state simulation — these are nearly identical across
        % layers for the same region.
        refLayer   = 'rice_south';
        refRows    = MP(MP.layer == refLayer, :);

        p_DD_vec  = zeros(nLoc, 1);
        p_ND_vec  = zeros(nLoc, 1);
        pi_D_vec  = zeros(nLoc, 1);
        hasParams = false(nLoc, 1);

        for iLoc = 1:nLoc
            rowIdx = find(refRows.region == locNamesGrma(iLoc), 1);
            if ~isempty(rowIdx)
                p_DD_vec(iLoc)  = refRows.p_DD(rowIdx);
                p_ND_vec(iLoc)  = refRows.p_ND(rowIdx);
                pi_D_vec(iLoc)  = refRows.pi_D(rowIdx);
                hasParams(iLoc) = true;
            end
        end

        % Load shared spatial correlation matrix
        sharedCorrFile = fullfile(grmaDataDir, 'spei6_corr_shared.csv');
        useCorr = false;
        if exist(sharedCorrFile, 'file')
            CT          = readtable(sharedCorrFile, 'ReadRowNames', true, 'TextType', 'string');
            corrRegions = string(CT.Properties.RowNames);

            locToCorrRow = zeros(nLoc, 1);
            for iLoc = 1:nLoc
                idx = find(corrRegions == locNamesGrma(iLoc), 1);
                if ~isempty(idx); locToCorrRow(iLoc) = idx; end
            end

            validIdx = find(hasParams & locToCorrRow > 0);
            nValid   = numel(validIdx);

            if nValid > 1
                corrRows = locToCorrRow(validIdx);
                R = table2array(CT(corrRows, corrRows));
                R = (R + R') / 2;
                minEig = min(eig(R));
                if minEig < 1e-8
                    R = R + (abs(minEig) + 1e-6) * eye(nValid);
                end
                try
                    cholL   = chol(R, 'lower');
                    useCorr = true;
                catch
                    warning('createUtilityLayers: Cholesky failed for shared correlation matrix. Using independent transitions.');
                end
            end
        else
            warning('createUtilityLayers: spei6_corr_shared.csv not found. Using independent regional transitions.');
        end

        % Initialise states from stationary distribution
        droughtStates = zeros(nLoc, nSimYears);   % 1 = drought, 0 = normal
        if useCorr
            z0 = cholL * randn(nValid, 1);
            state_vec = zeros(nLoc, 1);
            state_vec(validIdx) = double(normcdf(z0) < pi_D_vec(validIdx));
        else
            state_vec = zeros(nLoc, 1);
            state_vec(hasParams) = double(rand(sum(hasParams), 1) < pi_D_vec(hasParams));
        end

        % Simulate Markov chain forward — one shared sequence for all layers
        for iCyc = 1:nSimYears
            if useCorr
                u_all = normcdf(cholL * randn(nValid, 1));
            else
                u_all = rand(sum(hasParams), 1);
            end
            locsToUpdate = validIdx;   % or find(hasParams) if !useCorr

            for k = 1:numel(locsToUpdate)
                iLoc = locsToUpdate(k);
                if state_vec(iLoc) == 1
                    state_vec(iLoc) = double(u_all(k) < p_DD_vec(iLoc));
                else
                    state_vec(iLoc) = double(u_all(k) < p_ND_vec(iLoc));
                end
            end
            droughtStates(:, iCyc) = state_vec;
        end

        % ----------------------------------------------------------------
        % STEP 2: Apply layer-specific yield perturbations using the
        % shared drought state sequence.  Each layer has its own SPEI6
        % distribution (harvest month, Ky) so magnitude varies by layer.
        % ----------------------------------------------------------------

        nMarkovApplied = 0;
        for iL = grmaLayerIdx'
            layerName = char(layerDefs.name(iL));
            layerRows = MP(MP.layer == layerName, :);
            if isempty(layerRows)
                warning('createUtilityLayers: no Markov params for layer "%s". Skipping.', layerName);
                continue;
            end

            % Build per-location SPEI6 distribution vectors for this layer
            mu_d_vec = zeros(nLoc, 1);
            sd_d_vec = ones(nLoc, 1);

            for iLoc = 1:nLoc
                rowIdx = find(layerRows.region == locNamesGrma(iLoc), 1);
                if ~isempty(rowIdx)
                    mu_d_vec(iLoc) = layerRows.drought_spei_mean(rowIdx);
                    sd_d_vec(iLoc) = layerRows.drought_spei_std(rowIdx);
                end
            end

            % Per-layer drought floor: the agronomic minimum yield even in
            % extreme drought (utility_layers_v1.csv -> drought_min_yield).
            % Previously this block clipped at 0, allowing synthetic drought
            % years to push yield to 0% even where the crop has known
            % drought tolerance -- an inconsistency with the observed-SPEI
            % block (which respects the floor). Fix is to use the same
            % per-layer floor here so synthetic and observed drought
            % regimes are physically consistent.
            minYld = double(layerDefs.drought_min_yield(iL));
            if isnan(minYld); minYld = 0.0; end

            % Apply perturbations: drought state is shared, magnitude is layer-specific
            for iCyc = 1:nSimYears
                for iLoc = 1:nLoc
                    if ~hasParams(iLoc); continue; end
                    if droughtStates(iLoc, iCyc) == 1
                        spei6_sample = mu_d_vec(iLoc) + sd_d_vec(iLoc) * randn();
                        delta = scaleFac * spei6_sample;   % SPEI6 negative in drought → negative delta
                    else
                        delta = 0;
                    end
                    yieldFactor(iLoc, iL, iCyc) = ...
                        min(1.0, max(minYld, yieldFactor(iLoc, iL, iCyc) + delta));
                end
            end
            nMarkovApplied = nMarkovApplied + 1;
        end

        fprintf(['createUtilityLayers: drought Markov variability applied to %d layer(s) ' ...
                 '[scaleFactor=%.3f, spatialCorr=%d, sharedState=true].\n'], ...
                 nMarkovApplied, scaleFac, useCorr);
    end
end

% --- Fill simulation period (after spinup), applying drought factors ---
for iL = 1:nLayers
    for iCyc = 1:nSimYears
        tStart = leadTime + (iCyc - 1) * modelParameters.cycleLength + 1;
        for iQ = 1:modelParameters.cycleLength
            utilityBaseLayers(:, iL, tStart + iQ - 1) = ...
                mean_utility_by_layer(iL) * quarterShare(iL, iQ) ...
                .* yieldFactor(:, iL, iCyc);
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

% spatiallyRestricted(loc, layer) = true means that loc is OUTSIDE the
% allowed region for that layer.  Used later to enforce hard-slot blocking.
spatiallyRestricted = false(nLoc, nLayers);

restrictTo = layerDefs.restrict_to;
for iL = 1:nLayers
    if restrictTo(iL) ~= "ALL"
        regions = strsplit(restrictTo(iL), '|');
        allowedRows = ismember(locNameVec, regions);
        if ~any(allowedRows)
            warning('createUtilityLayers: layer "%s" restrict_to="%s" matched 0 locations in field "%s". Layer will be unavailable everywhere. Check spelling.', ...
                char(layerDefs.name(iL)), char(restrictTo(iL)), locNameField);
        end
        % Zero the base utility so income from this layer is 0 here
        utilityBaseLayers(~allowedRows, iL, :) = 0;
        % Record which loc/layer combinations are restricted
        spatiallyRestricted(~allowedRows, iL) = true;
    end
end

% --- Local demand coupling (kappa) ---------------------------------------
% In agriculture-dependent regions, local non-farm income (wage labour,
% petty trade) co-moves with the agricultural economy: when harvests fail,
% the demand that pays for non-farm work collapses too. The baseline model
% instead offers drought-IMMUNE non-farm layers everywhere, which the chain
% audit (2026-07) showed act as a local shock absorber: drought pushes
% agents into unskilled layers in-region instead of into migration.
%
% When modelParameters.localDemandCoupling (kappa, in [0, 1]) is > 0, every
% layer WITHOUT a grma_crop has its base utility scaled per location-year by
%
%   couplingFactor = 1 - kappa * (1 - agYF)
%
% where agYF is the mean drought yield factor across the ag layers actually
% available at that location (spatial restrictions respected). kappa = 0
% (default) reproduces legacy behaviour; kappa = 1 makes local non-farm
% income fully proportional to the local agricultural economy.
kappa = 0;
if isfield(modelParameters, 'localDemandCoupling')
    kappa = modelParameters.localDemandCoupling;
end
if kappa > 0 && ~isempty(grmaLayerIdx)
    nonAgIdx = setdiff(1:nLayers, grmaLayerIdx(:)');
    for iCyc = 1:nSimYears
        agYF = ones(nLoc, 1);
        for iLoc = 1:nLoc
            availAg = grmaLayerIdx(~spatiallyRestricted(iLoc, grmaLayerIdx));
            if ~isempty(availAg)
                agYF(iLoc) = mean(yieldFactor(iLoc, availAg, iCyc));
            end
        end
        couplingFactor = 1 - kappa * (1 - agYF);   % (nLoc x 1), in [1-kappa, 1]
        tStart = leadTime + (iCyc - 1) * modelParameters.cycleLength + 1;
        for iQ = 1:modelParameters.cycleLength
            utilityBaseLayers(:, nonAgIdx, tStart + iQ - 1) = ...
                utilityBaseLayers(:, nonAgIdx, tStart + iQ - 1) .* couplingFactor;
        end
    end
    % Refresh the spinup period so it mirrors the (coupled) first cycle.
    for iT = leadTime:-1:1
        utilityBaseLayers(:,:,iT) = utilityBaseLayers(:,:,iT + modelParameters.cycleLength);
    end
    fprintf('createUtilityLayers: local demand coupling applied (kappa = %.2f) to %d non-ag layer(s).\n', ...
            kappa, numel(nonAgIdx));
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

% Exported so midasMainLoop.m can recompute nExpected from the CURRENT
% regional population each timestep when modelParameters.dynamicNExpected
% is enabled (constant-fraction semantics: capacity = frac x population,
% rather than an absolute count frozen at the initial population).
nExpectedFrac = double(layerDefs.nExpected_frac);   % (nLayers x 1)

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

% Enforce spatial restrictions using the MIDAS hard-slot mechanism.
% Setting nExpected = 0 and hardSlotCountYN = true for restricted
% location/layer pairs means hasOpenSlots = false there, which causes
% choosePortfolio.m to actively strip those layers from any portfolio:
%   bestPortfolio(1,1:end-2) = hasOpenSlots(loc,:) & bestPortfolio(1,1:end-2)
% This is necessary because the backcasting algorithm in createPortfolio.m
% selects layers randomly without checking utility, so zeroing
% utilityBaseLayers alone is not enough to prevent occupation.
nExpected(spatiallyRestricted)      = 0;
hardSlotCountYN(spatiallyRestricted) = true;

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

%% -----------------------------------------------------------------------
%% 11. LOCAL-ONLY FLAGS (agricultural / location-tied layers)
%% -----------------------------------------------------------------------
% localOnly(i) = 1 means layer i is tied to the agent's current location
% (i.e., agricultural layers). Used for food insecurity tracking in
% midasMainLoop.m and for urban/rural calibration in buildNextRound.m.

localOnly = logical(layerDefs.localOnly);

end
