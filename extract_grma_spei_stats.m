% extract_grma_spei_stats.m
%
% Reads the GRMA SPEI-6 projected statistics NetCDF files, spatially
% aggregates the drought intensity and frequency variables to the 22
% Madagascar ADM2 regions, then computes a mean SPEI shift delta for each
% region relative to the GRMA baseline.
%
% The delta represents how much drier (more negative SPEI) each region
% becomes in each future scenario horizon, derived directly from the GRMA
% dataset rather than from generic IPCC regional estimates.
%
% Delta calculation per region:
%   mean_spei_contribution = frequency × intensity
%   (intensity is negative; frequency is fraction of time in drought)
%   delta = mean_spei_proj - mean_spei_baseline
%
% Output: Data/GRMA_SPEI_deltas.csv
%   Columns: NAME_2, delta_ssp2_2050, delta_ssp2_2085,
%                     delta_ssp5_2050, delta_ssp5_2085
%
% Run from the MIDAS-Madagascar project root:
%   >> extract_grma_spei_stats

clear; clc;

%% -----------------------------------------------------------------------
%% PATHS
%% -----------------------------------------------------------------------

grmaBase = fullfile('..', 'ISF - Migration modelling consultancy', ...
    'GRMA datasets', 'link', 'data', 'spei6');

files = struct( ...
    'baseline',  fullfile(grmaBase, 'stats_SPEI6_baseline.nc'), ...
    'ssp2_2050', fullfile(grmaBase, 'stats_SPEI6_median_ssp245_2050.nc'), ...
    'ssp2_2085', fullfile(grmaBase, 'stats_SPEI6_median_ssp245_2085.nc'), ...
    'ssp5_2050', fullfile(grmaBase, 'stats_SPEI6_median_ssp585_2050.nc'), ...
    'ssp5_2085', fullfile(grmaBase, 'stats_SPEI6_median_ssp585_2085.nc'));

shpFile = fullfile('Data', 'Mada Admin 2', 'Admin_2_lat_lon.shp');
outFile = fullfile('Data', 'GRMA_SPEI_deltas.csv');

scenNames = fieldnames(files);

%% -----------------------------------------------------------------------
%% READ GRID COORDINATES FROM BASELINE FILE
%% -----------------------------------------------------------------------

fprintf('Reading GRMA grid from: %s\n', files.baseline);
info = ncinfo(files.baseline);

fprintf('Variables in baseline file:\n');
for iV = 1:length(info.Variables)
    v = info.Variables(iV);
    dimNames = {v.Dimensions.Name};
    dimSizes = [v.Dimensions.Length];
    fprintf('  %-15s  dims: [%s]  size: [%s]\n', v.Name, ...
        strjoin(dimNames, ' x '), num2str(dimSizes));
end

lon = double(ncread(files.baseline, 'longitude'));  % coordinate vector
lat = double(ncread(files.baseline, 'latitude'));
nLon = length(lon);
nLat = length(lat);
fprintf('\nGrid: %d lon (%0.3f to %0.3f) x %d lat (%0.3f to %0.3f)\n', ...
    nLon, min(lon), max(lon), nLat, min(lat), max(lat));

% Determine the spatial dimension order of intensity/frequency variables.
% ncread returns data with dimensions in the order stored in the file.
% We need to know whether the data is [lon x lat] or [lat x lon].
intensInfo = info.Variables(strcmp({info.Variables.Name}, 'intensity'));
dimNames   = {intensInfo.Dimensions.Name};
if strcmp(dimNames{1}, 'longitude') || strcmp(dimNames{1}, 'x')
    % Data is [nLon x nLat] — will need to permute for meshgrid alignment
    dataIsLonLat = true;
else
    % Data is [nLat x nLon]
    dataIsLonLat = false;
end
fprintf('Data dimension order: %s\n', strjoin(dimNames, ' x '));

%% -----------------------------------------------------------------------
%% BUILD FLAT GRID AND REGION ASSIGNMENT
%% -----------------------------------------------------------------------

% meshgrid gives [nLat x nLon] arrays (standard for mapping)
[LON2D, LAT2D] = meshgrid(lon, lat);
gridLon = LON2D(:);   % [nPts x 1]
gridLat = LAT2D(:);
nPts    = numel(gridLon);

% Read shapefile
S    = shaperead(shpFile, 'UseGeoCoords', true);
nReg = length(S);

if isfield(S, 'NAME_2')
    regionNames = {S.NAME_2};
elseif isfield(S, 'ADM2_FR')
    regionNames = {S.ADM2_FR};
else
    error('Cannot find NAME_2 or ADM2_FR field in shapefile.');
end

% Assign each grid point to an ADM2 region (0 = outside all regions)
regionIdx = zeros(nPts, 1);
for iR = 1:nReg
    pLon  = S(iR).Lon;
    pLat  = S(iR).Lat;
    valid = ~isnan(pLon) & ~isnan(pLat);
    if ~any(valid), continue; end
    in = inpolygon(gridLon, gridLat, pLon(valid), pLat(valid));
    regionIdx(in) = iR;
end

nAssigned = sum(regionIdx > 0);
fprintf('Grid points assigned to regions: %d / %d\n', nAssigned, nPts);
if nAssigned == 0
    error(['No grid points matched any ADM2 region.\n' ...
           'Lon range in file: [%.3f, %.3f]; lat range: [%.3f, %.3f]\n' ...
           'Shapefile is in approx lon [43, 51], lat [-26, -12].'], ...
          min(lon), max(lon), min(lat), max(lat));
end

%% -----------------------------------------------------------------------
%% HELPER: read and flatten a variable to [nPts x 1]
%% -----------------------------------------------------------------------

function flat = readAndFlatten(ncFile, varName, nLon, nLat, dataIsLonLat)
    raw = double(ncread(ncFile, varName));
    % Mask implausible fill values
    raw(raw < -1e5 | raw > 1e5) = NaN;
    if dataIsLonLat
        % [nLon x nLat] -> permute to [nLat x nLon] -> flatten
        flat = reshape(permute(raw, [2 1]), nLon * nLat, 1);
    else
        % [nLat x nLon] -> flatten directly
        flat = raw(:);
    end
end

%% -----------------------------------------------------------------------
%% READ ALL SCENARIOS AND COMPUTE REGIONAL MEAN SPEI CONTRIBUTION
%% -----------------------------------------------------------------------
% mean_spei_contrib(iReg) = mean over grid points in region of (freq × intensity)
% This captures both how often drought occurs and how severe it is.

meanSpei = NaN(nReg, length(scenNames));

for iS = 1:length(scenNames)
    sName  = scenNames{iS};
    ncFile = files.(sName);
    fprintf('\nReading: %s\n', ncFile);

    intens_flat = readAndFlatten(ncFile, 'intensity',  nLon, nLat, dataIsLonLat);
    freq_flat   = readAndFlatten(ncFile, 'frequency',  nLon, nLat, dataIsLonLat);

    % Clip frequency to [0, 1]
    freq_flat = max(0, min(1, freq_flat));

    for iR = 1:nReg
        pts   = (regionIdx == iR);
        if ~any(pts), continue; end

        i_vals = intens_flat(pts);
        f_vals = freq_flat(pts);
        valid  = ~isnan(i_vals) & ~isnan(f_vals);
        if ~any(valid), continue; end

        % Mean SPEI contribution from drought periods: freq × intensity
        meanSpei(iR, iS) = mean(f_vals(valid) .* i_vals(valid), 'omitnan');
    end

    % Print regional summary
    fprintf('  Regional mean SPEI contribution (%.3f to %.3f, mean=%.3f)\n', ...
        min(meanSpei(:, iS), [], 'omitnan'), ...
        max(meanSpei(:, iS), [], 'omitnan'), ...
        mean(meanSpei(:, iS), 'omitnan'));
end

%% -----------------------------------------------------------------------
%% COMPUTE DELTAS RELATIVE TO BASELINE
%% -----------------------------------------------------------------------

iBase     = find(strcmp(scenNames, 'baseline'));
iSsp2_50  = find(strcmp(scenNames, 'ssp2_2050'));
iSsp2_85  = find(strcmp(scenNames, 'ssp2_2085'));
iSsp5_50  = find(strcmp(scenNames, 'ssp5_2050'));
iSsp5_85  = find(strcmp(scenNames, 'ssp5_2085'));

delta_ssp2_2050 = meanSpei(:, iSsp2_50) - meanSpei(:, iBase);
delta_ssp2_2085 = meanSpei(:, iSsp2_85) - meanSpei(:, iBase);
delta_ssp5_2050 = meanSpei(:, iSsp5_50) - meanSpei(:, iBase);
delta_ssp5_2085 = meanSpei(:, iSsp5_85) - meanSpei(:, iBase);

fprintf('\n--- GRMA SPEI deltas (mean across all regions) ---\n');
fprintf('SSP2-4.5 by 2050: %+.4f\n', mean(delta_ssp2_2050, 'omitnan'));
fprintf('SSP2-4.5 by 2085: %+.4f\n', mean(delta_ssp2_2085, 'omitnan'));
fprintf('SSP5-8.5 by 2050: %+.4f\n', mean(delta_ssp5_2050, 'omitnan'));
fprintf('SSP5-8.5 by 2085: %+.4f\n', mean(delta_ssp5_2085, 'omitnan'));

fprintf('\nPer-region deltas (SSP5-8.5 by 2085):\n');
for iR = 1:nReg
    fprintf('  %-25s  %+.4f\n', regionNames{iR}, delta_ssp5_2085(iR));
end

%% -----------------------------------------------------------------------
%% WRITE CSV
%% -----------------------------------------------------------------------

T = table(regionNames', delta_ssp2_2050, delta_ssp2_2085, ...
                        delta_ssp5_2050, delta_ssp5_2085, ...
    'VariableNames', {'NAME_2', 'delta_ssp2_2050', 'delta_ssp2_2085', ...
                               'delta_ssp5_2050', 'delta_ssp5_2085'});

writetable(T, outFile);
fprintf('\nWritten: %s\n', outFile);
fprintf('Run extend_spei_projections.py next to generate the extended SPEI CSVs.\n');
