function out = make_drought_state_panel(varargin)
% make_drought_state_panel  --  panel (c) of the drought workflow figure
%
%   make_drought_state_panel
%   make_drought_state_panel('SSP', 'SSP2', 'Seed', 7)
%
% WHAT IT SHOWS
% A raster of drought state by region and year. Regions on the vertical axis
% ordered north to south, years along the horizontal, one cell shaded where
% that region is in the drought state.
%
% TWO REGIMES, SIDE BY SIDE
%   1985-2022  OBSERVED. Derived from observed_spei_harvest.csv at the
%              rice_south harvest month, thresholded at SPEI-6 <= -0.5, which
%              is the same rule and the same reference layer the Markov
%              parameters were estimated from.
%   2023-2085  SYNTHETIC. One realisation of the two-state Markov chain, with
%              spatial correlation imposed through a Gaussian copula.
%
% WHY BOTH
% Supplemental 2.4.3 asserts that drought states are spatially correlated and
% that a Gaussian copula reproduces the observed north-south dipole. Nothing
% in the paper demonstrates it. Placing the observed record immediately beside
% a synthetic realisation lets a reader judge the claim: vertical banding
% across neighbouring regions means large-scale events co-occur, and the two
% halves should band in a comparable way. If the synthetic half is visibly
% more speckled than the observed half, the copula is not doing its job.
%
% WHAT ELSE IT MAKES VISIBLE
% Run length. Fitted p_DD in the Grand Sud is 0.09-0.17 against p_ND of
% 0.40-0.46, i.e. NEGATIVE persistence -- a drought year makes the next year
% less likely to be dry. The observed half confirms this is a property of the
% data and not of the chain: maximum observed run is two years, occurring
% twice in thirty-eight. Consecutive-year drought is therefore not the
% mechanism driving the model; recurrence outpacing herd recovery is.
%
% The synthetic half is drawn from ONE realisation, chosen by Seed. It is an
% example, not a summary, and the caption should say so -- a reader who takes
% it for an ensemble property will over-read whatever pattern this particular
% draw happens to show.

p = inputParser;
addParameter(p, 'SSP',       'SSP5');
addParameter(p, 'EndYear',   2085);
addParameter(p, 'Seed',      1);        % which synthetic realisation to display
addParameter(p, 'RefLayer',  'rice_south');   % layer the chain keys off
addParameter(p, 'Threshold', -0.5);     % SPEI-6 drought threshold
addParameter(p, 'South',     {'Androy', 'Anosy', 'Atsimo-Andrefana'});
addParameter(p, 'OutFile',   './Outputs/fig_panel_c_drought_states.png');
addParameter(p, 'LegendLocation', 'eastoutside');
addParameter(p, 'Axes',      []);
parse(p, varargin{:});
opt = p.Results;

addpath('./Override_Core_MIDAS_Code');
addpath('./Application_Specific_MIDAS_Code');
addpath('./Core_MIDAS_Code');

setenv('MIDAS_SSP', opt.SSP);
setenv('MIDAS_END_YEAR', num2str(opt.EndYear));
setenv('DROUGHT_VARIABILITY', '1');

% ---- world state --------------------------------------------------------
[agentParameters, modelParameters, networkParameters, mapParameters] = ...
    readParameters(table({'modelParameters.numAgents'}, 50, ...
                   'VariableNames', {'parameterNames', 'parameterValues'})); %#ok<ASGLU>
[locations, ~, ~, mapParameters] = createMapFromSHP(mapParameters); %#ok<ASGLU>
[locationLikelihood, genderLikelihood, ageLikelihood, survivalRate, ...
 fertilityRate, ageDiscountRateFactor, agePointsPopulation, ...
 agePointsSurvival, agePointsFertility, agePointsPref] = ...
    buildDemography(modelParameters, locations);
demographicVariables = struct( ...
    'locationLikelihood', locationLikelihood, 'genderLikelihood', genderLikelihood, ...
    'ageLikelihood', ageLikelihood, 'survivalRate', survivalRate, ...
    'fertilityRate', fertilityRate, 'ageDiscountRateFactor', ageDiscountRateFactor, ...
    'agePointsPopulation', agePointsPopulation, 'agePointsSurvival', agePointsSurvival, ...
    'agePointsFertility', agePointsFertility, 'agePointsPref', agePointsPref);

% Region names, resolved as createUtilityLayers resolves them (by ROW
% POSITION, not matrixID -- see the note in make_drought_module_figure.m).
if ismember('source_NAME_2', locations.Properties.VariableNames)
    srcFldUsed = "source_NAME_2";
else
    srcFlds = locations.Properties.VariableNames( ...
        startsWith(locations.Properties.VariableNames, 'source_'));
    srcFldUsed = string(srcFlds{1});
end
regNames = string(locations.(char(srcFldUsed)));
nLoc = numel(regNames);

% ---- repair truncated region names --------------------------------------
% createMapFromSHP loads a cached Admin_2_lat_lon.mat when present. If that
% cache was built without NAME_2, the fallback field is ADM2_FR, a
% 15-CHARACTER DBF field that TRUNCATES: 'Atsimo-Andrefana' becomes
% 'Atsimo-Andrefan', 'Vatovavy Fitovinany' becomes 'Vatovavy Fitovi'. Exactly
% two of the 22 names exceed 15 characters, so exactly two regions fail every
% drought lookup and run with no drought forcing at all.
%
% The figure repairs its own copy so it can still be produced, by matching each
% truncated name to the unique full name in the Markov parameter file. The
% MODEL is deliberately NOT repaired this way -- createUtilityLayers errors on
% unmatched regions, and it should, because a silently drought-free study
% region is worse than a failed run. Fix the cache before the campaign.
[regNames, nFixed] = repairTruncatedNames(regNames, modelParameters.droughtMarkovFile);
if nFixed > 0
    fprintf(['\n*** %d region name(s) were TRUNCATED and have been repaired for\n' ...
             '    this figure only. The model will still refuse to run.\n' ...
             '    Delete the geometry cache to fix it properly:\n' ...
             '      Data/Mada Admin 2/Admin_2_lat_lon.mat\n\n'], nFixed);
    locations.(char(srcFldUsed)) = cellstr(regNames);
end

% ---- synthetic states ---------------------------------------------------
rng(opt.Seed);
[~, ~, ~, ~, ~, ~, ~, ~, ~, ~, ~, ~, ~, ~, ~, ~, dStates] = ...
    createUtilityLayers(locations, modelParameters, demographicVariables);
nSimYears = size(dStates, 2);
% agYF column iCyc IS calendar year startYear + iCyc - 1
% (createUtilityLayers.m:304), so the offset is 0, not 1. This read
% startYear + (1:nSimYears) and labelled every drought year one year late.
years = modelParameters.startYear + (0:nSimYears-1);

% ---- observed states ----------------------------------------------------
% Same rule the Markov parameters were fitted with, so the two halves of the
% raster are directly comparable rather than merely adjacent.
obsFile = fullfile(fileparts(modelParameters.utilityLayersFile), ...
                   'observed_spei_harvest.csv');
obsStates = nan(nLoc, nSimYears);
if exist(obsFile, 'file')
    OS = readtable(obsFile, 'TextType', 'string', 'VariableNamingRule', 'preserve');
    nameCol = OS.Properties.VariableNames{ ...
        find(contains(lower(OS.Properties.VariableNames), {'name', 'region'}), 1)};
    obsNames = strtrim(string(OS.(nameCol)));
    % ROBUST MATCHING. Names are byte-identical across the shapefile,
    % observed_spei_harvest.csv, drought_markov_params.csv, spei6_corr_shared.csv
    % and the GRMA surfaces -- verified 2026-09-03, plain ASCII hyphens and
    % spaces throughout. But `locations` may be loaded from the cached
    % Admin_2_lat_lon.mat rather than re-read from the shapefile, and a stale
    % cache can carry names that no longer agree with the CSVs.
    %
    % So: exact match first, then trimmed/case-insensitive, and if a region
    % still fails, SAY SO and name the nearest candidates. A blank row on the
    % raster is indistinguishable from a drought-free region, which is exactly
    % the kind of silent gap this project has been bitten by before.
    nMatched = 0; unmatched = strings(0);
    for iLoc = 1:nLoc
        want = strtrim(regNames(iLoc));
        r = find(strtrim(obsNames) == want, 1);
        if isempty(r)
            r = find(strcmpi(strtrim(obsNames), want), 1);
        end
        if isempty(r)
            unmatched(end+1) = want; %#ok<AGROW>
            continue;
        end
        nMatched = nMatched + 1;
        for iy = 1:nSimYears
            col = sprintf('%s_y%d', opt.RefLayer, years(iy));
            if ismember(col, OS.Properties.VariableNames)
                v = OS.(col)(r);
                if ~isnan(v); obsStates(iLoc, iy) = double(v <= opt.Threshold); end
            end
        end
    end
    if ~isempty(unmatched)
        fprintf('\n*** %d region(s) UNMATCHED in %s ***\n', ...
                numel(unmatched), 'observed_spei_harvest.csv');
        for u = unmatched
            fprintf('  wanted: %s\n', u);
            % Nearest candidates by shared prefix, to expose a rename or a
            % stale cache rather than leaving the row blank.
            pre = extractBefore(u + " ", " ");
            cand = obsNames(startsWith(obsNames, extractBefore(pre + "xx", 4), 'IgnoreCase', true));
            if isempty(cand); cand = obsNames(1:min(3, numel(obsNames))); end
            fprintf('    file has: %s\n', strjoin(cellstr(cand)', ', '));
        end
        fprintf(['  These rows will be blank. If the names look identical, the\n' ...
                 '  locations table is probably coming from the cached\n' ...
                 '  Admin_2_lat_lon.mat -- delete it to force a shapefile re-read.\n\n']);
    end
    fprintf('observed states: %d of %d regions matched\n', nMatched, nLoc);
else
    warning('observed_spei_harvest.csv not found -- observed half will be blank');
end

% ---- combine: observed to 2022, synthetic from 2023 ---------------------
% The chain is simulated across the whole window but only APPLIED from 2023,
% so its pre-2023 columns are generated and unused. Showing them would imply
% the model used synthetic states during the observation period, which it did
% not.
S = nan(nLoc, nSimYears);
isObs = years <= 2022;
S(:,  isObs) = obsStates(:,  isObs);
S(:, ~isObs) = dStates(:,   ~isObs);

% ---- order regions north to south --------------------------------------
% Latitude is NOT in the locations table: createMapFromSHP keeps only the
% shapefile fields matching mapParameters.levelName ('NAME_') or levelID
% ('_PCODE'), so source_NAME_2, source_ADM2_FR and source_ADM2_PCODE survive
% and Latitude does not. An earlier version looked for it there, found
% nothing, and silently left the rows in shapefile order -- which put Diana
% and Sava, the two northernmost regions, in the middle of the raster and made
% the north-south dipole unreadable.
%
% Read it from the shapefile instead. shaperead works even on MATLAB versions
% where the rasterisation path does not (see repair_geometry_cache.m).
%
% Madagascar is in the SOUTHERN hemisphere, so latitudes are negative and
% "north" is the LARGEST value. Sorting descending puts north first in the
% array; because the axis uses YDir 'normal', row 1 is drawn at the BOTTOM, so
% the array must be sorted ASCENDING for north to appear at the top.
ord = 1:nLoc; haveLat = false;
try
    Sshp = shaperead(mapParameters.filePath);
    if isfield(Sshp, 'Latitude') && numel(Sshp) == nLoc
        lat = [Sshp.Latitude]';
        [~, ord] = sort(lat, 'ascend');   % south first in array -> north at top
        haveLat = true;
        fprintf('Regions ordered by latitude: %s (north, %.2f) to %s (south, %.2f)\n', ...
                regNames(ord(end)), lat(ord(end)), regNames(ord(1)), lat(ord(1)));
    end
catch shpErr
    fprintf('Could not read latitude from shapefile: %s\n', shpErr.message);
end
if ~haveLat
    fprintf(['NOTE: regions are in FILE ORDER, not north-south. The dipole will\n' ...
             '      not be readable. Check mapParameters.filePath.\n']);
end
S = S(ord, :); regNamesOrd = regNames(ord);

% ---- plot ---------------------------------------------------------------
if isempty(opt.Axes)
    fig = figure('Position', [100 100 1150 520], 'Color', 'w');
    ax  = axes(fig);
else
    ax = opt.Axes;
end
% NaN renders as white via AlphaData, so unmatched regions are visibly absent
% rather than silently drawn as "no drought".
imagesc(ax, years, 1:nLoc, S, 'AlphaData', ~isnan(S));
COL_DRY = [0.72 0.28 0.18];
COL_WET = [0.94 0.94 0.96];
colormap(ax, [COL_WET; COL_DRY]);
caxis(ax, [0 1]);
set(ax, 'YTick', 1:nLoc, 'YTickLabel', regNamesOrd, 'FontSize', 8, ...
        'TickLength', [0 0], 'YDir', 'normal');
hold(ax, 'on');

% LEGEND. imagesc produces a single image object, so the two states cannot be
% legended directly. These zero-area patches exist only to carry a colour and
% a name into the legend; NaN vertices mean nothing is drawn on the axes.
% Without them the reader has to infer that red means drought, which is an
% inference a figure should not require.
patch(ax, NaN, NaN, COL_DRY, 'EdgeColor', 'none', ...
      'DisplayName', sprintf('drought year (SPEI-6 \\leq %.1f)', opt.Threshold));
patch(ax, NaN, NaN, COL_WET, 'EdgeColor', [0.75 0.75 0.75], ...
      'DisplayName', 'normal year');
if any(isnan(S(:)))
    patch(ax, NaN, NaN, [1 1 1], 'EdgeColor', [0.75 0.75 0.75], ...
          'DisplayName', 'no data (region unmatched)');
end
plot(ax, [NaN NaN], [NaN NaN], '-', 'Color', [0.1 0.1 0.1], 'LineWidth', 1.5, ...
     'DisplayName', 'end of observed record (2022)');
% LEGEND PLACEMENT. 'eastoutside' standalone, where there is width to spare.
% Inside the composite this axes sits in the left column and an eastoutside
% legend would push into the map, so the assembler passes 'southoutside'.
legend(ax, 'show', 'Location', opt.LegendLocation, 'Box', 'off', 'FontSize', 9);

xline(ax, 2022.5, '-', 'Color', [0.1 0.1 0.1], 'LineWidth', 1.5, ...
      'HandleVisibility', 'off');

% Label each half for what it IS. The left half is the measured record and is
% identical in every model run; only the right half is a draw. Calling both
% "realisations" would misrepresent the observation period.
text(ax, 2003, nLoc + 0.9, 'OBSERVED record (1985-2022)', ...
     'FontSize', 9, 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
% Seed is named so the panel is reproducible, but no realisation COUNT is
% given: how many draws the campaign runs is a property of the campaign, not
% of this figure, and stating it here invites the reader to treat one draw as
% a summary of many.
text(ax, 2054, nLoc + 0.9, sprintf('SYNTHETIC (one Markov realisation, seed %d)', ...
     opt.Seed), ...
     'FontSize', 9, 'HorizontalAlignment', 'center', 'FontWeight', 'bold');
ylim(ax, [0.5 nLoc + 1.5]);
xlabel(ax, 'year');
title(ax, sprintf(['Drought state by region, %s.  Left: measured ERA5 record. ' ...
                   'Right: one Markov realisation.'], opt.SSP), ...
      'FontWeight', 'normal');

if isempty(opt.Axes)
    exportgraphics(fig, opt.OutFile, 'Resolution', 200);
    fprintf('Wrote %s\n', opt.OutFile);
end

% ---- diagnostics --------------------------------------------------------
% The claim the panel is making, stated numerically so the figure can be
% checked rather than eyeballed.
fprintf('\n--- panel (c) ---\n');
southMask = ismember(lower(regNamesOrd), lower(string(opt.South)));
for half = 1:2
    if half == 1
        M = S(:, years <= 2022); lbl = 'observed  ';
    else
        M = S(:, years >= 2023); lbl = 'synthetic ';
    end
    prev = mean(M(:), 'omitnan');
    % Spatial co-occurrence: mean pairwise correlation of regional state series.
    C = corrcoef(M', 'Rows', 'pairwise');
    C(logical(eye(size(C)))) = NaN;
    % Run length, southern regions only.
    runs = [];
    for iLoc = find(southMask)'
        v = M(iLoc, :); v(isnan(v)) = 0; c = 0;
        for x = v
            if x == 1; c = c + 1; elseif c > 0; runs(end+1) = c; c = 0; end %#ok<AGROW>
        end
        if c > 0; runs(end+1) = c; end %#ok<AGROW>
    end
    fprintf('%s prevalence %.3f | mean inter-region r %.3f | south max run %d yr\n', ...
            lbl, prev, mean(C(:), 'omitnan'), max([runs 0]));
end
fprintf(['\nIf the two mean inter-region correlations are similar, the copula is\n' ...
         'reproducing observed co-occurrence. If the synthetic value is much\n' ...
         'lower, the correlation structure is not surviving into the projection.\n']);

out = struct('years', years, 'states', S, 'regions', regNamesOrd);
end

function [names, nFixed] = repairTruncatedNames(names, markovFile)
% Match each name against the authoritative list in the Markov parameter file.
% A name that matches nothing exactly but is a unique PREFIX of exactly one
% entry is a truncation, and is replaced by the full string. Ambiguous or
% unmatched names are left alone and reported by the caller.
nFixed = 0;
if ~exist(markovFile, 'file'); return; end
MP  = readtable(markovFile, 'TextType', 'string');
ref = unique(strtrim(string(MP.region)));
for i = 1:numel(names)
    nm = strtrim(names(i));
    if any(ref == nm); continue; end                 % already correct
    hit = ref(startsWith(ref, nm));                  % truncation candidates
    if numel(hit) == 1
        fprintf('  repaired: "%s" -> "%s"\n', nm, hit);
        names(i) = hit;
        nFixed = nFixed + 1;
    elseif numel(hit) > 1
        fprintf('  AMBIGUOUS: "%s" could be any of: %s -- left unchanged\n', ...
                nm, strjoin(cellstr(hit)', ', '));
    end
end
end
